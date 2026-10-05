# frozen_string_literal: true

require "securerandom"

module Ghwatch
  # Agents start servers, virtual displays and apps that detach into their
  # own sessions (setsid), so they outlive the agent and are no longer its
  # process group. Every agent run is marked with an environment variable,
  # which those descendants inherit; after the run, whatever still carries
  # the mark is stopped. Linux only (/proc); elsewhere this does nothing.
  class ProcessReaper
    VARIABLE = "GHWATCH_RUN_ID"

    def initialize(log: Log.new, proc_root: "/proc", grace: 5)
      @log = log
      @proc_root = proc_root
      @grace = grace
    end

    def new_mark
      SecureRandom.hex(12)
    end

    def reap(mark)
      pids = marked(mark)
      return [] if pids.empty?

      signal("TERM", pids)
      deadline = Time.now + @grace
      sleep 0.2 while pids.any? { |pid| alive?(pid) } && Time.now < deadline
      signal("KILL", pids.select { |pid| alive?(pid) })
      @log.warn("stopped #{pids.size} process(es) the agent left running: #{pids.join(", ")}")
      pids
    end

    def marked(mark)
      entry = "#{VARIABLE}=#{mark}"
      Dir.glob(File.join(@proc_root, "[0-9]*")).filter_map do |directory|
        pid = File.basename(directory).to_i
        next if pid == Process.pid

        environ = File.binread(File.join(directory, "environ"))
        pid if environ.split("\0").include?(entry)
      rescue SystemCallError
        nil
      end
    end

    private

    def signal(name, pids)
      pids.each do |pid|
        Process.kill(name, pid)
      rescue SystemCallError
        nil
      end
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue SystemCallError
      false
    end
  end
end
