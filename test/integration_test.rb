# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/stub_http'

# Drives the whole run loop — lock, output scan, sidecar index, worker pool,
# downloads, sidecars and the summary — against a stubbed transport.
class FullRunTest < Minitest::Test
  include StubHttp

  PNG = Base64.decode64(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
  )

  def setup
    @dir = Dir.mktmpdir
    @tags_file = File.join(@dir, 'tags.txt')
    File.write(@tags_file, "# queries\nsolo\n")
    @archiver = build_archiver
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build_archiver(notify_url: nil)
    E621Archiver.new(
      output_dir: @dir,
      cache_dir: File.join(@dir, 'cache'),
      tags_file: @tags_file,
      credentials_file: File.join(@dir, 'credentials.txt'),
      blacklist_file: File.join(@dir, 'blacklist.txt'),
      username: 'tester',
      api_key: 'key',
      rate_limit: 1000,
      notify_url: notify_url
    )
  end

  def post(id)
    {
      'id' => id,
      'rating' => 's',
      'tags' => { 'general' => ['cat'], 'artist' => ['bob'] },
      'files' => {
        'original' => { 'url' => "https://cdn.e621.net/data/#{id}.png" },
        'meta' => { 'ext' => 'png', 'md5' => Digest::MD5.hexdigest(PNG) }
      }
    }
  end

  def stub_transport(ids: [4242])
    stub_http_get(@archiver) do |uri, _n|
      if uri.host == 'e621.net'
        StubHttp::Response.new(200, JSON.generate(ids.map { |id| post(id) }))
      else
        StubHttp::Response.new(200, PNG)
      end
    end
  end

  # The lock is released when the process exits, so close it by hand between
  # in-process runs.
  def release_lock
    lock = @archiver.instance_variable_get(:@lock_file)
    lock&.close
  end

  def run_archiver(archiver = @archiver)
    error = assert_raises(SystemExit) { archiver.run }
    error.status
  end

  def test_run_downloads_writes_sidecars_and_reports_success
    stub_transport

    assert_equal 0, run_archiver
    assert File.exist?(File.join(@dir, 'posts', '4242.png'))
    assert File.exist?(File.join(@dir, 'posts', '4242.xmp'))
    posts_children = Dir.exist?(File.join(@dir, 'posts')) ? Dir.children(File.join(@dir, 'posts')) : []
    assert_empty posts_children.select { |name| name.end_with?('.part') }
  end

  # A run bracketed by a start and a finish alert is the only way to tell a
  # process that died part way from one that is merely slow, so both must be
  # sent, in that order, from a run that actually completed.
  def test_a_full_run_announces_both_its_start_and_its_finish
    archiver = build_archiver(notify_url: 'https://ntfy.example.com/rubichiver')
    sent = []
    archiver.define_singleton_method(:post_notification) { |payload| sent << payload }
    stub_http_get(archiver) do |uri, _n|
      if uri.host == 'e621.net'
        StubHttp::Response.new(200, JSON.generate([post(4242)]))
      else
        StubHttp::Response.new(200, PNG)
      end
    end

    assert_equal 0, (assert_raises(SystemExit) { archiver.run }).status

    assert_equal ['e621 archive starting', 'e621 run finished'], sent.map { |p| p['title'] }
    assert_equal [3, 3], sent.map { |p| p['priority'] }
    assert_equal 'rubichiver', sent.first['topic']
    assert_includes sent.last['message'], 'downloaded: 1'
  end

  # A run that cannot start must not claim it started. The lock is taken before
  # the announcement, so a second concurrent run on the same archive exits
  # quietly instead of paging you about a run that never worked.
  def test_a_run_locked_out_of_the_archive_sends_no_start_alert
    stub_transport
    assert_equal 0, run_archiver

    sent = []
    contender = build_archiver(notify_url: 'https://ntfy.example.com/rubichiver')
    contender.define_singleton_method(:post_notification) { |payload| sent << payload }
    stub_http_get(contender) { StubHttp::Response.new(200, JSON.generate([post(4243)])) }

    assert_equal 1, (assert_raises(SystemExit) { contender.run }).status

    assert_empty sent, 'a run that could not take the lock must not announce a start'
  end

  def test_second_run_skips_posts_whose_sidecar_is_current
    stub_transport
    assert_equal 0, run_archiver
    release_lock

    @archiver = build_archiver
    stub_transport

    assert_equal 0, run_archiver
    assert_equal 1, @archiver.existing_posts.size
  end

  def test_missing_sidecar_is_regenerated_without_redownloading
    stub_transport
    assert_equal 0, run_archiver
    release_lock
    File.delete(File.join(@dir, 'posts', '4242.xmp'))
    downloaded = File.read(File.join(@dir, 'posts', '4242.png'))

    @archiver = build_archiver
    calls = stub_transport

    assert_equal 0, run_archiver
    assert_equal downloaded, File.read(File.join(@dir, 'posts', '4242.png'))
    assert File.exist?(File.join(@dir, 'posts', '4242.xmp'))
    refute calls.any? { |call| call[:uri].host == 'cdn.e621.net' }, 'should not download again'
  end

  def test_dry_run_writes_nothing
    dry = build_archiver
    dry.instance_variable_set(:@dry_run, true)
    stub_http_get(dry) do |uri, _n|
      if uri.host == 'e621.net'
        StubHttp::Response.new(200, JSON.generate([post(4242)]))
      else
        StubHttp::Response.new(200, PNG)
      end
    end

    assert_equal 0, run_archiver(dry)
    refute File.exist?(File.join(@dir, 'posts', '4242.png'))
    refute File.exist?(File.join(@dir, 'cache'))
  end
