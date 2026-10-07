# frozen_string_literal: true

require_relative 'test_helper'

class ArchiveDbTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'sub', 'rubichiver-database.db')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def db(path = @path, site: 'e621')
    store = ArchiveDb.new(path, site: site)
    assert store.load
    store
  end

  def test_records_survive_a_reopen
    store = db
    store.record_pool(id: 56_729, name: 'They Said', slug: 'they-said', post_count: 5, active: true)
    store.record_pool_post(56_729, 111)
    store.record_file(post_id: 111, pool_id: 56_729, path: 'pools/56729_they-said/111.png',
                      dir: 'pools/56729_they-said', md5: 'abc', ext: 'png', bytes: 10, sidecar: true)
    store.close

    reopened = db
    assert_equal 'they-said', reopened.pool(56_729)['slug']
    assert_equal 'They Said', reopened.pool(56_729)['name']
    assert_equal [111], reopened.pool_member_ids(56_729)
    assert_equal 'abc', reopened.file(111, 56_729)['md5']
    assert_equal 'pools/56729_they-said', reopened.file(111, 56_729)['dir']
    reopened.close
  end

  def test_flat_and_pool_entries_for_one_post_coexist
    store = db
    store.record_file(post_id: 7, path: 'posts/7.png', dir: 'posts')
    store.record_file(post_id: 7, pool_id: 99, path: 'pools/99_x/7.png', dir: 'pools/99_x')

    assert_equal 2, store.files.size
    assert_equal [nil, 99], [store.file(7)['pool'], store.file(7, 99)['pool']]
  end

  # The layout migration moves loose root files into posts/; their rows follow.
  # Pool rows are untouched: only the archive root moved.
  def test_relocate_root_files_points_dot_rows_at_posts
    store = db
    store.record_file(post_id: 7, path: '7.png', dir: '.', md5: 'abc', ext: 'png', bytes: 10, sidecar: true)
    store.record_file(post_id: 7, pool_id: 99, path: 'pools/99_x/7.png', dir: 'pools/99_x')

    assert_equal 1, store.relocate_root_files('posts')

    row = store.file(7)
    assert_equal 'posts/7.png', row['path']
    assert_equal 'posts', row['dir']
    assert_equal 'abc', row['md5'], 'everything else about the row is preserved'
    assert_equal 'pools/99_x/7.png', store.file(7, 99)['path'], 'pool rows are untouched'

    assert_equal 0, store.relocate_root_files('posts'), 'a second pass is a no-op'
  end

  def test_newest_record_wins
    store = db
    store.record_file(post_id: 7, path: '7.png', dir: '.', sidecar: false)
    store.record_file(post_id: 7, path: '7.png', dir: '.', sidecar: true)

    assert_equal '7.png', store.file(7)['path'], 'the second record replaces the first'
    assert_equal 1, store.file(7)['sidecar']
    assert_equal 1, store.files.size
  end

  def test_sidecar_update_lands_on_the_file_entry
    store = db
    store.record_file(post_id: 7, pool_id: 3, path: 'a/7.png', dir: 'a')
    store.record_sidecar(7, 3)

    assert_equal 1, store.file(7, 3)['sidecar']
  end

  # A directory that the pool slug has never been recorded for is created,
  # including its parent directories.
  def test_missing_parent_directory_is_created
    store = db
    store.record_file(post_id: 1, path: '1.png', dir: '.')
    assert store.persistent?
    store.close
  end

  # The slug names the directory a bundle already lives in, so once one is
  # recorded a later, different name must not move it.
  def test_pool_slug_is_frozen_on_first_sight
    store = db
    store.record_pool(id: 42, name: 'They Said', slug: 'they-said', post_count: 3, active: true)
    store.record_pool(id: 42, name: 'They Said (renamed)', slug: 'they-said-renamed', post_count: 9)

    assert_equal 'they-said', store.pool(42)['slug']
    assert_equal 'They Said (renamed)', store.pool(42)['name'], 'the display name is still updated'
    assert_equal 9, store.pool(42)['post_count']
  end

  # The raw record is ~2.8 KB of JSON per post and the posts row is rewritten on
  # every run for every post rediscovered, so it must not be re-serialised when
  # nothing changed. That is what keeps it in its own row.
  def test_an_unchanged_post_does_not_rewrite_its_raw_record
    store = db
    store.record_post(post_id: 7, raw_json: '{"id":7,"v":1}', tags: { 'general' => %w[cat] })
    first = store.raw_captured_at(7)

    store.record_post(post_id: 7, raw_json: '{"id":7,"v":1}', tags: { 'general' => %w[cat] })

    assert_equal first, store.raw_captured_at(7), 'a rediscovered post must not rewrite the blob'
  end

  # But a recache must refresh it, or a field that changed upstream would never
  # be seen. Asserted on content rather than the timestamp, which only has
  # second resolution.
  def test_a_recache_refreshes_the_raw_record
    store = db
    store.record_post(post_id: 7, raw_json: '{"id":7,"v":1}')

    store.record_post(post_id: 7, refresh: true, raw_json: '{"id":7,"v":2}')

    assert_equal 2, store.raw_post(7)['v']
  end

  # The raw response is the one thing in the schema that cannot be a projection
  # of something else, so it has to come back equivalent.
  def test_the_raw_response_survives_verbatim
    store = db
    payload = { 'id' => 7, 'files' => { 'meta' => { 'ext' => 'png' } },
                'stats' => { 'hotness' => 1.5 }, 'pools' => [59203],
                'tags' => { 'general' => %w[cat] } }
    store.record_post(post_id: 7, raw_json: JSON.generate(payload), md5: 'abc')

    assert_equal payload, store.raw_post(7)
  end

  # Nothing is lost even when no column models a field, which is the whole
  # reason the raw record exists: a site can add a key and it is still captured.
  def test_a_field_no_column_models_is_still_kept
    store = db
    store.record_post(post_id: 7, raw_json: JSON.generate('id' => 7, 'brand_new_field' => [1, 2]))

    assert_equal [1, 2], store.raw_post(7)['brand_new_field']
    assert_nil store.post(7)['brand_new_field']
  end

  # The "has" object is worth querying, so it is both columns and json. SQLite
  # stores booleans as 0/1, which is how every flag column reads back.
  def test_the_capability_flags_land_in_columns_and_as_json
    store = db
    store.record_post(post_id: 7, has: { 'parent' => true, 'children' => false,
                                         'active_children' => false, 'notes' => true, 'sample' => true })

    row = store.post(7)
    assert_equal 1, row['has_parent']
    assert_equal 1, row['has_notes']
    assert_equal 1, row['has_sample']
    assert_equal 0, row['has_active_children']
    assert_equal true, row['has']['notes']
  end

  # Gelbooru spells the same fact as a flat flag instead of an object.
  def test_has_notes_is_recorded_from_either_spelling
    store = db
    store.record_post(post_id: 7, has_notes: true)
    assert_equal 1, store.post(7)['has_notes']

    store.record_post(post_id: 8, has: { 'notes' => true })
    assert_equal 1, store.post(8)['has_notes']
  end

  # Every rendition on offer, one row each, so a sample or preview can be
  # fetched later without asking the site again.
  def test_every_file_variant_is_recorded
    store = db
    store.record_post(post_id: 7, md5: 'abc', ext: 'jpg', variants: [
                        { 'variant' => 'original', 'format' => 'jpg', 'width' => 1457,
                          'height' => 1032, 'url' => 'https://static.example/orig.jpg' },
                        { 'variant' => 'sample', 'format' => 'jpg', 'width' => 1200,
                          'height' => 850, 'url' => 'https://static.example/s.jpg' },
                        { 'variant' => 'sample', 'format' => 'webp', 'width' => 1200,
                          'height' => 850, 'url' => 'https://static.example/s.webp' }
                      ])

    variants = store.post_variants(7)
    assert_equal 3, variants.size
    assert_equal %w[original sample sample], variants.map { |v| v['variant'] }
    assert_equal %w[jpg jpg webp], variants.map { |v| v['format'] }
    assert_equal 'https://static.example/s.webp', variants.last['url']
  end

  # Re-recording must replace, not accumulate: a post that loses a rendition
  # upstream should not keep a stale row.
  def test_variants_are_replaced_rather_than_accumulated
    store = db
    2.times do |n|
      store.record_post(post_id: 7, refresh: true, variants: [
                          { 'variant' => 'sample', 'format' => 'jpg', 'url' => "https://x/#{n}.jpg" }
                        ])
    end

    assert_equal 1, store.post_variants(7).size
    assert_equal 'https://x/1.jpg', store.post_variants(7).first['url']
  end

  # Child ids in site order, rather than only the count.
  def test_children_are_recorded_in_order
    store = db
    store.record_post(post_id: 7, child_count: 2, children: [111, 222])

    assert_equal [111, 222], store.post_children(7)
    assert_equal 2, store.post(7)['child_count']
  end

  # A post with no children must clear a stale list, or a removed child would
  # read as still linked forever.
  def test_children_are_cleared_when_the_post_loses_them
    store = db
    store.record_post(post_id: 7, children: [111])
    store.record_post(post_id: 7, refresh: true, children: [])

    assert_empty store.post_children(7)
  end

  # Gelbooru's lifecycle and ownership words have no e621 equivalent but are the
  # only record that a post was withdrawn upstream.
  def test_gelbooru_lifecycle_fields_are_recorded
    store = db(@path, site: 'gelbooru')
    store.record_post(post_id: 9, status: 'active', creator_id: 55, creator_anonymous: false,
                      num_notes: 2, is_held: false, is_pending: true)

    row = store.post(9)
    assert_equal 'active', row['status']
    assert_equal 55, row['creator_id']
    assert_equal 2, row['num_notes']
    assert_equal 0, row['is_held']
    assert_equal 1, row['is_pending']
  end

  def test_post_detail_round_trips
    store = db
    store.record_post(
      post_id: 7, rating: 'e', created_at: '2026-07-28T02:20:59.721-04:00',
      updated_at: '2026-09-05T05:48:47.595-04:00', change_seq: 78_347_368, md5: 'abc',
      ext: 'png', bytes: 439_072, width: 1634, height: 2000, uploader_id: 267_695,
      uploader_name: 'easytogooglename', description: "a note\nwith a break",
      page_url: 'https://e621.net/posts/7', score_up: 64, score_down: -4, score_total: 60,
      fav_count: 91, comment_count: 1, child_count: 0, flags: { 'pending' => false },
      stats: { 'fav_count' => 91 }, locked_tags: [],
      tags: { 'general' => %w[anthro cat], 'artist' => %w[sukiya] },
      sources: ['https://www.pixiv.net/artworks/1', '']
    )

    row = store.post(7)
    assert_equal 'e', row['rating']
    assert_equal 'easytogooglename', row['uploader_name']
    assert_equal 1634, row['width']
    assert_equal 78_347_368, row['change_seq']
    assert_equal "a note\nwith a break", row['description']
    assert_equal({ 'pending' => false }, row['flags'])
    assert_equal [], row['locked_tags']
    assert_equal({ 'general' => %w[anthro cat], 'artist' => %w[sukiya] }, store.post_tags(7))
    assert_equal ['https://www.pixiv.net/artworks/1'], store.sources(7), 'blank sources are dropped'
    assert_equal 3, store.tag_count
  end

  # A normal run must not rewrite the tag rows of a post it already has, or every
  # run pays for the whole archive.
  def test_recording_a_known_post_does_not_rewrite_its_tags
    store = db
    store.record_post(post_id: 7, tags: { 'general' => %w[a b] })
    store.record_post(post_id: 7, tags: { 'general' => %w[b c] })

    assert_equal({ 'general' => %w[a b] }, store.post_tags(7))
    assert_equal 2, store.tag_count
  end

  # --recache-post-tags is how a tag changed upstream gets corrected.
  def test_refresh_replaces_the_tags_of_a_known_post
    store = db
    store.record_post(post_id: 7, tags: { 'general' => %w[a b] })
    store.record_post(post_id: 7, tags: { 'general' => %w[b c] }, refresh: true)

    assert_equal({ 'general' => %w[b c] }, store.post_tags(7))
    assert_equal 2, store.tag_count
  end

  # The summary counts come from the counters table, not from COUNT(*) over
  # millions of rows, so they have to track every write path.
  def test_counters_track_posts_and_tags
    store = db
    store.record_post(post_id: 7, tags: { 'general' => %w[a b] })
    store.record_post(post_id: 8, tags: { 'general' => %w[c] })

    assert_equal 2, store.post_count
    assert_equal 3, store.tag_count
    assert_equal 2, store.counter_value('posts')
    assert_equal 3, store.counter_value('tags')
  end

  # A normal run re-records every post it rediscovers; the counters must not
  # move when nothing changed, or the summary drifts a little every week.
  def test_re_recording_a_post_does_not_move_the_counters
    store = db
    store.record_post(post_id: 7, tags: { 'general' => %w[a b] })
    store.record_post(post_id: 7, tags: { 'general' => %w[a b] })

    assert_equal 1, store.post_count
    assert_equal 2, store.tag_count
  end

  # A recache that changes the tag list adjusts by the delta, not by the new
  # total, or a post that loses a tag inflates the count forever.
  def test_a_refresh_adjusts_the_tag_counter_by_the_delta
    store = db
    store.record_post(post_id: 7, tags: { 'general' => %w[a b c] })
    store.record_post(post_id: 7, tags: { 'general' => %w[a] }, refresh: true)

    assert_equal 1, store.tag_count
  end

  # A database from before the counters table gains seeded counters on open,
  # with everything it already held intact.
  def test_a_pre_counter_database_is_seeded_on_open
    legacy_path = File.join(@dir, 'nocounters.db')
    legacy = SQLite3::Database.new(legacy_path)
    legacy.execute_batch(<<~SQL)
      CREATE TABLE posts (site TEXT NOT NULL, post_id INTEGER NOT NULL, PRIMARY KEY (site, post_id)) WITHOUT ROWID;
      CREATE TABLE tags (site TEXT NOT NULL, post_id INTEGER NOT NULL, category TEXT NOT NULL, tag TEXT NOT NULL,
        PRIMARY KEY (site, post_id, category, tag)) WITHOUT ROWID;
      INSERT INTO posts (site, post_id) VALUES ('e621', 1), ('e621', 2);
      INSERT INTO tags (site, post_id, category, tag) VALUES ('e621', 1, 'general', 'a'),
        ('e621', 1, 'general', 'b'), ('e621', 2, 'general', 'c');
    SQL
    legacy.close

    store = db(legacy_path, site: 'e621')

    assert_equal 2, store.post_count
    assert_equal 3, store.tag_count
    assert_equal 2, store.counter_value('posts')
    assert_equal 3, store.counter_value('tags')
    store.close
  end

  # Downloads that exhausted every round are recorded for --retry-failed,
  # oldest failure first.
  def test_download_failures_round_trip
    store = db
    store.record_download_failure(7, attempts: 30, error: 'Connection reset by peer')
    store.record_download_failure(8, attempts: 30, error: 'response body incomplete')

    assert_equal [7, 8], store.failed_download_ids
    assert_equal 2, store.failed_download_count
    store.clear_download_failure(7)

    assert_equal [8], store.failed_download_ids
    assert_equal 1, store.failed_download_count
  end

  # A post that keeps failing keeps its latest timestamp, attempt count and
  # error rather than accumulating rows.
  def test_recording_a_failure_twice_keeps_the_latest
    store = db
    store.record_download_failure(7, attempts: 30, error: 'reset')
    store.record_download_failure(7, attempts: 30, error: 'eof')

    assert_equal [7], store.failed_download_ids
    row = store.send(:select_one, 'SELECT error FROM download_failures WHERE site = ? AND post_id = ?',
                     ['e621', 7])
    assert_equal 'eof', row['error']
  end

  def test_tag_types_persist_between_opens
    store = db
    store.remember_tag_types('cat' => 'general', 'sukiya' => 'artist')
    store.close

    assert_equal({ 'cat' => 'general', 'sukiya' => 'artist' }, db.tag_types)
  end

  # Both archivers share one database file, so the site column has to keep them
  # from reading each other's rows.
  def test_sites_do_not_see_each_others_rows
    e621 = db(site: 'e621')
    e621.record_file(post_id: 1, path: '1.png', dir: '.')
    e621.record_post(post_id: 1, rating: 'e')
    e621.close

    gelbooru = db(site: 'gelbooru')
    assert_empty gelbooru.files
    assert_nil gelbooru.post(1)

    gelbooru.record_file(post_id: 1, path: '1.jpg', dir: '.')
    gelbooru.close

    assert_equal '1.png', db(site: 'e621').file(1)['path']
    assert_equal '1.jpg', db(site: 'gelbooru').file(1)['path']
  end

  # SQLite refuses to open a non-database file, which must not stop a run: the
  # bad file is kept for inspection and a new store is started.
  def test_a_corrupt_file_is_quarantined_and_replaced
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "this is not a database\n" * 40)

    store = db
    assert store.persistent?
    store.record_file(post_id: 1, path: '1.png', dir: '.')
    assert_equal 1, store.file(1)['post']
    store.close

    quarantined = Dir.glob("#{@path}.corrupt-*")
    assert_equal 1, quarantined.size, 'the unreadable file is kept, not deleted'
  end

  # A store that cannot be written is degraded, never fatal, and stays queryable
  # so the run still completes on the filesystem alone.
  # Corruption discovered part-way through a run — after the store is open and
  # records have been written — must degrade the same way, not abort the run.
  def test_corruption_mid_session_is_survivable
    store = db
    store.record_file(post_id: 1, path: '1.png', dir: '.')
    assert_equal 1, store.files.size

    store.close
    # Corrupt a page in the middle, leaving the header intact: this is what a bad
    # disk looks like, and it is only noticed when a statement touches the page.
    File.open(@path, 'r+b') { |file| file.seek(2048); file.write('Z' * 2048) }

    reopened = db
    assert reopened.persistent?, 'a damaged store is replaced, not fatal'
    reopened.record_file(post_id: 2, path: '2.png', dir: '.')
    assert_equal '2.png', reopened.file(2)['path']
    assert_empty reopened.files.map { |row| row['path'] }.grep('1.png'), 'the damaged record is gone'
    reopened.close
  end

  def test_unwritable_store_is_not_fatal
    blocker = File.join(@dir, 'blocked')
    File.write(blocker, 'not a directory')
    store = db(File.join(blocker, 'rubichiver-database.db'))
    refute store.persistent?
    store.record_file(post_id: 1, path: '1.png', dir: '.')
    assert_equal 1, store.file(1)['post'], 'records stay queryable even if they cannot be persisted'
  end

  def test_disabled_store_answers_without_writing
    store = ArchiveDb.new(nil)
    assert store.load
    refute store.enabled?
    store.record_file(post_id: 1, path: '1.png', dir: '.')
    assert_empty store.files
  end

  def test_missing_database_replays_as_empty
    assert_empty db.files
    assert_equal 0, db.record_count
    assert_nil db.pool(1)
  end

  def test_forget_file_drops_the_entry
    store = db
    store.record_file(post_id: 7, path: '7.png', dir: '.')
    store.forget_file(7)

    assert_nil store.file(7)
    assert_equal 0, store.files.size
  end

  # A store that was never explicitly loaded still has to record; a silently
  # inert database is the worst possible failure mode here.
  def test_a_store_records_without_an_explicit_load
    store = ArchiveDb.new(@path, site: 'e621')
    store.record_file(post_id: 1, path: '1.png', dir: '.')
    store.close
    assert_equal 1, db.file(1)['post']
  end

  def test_writes_from_many_threads_all_land
    store = db
    threads = 4.times.map do |t|
      Thread.new do
        25.times { |i| store.record_file(post_id: (t * 25) + i, path: "#{(t * 25) + i}.png", dir: '.') }
      end
    end
    threads.each(&:join)
    store.close

    assert_equal 100, db.files.size
  end

  # A bulk import appends to the write-ahead log faster than it drains, and an
  # oversized log turns every commit into a long journal flush on a slow disk.
  # Observed blocking in xlog_wait_on_iclog with a 340 MB log.
  def test_a_large_write_load_does_not_leave_a_large_write_ahead_log
    store = db
    2000.times { |i| store.record_file(post_id: i, path: "#{i}.png", dir: '.') }
    200.times { |i| store.record_post(post_id: i, rating: 's', tags: { 'general' => %w[cat dog] }) }
    store.close

    wal = File.size?("#{@path}-wal")
    assert wal.nil? || wal < ArchiveDb::WAL_CHECKPOINT_BYTES,
           "the log should be folded back, not left at #{wal} bytes"
    assert_equal 2000, db.files.size, 'and the records are all still there'
  end

  # Checkpointing mid-run, at a commit boundary, is what keeps a long import from
  # stalling on a journal flush.
  def test_the_log_is_checkpointed_at_a_commit_boundary
    store = db
    1000.times { |i| store.record_file(post_id: i, path: "#{i}.png", dir: '.') }
    store.instance_variable_set(:@batch_statements, ArchiveDb::BATCH_STATEMENTS)
    store.send(:flush_batch)
    wal = File.size?("#{@path}-wal")
    store.close

    assert wal.nil? || wal < ArchiveDb::WAL_CHECKPOINT_BYTES
  end

  # A crash in the middle of a tag list must never leave a torn set behind.
  def test_a_post_write_commits_as_a_unit
    store = db
    100.times { |i| store.record_post(post_id: i, tags: { 'general' => (1..50).map { |t| "t#{t}" } }) }

    100.times do |i|
      assert_equal 50, store.post_tags(i)['general'].size, "post #{i} must be complete, never torn"
    end
  end

  # A database made by an earlier version gains the columns it is missing, and
  # keeps everything it already held.
  def test_an_older_database_migrates_in_place
    legacy_path = File.join(@dir, 'legacy.db')
    legacy = SQLite3::Database.new(legacy_path)
    legacy.execute_batch(<<~SQL)
      CREATE TABLE posts (
        site TEXT NOT NULL, post_id INTEGER NOT NULL, rating TEXT,
        PRIMARY KEY (site, post_id)
      ) WITHOUT ROWID;
      INSERT INTO posts (site, post_id, rating) VALUES ('e621', 7, 'e');
    SQL
    legacy.close

    store = db(legacy_path)
    store.record_post(post_id: 8, rating: 's', tags: { 'general' => %w[cat] })

    assert_equal 'e', store.post(7)['rating'], 'the old row survives the migration'
    assert_equal 0, store.post(8)['uncategorized']
    store.close

    reopened = db(legacy_path)
    assert_equal 0, reopened.post(7)['uncategorized'].to_i, 'the new column reads back as a number'
    reopened.close
  end

  def test_post_pools_is_the_reverse_of_pool_membership
    store = db
    store.record_pool_post(42, 7)
    store.record_pool_post(99, 7)

    assert_equal [42, 99], store.post_pools(7)
    assert_empty store.post_pools(8)
  end

  def test_size_on_disk_reports_the_store_and_its_wal
    store = db
    store.record_file(post_id: 1, path: '1.png', dir: '.')
    assert_operator store.size_on_disk, :>, 0
    assert_match(/rubichiver-database\.db/, store.inspect)
  end
end
