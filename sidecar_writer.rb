# frozen_string_literal: true

require 'open3'
require 'thread'

# Writes XMP sidecars through one long-lived exiftool process.
#
# Starting exiftool costs about 280ms -- Perl start-up plus module loading --
# while writing one sidecar costs about 10ms. Forking a process per sidecar
# therefore spends roughly 96% of its time on start-up: rewriting a large
# archive's sidecars costs hours, and nearly all of that is start-up rather
# than work. Measured on this archive, 50 sidecars cost 17.8s across 50
# processes and 0.82s here.
#
# exiftool's -stay_open mode keeps the process alive and reads further commands
# from stdin, so the start-up is paid once for the whole run instead of once
# per sidecar.
#
# The protocol is a strict request/response: a command is a list of argument
# lines terminated by -execute, and the answer is whatever exiftool prints
# before the {ready} marker. Only one command can be in flight at a time, so
# the whole exchange is serialised behind a mutex -- which is also what keeps
# the answer that comes back attached to the command that asked for it.
#
# Arguments travel as lines, one argument per line, and a line *is* an
# argument. A value holding a newline would therefore arrive as two arguments,
# and a value starting with '#' would be swallowed as a comment. The #[CSTR]
# prefix makes exiftool read the line as a C string instead, which is where the
# escaping below comes from: it is what keeps a description with a blank line
# in it one value, and a keyword that starts with '#' one keyword.
class SidecarWriter
  # exiftool prints this when it has finished a command.
  READY_MARKER = '{ready'
  # Makes exiftool read an argument line as a C string rather than as plain text.
  C_STRING_PREFIX = '#[CSTR]'
  # How long to wait for exiftool to answer before treating it as gone. A
  # command that hangs must not take the run with it.
  READ_TIMEOUT = 300
  # How long to let a pending error land on stderr once a command has failed.
  STDERR_GRACE = 0.2
  # How many stderr lines are kept for an error message.
  STDERR_KEEP = 40

  # exiftool's own error marker. Only a line that *starts* with "Error:"
  # counts: a warning about a file it could not open reads "Warning: Error
  # opening file", and exiftool still writes the sidecar and exits zero for
  # that, so mistaking it for a failure would condemn a good sidecar.
  ERROR_PATTERN = /^\s*Error:/.freeze

  @shared = nil
  @shared_mutex = Mutex.new

  class << self
    # The one writer for this process.
    #
    # The exiftool process is a resource, not something each archiver should
    # have a copy of: a Perl process with its modules loaded costs about a
    # hundred megabytes, and a leak of them exhausts the machine. One process
    # serves every writer, and it is stopped when the program ends.
    def shared(logger: nil)
      @shared_mutex.synchronize do
        @shared ||= new(logger: logger)
        @shared.logger = logger if logger
        @shared
      end
    end

    # Stops the shared process. Safe to call more than once; the next write
    # starts a new one.
    def close_shared
      @shared_mutex.synchronize do
        @shared&.close
        @shared = nil
      end
    end
  end

  # Where the pid of the exiftool process is recorded.
  #
  # A run that is killed outright cannot stop the process it started, and
  # exiftool's stay-open mode keeps it alive after its input ends, so a hard
  # kill leaves an exiftool behind waiting for commands that will never come.
  # Recording the pid lets the next run clean it up.
  attr_accessor :pid_path

  # Where a problem is reported.
  attr_accessor :logger

  def initialize(logger: nil)
    @logger = logger
    @mutex = Mutex.new
    @stdin = nil
    @stdout = nil
    @stderr = nil
    @wait_thread = nil
    @stderr_thread = nil
    @stderr_lines = []
    @stderr_mutex = Mutex.new
  end

  # Runs one exiftool command.
  #
  # @param args [Array<String>] the command, one argument per entry
  # @param output_path [String, nil] the file the command writes. It is
  #   removed first, so a leftover from a killed run cannot be mistaken for a
  #   file this command wrote -- exiftool refuses to overwrite, and would
  #   report that as an error instead of writing.
  # @return [true, String] true when the command succeeded, otherwise the
  #   reason it did not
  def run(args, output_path: nil)
    @mutex.synchronize { run_locked(args, output_path) }
  end

  # Whether a process is up. A writer that has never run has no process yet,
  # which is not the same as a broken one.
  def running?
    @mutex.synchronize { !@stdin.nil? && !@stdin.closed? }
  end

  # Stops the process. Safe to call more than once.
  def close
    @mutex.synchronize { shutdown }
  end

  # Stops an exiftool left behind by a run that was killed, so a hard kill
  # does not leave one behind for every run.
  def reap_orphan
    path = @pid_path
    return unless path && File.exist?(path)

    pid = File.read(path).to_i
    File.delete(path)
    return if pid <= 0
    return unless exiftool_process?(pid)

    Process.kill('TERM', pid)
  rescue StandardError
    nil
  end

  private

  def run_locked(args, output_path)
    remove_stale_output(output_path)

    unless ensure_process
      return 'exiftool is not installed'
    end

    begin
      failure = send_command(args)
    rescue StandardError => e
      # A broken pipe means the process died mid-command. That is a dead
      # process, not a failed sidecar: start another and try once more.
      shutdown
      unless ensure_process
        return "exiftool failed: #{e.class}: #{e.message}"
      end

      begin
        failure = send_command(args)
      rescue StandardError => retry_error
        shutdown
        return "exiftool failed: #{retry_error.class}: #{retry_error.message}"
      end
    end

    return failure if failure

    # exiftool said nothing went wrong, so the file itself is the last word.
    return true if output_path.nil? || File.exist?(output_path)

    # The file is not there. Give a pending error a moment to land, so the
    # message says what went wrong rather than only that nothing did.
    errors = drain_stderr(wait: STDERR_GRACE)
    return errors unless errors.empty?

    "exiftool did not write #{File.basename(output_path)}"
  end

  # A file left by a killed run would make exiftool refuse the write, and the
  # stale bytes would then be taken for a fresh sidecar.
  def remove_stale_output(output_path)
    return if output_path.nil?
    return unless File.exist?(output_path)

    File.delete(output_path)
  rescue SystemCallError
    nil
  end

  def send_command(args)
    drain_stderr
    args.each { |arg| @stdin.write("#{C_STRING_PREFIX}#{escape_argument(arg)}\n") }
    @stdin.write("-execute\n")
    @stdin.flush

    output = read_until_ready
    errors = drain_stderr
    return nil unless error_reported?(output) || error_reported?(errors)

    detail = errors.empty? ? output.strip : errors
    "exiftool reported: #{detail}"
  end

  # Whether exiftool said anything was wrong, as opposed to merely warning.
  def error_reported?(text)
    text.to_s.each_line.any? { |line| ERROR_PATTERN.match?(line) }
  end

  # Reads exiftool's answer up to the {ready} marker.
  #
  # The reading is done a chunk at a time into a buffer of our own rather than
  # with gets: a select on the pipe says nothing about what the stream has
  # already buffered, so waiting for the marker on a stream that had already
  # read it would block until the command timed out.
  def read_until_ready
    buffer = +''
    output = +''
    loop do
      while (newline = buffer.index("\n"))
        line = buffer.slice!(0, newline + 1)
        output << line
        return output if line.start_with?(READY_MARKER)
      end

      chunk = read_chunk
      raise IOError, 'exiftool closed the connection' if chunk.nil?

      buffer << chunk
    end
  end

  # The next piece of exiftool's answer, waiting for it if need be.
  def read_chunk
    loop do
      result = @stdout.read_nonblock(4096, exception: false)
      return result if result.is_a?(String)
      # End of file: exiftool is gone.
      return nil if result.nil?

      ready = IO.select([@stdout], nil, nil, READ_TIMEOUT)
      raise IOError, 'exiftool did not answer in time' unless ready
    end
  end

  def ensure_process
    return true if @stdin && !@stdin.closed?

    @stdin, @stdout, @stderr, @wait_thread = Open3.popen3('exiftool', '-stay_open', 'True', '-@', '-')
    @stdin.sync = true
    start_stderr_reader
    record_pid
    true
  rescue Errno::ENOENT
    @logger&.warn('exiftool is not installed; sidecars cannot be written')
    false
  end

  def record_pid
    return unless @pid_path && @wait_thread

    File.write(@pid_path, @wait_thread.pid.to_s)
  rescue SystemCallError
    nil
  end

  def forget_pid
    return unless @pid_path

    File.delete(@pid_path) if File.exist?(@pid_path)
  rescue SystemCallError
    nil
  end

  # Whether the pid really is an exiftool. A pid is reused, and a signal sent
  # to whatever took its place would be a very unpleasant surprise.
  def exiftool_process?(pid)
    command = File.read("/proc/#{pid}/cmdline")
    command.include?('exiftool')
  rescue StandardError
    false
  end

  # exiftool's errors go to stderr. Nobody reads them unless a thread does, and
  # a full pipe would block exiftool mid-command, so they are drained
  # continuously and the last few are kept for an error message.
  def start_stderr_reader
    @stderr_thread = Thread.new do
      while (line = @stderr.gets)
        @stderr_mutex.synchronize do
          @stderr_lines << line
          @stderr_lines.shift while @stderr_lines.size > STDERR_KEEP
        end
      end
    end
  end

  def drain_stderr(wait: 0)
    # Give a pending error a moment to land: it is written before the {ready}
    # marker, but the two travel on different pipes.
    if wait.positive? && @stderr
      IO.select([@stderr], nil, nil, wait)
    end

    @stderr_mutex.synchronize do
      lines = @stderr_lines
      @stderr_lines = []
      lines.map(&:strip).reject(&:empty?).join(' ')
    end
  end

  def shutdown
    @stderr_thread&.kill
    @stderr_thread = nil

    if @stdin && !@stdin.closed?
      begin
        @stdin.write("-stay_open\nFalse\n")
        @stdin.flush
      rescue IOError, Errno::EPIPE
        nil
      end
      begin
        @stdin.close
      rescue IOError
        nil
      end
    end

    if @wait_thread
      pid = @wait_thread.pid
      @wait_thread.join(5)
      begin
        Process.kill('TERM', pid) if @wait_thread.alive?
      rescue StandardError
        nil
      end
    end

    @stdin = nil
    @stdout = nil
    @stderr = nil
    @wait_thread = nil
    forget_pid
  end

  # Encodes one argument so exiftool reads it back exactly as it was given.
  #
  # The escapes are the C ones exiftool understands: a backslash, a double
  # quote, and the three whitespace characters that would otherwise be
  # ambiguous in a line-based protocol. Everything else travels as it is;
  # exiftool normalises the remaining control characters to a dot when it
  # writes the value anyway, so escaping them would only make the result
  # differ from the single-process path.
  def escape_argument(argument)
    text = argument.to_s
    text = text.gsub('\\', '\\\\\\\\')
    text = text.gsub('"', '\\"')
    text = text.gsub("\n", '\\n')
    text = text.gsub("\r", '\\r')
    text = text.gsub("\t", '\\t')
    text
  end
end

# The shared exiftool process is stopped when the program ends, so a run that
# never reaches its own cleanup still leaves nothing behind.
at_exit { SidecarWriter.close_shared }
