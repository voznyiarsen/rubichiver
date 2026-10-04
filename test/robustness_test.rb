# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/stub_http'

# Regressions for the ways a run could previously report success while losing
# work, leak a credential, or destroy something the user owned.
class RobustnessTest < Minitest::Test
  include StubHttp

  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, 'posts'))
    @archiver = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                 username: 'tester', api_key: 'key', rate_limit: 1000)
    @archiver.ensure_rate_limiter
  end

  def teardown
    shutdown_servers
    FileUtils.remove_entry(@dir)
  end

  def post(id = 1)
    { 'id' => id, 'rating' => 's', 'tags' => { 'general' => %w[cat] },
      'files' => { 'original' => { 'url' => "http://example.test/#{id}.png" },
                   'meta' => { 'ext' => 'png', 'md5' => 'abc' } } }
  end

  def process(count: 1, threads: 1, &configure)
    stats = Stats.new
    configure&.call
    processor = PostProcessor.new(rate_limiter: @archiver.rate_limiter, output_dir: @dir,
                                  stats: stats, thread_count: threads, archiver: @archiver)
    count.times { |i| processor.enqueue(post(i + 1)) }
    processor.finish
    processor.wait
    stats
  end

  # --- a lost post must be a reported failure ------------------------------

  # A truncated chunked body surfaces as Net::HTTPBadResponse, which is not a
  # socket error. It used to escape download_media entirely, so the post
  # vanished and the run still exited 0.
  def test_a_truncated_body_costs_a_retry_not_the_post
    attempts = 0
    @archiver.define_singleton_method(:http_get) do |_uri, **_opts, &body_handler|
      attempts += 1
      if attempts < 3
        raise Net::HTTPBadResponse, 'wrong number of arguments in the chunked body'
      end

      body_handler&.call(StubHttp::Response.new(200, 'ok'))
      nil
    end
    @archiver.define_singleton_method(:resolve_served_extension) { |_, ext, _| ext }
    @archiver.define_singleton_method(:post_md5) { |_| nil }
    @archiver.define_singleton_method(:write_sidecar) { |_m, _p| :unrated }

    # A post with no expected MD5 is accepted on the first complete transfer, so
    # the third attempt is the one that lands.
    stats = Stats.new
    processor = PostProcessor.new(rate_limiter: @archiver.rate_limiter, output_dir: @dir,
                                  stats: stats, thread_count: 1, archiver: @archiver)
    processor.enqueue(post)
    processor.finish
    processor.wait

    assert_equal 3, attempts, 'the fault is retried'
    assert_equal 1, stats.downloaded_files
    assert_equal 0, stats.failed_files
  end

  def test_an_unexpected_worker_fault_is_counted_as_a_failure
    @archiver.define_singleton_method(:post_file_url) do |_p|
      raise NoMethodError, "undefined method `xyz' for nil"
    end

    assert_equal 1, process.failed_files, 'a swallowed fault must not look like a clean run'
  end

  # A post the site gave no rating for is archived, not failed.
  def test_an_unrated_post_is_archived_not_failed
    unrated = post.merge('rating' => nil)
    @archiver.define_singleton_method(:write_sidecar) { |_m, _p| :unrated }
    @archiver.define_singleton_method(:download_media) do |_url, output, _id, _md5, thread_idx: nil|
      File.binwrite(output, 'ok')
      true
    end

    stats = Stats.new
    processor = PostProcessor.new(rate_limiter: @archiver.rate_limiter, output_dir: @dir,
                                  stats: stats, thread_count: 1, archiver: @archiver)
    processor.enqueue(unrated)
    processor.finish
    processor.wait

    assert_equal 1, stats.downloaded_files
    assert_equal 0, stats.failed_files, 'a missing rating is not a failed download'
  end

  # A failing exiftool is a real failure and has to be reported.
  def test_a_failed_sidecar_write_is_counted_as_a_failure
    @archiver.define_singleton_method(:write_sidecar) { |_m, _p| false }
    @archiver.define_singleton_method(:download_media) do |_url, output, _id, _md5, thread_idx: nil|
      File.binwrite(output, 'ok')
      true
    end

    assert_equal 1, process.failed_files
  end

  def test_api_get_swallows_an_unexpected_fault
    @archiver.instance_variable_set(:@interrupted, true)
    @archiver.define_singleton_method(:http_get) do |_uri, **_opts|
      raise NoMethodError, "undefined method `xyz' for nil:NilClass"
    end

    assert_nil @archiver.api_get(URI('http://example.test/posts.json'), { tags: 'cat' }),
               'an API hiccup of any shape is a failed request, not a crash'
  end

  # e621 answers an over-limit request with 503, not 429, and it means the request
