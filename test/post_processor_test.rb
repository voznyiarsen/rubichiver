# frozen_string_literal: true

require_relative 'test_helper'

class PostProcessorUnitTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, 'posts'))
    @stats = Stats.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # A real archiver with the network-facing pieces stubbed, so the location
  # and bookkeeping machinery is exercised rather than re-implemented here.
  class TestArchiver < Archiver
    attr_reader :downloaded

    def site_name
      'test'
    end

    def default_output_dir
      @output_dir
    end

    def post_file_url(post)
      post['file_url']
    end

    def post_file_ext(post)
      ext = File.extname(post['image'] || '').delete('.').downcase
      ext.empty? ? 'unknown' : ext
    end

    def post_md5(post)
      post['md5']
    end

    def resolve_served_extension(post, orig_ext, file_url)
      url_ext = File.extname(URI.parse(file_url || '').path).delete('.').downcase rescue ''
      url_ext.empty? ? orig_ext : url_ext
    end

    def extract_post_tags(post)
      (post['tags'] || '').to_s.split
    end

    def rating_value(_rating)
      '1'
    end

    def rating_label(_post)
      'safe'
    end

    def sidecar_valid?(_post, _location = nil)
      true
    end

    def download_media(_url, output_file, _post_id, _md5, thread_idx: nil)
      @downloaded << output_file
      File.write(output_file, 'fake')
      true
    end

    def write_sidecar(_media_file, _post)
      true
    end
  end

  def build_archiver(dir)
    archiver = TestArchiver.new(output_dir: dir, username: 'tester', api_key: 'key', rate_limit: 1000)
    archiver.instance_variable_set(:@downloaded, [])
    archiver
  end

  def processor(archiver, stats)
    PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: archiver.output_dir,
      stats: stats,
      thread_count: 0,
      archiver: archiver
    )
  end

  def test_output_file_uses_served_extension
    archiver = build_archiver(@dir)
    pp = processor(archiver, @stats)
    post = {
      'id' => 42,
      'image' => 'orig.webm',
      'file_url' => 'https://gelbooru.com/images/42/abc123.mp4',
      'md5' => 'deadbeef',
      'tags' => 'cat',
      'rating' => 'safe'
    }

    pp.send(:process_post, post, 0)

    assert File.exist?(File.join(@dir, 'posts', '42.mp4'))
  end

  def test_output_file_falls_back_to_original_extension
    archiver = build_archiver(@dir)
    pp = processor(archiver, @stats)
    post = {
      'id' => 7,
      'image' => 'orig.png',
      'file_url' => 'https://gelbooru.com/images/7/abc.png',
      'md5' => 'feedface',
      'tags' => 'dog',
      'rating' => 'safe'
    }

    pp.send(:process_post, post, 0)

    assert File.exist?(File.join(@dir, 'posts', '7.png'))
  end

  def test_unsupported_extension_skips_download
    archiver = build_archiver(@dir)
    pp = processor(archiver, @stats)
    post = {
      'id' => 9,
      'image' => 'orig.swf',
      'file_url' => 'https://x/9.swf',
      'md5' => 'x',
      'tags' => 'a',
      'rating' => 'safe'
    }

    pp.send(:process_post, post, 0)

    refute File.exist?(File.join(@dir, 'posts', '9.swf'))
    assert_equal 1, @stats.skipped_files
  end

  def test_existing_valid_sidecar_skips_download
    post = {
      'id' => 55,
      'image' => '55.jpeg',
      'file_url' => 'https://x/55.jpeg',
      'md5' => 'y',
      'tags' => 'cat',
      'rating' => 'safe'
    }

    File.write(File.join(@dir, 'posts', '55.jpeg'), 'x')

    archiver = build_archiver(@dir)
    archiver.scan_output_dir
    pp = processor(archiver, @stats)

    pp.send(:process_post, post, 0)

    assert_equal 1, @stats.skipped_files
    assert_empty archiver.downloaded
  end

  def test_existing_file_with_invalid_sidecar_regenerates
    post = {
      'id' => 56,
      'image' => '56.jpeg',
      'file_url' => 'https://x/56.jpeg',
      'md5' => 'y',
      'tags' => 'cat',
      'rating' => 'safe'
    }

    File.write(File.join(@dir, 'posts', '56.jpeg'), 'x')

    archiver = build_archiver(@dir)
    def archiver.sidecar_valid?(_post, _location = nil)
      false
    end
    archiver.scan_output_dir
    pp = processor(archiver, @stats)

    pp.send(:process_post, post, 0)

    assert_equal 1, @stats.autotagged_files
  end

  # Pool bundling can queue the same post more than once; it must be placed
  # once per location or two workers would write the same .part file.
  def test_a_post_is_placed_once_per_location
    post = { 'id' => 60, 'image' => '60.png', 'file_url' => 'https://x/60.png', 'md5' => 'z',
             'tags' => 'cat', 'rating' => 'safe' }
    archiver = build_archiver(@dir)
    pp = processor(archiver, @stats)

    3.times { pp.send(:process_post, post, 0) }

    assert_equal 1, archiver.downloaded.size
    assert_equal 1, @stats.downloaded_files
  end
end

class E621PostProcessorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, 'posts'))
    @stats = Stats.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_process_e621_post
    post = {
      'id' => 100,
      'rating' => 's',
      'tags' => { 'general' => ['cat'], 'artist' => ['bob'] },
      'files' => {
        'original' => { 'url' => 'https://cdn.e621.net/data/abc.jpg' },
        'meta' => { 'ext' => 'jpg', 'md5' => 'deadbeef' }
      }
    }

    archiver = E621Archiver.new(
      output_dir: @dir,
      username: 'tester',
      api_key: 'key',
      rate_limiter: RateLimiter.new(requests_per_second: 1000)
    )
    archiver.existing_posts = {}

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

    pp = PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: @dir,
      stats: @stats,
      thread_count: 0,
      archiver: archiver
    )
    pp.send(:process_post, post, 0)

    assert_equal 1, @stats.downloaded_files
    assert File.exist?(File.join(@dir, 'posts', '100.jpg'))
  end
end

class GelbooruPostProcessorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, 'posts'))
    @stats = Stats.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_process_gelbooru_post
    post = {
      'id' => 200,
      'image' => '200.png',
      'file_url' => 'https://gelbooru.com/images/200/abc.png',
      'md5' => 'feedface',
      'tags' => 'cat dog',
      'rating' => 'safe'
    }

    archiver = GelbooruArchiver.new(
      output_dir: @dir,
      api_key: 'key',
      user_id: '1',
      rate_limiter: RateLimiter.new(requests_per_second: 1000)
    )
    archiver.existing_posts = {}

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

    pp = PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: @dir,
      stats: @stats,
      thread_count: 0,
      archiver: archiver
    )
    pp.send(:process_post, post, 0)

    assert_equal 1, @stats.downloaded_files
    assert File.exist?(File.join(@dir, 'posts', '200.png'))
  end

  def test_categorize_tags
    archiver = GelbooruArchiver.new(
      output_dir: @dir,
      api_key: 'key',
      user_id: '1'
    )
    cats = archiver.categorize_tags('artist:alice character:bob copyright:series_x plain_tag')
    assert_equal ['alice'], cats['artist']
    assert_equal ['bob'], cats['character']
    assert_equal ['series_x'], cats['copyright']
    assert_equal ['plain_tag'], cats['general']
    cats2 = archiver.categorize_tags('rating:safe')
    assert_empty cats2['general']
  end
end
