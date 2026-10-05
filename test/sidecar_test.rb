# frozen_string_literal: true

require_relative 'test_helper'

class SidecarValidationTest < Minitest::Test
  POST = { 'id' => 123, 'rating' => 'e', 'created_at' => '2026-07-28T02:20:59.721-04:00',
           'sources' => ['https://example.test/art/1'],
           'tags' => { 'general' => %w[anthro], 'artist' => %w[bob] } }.freeze

  def setup
    @dir = Dir.mktmpdir
    @posts = File.join(@dir, 'posts')
    FileUtils.mkdir_p(@posts)
    @archiver = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                 username: 'tester', api_key: 'key')
    @root = Archiver::Location.new(@posts, nil)
    @media = File.join(@posts, '123.png')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def exiftool?
    system('exiftool -ver >/dev/null 2>&1')
  end

  def drift(**changes)
    Marshal.load(Marshal.dump(POST)).merge(changes)
  end

  def write_real_sidecar
    FileUtils.cp(fixture_image, @media)
    @archiver.write_sidecar(@media, POST)
  end

  # A minimal hand-written sidecar carries the rating and keywords but none of
  # the provenance fields, so it is no longer current.
  def write_minimal_sidecar
    File.write(File.join(@posts, '123.xmp'), <<~XMP)
      <?xpacket begin=' ' id='W5M0MpCehiHzreSzNTczkc9d'?>
      <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"><xmp:Rating>3</xmp:Rating></rdf:Description>
      <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:subject><rdf:Bag><rdf:li>rating:explicit</rdf:li><rdf:li>general:anthro</rdf:li><rdf:li>artist:bob</rdf:li></rdf:Bag></dc:subject></rdf:Description>
      </rdf:RDF></x:xmpmeta>
      <?xpacket end='w'?>
    XMP
  end

  def fixture_image
    File.expand_path('support/1x1.png', __dir__)
  end

  def test_a_freshly_written_sidecar_is_current
    skip 'exiftool not installed' unless exiftool?
    write_real_sidecar
    assert @archiver.sidecar_valid?(POST, @root)
  end

  def test_missing_sidecar_is_invalid
    refute @archiver.sidecar_valid?(POST, @root)
  end

  def test_a_sidecar_missing_newer_fields_is_invalid
    skip 'exiftool not installed' unless exiftool?
    write_minimal_sidecar
    refute @archiver.sidecar_valid?(POST, @root),
           'a sidecar with only a rating and keywords is no longer current'
  end

  def test_malformed_sidecar_is_invalid
    File.write(File.join(@posts, '123.xmp'), "this is not xmp at all \x00\x01")
    refute @archiver.sidecar_valid?(POST, @root)
  end

  # --- drift detection ------------------------------------------------------
  #
  # A sidecar is only worth keeping if it is rewritten when the post changes.
  # The old check compared keywords as a subset, so a tag deleted upstream left
  # its keyword in the file forever.

  def test_removing_a_tag_invalidates_the_sidecar
    skip 'exiftool not installed' unless exiftool?
    write_real_sidecar
    changed = drift('tags' => { 'general' => [], 'artist' => %w[bob] })

    refute @archiver.sidecar_valid?(changed, @root)
    @archiver.write_sidecar(@media, changed)
    @archiver.instance_variable_set(:@sidecar_index, nil)

    assert @archiver.sidecar_valid?(changed, @root)
    assert_empty(sidecar_field('Subject') & %w[general:anthro])
  end

  def test_adding_a_tag_invalidates_the_sidecar
    skip 'exiftool not installed' unless exiftool?
    write_real_sidecar
    changed = drift('tags' => { 'general' => %w[anthro new_tag], 'artist' => %w[bob] })

    refute @archiver.sidecar_valid?(changed, @root)
  end

  def test_rating_drift_invalidates_the_sidecar
    skip 'exiftool not installed' unless exiftool?
    write_real_sidecar
    refute @archiver.sidecar_valid?(drift('rating' => 's'), @root)
  end

  def test_date_drift_invalidates_the_sidecar
    skip 'exiftool not installed' unless exiftool?
    write_real_sidecar
    refute @archiver.sidecar_valid?(drift('created_at' => '2020-01-01T00:00:00.000-04:00'), @root)
  end

  def test_source_drift_invalidates_the_sidecar
    skip 'exiftool not installed' unless exiftool?
    write_real_sidecar
    refute @archiver.sidecar_valid?(drift('sources' => ['https://elsewhere.test/2']), @root)
    refute @archiver.sidecar_valid?(drift('sources' => []), @root)
  end

  def test_uploader_is_a_creator_field_not_just_a_keyword
    skip 'exiftool not installed' unless exiftool?
    write_real_sidecar
    assert_equal %w[bob], Array(sidecar_field('Creator'))
  end

  # The version and the account name both live in CreatorTool, and neither says
  # anything about the post. A release or a rename must not rewrite every
  # sidecar in the archive, so only the tool name has to match.
  def test_a_newer_version_does_not_invalidate_the_sidecar
    assert @archiver.send(:creator_tool_matches?,
                          'rubichiver/0.9.0 (e621 media archiver, used by tester)',
                          'rubichiver/1.0.0 (e621 media archiver, used by tester)')
  end

  def test_a_renamed_account_does_not_invalidate_the_sidecar
    assert @archiver.send(:creator_tool_matches?,
                          'rubichiver/1.0.0 (e621 media archiver, used by oldname)',
                          'rubichiver/1.0.0 (e621 media archiver, used by newname)')
  end

  def test_a_sidecar_from_another_tool_is_still_invalid
    refute @archiver.send(:creator_tool_matches?, 'exiftool 13.25', 'rubichiver/1.0.0 (x)')
    refute @archiver.send(:creator_tool_matches?, nil, 'rubichiver/1.0.0 (x)')
    refute @archiver.send(:creator_tool_matches?, '', 'rubichiver/1.0.0 (x)')
  end

  def test_a_sidecar_written_by_an_older_release_is_current
    skip 'exiftool not installed' unless exiftool?
    FileUtils.cp(fixture_image, @media)
    @archiver.write_sidecar(@media, POST)
    @archiver.instance_variable_set(:@sidecar_index, nil)

    newer = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db2'),
                             username: 'someone-else', api_key: 'k')
    assert newer.sidecar_valid?(POST, @root),
           'version and account must not matter, only the post content'
  end

  def test_sidecar_carries_the_provenance_a_browser_needs
    skip 'exiftool not installed' unless exiftool?
    write_real_sidecar

    assert_includes sidecar_field('Title').to_s, '#123'
    assert_includes sidecar_field('Rights').to_s, '/posts/123'
    assert_includes sidecar_field('Description').to_s, 'https://example.test/art/1'
    assert_equal 3, sidecar_field('Rating')
    refute_nil sidecar_field('CreateDate')
  end

  # exiftool reports group-qualified names, which is how the archiver keys them.
  def sidecar_field(field)
    @archiver.sidecar_reading(POST['id'], @root)[Archiver::SIDECAR_FIELDS.fetch(field)]
  end
