# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/stub_http'

# A sidecar is only ever written next to media, so a sidecar with nothing beside
# it means a file went missing. Left alone, that post is never revisited: it only
# comes back if some tag query happens to return it again. These are the two
# passes that put it right.
class RepairTest < Minitest::Test
  include StubHttp

  POST_ID = 3_134_467

  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, 'posts'))
    @db_path = File.join(@dir, 'db')
    @archiver = E621Archiver.new(output_dir: @dir, db_path: @db_path,
                                 username: 'tester', api_key: 'k', rate_limit: 1000)
    @archiver.ensure_rate_limiter
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def post(id = POST_ID, pools: [])
    { 'id' => id, 'rating' => 's', 'created_at' => '2026-07-28T02:20:59.721-04:00',
      'sources' => ['https://example.test/art/1'], 'pools' => pools,
      'tags' => { 'general' => %w[cat], 'artist' => %w[bob] },
      'files' => { 'original' => { 'url' => "http://example.test/#{id}.png" },
                   'meta' => { 'ext' => 'png', 'md5' => 'abc' } } }
  end

  # Writes a sidecar with no media beside it, and a healthy pair for contrast.
  def archive_with_a_orphan_sidecar
    File.write(File.join(@dir, 'posts', "#{POST_ID}.xmp"), "sidecar only\\n")
    File.write(File.join(@dir, 'posts', '99.png'), 'media')
    File.write(File.join(@dir, 'posts', '99.xmp'), "healthy\\n")
    @archiver.scan_output_dir
  end

  def test_a_sidecar_without_media_is_found
    archive_with_a_orphan_sidecar

    assert_equal [POST_ID], @archiver.sidecars_without_media
  end

  def test_a_complete_pair_is_not_reported
    File.write(File.join(@dir, 'posts', "#{POST_ID}.png"), 'media')
    File.write(File.join(@dir, 'posts', "#{POST_ID}.xmp"), 'sidecar')
    @archiver.scan_output_dir

    assert_empty @archiver.sidecars_without_media
  end

  # A stale .part is not media, so the post still counts as missing.
  def test_a_leftover_part_file_is_not_mistaken_for_media
    File.write(File.join(@dir, 'posts', "#{POST_ID}.xmp"), 'sidecar only')
    File.write(File.join(@dir, 'posts', "#{POST_ID}.png.part"), 'half a download')
    @archiver.scan_output_dir

    assert_equal [POST_ID], @archiver.sidecars_without_media
  end

  # Bytes the integrity check set aside are not media either.
  def test_damaged_bytes_set_aside_are_not_mistaken_for_media
    File.write(File.join(@dir, 'posts', "#{POST_ID}.xmp"), 'sidecar only')
    File.write(File.join(@dir, 'posts', "#{POST_ID}.png.damaged-20260928T101112Z"), 'truncated')
    @archiver.scan_output_dir

    assert_equal [POST_ID], @archiver.sidecars_without_media
  end

  def test_the_orphan_is_looked_up_by_id_and_queued
    archive_with_a_orphan_sidecar
    asked = nil
    found = JSON.generate([post])
    stub_http_get(@archiver) do |uri, _n|
      asked = query_params(uri)['tags']
      StubHttp::Response.new(200, found)
    end
    # A block handed to define_singleton_method becomes a method body, so `self`
    # is the archiver: anything from the test has to be captured in a local.
    out_dir = File.join(@dir, 'posts')
    @archiver.define_singleton_method(:post_file_url) { |p| p.dig('files', 'original', 'url') }
    @archiver.define_singleton_method(:post_locations) do |_p|
      [Archiver::Location.new(out_dir, nil)]
    end
    @archiver.define_singleton_method(:download_media) do |_url, output, _id, _md5, thread_idx: nil|
      File.binwrite(output, 'fetched')
      true
    end
    @archiver.define_singleton_method(:write_sidecar) { |_m, _p| true }

    stats = Stats.new
    processor = PostProcessor.new(rate_limiter: @archiver.rate_limiter, output_dir: @dir,
                                  stats: stats, thread_count: 1, archiver: @archiver)
    @archiver.repair_missing_media(processor, stats)
    processor.finish
    processor.wait

    assert_equal "id:#{POST_ID}", asked, 'the post is asked for directly, not via a tag query'
    assert_equal 1, stats.total_posts
    assert_equal 1, stats.downloaded_files
    assert File.exist?(File.join(@dir, 'posts', "#{POST_ID}.png")), 'and the media is back'
  end

  def test_repair_can_be_switched_off
    archive_with_a_orphan_sidecar
    asked = false
    stub_http_get(@archiver) do |_uri, _n|
      asked = true
      StubHttp::Response.new(200, JSON.generate([post]))
    end
    off = E621Archiver.new(output_dir: @dir, db_path: @db_path, username: 't', api_key: 'k',
                           rate_limit: 1000, repair_missing: false)
    off.ensure_rate_limiter
    stub_http_get(off) do |_uri, _n|
      asked = true
      StubHttp::Response.new(200, JSON.generate([post]))
    end

    stats = Stats.new
    processor = PostProcessor.new(rate_limiter: off.rate_limiter, output_dir: @dir,
                                  stats: stats, thread_count: 1, archiver: off)
    off.repair_missing_media(processor, stats)
    processor.finish
    processor.wait

    refute asked, 'no API request is made when the repair is off'
    assert_equal 0, stats.total_posts
  end

  # A post that is gone from the site entirely must not fail the run.
  def test_a_post_that_no_longer_exists_does_not_fail_the_run
    archive_with_a_orphan_sidecar
    stub_http_get(@archiver) { |_uri, _n| StubHttp::Response.new(200, JSON.generate([])) }

    stats = Stats.new
    processor = PostProcessor.new(rate_limiter: @archiver.rate_limiter, output_dir: @dir,
                                  stats: stats, thread_count: 1, archiver: @archiver)
    @archiver.repair_missing_media(processor, stats)
    processor.finish
    processor.wait

    assert_equal 0, stats.total_posts
    assert_equal 0, stats.failed_files
  end

  # --- the stall watchdog ---------------------------------------------------

  # A wedged run looks exactly like a slow one from outside, and burning hours
  # silently is the worst outcome, so the run has to say something.
  def test_a_stalled_run_says_so
    @archiver.reset_progress
    warnings = []

    Rubichiver::Logger.stub(:warn, ->(message, _ctx = {}) { warnings << message }) do
      late = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Archiver::STALL_WARN_SECONDS + 30
      @archiver.check_for_stall(late)

      assert_equal 1, warnings.size
      assert_match(/No progress/, warnings.first)
      assert_match(/disk stall/, warnings.first)
    end
  end

  def test_waiting_for_download_backoff_is_not_reported_as_a_disk_stall
    @archiver.reset_progress
    warnings = []
    retry_only = Object.new
    retry_only.define_singleton_method(:waiting_for_download_retry?) { true }
    late = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Archiver::STALL_WARN_SECONDS + 30

    Rubichiver::Logger.stub(:warn, ->(message, _ctx = {}) { warnings << message }) do
      assert_nil @archiver.check_for_stall(late, retry_only)
    end

    assert_empty warnings
  end

  def test_a_making_progress_run_is_not_warned_about
    @archiver.reset_progress
    warnings = []

    Rubichiver::Logger.stub(:warn, ->(message, _ctx = {}) { warnings << message }) do
      assert_nil @archiver.check_for_stall
    end

    assert_empty warnings, 'a healthy run is not nagged'
  end

  def test_progress_resets_the_idle_timer
    @archiver.reset_progress
    # Pretend the run has been silent for far longer than the threshold.
    mutex = @archiver.instance_variable_get(:@progress_mutex)
    mutex.synchronize do
      @archiver.instance_variable_set(:@progress_at,
                                      Process.clock_gettime(Process::CLOCK_MONOTONIC) -
                                      (Archiver::STALL_WARN_SECONDS * 3))
    end
    @archiver.note_progress
    warnings = []

    Rubichiver::Logger.stub(:warn, ->(message, _ctx = {}) { warnings << message }) do
      half = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (Archiver::STALL_WARN_SECONDS / 2)
      assert_nil @archiver.check_for_stall(half)
    end

    assert_empty warnings, 'recording progress restarts the idle timer'
    assert_equal 1, @archiver.instance_variable_get(:@progress_count)
  end

  # --- sidecars for formats exiftool cannot write ---------------------------

  # exiftool chooses the output format from the file extension. A temporary name
  # ending in .part made it fall back to the input format, which it cannot write
  # for webm ("Writing of WEBM files is not yet supported"), so every webm post
  # failed to get a sidecar and was counted as a run failure.
  def test_a_webm_post_gets_a_sidecar
    skip 'exiftool not installed' unless system('exiftool -ver >/dev/null 2>&1')

    media = File.join(@dir, 'posts', "#{POST_ID}.webm")
    File.binwrite(media, minimal_webm)
    @archiver.instance_variable_set(:@sidecar_index, nil)

    assert_equal true, @archiver.write_sidecar(media, post(POST_ID)),
                 'a webm must get a sidecar, not a failure'

    sidecar = File.join(@dir, 'posts', "#{POST_ID}.xmp")
    assert File.exist?(sidecar)
    assert_equal 'bob', `exiftool -s3 -XMP-dc:Creator #{sidecar}`.strip
  end

  def test_a_webm_failure_is_not_left_behind_as_a_temp_file
    File.binwrite(File.join(@dir, 'posts', "#{POST_ID}.webm"), 'not a webm at all')
    @archiver.write_sidecar(File.join(@dir, 'posts', "#{POST_ID}.webm"), post(POST_ID))
    @archiver.scan_output_dir

    leftovers = Dir.children(@dir).select { |name| name.match?(Archiver::SIDECAR_TMP_PATTERN) }
    assert_empty leftovers, 'a failed write cleans up after itself'
  end

  # A one-frame VP8 keyframe wrapped in a minimal Matroska/WebM container, which
  # is all exiftool needs to recognise the file.
  def minimal_webm
    data = File.binread(File.expand_path('support/1x1.webm', __dir__))
    data
  end

  def test_an_abandoned_sidecar_part_file_is_cleaned_up
    File.binwrite(File.join(@dir, 'posts', "#{POST_ID}.png"), 'media')
    abandoned = "#{POST_ID}.xmp.999#{Archiver::PART_SUFFIX}#{Archiver::SIDECAR_SUFFIX}"
    File.write(File.join(@dir, 'posts', abandoned), 'half written')
    @archiver.scan_output_dir

    refute File.exist?(File.join(@dir, 'posts', abandoned)), 'a killed run leaves nothing behind'
  end

  def test_an_abandoned_sidecar_part_is_not_mistaken_for_a_real_sidecar
    File.write(File.join(@dir, 'posts', "#{POST_ID}.xmp.999#{Archiver::PART_SUFFIX}#{Archiver::SIDECAR_SUFFIX}"), 'half')
    @archiver.scan_output_dir

    assert_empty @archiver.sidecars_without_media, 'a part-written sidecar is not an orphan'
  end

  # --- offline repair from the stored record --------------------------------

  # A file whose sidecar was never finished is completed from the database,
  # with no API call at all. That is how a killed run heals: the record and the
  # bytes are both there, only the metadata file is missing.
  def test_a_sidecar_is_rebuilt_from_the_stored_record
    media = File.join(@dir, 'posts', "#{POST_ID}.png")
    File.binwrite(media, 'media')
    @archiver.scan_output_dir
    @archiver.record_post_metadata(post)
    # The file row says the sidecar was never finished, exactly as a run killed
    # between writing the two would leave it.
    @archiver.db.record_file(post_id: POST_ID, path: "posts/#{POST_ID}.png", dir: 'posts',
                             ext: 'png', bytes: File.size(media), sidecar: false)
    stats = Struct.new(:done).new(0)
    stats.define_singleton_method(:increment) { |_stat| self.done += 1 }

    wrote = []
    @archiver.define_singleton_method(:write_sidecar) do |file, _post|
      wrote << file
      true
    end
    @archiver.repair_sidecars_from_db(stats)

    assert_equal [media], wrote
    assert_equal 1, stats.done
    assert_equal 1, @archiver.db.file(POST_ID)['sidecar'], 'the finish is recorded'
  end

  # A sidecar that already agrees with the stored record is left alone: rebuilding
  # every sidecar on every run would be pure churn.
  def test_a_current_sidecar_is_not_rebuilt_offline
    media = File.join(@dir, 'posts', "#{POST_ID}.png")
    File.binwrite(media, 'media')
    @archiver.scan_output_dir
    @archiver.record_post_metadata(post)
    assert_equal true, @archiver.write_sidecar(media, post)
    @archiver.db.record_file(post_id: POST_ID, path: "posts/#{POST_ID}.png", dir: 'posts',
                             ext: 'png', bytes: File.size(media), sidecar: true)

    stats = Struct.new(:done).new(0)
    stats.define_singleton_method(:increment) { |_stat| self.done += 1 }
    @archiver.define_singleton_method(:write_sidecar) do |_file, _post|
      raise 'an offline pass must not rewrite a sidecar that is already current'
    end

    @archiver.repair_sidecars_from_db(stats)
    assert_equal 0, stats.done
  end

  # But a sidecar from an older format -- keywords only -- is "finished" as far as
  # the flag is concerned while saying far less than the archive knows. Nothing
  # else would ever revisit it: a post is only re-fetched when a tag query
  # happens to return it, so one outside every query keeps the short sidecar
  # forever.
  def test_an_outdated_sidecar_is_rebuilt_offline
    media = File.join(@dir, 'posts', "#{POST_ID}.png")
    File.binwrite(media, 'media')
    File.write(File.join(@dir, 'posts', "#{POST_ID}.xmp"),
               "<x:xmpmeta><rdf:RDF><rdf:Description><dc:subject><rdf:Bag>" \
               "<rdf:li>rating:s</rdf:li></rdf:Bag></dc:subject>" \
               '</rdf:Description></rdf:RDF></x:xmpmeta>')
    @archiver.scan_output_dir
    @archiver.record_post_metadata(post)
    @archiver.db.record_file(post_id: POST_ID, path: "posts/#{POST_ID}.png", dir: 'posts',
                             ext: 'png', bytes: File.size(media), sidecar: true)
    stats = Struct.new(:done).new(0)
    stats.define_singleton_method(:increment) { |_stat| self.done += 1 }

    rebuilt = []
    @archiver.define_singleton_method(:write_sidecar) do |file, _post|
      rebuilt << file
      true
    end

    @archiver.repair_sidecars_from_db(stats)

    assert_equal [media], rebuilt
    assert_equal 1, stats.done
  end

  # --- recache repairs sidecars ---------------------------------------------

  def test_recache_regenerates_a_missing_sidecar
    media = File.join(@dir, 'posts', "#{POST_ID}.png")
    File.binwrite(media, 'media with no sidecar beside it')
    @archiver.scan_output_dir
    @archiver.instance_variable_set(:@sidecar_index, nil)
    found = JSON.generate([post])
    stub_http_get(@archiver) { |_uri, _n| StubHttp::Response.new(200, found) }
    @archiver.define_singleton_method(:sidecar_valid?) { |_p, _l = nil| false }
    written = []
    @archiver.define_singleton_method(:write_sidecar) do |file, _p|
      written << file
      true
    end

    @archiver.recache_all_post_tags

    assert_equal [media], written, 'the sidecar for a file that had none is regenerated'
  end

  def test_recache_leaves_a_current_sidecar_alone
    media = File.join(@dir, 'posts', "#{POST_ID}.png")
    File.binwrite(media, 'media')
    File.write(File.join(@dir, 'posts', "#{POST_ID}.xmp"), 'current')
    @archiver.scan_output_dir
    @archiver.instance_variable_set(:@sidecar_index, nil)
    found = JSON.generate([post])
    stub_http_get(@archiver) { |_uri, _n| StubHttp::Response.new(200, found) }
    @archiver.define_singleton_method(:sidecar_valid?) { |_p, _l = nil| true }
    written = []
    @archiver.define_singleton_method(:write_sidecar) do |file, _p|
      written << file
      true
    end

    @archiver.recache_all_post_tags

    assert_empty written, 'a sidecar that is already current is not rewritten'
  end
end
