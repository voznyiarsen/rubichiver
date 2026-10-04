# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/stub_http'

# Pool bundling: a post found through a tag query that belongs to a pool pulls
# the whole pool in, and every member lands in one bundle directory.
class PoolExpansionTest < Minitest::Test
  include StubHttp

  POOL_ID = 56_729
  POOL_IDS = [6_403_790, 6_403_810, 6_476_912].freeze

  def setup
    @dir = Dir.mktmpdir
    @cache = File.join(@dir, 'cache')
    @archiver = E621Archiver.new(
      output_dir: @dir, cache_dir: @cache,
      username: 'tester', api_key: 'key', rate_limit: 1000
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def post(id, pools: [POOL_ID])
    {
      'id' => id,
      'rating' => 's',
      'pools' => pools,
      'tags' => { 'general' => ['cat'] },
      'files' => {
        'original' => { 'url' => "https://cdn.e621.net/data/#{id}.png" },
        'meta' => { 'ext' => 'png', 'md5' => Digest::MD5.hexdigest('bytes') }
      }
    }
  end

  def pool_body(ids: POOL_IDS, name: 'They_Said_[SaturnSamo]', count: nil)
    {
      'id' => POOL_ID, 'name' => name, 'post_ids' => ids,
      'post_count' => count || ids.size, 'is_active' => true
    }
  end

  # Serves the pool definition and the id-batched post lookups.
  def stub_pool_api(posts: nil)
    posts ||= POOL_IDS.to_h { |id| [id, post(id, pools: [])] }

    stub_http_get(@archiver) do |uri, _n|
      if uri.path.start_with?('/pools/')
        StubHttp::Response.new(200, JSON.generate(pool_body))
      else
        params = query_params(uri)
        ids = params.fetch('tags').sub('id:', '').split(',').map(&:to_i)
        body = ids.filter_map { |id| posts[id] }
        StubHttp::Response.new(200, JSON.generate(body))
      end
    end
  end

  # --- pool metadata -------------------------------------------------------

  def test_post_locations_point_at_the_bundle_directory
    stub_pool_api
    location = @archiver.post_locations(post(6_476_912)).first

    assert_equal POOL_ID, location.pool_id
    assert_equal File.join(@dir, 'pools', '56729_they-said-saturnsamo'), location.directory
  end

  # A post in no pool stays in posts/.
  def test_post_without_a_pool_lands_in_posts
    location = @archiver.post_locations(post(1, pools: [])).first

    assert_nil location.pool_id
    assert_equal File.join(@dir, 'posts'), location.directory
  end

  def test_a_post_in_two_pools_gets_one_location_each
    stub_pool_api
    locations = @archiver.post_locations(post(6_476_912, pools: [POOL_ID, 12_345]))

    assert_equal [12_345, POOL_ID], locations.map(&:pool_id).sort
    assert_equal 2, locations.map(&:directory).uniq.size
  end

  def test_slug_is_stable_even_when_the_pool_is_renamed
    stub_pool_api
    first = @archiver.pool_directory(POOL_ID)

    # Second run: the store answers, so no request is needed at all.
    calls = stub_http_get(@archiver) { |_uri, _n| flunk 'pool directory should come from the store' }
    second = @archiver.pool_directory(POOL_ID)

    assert_equal first, second
    assert_empty calls
  end

  def test_slug_is_filesystem_safe
    assert_equal 'they-said-saturnsamo', @archiver.slugify('They_Said_[SaturnSamo]')
    assert_equal 'a-b', @archiver.slugify('  A///B  ')
    assert_equal 'pool', @archiver.slugify('!!!')
    assert_equal 'pool', @archiver.slugify(nil)
    assert_equal 60, @archiver.slugify('x' * 200).length
  end

  # v1 wraps the pool in an envelope and calls the id list "posts".
  def test_v1_pool_envelope_is_accepted
    stub_http_get(@archiver) do |_uri, _n|
      StubHttp::Response.new(200, JSON.generate('pool' => pool_body.merge('posts' => ['6403790', '6403810'],
                                                                         'post_ids' => nil)))
    end

    pool = @archiver.fetch_pool(POOL_ID)

    assert_equal [6_403_790, 6_403_810], pool['post_ids']
  end

  def test_pool_id_mismatch_is_rejected
    stub_http_get(@archiver) { StubHttp::Response.new(200, JSON.generate(pool_body.merge('id' => 999))) }

    assert_nil @archiver.fetch_pool(POOL_ID)
  end

  def test_failed_pool_lookup_is_not_cached
    responses = [StubHttp::Response.new(404), StubHttp::Response.new(200, JSON.generate(pool_body))]
    stub_http_get(@archiver) { responses.shift }

    assert_nil @archiver.fetch_pool(POOL_ID)
    assert_equal POOL_ID, @archiver.fetch_pool(POOL_ID)['id'], 'a retry should still work'
  end

  # --- expansion -----------------------------------------------------------

  def test_expansion_yields_every_member_pinned_to_the_pool
    stub_pool_api

    yielded = []
    @archiver.expand_pools(post(6_476_912)) { |sibling| yielded << sibling }

    assert_equal POOL_IDS.sort, yielded.map { |p| p['id'] }.sort
    assert_equal [POOL_ID], yielded.map { |p| p[Archiver::POOL_MEMBER] }.uniq
  end

  def test_expansion_happens_once_per_pool
    calls = stub_pool_api

    3.times { @archiver.expand_pools(post(6_476_912, pools: [POOL_ID])) { |_s| nil } }

    pool_requests = calls.count { |call| call[:uri].path.start_with?('/pools/') }
    assert_equal 1, pool_requests
  end

  # A post pulled in by a pool must not drag in the other pools it belongs to,
  # or bundling would cascade.
  def test_a_pool_member_does_not_expand_its_own_pools
    calls = stub_pool_api
    member = post(6_403_790).merge(Archiver::POOL_MEMBER => POOL_ID)

    @archiver.expand_pools(member) { |_s| flunk 'must not cascade' }

    assert_empty calls
  end

  def test_expansion_is_skipped_when_pools_are_disabled
    calls = stub_pool_api
    @archiver.pools_enabled = false

    @archiver.expand_pools(post(6_476_912)) { |_s| flunk 'pools are disabled' }

    assert_empty calls
    assert_equal [File.join(@dir, 'posts')], @archiver.post_locations(post(6_476_912)).map(&:directory)
  end

  def test_blacklisted_members_are_left_out
    blacklist = File.join(@dir, 'bl.txt')
    File.write(blacklist, "general:cat\n")
    @archiver.blacklist_file = blacklist
    stub_pool_api

    yielded = []
    @archiver.expand_pools(post(6_476_912)) { |sibling| yielded << sibling }

    assert_empty yielded
  end

  # A gap in the pool is reported rather than silently producing a short bundle.
  def test_posts_missing_from_the_api_response_are_reported
    stub_pool_api(posts: { 6_403_790 => post(6_403_790) })
    yielded = []

    @archiver.expand_pools(post(6_476_912)) { |sibling| yielded << sibling }

    assert_equal [6_403_790], yielded.map { |p| p['id'] }
  end

  def test_pool_metadata_and_membership_are_recorded
    stub_pool_api

    @archiver.expand_pools(post(6_476_912)) { |_s| nil }

    recorded = @archiver.db.pool(POOL_ID)
    assert_equal 'they-said-saturnsamo', recorded['slug']
    assert_equal 3, recorded['post_count']
    assert_equal POOL_IDS.sort, @archiver.db.pool_member_ids(POOL_ID).sort
  end

  def test_pool_directory_is_derived_from_the_stored_slug
    stub_pool_api
    @archiver.pool_directory(POOL_ID)
    calls = stub_http_get(@archiver) { |_uri, _n| flunk 'no further pool request expected' }

    assert_equal File.join(@dir, 'pools', '56729_they-said-saturnsamo'), @archiver.pool_directory(POOL_ID)
    assert_empty calls
  end

  def test_a_pool_with_no_id_is_reported_not_fatal
    stub_http_get(@archiver) do |uri, _n|
      if uri.path.start_with?('/pools/')
        StubHttp::Response.new(200, JSON.generate(pool_body(ids: [], count: 0)))
      else
        StubHttp::Response.new(200, JSON.generate([]))
      end
    end
    yielded = []

    @archiver.expand_pools(post(6_476_912)) { |sibling| yielded << sibling }

    assert_empty yielded
  end
end