end

class WriteSidecarTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_e621_write_sidecar_skips_unrated
    archiver = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                username: 'tester', api_key: 'key')
    result = archiver.write_sidecar(File.join(@dir, '1.jpg'),
                                    'id' => 1, 'rating' => nil, 'tags' => {})
    assert_equal :unrated, result
    refute File.exist?(File.join(@dir, '1.xmp'))
  end

  def test_gelbooru_write_sidecar_skips_unrated
    archiver = GelbooruArchiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                    api_key: 'key', user_id: '1')
    result = archiver.write_sidecar(File.join(@dir, '2.jpg'),
                                    'id' => 2, 'rating' => nil, 'tags' => '')
    assert_equal :unrated, result
    refute File.exist?(File.join(@dir, '2.xmp'))
  end

  # Gelbooru really does return "general" for some posts. It was missing from the
  # rating maps, so those posts silently produced no sidecar at all -- and since
  # a post is only revisited when a tag query returns it, the media was left
  # beside a missing sidecar indefinitely.
  def test_gelbooru_writes_a_sidecar_for_the_general_rating_the_api_returns
    archiver = GelbooruArchiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                    api_key: 'key', user_id: '1')
    media = File.join(@dir, '3.jpg')
    File.write(media, 'bytes')

    result = archiver.write_sidecar(media, 'id' => 3, 'rating' => 'general', 'tags' => 'cat')

    assert_equal true, result
    assert File.exist?(File.join(@dir, '3.xmp'))
  end

  def test_gelbooru_maps_general_like_the_other_lowest_ratings
    archiver = GelbooruArchiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                    api_key: 'key', user_id: '1')
    assert_equal archiver.rating_value('g'), archiver.rating_value('general')
    assert_equal archiver.rating_label('rating' => 'g'), archiver.rating_label('rating' => 'general')
  end

  # A flat tag list has no categories. Writing guessed keywords would put the
  # wrong category in the archive, so nothing is written and the post is left
  # for a run that gets a categorised answer.
  def test_flat_tags_do_not_produce_a_keyword_sidecar
    archiver = E621Archiver.new(output_dir: @dir, db_path: File.join(@dir, 'db'),
                                username: 'tester', api_key: 'key')
    result = archiver.write_sidecar(File.join(@dir, '3.jpg'),
                                    'id' => 3, 'rating' => 's', 'tags' => %w[cat dog])

    assert_equal :uncategorized, result
    refute File.exist?(File.join(@dir, '3.xmp'))
    refute archiver.sidecar_valid?({ 'id' => 3, 'rating' => 's', 'tags' => %w[cat dog] },
                                   Archiver::Location.new(@dir, nil))
  end
end
