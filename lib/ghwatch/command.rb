# frozen_string_literal: true

require "childprocess"
require "tempfile"

module Ghwatch
  class Command
    Result = Data.define(:argv, :stdout, :stderr, :exit_code, :timed_out) do
      def success?
        !timed_out && exit_code == 0
      end

      def text
        [stdout, stderr].reject(&:empty?).join("\n")
      end
    end

    def initialize(log: Log.new)
      @log = log
    end

    def run(*argv, chdir: nil, env: {}, timeout: 300, quiet: true, stdin: nil, progress: nil)
      stdout_file = Tempfile.new("ghwatch-stdout")
      stderr_file = Tempfile.new("ghwatch-stderr")
      process = ChildProcess.build(*argv.map(&:to_s))
      if chdir
        process.cwd = chdir.to_s
        # Some agent CLIs (e.g. OpenCode) take their directory from PWD, which
        # would otherwise still name the directory ghwatch was started from.
        process.environment["PWD"] = File.expand_path(chdir.to_s)
      end
      env.each { |key, value| process.environment[key.to_s] = value.to_s }
      process.io.stdout = stdout_file
      process.io.stderr = stderr_file
      process.duplex = true if stdin

      @log.info("$ #{argv.join(" ")}") unless quiet
      process.start
      stdin_writer = write_stdin(process, stdin) if stdin
      if progress
        progress_stop = Queue.new
        progress_thread = monitor_output(stdout_file.path, stderr_file.path, progress, progress_stop)
      end

      timed_out = false
      begin
        process.poll_for_exit(timeout)
      rescue ChildProcess::TimeoutError
        timed_out = true
        process.stop
      end

      stdout_file.rewind
      stderr_file.rewind

      Result.new(
        argv: argv,
        stdout: stdout_file.read,
        stderr: stderr_file.read,
        exit_code: timed_out ? nil : process.exit_code,
        timed_out: timed_out
      )
    ensure
      # Don't leave an agent running when ghwatch is interrupted mid-command.
      process.stop if process&.alive?
      stdin_writer&.join
      progress_stop&.push(true)
      progress_thread&.value
      stdout_file&.close!
      stderr_file&.close!
    end

    def executable?(name)
      paths = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
      extensions = Gem.win_platform? ? ENV.fetch("PATHEXT", ".EXE;.BAT;.CMD").split(";") : [""]

      paths.any? do |directory|
        extensions.any? do |extension|
          path = File.join(directory, "#{name}#{extension}")
          File.file?(path) && File.executable?(path)
        end
      end
    end

    private

    def monitor_output(stdout_path, stderr_path, progress, stop)
      Thread.new do
        File.open(stdout_path, "r") do |stdout|
          File.open(stderr_path, "r") do |stderr|
            readers = {stdout: stdout, stderr: stderr}
            loop do
              readers.each { |stream, reader| progress.output(stream, reader.read) }
              progress.tick
              break if stop.pop(timeout: 0.1)
            end
            readers.each { |stream, reader| progress.output(stream, reader.read) }
          end
        end
      ensure
        progress.finish
      end
    end

    # Written from a thread so a child that stops reading can't block the
    # timeout; the pipe breaks once the child exits or is stopped.
    def write_stdin(process, data)
      Thread.new do
        io = process.io.stdin
        io.write(data.to_s)
      rescue Errno::EPIPE, IOError
        nil
      ensure
        io&.close unless io&.closed?
      end
    end
  end
end
