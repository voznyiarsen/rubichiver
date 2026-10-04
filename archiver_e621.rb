# frozen_string_literal: true

require 'json'
require 'uri'
require 'net/http'
require 'digest'
require 'fileutils'
require_relative 'archiver_base'

class E621Archiver < Archiver
  DEFAULT_API_BASE = 'https://e621.net'
  API_BASE = ENV['RUBICHIVER_E621_API'] || DEFAULT_API_BASE
  PAGE_LIMIT = 320
  MAX_PAGES = 2000
  POOL_DIR = 'pools'
  # Ids per request when filling in a pool. Kept well below the page limit so
  # the query string stays a sane length.
  POOL_POST_BATCH = 100

  RATING_MAP = {
    's' => '1',
    'q' => '2',
    'e' => '3'
  }.freeze

  RATING_LABELS = {
    's' => 'safe',
    'q' => 'questionable',
    'e' => 'explicit'
  }.freeze

  def default_output_dir
    './e621-archive'
  end

  def site_name
    'e621'
  end

  def requires_user_id?
    false
  end

  def pools_supported?
    true
  end

  def api_base
    @api_base || API_BASE
  end

  # e621 asks clients to identify themselves and to name the account in use.
  def user_agent
    "rubichiver/#{Rubichiver::VERSION} (e621 media archiver, used by #{@username})"
  end

  def load_credentials_from_file
    username = nil
    api_key = nil

    File.foreach(@credentials_file) do |line|
      line = line.strip
      if line.start_with?('USERNAME=')
        username = line.split('=', 2).last
      elsif line.start_with?('API_KEY=')
        api_key = line.split('=', 2).last
      end
    end

    [username, api_key, nil]
  end

  def post_file_url(post)
    post.dig('files', 'original', 'url')
  end

  def post_file_ext(post)
    post.dig('files', 'meta', 'ext') || 'unknown'
  end

  def post_md5(post)
    post.dig('files', 'meta', 'md5')
  end

  def api_search_posts(tags, page, force: false, cache: true, thread_idx: nil)
    context = { tags: tags.join(' '), page: page }
    cache_path = api_cache_path(query_hash(tags), page)

    if cache && !force
      cached = read_api_cache(cache_path)
      if cached.is_a?(Array)
        log_debug "Using cached API response for: #{tags.join(' ')} (page #{page}, #{cached.size} posts)",
                  page: page, cached: cached.size, api: true
        return Archiver::ApiResult.new(cached, cached.size, nil)
      end
    end

    uri = URI("#{api_base}/posts.json")
    uri.query = URI.encode_www_form(
      tags: tags.join(' '), page: page, limit: PAGE_LIMIT, v2: true, mode: 'extended'
    )

    response = api_get(uri, context, headers: { 'Authorization' => basic_auth_header },
                     thread_idx: thread_idx)
    unless response
      return Archiver::ApiResult.new(nil, 0, "request failed after #{MAX_RETRIES} attempts")
    end

    unless response.is_a?(Net::HTTPSuccess)
      log_error "API search failed", tags: context[:tags], page: page, status: response.code, api: true
      return Archiver::ApiResult.new(nil, 0, "HTTP #{response.code}")
    end

    posts = parse_posts_response(response.body, context)
    return Archiver::ApiResult.new(nil, 0, 'unrecognised response') unless posts

    write_api_cache(cache_path, posts) if cache
    log_debug "Cached API response: #{tags.join(' ')} (page #{page}, #{posts.size} posts)", api: true
    Archiver::ApiResult.new(posts, posts.size, nil)
  end

  # e621 is migrating from a { "posts": [...] } envelope to a bare array.
  # Returning [] for a shape we do not recognise would be indistinguishable
  # from "nothing new", so unrecognised payloads are reported as failures.
  def parse_posts_response(body, context)
    parsed = JSON.parse(body)
    case parsed
    when Array
      parsed
    when Hash
      posts = parsed['posts']
      if posts.is_a?(Array)
        log_warn "e621 returned a v1 (wrapped) response for: #{context[:tags]} — rubichiver asks for v2",
                 tags: context[:tags], page: context[:page], api: true
        posts
      else
        log_error "Unrecognised e621 response shape (top-level keys: #{parsed.keys.first(5).join(', ')})",
                  tags: context[:tags], page: context[:page], api: true
        nil
      end
    else
      log_error "Unrecognised e621 response type: #{parsed.class}",
                tags: context[:tags], page: context[:page], api: true
      nil
    end
  rescue JSON::ParserError => e
    log_error "Failed to parse API response", error: e.message, tags: context[:tags], api: true
    nil
  end

  def basic_auth_header
    "Basic #{["#{@username}:#{@api_key}"].pack('m0')}"
  end

  def query_hash(tags)
    Digest::SHA256.hexdigest("v2:#{tags.sort.join(' ')}")
  end

  def fetch_all_posts_for_query(query_tags, seen_ids, stats)
    query_str = query_tags.join(' ')
    log_info "Fetching posts for: #{query_str}", query: query_str, api: true

    # Read the cached page 1 before the live fetch overwrites it, otherwise the
    # two always look identical and no other page is ever refreshed.
    cached_p1 = read_api_cache(api_cache_path(query_hash(query_tags), 1))
    fresh = api_search_posts(query_tags, 1, force: true)
    return [] unless fresh.ok?

    needs_update = page_one_changed?(query_tags, cached_p1, fresh.posts)

    all_posts = []
    page = 1

    loop do
      break if page > MAX_PAGES

      posts =
        if page == 1
          fresh.posts
        else
          result = api_search_posts(query_tags, page, force: needs_update)
          if !result.ok? && !needs_update
            log_debug "Cache miss for page #{page}, fetching live", query: query_str, page: page, api: true
            result = api_search_posts(query_tags, page, force: true)
          end
          break unless result.ok?

          result.posts
        end
      break if posts.empty?

      posts.each do |post|
        post_id = post['id']
        next if seen_ids.include?(post_id)
        seen_ids.add(post_id)

        if blacklisted_post?(post)
          stats.increment(:blacklisted_files)
          next
        end

        unless post.dig('files', 'original', 'url')
          log_debug "Post #{post_id}: no original file URL, skipping", post_id: post_id, api: true
          next
        end

        stats.increment(:total_posts)
        all_posts << post
      end

      break if posts.size < PAGE_LIMIT
      page += 1
    end

    all_posts
  end

  # New posts on page 1 push older posts onto later pages, so any change means
  # every cached page for this query has to be refetched.
  def page_one_changed?(query_tags, cached_p1, fresh_p1)
    unless cached_p1.is_a?(Array) && !cached_p1.empty?
      log_debug "No usable cache for: #{query_tags.join(' ')}, performing full fetch", api: true
      return true
    end

    new_ids = fresh_p1.map { |post| post['id'] } - cached_p1.map { |post| post['id'] }
    if new_ids.any?
      log_info "New posts detected for: #{query_tags.join(' ')} (#{new_ids.size} new), updating cache...",
               query: query_tags.join(' '), new_posts: new_ids.size, api: true
      true
    else
      log_debug "No new posts for: #{query_tags.join(' ')}, using cached pages", api: true
      false
    end
  end

  # e621 accepts a comma-separated id list, so a whole batch goes in one query.
  # Not cached: the id list differs on every recache run.
  def fetch_posts_by_ids(ids)
    api_search_posts(["id:#{ids.join(',')}"], 1, force: true, cache: false)
  end

  # Tag names for the blacklist, in either the grouped (v1/v2 extended) or the
  # flat (v2 basic) shape.
  def post_tag_names(post)
    tag_data = post['tags']
    return [] if tag_data.nil?
    return tag_data.flatten if tag_data.is_a?(Array)

    tag_data.values.flatten
  end

  def extract_post_tags(post)
    tag_data = post['tags']

    if tag_data.is_a?(Array)
      warn_flat_tags
      return []
    end

    keywords = []
    categorized_post_tags(post).each do |category, tags|
      tags.each { |tag| keywords << "#{category}:#{tag}" }
    end
    keywords
  end

  # For the archive database. A flat tag list has no categories, so it is filed
  # under 'general' — honest for a query store, even though it is not good
  # enough for sidecar keywords.
  def categorized_post_tags(post)
    tag_data = post['tags']
    if tag_data.is_a?(Array)
      warn_flat_tags
      return tag_data.empty? ? {} : { 'general' => tag_data }
    end
    return {} unless tag_data.is_a?(Hash)

    TAG_CATEGORIES.each_with_object({}) do |category, result|
      names = tag_data[category]
      result[category] = names if names.is_a?(Array) && !names.empty?
    end
  end

  def post_artists(post)
    Array(categorized_post_tags(post)['artist'])
  end

  def post_sources(post)
    Array(post['sources']).map(&:to_s).reject(&:empty?)
  end

  def post_description(post)
    post['description']
  end

  def post_page_url(post)
    "#{api_base}/posts/#{post['id']}"
  end

  def post_width(post)
    post.dig('files', 'original', 'width') || post.dig('files', 'sample', 'width')
  end

  def build_stored_post(record, categories, sources)
    { 'id' => record['post_id'], 'rating' => record['rating'],
      'created_at' => record['created_at'], 'updated_at' => record['updated_at'],
      'description' => record['description'], 'sources' => sources,
      'pools' => @db.post_pools(record['post_id']).map { |id| { 'id' => id } },
      'tags' => categories }
  end

  def post_height(post)
    post.dig('files', 'original', 'height') || post.dig('files', 'sample', 'height')
  end

  # Everything the API offers for a post, so the archive database holds the
  # whole record rather than just enough to name a file.
  def post_metadata(post)
    super.merge(
      # A flat tag list has no categories. The database still files the tags
      # under 'general', but the sidecar must not guess keywords from them, so
      # the record marks where they came from.
      uncategorized: post['tags'].is_a?(Array),
      change_seq: post['change_seq'],
      bytes: post.dig('files', 'meta', 'size'),
      width: post_width(post),
      height: post_height(post),
      duration: post.dig('files', 'meta', 'duration'),
      uploader_id: post['uploader_id'],
      uploader_name: post['uploader_name'],
      approver_id: post['approver_id'],
      score_up: post.dig('stats', 'score', 'up'),
      score_down: post.dig('stats', 'score', 'down'),
      score_total: post.dig('stats', 'score', 'total'),
      fav_count: post.dig('stats', 'fav_count'),
      comment_count: post.dig('stats', 'comment_count'),
      parent_id: post.dig('relationships', 'parent_id'),
      child_count: Array(post.dig('relationships', 'children')).size,
      has_children: post.dig('has', 'children'),
      flags: post['flags'],
      stats: post['stats'],
      locked_tags: post['locked_tags']
    )
  end

  # Only reachable if the API answers mode=basic. Sidecar keywords are then
  # left unwritten rather than written under a guessed category, and the tags
  # are still recorded in the database under 'general'. Say so once.
  def warn_flat_tags
    return if @warned_flat_tags

    @warned_flat_tags = true
    log_warn "e621 returned a flat tag list instead of categorised tags; " \
             'sidecar keywords are withheld for these posts (tags are still recorded as general)',
             api: true
  end

  def rating_value(rating)
    RATING_MAP[rating]
  end

  def rating_label(post)
    RATING_LABELS[post['rating']]
  end

  # --- Pools ----------------------------------------------------------------

  def pool_directory(pool_id)
    File.join(@output_dir, POOL_DIR, "#{pool_id}_#{pool_slug(pool_id)}")
  end

  # A bundle directory has to be the same on every run, so the slug is frozen
  # the first time a pool is seen — and what is already on disk wins, because
  # that is where the files are.
  #
  # The order below is what makes a bundle survive the things that would
  # otherwise strand it: a lost or rebuilt database, a migration away from the
  # old JSON Lines journal, and a pool renamed upstream. In all three cases the
  # files are already sitting in a directory whose name is the answer, and
  # re-deriving it from the API would create a second directory instead.
  def pool_slug(pool_id)
    cached = @db&.pool(pool_id)
    return cached['slug'] if cached && !cached['slug'].to_s.empty?

    on_disk = pool_slugs_on_disk(pool_id)
    if on_disk.size > 1
      log_warn "Pool #{pool_id} has #{on_disk.size} bundle directories; adopting #{on_disk.first} " \
               'and leaving the others in place', pool_id: pool_id, directories: on_disk.join(', '), api: true
    end

    # A directory that already exists names the bundle. Only a pool with none is
    # named from the API, falling back to its id when that lookup fails — so the
    # slug is frozen either way.
    record_pool(pool_id, slug: on_disk.first)
  end

  # Bundle slugs already on disk for this pool, read from the directory names.
  def pool_slugs_on_disk(pool_id)
    root = File.join(@output_dir, POOL_DIR)
    return [] unless Dir.exist?(root)

    pattern = /\A#{Regexp.escape(pool_id.to_s)}_(.+)\z/
    Dir.children(root).select { |name| File.directory?(File.join(root, name)) }
       .filter_map { |name| name[pattern, 1] }
       .sort
  end

  # Records the pool and returns the frozen slug. An explicit slug (one a
  # directory is already named after) always wins; otherwise the API name is
  # used, or the pool's id when the pool cannot be looked up. The title is
  # refreshed every time and never affects the directory, so a renamed pool
  # still shows its new name in the database and in sidecar keywords.
  def record_pool(pool_id, slug: nil)
    pool = fetch_pool(pool_id)
    frozen = slug || (pool && slugify(pool['name'])) || "pool-#{pool_id}"
    @db&.record_pool(id: pool_id, name: pool && pool['name'], slug: frozen,
                     post_count: pool && pool['post_count'], active: pool && pool['is_active'])
    frozen
  end

  # Fetches a pool definition, tolerating both API shapes: the bare object and
  # the legacy { "pool": {...} } envelope. Successful lookups are memoised for
  # the run; failures are not, so a transient error is retried on the next use.
  def fetch_pool(pool_id, thread_idx: nil)
    @pool_cache ||= {}
    return @pool_cache[pool_id] if @pool_cache.key?(pool_id)

    uri = URI("#{api_base}/pools/#{pool_id}.json")
    context = { tags: "pool #{pool_id}", page: 1 }

    response = api_get(uri, context, headers: { 'Authorization' => basic_auth_header },
                       thread_idx: thread_idx)
    unless response
      log_warn "Could not fetch pool #{pool_id}", pool_id: pool_id, api: true
      return nil
    end

    unless response.is_a?(Net::HTTPSuccess)
      log_warn "Pool lookup failed", pool_id: pool_id, status: response.code, api: true
      return nil
    end

    pool = parse_pool(response.body, pool_id)
    unless pool
      log_warn "Pool #{pool_id} returned an unrecognised shape", pool_id: pool_id, api: true
      return nil
    end

    @pool_cache[pool_id] = pool
  end

  def parse_pool(body, pool_id)
    parsed = JSON.parse(body)
    pool = parsed.is_a?(Hash) ? (parsed['pool'] || parsed) : parsed
    return nil unless pool.is_a?(Hash) && pool['id']
    return nil unless pool['id'].to_i == pool_id.to_i

    ids = pool['post_ids'] || pool['posts'] || []
    pool.merge('post_ids' => Array(ids).filter_map { |id| Integer(id, exception: false) }.uniq)
  rescue JSON::ParserError => e
    log_error "Failed to parse pool response", error: e.message, pool_id: pool_id, api: true
    nil
  end

  def slugify(name)
    base = name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
    base = 'pool' if base.empty?
    base[0, 60]
  end
  def post_pool_ids(post)
    Array(post['pools']).filter_map { |entry| entry.is_a?(Hash) ? entry['id'] : entry }
                         .filter_map { |id| Integer(id, exception: false) }
  end

  def pool_id_for_directory(directory)
    File.basename(directory)[/\A(\d+)_/, 1]&.to_i
  end

  # Downloads every member of a pool into one directory, so a multi-page work
  # is archived as a bundle rather than as loose files.
  def bundle_pool(pool_id, thread_idx: nil)
    pool = fetch_pool(pool_id, thread_idx: thread_idx)
    unless pool
      log_warn "Pool #{pool_id} could not be read; only the triggering post will be placed",
               pool_id: pool_id, api: true
      return
    end

    post_ids = pool['post_ids']
    expected = pool['post_count'].to_i
    if expected.positive? && post_ids.size < expected
      log_warn "Pool #{pool_id} reports #{expected} posts but only #{post_ids.size} ids came back",
               pool_id: pool_id, api: true
    end
    if pool['is_active'] == false
      log_warn "Pool #{pool_id} (#{pool['name']}) is not active", pool_id: pool_id, api: true
    end

    log_info "Bundling pool #{pool_id} \"#{pool['name']}\" (#{post_ids.size} posts)",
             pool_id: pool_id, posts: post_ids.size
    @pools_expanded_mutex.synchronize { @pools_expanded += 1 }
    # Re-records the title and member list; the directory slug stays as frozen.
    record_pool(pool_id)
    post_ids.each { |id| @db.record_pool_post(pool_id, id) }

    posts = fetch_posts_for_pool(pool_id, post_ids, thread_idx: thread_idx)
    by_id = posts.each_with_object({}) { |post, hash| hash[post['id'].to_i] = post }

    # The post that triggered the expansion comes back as a member too; it is
    # already claimed for this location, so the processor drops the duplicate.
    post_ids.each do |id|
      post = by_id[id]
      unless post
        log_warn "Pool #{pool_id}: post #{id} was not returned by the API, leaving a gap in the bundle",
                 pool_id: pool_id, post_id: id, api: true
        next
      end
      next if blacklisted_post?(post)

      # A pool member is archived like any other post, so its detail belongs in
      # the database too — this is how a bundled post's sources end up captured
      # when it was never returned by a tag query.
      record_post_metadata(post)
      yield mark_pool_member(post, pool_id)
    end
  end

  # Pins a post to the pool that pulled it in, so its own pools are not expanded
  # in turn and it is not placed anywhere else.
  def mark_pool_member(post, pool_id)
    marked = post.dup
    marked[POOL_MEMBER] = pool_id
    marked
  end

  def post_locations(post)
    return [root_location] unless pools_active?

    pool_id = post[POOL_MEMBER]
    return [Location.new(pool_directory(pool_id), pool_id)] if pool_id

    ids = post_pool_ids(post)
    return [root_location] if ids.empty?

    ids.uniq.map { |id| Location.new(pool_directory(id), id) }
  end

  def fetch_posts_for_pool(pool_id, post_ids, thread_idx: nil)
    posts = []

    post_ids.each_slice(POOL_POST_BATCH) do |batch|
      break if @interrupted

      result = api_search_posts(["id:#{batch.join(',')}"], 1, force: true, cache: false,
                                thread_idx: thread_idx)
      if !result.ok?
        log_warn "Could not fetch #{batch.size} posts of pool #{pool_id}", pool_id: pool_id, api: true
        next
      end

      posts.concat(result.posts)
    end

    posts
  end
end
