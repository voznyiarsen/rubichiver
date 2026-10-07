# frozen_string_literal: true

require 'set'
require 'uri'
require 'open3'
require 'fileutils'
require_relative 'logger'

class Stats
  attr_reader :total_posts, :downloaded_files, :autotagged_files, :skipped_files,
              :failed_files, :blacklisted_files, :reused_files

  def initialize
    @mutex = Mutex.new
    @total_posts = 0
    @downloaded_files = 0
    @autotagged_files = 0
    @skipped_files = 0
    @failed_files = 0
    @blacklisted_files = 0
    @reused_files = 0
  end

  def increment(stat)
    @mutex.synchronize do
      case stat
      when :total_posts then @total_posts += 1
      when :downloaded_files then @downloaded_files += 1
      when :autotagged_files then @autotagged_files += 1
      when :skipped_files then @skipped_files += 1
      when :failed_files then @failed_files += 1
      when :blacklisted_files then @blacklisted_files += 1
      when :reused_files then @reused_files += 1
      end
    end
  end
end

class PostProcessor
  include Rubichiver::Logging

  UNSUPPORTED_EXTENSIONS = %w[swf].freeze
  # Upper bound on how long an idle worker sleeps before rechecking the stop
  # condition, in case a wakeup is missed.
  IDLE_POLL_SECONDS = 0.25
  # A download gets MAX_RETRIES back-to-back attempts (one round), then goes
  # to the back of the queue and tries again later. Rounds times attempts is
  # the total budget per post: 10 x 3 = ~30.
  MAX_ROUNDS = 10
  # Seconds to wait before each later round. Indexed by completed rounds, so
  # the first retry waits 30s and a stubborn post waits up to 5 minutes between
  # rounds. Worst case added latency is ~31 minutes, and only workers with
  # nothing else to do sit it out — everyone else keeps draining the queue.
  ROUND_DELAYS = [30, 60, 120, 180, 300, 300, 300, 300, 300].freeze
  # A retry carries the original claimed location and round number; it is not
  # an API post and is never persisted as site data.
  RetryWork = Struct.new(:post, :location, :served_ext, :orig_ext, :file_url, :round)
  # Cap on a dequeue wait so an interrupt is honoured promptly even when the
  # only outstanding work is deferred retries due minutes out.
  DEFER_WAIT_CAP = 1.0

  def initialize(rate_limiter:, output_dir:, stats:, thread_count: 4, dry_run: false, archiver: nil)
    @queue = Queue.new
    # Posts whose download round failed and are waiting out their backoff.
    # Entries are [due_monotonic, RetryWork]; each stays counted in @pending
    # while deferred, so workers cannot exit with retries outstanding.
    @deferred = []
    @rate_limiter = rate_limiter
    @output_dir = output_dir
    @stats = stats
    @dry_run = dry_run
    @archiver = archiver
    @workers = []
    @interrupt_skipped = 0
    @interrupt_mutex = Mutex.new
    # A post is placed once per location. Pool bundling can enqueue the same
    # post from several directions at once, and two workers must never write
    # the same .part file.
    @claimed = Set.new
    @claim_mutex = Mutex.new
    # Workers can produce more work — pool bundling enqueues the rest of a
    # bundle from inside the worker that found it — so termination is tracked
    # by an outstanding-work count rather than by sentinels. Sentinels would be
    # reached before those extra items and truncate bundles non-deterministically.
    @pending = 0
    @finishing = false
    @pending_mutex = Mutex.new
    @work_available = ConditionVariable.new

    thread_count.times { |i| @workers << Thread.new { worker_loop(i) } }
  end

  def enqueue(post)
    @pending_mutex.synchronize do
      @pending += 1
      @queue << post
      @work_available.signal
    end
  end

  def finish
    @pending_mutex.synchronize do
      @finishing = true
      @work_available.broadcast
    end
  end

  def wait
    @workers.each(&:join)
    log_info "Skipped #{@interrupt_skipped} posts due to interrupt" if @interrupt_skipped > 0
  end

  # Waiting for a backoff is intentional, not a disk stall. The watchdog can
  # suppress its warning only when *all* outstanding work is deferred; a stuck
  # download worker must still be reported.
  def waiting_for_download_retry?
    @pending_mutex.synchronize do
      @finishing && @queue.empty? && !@deferred.empty? && @pending == @deferred.size
    end
  end

  private

  # Blocks until an item is available, or returns nil once the run is finishing
  # and nothing is outstanding. Retries whose backoff has elapsed rejoin the
  # back of the queue; ones still waiting keep the worker parked without
  # spinning, and an interrupt drains them immediately so shutdown never hangs
  # on a backoff.
  def dequeue
    @pending_mutex.synchronize do
      loop do
        release_due_retries
        unless @queue.empty?
          return @queue.pop(true)
        end
        return nil if @finishing && @pending.zero?

        if !@deferred.empty? && @archiver&.interrupted
          @deferred.each { |(_, post)| @queue << post }
          @deferred.clear
          @work_available.broadcast
          next
        end

        wait_for = deferred_wait
        if wait_for
          @work_available.wait(@pending_mutex, wait_for)
        else
          @work_available.wait(@pending_mutex, IDLE_POLL_SECONDS)
        end
      end
    end
  end

  # Moves retries whose backoff has elapsed to the back of the queue, behind
  # every post that has not been tried yet.
  def release_due_retries
    return if @deferred.empty?

    now = monotonic_now
    due, later = @deferred.partition { |(due_at, _)| due_at <= now }
    return if due.empty?

    @deferred.replace(later)
    due.each { |(_, post)| @queue << post }
    @work_available.broadcast
  end

  # How long to park when the only outstanding work is backing off, capped so
  # an interrupt is honoured promptly. Nil when ordinary work may still arrive.
  def deferred_wait
    return nil if @deferred.empty?

    wait_for = @deferred.map(&:first).min - monotonic_now
    wait_for = 0 if wait_for.negative?
    [wait_for, DEFER_WAIT_CAP].min
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def complete_one
    @pending_mutex.synchronize do
      @pending -= 1
      @work_available.broadcast if @finishing
    end
  end

  def worker_loop(idx)
    loop do
      post = dequeue
      break if post.nil?

      begin
        if post.is_a?(RetryWork)
          process_retry(post, idx)
        else
          process_post(post, idx)
        end
      rescue => e
        # An unexpected fault must be a *reported* failure. Swallowing it here
        # dropped the post entirely while the run still exited 0, which is the
        # one outcome an archiver must never produce.
        log_error "Worker thread error: #{e.class}: #{e.message}", thread: idx, error: e.message,
                                                                    backtrace: e.backtrace&.first(3)&.join(' | ')
        @stats.increment(:failed_files)
      ensure
        complete_one
      end
    end
  end

  # The original location claim remains held across rounds, so another worker
  # cannot race the same .part file. Neither pool expansion nor discovery is
  # repeated for a retry; only this location's failed download is retried.
  def process_retry(work, thread_idx)
    if @archiver.interrupted
      @interrupt_mutex.synchronize { @interrupt_skipped += 1 }
      @stats.increment(:skipped_files)
      return
    end

    place_post(work.post, work.location, work.served_ext, work.orig_ext,
               work.file_url, thread_idx, round: work.round)
  end

  def retry_delay_for_round(completed_round)
    ROUND_DELAYS.fetch(completed_round - 1)
  end

  def defer_download(post, location, served_ext, orig_ext, file_url, round)
    delay = retry_delay_for_round(round)
    work = RetryWork.new(post, location, served_ext, orig_ext, file_url, round + 1)
    @pending_mutex.synchronize do
      @pending += 1
      @deferred << [monotonic_now + delay, work]
      @work_available.broadcast
    end
    log_warn "Post #{post['id']} download failed after #{round * Archiver::MAX_RETRIES} attempts; " \
             "requeued for round #{round + 1}/#{MAX_ROUNDS} in #{delay}s",
             post_id: post['id'], round: round, delay: delay
  end

  def claim(post_id, location)
    key = @archiver.existing_key(post_id, location)
    @claim_mutex.synchronize { @claimed.add?(key) ? true : false }
  end

  def process_post(post, thread_idx)
    post_id = post['id']

    log_info "Thread #{thread_idx}: Processing post #{post_id}", post_id: post_id, thread: thread_idx

    if @archiver.interrupted
      @interrupt_mutex.synchronize { @interrupt_skipped += 1 }
      @stats.increment(:skipped_files)
      return
    end

    file_url = @archiver.post_file_url(post)
    unless file_url
      log_debug "Thread #{thread_idx}: Post #{post_id} has no file URL, skipping", thread: thread_idx
      @stats.increment(:skipped_files)
      return
    end

    orig_ext = @archiver.post_file_ext(post)
    served_ext = @archiver.resolve_served_extension(post, orig_ext, file_url)

    if UNSUPPORTED_EXTENSIONS.include?(served_ext.downcase)
      log_info "Thread #{thread_idx}: Skipping post #{post_id} (unsupported format: #{served_ext})", thread: thread_idx
      @stats.increment(:skipped_files)
      return
    end

    locations = @archiver.post_locations(post)

    if @dry_run
      locations.each do |location|
        log_info "Thread #{thread_idx}: Would archive post #{post_id} (#{served_ext}) in #{location.directory}",
                 post_id: post_id, url: file_url, directory: location.directory, thread: thread_idx
      end
      return
    end

    # Bundling runs before this post is placed so the pool's remaining posts
    # are queued. It is a no-op for posts that were themselves pulled in by a
    # pool, which keeps bundling from cascading.
    @archiver.expand_pools(post, thread_idx: thread_idx) { |sibling| enqueue(sibling) }

    locations.each do |location|
      next unless claim(post_id, location)

      place_post(post, location, served_ext, orig_ext, file_url, thread_idx)
    end
  end

  def place_post(post, location, served_ext, orig_ext, file_url, thread_idx, round: 1)
    post_id = post['id']

    FileUtils.mkdir_p(location.directory) unless Dir.exist?(location.directory)

    existing = @archiver.existing_media(post_id, location)
    if existing
      refresh_sidecar(existing, post, location, thread_idx)
      return
    end

    # A post that is already archived somewhere else does not need fetching a
    # second time just because it is a member of another pool.
    reused = @archiver.place_existing_media(post_id, location, served_ext)
    if reused
      log_info "Thread #{thread_idx}: Post #{post_id} already archived elsewhere, placed at #{reused}",
               post_id: post_id, directory: location.directory, thread: thread_idx
      @stats.increment(:reused_files)
      # Carries the source's recorded MD5 over, so the placed copy is still
      # covered by --verify-md5 rather than being exempt from it.
      @archiver.record_archived_file(post, location, reused,
                                     md5: @archiver.db.known_md5(post_id))
      refresh_sidecar(reused, post, location, thread_idx)
      return
    end

    output_file = File.join(location.directory, "#{post_id}.#{served_ext}")
    # When the served extension differs from the recorded one the site is not
    # serving the bytes the MD5 was computed over, so verification is dropped.
    md5 = served_ext == orig_ext ? @archiver.post_md5(post) : nil

    unless @archiver.download_media(file_url, output_file, post_id, md5, thread_idx: thread_idx)
      if @archiver.interrupted
        @interrupt_mutex.synchronize { @interrupt_skipped += 1 }
        @stats.increment(:skipped_files)
      elsif round < MAX_ROUNDS
        defer_download(post, location, served_ext, orig_ext, file_url, round)
      else
        attempts = round * Archiver::MAX_RETRIES
        log_error "Thread #{thread_idx}: Post #{post_id} download failed after " \
                  "#{attempts} attempts (#{MAX_ROUNDS} rounds); recorded for --retry-failed",
                  post_id: post_id, thread: thread_idx
        @archiver.db.record_download_failure(post_id, attempts: attempts,
                                                       error: @archiver.download_error_for(post_id))
        @stats.increment(:failed_files)
      end
      return
    end

    log_info "Thread #{thread_idx}: Writing XMP sidecar for post #{post_id}", post_id: post_id, thread: thread_idx
    @archiver.record_archived_file(post, location, output_file, md5: md5)
    result = @archiver.write_sidecar(output_file, post)

    case result
    when true
      @archiver.record_sidecar_written(post, location, output_file)
      log_info "Thread #{thread_idx}: Post #{post_id} archived successfully", post_id: post_id, thread: thread_idx
      @stats.increment(:downloaded_files)
    when :skipped, :unrated, :uncategorized
      # The media is safely archived; only the metadata is missing, and a later
      # run can supply it. Counting it as a download keeps the two honest.
      log_info "Thread #{thread_idx}: Post #{post_id} archived, sidecar not written (#{result})",
               post_id: post_id, reason: result, thread: thread_idx
      @stats.increment(:downloaded_files)
    else
      log_error "Thread #{thread_idx}: Post #{post_id} sidecar write failed", post_id: post_id, thread: thread_idx
      @stats.increment(:failed_files)
    end
  end

  # An already-archived post is only touched when its sidecar has drifted from
  # what the post currently says. Either way the file is verified present, so
  # any earlier recorded download failure for the post is resolved.
  def refresh_sidecar(existing, post, location, thread_idx)
    post_id = post['id']

    if @archiver.sidecar_valid?(post, location)
      log_info "Thread #{thread_idx}: Post #{post_id} sidecar valid, skipping", post_id: post_id, thread: thread_idx
      @archiver.db.clear_download_failure(post_id)
      @stats.increment(:skipped_files)
      return
    end

    log_info "Thread #{thread_idx}: Post #{post_id} sidecar missing or invalid, regenerating",
             post_id: post_id, thread: thread_idx
    result = @archiver.write_sidecar(existing, post)

    case result
    when true
      @archiver.record_sidecar_written(post, location, existing)
      @archiver.db.clear_download_failure(post_id)
      log_info "Thread #{thread_idx}: Post #{post_id} sidecar regenerated successfully",
               post_id: post_id, thread: thread_idx
      @stats.increment(:autotagged_files)
    when :skipped, :unrated, :uncategorized
      # The site gave no rating, or no usable tag categories. Not a failure —
      # the media is archived and a later run can do better.
      log_info "Thread #{thread_idx}: Post #{post_id} sidecar not written (#{result})",
               post_id: post_id, reason: result, thread: thread_idx
      @stats.increment(:skipped_files)
    else
      # exiftool itself failed. That is a real failure and has to be reported,
      # or a broken exiftool looks exactly like a clean run.
      log_error "Thread #{thread_idx}: Post #{post_id} sidecar regeneration failed",
                post_id: post_id, thread: thread_idx
      @stats.increment(:failed_files)
    end
  end
end