# never ran. Treating it as an ordinary blip burns the retry budget in seconds
# and drops the post; it has to back off like the sustained condition it is.
def test_a_rate_limited_response_backs_off_hard
  sleeps = []
  @archiver.define_singleton_method(:sleep) { |s| sleeps << s }
  respond_with('503')

  assert_nil @archiver.api_get(URI('http://example.test/posts.json'), { tags: 'cat' })

  refute_empty sleeps, 'a refused request must wait before trying again'
  assert_operator sleeps.max, :>=, 5, "expected a rate-limit backoff, got #{sleeps.inspect}"
end

# The first refusal drops to 1 req/s per worker. api_get retries internally, so
# those retries must NOT walk through every stage in a second -- the pool holds
# stage 1 until the window has genuinely elapsed.
def test_a_single_refused_request_does_not_walk_through_every_stage
  @archiver.define_singleton_method(:sleep) { |_s| nil }
  respond_with('503')
  limiter = @archiver.rate_limiter

  assert_equal 0, limiter.current_stage
  @archiver.api_get(URI('http://example.test/posts.json'), { tags: 'cat' })
  assert_equal 1, limiter.current_stage, 'one refused request settles at stage 1'
end

# Being refused again once that minute has passed means we are still too fast,
# so the run drops to a single request per second shared between all workers.
def test_still_being_throttled_after_the_window_escalates
  now = 1000.0
  limiter = RateLimiterPool.new(requests_per_second: 8, threads: 4, cooldown: 60, stages: 2,
                                clock: -> { now })

  assert_equal [1, true], limiter.note_refusal
  # Retries of that same request land inside the window: held, not escalated.
  3.times { assert_equal [1, false], limiter.note_refusal }

  # Still being refused a minute later means we are still going too fast.
  now += 61
  assert_equal [2, true], limiter.note_refusal

  # Already at the floor, so it stays there rather than inventing a stage 3.
  now += 61
  assert_equal [2, true], limiter.note_refusal
  assert_equal 2, limiter.current_stage
end

def test_the_stage_lifts_itself_once_the_window_passes
  now = 1000.0
  limiter = RateLimiterPool.new(requests_per_second: 8, threads: 4, cooldown: 60, clock: -> { now })
  limiter.note_refusal
  assert_equal 1, limiter.current_stage
  assert limiter.throttled?

  now += 61
  assert_equal 0, limiter.current_stage
  refute limiter.throttled?
end

# Only a real change of stage is worth alerting about; one refused request is
# retried several times and would otherwise page you several times over.
def test_only_an_escalation_is_reported_and_alerted
  @archiver.define_singleton_method(:sleep) { |_s| nil }
  respond_with('429')

  log = capture_log do
    3.times { @archiver.api_get(URI('http://example.test/posts.json'), { tags: 'cat' }) }
  end

  assert_equal 1, log.scan('is rate limiting this run').size
  assert_includes log, '1 req/s per worker'
end

def test_a_transient_server_error_is_not_reported_as_rate_limiting
  @archiver.define_singleton_method(:sleep) { |_s| nil }
  respond_with('500')

  log = capture_log { @archiver.api_get(URI('http://example.test/posts.json'), { tags: 'cat' }) }

  refute_includes log, 'is rate limiting this run'
