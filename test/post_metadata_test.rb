# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/stub_http'

# What rubichiver captures about a post, and what it writes alongside the file.
# The archive database is the queryable record; the XMP sidecar is the portable
# one, and it has to carry enough to identify and re-find the artwork offline.
class PostMetadataTest < Minitest::Test
  include StubHttp

  def setup
    @dir = Dir.mktmpdir
    @db_path = File.join(@dir, 'rubichiver-database.db')
    @e621 = E621Archiver.new(output_dir: @dir, db_path: @db_path, username: 'tester', api_key: 'k')
    @gelbooru = GelbooruArchiver.new(output_dir: @dir, db_path: @db_path, api_key: 'k', user_id: '1')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  E621_POST = {
    'id' => 6_577_648,
    'created_at' => '2026-07-28T02:20:59.721-04:00',
    'updated_at' => '2026-09-05T05:48:47.595-04:00',
    'change_seq' => 78_347_368,
    'files' => { 'meta' => { 'md5' => '56b20c4c', 'ext' => 'jpg', 'size' => 439_072, 'duration' => nil },
                 'original' => { 'width' => 1634, 'height' => 2000, 'url' => 'https://x/1.jpg' } },
    'uploader_id' => 267_695,
    'uploader_name' => 'easytogooglename',
    'approver_id' => 347_033,
    'stats' => { 'score' => { 'up' => 64, 'down' => -4, 'total' => 60 },
                 'fav_count' => 91, 'comment_count' => 1 },
    'flags' => { 'pending' => false, 'flagged' => false },
    'has' => { 'children' => false },
    'relationships' => { 'parent_id' => nil, 'children' => [] },
    'pools' => [],
    'rating' => 'e',
    'locked_tags' => [],
    'sources' => ['https://www.pixiv.net/artworks/104093434'],
    'description' => 'updater note',
    'tags' => { 'general' => %w[anthro cat], 'artist' => %w[sukiya], 'copyright' => %w[cave_story],
                'character' => %w[skoll], 'species' => %w[lagomorph], 'invalid' => [],
                'meta' => %w[hi_res], 'contributor' => [], 'lore' => [] }
  }.freeze

  GELBOORU_POST = {
    'id' => '5', 'rating' => 'safe', 'date' => '1_759_060_800', 'source' => 'https://a.test/1, https://b.test/2',
    'width' => 800, 'height' => 600, 'file_size' => 1234, 'md5' => 'abc', 'image' => '5.png',
    'creator_name' => 'somebody', 'uploader_id' => '7', 'up' => '5', 'down' => '0', 'score' => '5',
    'comments' => '2', 'file_url' => 'https://x/5.png',
    'tags' => '1girl solo style:gothic metadata:absurd_res metadata:highres invalid_tag:junk ' \
              'artist:foo copyright:bar character:baz species:fox 2020 rating:safe'
  }.freeze

  # --- e621 ----------------------------------------------------------------

  def test_e621_detail_is_captured
    @e621.record_post_metadata(E621_POST)
    @e621.db.close
    row = @e621.db.post(6_577_648)

    assert_equal 'e', row['rating']
    assert_equal '2026-07-28T02:20:59.721-04:00', row['created_at']
    assert_equal '2026-09-05T05:48:47.595-04:00', row['updated_at']
    assert_equal 78_347_368, row['change_seq'], 'the revalidation key'
    assert_equal '56b20c4c', row['md5']
    assert_equal 439_072, row['bytes']
    assert_equal 1634, row['width']
    assert_equal 2000, row['height']
    assert_equal 267_695, row['uploader_id']
    assert_equal 'easytogooglename', row['uploader_name']
    assert_equal 347_033, row['approver_id']
    assert_equal 'updater note', row['description']
    assert_equal 91, row['fav_count']
    assert_equal 64, row['score_up']
    assert_equal(-4, row['score_down'])
    assert_equal 1, row['comment_count']
    assert_equal({ 'pending' => false, 'flagged' => false }, row['flags'])
  end

  def test_e621_sources_and_tags_are_queryable
    @e621.record_post_metadata(E621_POST)
    @e621.db.close

    assert_equal ['https://www.pixiv.net/artworks/104093434'], @e621.db.sources(6_577_648)
    tags = @e621.db.post_tags(6_577_648)
    assert_equal %w[sukiya], tags['artist']
    assert_equal %w[cave_story], tags['copyright']
    assert_equal %w[hi_res], tags['meta']
  end

  def test_e621_keywords_cover_every_tag_exactly_once
    keywords = @e621.extract_post_tags(E621_POST)
    raw = E621_POST['tags'].values.flatten

    assert_equal raw.size, keywords.size
    assert_equal raw.sort, keywords.map { |k| k.split(':', 2).last }.sort
  end

  def test_e621_artist_is_a_creator_field
    assert_equal %w[sukiya], @e621.post_artists(E621_POST)
  end

  def test_e621_page_url_and_sources
    assert_equal 'https://e621.net/posts/6577648', @e621.post_page_url(E621_POST)
    assert_equal ['https://www.pixiv.net/artworks/104093434'], @e621.post_sources(E621_POST)
  end

  # --- Gelbooru ------------------------------------------------------------

  def test_gelbooru_metadata_and_style_tags_are_not_dropped
    categories = @gelbooru.categorized_post_tags(GELBOORU_POST)

    assert_equal %w[gothic absurd_res highres], categories['metadata'],
                 'style:/metadata: tags used to vanish from the sidecar entirely'
    assert_equal %w[junk], categories['invalid']
  end

  def test_gelbooru_keywords_include_the_previously_dropped_tags
    keywords = @gelbooru.extract_post_tags(GELBOORU_POST)

    assert_includes keywords, 'metadata:gothic'
    assert_includes keywords, 'metadata:highres'
    assert_includes keywords, 'invalid:junk'
    assert_includes keywords, 'artist:foo'
    refute_includes keywords, 'rating:safe', 'the rating is not a keyword'
  end

  def test_gelbooru_tag_type_six_is_invalid_not_metadata
    assert_equal 'invalid', GelbooruArchiver::TAG_TYPE_MAP[6]
    assert_equal 'metadata', GelbooruArchiver::TAG_TYPE_MAP[7]
    assert_includes Archiver::TAG_CATEGORIES, 'metadata',
                    'the category has to be one the sidecar writer iterates'
  end

  def test_gelbooru_detail_is_captured
    @gelbooru.record_post_metadata(GELBOORU_POST)
    @gelbooru.db.close
    row = @gelbooru.db.post(5)

    assert_equal 'safe', row['rating']
    assert_equal 800, row['width']
    assert_equal 1234, row['bytes']
    assert_equal 'somebody', row['uploader_name']
    assert_equal 5, row['score_up']
    assert_equal 2, row['comment_count']
    assert_equal '2025-09-28T12:00:00Z', row['created_at'], 'the Unix date is normalised for querying'
  end

  def test_gelbooru_sources_are_split_on_commas
    assert_equal ['https://a.test/1', 'https://b.test/2'], @gelbooru.post_sources(GELBOORU_POST)
  end

  # --- tag category lookups survive between runs ----------------------------

  def test_resolved_tag_types_are_persisted_for_the_next_run
    first = GelbooruArchiver.new(output_dir: @dir, db_path: @db_path, api_key: 'k', user_id: '1')
    first.prime_tag_types({ 'gothic' => 'metadata' })
    first.instance_variable_set(:@tag_type_cache, { 'gothic' => 'metadata', 'resolved' => 'artist' })
    first.flush_tag_types
    first.db.close

    second = GelbooruArchiver.new(output_dir: @dir, db_path: @db_path, api_key: 'k', user_id: '1')
    second.db.load
    second.load_cached_tag_types

    assert_equal 'metadata', second.tag_type_cache['gothic']
    assert_equal 'artist', second.tag_type_cache['resolved']
  end

  def test_a_resolved_tag_type_is_used_for_keywords
    archiver = GelbooruArchiver.new(output_dir: @dir, db_path: nil, api_key: 'k', user_id: '1')
    archiver.prime_tag_types({ 'sukiya' => 'artist' })

    assert_includes archiver.extract_post_tags(GELBOORU_POST.merge('tags' => '1girl sukiya')), 'artist:sukiya'
  end

  # --- a stored record must say the same thing as the live post --------------

  # The offline repair path rebuilds a post-shaped hash from the database and
  # feeds it to sidecar_payload. If that hash says anything different from the
  # API response, the repair writes a wrong sidecar.
  def test_a_rebuilt_e621_post_says_what_the_api_said
    @e621.record_post_metadata(E621_POST)
    synthetic = @e621.stored_post(E621_POST['id'])

    refute_nil synthetic, 'the stored record rebuilds'
    live = @e621.sidecar_payload(E621_POST)
    rebuilt = @e621.sidecar_payload(synthetic)

    assert_equal live.keys, rebuilt.keys
    Archiver::SIDECAR_FIELDS.each_key do |field|
      assert @e621.sidecar_field_matches?(rebuilt[field], live[field], field),
             "#{field} differs: #{live[field].inspect[0, 80]} vs #{rebuilt[field].inspect[0, 80]}"
    end
  end

  def test_a_rebuilt_gelbooru_post_validates_against_the_live_one
    @gelbooru.record_post_metadata(GELBOORU_POST)
    synthetic = @gelbooru.stored_post(5)

    refute_nil synthetic
    rebuilt = @gelbooru.sidecar_payload(synthetic)
    live = @gelbooru.sidecar_payload(GELBOORU_POST)

    Archiver::SIDECAR_FIELDS.each_key do |field|
      assert @gelbooru.sidecar_field_matches?(rebuilt[field], live[field], field),
             "#{field} differs: #{live[field].inspect[0, 80]} vs #{rebuilt[field].inspect[0, 80]}"
    end
  end

  def test_a_post_with_no_stored_record_does_not_rebuild
    assert_nil @e621.stored_post(999_999)
  end

  # A flat tag list never had categories, so rebuilding keywords off the
  # database's 'general' filing would write guesses. Nothing is rebuilt, and
  # the post stays waiting for a categorised answer.
  def test_a_flat_post_is_not_rebuilt_from_the_database
    flat = { 'id' => 1, 'rating' => 's', 'tags' => %w[cat dog] }
    @e621.record_post_metadata(flat)

    assert_nil @e621.stored_post(1)
  end

  # --- flat tag lists ------------------------------------------------------

  # mode=basic gives no categories. The sidecar is withheld rather than filled
  # with guessed ones, but the tags are still recorded.
  def test_flat_tags_are_recorded_but_not_guessed_into_keywords
    flat = { 'id' => 1, 'rating' => 's', 'tags' => %w[cat dog] }

    assert_empty @e621.extract_post_tags(flat)
    assert_equal({ 'general' => %w[cat dog] }, @e621.categorized_post_tags(flat))
    assert_equal :uncategorized, @e621.send(:sidecar_payload, flat)
  end
end
