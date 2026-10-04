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

  def initialize(rate_limiter:, output_dir:, stats:, thread_count: 4, dry_run: false, archiver: nil)
    @queue = Queue.new
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

  private

  # Blocks until an item is available, or returns nil once the run is finishing
  # and nothing is outstanding.
  def dequeue
    @pending_mutex.synchronize do
      loop do
        return @queue.pop(true) unless @queue.empty?
        return nil if @finishing && @pending.zero?

        @work_available.wait(@pending_mutex, IDLE_POLL_SECONDS)
      end
    end
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
        process_post(post, idx)
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

  def place_post(post, location, served_ext, orig_ext, file_url, thread_idx)
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
      log_error "Thread #{thread_idx}: Post #{post_id} download failed", post_id: post_id, thread: thread_idx
      @stats.increment(:failed_files)
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
  # what the post currently says.
  def refresh_sidecar(existing, post, location, thread_idx)
    post_id = post['id']

    if @archiver.sidecar_valid?(post, location)
      log_info "Thread #{thread_idx}: Post #{post_id} sidecar valid, skipping", post_id: post_id, thread: thread_idx
      @stats.increment(:skipped_files)
      return
    end

    log_info "Thread #{thread_idx}: Post #{post_id} sidecar missing or invalid, regenerating",
             post_id: post_id, thread: thread_idx
    result = @archiver.write_sidecar(existing, post)

    case result
    when true
      @archiver.record_sidecar_written(post, location, existing)
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