end

# ntfy takes the topic from the JSON body and only parses title/message/tags
# when it is posted to the server root. Posting the same JSON to the topic URL
# arrives as one raw string, which reads as noise rather than an alert.
def test_ntfy_alerts_carry_the_topic_in_the_body_and_post_to_the_root
  archiver = notifying_archiver('https://ntfy.sh/rubichiver-test-topic')

  body = archiver.send(:notification_body, 'title here', 'message here', 5, ['warning'])
  assert_equal 'rubichiver-test-topic', body['topic']
  assert_equal 'title here', body['title']
  assert_equal 'message here', body['message']
  assert_equal 'https://ntfy.sh/', archiver.send(:notification_target).to_s
end

def test_a_non_ntfy_endpoint_keeps_the_url_and_gets_an_event_body
  archiver = notifying_archiver('https://example.test/hook')

  body = archiver.send(:notification_body, 'title here', 'message here', 4, [])
  refute body.key?('topic')
  assert_equal 'rubichiver.e621.alert', body['event']
  assert_equal 'https://example.test/hook', archiver.send(:notification_target).to_s
end

def test_notification_failures_never_take_the_run_down
  archiver = notifying_archiver('https://ntfy.sh/rubichiver-test-topic')
  archiver.define_singleton_method(:post_notification) { |_p| raise Errno::ECONNREFUSED }

  archiver.send(:notify_event, 't', 'm')
rescue StandardError => e
  flunk "a dead webhook must not raise: #{e.class}: #{e.message}"
end

# Credentials ride in the notify URL as standard userinfo, which is the only
# auth ntfy needs. Read off @notify_url, not the request target: the target is
# rebuilt from scheme/host/port for ntfy and has already dropped them.
def test_notification_credentials_come_from_the_url_userinfo
  archiver = notifying_archiver('https://alice:s3cr3t@ntfy.example.com/rubichiver')

  request = Net::HTTP::Post.new(archiver.send(:notification_target))
  archiver.send(:apply_notification_auth, request)

  assert_equal "Basic #{['alice:s3cr3t'].pack('m0')}", request['Authorization']
  assert_equal 'https://ntfy.example.com/', request.uri.to_s,
               'the topic is dropped, but the credentials must survive'
end

# A password containing characters that are reserved in a URI must arrive
# intact: URI#password hands back the still-encoded form.
def test_notification_credentials_are_percent_decoded
  archiver = notifying_archiver('https://alice:p%40ss%3Aword@ntfy.example.com/rubichiver')

  request = Net::HTTP::Post.new(archiver.send(:notification_target))
  archiver.send(:apply_notification_auth, request)

  assert_equal "Basic #{['alice:p@ss:word'].pack('m0')}", request['Authorization']
end

# Most webhooks are open, so a URL with no credentials must send no
# Authorization header at all rather than an empty one (which servers reject).
def test_notification_without_credentials_sends_no_authorization_header
  archiver = notifying_archiver('https://ntfy.example.com/rubichiver')

  request = Net::HTTP::Post.new(archiver.send(:notification_target))
  archiver.send(:apply_notification_auth, request)

  assert_nil request['Authorization']
end

# The run is announced once it is genuinely under way. Its job is to bound the
# silence: the work that follows takes hours, so a start with no matching
# end-of-run report is the only sign the process died part way.
def test_a_started_run_announces_itself_before_the_long_phase
  archiver = notifying_archiver('https://ntfy.example.com/rubichiver', thread_count: 4, rate_limit: 8)
  sent = capture_notifications(archiver)

  archiver.send(:notify_start)

  assert_equal 1, sent.size
  assert_equal 'e621 archive starting', sent.first['title']
  assert_equal 3, sent.first['priority']
  assert_includes sent.first['message'], 'mode: archive'
  assert_includes sent.first['message'], 'workers: 4'
  assert_includes sent.first['message'], 'rate limit: 8/s per worker'
