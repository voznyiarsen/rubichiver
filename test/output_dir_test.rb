# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/stub_http'

class OutputDirTest < Minitest::Test
  include StubHttp

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build_archiver(**overrides)
    E621Archiver.new(
      **{ output_dir: @dir, username: 'tester', api_key: 'key', rate_limit: 1000 }.merge(overrides)
    )
  end

  def posts_dir
    File.join(@dir, 'posts')
  end

  def root_location
    Archiver::Location.new(posts_dir, nil)
  end

  # A .part file left behind by a killed run must never be indexed as a
  # finished download, or the post is skipped forever and gets a sidecar
  # attached to a truncated file.
  def test_scan_ignores_and_removes_part_files
    FileUtils.mkdir_p(posts_dir)
    File.write(File.join(posts_dir, '1234.png.part'), 'partial')
    File.write(File.join(posts_dir, '99.png'), 'complete')

    archiver = build_archiver
    posts = archiver.send(:scan_output_dir)

    assert_equal [File.join(posts_dir, '99.png')], posts.values
    assert_equal [99], archiver.existing_post_ids
    refute File.exist?(File.join(posts_dir, '1234.png.part')), 'stale .part file should be removed'
  end

  def test_scan_ignores_sidecars_and_hidden_files
    FileUtils.mkdir_p(posts_dir)
    File.write(File.join(posts_dir, '7.png'), 'x')
    File.write(File.join(posts_dir, '7.xmp'), 'x')
    File.write(File.join(posts_dir, '8.png.tmp'), 'x')
    File.write(File.join(@dir, '.rubichiver.lock'), 'x')
    File.write(File.join(@dir, '.rubichiver.db'), '{}')

    posts = build_archiver.send(:scan_output_dir)

    assert_equal [File.join(posts_dir, '7.png')], posts.values
  end

  # Files already inside a bundle are indexed under that bundle's location, so
  # a later run knows where they live.
  # A sidecar on its own must not be mistaken for an archived download, or a
  # post whose media was deleted would never be fetched again.
  def test_a_lone_sidecar_is_not_indexed_as_media
    FileUtils.mkdir_p(posts_dir)
    File.write(File.join(posts_dir, '7.xmp'), 'sidecar only')

    archiver = build_archiver
    assert_empty archiver.scan_output_dir
    assert_empty archiver.existing_post_ids
    assert_nil archiver.existing_media(7, root_location)
  end

  def test_scan_indexes_files_inside_collection_directories
    pool_dir = File.join(@dir, 'pools', '56729_they_said')
    FileUtils.mkdir_p(pool_dir)
    FileUtils.mkdir_p(posts_dir)
    File.write(File.join(pool_dir, '6403790.png'), 'x')
    File.write(File.join(posts_dir, '6403790.png'), 'x')

    archiver = build_archiver
    posts = archiver.scan_output_dir

    assert_equal 2, posts.size
    assert_equal File.join(posts_dir, '6403790.png'),
                 archiver.existing_media(6_403_790, root_location)
    assert_equal File.join(pool_dir, '6403790.png'),
                 archiver.existing_media(6_403_790, Archiver::Location.new(pool_dir, 56_729))
  end

  def test_scan_keeps_part_files_during_dry_run
    FileUtils.mkdir_p(posts_dir)
    part = File.join(posts_dir, '1234.png.part')
    File.write(part, 'partial')

    build_archiver(dry_run: true).send(:scan_output_dir)

    assert File.exist?(part), 'dry run must not delete anything'
  end

  # Loose files left at the archive root by the old layout move into posts/ on
  # startup, and their database rows follow them. Anything that is not a post
  # file — the lock, the database, the cache — stays where it is.
  def test_loose_root_files_are_migrated_into_posts
    File.write(File.join(@dir, '1234.png'), 'media')
    File.write(File.join(@dir, '1234.xmp'), 'sidecar')
    File.write(File.join(@dir, '.rubichiver.lock'), 'x')

    archiver = build_archiver
    archiver.db.load
    archiver.db.record_file(post_id: 1234, path: '1234.png', dir: '.',
                            md5: 'abc', ext: 'png', bytes: 5, sidecar: true)
    archiver.send(:migrate_loose_files_to_posts)

    assert File.file?(File.join(posts_dir, '1234.png'))
    assert File.file?(File.join(posts_dir, '1234.xmp'))
    assert File.file?(File.join(@dir, '.rubichiver.lock')), 'the lock must stay at the root'
    refute File.exist?(File.join(@dir, '1234.png'))
    row = archiver.db.file(1234)
    assert_equal 'posts/1234.png', row['path']
    assert_equal 'posts', row['dir']

    posts = archiver.scan_output_dir
    assert_equal [File.join(posts_dir, '1234.png')], posts.values
  end

  def test_migration_leaves_pool_bundles_and_dotfiles_alone
    pool_dir = File.join(@dir, 'pools', '56729_they_said')
    FileUtils.mkdir_p(pool_dir)
    File.write(File.join(pool_dir, '6403790.png'), 'x')
    File.write(File.join(@dir, 'tags.txt'), 'solo')

    archiver = build_archiver
    archiver.db.load
    archiver.send(:migrate_loose_files_to_posts)

    assert File.file?(File.join(pool_dir, '6403790.png'))
    assert File.file?(File.join(@dir, 'tags.txt'))
    refute Dir.exist?(posts_dir), 'no loose files means no posts/ directory is created'
  end

  def test_second_run_cannot_take_the_output_dir_lock
    first = build_archiver
    first.send(:acquire_run_lock)

    second = build_archiver
    error = assert_raises(SystemExit) { second.send(:acquire_run_lock) }
    assert_equal 1, error.status
  end

  def test_lock_is_released_for_the_next_run
    first = build_archiver
    first.send(:acquire_run_lock)
    first.instance_variable_get(:@lock_file).close

    build_archiver.send(:acquire_run_lock)
  end

  def test_dry_run_writes_no_caches
    cache = File.join(@dir, 'cache')
    archiver = build_archiver(dry_run: true, cache_dir: cache)

    stub_http_get(archiver) { StubHttp::Response.new(200, JSON.generate([{ 'id' => 1, 'rating' => 's',
                                                                       'tags' => { 'general' => ['cat'] } }])) }

    result = archiver.api_search_posts(['solo'], 1, force: true)
    archiver.record_post_metadata({ 'id' => 1, 'rating' => 's', 'tags' => { 'general' => ['cat'] } })

    assert result.ok?
    refute File.exist?(cache), 'dry run must not create the cache directory'
    refute archiver.db.enabled?, 'a dry run must not open the archive database'
  end

  def test_cache_is_written_when_not_dry_running
    cache = File.join(@dir, 'cache')
    archiver = build_archiver(cache_dir: cache)
    stub_http_get(archiver) { StubHttp::Response.new(200, JSON.generate([{ 'id' => 1 }])) }

    archiver.api_search_posts(['solo'], 1, force: true)

    assert File.exist?(File.join(cache, "api_posts_#{archiver.query_hash(['solo'])}_p1.json"))
  end
