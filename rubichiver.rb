#!/usr/bin/env ruby
# frozen_string_literal: true

# rubichiver - Unified Media Archiver
# Downloads media from booru sites and writes XMP sidecar metadata.
# Supports e621.net and Gelbooru via --site flag.

require 'optparse'
require_relative 'version'
require_relative 'logger'
require_relative 'rate_limiter'
require_relative 'post_processor'
require_relative 'blacklist'
require_relative 'archive_db'
require_relative 'archiver_base'
require_relative 'archiver_e621'
require_relative 'archiver_gelbooru'

if __FILE__ == $PROGRAM_NAME
  sites = {
    'e621' => { archiver: E621Archiver, credentials: './e621-api-credentials.txt' },
    'gelbooru' => { archiver: GelbooruArchiver, credentials: './gelbooru-api-credentials.txt' }
  }

  options = {
    site: nil,
    output: nil,
    tags: './tags.txt',
    credentials: nil,
    blacklist: './blacklist.txt',
    cache_dir: nil,
    db_path: nil,
    dry_run: false,
    recache_post_tags: false,
    pools: true,
    repair_missing: true,
    verify_md5: false,
    notify: nil,
    threads: 2,
    rate_limit: Archiver::DEFAULT_REQUESTS_PER_SECOND,
    verbose: false,
    json: false,
    cache_max_age: Archiver::CACHE_MAX_AGE_DAYS
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby #{File.basename($PROGRAM_NAME)} --site SITE [OPTIONS]"
    opts.separator ''

    opts.separator 'Site:'
    opts.on('-s', '--site SITE', "Target site: #{sites.keys.join(' or ')}") do |value|
      options[:site] = value
    end

    opts.separator ''
    opts.separator 'Input and output:'
    opts.on('-o', '--output DIR', 'Output directory') { |value| options[:output] = value }
    opts.on('-t', '--tags FILE', 'Tag query file (default: ./tags.txt)') { |value| options[:tags] = value }
    opts.on('-b', '--blacklist FILE', 'Blacklist file, e621 syntax (default: ./blacklist.txt)') do |value|
      options[:blacklist] = value
    end
    opts.on('-C', '--cache-dir DIR', 'Cache directory for API responses (default: $output/cache)') do |value|
      options[:cache_dir] = value
    end
    opts.on('--db FILE', "Archive database of post metadata and file provenance " \
                         "(default: #{ArchiveDb::DEFAULT_PATH})") do |value|
      options[:db_path] = value
    end
    opts.on('--cache-max-age DAYS', Integer,
            "Drop cached API pages older than DAYS (default: #{Archiver::CACHE_MAX_AGE_DAYS}, 0 disables)") do |value|
      options[:cache_max_age] = value
    end

    opts.separator ''
    opts.separator 'Credentials:'
    opts.on('-c', '--credentials FILE', 'API credentials file (default: ./<site>-api-credentials.txt)') do |value|
      options[:credentials] = value
    end

    opts.separator ''
    opts.separator 'Run behaviour:'
    opts.on('--dry-run', 'Preview posts that would be archived, writing nothing to disk') do
      options[:dry_run] = true
    end
    opts.on('--recache-post-tags', 'Refresh the stored metadata of every archived post, ' \
                                   'and regenerate missing sidecars (no downloads)') do
      options[:recache_post_tags] = true
    end
    opts.on('--[no-]pools', 'Bundle a whole collection directory when a found post belongs to one') do |value|
      options[:pools] = value
    end
    opts.on('--[no-]repair-missing',
            'Re-fetch posts that have a sidecar but no media file (default on)') do |value|
      options[:repair_missing] = value
    end
    opts.on('--retry-failed',
            'Look up downloads that exhausted every retry round by id and try them again ' \
            '(posts the site no longer returns are dropped from the retry list)') do
      options[:retry_failed] = true
    end
    opts.on('--verify-md5', 'Re-hash archived files against the database on startup (slow)') do
      options[:verify_md5] = true
    end
    opts.on('--notify URL', 'POST a JSON run report to URL on completion (ntfy/Slack/Discord webhook)') do |value|
      options[:notify] = value
    end

    opts.separator ''
    opts.separator 'Tuning:'
    opts.on('-j', '--threads N', Integer, 'Download worker threads (default: 2)') do |value|
      options[:threads] = value
    end
    opts.on('--rate-limit N', Float,
            "Requests per second *per worker thread* (default: #{Archiver::DEFAULT_REQUESTS_PER_SECOND}; " \
            'the run total is this times --threads)') do |value|
      options[:rate_limit] = value
    end

    opts.separator ''
    opts.separator 'Logging:'
    opts.on('-v', '--verbose', 'Verbose output') { options[:verbose] = true }
    opts.on('--json', 'JSON log output (machine-parseable)') { options[:json] = true }

    opts.separator ''
    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      exit 0
    end
    opts.on('--version', 'Show the rubichiver version') do
      puts "rubichiver #{Rubichiver::VERSION}"
      exit 0
    end
  end

  begin
    parser.parse!
  rescue OptionParser::ParseError => e
    warn "Error: #{e.message}"
    warn ''
    warn parser.to_s
    exit 1
  end

  site = options.delete(:site)
  if site.nil?
    warn parser.to_s
    warn ''
    warn "Error: --site is required (one of: #{sites.keys.join(', ')})"
    exit 1
  end

  config = sites[site]
  unless config
    warn "Error: --site must be one of #{sites.keys.join(', ')}, got '#{site}'"
    exit 1
  end

  options[:credentials] ||= config[:credentials]
  # Both sites share one database by default, so an archive can be queried as a
  # whole. --db still points it somewhere else.
  options[:db_path] ||= ArchiveDb::DEFAULT_PATH
  notify_url = options.delete(:notify)

  Rubichiver::Logger.configure(
    level: options[:verbose] ? :debug : :info,
    format: options[:json] ? :json : :human
  )

  archiver = config[:archiver].new(
    output_dir: options[:output],
    tags_file: options[:tags],
    credentials_file: options[:credentials],
    blacklist_file: options[:blacklist],
    dry_run: options[:dry_run],
    thread_count: options[:threads],
    rate_limit: options[:rate_limit],
    verbose: options[:verbose],
    notify_url: notify_url,
    cache_dir: options[:cache_dir],
    db_path: options[:db_path],
    pools: options[:pools],
    repair_missing: options[:repair_missing],
    retry_failed: options[:retry_failed],
    verify_md5: options[:verify_md5],
    recache_post_tags: options[:recache_post_tags],
    cache_max_age: options[:cache_max_age]
  )

  archiver.install_signal_handlers
  archiver.run
end