end

# The three modes read differently at a glance, which is the whole point of
# announcing them separately.
def test_the_start_notification_names_the_mode_it_is_in
  {
    {} => 'e621 archive starting',
    { recache_post_tags: true } => 'e621 recache starting',
    { dry_run: true } => 'e621 dry run starting'
  }.each do |opts, expected|
    archiver = notifying_archiver('https://ntfy.example.com/rubichiver', **opts)
    sent = capture_notifications(archiver)
    archiver.send(:notify_start)
    assert_equal expected, sent.first['title']
  end
end

# Same privacy rule as the end-of-run report: counters and settings only. The
# archive's paths, its tag queries and the account name must not travel.
def test_the_start_notification_carries_no_paths_or_tags
  archiver = notifying_archiver('https://ntfy.example.com/rubichiver')
  sent = capture_notifications(archiver)

  archiver.send(:notify_start)

  message = sent.first['message']
  refute_includes message, archiver.output_dir.to_s
  refute_includes message, 'tester'
  refute_includes message, @dir
  # Only "N/s" may contain a slash, which is what "per worker" is for.
  scrubbed = message.gsub(%r{\d+/s}, '')
  refute_includes scrubbed, '/'
end

# Gelbooru has no pools, so announcing "bundled" there would be a lie.
def test_the_start_notification_reports_pools_per_site
  e621 = notifying_archiver('https://ntfy.example.com/rubichiver')
  sent = capture_notifications(e621)
  e621.send(:notify_start)
  assert_includes sent.first['message'], 'pools: bundled'

  gelbooru = GelbooruArchiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                 username: 'tester', api_key: 'key',
                                 notify_url: 'https://ntfy.example.com/rubichiver')
  sent = capture_notifications(gelbooru)
  gelbooru.send(:notify_start)
  assert_includes sent.first['message'], 'pools: disabled'
end

def capture_notifications(archiver)
  sent = []
  archiver.define_singleton_method(:post_notification) { |payload| sent << payload }
  sent
end

def notifying_archiver(url, **opts)
  E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                   username: 'tester', api_key: 'key', notify_url: url, **opts)
end

def respond_with(code)
  @archiver.define_singleton_method(:http_get) do |_uri, **_opts|
    Struct.new(:code).new(code)
  end
end

# Swaps the logger's sink for the duration of the block, since what is asserted
# here is what the operator would actually see in the journal.
def capture_log
  io = StringIO.new
  previous = Rubichiver::Logger.output
  Rubichiver::Logger.configure(level: :debug, output: io, colors: false)
  yield
  io.string
ensure
  Rubichiver::Logger.configure(level: :debug, output: previous, colors: false)
end