end

class TagQueryFileTest < Minitest::Test
  class RecordingProcessor
    attr_reader :enqueued

    def initialize
      @enqueued = []
    end

    def enqueue(post)
      @enqueued << post
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @tags_file = File.join(@dir, 'tags.txt')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_comments_and_blank_lines_are_skipped
    File.write(@tags_file, "# a comment\n\n  \nsolo\nfurry canine\n  # indented comment\n")

    queries = collect_queries

    assert_equal [%w[solo], %w[furry canine]], queries
  end

  def test_empty_tags_file_yields_no_queries
    File.write(@tags_file, "# only comments\n\n")

    assert_empty collect_queries
  end

  private

  def collect_queries
    seen = []
    archiver = E621Archiver.new(output_dir: @dir, tags_file: @tags_file, username: 'u', api_key: 'k')
    archiver.define_singleton_method(:fetch_all_posts_for_query) do |query_tags, _seen, _stats|
      seen << query_tags
      []
    end

    processor = RecordingProcessor.new
    archiver.send(:process_tag_queries, processor, Stats.new)
    seen
  end
end

class SidecarIndexTest < Minitest::Test
  # exiftool validates the format of the file it reads, so the stand-in media
  # files have to be real images.
  PNG = Base64.decode64(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
  )

  def setup
    @dir = Dir.mktmpdir
    @archiver = GelbooruArchiver.new(
      output_dir: @dir, api_key: 'key', user_id: '1',
      cache_dir: File.join(@dir, 'cache')
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def post(id, rating: 'safe')
    { 'id' => id, 'rating' => rating, 'tags' => "cat#{id}", 'file_url' => "https://x/#{id}.png" }
  end

  def posts_dir
    File.join(@dir, 'posts')
  end

  def root_location
    Archiver::Location.new(posts_dir, nil)
  end

  def write_media(id, directory = nil)
    directory ||= posts_dir
    FileUtils.mkdir_p(directory)
    path = File.join(directory, "#{id}.png")
    File.binwrite(path, PNG)
    path
  end

  def test_index_is_built_once_and_answers_sidecar_readings
    [11, 12].each do |id|
      media = write_media(id)
      assert @archiver.write_sidecar(media, post(id))
    end
    @archiver.scan_output_dir

    @archiver.send(:build_sidecar_index)

    root = root_location
    assert_equal 2, @archiver.instance_variable_get(:@sidecar_index).size
    assert @archiver.sidecar_reading(11, root).is_a?(Hash)
    assert_nil @archiver.sidecar_reading(999, root)
  end

  def test_sidecar_valid_uses_the_index
    media = write_media(13)
    @archiver.write_sidecar(media, post(13))
    @archiver.scan_output_dir
    @archiver.send(:build_sidecar_index)

    root = root_location
    assert @archiver.sidecar_valid?(post(13), root)
    refute @archiver.sidecar_valid?(post(13, rating: 'explicit'), root), 'rating drift must invalidate the sidecar'
  end

  def test_index_stays_empty_when_nothing_is_on_disk_yet
    @archiver.existing_posts = {}
    @archiver.send(:build_sidecar_index)

    assert_empty @archiver.instance_variable_get(:@sidecar_index)
    refute @archiver.sidecar_valid?(post(15), root_location)
  end

  def test_sidecar_temp_file_is_not_left_in_the_media_directory
    media = write_media(14)

    @archiver.write_sidecar(media, post(14))

    leftovers = Dir.children(posts_dir).select { |name| name.end_with?('.part', '.tmp') }
    assert_empty leftovers
  end
end
