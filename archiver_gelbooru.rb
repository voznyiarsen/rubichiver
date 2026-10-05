# frozen_string_literal: true

require 'json'
require 'uri'
require 'net/http'
require 'digest'
require_relative 'archiver_base'

class GelbooruArchiver < Archiver
  DEFAULT_API_BASE = 'https://gelbooru.com'
  API_BASE = ENV['RUBICHIVER_GELBOORU_API'] || DEFAULT_API_BASE
  API_PATH = '/index.php'
  PAGE_LIMIT = 100
  TAG_TYPE_BATCH = 100

  # Gelbooru returns "general" for some posts, not only safe/questionable/
  # explicit/sensitive. It is the lowest of the ratings -- the counterpart of
  # e621's "g" -- so it maps like "safe". Leaving it out means no sidecar is ever
  # written for such a post: the rating does not resolve, the write is skipped as
  # "unrated", and since a post is only revisited when a tag query happens to
  # return it, the media then sits beside a missing sidecar indefinitely.
  RATING_MAP = {
    'safe' => '1', 's' => '1', 'g' => '1', 'general' => '1',
    'questionable' => '2', 'q' => '2',
    'explicit' => '3', 'e' => '3',
    'sensitive' => '2'
  }.freeze

  RATING_LABELS = {
    'safe' => 'safe', 's' => 'safe', 'g' => 'safe', 'general' => 'safe',
    'questionable' => 'questionable', 'q' => 'questionable',
    'explicit' => 'explicit', 'e' => 'explicit',
    'sensitive' => 'sensitive'
  }.freeze

  TAG_PREFIX_MAP = {
    'artist' => 'artist',
    'character' => 'character',
    'copyright' => 'copyright',
    'series' => 'copyright',
    'circle' => 'contributor',
    'studio' => 'contributor',
    'metadata' => 'metadata',
    'style' => 'metadata',
    'species' => 'species',
    'lore' => 'lore',
    'invalid' => 'invalid',
    'invalid_tag' => 'invalid',
    'contributor' => 'contributor',
    'rating' => 'rating'
  }.freeze

  # Gelbooru's tag type ids. 6 is invalid, not metadata, and 7 is metadata —
  # getting these the wrong way round mislabels every affected keyword.
  TAG_TYPE_MAP = {
    0 => 'general',
    1 => 'artist',
    3 => 'copyright',
    4 => 'character',
    5 => 'species',
    6 => 'invalid',
    7 => 'metadata'
  }.freeze

  def default_output_dir
    './gelbooru-archive'
  end

  def site_name
    'gelbooru'
  end

  def requires_user_id?
    true
  end

  def api_base
    @api_base || API_BASE
  end

  def user_agent
    "rubichiver/#{Rubichiver::VERSION} (gelbooru media archiver)"
  end

  def request_headers
    { 'Referer' => "#{api_base}/" }
  end

  def load_credentials_from_file
    username = nil
    api_key = nil
    user_id = nil

    File.foreach(@credentials_file) do |line|
      line = line.strip
      if line.start_with?('USERNAME=')
        username = line.split('=', 2).last
      elsif line.start_with?('API_KEY=')
        api_key = line.split('=', 2).last
      elsif line.start_with?('USER_ID=')
        user_id = line.split('=', 2).last
      end
    end

    [username, api_key, user_id]
  end

  def post_file_url(post)
    post['file_url']
  end

  def post_file_ext(post)
    image_name = post['image'] || ''
    ext = File.extname(image_name).delete('.').downcase
    ext.empty? ? 'unknown' : ext
  end

  def post_md5(post)
    post['md5']
  end

  def post_tag_names(post)
    post['tags'].to_s.split
  end

  def resolve_served_extension(post, orig_ext, file_url)
    url_ext = begin
      File.extname(URI.parse(file_url || '').path).delete('.').downcase
    rescue URI::InvalidURIError
      ''
    end

    url_ext.empty? ? orig_ext : url_ext
  end

  def query_cache_hash(tags)
    Digest::SHA256.hexdigest("gelbooru:#{tags.join(' ')}")
  end

  def normalize_posts(data)
    return nil unless data.is_a?(Hash)

    posts = data['post']
    return [] if posts.nil?
    return [posts] unless posts.is_a?(Array)

    posts
  end

  def api_search_posts(tags, page, force: false, cache: true, thread_idx: nil)
    context = { tags: tags.join(' '), page: page }
    cache_path = api_cache_path(query_cache_hash(tags), page)

    if cache && !force
      cached = read_api_cache(cache_path)
      if cached.is_a?(Hash) && cached['@attributes']
        posts = normalize_posts(cached)
        if posts
          count = cached.dig('@attributes', 'count') || posts.size
          log_debug "Using cached API response for: #{tags.join(' ')} (page #{page}, #{posts.size} posts, total=#{count})",
                    page: page, cached: posts.size, api: true
          return Archiver::ApiResult.new(posts, count, nil, cached)
        end
      end
      log_debug "Cached data is invalid for: #{tags.join(' ')} (page #{page}), re-fetching", page: page, api: true
    end

    params = {
      page: 'dapi', s: 'post', q: 'index',
      tags: tags.join(' '), pid: page - 1, limit: PAGE_LIMIT, json: 1
    }.merge(api_credentials_params)

    result = api_post_index(params, context, thread_idx: thread_idx)
    return result unless result.ok?

    write_api_cache(cache_path, result.payload) if cache
    log_debug "Cached API response: #{tags.join(' ')} (page #{page}, #{result.posts.size} posts, total=#{result.total})",
              page: page, api: true
    result
  end

  def api_post_index(params, context, thread_idx: nil)
    uri = URI("#{api_base}#{API_PATH}")
    uri.query = URI.encode_www_form(params)

    response = api_get(uri, context, thread_idx: thread_idx)
    unless response
      return Archiver::ApiResult.new(nil, 0, "request failed after #{MAX_RETRIES} attempts")
    end

    unless response.is_a?(Net::HTTPSuccess)
      log_error "API search failed", tags: context[:tags], page: context[:page], status: response.code, api: true
      return Archiver::ApiResult.new(nil, 0, "HTTP #{response.code}")
    end

    data = parse_json(response.body, context)
    return Archiver::ApiResult.new(nil, 0, 'unparsable response') unless data

    unless data.is_a?(Hash) && data['@attributes']
      log_error "API response missing @attributes metadata", tags: context[:tags], page: context[:page], api: true
      return Archiver::ApiResult.new(nil, 0, 'missing @attributes')
    end

    posts = normalize_posts(data)
    return Archiver::ApiResult.new(nil, 0, 'no post data') unless posts

    Archiver::ApiResult.new(posts, data.dig('@attributes', 'count') || posts.size, nil, data)
  end

  def parse_json(body, context)
    JSON.parse(body)
  rescue JSON::ParserError, Zlib::BufError, IOError => e
    log_error "Failed to parse API response", error: e.message, tags: context[:tags], api: true
    nil
  end

  def api_credentials_params
    { api_key: @api_key, user_id: @user_id }
  end

  def cache_needs_update?(query_tags)
    cached_p1 = read_api_cache(api_cache_path(query_cache_hash(query_tags), 1))
    posts = normalize_posts(cached_p1)
    return [true, nil, 0] if posts.nil? || posts.empty?

    fresh = api_search_posts(query_tags, 1, force: true)
    return [false, nil, 0] unless fresh.ok?

    [posts.map { |post| post['id'] }.sort != fresh.posts.map { |post| post['id'] }.sort,
     fresh.posts, fresh.total]
  end

  def clear_tag_cache(tags)
    query_hash = query_cache_hash(tags)
    Dir.glob(File.join(@cache_dir, "api_posts_#{query_hash}_p*.json")).each do |file|
      File.delete(file)
      log_debug "Deleted cache file: #{File.basename(file)}", api: true
    end
  end

  def fetch_all_posts_for_query(query_tags, seen_ids, stats)
    query_str = query_tags.join(' ')
    log_info "Fetching posts for: #{query_str}", query: query_str, api: true

    needs_update, fresh_p1, fresh_count = cache_needs_update?(query_tags)
    if needs_update
      log_info "Cache update needed for: #{query_str}, refreshing...", query: query_str, api: true
      clear_tag_cache(query_tags)
      fresh_p1 = nil
    else
      log_info "Cache is up to date for: #{query_str}", query: query_str, api: true
    end

    all_posts = []
    page = 1
    total_count = nil

    loop do
      if page == 1 && fresh_p1
        posts = fresh_p1
        count = fresh_count
      else
        result = api_search_posts(query_tags, page)
        break unless result.ok?

        posts = result.posts
        count = result.total
      end
      total_count = count.to_i if count.to_i.positive?
      break if posts.empty?

      log_debug "Page #{page}: #{posts.size} posts, total=#{total_count || '?'}", page: page, api: true

      posts.each do |post|
        post_id = post['id']
        next if seen_ids.include?(post_id)
        seen_ids.add(post_id)

        if blacklisted_post?(post)
          log_debug "Post #{post_id}: Blacklisted, skipping", post_id: post_id, api: true
          stats.increment(:blacklisted_files)
          next
        end

        unless post['file_url']
          log_debug "Post #{post_id}: No file URL, skipping", post_id: post_id, api: true
          next
        end

        stats.increment(:total_posts)
        all_posts << post
      end

      log_debug "Page #{page}: #{all_posts.size}/#{total_count || '?'} unique posts collected so far", api: true
      break if total_count && all_posts.size >= total_count
      page += 1
    end

    resolve_tag_types_for_posts(all_posts)

    all_posts
  end

  # Gelbooru's tag matcher accepts a single id per request, so there is no bulk
  # lookup to batch: recaching costs one request per archived post.
  def recache_batch_size
    1
  end

  def fetch_posts_by_ids(ids)
    posts = []

    ids.each do |id|
      break if @interrupted

      post = fetch_post_by_id(id)
      posts << post if post
    end

    Archiver::ApiResult.new(posts, posts.size, nil)
  end

  def fetch_post_by_id(id)
    context = { tags: "id:#{id}", page: 1 }
    params = { page: 'dapi', s: 'post', q: 'index', id: id, json: 1 }.merge(api_credentials_params)
    result = api_post_index(params, context)
    return nil unless result.ok?

    result.posts.first
  end

  def categorize_tags(tag_string)
    categories = Hash.new { |hash, key| hash[key] = [] }

    tag_string.split.each do |tag|
      if tag.include?(':')
        prefix, name = tag.split(':', 2)
        next if prefix == 'rating'
        categories[TAG_PREFIX_MAP[prefix] || 'general'] << name
      else
        categories[tag_type_cache[tag] || 'general'] << tag
      end
    end

    categories
  end

  def tag_type_cache
    @tag_type_cache ||= {}
  end

  # Tag category lookups survive between runs in the archive database, so a
  # long-lived archive asks the tag API about each tag once rather than once
  # per run. This is the single largest API cost Gelbooru would otherwise pay.
  def prime_tag_types(cached)
    cache = tag_type_cache
    cache.merge!(cached)
  end

  def flush_tag_types
    return unless @db.enabled?
    return if @tag_type_cache.nil? || @tag_type_cache.empty?

    @db.remember_tag_types(@tag_type_cache)
  end

  # Gelbooru returns tags as one flat string, so the tag API is the only source
  # for the category. Unknown tags stay 'general'.
  def resolve_tag_types(tag_names)
    return if tag_names.empty?
    ensure_rate_limiter

    cache = tag_type_cache
    unknown = tag_names.reject { |tag| cache.key?(tag) }
    return if unknown.empty?

    unknown.each_slice(TAG_TYPE_BATCH) do |batch|
      break if @interrupted

      params = {
        page: 'dapi', s: 'tag', q: 'index',
        names: batch.join(' '), json: 1
      }.merge(api_credentials_params)

      uri = URI("#{api_base}#{API_PATH}")
      uri.query = URI.encode_www_form(params)

      response = api_get(uri, { tags: 'tag index', page: 1 }, read_timeout: 30)
      next unless response.is_a?(Net::HTTPSuccess)

      data = parse_json(response.body, { tags: 'tag index' })
      next unless data.is_a?(Hash) && data['tag']

      tags = data['tag']
      tags = [tags] unless tags.is_a?(Array)
      tags.each do |tag|
        next unless tag.is_a?(Hash) && tag['name'] && tag['type']

        cache[tag['name']] = TAG_TYPE_MAP[tag['type'].to_i] || 'general'
      end
    end
  end

  def resolve_tag_types_for_posts(posts)
    unique_tags = Set.new
    posts.each { |post| (post['tags'] || '').split.each { |tag| unique_tags << tag } }
    resolve_tag_types(unique_tags.to_a)
  end

  def categorized_post_tags(post)
    categorized = categorize_tags(post['tags'] || '')
    TAG_CATEGORIES.each_with_object({}) do |category, result|
      names = categorized[category]
      result[category] = names if names.is_a?(Array) && !names.empty?
    end
  end

  def extract_post_tags(post)
    keywords = []
    categorized_post_tags(post).each do |category, tags|
      tags.each { |tag| keywords << "#{category}:#{tag}" }
    end
    keywords
  end

  def post_artists(post)
    Array(categorized_post_tags(post)['artist'])
  end

  # Gelbooru packs the source URLs into a single comma-separated field.
  def post_sources(post)
    post['source'].to_s.split(',').map(&:strip).reject(&:empty?)
  end

  def post_page_url(post)
    "#{api_base}/index.php?page=post&s=view&id=#{post['id']}"
  end

  def post_width(post)
    post['width']
  end

  def post_height(post)
    post['height']
  end

  # Gelbooru reports the upload time as a Unix timestamp under 'date', with an
  # ISO string under 'created_at' on newer responses. Both are normalised to ISO
  # UTC so the database can be queried by date.
  def post_timestamp(post, field)
    explicit = post[field].to_s
    return explicit unless explicit.strip.empty?

    return post['updated_at'] unless field == 'created_at'

    seconds = Integer(post['date'], exception: false)
    seconds && Time.at(seconds).utc.iso8601
  end

  def build_stored_post(record, categories, sources)
    # Re-emitted as prefixed forms so categorize_tags lands every stored
    # category back where it was: a stored contributor tag as plain 'foo' would
    # otherwise fall through to general.
    flat = categories.flat_map do |category, names|
      category == 'general' ? Array(names) : Array(names).map { |name| "#{category}:#{name}" }
    end.join(' ')
    { 'id' => record['post_id'], 'rating' => record['rating'],
      'created_at' => record['created_at'], 'updated_at' => record['updated_at'],
      'source' => sources.join(','), 'tags' => flat }
  end

  def post_metadata(post)
    super.merge(
      bytes: post['file_size'],
      width: post_width(post),
      height: post_height(post),
      uploader_id: post['uploader_id'],
      uploader_name: post['creator_name'],
      score_up: post['up'],
      score_down: post['down'],
      score_total: post['score'],
      comment_count: post['comments'],
      fav_count: post['fav_count'],
      # status is Gelbooru's own lifecycle word (active/pending/deleted) and has
      # no e621 equivalent, but it is the field that says whether a post is
      # still live, so it is worth keeping under the shared name.
      status: post['status'],
      creator_id: post['creator_id'],
      creator_anonymous: post['creator_anonymous'],
      num_notes: post['num_notes'],
      is_held: post['is_held'],
      is_pending: post['is_pending'],
      has_notes: post['has_notes'],
      preview_width: post['preview_width'] || post['sample_width'],
      sample_width: post['sample_width'],
      sample_height: post['sample_height'],
      raw_json: raw_post_json(post),
      variants: file_variants(post)
    )
  end

  # The whole record, verbatim. Gelbooru posts arrive flat, so this is the
  # only way fields rubichiver does not model are preserved.
  def raw_post_json(post)
    JSON.generate(post)
  rescue JSON::GeneratorError, SystemCallError
    nil
  end

  # Gelbooru serves the file at file_url and offers a sample and a preview as
  # separate URLs, all named by the post's own extension.
  def file_variants(post)
    ext = post_file_ext(post)
    { 'original' => post['file_url'], 'sample' => post['sample_url'], 'preview' => post['preview_url'] }
      .filter_map do |variant, url|
        next if url.to_s.empty?

        { 'variant' => variant, 'format' => ext, 'width' => nil, 'height' => nil, 'url' => url }
      end
  end

  def rating_value(rating)
    RATING_MAP[rating]
  end

  def rating_label(post)
    RATING_LABELS[post['rating']]
  end
end
