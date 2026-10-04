# frozen_string_literal: true

require 'socket'
require 'rbconfig'
require_relative 'test_helper'
require_relative 'support/stub_http'

# A minimal HTTP server for the end-to-end recovery tests. It exists so the
# real CLI can be run as a real process against a real socket, which is the
# only way to test what a hard kill or a graceful interrupt actually leaves
# behind on disk.
class StubServer
  PNG = Base64.decode64(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
  )

  attr_accessor :chunk_delay, :chunk_size

  def initialize(chunk_delay: 0.15, chunk_size: 8)
    @chunk_delay = chunk_delay
    @chunk_size = chunk_size
    @server = TCPServer.new('127.0.0.1', 0)
    @running = true
    @thread = Thread.new { accept_loop }
  end

  def port
    @server.addr[1]
  end

  def base_url
    "http://127.0.0.1:#{port}"
  end

  def stop
    @running = false
    @thread&.kill
    @server.close
  rescue IOError
    nil
  end

  def self.run(chunk_delay: 0.15, chunk_size: 8, &responder)
    server = new(chunk_delay: chunk_delay, chunk_size: chunk_size)
    server.define_singleton_method(:body_for) { |path| responder.call(path) }
    server
  end

  private

  def accept_loop
    while @running
      socket = @server.accept
      Thread.new(socket) { |client| handle(client) }
    end
  rescue IOError, Errno::EBADF, Errno::EINVAL
    nil
  end

  def handle(socket)
    request_line = socket.gets.to_s
    while (line = socket.gets)
      break if line.strip.empty?
    end
    body = body_for(request_line.split[1].to_s)
    return not_found(socket) if body.nil?

    socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
    # Chunked so a test can kill the client while the body is still in flight.
    body.bytes.each_slice(@chunk_size) do |slice|
      socket.write(slice.pack('C*'))
      socket.flush
      sleep @chunk_delay
    end
  rescue IOError, SystemCallError
    nil
  ensure
    begin
      socket.close
    rescue StandardError
      nil
    end
  end

  def not_found(socket)
    socket.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  end
end

