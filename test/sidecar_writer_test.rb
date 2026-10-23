# frozen_string_literal: true

require_relative 'test_helper'
require 'sidecar_writer'

# The sidecar writer keeps one exiftool process for the whole program and
# drives it over its stay-open protocol. The protocol is line-based, so the
# values that come off the site have to survive it unchanged.
class SidecarWriterTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @media = File.join(@dir, 'media.png')
    FileUtils.cp(File.expand_path('support/1x1.png', __dir__), @media)
    @writer = SidecarWriter.new
  end

  def teardown
    @writer.close
    FileUtils.remove_entry(@dir)
  end

  def exiftool?
    system('exiftool -ver >/dev/null 2>&1')
  end

  def write(values, name: 'out')
    output = File.join(@dir, "#{name}.xmp")
    args = ['-o', output]
    values.each do |tag, value|
      if value.is_a?(Array)
        args << "-#{tag}=#{value.first}"
        value.drop(1).each { |item| args << "-#{tag}+=#{item}" }
      else
        args << "-#{tag}=#{value}"
      end
    end
    args << @media
    @writer.run(args, output_path: output)
    output
  end

  def read_back(path)
    stdout, _stderr, status = Open3.capture3('exiftool', '-json', '-G1', path)
    return nil unless status.success?

    entry = JSON.parse(stdout)
    entry = entry.first if entry.is_a?(Array)
    entry
  end

  # A value with a newline in it is the reason the writer escapes its
  # arguments: exiftool reads one argument per line, so an unescaped newline
  # would arrive as two arguments and the description would be cut short.
  def test_a_value_with_a_newline_survives_the_line_based_protocol
    skip 'exiftool not installed' unless exiftool?

    description = "Source: https://example.test/1\n\nA note about the work"
    path = write({ 'XMP-dc:Description' => description })

    assert File.exist?(path)
    entry = read_back(path)
    assert_equal description, entry['XMP-dc:Description']
  end

  # A keyword that begins with a hash would be taken for a comment by a
  # line-based reader.
  def test_a_value_starting_with_a_hash_survives
    skip 'exiftool not installed' unless exiftool?

    path = write({ 'XMP-dc:Subject' => ['#hash', 'plain'] })

    entry = read_back(path)
    assert_equal ['#hash', 'plain'], Array(entry['XMP-dc:Subject'])
  end

  # Leading whitespace is easy to lose in a line-based protocol.
  def test_leading_whitespace_survives
    skip 'exiftool not installed' unless exiftool?

    path = write({ 'XMP-dc:Subject' => ['  indented', 'plain'] })

    entry = read_back(path)
    assert_equal ['  indented', 'plain'], Array(entry['XMP-dc:Subject'])
  end

  def test_quotes_and_backslashes_survive
    skip 'exiftool not installed' unless exiftool?

    path = write({ 'XMP-dc:Description' => 'a "quoted" word and a \\ backslash' })

    entry = read_back(path)
    assert_equal 'a "quoted" word and a \\ backslash', entry['XMP-dc:Description']
  end

  def test_non_ascii_survives
    skip 'exiftool not installed' unless exiftool?

    path = write({ 'XMP-dc:Title' => 'héllo — 日本' })

    entry = read_back(path)
    assert_equal 'héllo — 日本', entry['XMP-dc:Title']
  end

  # The whole point of the writer: one process for many sidecars.
  def test_one_process_serves_many_writes
    skip 'exiftool not installed' unless exiftool?

    5.times { |i| write({ 'XMP-dc:Title' => "post #{i}" }, name: "many#{i}") }

    assert @writer.running?, 'the process is kept for the next write'
    assert_equal 5, Dir.children(@dir).count { |name| name.start_with?('many') && name.end_with?('.xmp') }
  end

  # A file left behind by a killed run would otherwise be taken for a sidecar
  # this command wrote: exiftool refuses to overwrite and says so, but the
  # stale bytes are still on disk.
  def test_a_stale_output_file_is_replaced_rather_than_kept
    skip 'exiftool not installed' unless exiftool?

    output = File.join(@dir, 'stale.xmp')
    File.write(output, 'half written')
    args = ['-o', output, '-XMP-dc:Title=fresh', @media]

    assert_equal true, @writer.run(args, output_path: output)
    assert_includes File.read(output), 'fresh'
  end

  # A sidecar that cannot be written is a failure, and it must not be left
  # behind as a half-written file.
  def test_a_failing_write_is_reported_and_leaves_nothing_behind
    skip 'exiftool not installed' unless exiftool?

    blocker = File.join(@dir, 'not-a-directory')
    File.write(blocker, 'x')
    output = File.join(blocker, 'broken.xmp')
    args = ['-o', output, '-XMP-dc:Title=nope', @media]

    refute_equal true, @writer.run(args, output_path: output)
    refute File.exist?(output)
  end

  # A source exiftool cannot open is a warning, not a failure: it still writes
  # the sidecar, and the sidecar is what the archive wanted.
  def test_a_source_exiftool_cannot_open_is_not_a_failure
    skip 'exiftool not installed' unless exiftool?

    output = File.join(@dir, 'warned.xmp')
    args = ['-o', output, '-XMP-dc:Title=t', File.join(@dir, 'missing.png')]

    assert_equal true, @writer.run(args, output_path: output)
    assert File.exist?(output)
  end

  # A dead process is not a failed sidecar: the writer starts another and
  # tries again.
  def test_the_writer_recovers_from_a_dead_process
    skip 'exiftool not installed' unless exiftool?

    output = File.join(@dir, 'after.xmp')
    write({ 'XMP-dc:Title' => 'first' }, name: 'before')
    @writer.send(:shutdown)

    args = ['-o', output, '-XMP-dc:Title=second', @media]
    assert_equal true, @writer.run(args, output_path: output)
    assert_includes File.read(output), 'second'
  end

  # A run that was killed outright cannot stop the process it started, so the
  # next run has to be able to find and stop it.
  def test_an_orphaned_process_is_reaped
    skip 'exiftool not installed' unless exiftool?

    output = File.join(@dir, 'orphan.xmp')
    write({ 'XMP-dc:Title' => 'first' }, name: 'orphan')
    pid = @writer.instance_variable_get(:@wait_thread).pid
    @writer.pid_path = File.join(@dir, 'exiftool.pid')
    @writer.send(:record_pid)

    @writer.reap_orphan

    refute File.exist?(@writer.pid_path), 'the pid file is gone'
    20.times do
      break unless process_alive?(pid)

      sleep 0.05
    end
    refute process_alive?(pid), 'the orphaned exiftool was stopped'
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
