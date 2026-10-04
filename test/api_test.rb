# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/stub_http'

class E621ApiShapeTest < Minitest::Test
  include StubHttp

  def setup
    @dir = Dir.mktmpdir
    @archiver = E621Archiver.new(
      output_dir: @dir, cache_dir: File.join(@dir, 'cache'),
      username: 'tester', api_key: 'key', rate_limit: 1000
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def respond_with(body)
    stub_http_get(@archiver) { StubHttp::Response.new(200, body) }
  end

  def test_v2_bare_array_is_accepted
    respond_with(JSON.generate([{ 'id' => 1 }, { 'id' => 2 }]))

    result = @archiver.api_search_posts(['solo'], 1, force: true)

    assert result.ok?
    assert_equal 2, result.posts.size
  end

  # e621 is mid-migration from { "posts": [...] } to a bare array; both shapes
  # have to keep working.
  def test_v1_wrapped_response_is_accepted
    respond_with(JSON.generate('posts' => [{ 'id' => 1 }]))

    result = @archiver.api_search_posts(['solo'], 1, force: true)

    assert result.ok?
    assert_equal 1, result.posts.size
  end

  # A shape we do not understand must not be reported as "no posts found".
  def test_unrecognised_shape_is_a_failure_not_an_empty_page
    respond_with(JSON.generate('unexpected' => { 'posts' => 'nope' }))

    result = @archiver.api_search_posts(['solo'], 1, force: true)

    refute result.ok?
    assert result.error
  end

  def test_unparsable_body_is_a_failure
    respond_with('not json at all')

    refute @archiver.api_search_posts(['solo'], 1, force: true).ok?
  end

  def test_http_error_is_a_failure
    stub_http_get(@archiver) { StubHttp::Response.new(403) }

    result = @archiver.api_search_posts(['solo'], 1, force: true)

    refute result.ok?
    assert_match(/403/, result.error)
  end

  def test_rate_limited_requests_are_retried
    @archiver.define_singleton_method(:retry_delay) { |_| 0 }
    responses = [StubHttp::Response.new(429), StubHttp::Response.new(200, JSON.generate([{ 'id' => 7 }]))]
    stub_http_get(@archiver) { responses.shift }

    result = @archiver.api_search_posts(['solo'], 1, force: true)

    assert result.ok?
    assert_equal 7, result.posts.first['id']
  end

  def test_retries_are_bounded
    @archiver.define_singleton_method(:retry_delay) { |_| 0 }
    calls = stub_http_get(@archiver) { StubHttp::Response.new(503) }

    result = @archiver.api_search_posts(['solo'], 1, force: true)

    refute result.ok?
    assert_equal Archiver::MAX_RETRIES, calls.size
  end

  def test_flat_tag_list_does_not_produce_mislabeled_keywords
    assert_empty @archiver.extract_post_tags('id' => 1, 'tags' => %w[cat dog])
  end

  def test_grouped_tags_are_prefixed_with_their_category
    tags = @archiver.extract_post_tags('id' => 1, 'tags' => { 'general' => %w[cat], 'artist' => %w[bob] })

    assert_equal ['general:cat', 'artist:bob'], tags
  end
end

class E621CacheFreshnessTest < Minitest::Test
  include StubHttp

  PAGE_LIMIT = E621Archiver::PAGE_LIMIT

  def setup
    @dir = Dir.mktmpdir
    @cache = File.join(@dir, 'cache')
    @query = ['solo']
    @archiver = E621Archiver.new(
      output_dir: @dir, cache_dir: @cache,
      username: 'tester', api_key: 'key', rate_limit: 1000
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def post(id)
    {
      'id' => id,
      'rating' => 's',
      'tags' => { 'general' => ['cat'] },
      'files' => {
        'original' => { 'url' => "https://cdn.e621.net/data/#{id}.png" },
        'meta' => { 'ext' => 'png', 'md5' => 'abc' }
      }
    }
  end

  def write_cache(page, posts)
    FileUtils.mkdir_p(@cache)
    path = @archiver.api_cache_path(@archiver.query_hash(@query), page)
    File.write(path, JSON.generate(posts))
  end

  def test_new_posts_on_page_one_mark_later_pages_stale
    assert @archiver.page_one_changed?(@query, [post(1)], [post(1), post(2)])
    assert @archiver.page_one_changed?(@query, nil, [post(1)])
    assert @archiver.page_one_changed?(@query, [], [post(1)])
    refute @archiver.page_one_changed?(@query, [post(1), post(2)], [post(1), post(2)])
  end

  # Regression: page 1 used to be compared against the cache entry the fetch had
  # just overwritten, so later pages were never refreshed and new posts were
  # silently dropped.
  def test_later_pages_are_refetched_when_page_one_changed
    write_cache(1, (1..(PAGE_LIMIT - 1)).map { |id| post(id) } + [post(999)])
    write_cache(2, [post(777)])

    stub_http_get(@archiver) do |uri, _n|
      page = query_params(uri)['page'].to_i
      ids = page == 1 ? (1..PAGE_LIMIT).to_a : [PAGE_LIMIT + 1, PAGE_LIMIT + 2]
      StubHttp::Response.new(200, JSON.generate(ids.map { |id| post(id) }))
    end

    posts = @archiver.fetch_all_posts_for_query(@query, Set.new, Stats.new)

    assert_equal PAGE_LIMIT + 2, posts.size
    refute_includes posts.map { |p| p['id'] }, 777, 'stale cached page must not be reused'
  end

  def test_cached_pages_are_reused_when_nothing_changed
    write_cache(1, (1..PAGE_LIMIT).to_a.map { |id| post(id) })
    write_cache(2, [post(777)])

    calls = stub_http_get(@archiver) do |uri, _n|
      page = query_params(uri)['page'].to_i
      ids = page == 1 ? (1..PAGE_LIMIT).to_a : []
      StubHttp::Response.new(200, JSON.generate(ids.map { |id| post(id) }))
    end

    posts = @archiver.fetch_all_posts_for_query(@query, Set.new, Stats.new)

    assert_equal PAGE_LIMIT + 1, posts.size
    assert_equal 1, calls.size, 'only page 1 should be fetched live'
    assert_includes posts.map { |p| p['id'] }, 777
  end

  def test_recache_batches_ids_into_one_request
    stub_http_get(@archiver) { StubHttp::Response.new(200, JSON.generate([post(1)])) }

    assert_equal Archiver::RECACHE_BATCH_SIZE, @archiver.recache_batch_size
    result = @archiver.fetch_posts_by_ids([1, 2, 3])

    assert result.ok?
    assert_equal 1, result.posts.size
  end

  def test_recache_leaves_no_api_cache_entries_behind
    stub_http_get(@archiver) { StubHttp::Response.new(200, JSON.generate([post(1)])) }

    @archiver.fetch_posts_by_ids([1, 2, 3])

    assert_empty Dir.glob(File.join(@cache, 'api_posts_*.json'))
  end
end

class E621RecacheTest < Minitest::Test
  include StubHttp

  def setup
    @dir = Dir.mktmpdir
    @cache = File.join(@dir, 'cache')
    @archiver = E621Archiver.new(
      output_dir: @dir, cache_dir: @cache,
      username: 'tester', api_key: 'key', rate_limit: 1000
    )
    FileUtils.mkdir_p(File.join(@dir, 'posts'))
    File.write(File.join(@dir, 'posts', '5.png'), 'x')
    File.write(File.join(@dir, 'posts', '6.png'), 'x')
    @archiver.scan_output_dir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_recache_refreshes_every_archived_post
    stub_http_get(@archiver) do |uri, _n|
      ids = query_params(uri)['tags'].sub('id:', '').split(',')
      StubHttp::Response.new(200, JSON.generate(ids.map { |id| { 'id' => id.to_i, 'rating' => 's',
                                                              'tags' => { 'general' => ['cat'] } } }))
    end

    @archiver.recache_all_post_tags
    @archiver.db.close

    assert_equal({ 'general' => %w[cat] }, @archiver.db.post_tags(5))
    assert_equal({ 'general' => %w[cat] }, @archiver.db.post_tags(6))
  end
end

class GelbooruRecacheTest < Minitest::Test
  include StubHttp

  def setup
    @dir = Dir.mktmpdir
    @cache = File.join(@dir, 'cache')
    @archiver = GelbooruArchiver.new(
      output_dir: @dir, cache_dir: @cache, api_key: 'key', user_id: '1', rate_limit: 1000
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def gelbooru_post(id)
    { 'id' => id.to_s, 'rating' => 'safe', 'tags' => "cat#{id}", 'file_url' => "https://x/#{id}.png",
      'md5' => 'abc', 'image' => "#{id}.png" }
  end

  def respond_to_post_index
    stub_http_get(@archiver) do |uri, _n|
      params = query_params(uri)
      post = gelbooru_post(params['id'])
      StubHttp::Response.new(200, JSON.generate('@attributes' => { 'count' => '1' }, 'post' => post))
    end
  end

  # Gelbooru has no comma-separated id lookup, so the shared batching would ask
  # for a post that cannot exist.
  def test_recache_uses_one_request_per_id
    calls = respond_to_post_index

    result = @archiver.fetch_posts_by_ids([5, 6])

    assert_equal 1, @archiver.recache_batch_size
    assert_equal 2, calls.size
    assert_equal %w[5 6], calls.map { |call| query_params(call[:uri])['id'] }.sort
    assert_equal %w[5 6], result.posts.map { |post| post['id'] }.sort
  end

  def test_recache_records_post_metadata
    FileUtils.mkdir_p(File.join(@dir, 'posts'))
    File.write(File.join(@dir, 'posts', '5.png'), 'x')
    File.write(File.join(@dir, 'posts', '6.png'), 'x')
    @archiver.scan_output_dir
    respond_to_post_index

    @archiver.recache_all_post_tags
    @archiver.db.close

    assert_equal 2, @archiver.db.post_count
    assert_equal 5, @archiver.db.post(5)['post_id']
  end

  def test_single_post_response_is_not_wrapped_twice
    assert_equal 1, @archiver.normalize_posts('@attributes' => {}, 'post' => gelbooru_post(1)).size
  end
end

class DownloadMediaTest < Minitest::Test
  include StubHttp

  BODY = 'the quick brown fox'

  def setup
    @dir = Dir.mktmpdir
    @archiver = E621Archiver.new(
      output_dir: @dir, username: 'tester', api_key: 'key', rate_limit: 1000
    )
    @archiver.define_singleton_method(:retry_delay) { |_| 0 }
    @output = File.join(@dir, '1.png')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def respond_with(code, body = '')
    stub_http_get(@archiver) { StubHttp::Response.new(code, body) }
  end

  def part_files
    Dir.children(@dir).select { |name| name.end_with?('.part') }
  end

  def test_matching_md5_is_written_to_the_output_file
    respond_with(200, BODY)

    assert @archiver.download_media('https://x/1.png', @output, 1, Digest::MD5.hexdigest(BODY))
    assert_equal BODY, File.read(@output)
    assert_empty part_files
  end

  # A truncated file must not survive as something the next run indexes.
  def test_md5_mismatch_fails_and_leaves_no_partial_file
    respond_with(200, BODY)

    refute @archiver.download_media('https://x/1.png', @output, 1, 'wrong')
    refute File.exist?(@output)
    assert_empty part_files
  end

  def test_missing_md5_is_accepted
    respond_with(200, BODY)

    assert @archiver.download_media('https://x/1.png', @output, 1, nil)
    assert_equal BODY, File.read(@output)
  end

  def test_http_error_is_retried_then_reported
    calls = respond_with(404)

    refute @archiver.download_media('https://x/1.png', @output, 1, Digest::MD5.hexdigest(BODY))
    assert_equal Archiver::MAX_RETRIES, calls.size
    assert_empty part_files
  end

  def test_interrupted_run_does_not_download
    @archiver.interrupted = true
    calls = respond_with(200, BODY)

    refute @archiver.download_media('https://x/1.png', @output, 1, nil)
    assert_empty calls
    assert_empty part_files
  end
end

# A redirect in the middle of a download has to be followed rather than written
# out as the 302 body.
class DownloadRedirectTest < Minitest::Test
  class RedirectingHTTP
    Get = Class.new do
      def initialize(*_args); end
      def []=(*_args); end
    end

    attr_accessor :use_ssl, :open_timeout, :read_timeout

    def initialize(*_args); end

    def request(_request)
      response =
        if RedirectingHTTP.redirects.zero?
          RedirectingHTTP.instance_variable_set(:@redirects, 1)
          StubHttp::Response.new(302, '', '/final.png')
        else
          StubHttp::Response.new(200, 'payload')
        end
      # Net::HTTP yields the response to the block and returns the response,
      # not the block's value.
      yield response
      response
    end

    def self.redirects
      @redirects ||= 0
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @archiver = E621Archiver.new(
      output_dir: @dir, username: 'tester', api_key: 'key', rate_limit: 1000
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_redirect_is_followed_and_only_the_final_body_is_kept
    real = Net.send(:remove_const, :HTTP)
    Net.send(:const_set, :HTTP, RedirectingHTTP)
    RedirectingHTTP.instance_variable_set(:@redirects, 0)
    output = File.join(@dir, '1.png')

    begin
      assert @archiver.download_media('https://x/1.png', output, 1, Digest::MD5.hexdigest('payload'))
      assert_equal 'payload', File.read(output)
    ensure
      Net.send(:remove_const, :HTTP)
      Net.send(:const_set, :HTTP, real)
    end
  end
end
