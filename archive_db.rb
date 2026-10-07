# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require 'monitor'
begin
  require 'sqlite3'
rescue LoadError
  raise LoadError, "rubichiver needs the sqlite3 gem to open its archive database.\n" \
                   'Install it with: gem install sqlite3'
end

# Durable record of what the archive holds, and of everything the site knows
# about each post.
#
# The filesystem stays authoritative for file *contents*; this store records
# *provenance* and *detail* — which post produced which file, which directory it
# lives in, which pool it was bundled for, whether its sidecar was current when
# it was written, and the full metadata the API returned (sources, dates,
# uploader, dimensions, score, categorized tags). It exists so the archive can
# be queried and repaired when the filesystem and the memory of past runs
# disagree: a deleted file, a renamed directory, a hand-copied archive, a stale
# sidecar.
#
# Storage is SQLite. Earlier revisions used a JSON Lines journal to stay
# stdlib-only; that constraint no longer applies, and SQLite buys real querying
# (`sqlite3 /mnt/hdd/rubichiver-database.db "select ..."`), indexed tag lookups
# and integrity guarantees that a hand-rolled append file cannot offer.
#
# Every statement is serialised behind one mutex, because the sqlite3 gem's
# connection is not thread-safe and downloads land on several workers at once.
# WAL plus `synchronous = NORMAL` keeps commits to a WAL append, so a SIGKILL
# cannot lose a record; only an OS-level crash can. Writes are batched into a
# transaction and flushed every BATCH_STATEMENTS statements or BATCH_SECONDS
# seconds, and on close. A store that cannot be opened is never fatal — the
# archiver warns and falls back to an in-memory one so the run still completes
# and the filesystem remains the source of truth.
class ArchiveDb
  # Where the store lives unless --db says otherwise. Both sites share it, so
  # one archive can be queried as a whole.
  DEFAULT_PATH = ENV['RUBICHIVER_DB'] || '/mnt/hdd/rubichiver-database.db'
  SCHEMA_VERSION = 1

  # A post with no pool lives in posts/. SQLite permits NULL in a PRIMARY KEY
  # column, which would silently defeat uniqueness, so the root location is a
  # sentinel instead.
  ROOT_POOL = 0

  BATCH_STATEMENTS = 2000
  BATCH_SECONDS = 15.0
  BUSY_TIMEOUT_MS = 15_000
  # Fold the write-ahead log back into the database once it grows past this. A
  # bulk import appends to it faster than it drains, and on a slow disk an
  # oversized log turns every commit into a long journal flush: observed
  # blocking in xlog_wait_on_iclog with a 340 MB log on a spinning drive.
  # Commits land roughly every 25 posts at this size, so a SIGKILL loses at most
  # that much metadata; the files stay on disk and the next run re-adopts them.
  WAL_CHECKPOINT_BYTES = 16 * 1024 * 1024
  # SQLite leaves a checkpointed log at whatever size it reached, so on its own
  # the file only ever grows across a long import. Capping it means the log is
  # truncated back after each checkpoint instead.
  WAL_SIZE_LIMIT_BYTES = 16 * 1024 * 1024
  # Tags are inserted in one statement per chunk rather than one per tag: a post
  # carries dozens, and 40x fewer statements is 40x less work per post.
  TAG_INSERT_CHUNK = 200

  attr_reader :path

  def initialize(path, site: nil, logger: nil)
    @path = path
    @site = site.to_s
    @logger = logger
    # Monitor, not Mutex: a plain mutex deadlocks the moment a write helper is
    # called from inside an already-locked read, and every method here can be.
    @lock = Monitor.new
    @conn = nil
    @persistent = false
    @in_batch = false
    @batch_statements = 0
    @batch_started_at = nil
    @tag_types = nil
  end

  def enabled?
    !@path.nil? && !@path.empty?
  end

  def persistent?
    enabled? && @persistent
  end

  def site
    @site
  end

  # Opens (and creates) the store. A file that is not a database is moved aside
  # and a fresh one is created, so a corrupt store never stops a run. Returns
  # true unless the store could not be opened at all, which downgrades to an
  # in-memory one instead.
  def load
    return true unless enabled?

    @lock.synchronize { open_and_migrate }
    true
  rescue *CORRUPT_ERRORS => e
    # A damaged index is replaced rather than merely tolerated, so this run can
    # rebuild it from the filesystem.
    rebuild_after_corruption(e)
    true
  rescue SQLite3::Exception, SystemCallError, IOError => e
    warn_once("archive db could not be opened; continuing without it", e)
    fallback_to_memory
    true
  end

  def close
    @lock.synchronize do
      flush_batch
      # Leaving a clean store behind: the last connection to close checkpoints
      # anyway, but doing it here keeps the log from surviving a kill.
      @conn&.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    rescue SQLite3::Exception
      nil
    end
    @lock.synchronize { @conn&.close }
    @conn = nil
  end

  # --- reads ----------------------------------------------------------------
  #
  # Every statement goes through select/select_one/write, which is also where a
  # damaged file is caught. A corrupt database is a rebuildable index, never a
  # reason to abandon an archive run.

  def pool(pool_id)
    row = select_one('SELECT pool_id, name, slug, post_count, is_active, first_seen ' \
                     'FROM pools WHERE site = ? AND pool_id = ?', [@site, pool_id])
    row && pool_row(row)
  end

  # @param pool_id [Integer, nil] nil for a post that is not part of a pool.
  def file(post_id, pool_id = nil)
    row = select_one("#{FILE_SELECT} WHERE site = ? AND post_id = ? AND pool_id = ?",
                     [@site, post_id, pool_key(pool_id)])
    row && file_row(row)
  end

  def files
    select(FILE_SELECT.to_s + ' WHERE site = ?', [@site]).map { |row| file_row(row) }
  end

  def post(post_id)
    row = select_one('SELECT * FROM posts WHERE site = ? AND post_id = ?', [@site, post_id])
    row && post_row(row)
  end

  # Source URLs recorded for a post, in the order the site listed them.
  def sources(post_id)
    select('SELECT url FROM post_sources WHERE site = ? AND post_id = ? ORDER BY ordinal',
           [@site, post_id]).map { |row| row['url'] }
  end

  # Categorized tags for a post, as a hash of category => [tag].
  def post_tags(post_id)
    select('SELECT category, tag FROM tags WHERE site = ? AND post_id = ? ORDER BY category, tag',
           [@site, post_id]).group_by { |row| row['category'] }
               .transform_values { |rows| rows.map { |row| row['tag'] } }
  end

  # The verbatim response, for the fields no column models. Parsed on demand
  # rather than in post_row: most callers want a column, and parsing a blob on
  # every read of a 4.5M-tag store would be absurd.
  def raw_post(post_id)
    row = select_one('SELECT raw_json FROM posts WHERE site = ? AND post_id = ?', [@site, post_id])
    return nil unless row && row['raw_json']

    JSON.parse(row['raw_json'])
  rescue JSON::ParserError
    nil
  end

  # The verbatim response. Its own row rather than a posts column on purpose: the
  # blob is ~2.8 KB for a typical e621 post, and posts is rewritten on every run
  # for every post rediscovered, so keeping it inline means re-serialising
  # identical bytes tens of thousands of times. Here it is written once, and
  # rewritten only when a recache says the post actually changed.
  def record_raw(post_id, raw_json)
    run('INSERT OR REPLACE INTO post_raw (site, post_id, raw_json, captured_at) VALUES (?,?,?,?)',
        [@site, post_id, raw_json, Time.now.utc.iso8601])
  end

  # When the verbatim record was captured, so "has the site changed this?" is a
  # comparison rather than a diff of two multi-kilobyte documents.
  def raw_captured_at(post_id)
    select_one('SELECT captured_at FROM post_raw WHERE site = ? AND post_id = ?',
               [@site, post_id])&.fetch('captured_at', nil)
  end

  # The verbatim response, for the fields no column models. Parsed on demand
  # rather than in post_row: most callers want a column, and parsing a blob on
  # every read would be absurd.
  def raw_post(post_id)
    row = select_one('SELECT raw_json FROM post_raw WHERE site = ? AND post_id = ?', [@site, post_id])
    return nil unless row && row['raw_json']

    JSON.parse(row['raw_json'])
  rescue JSON::ParserError
    nil
  end

  # Every rendition the site offered, one row per variant and format.
  def post_variants(post_id)
    select('SELECT variant, format, width, height, url FROM post_files ' \
           'WHERE site = ? AND post_id = ? ORDER BY variant, format', [@site, post_id])
      .map { |row| row.reject { |key, _| %w[site post_id].include?(key) } }
  end

  # Child post ids, in the order the site listed them.
  def post_children(post_id)
    select('SELECT child_id FROM post_children WHERE site = ? AND post_id = ? ORDER BY ordinal',
           [@site, post_id]).map { |row| row['child_id'] }
  end

  def record_count
    count('pools') + count('files')
  end

  # Any digest recorded for this post. Every file row for a post describes the
  # same bytes, so one is enough to make a copy placed from another of them
  # verifiable. Nil until the post has been downloaded at least once.
  def known_md5(post_id)
    select_one('SELECT md5 AS md5 FROM files WHERE site = ? AND post_id = ? AND md5 IS NOT NULL LIMIT 1',
               [@site, post_id])&.fetch('md5', nil)
  end

  # The extension the site itself advertises for a post, which is not always the
  # container it serves: Gelbooru lists a .webm and hands out the .mp4, and e621
  # does the reverse for some posts. Comparing it against a file row's own
  # extension is what tells a digest that describes those bytes from one that
  # does not. Nil when the post has not been recorded.
  def post_ext(post_id)
    select_one('SELECT ext AS ext FROM posts WHERE site = ? AND post_id = ?', [@site, post_id])&.fetch('ext', nil)
  end

  def post_count
    counter_value('posts') || count('posts')
  end

  def tag_count
    counter_value('tags') || count('tags')
  end

  # A cached count, or nil when this store predates the counters table and has
  # not been backfilled yet. Reads only: seeding happens once in
  # backfill_counters!, never on the read path.
  def counter_value(kind)
    row = select_one('SELECT value AS v FROM counters WHERE site = ? AND kind = ?', [@site, kind])
    row && !row['v'].nil? ? row['v'].to_i : nil
  rescue SQLite3::Exception
    nil
  end

  def set_counter(kind, value)
    run('INSERT INTO counters (site, kind, value) VALUES (?,?,?) ' \
        'ON CONFLICT(site, kind) DO UPDATE SET value = excluded.value',
        [@site, kind, value])
  end

  def bump_counter(kind, delta)
    return if delta.nil? || delta.zero?

    run('INSERT INTO counters (site, kind, value) VALUES (?,?,?) ' \
        'ON CONFLICT(site, kind) DO UPDATE SET value = value + excluded.value',
        [@site, kind, delta])
  end

  # Seeds the counters from the tables the first time a pre-counter database is
  # opened. The tags COUNT(*) is the slow one (tens of minutes on 4.5M rows of
  # spinning disk), but it runs exactly once; every later open reads two rows.
  def backfill_counters!
    { 'posts' => 'posts', 'tags' => 'tags' }.each do |kind, table|
      next unless counter_value(kind).nil?

      set_counter(kind, count(table))
    end
    flush_batch
  rescue SQLite3::Exception, SystemCallError, IOError
    nil
  end

  def tag_count_for_post(post_id)
    select_one('SELECT COUNT(*) AS n FROM tags WHERE site = ? AND post_id = ?',
               [@site, post_id])&.fetch('n', 0).to_i
  end

  # Records a download that exhausted every retry round. Upserted: a post that
  # keeps failing keeps its latest timestamp, attempt count and error.
  def record_download_failure(post_id, attempts:, error: nil)
    return unless connected?

    run('INSERT INTO download_failures (site, post_id, failed_at, attempts, error) ' \
        'VALUES (?,?,?,?,?) ON CONFLICT(site, post_id) DO UPDATE SET ' \
        'failed_at = excluded.failed_at, attempts = excluded.attempts, error = excluded.error',
        [@site, post_id, Time.now.utc.iso8601, attempts, error])
  end

  # A post that finally archived is no failure. Called on every successful
  # placement, so a recovered post cannot linger in the retry list.
  def clear_download_failure(post_id)
    return unless connected?

    run('DELETE FROM download_failures WHERE site = ? AND post_id = ?', [@site, post_id])
  end

  # Ids still waiting for a retry, oldest failure first.
  def failed_download_ids
    select('SELECT post_id FROM download_failures WHERE site = ? ORDER BY failed_at',
           [@site]).map { |row| row['post_id'] }
  end

  def failed_download_count
    select_one('SELECT COUNT(*) AS n FROM download_failures WHERE site = ?',
               [@site])&.fetch('n', 0).to_i
  end

  def pool_member_ids(pool_id)
    select('SELECT post_id FROM pool_posts WHERE site = ? AND pool_id = ? ORDER BY post_id',
           [@site, pool_id]).map { |row| row['post_id'] }
  end

  # Pools this post was bundled for. The reverse map of pool_member_ids, used
  # when a pool label has to be rebuilt without asking the site.
  def post_pools(post_id)
    select('SELECT pool_id FROM pool_posts WHERE site = ? AND post_id = ? ORDER BY pool_id',
           [@site, post_id]).map { |row| row['pool_id'] }
  end

  def size_on_disk
    return 0 unless persistent?

    (File.size?(@path) || 0) + (File.size?("#{@path}-wal") || 0)
  end

  def inspect
    return 'disabled' unless enabled?

    "path=#{@path} site=#{@site} records=#{record_count} persistent=#{@persistent}"
  end

  # --- writes ---------------------------------------------------------------

  # Provenance for one archived file: where it lives and what it should hash to.
  def record_file(post_id:, pool_id: nil, path:, dir:, md5: nil, ext: nil,
                  bytes: nil, sidecar: false, rating: nil, width: nil, height: nil)
    return unless connected?

    run("INSERT OR REPLACE INTO files " \
        '(site, post_id, pool_id, path, dir, md5, ext, bytes, sidecar, rating, width, height, archived_at) ' \
        'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [@site, post_id, pool_key(pool_id), path, dir, md5, ext, bytes, sidecar ? 1 : 0, rating, width, height,
         Time.now.utc.iso8601])
  end

  # Small standalone update so a sidecar refresh does not have to rewrite the
  # whole file entry.
  def record_sidecar(post_id, pool_id, sidecar: true)
    return unless connected?

    run('UPDATE files SET sidecar = ? WHERE site = ? AND post_id = ? AND pool_id = ?',
        [sidecar ? 1 : 0, @site, post_id, pool_key(pool_id)])
  end

  def forget_file(post_id, pool_id = nil)
    return unless connected?

    run('DELETE FROM files WHERE site = ? AND post_id = ? AND pool_id = ?', [@site, post_id, pool_key(pool_id)])
  end

  # Points every root file row at the posts/ subdirectory after a layout
  # migration moved the files on disk. Returns the number of rows updated.
  # Pool rows are untouched: only the archive root moved.
  def relocate_root_files(posts_dir)
    return 0 unless connected?

    @lock.synchronize do
      @conn.execute("UPDATE files SET dir = ?, path = ? || '/' || path " \
                    'WHERE site = ? AND dir = ?',
                    [posts_dir, posts_dir, @site, '.'])
      @conn.changes
    end
  end

  def record_pool(id:, name:, slug:, post_count: nil, active: nil)
    return unless connected?

    @lock.synchronize do
      # The slug is frozen on first sight: it names the directory the bundle
      # already lives in, so recomputing it later would move the whole bundle.
      # Only the first run that sees a pool writes a slug.
      if frozen_slug(id).to_s.empty?
        run('INSERT OR REPLACE INTO pools (site, pool_id, name, slug, post_count, is_active, first_seen) ' \
            'VALUES (?,?,?,?,?,?,?)',
            [@site, id, name, slug, post_count, bool(active), Time.now.utc.iso8601],
            immediate: true)
      else
        run('INSERT INTO pools (site, pool_id, name, slug, post_count, is_active, first_seen) ' \
            'VALUES (?,?,?,?,?,?,?) ON CONFLICT(site, pool_id) DO UPDATE SET ' \
            'name = excluded.name, post_count = excluded.post_count, is_active = excluded.is_active',
            [@site, id, name, slug, post_count, bool(active), Time.now.utc.iso8601],
            immediate: true)
      end
    end
  end

  def record_pool_post(pool_id, post_id)
    return if pool_id.nil? || post_id.nil?
    return unless connected?

    run('INSERT OR IGNORE INTO pool_posts (site, pool_id, post_id) VALUES (?,?,?)', [@site, pool_id, post_id])
  end

  # The full detail record for a post, exactly as the site reported it. Tags and
  # sources are normalised into their own tables so they stay queryable;
  # everything else the API offered is kept in columns.
  def record_post(post_id:, refresh: false, uncategorized: false, rating: nil, created_at: nil, updated_at: nil, change_seq: nil,
                  md5: nil, ext: nil, bytes: nil, width: nil, height: nil, duration: nil,
                  uploader_id: nil, uploader_name: nil, approver_id: nil, description: nil,
                  page_url: nil, score_up: nil, score_down: nil, score_total: nil,
                  fav_count: nil, comment_count: nil, parent_id: nil, child_count: nil,
                  has_children: nil, flags: nil, stats: nil, locked_tags: nil,
                  tags: nil, sources: nil,
                  has: nil, sample_width: nil, sample_height: nil,
                  preview_width: nil, preview_height: nil,
                  is_favorited: nil, vote: nil, hotness: nil,
                  status: nil, creator_id: nil, creator_anonymous: nil, num_notes: nil,
                  is_held: nil, is_pending: nil, has_notes: nil,
                  raw_json: nil, variants: nil, children: nil)
    return unless connected?

    @lock.synchronize do
      hold_batch do
      # Re-recording a post that is already stored means rewriting its tag rows:
      # dozens of statements per post, every run, for nothing. A normal run
      # therefore only fills in what is missing, and `refresh: true` (which is
      # what --recache-post-tags asks for) is the way to force the tag list to be
      # rewritten, so a tag changed upstream can still be corrected.
      known = !refresh && tags_known?(post_id)
      # The posts counter needs new-vs-replace, and INSERT OR REPLACE does not
      # say which it did. One indexed point read; record_post runs on the main
      # thread at discovery, so no worker can slip in between.
      is_new = select_one('SELECT 1 AS x FROM posts WHERE site = ? AND post_id = ?',
                          [@site, post_id]).nil?
      values = {
        'site' => @site, 'post_id' => post_id, 'rating' => rating, 'created_at' => created_at,
        'updated_at' => updated_at, 'change_seq' => change_seq, 'md5' => md5, 'ext' => ext,
        'bytes' => bytes, 'width' => width, 'height' => height, 'duration' => duration,
        'uploader_id' => uploader_id, 'uploader_name' => uploader_name, 'approver_id' => approver_id,
        'description' => description, 'page_url' => page_url, 'score_up' => score_up,
        'score_down' => score_down, 'score_total' => score_total, 'fav_count' => fav_count,
        'comment_count' => comment_count, 'parent_id' => parent_id, 'child_count' => child_count,
        # SQLite stores booleans as integers; the gem cannot bind a Ruby true/false.
        'has_children' => bool(has_children),
        'uncategorized' => bool(uncategorized),
        'flags_json' => flags && JSON.generate(flags),
        'stats_json' => stats && JSON.generate(stats), 'locked_tags' => locked_tags && JSON.generate(locked_tags),
        'has_json' => has && JSON.generate(has),
        'has_parent' => bool(has.is_a?(Hash) ? has['parent'] : nil),
        'has_active_children' => bool(has.is_a?(Hash) ? has['active_children'] : nil),
        # "Has notes" is one fact with two spellings: e621 reports it inside the
        # has object, Gelbooru as a flat flag. One column, either source.
        'has_notes' => bool(has_notes.nil? && has.is_a?(Hash) ? has['notes'] : has_notes),
        'has_sample' => bool(has.is_a?(Hash) ? has['sample'] : nil),
        'sample_width' => sample_width, 'sample_height' => sample_height,
        'preview_width' => preview_width, 'preview_height' => preview_height,
        'is_favorited' => bool(is_favorited), 'vote' => vote, 'hotness' => hotness,
        'status' => status, 'creator_id' => creator_id,
        'creator_anonymous' => bool(creator_anonymous), 'num_notes' => num_notes,
        'is_held' => bool(is_held), 'is_pending' => bool(is_pending),
        'captured_at' => Time.now.utc.iso8601
      }

      run("INSERT OR REPLACE INTO posts (#{POST_COLUMNS.join(', ')}) " \
          "VALUES (#{Array.new(POST_COLUMNS.size, '?').join(',')})",
          POST_COLUMNS.map { |column| values[column] })
      bump_counter('posts', 1) if is_new

      # A new post has no rows to delete, so skip that read; a recache passes
      # refresh: true and goes through the counted path inside.
      replace_tags(post_id, tags, old_count: (is_new ? 0 : nil)) if tags && !known
      replace_sources(post_id, sources) if sources && !known
      # The raw record and the nested lists it describes are refreshed with the
      # tags rather than on every write. They change only when the post does,
      # which is exactly when a recache (refresh: true) is what brought us here.
      record_raw(post_id, raw_json) if raw_json && !known
      replace_variants(post_id, variants) if variants && !known
      replace_children(post_id, children) if children && !known
      backfill_file_md5(post_id, md5, ext)
      end
    end
  end

  def tags_known?(post_id)
    !@conn.get_first_value('SELECT 1 FROM tags WHERE site = ? AND post_id = ? LIMIT 1',
                           [@site, post_id]).nil?
  end

  # A file adopted from the filesystem has no recorded digest, which would leave
  # --verify-md5 permanently blind to everything archived before the database
  # existed. The post's own detail supplies it, so the digest is filled in as
  # soon as the post is seen rather than only after a fresh download.
  #
  # Only for a file whose extension matches the post's. Both sites hand out an
  # alternate encoding — Gelbooru serves .mp4 for a post whose `image` says
  # .webm, e621 serves .webm for some .mp4 posts — and the archive keeps what was
  # served. That file's bytes are not the ones the digest was computed over, so
  # recording the digest against it would make --verify-md5 condemn a perfectly
  # good file as corrupt, move it aside and fetch it again, on every run, forever.
  def backfill_file_md5(post_id, md5, post_ext = nil)
    return if md5.nil? || md5.to_s.empty?

    if post_ext && !post_ext.to_s.empty?
      run('UPDATE files SET md5 = ? WHERE site = ? AND post_id = ? ' \
          'AND (ext IS NULL OR ext = ? OR ext = "") AND (md5 IS NULL OR md5 = ?)',
          [md5, @site, post_id, post_ext.to_s.downcase, ''])
    else
      run('UPDATE files SET md5 = ? WHERE site = ? AND post_id = ? AND (md5 IS NULL OR md5 = ?)',
          [md5, @site, post_id, ''])
    end
  end
  # Cached tag category lookups, so a run does not have to ask the tag API
  # again for every tag it has already seen.
  def tag_types
    @tag_types ||= select('SELECT tag, category FROM tag_types WHERE site = ?', [@site])
                   .to_h { |row| [row['tag'], row['category']] }
  end

  def remember_tag_types(types)
    return if types.nil? || types.empty?
    return unless connected?

    @lock.synchronize do
      types.each do |tag, category|
        run('INSERT OR REPLACE INTO tag_types (site, tag, category) VALUES (?,?,?)',
                   [@site, tag, category])
      end
      @tag_types&.merge!(types)
    end
  end

  # --- plumbing -------------------------------------------------------------

  private

  FILE_SELECT = 'SELECT site, post_id, pool_id, path, dir, md5, ext, bytes, sidecar, rating, ' \
                'width, height, archived_at FROM files'

  # One place to keep the insert and its binds in step: placeholders are derived
  # from this list, so a column can never drift out of alignment with its value.
  # Capability flags the site reports about the post (v2 "has") are columns
  # because they are worth querying; the whole object is also kept in has_json.
  # Variant geometry is here so a post's sample/preview size is answerable
  # without the raw record, while the variant URLs live in post_files. `status`
  # and its neighbours are Gelbooru's own lifecycle and ownership words: a post
  # withdrawn upstream still says so there, which is the only record of it once
  # the bytes are archived. The complete response is *not* a column — see
  # post_raw and record_post.
  POST_COLUMNS = %w[
    site post_id rating created_at updated_at change_seq md5 ext bytes width height duration
    uploader_id uploader_name approver_id description page_url score_up score_down score_total
    fav_count comment_count parent_id child_count has_children flags_json stats_json
    locked_tags uncategorized captured_at
    has_parent has_active_children has_notes has_sample
    sample_width sample_height preview_width preview_height
    is_favorited vote hotness
    status creator_id creator_anonymous num_notes is_held is_pending
    has_json
  ].freeze

  # Declared types for columns an older database may need added. SQLite stores
  # dynamically regardless, so this only sets the affinity; unknown columns
  # default to TEXT.
  POST_COLUMN_TYPES = {
    'post_id' => 'INTEGER', 'change_seq' => 'INTEGER', 'bytes' => 'INTEGER',
    'width' => 'INTEGER', 'height' => 'INTEGER', 'duration' => 'REAL',
    'uploader_id' => 'INTEGER', 'approver_id' => 'INTEGER',
    'score_up' => 'INTEGER', 'score_down' => 'INTEGER', 'score_total' => 'INTEGER',
    'fav_count' => 'INTEGER', 'comment_count' => 'INTEGER', 'parent_id' => 'INTEGER',
    'child_count' => 'INTEGER', 'has_children' => 'INTEGER', 'uncategorized' => 'INTEGER',
    'has_parent' => 'INTEGER', 'has_active_children' => 'INTEGER', 'has_notes' => 'INTEGER',
    'has_sample' => 'INTEGER', 'is_favorited' => 'INTEGER', 'vote' => 'INTEGER',
    'hotness' => 'REAL', 'sample_width' => 'INTEGER', 'sample_height' => 'INTEGER',
    'preview_width' => 'INTEGER', 'preview_height' => 'INTEGER',
    'creator_id' => 'INTEGER', 'num_notes' => 'INTEGER', 'creator_anonymous' => 'INTEGER',
    'is_held' => 'INTEGER', 'is_pending' => 'INTEGER'
  }.freeze

  def connected?
    return false unless enabled?
    return true if @conn

    # Connect on first use as well as on load, so a store that was never
    # explicitly loaded still records. A silently inert database is far worse
    # than one that opens itself.
    begin
      @lock.synchronize { open_and_migrate unless @conn }
    rescue *CORRUPT_ERRORS => e
      rebuild_after_corruption(e)
    rescue SQLite3::Exception => e
      warn_once("archive db could not be opened; continuing without it", e)
      fallback_to_memory
    end
    !@conn.nil?
  end

  def pool_key(pool_id)
    pool_id.nil? ? ROOT_POOL : pool_id
  end

  # nil stays nil; anything else becomes 0 or 1.
  def bool(value)
    return nil if value.nil?

    value ? 1 : 0
  end

  def pool_row(row)
    { 'id' => row['pool_id'], 'name' => row['name'], 'slug' => row['slug'],
      'post_count' => row['post_count'], 'is_active' => row['is_active'] ? true : false,
      'first_seen' => row['first_seen'] }
  end

  def file_row(row)
    { 'site' => row['site'], 'post' => row['post_id'],
      'pool' => row['pool_id'] == ROOT_POOL ? nil : row['pool_id'],
      'path' => row['path'], 'dir' => row['dir'], 'md5' => row['md5'], 'ext' => row['ext'],
      'bytes' => row['bytes'], 'sidecar' => row['sidecar'], 'rating' => row['rating'],
      'width' => row['width'], 'height' => row['height'], 'archived_at' => row['archived_at'] }
  end

  def post_row(row)
    row = row.dup
    %w[flags_json stats_json locked_tags has_json].each do |key|
      value = row.delete(key)
      row[key.sub('_json', '')] = value && (JSON.parse(value) rescue nil)
    end
    row
  end

  def replace_tags(post_id, tags, old_count: nil)
    old_count = tag_count_for_post(post_id) if old_count.nil?
    run('DELETE FROM tags WHERE site = ? AND post_id = ?', [@site, post_id])
    inserted = 0
    tags.each do |category, names|
      Array(names).each do |tag|
        run('INSERT OR IGNORE INTO tags (site, post_id, category, tag) VALUES (?,?,?,?)',
                   [@site, post_id, category.to_s, tag.to_s])
        inserted += 1
      end
    end
    bump_counter('tags', inserted - old_count)
  end

  def replace_sources(post_id, sources)
    run('DELETE FROM post_sources WHERE site = ? AND post_id = ?', [@site, post_id])
    Array(sources).each_with_index do |url, ordinal|
      next if url.to_s.empty?

      run('INSERT OR REPLACE INTO post_sources (site, post_id, ordinal, url) VALUES (?,?,?,?)',
                 [@site, post_id, ordinal, url.to_s])
    end
  end

  # Every rendition the site offers, keyed so a re-record replaces rather than
  # duplicates. A variant with no URL (e.g. a webp preview a site does not
  # actually serve) is still recorded with its dimensions.
  def replace_variants(post_id, variants)
    return if variants.empty?

    run('DELETE FROM post_files WHERE site = ? AND post_id = ?', [@site, post_id])
    variants.each do |variant|
      next if variant['variant'].to_s.empty?

      run('INSERT OR REPLACE INTO post_files (site, post_id, variant, format, width, height, url) ' \
          'VALUES (?,?,?,?,?,?,?)',
          [@site, post_id, variant['variant'].to_s, variant['format'].to_s,
           variant['width'], variant['height'], variant['url']])
    end
  end

  # Child post ids in site order. The ordinal is the primary key, so the
  # response order is preserved and a post that gains a child gains a row.
  def replace_children(post_id, children)
    run('DELETE FROM post_children WHERE site = ? AND post_id = ?', [@site, post_id])
    Array(children).each_with_index do |child_id, ordinal|
      next if child_id.nil?

      run('INSERT OR REPLACE INTO post_children (site, post_id, ordinal, child_id) VALUES (?,?,?,?)',
          [@site, post_id, ordinal, child_id])
    end
  end

  def frozen_slug(pool_id)
    select_one('SELECT slug AS slug FROM pools WHERE site = ? AND pool_id = ?',
               [@site, pool_id])&.fetch('slug', nil)
  end

  # --- statement helpers ----------------------------------------------------
  #
  # The single point where the store can fail in a way the archiver has to
  # survive. A damaged file is set aside, a fresh one is opened, and the caller
  # is retried once; if that still fails the store degrades to in-memory and the
  # run continues on the filesystem alone.

  CORRUPT_ERRORS = [SQLite3::NotADatabaseException, SQLite3::CorruptException].freeze

  def select(sql, binds = [])
    guard { @conn.execute(sql, binds) } || []
  end

  def select_one(sql, binds = [])
    guard { @conn.get_first_row(sql, binds) }
  end

  def count(table)
    select_one("SELECT COUNT(*) AS n FROM #{table} WHERE site = ?", [@site])&.fetch('n', nil).to_i
  end

  # Executes a write inside the open batch, so a run's writes commit together
  # instead of one COMMIT per statement. Safe to call from inside an
  # already-locked read, so helpers can compose.
  #
  # `immediate: true` commits straight away, for the few records a hard kill
  # must not be able to lose — a pool slug names the directory a whole bundle
  # lives in, so losing one would move that bundle on the next run.
  def run(sql, binds, immediate: false)
    guard do
      @lock.synchronize do
        begin_batch
        @conn.execute(sql, binds)
      end
    end
    track_batch
    @lock.synchronize { flush_batch } if immediate
  end

  # Opens the batch transaction. Called before the write, not after, so the
  # statement actually lands inside it; the old order (BEGIN after EXECUTE)
  # left every statement auto-committing and the batch forever empty.
  def begin_batch
    return unless @persistent
    return if @in_batch

    @conn.execute('BEGIN IMMEDIATE')
    @in_batch = true
    @batch_statements = 0
    @batch_started_at = monotonic_now
  end

  # Holds the batch open across a multi-statement write, so a post's row, its
  # tag rows and its sources either commit together or not at all. A crash in
  # the middle of a tag list would otherwise leave a torn set that looks
  # complete to the next run, and the missing half would never be rewritten.
  def hold_batch
    @batch_hold = (@batch_hold || 0) + 1
    yield
  ensure
    # Re-check the batch threshold now that the write is allowed to commit.
    # Commits therefore always land on a post boundary, never in the middle of
    # one, and batching still works: most posts only add to the open batch.
    @batch_hold = (@batch_hold || 0) - 1
    track_batch
  end

  def guard(recovered = false)
    return nil unless connected?

    # No pre-flush here: reads on this connection see the open batch's writes
    # already, and flushing first would commit a half-written post in the middle
    # of hold_batch. Commits happen at post boundaries (hold_batch release),
    # batch thresholds, immediates and close.
    @lock.synchronize { yield }
  rescue *CORRUPT_ERRORS => e
    raise if recovered

    rebuild_after_corruption(e)
    guard(true) { yield }
  rescue SQLite3::Exception => e
    # Anything else the store complains about: a locked table, a full disk, a
    # constraint. The archive run matters more than the index.
    warn_once("archive db operation failed; continuing without it", e)
    nil
  end

  def track_batch
    return unless @persistent
    return unless @in_batch

    @lock.synchronize do
      @batch_statements += 1
      return if (@batch_hold || 0).positive?
      return unless @batch_statements >= BATCH_STATEMENTS || monotonic_now - @batch_started_at >= BATCH_SECONDS

      flush_batch
    end
  end

  def flush_batch
    @lock.synchronize do
      return unless @in_batch

      @conn.execute('COMMIT')
      checkpoint_wal
    end
  rescue SQLite3::Exception
    begin
      @conn.execute('ROLLBACK')
    rescue SQLite3::Exception
      nil
    end
  ensure
    @in_batch = false
    @batch_statements = 0
  end

  # Checked at a commit boundary. PASSIVE while the run is working: it folds what
  # it can without blocking writers, which is what matters on a spinning disk.
  # The log is reset to nothing once, at close, where a blocking checkpoint
  # costs nothing because no worker is waiting on it.
  def checkpoint_wal
    return unless @persistent
    return if wal_bytes < WAL_CHECKPOINT_BYTES

    @conn.execute('PRAGMA wal_checkpoint(PASSIVE)')
  rescue SQLite3::Exception
    nil
  end

  def wal_bytes
    File.size?("#{@path}-wal") || 0
  rescue SystemCallError
    0
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def open_and_migrate
    return if @conn

    begin
      FileUtils.mkdir_p(File.dirname(@path))
      @conn = SQLite3::Database.new(@path)
      configure!
      @persistent = true
    rescue SQLite3::NotADatabaseException => e
      # The path holds something that is not a database. Keep the evidence, then
      # start over: the archive can always be rebuilt from the filesystem.
      @conn.close if @conn
      @conn = nil
      quarantine_corrupt_file
      warn_once("archive db was not a database; started a new one", e)
      retry
    end

    create_schema!
    backfill_counters!
    @tag_types = nil
  end

  def configure!
    @conn.results_as_hash = true
    @conn.busy_timeout = BUSY_TIMEOUT_MS
    # WAL keeps a reader from blocking the writer, and busy_timeout covers the
    # other archiver run sharing this file.
    @conn.execute('PRAGMA journal_mode = WAL')
    @conn.execute('PRAGMA synchronous = NORMAL')
    @conn.execute('PRAGMA foreign_keys = ON')
    @conn.execute("PRAGMA journal_size_limit = #{WAL_SIZE_LIMIT_BYTES}")
  end

  # Closes the connection, keeps the unreadable file for inspection and opens a
  # new one. The archive is rebuilt from the filesystem on the next run.
  def rebuild_after_corruption(error)
    @lock.synchronize do
      flush_batch
      @conn.close if @conn
      @conn = nil
      quarantine_corrupt_file
      warn_once("archive db was damaged; started a new one", error)
      open_and_migrate
    end
  rescue SQLite3::Exception, SystemCallError => e
    @conn = nil
    warn_once("archive db could not be replaced; continuing in memory", e)
    fallback_to_memory
  end

  def quarantine_corrupt_file
    stamp = Time.now.utc.strftime('%Y%m%d%H%M%S')
    FileUtils.mv(@path, "#{@path}.corrupt-#{stamp}")
  rescue SystemCallError
    File.delete(@path) if File.exist?(@path)
  end

  def fallback_to_memory
    @lock.synchronize do
      @conn.close if @conn
      @conn = SQLite3::Database.new(':memory:')
      @conn.results_as_hash = true
      @persistent = false
      create_schema!
    end
  rescue SQLite3::Exception
    @conn = nil
  end

  def create_schema!
    @conn.execute_batch(SCHEMA_TABLES)
    migrate_columns!
    @conn.execute_batch(SCHEMA_INDEXES)
    @conn.execute('INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)',
                  ['version', SCHEMA_VERSION.to_s])
  end

  # Brings the posts table of an older database up to the current columns. Each
  # addition is guarded, so opening a current store is a no-op and a legacy file
  # migrates in place. This has to run before the indexes are built, because an
  # index on a column the table does not have yet is an error that would abort
  # the open — and a failed open degrades to an in-memory store, silently
  # abandoning everything on disk.
  def migrate_columns!
    names = @conn.execute('PRAGMA table_info(posts)').map { |row| row['name'] }
    POST_COLUMNS.each do |column|
      next if names.include?(column) || %w[site post_id].include?(column)

      @conn.execute("ALTER TABLE posts ADD COLUMN #{column} #{POST_COLUMN_TYPES.fetch(column, 'TEXT')}")
    end
  end

  def warn_once(message, error)
    return if @warned

    @warned = true
    @logger&.warn(message, error: error.message, db: true, path: @path)
  end

  SCHEMA_TABLES = <<~SQL
    CREATE TABLE IF NOT EXISTS schema_meta (
      key   TEXT PRIMARY KEY,
      value TEXT
    );

    -- The complete API response for a post, verbatim. Everything else in this
    -- schema is a projection of it, so this is the one record that cannot lose a
    -- field: a site adding something is captured without a code change, and the
    -- columns can be backfilled from here at any time. It is deliberately its
    -- own row rather than a column on posts — see record_post.
    CREATE TABLE IF NOT EXISTS post_raw (
      site        TEXT    NOT NULL,
      post_id     INTEGER NOT NULL,
      raw_json    TEXT    NOT NULL,
      captured_at TEXT,
      PRIMARY KEY (site, post_id)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS posts (
      site          TEXT    NOT NULL,
      post_id       INTEGER NOT NULL,
      rating        TEXT,
      created_at    TEXT,
      updated_at    TEXT,
      change_seq    INTEGER,
      md5           TEXT,
      ext           TEXT,
      bytes         INTEGER,
      width         INTEGER,
      height        INTEGER,
      duration      REAL,
      uploader_id   INTEGER,
      uploader_name TEXT,
      approver_id   INTEGER,
      description   TEXT,
      page_url      TEXT,
      score_up      INTEGER,
      score_down    INTEGER,
      score_total   INTEGER,
      fav_count     INTEGER,
      comment_count INTEGER,
      parent_id     INTEGER,
      child_count   INTEGER,
      has_children  INTEGER,
      flags_json    TEXT,
      stats_json    TEXT,
      locked_tags   TEXT,
      uncategorized INTEGER DEFAULT 0,
      captured_at   TEXT,
      PRIMARY KEY (site, post_id)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS tags (
      site     TEXT    NOT NULL,
      post_id  INTEGER NOT NULL,
      category TEXT    NOT NULL,
      tag      TEXT    NOT NULL,
      PRIMARY KEY (site, post_id, category, tag)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS post_sources (
      site    TEXT    NOT NULL,
      post_id INTEGER NOT NULL,
      ordinal INTEGER NOT NULL,
      url     TEXT    NOT NULL,
      PRIMARY KEY (site, post_id, ordinal)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS pools (
      site       TEXT    NOT NULL,
      pool_id    INTEGER NOT NULL,
      name       TEXT,
      slug       TEXT,
      post_count INTEGER,
      is_active  INTEGER,
      first_seen TEXT,
      PRIMARY KEY (site, pool_id)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS pool_posts (
      site    TEXT    NOT NULL,
      pool_id INTEGER NOT NULL,
      post_id INTEGER NOT NULL,
      PRIMARY KEY (site, pool_id, post_id)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS files (
      site        TEXT    NOT NULL,
      post_id     INTEGER NOT NULL,
      pool_id     INTEGER NOT NULL DEFAULT 0,
      path        TEXT    NOT NULL,
      dir         TEXT    NOT NULL,
      md5         TEXT,
      ext         TEXT,
      bytes       INTEGER,
      sidecar     INTEGER NOT NULL DEFAULT 0,
      rating      TEXT,
      width       INTEGER,
      height      INTEGER,
      archived_at TEXT,
      PRIMARY KEY (site, post_id, pool_id)
    ) WITHOUT ROWID;

    -- The file variants e621 offers. The archive only ever keeps the original,
    -- but the sample and preview URLs are recorded here so the archive can be
    -- rebuilt (or a different rendition fetched) without asking the site again.
    CREATE TABLE IF NOT EXISTS post_files (
      site     TEXT    NOT NULL,
      post_id  INTEGER NOT NULL,
      variant  TEXT    NOT NULL,
      format   TEXT    NOT NULL,
      width    INTEGER,
      height   INTEGER,
      url      TEXT,
      PRIMARY KEY (site, post_id, variant, format)
    ) WITHOUT ROWID;

    -- Child posts, in the order the site listed them. relationships.children is
    -- an array of ids in the v2 response and was previously reduced to a count.
    CREATE TABLE IF NOT EXISTS post_children (
      site    TEXT    NOT NULL,
      post_id INTEGER NOT NULL,
      ordinal INTEGER NOT NULL,
      child_id INTEGER NOT NULL,
      PRIMARY KEY (site, post_id, ordinal)
    ) WITHOUT ROWID;

    CREATE TABLE IF NOT EXISTS tag_types (
      site     TEXT NOT NULL,
      tag      TEXT NOT NULL,
      category TEXT NOT NULL,
      PRIMARY KEY (site, tag)
    ) WITHOUT ROWID;

    -- Cached row counts, so the end-of-run summary never runs COUNT(*) over
    -- millions of tag rows on a spinning disk. Maintained incrementally by the
    -- record paths below and seeded once by backfill_counters! on migration.
    CREATE TABLE IF NOT EXISTS counters (
      site  TEXT    NOT NULL,
      kind  TEXT    NOT NULL,
      value INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (site, kind)
    ) WITHOUT ROWID;

    -- Downloads that burned through every retry round. Repaired by rerunning
    -- with --retry-failed, which asks the site for these ids directly; a post
    -- the site no longer returns is dropped as gone upstream, and a post that
    -- finally archives clears its row on success.
    CREATE TABLE IF NOT EXISTS download_failures (
      site      TEXT    NOT NULL,
      post_id   INTEGER NOT NULL,
      failed_at TEXT    NOT NULL,
      attempts  INTEGER NOT NULL DEFAULT 0,
      error     TEXT,
      PRIMARY KEY (site, post_id)
    ) WITHOUT ROWID;
  SQL

  SCHEMA_INDEXES = <<~SQL
    CREATE INDEX IF NOT EXISTS posts_md5_idx  ON posts (site, md5);
    CREATE INDEX IF NOT EXISTS posts_date_idx ON posts (site, created_at);
    CREATE INDEX IF NOT EXISTS posts_rate_idx ON posts (site, rating);
    CREATE INDEX IF NOT EXISTS tags_cat_idx    ON tags (site, category, tag);
    CREATE INDEX IF NOT EXISTS files_dir_idx   ON files (site, dir);
  SQL
end
