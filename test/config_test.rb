# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  REVIEWER = {"prompt" => "reviewer.md", "models" => [{"runner" => "opencode", "model" => "reviewer-model"}]}.freeze

  def test_the_test_judge_runs_on_the_reviewer_models_with_its_own_prompt_unless_configured
    judge = Ghwatch::Config.new({"roles" => {"reviewer" => REVIEWER}}).role("test_judge")
    assert_equal "test_judge.md", judge.prompt
    assert_equal ["reviewer-model"], judge.models.map(&:model)
    assert File.exist?(File.join(Ghwatch::PromptStore::BUILTIN_DIR, judge.prompt))

    own = {"models" => [{"runner" => "claude", "model" => "judge-model"}]}
    judge = Ghwatch::Config.new({"roles" => {"reviewer" => REVIEWER, "test_judge" => own}}).role("test_judge")
    assert_equal ["judge-model"], judge.models.map(&:model)

    error = assert_raises(Ghwatch::Config::Error) { Ghwatch::Config.new({"roles" => {}}).role("test_judge") }
    assert_includes error.message, "[roles.test_judge]"
  end
end
