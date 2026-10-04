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

    def run(*argv, chdir: nil, env: {}, timeout: 300, quiet: true)
      stdout_file = Tempfile.new("ghwatch-stdout")
      stderr_file = Tempfile.new("ghwatch-stderr")
      process = ChildProcess.build(*argv.map(&:to_s))
      process.cwd = chdir.to_s if chdir
      env.each { |key, value| process.environment[key.to_s] = value.to_s }
      process.io.stdout = stdout_file
      process.io.stderr = stderr_file

      @log.info("$ #{argv.join(' ')}") unless quiet
      process.start

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
  end
end