def test_a_download_fault_of_any_shape_is_reported_not_raised
    @archiver.define_singleton_method(:http_get) do |_uri, **_opts, &_handler|
      raise ArgumentError, 'something nobody anticipated'
    end
    output = File.join(@dir, '9.png')

    refute @archiver.download_media('http://example.test/9.png', output, 9, nil),
           'an unanticipated fault is a failed download, not a crash'
    refute File.exist?(output), 'and it leaves no half-written file behind'
  end

  # --- credentials must not follow a redirect -------------------------------

  # The origin gets the key; the host a 302 names does not. Replaying an
  # Authorization header across a redirect hands the API key to a third party.
  def test_credentials_are_not_replayed_to_a_redirect_target
    stolen = Queue.new
    other = webrick { |srv| srv.mount_proc('/elsewhere') { |req, res| stolen << req['authorization']; res.body = '[]' } }
    origin = webrick do |srv|
      srv.mount_proc('/posts.json') do |_req, res|
        res.status = 302
        res['Location'] = "http://127.0.0.1:#{other.config[:Port]}/elsewhere"
        res.body = ''
      end
    end

    archiver = E621Archiver.new(output_dir: @dir, db_path: nil, username: 'tester', api_key: 'SECRET')
    archiver.instance_variable_set(:@rate_limiter, @archiver.rate_limiter)
    key = { 'Authorization' => "Basic #{['tester:SECRET'].pack('m0')}" }

    response = archiver.http_get(URI("http://127.0.0.1:#{origin.config[:Port]}/posts.json"),
                                 headers: key)

    assert_equal '200', response.code, 'the redirect was still followed'
    assert_nil stolen.pop, 'the redirect target must not receive the API key'
  end

  # A same-host redirect is a CDN hop, not a leak: the key still goes with it.
  def test_credentials_survive_a_same_host_redirect
    origin = webrick do |srv|
      srv.mount_proc('/start') { |_req, res| res.status = 302; res['Location'] = '/next'; res.body = '' }
      srv.mount_proc('/next') { |req, res| res['seen'] = req['authorization']; res.body = '[]' }
    end
    seen = Queue.new
    origin.mount_proc('/next') { |req, res| seen << req['authorization']; res.body = '[]' }

    archiver = E621Archiver.new(output_dir: @dir, db_path: nil, username: 'tester', api_key: 'SECRET')
    archiver.instance_variable_set(:@rate_limiter, @archiver.rate_limiter)
    key = { 'Authorization' => "Basic #{['tester:SECRET'].pack('m0')}" }

    response = archiver.http_get(URI("http://127.0.0.1:#{origin.config[:Port]}/start"),
                                 headers: key)

    assert_equal '200', response.code
    assert_equal key['Authorization'], seen.pop, 'a same-host hop keeps the key'
  end

  # --- pool slugs must not move ---------------------------------------------

  # A pool whose first lookup fails used to land in pools/42_pool and then move
  # to pools/42_my-cool-pool, stranding the bundle.
  def test_a_pool_slug_is_frozen_even_when_the_first_lookup_fails
    calls = 0
    first_run = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                 username: 'tester', api_key: 'k')
    first_run.define_singleton_method(:fetch_pool) do |id|
      calls += 1
      calls == 1 ? nil : { 'id' => id, 'name' => 'My Cool Pool', 'post_count' => 1, 'post_ids' => [7] }
    end
    first = first_run.pool_directory(42)
    first_run.db.close

    second_run = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                  username: 'tester', api_key: 'k')
    second_run.define_singleton_method(:fetch_pool) do |id|
      { 'id' => id, 'name' => 'My Cool Pool', 'post_count' => 1, 'post_ids' => [7] }
    end

    assert_equal first, second_run.pool_directory(42), 'the bundle directory must never move'
    assert_match(%r{42_pool-42\z}, first)
  end

  def test_a_pool_named_up_front_keeps_its_slug
    e621 = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                            username: 'tester', api_key: 'k')
    e621.define_singleton_method(:fetch_pool) do |id|
      { 'id' => id, 'name' => 'My Cool Pool', 'post_count' => 1, 'post_ids' => [7] }
    end

    assert_match(%r{42_my-cool-pool\z}, e621.pool_directory(42))
  end

  # --- migrating an archive made by an earlier version ----------------------

  # A bundle directory that already exists names itself. A pool renamed upstream
  # must not create a second directory and strand the first — which is exactly
  # what happened when the slug came from the API and the database was fresh.
  def test_an_existing_bundle_directory_is_adopted_over_the_api_name
    FileUtils.mkdir_p(File.join(@dir, 'pools', '42_they-said-saturnsaco'))
    e621 = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                            username: 'tester', api_key: 'k')
    e621.define_singleton_method(:fetch_pool) do |id|
      { 'id' => id, 'name' => 'They Said', 'post_count' => 1, 'post_ids' => [7] }
    end

    assert_match(%r{42_they-said-saturnsaco\z}, e621.pool_directory(42))
    assert_equal 'they-said-saturnsaco', e621.db.pool(42)['slug'], 'the directory name is frozen'
    assert_equal 'They Said', e621.db.pool(42)['name'], 'but the current title is still recorded'
  end

  # The same rule covers a database that was lost, so a rebuild cannot move a
  # bundle either.
  def test_a_bundle_survives_the_database_being_lost
    FileUtils.mkdir_p(File.join(@dir, 'pools', '42_whatever-it-was'))
    e621 = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                            username: 'tester', api_key: 'k')
    e621.define_singleton_method(:fetch_pool) do |id|
      { 'id' => id, 'name' => 'A Completely Different Name', 'post_count' => 1, 'post_ids' => [7] }
    end
    first = e621.pool_directory(42)
    e621.db.close
    FileUtils.rm_f(File.join(@dir, 'db'))

    rebuilt = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                               username: 'tester', api_key: 'k')
    rebuilt.define_singleton_method(:fetch_pool) do |id|
      { 'id' => id, 'name' => 'A Completely Different Name', 'post_count' => 1, 'post_ids' => [7] }
    end

    assert_equal first, rebuilt.pool_directory(42)
  end

  def test_two_directories_for_one_pool_are_reported_not_silently_merged
    FileUtils.mkdir_p(File.join(@dir, 'pools', '42_aaa'))
    FileUtils.mkdir_p(File.join(@dir, 'pools', '42_zzz'))
    e621 = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                            username: 'tester', api_key: 'k')
    e621.define_singleton_method(:fetch_pool) do |id|
      { 'id' => id, 'name' => 'They Said', 'post_count' => 1, 'post_ids' => [7] }
    end

    # Deterministic, and the leftovers are surfaced rather than deleted.
    assert_match(%r{42_aaa\z}, e621.pool_directory(42))
  end

  # A file adopted from the filesystem has no recorded digest, which would leave
  # --verify-md5 blind to everything archived before the database existed.
  def test_an_adopted_file_picks_up_its_digest_when_the_post_is_seen
    File.binwrite(File.join(@dir, 'posts', '7.png'), 'x')
    @archiver.scan_output_dir
    @archiver.send(:reconcile_with_db)
    assert_nil @archiver.db.file(7)['md5']

    @archiver.db.record_post(post_id: 7, md5: 'abc123', rating: 's', tags: { 'general' => %w[cat] })

    assert_equal 'abc123', @archiver.db.file(7)['md5']
  end

  # A copy placed by hard link shares the source's bytes, so it inherits the
  # source's recorded digest and stays covered by --verify-md5.
  def test_a_placed_copy_inherits_the_source_digest
    File.binwrite(File.join(@dir, 'posts', '7.png'), 'x')
    pool = File.join(@dir, 'pools', '42_s')
    FileUtils.mkdir_p(pool)
    File.binwrite(File.join(pool, '7.png'), 'x')
    @archiver.db.record_file(post_id: 7, path: 'posts/7.png', dir: 'posts', md5: 'abc123', ext: 'png', bytes: 1)
    @archiver.scan_output_dir

    location = Archiver::Location.new(pool, 42)
    placed = @archiver.place_existing_media(7, location, 'png')
    refute_nil placed
    assert_equal '7.png', File.basename(placed)

    assert_equal 'abc123', @archiver.db.known_md5(7)
  end

  # --- reading a large archive ----------------------------------------------

  # Dropping straight to one exiftool per sidecar would turn a seconds-long pass
  # over a large archive into an hours-long one, so a batch that will not read is
  # retried smaller first.
  def test_a_failed_sidecar_batch_is_retried_smaller
    @archiver.instance_variable_set(:@sidecar_index, {})
    batch = Array.new(8) { |i| ["/sidecars/#{i}.xmp", "k#{i}"] }
    sizes = []

    responder = lambda do |paths|
      sizes << paths.size
      if paths.size > 2
        ['', 'Argument list too long', failing_status]
      else
        [JSON.generate(paths.map { |path| { 'SourceFile' => path } }), '', passing_status]
      end
    end
    with_capture3(responder) do
      assert @archiver.index_sidecar_batch(batch), 'a smaller batch works, so the index is kept'
    end

    assert_operator sizes.size, :>, 1, 'the batch was retried at a smaller size'
    assert_equal 8, sizes.first, 'it starts with the whole batch'
    assert_operator sizes.min, :<=, 2, 'and shrinks until it fits'
    assert_equal 8, @archiver.instance_variable_get(:@sidecar_index).size,
                 'every sidecar still ends up indexed'
  end

  def test_a_sidecar_batch_that_cannot_be_read_at_all_is_reported
    batch = Array.new(8) { |i| ["/sidecars/#{i}.xmp", "k#{i}"] }
    with_capture3(->(_paths) { ['', 'boom', failing_status] }) do
      refute @archiver.index_sidecar_batch(batch), 'the caller has to fall back to single reads'
    end
  end

  def test_an_empty_sidecar_batch_is_a_no_op
    assert @archiver.index_sidecar_batch([])
  end

  # --- cache growth ---------------------------------------------------------

  def test_stale_api_cache_pages_are_pruned
    cache = File.join(@dir, 'cache')
    FileUtils.mkdir_p(cache)
    fresh = File.join(cache, 'api_posts_aaa_p1.json')
    stale = File.join(cache, 'api_posts_bbb_p1.json')
    File.write(fresh, '[]')
    File.write(stale, '[]')
    old = Time.now - (Archiver::CACHE_MAX_AGE_DAYS * 86_400) - 60
    File.utime(old, old, stale)

    @archiver.prune_stale_cache

    assert File.exist?(fresh), 'a recent page is kept'
    refute File.exist?(stale), 'a page past its maximum age is dropped'
  end

  def test_cache_pruning_can_be_switched_off
    cache = File.join(@dir, 'cache')
    FileUtils.mkdir_p(cache)
    stale = File.join(cache, 'api_posts_ccc_p1.json')
    File.write(stale, '[]')
    old = Time.now - (Archiver::CACHE_MAX_AGE_DAYS * 86_400) - 60
    File.utime(old, old, stale)

    no_prune = E621Archiver.new(output_dir: @dir, db_path: nil, cache_dir: cache, cache_max_age: 0)
    no_prune.prune_stale_cache

    assert File.exist?(stale)
  end

  # --- the media index is shared between workers ----------------------------

  def test_the_media_index_survives_concurrent_placement
    @archiver.define_singleton_method(:write_sidecar) { |_m, _p| :unrated }
    @archiver.define_singleton_method(:download_media) do |_url, output, _id, _md5, thread_idx: nil|
      File.binwrite(output, 'x')
      true
    end

    stats = process(count: 20, threads: 4)

    assert_equal 20, stats.downloaded_files
    assert_equal 20, @archiver.existing_post_ids.size, 'every placed file is indexed exactly once'
    assert_equal 20, @archiver.existing_posts.size
  end

  private

  # Stands in for an exiftool process over a batch of sidecars. The responder is
  # handed the paths, which is what decides whether a batch fits. The block is
  # the code under test.
  def with_capture3(responder, &body)
    @archiver.define_singleton_method(:exiftool_read) { |paths| responder.call(paths) }
    body.call
  end

  def passing_status
    Object.new.tap { |o| o.define_singleton_method(:success?) { true } }
  end

  def failing_status
    Object.new.tap { |o| o.define_singleton_method(:success?) { false } }
  end

  def webrick
    require 'webrick'
    server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    (@servers ||= []) << server
    yield server if block_given?
    Thread.new { server.start }
    sleep 0.4
    server
  end

  def shutdown_servers
    Array(@servers).each(&:shutdown)
    @servers = nil
  end
end
