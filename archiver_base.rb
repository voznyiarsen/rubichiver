# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'
require 'digest'
require 'monitor'
require 'time'
require 'net/http'
require 'uri'
require 'open3'
require_relative 'logger'
require_relative 'rate_limiter'
require_relative 'archive_db'
require_relative 'version'
require_relative 'dns_cache'

class Archiver
  include Rubichiver::Logging

  MAX_RETRIES = 3
  RETRY_BACKOFF = 1
  MAX_REDIRECTS = 5
  OPEN_TIMEOUT = 30
  API_READ_TIMEOUT = 60
  DOWNLOAD_READ_TIMEOUT = 300
  RECACHE_BATCH_SIZE = 300
  # One exiftool per batch, so bigger batches mean fewer forks. 2000 paths fit
  # comfortably in an argv; a batch that will not read is still halved until it
  # does, so an oversized batch degrades rather than fails.
  SIDECAR_READ_BATCH = 2000
  # Cache entries older than this are dropped at startup, so the cache stays
  # useful without growing without bound.
  CACHE_MAX_AGE_DAYS = 90
  # A run that makes no visible progress for this long says so loudly. A wedged
  # run looks exactly like a slow one from the outside, and silently burning
  # hours is worse than a noisy warning.
  STALL_WARN_SECONDS = 300
  # Per worker, not per run: with -j 4 the ceiling is four times this.
  #
  # This is a ceiling, not a throttle, and it is set far above what e621 allows
  # (2 req/s TOTAL, and 503 over it) on purpose. A measured run made 2,856
  # requests in 10 hours -- 0.08 req/s -- so it never comes close to binding
  # either value, and the run is bound by exiftool and disk seeks instead. What
  # it does change is work that is genuinely request-bound: Gelbooru has no bulk
  # id lookup, so a recache is one request per archived post, which is ~2.8
  # hours at 1 req/s and minutes here.
  #
  # Going over the site's limit is therefore not the risk it looks like -- the
  # site is never actually being hit that hard. The real protection is the site's
  # own 503 and the adaptive back-off, which handles the case where this
  # ceiling ever does bind.
  DEFAULT_REQUESTS_PER_SECOND = 8

  # Loose posts and their sidecars live here, not at the archive root. The root
  # holds the lock file, the database, pool bundles and this directory — nothing
  # else — so a listing of the archive shows structure instead of 100k files.
  POSTS_DIR = 'posts'

  SIDECAR_SUFFIX = '.xmp'
  PART_SUFFIX = '.part'
  # Never treated as archived media, and removed at the start of a run.
  TEMP_SUFFIXES = [PART_SUFFIX, '.tmp'].freeze
  # Marks bytes the integrity check set aside. Never indexed as media, so a
  # re-download writes a clean file while the original stays recoverable.
  DAMAGED_MARK = '.damaged'
  DAMAGED_PATTERN = /\.damaged-\d{8}T\d{6}Z\z/.freeze
  # A sidecar part-written by a killed run. exiftool picks the output format from
  # the file extension, so the temporary name has to end in .xmp for the
  # extension to mean anything — the .part marker goes before it.
  SIDECAR_TMP_PATTERN = /\.xmp\.\d+\.part\.xmp\z/.freeze
  DB_BASENAME = '.rubichiver.db'
  # Marks a post that was pulled in by a pool rather than by a tag query, so
  # its own pools are not expanded in turn.
  POOL_MEMBER = '_pool_member'

  TAG_CATEGORIES = %w[general artist contributor copyright character species invalid meta metadata lore].freeze

  # XMP fields a sidecar carries, in the order they are written. The key is how
  # a field is addressed inside the expected-payload hash; the value is the
  # exiftool tag, used both to write the sidecar and to read it back for
  # validation, so the write and the check can never disagree about what the
  # sidecar should say.
  SIDECAR_FIELDS = {
    'Title' => 'XMP-dc:Title',
    'Creator' => 'XMP-dc:Creator',
    'Subject' => 'XMP-dc:Subject',
    'Description' => 'XMP-dc:Description',
    'Rights' => 'XMP-dc:Rights',
    'Rating' => 'XMP-xmp:Rating',
    'CreateDate' => 'XMP-xmp:CreateDate',
    'ModifyDate' => 'XMP-xmp:ModifyDate',
    'CreatorTool' => 'XMP-xmp:CreatorTool'
  }.freeze

  # Fields compared by name, i.e. dates, which exiftool re-renders in its own
  # format on the way out.
  DATE_SIDECAR_FIELDS = %w[CreateDate ModifyDate].freeze

  # Transport faults worth another attempt. Deliberately broad: a truncated
  # chunked body surfaces as Net::HTTPBadResponse or Net::ProtocolError, not as
  # a socket error, and missing those lost posts silently.
  NETWORK_ERRORS = [
    SocketError,
    IOError,
    EOFError,
    SystemCallError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Net::HTTPBadResponse,
    Net::ProtocolError,
    OpenSSL::SSL::SSLError,
    Zlib::BufError,
    Zlib::DataError
  ].freeze

  # Documented e621 responses that are worth another attempt. Everything else
  # is a hard failure and is surfaced immediately.
  RETRYABLE_STATUSES = [429, 500, 502, 503, 504, 520, 522, 524].freeze
  # e621 documents 503 as what you get for exceeding its rate limit, and 429 as
  # "sending requests too fast" -- so both mean the same thing here and both mean
  # the request never reached the application.
  RATE_LIMIT_STATUSES = [429, 503].freeze
  # Being over a site's limit is not a blip, it is a sustained condition, so it
  # backs off far harder than a transient 5xx instead of burning through the
  # retry budget and dropping the post.
  RATE_LIMIT_BACKOFF = [5, 20, 60].freeze
  # How the back-off escalates, and for how long each stage is held before the
  # pool returns to its configured rate:
  #   stage 1 -> 1 req/s per worker
  #   stage 2 -> 1 req/s across the whole run
  # A further refusal while a stage is already held steps up one level, so a run
  # still being throttled after a minute ends up sharing a single request per
  # second between every worker.
  RATE_LIMIT_STAGES = 2
  RATE_LIMIT_COOLDOWN = 60

  # The pool is read by the run loop and by tests, so it is exposed rather than
  # reached for through instance_variable_get.
  attr_reader :rate_limiter

  # Where a post's media and sidecar belong. A post in no pool has exactly one
  # location, posts/; a post in two pools has one per pool.
  Location = Struct.new(:directory, :pool_id) do
    def pooled?
      !pool_id.nil?
    end
  end

  # Uniform result for API searches. `posts` is nil on failure so a failed
  # request is never mistaken for an empty page. `payload` is the raw document
  # when one site caches more than the post list.
  ApiResult = Struct.new(:posts, :total, :error, :payload) do
    def ok?
      !posts.nil?
    end
  end

  attr_accessor :username, :api_key, :output_dir, :cache_dir, :tags_file, :credentials_file,
                :blacklist_file, :dry_run, :thread_count, :rate_limit,
                :rate_limiter, :blacklist, :existing_posts, :interrupted, :verbose,
                :notify_url, :user_id, :db, :pools_enabled, :repair_missing

  def initialize(username: nil, api_key: nil, user_id: nil, output_dir: nil,
                 cache_dir: nil, db_path: nil,
                 tags_file: './tags.txt', credentials_file: nil,
                 blacklist_file: './blacklist.txt', dry_run: false,
                 thread_count: 2, rate_limit: DEFAULT_REQUESTS_PER_SECOND, verbose: false,
                 interrupted: false, rate_limiter: nil, notify_url: nil,
                 recache_post_tags: false, pools: true, verify_md5: false,
                 cache_max_age: CACHE_MAX_AGE_DAYS, repair_missing: true)
    @username = username
    @api_key = api_key
    @user_id = user_id
    @output_dir = File.expand_path(output_dir || default_output_dir)
    @cache_dir = cache_dir ? File.expand_path(cache_dir) : File.join(@output_dir, 'cache')
    @db_path = db_path ? File.expand_path(db_path) : File.join(@output_dir, DB_BASENAME)
    @tags_file = tags_file
    @credentials_file = credentials_file
    @blacklist_file = blacklist_file
    @dry_run = dry_run
    @thread_count = thread_count
    @rate_limit = rate_limit
    @verbose = verbose
    @interrupted = interrupted
    @rate_limiter = rate_limiter
    @blacklist = nil
    @existing_posts = {}
    @existing_by_post = Hash.new { |hash, key| hash[key] = [] }
    @notify_url = notify_url
    @recache_post_tags = recache_post_tags
    @pools_enabled = pools
    @verify_md5 = verify_md5
    @cache_max_age = cache_max_age
    @repair_missing = repair_missing
    @repaired_sidecars = 0
    @integrity_faults = Hash.new(0)
    @sidecar_index = nil
    @lock_file = nil
    @pool_claims = Set.new
    @pool_claim_mutex = Mutex.new
    @pools_expanded = 0
    @pools_expanded_mutex = Mutex.new
    # The media index and the per-post reverse map are read by every worker and
    # written by whichever worker just placed a file, so they need a real lock.
    @existing_mutex = Monitor.new
    @db = ArchiveDb.new(@dry_run ? nil : @db_path, site: site_name, logger: Rubichiver::Logger)
  end

  # Each worker gets its own request budget, so the pool is sized to the worker
  # count rather than acting as one shared ceiling.
  def ensure_rate_limiter
    @rate_limiter ||= RateLimiterPool.new(requests_per_second: @rate_limit, threads: @thread_count,
                                          cooldown: RATE_LIMIT_COOLDOWN, stages: RATE_LIMIT_STAGES)
  end

  def blacklist
    @blacklist ||= Blacklist.new(@blacklist_file)
  end

  def default_output_dir
    raise NotImplementedError
  end

  def site_name
    raise NotImplementedError
  end

  # Gelbooru authenticates with a numeric user id in addition to the key.
  def requires_user_id?
    false
  end

  # Whether the site exposes collections that are bundled on discovery.
  def pools_supported?
    false
  end

  def pools_active?
    pools_supported? && @pools_enabled
  end

  # Whether a sidecar with no media beside it is re-fetched by id at startup.
  def repair_missing?
    @repair_missing
  end

  def run
    @username, @api_key, @user_id = load_credentials
    validate_credentials

    unless @dry_run
      FileUtils.mkdir_p(@output_dir) unless Dir.exist?(@output_dir)
      acquire_run_lock
    end

    ensure_rate_limiter
    blacklist
    @db.load unless @dry_run
    prune_stale_cache
    load_cached_tag_types
    migrate_loose_files_to_posts unless @dry_run
    scan_output_dir
    log_info "Found #{@existing_posts.size} existing files in output directory"
    check_archived_integrity
    reconcile_with_db
    build_sidecar_index unless @dry_run

    log_info "#{site_name} Archiver starting..."
    log_info "Output directory: #{@output_dir}", output_dir: @output_dir
    log_info "Tags file: #{@tags_file}", tags_file: @tags_file
    log_info "API username: #{@username}", username: @username
    log_info "Max retries: #{MAX_RETRIES}", max_retries: MAX_RETRIES
    log_info "Worker threads: #{@thread_count}", threads: @thread_count
    log_info "Pool bundling: #{pools_active? ? 'enabled' : 'disabled'}", pools: pools_active?
    log_info "Blacklist: #{@blacklist_file}" if @blacklist&.any?
    log_info "Archive database: #{@db.path} (#{@db.persistent? ? @db.inspect : 'not persistent'})" if @db.enabled?
    log_info ""

    # Once every startup step that can abort the run has already succeeded, so
    # this only ever fires for a run that is genuinely about to work.
    notify_start

    begin
      collect_and_process
    ensure
      flush_tag_types
      @db.close
    end
  end

  def collect_and_process
    start_time = Time.now
    stats = Stats.new
    processor = PostProcessor.new(
      rate_limiter: @rate_limiter,
      output_dir: @output_dir,
      stats: stats,
      thread_count: @thread_count,
      dry_run: @dry_run,
      archiver: self
    )

    watchdog = start_stall_watchdog(processor)

    if @recache_post_tags
      log_info "Recache mode — refreshing stored metadata for all existing posts"
      recache_all_post_tags
    else
      unless File.exist?(@tags_file)
        log_error "Cannot open tags file", tags_file: @tags_file
        exit 1
      end

      log_info "Dry run mode — discovering posts that would be archived" if @dry_run

      repair_sidecars_from_db(stats)
      repair_missing_media(processor, stats)
      process_tag_queries(processor, stats)
    end

    processor.finish
    processor.wait
    stop_stall_watchdog(watchdog)

    log_warn "Interrupted — partial results below" if @interrupted

    elapsed = Time.now - start_time
    report = build_report(stats, elapsed)
    print_summary(stats, elapsed, report)
    notify(report)

    exit(@interrupted || stats.failed_files > 0 ? 1 : 0)
  end

  # Records progress as it happens and warns when it stops. The most expensive
  # thing this tool does — walking the archive, reading and rewriting tens of
  # thousands of sidecars — can block on the disk for a very long time with no
  # output, and there is no other way to tell that apart from a hang.
  def start_stall_watchdog(processor = nil)
    reset_progress
    Thread.new do
      loop do
        sleep 30
        check_for_stall(Process.clock_gettime(Process::CLOCK_MONOTONIC), processor)
      end
    end
  end

  def reset_progress
    @progress_count = 0
    @progress_mutex = Mutex.new
    @progress_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Separated from the polling thread so it can be exercised directly.
  def check_for_stall(now = Process.clock_gettime(Process::CLOCK_MONOTONIC), processor = nil)
    return nil unless @progress_mutex

    # A run whose only remaining work is timed download retries is intentionally
    # idle. Reporting that as a wedged disk would be a false alarm. Still warn
    # when a worker is active but stopped making progress.
    if processor&.waiting_for_download_retry?
      @progress_mutex.synchronize { @progress_at = now }
      return nil
    end

    idle = @progress_mutex.synchronize do
      [now - @progress_at, @progress_count]
    end
    seconds, done = idle
    return nil if seconds < STALL_WARN_SECONDS

    log_warn "No progress for #{format('%.0f', seconds / 60)} minutes (#{done} items done); " \
             'still running, but this is a disk stall — check the drive',
             idle_minutes: (seconds / 60).round(1), done: done, api: true
    @progress_mutex.synchronize { @progress_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    seconds
  end

  def note_progress
    return unless defined?(@progress_mutex) && @progress_mutex

    @progress_mutex.synchronize do
      @progress_count += 1
      @progress_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  def stop_stall_watchdog(watchdog)
    watchdog&.kill
  end

  def print_summary(stats, elapsed, report)
    total_requests = @rate_limiter.request_count
    requests_per_sec = total_requests / elapsed if elapsed.positive?

    logger.separator
    logger.info 'SUMMARY'
    logger.separator
    logger.info "Total posts processed: #{stats.total_posts}", total_posts: stats.total_posts
    logger.info "Files downloaded: #{stats.downloaded_files}", downloaded: stats.downloaded_files
    if stats.reused_files > 0
      logger.info "Files placed from existing copies: #{stats.reused_files}", reused: stats.reused_files
    end
    if stats.autotagged_files > 0
      logger.info "Existing files auto-tagged: #{stats.autotagged_files}", autotagged: stats.autotagged_files
    end
    logger.info "Files skipped (already exist): #{stats.skipped_files}", skipped: stats.skipped_files
    logger.info "Files failed: #{stats.failed_files}", failed: stats.failed_files
    if stats.blacklisted_files > 0
      logger.info "Files blacklisted: #{stats.blacklisted_files}", blacklisted: stats.blacklisted_files
    end
    if report[:sidecars_repaired].positive?
      logger.info "Sidecars regenerated: #{report[:sidecars_repaired]}",
                  sidecars_repaired: report[:sidecars_repaired]
    end
    if report[:pools_expanded].positive?
      logger.info "Pools bundled: #{report[:pools_expanded]}", pools: report[:pools_expanded]
    end
    if report[:integrity_faults].positive?
      logger.info "Damaged files re-queued for download: #{report[:integrity_faults]}",
                  integrity_faults: report[:integrity_faults]
    end
    if report[:preserved_files].positive?
      logger.info "Edited files left alone: #{report[:preserved_files]}",
                  preserved_files: report[:preserved_files]
    end
    if @db.enabled? && @db.persistent?
      logger.info "Posts in archive db: #{@db.post_count} (#{@db.tag_count} tags)",
                  db_posts: @db.post_count, db_tags: @db.tag_count
    end
    logger.info "DRY RUN — preview mode", dry_run: true if @dry_run
    logger.info "Throttled requests (API + downloads): #{total_requests}", request_count: total_requests
    logger.info "Time elapsed: #{format('%.2f', elapsed)}s", elapsed_seconds: elapsed.round(2)
    if requests_per_sec
      logger.info "Requests per second: #{format('%.2f', requests_per_sec)}", requests_per_sec: requests_per_sec.round(2)
    end
    logger.separator
  end

  def build_report(stats, elapsed)
    {
      event: "rubichiver.#{site_name}.run-complete",
      success: stats.failed_files.zero? && !@interrupted,
      interrupted: @interrupted,
      dry_run: @dry_run,
      output_dir: @output_dir,
      total_posts: stats.total_posts,
      downloaded: stats.downloaded_files,
      reused: stats.reused_files,
      autotagged: stats.autotagged_files,
      skipped: stats.skipped_files,
      failed: stats.failed_files,
      blacklisted: stats.blacklisted_files,
      pools_expanded: pools_expanded_count,
      sidecars_repaired: @repaired_sidecars,
      integrity_faults: integrity_fault_count,
      preserved_files: preserved_file_count,
      posts_recorded: @db.enabled? ? @db.post_count : nil,
      elapsed_seconds: elapsed.round(2),
      db: @db.enabled? ? @db.path : nil,
      timestamp: Time.now.utc.iso8601
    }
  end

  def pools_expanded_count
    @pools_expanded_mutex.synchronize { @pools_expanded }
  end

  def install_signal_handlers
    trap('INT') { request_shutdown('INT', 'Ctrl+C') }
    trap('TERM') { request_shutdown('TERM', 'a TERM signal') }
  end

  # First signal asks the workers to drain, second one gives up on them.
  def request_shutdown(signal, trigger)
    if @interrupted
      $stderr.puts "[Interrupt] Force exiting..."
      trap(signal, 'DEFAULT')
      Process.kill(signal, Process.pid)
    else
      @interrupted = true
      $stderr.puts "[Interrupt] Graceful shutdown initiated by #{trigger}, " \
                   'finishing in-progress work... (repeat to force exit)'
    end
  end

  def load_credentials_from_file
    raise NotImplementedError
  end

  def load_credentials
    return [@username, @api_key, @user_id] unless credentials_file_present?

    load_credentials_from_file
  end

  def credentials_file_present?
    !@credentials_file.nil? && File.exist?(@credentials_file)
  end

  def validate_credentials
    missing = []
    missing << 'API_KEY' if @api_key.nil?
    missing << 'USER_ID' if @user_id.nil? && requires_user_id?
    missing << 'USERNAME' if @username.nil? && !requires_user_id?
    return if missing.empty?

    if credentials_file_present?
      log_fatal "Incomplete API credentials (missing: #{missing.join(', ')})", credentials_file: @credentials_file
    else
      log_fatal "API credentials file not found", credentials_file: @credentials_file
    end
    exit 1
  end

  def process_tag_queries(processor, stats)
    queries = []
    File.foreach(@tags_file) do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')
      queries << line.split
    end

    if queries.empty?
      log_warn "No tag queries found in tags file", tags_file: @tags_file
      return
    end

    seen_ids = Set.new
    queries.each do |query_tags|
      break if @interrupted
      posts = fetch_all_posts_for_query(query_tags, seen_ids, stats)
      posts.each do |post|
        record_post_metadata(post)
        processor.enqueue(post)
        note_progress
      end
    end
  end

  # Refreshes the cached tag/rating data for posts that are already on disk,
  # without downloading anything. Subclasses supply the fetch primitive because
  # the two sites expose no common way of addressing posts by id.
  def recache_all_post_tags
    post_ids = existing_post_ids
    if post_ids.empty?
      log_info "No media files found in output directory"
      return
    end

    batch_size = recache_batch_size
    total_batches = (post_ids.size.to_f / batch_size).ceil
    log_info "Found #{post_ids.size} unique posts to recache", posts: post_ids.size, batches: total_batches

    if batch_size == 1
      log_warn "#{site_name} has no bulk post lookup — recaching costs one request per post " \
               "(~#{(post_ids.size / @rate_limit.to_f).ceil / 60} min at #{@rate_limit}/s)"
    end

    post_ids.each_slice(batch_size).with_index do |batch, idx|
      break if @interrupted

      log_info "Recache batch #{idx + 1}/#{total_batches} (#{batch.size} IDs)",
               batch: idx + 1, total_batches: total_batches, api: true

      result = fetch_posts_by_ids(batch)
      next unless result.ok?

      result.posts.each do |post|
        break if @interrupted
        record_post_metadata(post, refresh: true)
        repair_sidecar(post)
        note_progress
      end
    end

    log_info "Recache complete for #{post_ids.size} posts"
  end

  # A recache is the one pass that visits every archived post, so it is the
  # natural place to put a missing or drifted sidecar right. Without this, a
  # post whose sidecar was lost keeps no metadata at all until some tag query
  # happens to return it again.
  def repair_sidecar(post)
    return if @dry_run

    post_locations(post).each do |location|
      media = existing_media(post['id'], location)
      next unless media
      next if sidecar_valid?(post, location)

      log_info "Regenerating missing or stale sidecar for post #{post['id']} in #{relative_directory(location.directory)}",
               post_id: post['id'], directory: relative_directory(location.directory)
      result = write_sidecar(media, post)
      next unless result == true

      record_sidecar_written(post, location, media)
      @repaired_sidecars += 1
    end
  end

  def recache_batch_size
    RECACHE_BATCH_SIZE
  end

  def fetch_posts_by_ids(_ids)
    raise NotImplementedError
  end

  def notify(report)
    title = report[:success] ? "#{site_name} run finished" : "#{site_name} run finished with failures"
    message = report_summary(report)
    notify_event(
      title,
      message,
      priority: report[:success] ? 3 : 5,
      tags: report[:success] ? ['white_check_mark'] : ['rotating_light']
    )
  end

  # An ad-hoc alert, e.g. the run being throttled mid-flight. Silent without
  # this: the only other notification is the end-of-run report, hours away.
  def notify_event(title, message, priority: 4, tags: [])
    return unless @notify_url

    post_notification(notification_body(title, message, priority, tags))
  rescue StandardError => e
    log_warn "Alert notification failed: #{e.message}", api: true
  end

  # The run is under way. Its purpose is to bound the silence: the work that
  # follows is measured in hours, and the only other notification is the
  # end-of-run report. A start with no matching report means the run died part
  # way, which is otherwise indistinguishable from a slow one.
  def notify_start
    notify_event(
      "#{site_name} #{run_mode_label} starting",
      run_start_summary,
      priority: 3,
      tags: [run_mode_tag]
    )
  end

  def notification_body(title, message, priority, tags)
    uri = URI(@notify_url)
    # ntfy takes the topic from the URL path and the rest as a JSON body; a bare
    # JSON report would arrive with no message at all.
    return { 'topic' => topic_from(uri), 'title' => title, 'message' => message,
             'priority' => priority, 'tags' => tags } if ntfy?(uri)

    { 'event' => "rubichiver.#{site_name}.alert", 'title' => title, 'message' => message,
      'priority' => priority, 'tags' => tags, 'timestamp' => Time.now.utc.iso8601 }
  end

  def ntfy?(uri)
    uri.host.to_s.downcase.include?('ntfy')
  end

  def topic_from(uri)
    uri.path.to_s.sub(%r{\A/}, '')
  end

  def run_mode_label
    return 'recache' if @recache_post_tags
    return 'dry run' if @dry_run

    'archive'
  end

  def run_mode_tag
    return 'arrows_counterclockwise' if @recache_post_tags
    return 'test_tube' if @dry_run

    'rocket'
  end

  # Counters and settings only, for the same reason the end-of-run report is:
  # nothing that identifies the archive or its contents leaves the machine.
  def run_start_summary
    [
      "mode: #{run_mode_label}  workers: #{@thread_count}  " \
      "rate limit: #{@rate_limit}/s per worker",
      "pools: #{pools_active? ? 'bundled' : 'disabled'}  " \
      "repair missing: #{repair_missing? ? 'on' : 'off'}",
      "archive holds #{@existing_posts.size} existing file(s)"
    ].join("\n")
  end

  def report_summary(report)
    [
      "posts: #{report[:total_posts]}  downloaded: #{report[:downloaded]}  " \
      "skipped: #{report[:skipped]}  failed: #{report[:failed]}",
      "blacklisted: #{report[:blacklisted]}  reused: #{report[:reused]}  " \
      "sidecars repaired: #{report[:sidecars_repaired]}",
      "elapsed: #{report[:elapsed_seconds]}s#{report[:interrupted] ? '  (interrupted)' : ''}"
    ].join("\n")
  end

  def post_notification(payload)
    uri = notification_target
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = OPEN_TIMEOUT

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['User-Agent'] = user_agent
    apply_notification_auth(request)
    request.body = JSON.generate(payload)

    response = http.request(request)
    return if response.is_a?(Net::HTTPSuccess)

    log_warn "Alert notification failed", status: response&.code, api: true
  rescue *NETWORK_ERRORS => e
    log_warn "Alert notification failed: #{e.message}", api: true
  end

  # Credentials ride in the notify URL as standard userinfo
  # (https://user:pass@host/topic), which is the only auth ntfy needs and needs
  # no extra flag or option surface. Read off @notify_url rather than the
  # request target, because notification_target drops the userinfo along with
  # the topic. Nothing here logs the password.
  def apply_notification_auth(request)
    uri = URI(@notify_url)
    return if uri.user.nil? || uri.password.nil?

    request.basic_auth(uri.user, URI.decode_www_form_component(uri.password))
  rescue StandardError => e
    log_warn "Notify URL credentials unreadable: #{e.message}", api: true
  end

  # ntfy only parses title/message/priority/tags from a JSON body when the topic
  # travels in that body, which means posting to the server root. Posting the
  # same JSON to the topic URL arrives as one long raw string, which is worse
  # than no alert at all: it looks delivered and reads as noise.
  def notification_target
    uri = URI(@notify_url)
    return uri unless ntfy?(uri)

    URI("#{uri.scheme}://#{uri.host}:#{uri.port}/")
  end

  # --- Locations ------------------------------------------------------------

  # Where this post's files belong. A post pulled in by a pool is pinned to
  # that pool so bundling cannot cascade into the pools its members happen to
  # belong to.
  def post_locations(post)
    pool_id = post[POOL_MEMBER]
    return [root_location] if pool_id.nil?

    [Location.new(pool_directory(pool_id), pool_id)]
  end

  def posts_directory
    File.join(@output_dir, POSTS_DIR)
  end

  def root_location
    Location.new(posts_directory, nil)
  end

  def relative_directory(directory)
    root = File.expand_path(@output_dir)
    path = File.expand_path(directory)
    return '.' if path == root

    path.delete_prefix("#{root}/")
  end

  def existing_key(post_id, location)
    "#{post_id}|#{location.pool_id || 0}|#{relative_directory(location.directory)}"
  end

  def existing_media(post_id, location)
    @existing_mutex.synchronize { @existing_posts[existing_key(post_id, location)] }
  end

  def existing_post_ids
    @existing_mutex.synchronize { @existing_by_post.keys.sort }
  end

  # Puts a copy of bytes this post already has elsewhere in the archive at the
  # target path, so a post shared by several pools is downloaded once. Links
  # when the filesystem allows it, copies when it does not.
  # Returns the path placed, and the MD5 the source was recorded with, so a
  # placed copy stays verifiable under --verify-md5. Hard links share the
  # source's bytes, so re-hashing the target is pointless anyway.
  def place_existing_media(post_id, location, ext)
    source = reusable_source_for(post_id, location, ext)
    return nil unless source

    target = File.join(location.directory, "#{post_id}.#{ext}")
    return target if File.exist?(target)

    begin
      File.link(source, target)
    rescue NotImplementedError, SystemCallError
      begin
        FileUtils.copy_file(source, target)
      rescue SystemCallError, IOError => e
        log_warn "Could not place post #{post_id} from #{source}: #{e.message}", post_id: post_id
        return nil
      end
    end

    target
  end

  def reusable_source_for(post_id, location, ext)
    candidates = @existing_mutex.synchronize { (@existing_by_post[post_id] || []).filter_map { |key| @existing_posts[key] } }
    candidates.reject! { |path| File.dirname(path) == location.directory }
    candidates.find { |path| File.extname(path).delete('.') == ext.to_s } ||
      candidates.find { |path| File.file?(path) }
  end



  def remember_existing(post_id, location, path)
    index_existing(post_id, location, path)
  end

  # --- Pools ----------------------------------------------------------------

  def pool_directory(_pool_id)
    raise NotImplementedError
  end

  # Expands every pool this post belongs to, handing each sibling to the given
  # block. Expanding is claimed per pool so concurrent workers do not fetch the
  # same bundle twice.
  def expand_pools(post, thread_idx: nil)
    return unless pools_active?
    return if post[POOL_MEMBER]

    post_pool_ids(post).each do |pool_id|
      next unless claim_pool(pool_id)

      bundle_pool(pool_id, thread_idx: thread_idx) { |sibling| yield sibling }
    end
  end

  def claim_pool(pool_id)
    @pool_claim_mutex.synchronize { @pool_claims.add?(pool_id) ? true : false }
  end

  def post_pool_ids(_post)
    []
  end

  # --- HTTP -----------------------------------------------------------------

  # Overridable so the end-to-end tests can drive the real CLI against a local
  # server instead of a live site.
  def api_base
    raise NotImplementedError
  end

  def user_agent
    "rubichiver/#{Rubichiver::VERSION} (#{site_name} archiver)"
  end

  # Headers every request to this site should carry.
  def request_headers
    {}
  end

  # GET with redirect following. When a block is given it receives the response
  # and returns true once it has consumed the body, or false to have the body
  # discarded (redirects). Without a block the response is returned unread.
  #
  # Credentials are only ever sent to the host they were minted for. Replaying
  # an Authorization header across a redirect hands the API key to whatever
  # host the response names.
  def http_get(uri, read_timeout: API_READ_TIMEOUT, headers: {}, &body_handler)
    redirects = 0
    origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"

    loop do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = read_timeout

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = user_agent
      request['Accept-Encoding'] = 'identity'
      this_host = origin == "#{uri.scheme}://#{uri.host}:#{uri.port}"
      (this_host ? request_headers.merge(headers) : {}).each { |key, value| request[key] = value }

      consumed = false
      response = if body_handler
                   http.request(request) do |res|
                     consumed = body_handler.call(res) ? true : false
                     consumed
                   end
                 else
                   http.request(request)
                 end

      drain(response) if body_handler && !consumed

      if response.is_a?(Net::HTTPRedirection) && redirects < MAX_REDIRECTS
        location = response['location']
        break unless location

        begin
          uri = URI.join(uri, location)
        rescue URI::Error => e
          # A malformed Location must not abort the run; the caller sees the
          # redirect itself and reports it as a failed request.
          log_warn "Ignoring malformed redirect target: #{location[0, 120]}", error: e.message, api: true
          break
        end
        redirects += 1
        next
      end

      return response
    end
  end

  # Throttled GET with bounded exponential backoff. Returns the response as
  # soon as a non-retryable status arrives, or nil when every attempt failed.
  #
  # @param thread_idx [Integer, nil] the worker making the request, so it spends
  #   its own budget rather than contending for a shared one.
  def api_get(uri, context, read_timeout: API_READ_TIMEOUT, headers: {}, thread_idx: nil)
    ensure_rate_limiter
    retries = 0

    while retries < MAX_RETRIES
      return nil if @interrupted

      @rate_limiter.throttle!(thread_idx)
      response = begin
        http_get(uri, read_timeout: read_timeout, headers: headers)
      rescue *NETWORK_ERRORS => e
        log_warn "API request error (attempt #{retries + 1}/#{MAX_RETRIES})",
                 error: e.message, tags: context[:tags], page: context[:page], api: true
        nil
      rescue StandardError => e
        # A URI that will not parse, a TLS library disagreement, anything the
        # retry list did not anticipate. An API hiccup must never take the run
        # down with it.
        log_warn "API request failed (attempt #{retries + 1}/#{MAX_RETRIES})",
                 error: "#{e.class}: #{e.message}", tags: context[:tags], page: context[:page], api: true
        nil
      end

      return response if response && !RETRYABLE_STATUSES.include?(response.code.to_i)

      throttled = response && RATE_LIMIT_STATUSES.include?(response.code.to_i)
      if throttled
        register_rate_limited!
      elsif response
        log_warn "API returned #{response.code}, retrying...",
                 tags: context[:tags], page: context[:page], status: response.code, api: true
      end

      retries += 1
      delay = throttled ? rate_limit_delay(retries) : retry_delay(retries)
      sleep(delay) if retries < MAX_RETRIES
      return nil if @interrupted
    end

    nil
  end

  # Streams url to output_file, verifying MD5 when the site supplies one.
  # Partial downloads live in a .part file and are always cleaned up, so an
  # interrupted run never leaves something that looks like a finished file.
  def download_media(url, output_file, post_id, expected_md5, thread_idx: nil)
    ensure_rate_limiter
    tmp_file = "#{output_file}#{PART_SUFFIX}"
    retries = 0

    while retries < MAX_RETRIES
      break if @interrupted

      @rate_limiter.throttle!(thread_idx)
      digest = Digest::MD5.new
      status = nil
      written = false

      begin
        http_get(URI(url), read_timeout: DOWNLOAD_READ_TIMEOUT) do |res|
          status = res.code
          next false unless res.is_a?(Net::HTTPSuccess)

          File.open(tmp_file, 'wb') do |f|
            res.read_body { |chunk| f.write(chunk); digest.update(chunk) }
          end
          written = true
        end
      rescue *NETWORK_ERRORS => e
        # Truncated bodies arrive as Net::HTTPBadResponse/Net::ProtocolError and
        # are the commonest failure of all; they must cost a retry, not the post.
        log_warn "Network error downloading post #{post_id} (attempt #{retries + 1}/#{MAX_RETRIES}): #{e.message}",
                 post_id: post_id, thread: thread_idx, api: true
        written = false
      rescue StandardError => e
        log_warn "Download of post #{post_id} failed (attempt #{retries + 1}/#{MAX_RETRIES}): #{e.class}: #{e.message}",
                 post_id: post_id, thread: thread_idx, api: true
        written = false
      end

      if written
        if expected_md5.nil? || expected_md5.to_s.empty?
          File.rename(tmp_file, output_file)
          # The digest was computed over the bytes as they streamed past, so it
          # costs nothing to keep. Without it a container variant would be
          # recorded with no digest at all and stay permanently outside
          # --verify-md5, one more unverified file on every run.
          remember_downloaded_digest(output_file, digest.hexdigest)
          log_debug "Post #{post_id}: no MD5 to verify against", post_id: post_id, thread: thread_idx, api: true
          return true
        end

        if digest.hexdigest == expected_md5
          File.rename(tmp_file, output_file)
          return true
        end

        log_error "MD5 mismatch for post #{post_id} (expected #{expected_md5}, got #{digest.hexdigest})",
                  post_id: post_id, thread: thread_idx, api: true
      else
        # A 200 only means the headers arrived. A broken TLS connection or a
        # truncated body can still fail the transfer after that point; calling
        # this an "HTTP 200 failure" hides the actual transport fault above.
        reason = status.to_i == 200 ? 'response body incomplete' : "HTTP #{status}"
        log_warn "Download failed for post #{post_id} (#{reason})",
                 post_id: post_id, status: status, thread: thread_idx, api: true
      end

      File.delete(tmp_file) if File.exist?(tmp_file)
      retries += 1
      if retries < MAX_RETRIES
        throttled = RATE_LIMIT_STATUSES.include?(status.to_i)
        register_rate_limited! if throttled
        delay = throttled ? rate_limit_delay(retries) : retry_delay(retries)
        log_debug "Retrying post #{post_id} in #{format('%.1f', delay)}s...",
                  post_id: post_id, retry_count: retries, thread: thread_idx, api: true
        sleep(delay)
        break if @interrupted
      end
    end

    File.delete(tmp_file) if File.exist?(tmp_file)
    false
  end

  def retry_delay(retries)
    RETRY_BACKOFF * (2**retries) + rand * 0.5
  end

  # Backoff for a request the site refused because it was going too fast.
  def rate_limit_delay(retries)
    RATE_LIMIT_BACKOFF[[retries, RATE_LIMIT_BACKOFF.size - 1].min]
  end

  # Answers a refusal: step the pool down one stage, hold it for a minute, and
  # say so. A site saying "slow down" should not need anyone watching, so the
  # pool recovers by itself once the window passes.
  def register_rate_limited!
    stage, escalated = @rate_limiter.note_refusal

    # A refused request is retried several times over, so only a real change of
    # stage is worth a line in the log and an alert -- otherwise one unlucky
    # request pages you several times over.
    unless escalated
      log_debug "Still rate limited; holding #{rate_limit_stage_label(stage)}",
                stage: stage, api: true
      return stage
    end

    log_warn "#{site_name} is rate limiting this run (HTTP 429/503). Slowing to " \
             "#{rate_limit_stage_label(stage)} for #{RATE_LIMIT_COOLDOWN}s, then resuming " \
             "#{@rate_limit}/s per worker.",
             stage: stage, rate_limit: "#{@rate_limit}/s per thread x #{@thread_count} threads", api: true
    notify_event(
      "#{site_name} rate limited — slowed to #{rate_limit_stage_label(stage)}",
      "The site refused a request with 429/503. Requests are being rejected, not just " \
      "delayed, so posts will fail once their retries run out.\n\n" \
      "Now running at #{rate_limit_stage_label(stage)} for #{RATE_LIMIT_COOLDOWN}s (was " \
      "#{@rate_limit}/s per worker x #{@thread_count} threads). e621 documents 2 req/s " \
      "TOTAL and asks for 1/s sustained; consider lowering --rate-limit or --threads " \
      "in the service unit.",
      priority: 5,
      tags: ['warning']
    )
    stage
  end

  def rate_limit_stage_label(stage)
    stage >= 2 ? '1 req/s in total' : '1 req/s per worker'
  end

  def drain(response)
    response.read_body { |_chunk| }
  rescue IOError, Net::ProtocolError
    nil
  end

  # --- API ------------------------------------------------------------------

  # cache: false is used by one-shot lookups (recache, pool bundling) that
  # would otherwise leave thousands of single-use entries behind.
  def api_search_posts(_tags, _page, force: false, cache: true, thread_idx: nil)
    raise NotImplementedError
  end

  def fetch_all_posts_for_query(_query_tags, _seen_ids, _stats)
    raise NotImplementedError
  end

  def post_file_url(_post)
    raise NotImplementedError
  end

  def post_file_ext(_post)
    raise NotImplementedError
  end

  def post_md5(_post)
    raise NotImplementedError
  end

  def resolve_served_extension(_post, orig_ext, _file_url)
    orig_ext
  end

  def extract_post_tags(_post)
    raise NotImplementedError
  end

  # Tags grouped by category, for the archive database. A site that answers with
  # a flat tag list has no categories to give, so those land under 'general' —
  # which is what a queryable store can honestly offer, and deliberately not
  # what the sidecar keywords use (see extract_post_tags).
  def categorized_post_tags(_post)
    raise NotImplementedError
  end

  def post_tag_names(_post)
    []
  end

  # Everything the site reported for a post, flattened into the columns the
  # archive database stores. Subclasses fill in what their API offers, so the
  # captured detail is as complete as each site makes it.
  def post_metadata(post)
    {
      post_id: post['id'],
      rating: post['rating'],
      created_at: post_timestamp(post, 'created_at'),
      updated_at: post_timestamp(post, 'updated_at'),
      md5: post_md5(post),
      ext: post_file_ext(post),
      page_url: post_page_url(post),
      description: post_description(post),
      tags: categorized_post_tags(post),
      sources: post_sources(post)
    }
  end

  # Persists the full post detail. Called once per post at discovery, on the
  # main thread, so the download workers only ever touch the file table.
  def record_post_metadata(post, refresh: false)
    return unless @db.enabled?

    @db.record_post(refresh: refresh, **post_metadata(post))
  rescue SQLite3::Exception, SystemCallError, IOError => e
    log_warn "Could not record metadata for post #{post['id']}: #{e.message}", post_id: post['id'], db: true
  end

  # Rebuilds a post-shaped hash from the stored record alone, so a sidecar can
  # be regenerated without asking the site. The hash uses the same shape the
  # site's API produces, so sidecar_payload and its validators work unchanged.
  # Returns nil when there is no stored record, or when the stored tags came
  # from a flat list and guessing keyword categories off them would be wrong.
  def stored_post(post_id)
    return nil unless @db.enabled?

    record = @db.post(post_id)
    return nil unless record
    # SQLite stores the flag as 0/1, and in Ruby 0 is truthy, so this has to be
    # numeric rather than a bare predicate.
    return nil if record['uncategorized'].to_i == 1

    build_stored_post(record, @db.post_tags(post_id), @db.sources(post_id))
  end

  # Subclasses assemble the same shape their API response would have, from the
  # stored record, its categorized tags and its sources.
  def build_stored_post(_record, _categories, _sources)
    raise NotImplementedError
  end

  # Rebuilds, from the stored record alone, every sidecar that is missing or no
  # longer says what the archive knows about the post. No API call is made, so
  # this is also how a killed run's half-written pair completes itself without
  # refetching anything, and how sidecars written in an older format get
  # migrated.
  #
  # "No longer says" matters as much as "missing": an earlier version wrote
  # keywords only, and those files still exist. Nothing else would ever revisit
  # them, because a post is only re-fetched when a tag query happens to return
  # it, and a post outside every query would keep its short sidecar forever.
  def repair_sidecars_from_db(stats)
    return unless @db.enabled?
    return if @dry_run

    missing = @db.files.select { |record| sidecar_needs_rebuild?(record) }
    return if missing.empty?

    log_info "#{missing.size} archived file(s) have a missing or outdated sidecar; " \
             'rebuilding from the stored record',
             count: missing.size
    missing.each do |record|
      post = stored_post(record['post'])
      next unless post

      location = location_of(record)
      path = @existing_posts[existing_key(record['post'], location)]
      next unless path && File.file?(path)

      result = write_sidecar(path, post)
      next unless result == true

      record_sidecar_written(post, location, path)
      stats.increment(:autotagged_files)
    end
  end

  # True when the sidecar is absent, or disagrees with the stored record. The
  # comparison is against the database rather than the live site, so a post the
  # queries never reach still converges; one the queries do reach is re-checked
  # against the site during the run and corrected if the stored copy has since
  # fallen behind.
  def sidecar_needs_rebuild?(record)
    location = location_of(record)
    return true unless record['sidecar']
    return true unless File.exist?(sidecar_path(record['post'], location))

    post = stored_post(record['post'])
    # Nothing stored to rebuild from: leave it alone rather than guessing.
    return false unless post

    !sidecar_valid?(post, location)
  end

  def rating_value(_rating)
    raise NotImplementedError
  end

  def rating_label(_post)
    raise NotImplementedError
  end

  def blacklisted_post?(post)
    return false unless blacklist.any?

    blacklist.blacklisted?(post_tag_names(post), post['rating'], post['id'])
  end

  # --- Caches ---------------------------------------------------------------

  def caching_enabled?
    !@dry_run
  end

  def api_cache_path(query_hash, page)
    File.join(@cache_dir, "api_posts_#{query_hash}_p#{page}.json")
  end

  def read_api_cache(path)
    return nil unless File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError, SystemCallError, IOError => e
    log_warn "Discarding unreadable API cache entry", file: File.basename(path), error: e.message, api: true
    nil
  end

  def write_api_cache(path, payload)
    return unless caching_enabled?

    FileUtils.mkdir_p(@cache_dir)
    File.write(path, JSON.pretty_generate(payload))
  end

  # The per-post tag cache that used to live here is gone: the archive database
  # now holds tags durably and queryably, and a sidecar is validated against the
  # post the API just returned rather than against a stale file on disk. That
  # removed both the growth (one small file per post, forever) and the class of
  # bug where a stale cache made a drifted sidecar look correct.

  # Drops cached API pages that have not been touched in CACHE_MAX_AGE_DAYS, so
  # a long-lived archive does not accumulate pages for queries that no longer
  # run. Age rather than reachability: a page for a query that is temporarily
  # absent from tags.txt is still worth keeping.
  def prune_stale_cache
    return if @dry_run || @cache_max_age.to_i <= 0 || !Dir.exist?(@cache_dir)

    cutoff = Time.now - (@cache_max_age * 86_400)
    removed = 0
    Dir.glob(File.join(@cache_dir, 'api_posts_*.json')).each do |file|
      mtime = File.mtime(file)
      next if mtime >= cutoff

      File.delete(file)
      removed += 1
    rescue SystemCallError => e
      log_debug "Could not prune #{File.basename(file)}: #{e.message}"
    end
    return if removed.zero?

    log_info "Pruned #{removed} API cache page(s) older than #{@cache_max_age} days",
             pruned: removed, max_age_days: @cache_max_age
  end

  # Restores persisted tag category lookups, so a run does not re-ask the tag API
  # about every tag it has ever seen.
  def load_cached_tag_types
    return unless @db.enabled?

    cached = @db.tag_types
    return if cached.empty?

    prime_tag_types(cached)
  end

  # Subclasses that resolve tag categories override these.
  def prime_tag_types(_cached)
    nil
  end

  def flush_tag_types
    nil
  end

  # --- Output directory -----------------------------------------------------

  # Moves loose posts left at the archive root by an older layout into posts/,
  # and points their database rows at the new location. Runs before the scan,
  # so the rest of the run only ever sees the new layout. Skipped on a dry run
  # like every other write.
  def migrate_loose_files_to_posts
    return unless Dir.exist?(@output_dir)

    loose = Dir.children(@output_dir).select do |name|
      next false if name.start_with?('.')

      source = File.join(@output_dir, name)
      File.file?(source) && name.match?(/\A\d+\./)
    end
    return if loose.empty?

    FileUtils.mkdir_p(posts_directory)
    moved = 0
    loose.each do |name|
      source = File.join(@output_dir, name)
      target = File.join(posts_directory, name)
      if File.exist?(target)
        if File.size(target) == File.size(source)
          File.delete(source)
          moved += 1
        else
          log_warn "Not migrating #{name}: a different file already exists in #{POSTS_DIR}/",
                   file: name, api: false
        end
        next
      end

      FileUtils.mv(source, target)
      moved += 1
    end

    relocated = @db.enabled? ? @db.relocate_root_files(POSTS_DIR) : 0
    log_info "Moved #{moved} loose file(s) into #{POSTS_DIR}/ (#{relocated} database row(s) updated)",
             moved: moved, relocated: relocated if moved.positive? || relocated.positive?
  rescue SystemCallError, IOError => e
    log_warn "Could not migrate loose files into #{POSTS_DIR}/: #{e.message}"
  end

  # Indexes media already on disk, including inside collection directories.
  # Incomplete .part files from a killed run are deleted rather than indexed:
  # treating one as a finished download would skip the re-download and hang a
  # sidecar off a truncated file.
  def scan_output_dir
    @existing_mutex.synchronize do
      @existing_posts = {}
      @existing_by_post = Hash.new { |hash, key| hash[key] = [] }
    end

    scan_directory(posts_directory, root_location)
    collection_directories.each do |directory|
      scan_directory(directory, Location.new(directory, pool_id_for_directory(directory)))
    end

    @existing_posts
  end

  def scan_directory(directory, location)
    return unless Dir.exist?(directory)

    Dir.children(directory).each do |file|
      next if file.start_with?('.')

      full = File.join(directory, file)

      if file.end_with?(*TEMP_SUFFIXES) || file.match?(SIDECAR_TMP_PATTERN)
        File.delete(full) if File.file?(full) && !@dry_run
        next
      end

      # Bytes the integrity check set aside. They are not the archived file, so
      # indexing them would make a damaged post look downloaded.
      next if file.match?(DAMAGED_PATTERN)

      # A sidecar on its own is not a download. Indexing it as media would make
      # a post whose file was deleted look archived, and the media would never
      # be fetched again.
      next if file.end_with?(SIDECAR_SUFFIX)

      next unless File.file?(full)
      next unless file =~ /\A(\d+)\./

      index_existing($1.to_i, location, full)
    end
  end

  # Single entry point for the media index. Every mutation goes through here
  # because workers add to it while other workers are reading it.
  def index_existing(post_id, location, path)
    key = existing_key(post_id, location)
    @existing_mutex.synchronize do
      @existing_posts[key] = path
      @existing_by_post[post_id] << key unless @existing_by_post[post_id].include?(key)
    end
  end

  # Directories that hold collection bundles, searched one or two levels deep
  # (a bare collection/, or pools/<id>_<slug>/). Their files are indexed too: a
  # copy already archived in a bundle can satisfy a later download instead of
  # fetching the bytes again.
  def collection_directories
    return [] unless Dir.exist?(@output_dir)

    Dir.children(@output_dir).flat_map do |entry|
      next [] if entry.start_with?('.')
      # Loose posts are scanned explicitly as the root location, not as a
      # collection.
      next [] if entry == POSTS_DIR

      path = File.join(@output_dir, entry)
      next [] unless File.directory?(path)
      next [path] if holds_media?(path)

      Dir.children(path).filter_map do |sub|
        sub_path = File.join(path, sub)
        sub_path if File.directory?(sub_path) && holds_media?(sub_path)
      end
    end
  end

  def holds_media?(directory)
    Dir.children(directory).any? do |entry|
      next false if entry.start_with?('.') || entry.end_with?(SIDECAR_SUFFIX, *TEMP_SUFFIXES)
      next false if entry.match?(DAMAGED_PATTERN)

      File.file?(File.join(directory, entry)) && entry.match?(/\A\d+\.[^.]/)
    end
  end

  def pool_id_for_directory(_directory)
    nil
  end

  # --- Archive database -----------------------------------------------------

  # Brings the store in line with the filesystem. Entries whose file has gone
  # are dropped so a later run fetches them again; files that were never
  # recorded (an older run, a hand-copied archive) are adopted.
  def reconcile_with_db
    return unless @db.enabled?

    missing = @db.files.reject { |record| db_file_present?(record) }
    missing.each { |record| @db.forget_file(record['post'], record['pool']) }

    adopted = 0
    @existing_posts.each do |key, path|
      post_id, pool_id, relative = split_existing_key(key)
      next if @db.file(post_id, pool_id)

      adopted += 1
      location = Location.new(db_directory(relative), pool_id)
      @db.record_file(post_id: post_id, pool_id: pool_id, path: relative_path_for(path), dir: relative,
                      ext: File.extname(path).delete('.'),
                      bytes: file_size(path),
                      sidecar: File.exist?(sidecar_path(post_id, location)))
    end

    log_info "Archive db reconciled: #{@db.record_count} entries " \
             "(#{missing.size} missing file(s) requeued, #{adopted} unrecorded file(s) adopted)",
             db_records: @db.record_count, missing: missing.size, adopted: adopted
  end

  def file_size(path)
    File.size(path) if File.file?(path)
  rescue SystemCallError
    nil
  end

  # Posts whose sidecar survived but whose media did not: the signature of a run
  # killed part-way, or of a file deleted by hand. Nothing else would ever visit
  # them, because a post is only re-fetched when a tag query happens to return
  # it — so they are asked for by id, one request each.
  def repair_missing_media(processor, stats)
    ids = repair_missing? ? sidecars_without_media : []
    return if ids.empty?

    log_warn "#{ids.size} post(s) have a sidecar but no media file; fetching them by id",
             count: ids.size, posts: ids.first(10).join(',')
    result = fetch_posts_by_ids(ids)
    unless result.ok?
      log_error "Could not look up the posts missing their media", count: ids.size
      return
    end

    result.posts.compact.each do |post|
      next unless post['files'] || post_file_url(post)

      stats.increment(:total_posts)
      processor.enqueue(post)
    end
  end

  # Ids that have a sidecar next to nothing, across posts/ and every bundle
  # directory.
  def sidecars_without_media
    directories = [posts_directory] + collection_directories
    directories.flat_map do |dir|
      next [] unless Dir.exist?(dir)

      media = media_ids_in(dir)
      Dir.children(dir).filter_map do |name|
        next unless name.end_with?(SIDECAR_SUFFIX)
        next if name.match?(SIDECAR_TMP_PATTERN)

        id = name.delete_suffix(SIDECAR_SUFFIX)
        next unless id.match?(/\A\d+\z/)
        next if media.include?(id)

        id.to_i
      end
    end.uniq.sort
  end

  def media_ids_in(directory)
    ids = Set.new
    Dir.children(directory).each do |name|
      next if name.end_with?(SIDECAR_SUFFIX, *TEMP_SUFFIXES) || name.match?(DAMAGED_PATTERN)

      id = name[/\A(\d+)\./, 1]
      ids << id if id
    end
    ids
  end

  def db_file_present?(record)
    key = existing_key(record['post'], Location.new(db_directory(record['dir']), record['pool']))
    @existing_posts.key?(key)
  end

  # Compares what is on disk with what the store says was written there. A file
  # that is empty, shorter than recorded, or (with --verify-md5) no longer
  # hashes to the recorded digest is treated as absent, so it is fetched again
  # instead of being trusted forever because a sidecar happens to exist.
  def check_archived_integrity
    @integrity_faults = Hash.new(0)
    @preserved_files = []
    return unless @db.enabled?

    @db.files.each do |record|
      path = @existing_posts[existing_key(record['post'], location_of(record))]
      next unless path

      fault = integrity_fault(path, record)
      next unless fault

      handle_integrity_fault(record, path, fault)
    end

    return if @integrity_faults.empty? && @preserved_files.empty?

    @preserved_files.each do |entry|
      log_warn "Archived file was changed on purpose and left in place: #{entry[:path]}",
               path: entry[:path], bytes: entry[:bytes]
    end
    log_warn "Archive integrity: #{@integrity_faults.values.sum} damaged file(s) queued for re-download, " \
             "#{@preserved_files.size} changed file(s) left alone",
             **{ integrity: @integrity_faults.transform_keys(&:to_s), preserved: @preserved_files.size }
  end

  def integrity_fault_count
    @integrity_faults&.values&.sum || 0
  end

  def preserved_file_count
    @preserved_files&.size || 0
  end

  def location_of(record)
    Location.new(db_directory(record['dir']), record['pool'])
  end

  def integrity_fault(path, record)
    return nil unless File.file?(path)
    # A different extension means a different file, not a damaged one.
    return nil if record['ext'] && File.extname(path).delete('.') != record['ext']

    size = File.size(path)
    return :empty if size.zero?

    recorded = record['bytes'].to_i
    return :truncated if recorded.positive? && size < recorded
    return :modified if recorded.positive? && size > recorded
    return :corrupt if @verify_md5 && comparable_md5?(record) &&
                       Digest::MD5.file(path).hexdigest != record['md5']

    nil
  rescue SystemCallError => e
    log_debug "Could not read #{path}: #{e.message}"
    nil
  end

  # A recorded digest only describes the bytes it was computed over. When the
  # site served a different container than the post advertises — Gelbooru hands
  # out .mp4 for a post whose `image` says .webm, e621 hands out .webm for some
  # .mp4 posts — the archived file was never those bytes, so its digest is not a
  # corruption signal and must not condemn the file.
  def comparable_md5?(record)
    return false if record['md5'].nil? || record['md5'].to_s.empty?

    file_ext = record['ext'].to_s.downcase
    return true if file_ext.empty?

    post_ext = @db.post_ext(record['post'])
    post_ext.nil? || post_ext.to_s.empty? || post_ext.to_s.downcase == file_ext
  end

  # A file that is *larger* than the archive recorded has been changed on
  # purpose — re-encoded, edited, annotated. Re-fetching it would silently
  # destroy that work, so it is reported and left exactly as it is. Everything
  # else (empty, truncated, or a same-size hash mismatch under --verify-md5)
  # cannot be the archived bytes, so the original is moved aside under a name
  # the media scan ignores and the download starts over. Nothing is deleted
  # either way: whatever gets replaced is still on disk.
  def handle_integrity_fault(record, path, fault)
    if fault == :modified
      @preserved_files << { post: record['post'], path: relative_path_for(path), bytes: File.size(path) }
      return
    end

    @integrity_faults[fault] += 1
    preserved = preserve_damaged_file(path)
    @existing_mutex.synchronize do
      key = existing_key(record['post'], location_of(record))
      @existing_posts.delete(key)
      @existing_by_post[record['post']]&.delete(key)
    end
    log_warn "Archived file looks #{fault}, queued for re-download" \
             "#{preserved ? " (original kept as #{File.basename(preserved)})" : ''}",
             post_id: record['post'], path: relative_path_for(path), fault: fault
  end

  # Moves the suspect bytes aside under a name the media scan skips, so a
  # re-download writes a clean file while the old bytes stay recoverable.
  def preserve_damaged_file(path)
    stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    target = "#{path}#{DAMAGED_MARK}-#{stamp}"
    FileUtils.mv(path, target)
    target
  rescue SystemCallError => e
    log_warn "Could not set #{relative_path_for(path)} aside: #{e.message}"
    nil
  end

  def db_directory(relative)
    return posts_directory if relative.nil? || relative == '.' || relative == POSTS_DIR

    File.join(@output_dir, relative)
  end

  def split_existing_key(key)
    post_id, pool_id, relative = key.split('|', 3)
    [post_id.to_i, pool_id == '0' ? nil : pool_id.to_i, relative]
  end

  # Where a download left the digest it already computed, so the row can record
  # it. Keyed per thread: the download and the record that follows it happen on
  # the same worker, and one instance variable would be interleaved by another.
  def remember_downloaded_digest(path, digest)
    Thread.current[:rubichiver_download_digests] ||= {}
    Thread.current[:rubichiver_download_digests][path] = digest
  end

  def downloaded_digest(path)
    Thread.current[:rubichiver_download_digests]&.delete(path)
  end

  def record_archived_file(post, location, path, md5: nil, sidecar: nil)
    remember_existing(post['id'], location, path)
    return unless @db.enabled?

    # A container variant is verified against nothing, so take the digest the
    # download already produced rather than leaving the row unverifiable.
    md5 ||= downloaded_digest(path)

    @db.record_file(
      post_id: post['id'], pool_id: location.pool_id,
      path: relative_path_for(path), dir: relative_directory(location.directory),
      md5: md5, ext: File.extname(path).delete('.'),
      bytes: (File.size(path) if File.file?(path)),
      sidecar: sidecar.nil? ? File.exist?(sidecar_path(post['id'], location)) : sidecar,
      rating: post['rating'], width: post_width(post), height: post_height(post)
    )
  end

  def record_sidecar_written(post, location, path)
    return unless @db.enabled?

    @db.record_sidecar(post['id'], location.pool_id, sidecar: true)
    remember_existing(post['id'], location, path)
  end

  def relative_path_for(path)
    root = "#{File.expand_path(@output_dir)}/"
    expanded = File.expand_path(path)
    expanded.delete_prefix(root)
  end

  def acquire_run_lock
    @lock_file = File.open(File.join(@output_dir, '.rubichiver.lock'), File::RDWR | File::CREAT, 0o644)
    return if @lock_file.flock(File::LOCK_EX | File::LOCK_NB)

    @lock_file.close
    @lock_file = nil
    log_fatal "Another rubichiver run already holds this output directory", output_dir: @output_dir
    exit 1
  end

  # --- Sidecars -------------------------------------------------------------

  def sidecar_path(post_id, location = nil)
    location ||= root_location
    File.join(location.directory, "#{post_id}#{SIDECAR_SUFFIX}")
  end

  # One exiftool process per existing post does not scale to an archive of any
  # size, so the sidecars are read up front in batches and consulted from an
  # index afterwards. A nil index (no pre-pass) falls back to single reads.
  def build_sidecar_index
    @sidecar_index = {}
    pairs = @existing_posts.filter_map do |key, _media|
      location = location_for_key(key)
      sidecar = sidecar_path(location_key_post_id(key), location)
      [sidecar, key] if File.file?(sidecar)
    end
    return if pairs.empty?

    log_info "Reading #{pairs.size} existing sidecars", api: true
    total_batches = (pairs.size.to_f / SIDECAR_READ_BATCH).ceil

    pairs.each_slice(SIDECAR_READ_BATCH).with_index do |batch, idx|
      break if @interrupted

      next if index_sidecar_batch(batch)

      log_error "exiftool could not read every sidecar in batch #{idx + 1}/#{total_batches}; " \
                'falling back to checking sidecars one at a time', api: true
      @sidecar_index = nil
      return
    end

    log_info "Indexed #{@sidecar_index.size} sidecars", api: true
  end

  # Returns false when the batch could not be read, so the caller can drop the
  # index rather than treat unread sidecars as invalid and rewrite them. The
  # group-qualified read is what lets each field be looked up unambiguously.
  def index_sidecar_batch(batch)
    return true if batch.empty?

    by_source = batch.to_h
    stdout, stderr, status = exiftool_read(batch.map(&:first))
    unless status.success?
      log_warn "exiftool failed on #{batch.size} sidecar(s): #{stderr.to_s.lines.first.to_s.strip}", api: true
      return index_sidecar_batch_smaller(batch)
    end

    entries = JSON.parse(stdout)
    entries = [entries] unless entries.is_a?(Array)
    entries.each do |entry|
      next unless entry.is_a?(Hash) && entry['SourceFile']

      key = by_source[entry['SourceFile']]
      @sidecar_index[key] = entry if key
    end
    true
  rescue JSON::ParserError => e
    log_warn "exiftool returned unparsable JSON for a sidecar batch: #{e.message}", api: true
    false
  end

  # Halves the batch until it reads, then gives up so the caller can fall back to
  # reading sidecars one at a time. Dropping straight to one process per sidecar
  # would turn a seconds-long pass over a large archive into an hours-long one.
  #
  # The split is on the batch that actually arrived, not on a nominal size, so
  # every retry is a strictly smaller request: halving the nominal size instead
  # would re-issue the very same command whenever the batch was already smaller
  # than the next step down.
  def index_sidecar_batch_smaller(batch)
    return false if batch.size <= 1

    batch.each_slice(batch.size / 2).all? { |part| index_sidecar_batch(part) }
  end

  # One exiftool process over a set of sidecars, returning its captured output.
  # Split out so the batching above can be exercised without spawning a real
  # process per case.
  def exiftool_read(paths)
    Open3.capture3('exiftool', '-json', '-G1', *SIDECAR_FIELDS.values.map { |tag| "-#{tag}" }, *paths)
  end

  def location_key_post_id(key)
    key.split('|', 2).first.to_i
  end

  def location_for_key(key)
    _post_id, pool_id, relative = split_existing_key(key)
    Location.new(db_directory(relative), pool_id)
  end

  def sidecar_index_key(post_id, location)
    existing_key(post_id, location)
  end

  # Everything the sidecar should say about a post, as a plain hash keyed by
  # SIDECAR_FIELDS. Written and validated from this one structure, so a field
  # can never be written but not checked (which is how stale keywords used to
  # survive forever) or checked but never written.
  #
  # Returns :unrated when the site gave no rating, and :uncategorized when it
  # sent a flat tag list: guessing categories there would write wrong keywords,
  # so nothing is written and the post is retried on a later run.
  def sidecar_payload(post)
    return :unrated unless rating_label(post)

    tags = extract_post_tags(post)
    return :uncategorized if tags.empty? && !post_tag_names(post).empty?

    {
      'Title' => post_title(post),
      'Creator' => post_artists(post),
      'Subject' => (["rating:#{rating_label(post)}"] + post_pool_names(post) + tags),
      'Description' => sidecar_description(post),
      'Rights' => post_page_url(post),
      'Rating' => rating_value(post['rating']),
      'CreateDate' => post_timestamp(post, 'created_at'),
      'ModifyDate' => post_timestamp(post, 'updated_at'),
      'CreatorTool' => user_agent
    }
  end

  def payload_field(payload, key)
    payload.is_a?(Hash) ? payload[key] : nil
  end

  # A sidecar is current only if every field says what the post currently says.
  # Keywords are compared as a set, not as a subset: a tag deleted upstream has
  # to invalidate the sidecar, otherwise it is never cleaned up.
  def sidecar_valid?(post, location = nil)
    location ||= root_location
    post_id = post['id']
    return false unless File.exist?(sidecar_path(post_id, location))

    expected = sidecar_payload(post)
    return false unless expected.is_a?(Hash)

    reading = sidecar_reading(post_id, location)
    return false unless reading.is_a?(Hash)

    SIDECAR_FIELDS.each do |key, tag|
      next if sidecar_field_matches?(reading[tag], payload_field(expected, key), key)

      log_debug "Sidecar for post #{post_id} is stale: #{key} differs", post_id: post_id, field: key
      return false
    end
    true
  end

  def sidecar_field_matches?(actual, expected, key)
    if expected.nil? || (expected.respond_to?(:empty?) && expected.empty?)
      return actual.nil? || actual == '' || actual == []
    end

    return false if actual.nil?

    if expected.is_a?(Array)
      # Set equality, so a keyword the post no longer has invalidates the file.
      Array(actual).flatten.map(&:to_s).sort == expected.map(&:to_s).sort
    elsif key == 'CreatorTool'
      creator_tool_matches?(actual, expected)
    elsif DATE_SIDECAR_FIELDS.include?(key)
      # exiftool re-renders dates in its own format, so compare instants.
      !canonical_time(actual).nil? && canonical_time(actual) == canonical_time(expected)
    else
      actual.to_s == expected.to_s
    end
  end

  # The version string and the account name both live in CreatorTool, and neither
  # says anything about the post. Comparing them exactly rewrites every sidecar
  # on each release or rename — tens of thousands of exiftool runs for zero new
  # information — so only the tool name has to match. A sidecar written by
  # something else still invalidates, as it should.
  def creator_tool_matches?(actual, expected)
    actual_tool = actual.to_s.split('/').first.to_s.strip
    expected_tool = expected.to_s.split('/').first.to_s.strip
    !actual_tool.empty? && actual_tool == expected_tool
  end

  # exiftool reports XMP dates back as "YYYY:MM:DD HH:MM:SS[.sss][Z|±HH:MM]",
  # which Time.parse does not accept, so the date separators are normalised
  # first. The result is the instant in UTC, or nil when it cannot be read.
  def canonical_time(value)
    text = value.to_s.strip
    return nil if text.empty?

    text = text.sub(/\A(\d{4}):(\d{2}):(\d{2})/, '\1-\2-\3')
    Time.parse(text).to_i
  rescue ArgumentError, TypeError
    nil
  end

  def sidecar_reading(post_id, location = nil)
    location ||= root_location
    key = sidecar_index_key(post_id, location)
    return @sidecar_index[key] if @sidecar_index

    path = sidecar_path(post_id, location)
    return nil unless File.file?(path)

    stdout, _stderr, status = exiftool_read([path])
    return nil unless status.success?

    data = JSON.parse(stdout)
    data.is_a?(Array) ? data.first : data
  rescue JSON::ParserError
    nil
  end

  # Returns true when a sidecar was written, :skipped when the site gave no
  # rating, :uncategorized when it gave no usable tag categories, and false when
  # exiftool failed.
  def write_sidecar(media_file, post)
    post_id = post['id']
    sidecar = sidecar_path(post_id, Location.new(File.dirname(media_file), nil))
    payload = sidecar_payload(post)
    return payload unless payload.is_a?(Hash)

    # The name has to end in .xmp: exiftool decides what to write from the output
    # extension, and given anything else it falls back to the input format, which
    # it cannot write for webm ("Writing of WEBM files is not yet supported").
    # The .part marker before it keeps the in-flight file out of the media scan if
    # this process dies between writing and renaming.
    tmp_sidecar = "#{sidecar}#{Process.pid}#{PART_SUFFIX}#{SIDECAR_SUFFIX}"
    File.delete(tmp_sidecar) if File.exist?(tmp_sidecar)

    args = ['-o', tmp_sidecar]
    payload.each do |key, value|
      tag = SIDECAR_FIELDS[key]
      next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      if value.is_a?(Array)
        # A list tag needs '=' for its first entry and '+=' for the rest.
        args << "-#{tag}=#{value.first}"
        value.drop(1).each { |item| args << "-#{tag}+=#{item}" }
      else
        args << "-#{tag}=#{value}"
      end
    end
    args << media_file

    _stdout, stderr, status = Open3.capture3('exiftool', *args)

    if status.success? && File.exist?(tmp_sidecar)
      File.rename(tmp_sidecar, sidecar)
      return true
    end

    File.delete(tmp_sidecar) if File.exist?(tmp_sidecar)
    log_error "exiftool sidecar write failed: #{stderr}", sidecar: sidecar, post_id: post_id, stderr: stderr
    false
  end

  # --- Sidecar content ------------------------------------------------------

  # A short human-readable title: the work it is, then where it came from. The
  # filename only carries a post id, so this is the field a media browser shows.
  def post_title(post)
    subject = Array(categorized_post_tags(post)['copyright']).first ||
              Array(categorized_post_tags(post)['character']).first ||
              Array(categorized_post_tags(post)['artist']).first
    subject ? "#{subject} \u2014 #{site_name} ##{post['id']}" : "#{site_name} ##{post['id']}"
  end

  # The artist, in the field every catalogue tool reads. Without it the artist
  # is just another keyword and the sidecar is of little use to a browser.
  def post_artists(_post)
    []
  end

  # The original source links, which are what makes a post findable again once
  # it is offline, followed by whatever the uploader wrote.
  def sidecar_description(post)
    parts = post_sources(post).map { |url| "Source: #{url}" }
    note = post_description(post).to_s.strip
    parts << note unless note.empty?
    parts.empty? ? nil : parts.join("\n\n")
  end

  def post_description(_post)
    nil
  end

  def post_sources(_post)
    []
  end

  def post_page_url(_post)
    nil
  end

  def post_width(_post)
    nil
  end

  def post_height(_post)
    nil
  end

  # Pool names the post belongs to, as keywords. Read from the database rather
  # than fetched, so a sidecar can be validated without extra requests.
  def post_pool_names(post)
    return [] unless pools_active?

    post_pool_ids(post).filter_map do |pool_id|
      name = @db.pool(pool_id)&.fetch('name', nil)
      name && "pool:#{name}"
    end
  end

  def post_timestamp(post, field)
    value = post[field]
    value.to_s.strip.empty? ? nil : value.to_s
  end
end
