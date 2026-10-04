# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class RunnerResultTest < Minitest::Test
  def invoke(output, exit_code: 0, timed_out: false)
    command = Minitest::Mock.new
    result = Ghwatch::Command::Result.new(argv: [], stdout: output, stderr: "", exit_code: exit_code, timed_out: timed_out)
    command.expect(:run, result) { |*args, **options| true }
    runner = Ghwatch::Runners::OpenCode.new(
      settings: {"command" => "opencode", "capacity_patterns" => ["capacity"]}, command: command
    )
    invocation = runner.run(model: "test", prompt: "test", cwd: ".")
    command.verify
    invocation
  end

  def test_successful_review_is_not_discarded_due_to_words_in_inspected_code
    output = <<~TEXT
      const COMMAND_CAPACITY: usize = 128;
      quota handling and rate limits were reviewed
      GHWATCH_RESULT_BEGIN
      {"status":"changes_requested","body":"Fix the lifecycle"}
      GHWATCH_RESULT_END
    TEXT
    result = invoke(output)
    assert result.success?
    assert_nil result.error_kind
    assert_equal "changes_requested", Ghwatch::Result.parse(result.output).fetch("status")
    refute invoke(output, exit_code: 1).success?
    assert_equal "timeout", invoke(output, timed_out: true).error_kind
  end

  def test_capacity_and_quota_failures_without_a_result_still_allow_fallback
    assert_equal "capacity", invoke("capacity unavailable", exit_code: 1).error_kind
    assert_equal "quota", invoke("quota exceeded").error_kind
    assert_equal "quota", invoke("quota exceeded\nGHWATCH_RESULT_BEGIN\ninvalid JSON\nGHWATCH_RESULT_END").error_kind
  end
end