# Runs the real rubichiver.rb as a child process against StubServer.
module CliRunner
  SCRIPT = File.expand_path('../rubichiver.rb', __dir__)
  BOOT_TIMEOUT = 20

  # Starts the real CLI against StubServer.
  #
  # `during_download: :kill` waits for a download to be in flight and then
  # SIGKILLs the process; `during_download: :interrupt` sends SIGINT instead.
  # Both wait for the .part file first, because a signal delivered during
  # start-up would be handled by the default disposition rather than by the
  # archiver's own handler.
  def run_cli(server:, out_dir:, extra: [], during_download: nil)
    log = File.join(@dir, "cli-#{@cli_runs}.log")
    @cli_runs += 1
    pid = Process.spawn(
      { 'RUBICHIVER_E621_API' => server.base_url, 'RUBICHIVER_GELBOORU_API' => server.base_url,
        # The CLI defaults to the shared archive database. A test must never
        # write to it, so each run gets its own.
        'RUBICHIVER_DB' => File.join(@dir, "cli-db-#{@cli_runs}.db") },
      RbConfig.ruby, SCRIPT, '--site', 'e621',
      '--tags', @tags_file, '--output', out_dir,
      '--credentials', @credentials_file,
      '--rate-limit', '100', '--threads', '1', *extra,
      out: log, err: log
    )

    if during_download
      started = wait_for_partial_file(pid, out_dir)
      Process.kill(during_download == :kill ? 'KILL' : 'INT', pid)
      return [pid, log] unless started
    end

    _pid, status = Process.wait2(pid)
    outcome = status.signaled? ? "signal #{status.termsig}" : status.exitstatus
    [outcome, File.read(log)]
  end

  private

  # Liveness is probed with signal 0: reaping the child here would leave
  # nothing for the caller to wait on.
  def wait_for_partial_file(pid, out_dir)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
    loop do
      return true if Dir.glob(File.join(out_dir, '**', '*.part')).any?
      return false unless alive?(pid)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def wait_for(timeout = 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      raise 'timed out waiting for condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end
end

# Self-recovery: what the archive does when the filesystem, the caches, the
# database or the process itself is damaged.
class RecoveryTest < Minitest::Test
  include StubHttp
  include CliRunner

  POST_ID = 4_242

  def setup
    @dir = Dir.mktmpdir
    @cli_runs = 0
    @out = File.join(@dir, 'archive')
    FileUtils.mkdir_p(@out)
    FileUtils.mkdir_p(File.join(@out, 'posts'))
    @tags_file = File.join(@dir, 'tags.txt')
    File.write(@tags_file, "solo\n")
    @credentials_file = File.join(@dir, 'creds.txt')
    File.write(@credentials_file, "USERNAME=tester\nAPI_KEY=key\n")
    @archiver = E621Archiver.new(
      output_dir: @out, cache_dir: File.join(@out, 'cache'),
      username: 'tester', api_key: 'key', rate_limit: 1000
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def post
    {
      'id' => POST_ID, 'rating' => 's', 'pools' => [],
      'tags' => { 'general' => ['cat'] },
      'files' => {
        'original' => { 'url' => 'https://cdn.e621.net/data/4242.png' },
        'meta' => { 'ext' => 'png', 'md5' => Digest::MD5.hexdigest(StubServer::PNG) }
      }
    }
  end

  def stub_api(body: StubServer::PNG)
    stub_http_get(@archiver) do |uri, _n|
      if uri.host == 'cdn.e621.net'
        StubHttp::Response.new(200, body)
      else
        StubHttp::Response.new(200, JSON.generate([post]))
      end
    end
  end

  def run_archiver
    assert_raises(SystemExit) { @archiver.run }
  end

  # Archives the post, then rebuilds a fresh archiver the way the next run would.
  def archive_then_reopen
    stub_api
    run_archiver
    # The lock is released when a process exits, so close it by hand here.
    @archiver.instance_variable_get(:@lock_file)&.close
    @archiver = E621Archiver.new(
      output_dir: @out, cache_dir: File.join(@out, 'cache'),
      username: 'tester', api_key: 'key', rate_limit: 1000
    )
    @archiver.db.load
    @archiver.scan_output_dir
    # The replacement has its own transport, exactly like a new process would.
    stub_api
    @archiver
  end

  def media_path
    File.join(@out, 'posts', "#{POST_ID}.png")
  end

  def db_path
    File.join(@out, '.rubichiver.db')
  end

  # A server that serves the search result and the file itself, with the post's
  # download URL pointing back at the server so the CLI needs no real network.
  def cli_server(chunk_delay: 0.15, chunk_size: 8)
    server = StubServer.new(chunk_delay: chunk_delay, chunk_size: chunk_size)
    body = StubServer::PNG
    build_post = method(:post_with_url)
    server.define_singleton_method(:body_for) do |path|
      if path.start_with?('/posts.json')
        JSON.generate([build_post.call("#{base_url}/data/#{POST_ID}.png")])
      else
        body
      end
    end
    server
  end

  def post_with_url(url)
    post.merge('files' => { 'original' => { 'url' => url },
                           'meta' => { 'ext' => 'png', 'md5' => Digest::MD5.hexdigest(StubServer::PNG) } })
  end

  def part_files
    Dir.glob(File.join(@out, '**', '*.part'))
  end

  # --- damaged media --------------------------------------------------------

  # A zero-byte file is never a valid download, even when a sidecar sits
  # beside it claiming otherwise.
  def test_a_zero_byte_file_is_fetched_again
    archive_then_reopen
    File.write(media_path, '')

    @archiver.send(:check_archived_integrity)

    assert_equal 1, @archiver.integrity_fault_count
    assert_nil @archiver.existing_media(POST_ID, Archiver::Location.new(File.join(@out, 'posts'), nil))
  end

  def test_a_truncated_file_is_fetched_again
    archive_then_reopen
    File.binwrite(media_path, StubServer::PNG[0, 40])

    @archiver.send(:check_archived_integrity)

    assert_equal 1, @archiver.integrity_fault_count
  end

  # Damage is reported but never destructive: the file stays until a download
  # overwrites it, so a mistaken check cannot destroy anything.
  def test_a_damaged_file_is_set_aside_not_deleted
    archive_then_reopen
    File.binwrite(media_path, StubServer::PNG[0, 40])

    @archiver.send(:check_archived_integrity)

    refute File.exist?(media_path), 'the truncated file is moved out of the way'
    preserved = Dir.glob(File.join(@out, 'posts', '*.damaged-*'))
    assert_equal 1, preserved.size, 'but its bytes are still on disk'
    assert_equal StubServer::PNG[0, 40], File.binread(preserved.first)
  end

  # A file that grew is the user editing it, not damage. Re-fetching would
  # destroy their work, so it is reported and left alone.
  def test_a_file_the_user_grew_is_left_alone
    archive_then_reopen
    edited = StubServer::PNG + 'my edits'
    File.binwrite(media_path, edited)

    @archiver.send(:check_archived_integrity)

    assert_equal 1, @archiver.preserved_file_count
    assert_equal 0, @archiver.integrity_fault_count, 'a grown file is not queued for re-download'
    assert_equal edited, File.binread(media_path), 'the edited bytes are untouched'
  end

  def test_a_preserved_file_is_still_indexed_as_archived
    archive_then_reopen
    File.binwrite(media_path, StubServer::PNG + 'my edits')

    @archiver.send(:check_archived_integrity)

    assert_equal media_path, @archiver.existing_media(POST_ID, Archiver::Location.new(File.join(@out, 'posts'), nil)),
                 'leaving it alone must not re-download it over and over'
  end

  def test_set_aside_damage_is_not_reindexed_as_media
    archive_then_reopen
    File.binwrite(media_path, StubServer::PNG[0, 40])
    @archiver.send(:check_archived_integrity)

    @archiver.scan_output_dir
    assert_nil @archiver.existing_media(POST_ID, Archiver::Location.new(File.join(@out, 'posts'), nil)),
               'a .damaged file must not look like an archived download'
  end

  # A file the user grew is not damage, and re-fetching it would destroy their
  # work, so it is reported separately and never queued.
  def test_a_larger_file_is_reported_but_kept
    archive_then_reopen
    File.binwrite(media_path, StubServer::PNG + 'extra')

    @archiver.send(:check_archived_integrity)

    assert_equal 0, @archiver.integrity_fault_count
    assert_equal 1, @archiver.preserved_file_count
    assert_empty @archiver.instance_variable_get(:@integrity_faults)
  end

  # Same length, different bytes: only a hash can tell.
  def test_verify_md5_catches_a_same_size_corruption
    archive_then_reopen
    corrupt = StubServer::PNG.dup
    corrupt.setbyte(10, (corrupt.getbyte(10) + 1) % 256)
    File.binwrite(media_path, corrupt)

    @archiver.send(:check_archived_integrity)
    assert_equal 0, @archiver.integrity_fault_count, 'size alone cannot see this'

    verified = E621Archiver.new(output_dir: @out, cache_dir: File.join(@out, 'cache'),
                                username: 'tester', api_key: 'key', rate_limit: 1000, verify_md5: true)
    verified.db.load
    verified.scan_output_dir
    verified.send(:check_archived_integrity)

    assert_equal 1, verified.integrity_fault_count
  end

  def test_verify_md5_passes_a_healthy_archive
    archive_then_reopen
    verified = E621Archiver.new(output_dir: @out, cache_dir: File.join(@out, 'cache'),
                                username: 'tester', api_key: 'key', rate_limit: 1000, verify_md5: true)
    verified.db.load
    verified.scan_output_dir
    verified.send(:check_archived_integrity)

    assert_equal 0, verified.integrity_fault_count
  end

  # Gelbooru serves a .mp4 for a post whose `image` says .webm, so there is no
  # expected MD5 to check the download against. The bytes are still hashed as
  # they stream past, and recording that digest keeps the file verifiable --
  # otherwise every future variant lands in the database with no digest at all
  # and silently drops out of --verify-md5 coverage.
  def test_a_container_variant_is_recorded_with_a_verifiable_digest
    dir = Dir.mktmpdir
    archiver = GelbooruArchiver.new(output_dir: dir, db_path: File.join(dir, 'db'),
                                    api_key: 'k', user_id: '1', rate_limit: 1000)
    archiver.db.load
    stub_http_get(archiver) { StubHttp::Response.new(200, 'variant-bytes') }

    path = File.join(dir, '5.mp4')
    assert archiver.download_media('https://cdn.test/5.mp4', path, 5, nil, thread_idx: 0)

    archiver.record_archived_file({ 'id' => 5, 'rating' => 's' }, Archiver::Location.new(dir, nil),
                                  path, md5: nil)

    assert_equal Digest::MD5.hexdigest('variant-bytes'), archiver.db.file(5)['md5']
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # A pool member re-served under a different extension is a different file,
  # not a damaged one, and must not trigger a fetch loop.
  def test_a_different_extension_is_not_treated_as_damage
    archive_then_reopen
    File.delete(media_path)
    File.write(File.join(@out, 'posts', "#{POST_ID}.jpg"), 'x')
    @archiver.scan_output_dir
    record = @archiver.db.file(POST_ID)
    record['ext'] = 'png'

    @archiver.send(:check_archived_integrity)

    assert_equal 0, @archiver.integrity_fault_count
  end

  def test_a_damaged_file_is_repaired_by_a_rerun
    archive_then_reopen
    File.write(media_path, '')

    stub_api
    run_archiver

    assert_equal StubServer::PNG, File.binread(media_path)
    assert_equal 0, @archiver.build_report(Stats.new, 1.0)[:failed]
  end

  # Gelbooru serves a .mp4 for a post whose `image` says .webm, and e621 serves a
  # .webm for some .mp4 posts. The archived bytes are then not the ones the
  # digest was computed over, so a hash mismatch is not corruption and must not
  # condemn the file -- doing so would move it aside and re-fetch it on every
  # run, forever.
  def test_a_container_variant_is_not_condemned_by_verify_md5
    archive_then_reopen
    record_container_variant(post_ext: 'webm', file_ext: 'mp4')

    assert_equal 0, verified_archiver.integrity_fault_count
  end

  # The guard above must not blunt the check for a file that *is* the container
  # the digest was taken over.
  def test_verify_md5_still_catches_corruption_of_the_advertised_container
    archive_then_reopen
    corrupt = StubServer::PNG.dup
    corrupt.setbyte(10, (corrupt.getbyte(10) + 1) % 256)
    File.binwrite(media_path, corrupt)
    record_container_variant(post_ext: 'png', file_ext: 'png')

    assert_equal 1, verified_archiver.integrity_fault_count
  end

  # And a file whose extension does not even match its own row is skipped by the
  # existing guard, before any of this comes into play.
  def test_a_different_extension_is_not_treated_as_damage_by_verify_md5
    archive_then_reopen
    record_container_variant(post_ext: 'webm', file_ext: 'mp4')
    @archiver.db.record_file(post_id: POST_ID, path: "posts/#{POST_ID}.mp4", dir: 'posts',
                             md5: 'f' * 32, ext: 'png', bytes: File.size(variant_path), sidecar: true)

    assert_equal 0, verified_archiver.integrity_fault_count
  end

  # Repoints the archive at a container the post does not advertise, with a digest
  # that deliberately does not match the bytes -- exactly the state a container
  # variant leaves behind. The media is renamed to match, so the variant file
  # really is on disk and really is what the database points at.
  def record_container_variant(post_ext:, file_ext:)
    db = @archiver.db
    variant_path = File.join(@out, 'posts', "#{POST_ID}.#{file_ext}")
    db.record_post(post_id: POST_ID, md5: 'f' * 32, ext: post_ext, rating: 's',
                  tags: { 'general' => %w[cat] })
    File.rename(media_path, variant_path)
    db.record_file(post_id: POST_ID, path: "posts/#{POST_ID}.#{file_ext}", dir: 'posts',
                   md5: 'f' * 32, ext: file_ext, bytes: File.size(variant_path), sidecar: true)
    @variant_path = variant_path
  end

  def variant_path
    @variant_path
  end

  def verified_archiver
    # The writes above are batched, so they have to reach disk before another
    # connection reads them -- the same thing closing the store does at exit.
    @archiver.db.close
    archiver = E621Archiver.new(output_dir: @out, cache_dir: File.join(@out, 'cache'),
                                username: 'tester', api_key: 'key', rate_limit: 1000, verify_md5: true)
    archiver.db.load
    archiver.scan_output_dir
    archiver.send(:check_archived_integrity)
    archiver
  end

  # --- damaged caches -------------------------------------------------------

  def test_a_corrupt_api_cache_is_discarded_and_the_run_continues
    archive_then_reopen
    Dir.glob(File.join(@out, 'cache', 'api_posts_*.json')).each do |path|
      File.write(path, '{{{ not json')
    end

    stub_api
    run_archiver

    assert_equal 0, @archiver.build_report(Stats.new, 1.0)[:failed]
  end

  # The post record now lives in the archive database rather than in a pile of
  # per-post cache files, so the interesting self-recovery case is a damaged
  # database rather than a damaged tag cache.
  def test_a_corrupt_database_does_not_stop_the_run
    archive_then_reopen
    @archiver.db.close
    File.binwrite(db_path, "not a database at all\n" * 40)

    stub_api
    run_archiver

    assert_equal 0, @archiver.build_report(Stats.new, 1.0)[:failed]
    assert File.exist?(media_path)
    refute_empty Dir.glob("#{db_path}.corrupt-*"), 'the unreadable file is kept, not deleted'
  end

  def test_a_missing_database_is_rebuilt_from_the_filesystem
    archive_then_reopen
    @archiver.db.close
    FileUtils.rm_f(db_path)
    FileUtils.rm_f(Dir.glob("#{db_path}-*"))

    stub_api
    run_archiver

    assert_equal POST_ID, @archiver.db.file(POST_ID)['post']
  end

  def test_a_missing_database_still_records_post_metadata
    archive_then_reopen
    @archiver.db.close
    FileUtils.rm_f(db_path)
    FileUtils.rm_f(Dir.glob("#{db_path}-*"))

    stub_api
    run_archiver

    row = @archiver.db.post(POST_ID)
    refute_nil row, 'the post is re-recorded from the API response'
    assert_equal File.join(@out, 'posts'), File.dirname(media_path)
    assert_equal StubServer::PNG.size, @archiver.db.file(POST_ID)['bytes']
  end

  # A sidecar that cannot be written is a reported failure, not a crash, and
  # the media is still there for the next run to fix.
  def test_an_exiftool_failure_is_reported_and_the_media_is_kept
    archive_then_reopen
    @archiver.define_singleton_method(:sidecar_valid?) { |_post, _location = nil| false }
    @archiver.define_singleton_method(:write_sidecar) { |_media, _post| false }

    error = assert_raises(SystemExit) { @archiver.run }

    assert_equal 1, error.status, 'a failed sidecar must make the run report failure'
    assert_equal StubServer::PNG, File.binread(media_path)
  end

  # --- killed and interrupted processes -------------------------------------

  # The canonical self-recovery case: a hard kill mid-download must not leave
  # anything that a later run mistakes for a finished file.
  def test_a_hard_kill_mid_download_recovers_on_the_next_run
    server = cli_server

    # A hard kill lands mid-download, so a partial file is what it leaves behind.
    killed, = run_cli(server: server, out_dir: @out, during_download: :kill)
    assert_equal 'signal 9', killed, 'the first run should have been killed outright'
    refute_empty part_files, 'a partial file is expected after a hard kill'

    server.chunk_delay = 0
    server.chunk_size = 65_536
    code, log = run_cli(server: server, out_dir: @out)

    assert_equal 0, code, "recovery run failed:\n#{log}"
    assert_empty part_files, 'a partial file must not survive'
    assert_equal StubServer::PNG, File.binread(media_path)
    assert File.exist?(File.join(@out, 'posts', "#{POST_ID}.xmp"))
  ensure
    server&.stop
  end

  # A graceful interrupt stops without writing a half file, and the exit code
  # says the run was incomplete.
  def test_an_interrupt_drains_and_reports_incomplete
    server = cli_server
    code, log = run_cli(server: server, out_dir: @out, during_download: :interrupt)

    assert_equal 1, code, "an interrupted run must not report success:\n#{log}"
    assert_empty part_files
  ensure
    server&.stop
  end

  def test_a_second_run_after_a_hard_kill_completes_the_archive
    server = cli_server
    run_cli(server: server, out_dir: @out, during_download: :kill)
    server.chunk_delay = 0
    server.chunk_size = 65_536
    code, log = run_cli(server: server, out_dir: @out)

    assert_equal 0, code, log
    assert_equal StubServer::PNG, File.binread(media_path)
    cli_db = Dir.glob(File.join(@dir, 'cli-db-*.db')).max_by { |f| File.mtime(f) }
    assert_equal POST_ID, ArchiveDb.new(cli_db, site: 'e621').tap(&:load).file(POST_ID)['post']
  ensure
    server&.stop
  end
end