end

# End to end: a post found by a tag query drags its whole pool in, and the
# bundle directory holds every member with its own sidecar.
class PoolBundleRunTest < Minitest::Test
  include StubHttp

  PNG = Base64.decode64(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
  )
  POOL_ID = 56_729
  POOL_IDS = [6_403_790, 6_403_810, 6_476_912].freeze

  def setup
    @dir = Dir.mktmpdir
    @tags_file = File.join(@dir, 'tags.txt')
    File.write(@tags_file, "solo\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def post(id, pools: [])
    {
      'id' => id, 'rating' => 's', 'pools' => pools,
      'tags' => { 'general' => ['cat'] },
      'files' => {
        'original' => { 'url' => "https://cdn.e621.net/data/#{id}.png" },
        'meta' => { 'ext' => 'png', 'md5' => Digest::MD5.hexdigest(PNG) }
      }
    }
  end

  def build_archiver
    E621Archiver.new(
      output_dir: @dir,
      cache_dir: File.join(@dir, 'cache'),
      tags_file: @tags_file,
      credentials_file: File.join(@dir, 'credentials.txt'),
      username: 'tester', api_key: 'key', rate_limit: 1000
    )
  end

  # Search returns one post that belongs to a pool; the pool lookup and the
  # id-batched member lookups are served from the same stub.
  def stub_transport
    stub_http_get(@archiver) do |uri, _n|
      if uri.host == 'cdn.e621.net'
        StubHttp::Response.new(200, PNG)
      elsif uri.path.start_with?('/pools/')
        StubHttp::Response.new(200, JSON.generate(
                                           'id' => POOL_ID, 'name' => 'They_Said_[SaturnSamo]',
                                           'post_ids' => POOL_IDS, 'post_count' => POOL_IDS.size,
                                           'is_active' => true
                                         ))
      else
        query = query_params(uri)['tags']
        # Only the tag query matches "solo"; id lookups return the members.
        ids = query.start_with?('id:') ? query.sub('id:', '').split(',').map(&:to_i) : [6_476_912]
        body = ids.map { |id| post(id, pools: id == 6_476_912 ? [POOL_ID] : []) }
        StubHttp::Response.new(200, JSON.generate(body))
      end
    end
  end

  def run_archiver(archiver = @archiver)
    error = assert_raises(SystemExit) { archiver.run }
    error.status
  end

  def bundle_dir
    File.join(@dir, 'pools', '56729_they-said-saturnsamo')
  end

  def test_a_found_post_pulls_its_whole_pool_into_one_directory
    @archiver = build_archiver
    stub_transport

    assert_equal 0, run_archiver

    POOL_IDS.each do |id|
      assert File.exist?(File.join(bundle_dir, "#{id}.png")), "missing #{id}.png in the bundle"
      assert File.exist?(File.join(bundle_dir, "#{id}.xmp")), "missing #{id}.xmp in the bundle"
    end
    refute File.exist?(File.join(@dir, 'posts', '6403790.png')), 'members should live in the bundle, not in posts/'
  end

  def test_the_run_report_counts_pools_and_records_the_bundle
    @archiver = build_archiver
    stub_transport
    run_archiver

    report = @archiver.build_report(Stats.new, 1.0)
    assert_equal 1, report[:pools_expanded]
    assert_equal 1, @archiver.pools_expanded_count

    assert_equal 3, @archiver.db.pool_member_ids(POOL_ID).size
    assert_equal 'they-said-saturnsamo', @archiver.db.pool(POOL_ID)['slug']
    assert_equal POOL_IDS.sort, @archiver.db.files.map { |f| f['post'] }.sort
    assert(@archiver.db.files.all? { |f| f['sidecar'] == 1 })
  end

  # A second visit must not refetch anything: the bundle is already complete.
  def test_a_second_run_downloads_nothing_more
    @archiver = build_archiver
    stub_transport
    assert_equal 0, run_archiver
    lock = @archiver.instance_variable_get(:@lock_file)
    lock&.close

    @archiver = build_archiver
    calls = stub_transport
    assert_equal 0, run_archiver

    assert_empty calls.select { |call| call[:uri].host == 'cdn.e621.net' }
  end

  # One member already archived in posts/ is linked into the bundle rather
  # than fetched a second time.
  def test_a_post_already_archived_elsewhere_is_placed_not_downloaded
    root_copy = File.join(@dir, 'posts', '6403790.png')
    FileUtils.mkdir_p(File.dirname(root_copy))
    File.write(root_copy, PNG)
    @archiver = build_archiver
    calls = stub_transport

    assert_equal 0, run_archiver

    bundle_copy = File.join(bundle_dir, '6403790.png')
    assert File.exist?(bundle_copy)
    assert_equal File.stat(root_copy).ino, File.stat(bundle_copy).ino, 'should be a link, not a second copy'
    assert_empty calls.select { |call| call[:uri].path == '/data/6403790.png' }
    assert_equal 2, @archiver.db.files.count { |f| f['post'] == 6_403_790 }, 'both locations are recorded'
  end

  def test_pool_bundling_can_be_switched_off
    FileUtils.mkdir_p(File.join(@dir, 'posts'))
    File.write(File.join(@dir, 'posts', '6403790.png'), PNG)
    @archiver = build_archiver
    @archiver.pools_enabled = false
    calls = stub_transport

    assert_equal 0, run_archiver

    assert_empty calls.select { |call| call[:uri].path.start_with?('/pools/') }
    assert File.exist?(File.join(@dir, 'posts', '6476912.png')), 'without bundling the post is archived in posts/'
  end

  def test_a_deleted_member_file_is_downloaded_again
    @archiver = build_archiver
    stub_transport
    run_archiver
    lock = @archiver.instance_variable_get(:@lock_file)
    lock&.close
    File.delete(File.join(bundle_dir, '6403810.png'))
    File.delete(File.join(bundle_dir, '6403810.xmp'))

    @archiver = build_archiver
    calls = stub_transport
    assert_equal 0, run_archiver

    assert File.exist?(File.join(bundle_dir, '6403810.png'))
    assert_equal 1, calls.count { |call| call[:uri].path == '/data/6403810.png' }
  end
end

class E621FetchIntegrationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @tags_file = File.join(@dir, 'tags.txt')
    File.write(@tags_file, "solo\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_e621_archiver_scan_existing_posts
    creds = File.join(@dir, 'creds.txt')
    File.write(creds, "USERNAME=tester\nAPI_KEY=key\n")
    File.write(File.join(@dir, '100.jpg'), 'fake')
    File.write(File.join(@dir, '101.png'), 'fake')

    archiver = E621Archiver.new(
      output_dir: @dir,
      credentials_file: creds,
      username: 'tester',
      api_key: 'key',
      tags_file: @tags_file
    )

    archiver.run

    # The run should fail because API key is fake, but we just test it doesn't crash
    # in unexpected ways. This is a smoke test.
  rescue SystemExit
    # expected - API call will fail with invalid credentials
  end
end

class GelbooruIntegrationTest < Minitest::Test
  PAGES = {
    1 => { '@attributes' => { 'count' => '3' }, 'post' => [
      { 'id' => '1', 'file_url' => 'https://x/1.jpg', 'md5' => 'a', 'tags' => 'cat dog', 'rating' => 'safe' },
      { 'id' => '2', 'file_url' => 'https://x/2.jpg', 'md5' => 'b', 'tags' => 'bird', 'rating' => 'questionable' }
    ]},
    2 => { '@attributes' => { 'count' => '3' }, 'post' => [
      { 'id' => '3', 'file_url' => 'https://x/3.jpg', 'md5' => 'c', 'tags' => 'fish', 'rating' => 'explicit' }
    ]},
    3 => { '@attributes' => { 'count' => '3' }, 'post' => [] }
  }.freeze

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build_archiver(blacklist_body, tags: ['solo'])
    bl_path = File.join(@dir, 'bl.txt')
    File.write(bl_path, blacklist_body)
    tags_file = File.join(@dir, 'tags.txt')
    File.write(tags_file, tags.join(' '))

    GelbooruArchiver.new(
      output_dir: @dir,
      api_key: 'k',
      user_id: '1',
      tags_file: tags_file,
      blacklist_file: bl_path,
      rate_limit: 1000
    )
  end

  def setup_stubbed_http(archiver)
    def archiver.http_get(uri, read_timeout: 60, headers: {})
      m = uri.query.match(/pid=(\d+)/)
      page = (m ? m[1].to_i : 0) + 1
      data = GelbooruIntegrationTest::PAGES[page] || { '@attributes' => { 'count' => '3' }, 'post' => [] }
      body = JSON.generate(data)
      res = Net::HTTPResponse.new('1.1', 200, 'OK')
      res.instance_variable_set(:@body, body)
      def res.body; @body; end
      def res.read_body; @body; end
      def res.is_a?(k); k == Net::HTTPSuccess || super; end
      res
    end

    def archiver.download_media(url, output_file, post_id, md5, thread_idx: nil)
      File.write(output_file, 'fake')
      true
    end

    def archiver.sidecar_valid?(post)
      false
    end

    def archiver.write_sidecar(media_file, post)
      true
    end
  end

  def test_gelbooru_fetch_collects_all_posts_across_pages
    archiver = build_archiver('')
    setup_stubbed_http(archiver)

    stats = Stats.new
    posts = archiver.fetch_all_posts_for_query(['solo'], Set.new, stats)
    assert_equal %w[1 2 3], posts.map { |p| p['id'] }.sort
    assert_equal 3, stats.total_posts
  end

  def test_gelbooru_fetch_applies_blacklist
    archiver = build_archiver("rating:explicit\n")
    setup_stubbed_http(archiver)

    stats = Stats.new
    posts = archiver.fetch_all_posts_for_query(['solo'], Set.new, stats)
    assert_equal %w[1 2], posts.map { |p| p['id'] }.sort
    assert_equal 1, stats.blacklisted_files
  end

  def test_gelbooru_fetch_dedups_across_calls
    archiver = build_archiver('')
    setup_stubbed_http(archiver)

    stats = Stats.new
    seen = Set.new
    archiver.fetch_all_posts_for_query(['solo'], seen, stats)
    second = archiver.fetch_all_posts_for_query(['solo'], seen, Stats.new)
    assert_empty second
  end
end
