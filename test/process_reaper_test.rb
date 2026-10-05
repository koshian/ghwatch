# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class ProcessReaperTest < Minitest::Test
  def setup
    skip "needs /proc" unless File.directory?("/proc/self")
    @directory = Dir.mktmpdir("ghwatch-reaper")
    @log = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory
  end

  def test_an_agent_run_stops_what_it_detached_and_spares_other_processes
    pid_file = File.join(@directory, "detached.pid")
    agent = File.join(@directory, "agent")
    File.write(agent, <<~SH)
      #!/bin/sh
      setsid sh -c 'echo $$ > #{pid_file}; exec sleep 300' </dev/null >/dev/null 2>&1 &
      while [ ! -s #{pid_file} ]; do sleep 0.05; done
      echo done
    SH
    File.chmod(0o755, agent)
    bystander = Process.spawn("sleep", "300")
    runner = Ghwatch::Runners::OpenCode.new(
      settings: {"command" => agent, "timeout" => "30s"},
      command: Ghwatch::Command.new(log: Ghwatch::Log.new(StringIO.new)),
      log: Ghwatch::Log.new(@log)
    )

    runner.run(model: "test", prompt: "", cwd: @directory)
    detached = File.read(pid_file).to_i
    refute alive?(detached), "the detached process should have been stopped"
    assert alive?(bystander)
    assert_includes @log.string, "the agent left running"
  ensure
    Process.kill("KILL", bystander) if bystander
    Process.wait(bystander) if bystander
  end

  def test_nothing_is_stopped_without_marked_processes
    reaper = Ghwatch::ProcessReaper.new(log: Ghwatch::Log.new(@log))
    assert_empty reaper.reap(reaper.new_mark)
    assert_empty @log.string
  end

  private

  def alive?(pid)
    Process.kill(0, pid)
    !File.read("/proc/#{pid}/stat").split[2].eql?("Z")
  rescue SystemCallError
    false
  end
end
