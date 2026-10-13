# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

# Each time a PR goes back to the worker, why it did is kept, so the worker
# and reviewers can tell when the rounds circle around one mechanism, and the
# person asked at the limit can see how it got there.
class ReworkHistoryTest < Minitest::Test
  class HumanChannel
    attr_reader :asked

    def initialize = @asked = []

    def wait(task:, body:, outcome:, kind:, target:)
      @asked << body
      task.human_marker = "marker"
    end
  end

  def setup
    @channel = HumanChannel.new
    @config = OpenStruct.new(retry_after: 60, human_language: "English")
    @machine = Ghwatch::StateMachine.new(github: nil, config: @config, human_channel: @channel,
      log: Ghwatch::Log.new(StringIO.new))
    @task = Ghwatch::Task.for_issue(7, branch: "ghwatch/issue-7", worktree: "/w/7")
    @task.pr_number = 9
    @task.state = "waiting_for_review"
  end

  def review(summary, solved: nil, simplify: nil)
    rework = {"source" => "review", "summary" => summary, "main_problem_solved" => solved, "simplify" => simplify}.compact
    @machine.apply_result(@task, "reviewer", "changes_requested", rework: rework)
    @task.state = "waiting_for_review" unless @task.state == "waiting_for_human_input"
  end

  def test_rounds_are_kept_and_shown_to_the_worker_and_the_reviewer
    review("URL boundary misses a closing quote", solved: false)
    @task.state = "ready_to_merge"
    @machine.react(@task, {"checks_failed" => {head: "h2", failed: ["CI"]}})
    @task.state = "changes_requested"

    assert_equal [
      {"round" => 1, "source" => "review", "summary" => "URL boundary misses a closing quote", "main_problem_solved" => false},
      {"round" => 2, "source" => "checks", "summary" => "Required CI checks failed: CI"}
    ], @task.metadata["rework_history"]

    builder = Ghwatch::ContextBuilder.new(config: @config)
    [builder.worker(task: @task, issue: nil, pull_request: nil),
      builder.reviewer(task: @task, issue: nil, pull_request: {"headRefOid" => "h3"})].each do |context|
      assert_includes context, "Rework round: 2 of #{Ghwatch::StateMachine::REWORK_LIMIT}"
      assert_includes context, "1. review: URL boundary misses a closing quote\n2. checks: Required CI checks failed: CI"
    end
  end

  def test_a_task_never_sent_back_is_not_told_about_rounds
    context = Ghwatch::ContextBuilder.new(config: @config).worker(task: @task, issue: nil, pull_request: nil)
    refute_includes context, "Rework round"
  end

  def test_the_person_asked_at_the_limit_sees_the_rounds_whether_the_issue_is_solved_and_what_to_simplify
    review("quote not excluded", solved: false)
    review("full stop not excluded", simplify: "Shorten only a pasted text that is a single URL")
    review("& in the query cut off")
    review("boundary check is quadratic in the input length", solved: true, simplify: "Shorten only a pasted text that is a single URL")

    assert_equal "waiting_for_human_input", @task.state
    message = @channel.asked.last
    assert_includes message, "Rework rounds:\n1. review: quote not excluded\n2. review: full stop not excluded\n" \
      "3. review: & in the query cut off\n4. review: boundary check is quadratic in the input length"
    assert_includes message, "As the reviewer sees it, the issue's own problem is solved."
    assert_includes message, "Ways to simplify:\n- Shorten only a pasted text that is a single URL"
    refute_includes message.sub("Ways to simplify:\n- Shorten", ""), "Shorten only", "each idea once"

    @machine.react(@task, {"reply" => {question: {}, replies: []}})
    refute @task.metadata.key?("rework_history"), "a reply starts a fresh set of rounds"
  end

  def test_the_question_is_in_japanese_when_people_read_japanese
    @config.human_language = "ja"
    @task.metadata["rework_rounds"] = Ghwatch::StateMachine::REWORK_LIMIT
    review("下書きを戻す仕組みに競合が残る", solved: true, simplify: "下書きを戻す仕組みを外す")

    message = @channel.asked.last
    assert_includes message, "差し戻しの経緯:\n1. レビュー: 下書きを戻す仕組みに競合が残る"
    assert_includes message, "本題(Issue の問題)は、レビュアーの見立てでは解決済みです。"
    assert_includes message, "単純化の候補:\n- 下書きを戻す仕組みを外す"
  end

  def test_long_reasons_are_cut_and_unknown_values_dropped
    @machine.apply_result(@task, "reviewer", "changes_requested",
      rework: {"source" => "review", "summary" => "x" * 500, "main_problem_solved" => "maybe", "simplify" => " "})
    round = @task.metadata["rework_history"].last
    assert_equal Ghwatch::StateMachine::REWORK_SUMMARY_LENGTH + 2, round["summary"].length
    refute round.key?("main_problem_solved")
    refute round.key?("simplify")
  end
end
