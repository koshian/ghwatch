# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "rbconfig"
require "minitest/mock"

class AgentProgressTest < Minitest::Test
  class Terminal < StringIO
    def tty? = true
  end

  def test_spinner_animates_and_is_cleared_on_finish
    io = Terminal.new
    progress = Ghwatch::AgentProgress.new(label: "[worker] [pr-164]", io: io)
    2.times { progress.tick }
    progress.finish
    assert_includes io.string, "| [worker] [pr-164] running"
    assert_includes io.string, "/ [worker] [pr-164] running"
    assert io.string.end_with?("\r\e[2K")
  end

  def test_non_terminal_output_has_no_spinner_and_flushes_partial_lines
    io = StringIO.new
    progress = Ghwatch::AgentProgress.new(label: "[reviewer]", io: io)
    progress.tick
    progress.output(:stdout, "test")
    progress.output(:stdout, "s passed\nfinal")
    progress.output(:stderr, "warning\n")
    progress.finish
    assert_equal "[reviewer] stdout: tests passed\n[reviewer] stderr: warning\n[reviewer] stdout: final\n", io.string
  end

  def test_command_streams_before_exit_and_preserves_result_output
    Dir.mktmpdir do |directory|
      gate = File.join(directory, "continue")
      io = StringIO.new
      progress = Ghwatch::AgentProgress.new(label: "[worker]", io: io)
      received = Queue.new
      progress.define_singleton_method(:output) do |stream, text|
        super(stream, text)
        received.push(true) if text.include?("starting")
      end
      script = 'STDOUT.sync = true; puts "starting"; sleep 0.01 until File.exist?(ARGV.fetch(0)); STDERR.write("warning"); puts "finished"'
      thread = Thread.new { Ghwatch::Command.new.run(RbConfig.ruby, "-e", script, gate, progress: progress, timeout: 3) }
      assert received.pop(timeout: 2), "expected output before subprocess exit"
      assert thread.alive?
      File.write(gate, "continue")
      result = thread.value
      assert result.success?
      assert_equal "starting\nfinished\n", result.stdout
      assert_equal "warning", result.stderr
      assert_includes io.string, "stdout: starting"
      assert_includes io.string, "stderr: warning"
    ensure
      thread&.join
    end
  end

  def test_timeout_stops_spinner_and_keeps_partial_output
    io = Terminal.new
    progress = Ghwatch::AgentProgress.new(label: "[worker]", io: io)
    result = Ghwatch::Command.new.run(RbConfig.ruby, "-e", 'STDOUT.sync = true; print "partial"; sleep 5', progress: progress, timeout: 0.3)
    assert result.timed_out
    assert_equal "partial", result.stdout
    assert_includes io.string, "stdout: partial"
    assert io.string.end_with?("\r\e[2K")
  end

  def test_role_runner_enables_progress_only_when_verbose_and_preserves_protocol
    [false, true].each do |verbose|
      command = Minitest::Mock.new
      output = "GHWATCH_RESULT_BEGIN\n{\"status\":\"continue\"}\nGHWATCH_RESULT_END\n"
      result = Ghwatch::Command::Result.new(argv: [], stdout: output, stderr: "", exit_code: 0, timed_out: false)
      command.expect(:run, result) do |*args, **options|
        if verbose
          assert_instance_of Ghwatch::AgentProgress, options.fetch(:progress)
        else
          refute options.key?(:progress)
        end
        true
      end
      config = Ghwatch::Config.new({"roles" => {"worker" => {"models" => [{"runner" => "opencode", "model" => "test"}]}}})
      prompts = Object.new
      def prompts.compose(role, context:) = "prompt"
      runner = Ghwatch::RoleRunner.new(config: config, command: command, prompt_store: prompts,
        log: Ghwatch::Log.new(StringIO.new), verbose: verbose)
      outcome = runner.run("worker", context: "context", cwd: ".")
      assert outcome.success?
      assert_equal "continue", outcome.data.fetch("status")
      command.verify
    end
  end
end
