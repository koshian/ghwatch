# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "minitest/mock"
require "stringio"

class ReviewWorkspaceTest < Minitest::Test
  class Github < Ghwatch::Github
    attr_accessor :pull_request_data

    def initialize
      super(project: nil, command: nil)
      @pull_request_data = {"number" => 167, "state" => "OPEN", "headRefOid" => "tested-head"}
    end

    def pull_request(number) = pull_request_data.dup
  end

  def setup
    @task = Ghwatch::Task.for_pr(167)
    @github = Github.new
    @config = OpenStruct.new(retry_after: 60)
    @state = Object.new
    @state.define_singleton_method(:save_task) { |task| task }
    task = @task
    @state.define_singleton_method(:tasks) { [task] }
  end

  def test_reviewer_uses_prepared_workspace_and_discards_result_when_head_changes
    worktrees = Minitest::Mock.new
    worktrees.expect(:prepare_review, "/review/pr-167") { |task, pr, **options| task == @task && pr["headRefOid"] == "tested-head" }
    roles = Minitest::Mock.new
    outcome = Ghwatch::RoleRunner::Outcome.new(success: true, role: "reviewer", runner: "test", model: "test",
      data: {"status" => "merge"}, error_kind: nil, error: nil, raw_output: "")
    roles.expect(:run, outcome) do |role, **options|
      assert_equal "/review/pr-167", options.fetch(:cwd)
      assert_includes options.fetch(:context), "tested-head"
      assert_includes options.fetch(:context), "Xvfb"
      @github.pull_request_data["headRefOid"] = "new-head"
      true
    end
    reviewer = Ghwatch::Actions::Reviewer.new(
      worktrees: worktrees, project: nil, config: @config, state: @state,
      github: @github, roles: roles, context_builder: Ghwatch::ContextBuilder.new(config: @config),
      human_channel: nil, issue_triage: nil, log: Ghwatch::Log.new(StringIO.new)
    )
    reviewer.run(@task)
    assert_equal "waiting_for_review", @task.state
    assert_match(/changed during review/, @task.last_error)
    refute @task.retry_due?
    assert_nil @task.last_review_signature
    worktrees.verify
    roles.verify
  end

  def test_reconciliation_cleans_review_workspace_only_after_merge_or_close
    worktrees = Minitest::Mock.new
    engine = Ghwatch::TaskEngine.new(
      state: @state, github: @github, human_channel: nil, worker_action: nil,
      reviewer_action: nil, finalizer_action: nil, config: @config, worktrees: worktrees
    )
    engine.reconcile_all
    worktrees.verify
    @github.pull_request_data["state"] = "CLOSED"
    worktrees.expect(:cleanup_review, nil, [@task])
    engine.reconcile_all
    assert @task.done?
    worktrees.verify

    @task.state = "waiting_for_review"
    @github.pull_request_data["mergedAt"] = "2026-10-04T08:00:00Z"
    worktrees.expect(:cleanup_review, nil, [@task])
    engine.reconcile_all
    assert @task.done?
    worktrees.verify
  end

  def test_deep_review_uses_the_prepared_workspace_and_can_accept_the_tested_head
    def @config.auto_merge? = true
    worktrees = Minitest::Mock.new
    2.times do
      worktrees.expect(:prepare_review, "/review/pr-167") { |task, pr, **options| task == @task && pr["headRefOid"] == "tested-head" }
    end
    roles = Minitest::Mock.new
    %w[deep_review merge].each_with_index do |status, index|
      role = (index == 0) ? "reviewer" : "deep_reviewer"
      outcome = Ghwatch::RoleRunner::Outcome.new(success: true, role: role, runner: "test", model: "test",
        data: {"status" => status}, error_kind: nil, error: nil, raw_output: "")
      roles.expect(:run, outcome) do |actual_role, **options|
        assert_equal role, actual_role
        assert_equal "/review/pr-167", options.fetch(:cwd)
        true
      end
    end
    reviewer = Ghwatch::Actions::Reviewer.new(
      worktrees: worktrees, project: nil, config: @config, state: @state,
      github: @github, roles: roles, context_builder: Ghwatch::ContextBuilder.new(config: @config),
      human_channel: nil, issue_triage: nil, log: Ghwatch::Log.new(StringIO.new)
    )
    reviewer.run(@task)
    assert_equal "ready_to_merge", @task.state
    assert @task.retry_due?
    assert_equal @github.review_signature(@github.pull_request_data), @task.last_review_signature
    worktrees.verify
    roles.verify
  end

  def test_a_pr_behind_its_base_is_updated_once_before_review
    def @config.update_pr_branches? = true
    updates = []
    @github.define_singleton_method(:update_pull_request_branch) { |number, expected_head:| updates << [number, expected_head] }
    worktrees = Minitest::Mock.new
    worktrees.expect(:behind_base?, true) { |task, pr| task == @task && pr["headRefOid"] == "tested-head" }
    reviewer = reviewer_with(worktrees, Minitest::Mock.new)
    def reviewer.branch_update_wait = 0
    reviewer.run(@task)
    assert_equal [[167, "tested-head"]], updates
    assert_equal "waiting_for_review", @task.state
    assert @task.retry_due?
    worktrees.verify

    # GitHub has not applied it yet: review the current head instead of asking again.
    worktrees.expect(:prepare_review, "/review/pr-167") { |task, pr, **options| true }
    roles = review_roles("comment")
    reviewer_with(worktrees, roles).run(@task)
    assert_equal 1, updates.size
    worktrees.verify
    roles.verify
  end

  def test_a_refused_update_is_reviewed_as_is_and_not_retried_for_that_head
    def @config.update_pr_branches? = true
    @github.define_singleton_method(:update_pull_request_branch) { |number, expected_head:| raise "merge conflict" }
    worktrees = Minitest::Mock.new
    worktrees.expect(:behind_base?, true) { |task, pr| true }
    worktrees.expect(:prepare_review, "/review/pr-167") { |task, pr, **options| true }
    roles = review_roles("comment")
    reviewer_with(worktrees, roles).run(@task)
    assert_equal "tested-head", @task.metadata["branch_update_failed_head"]
    worktrees.verify
    roles.verify
  end

  def test_a_commented_head_is_not_reviewed_again_until_something_changes
    worktrees = Minitest::Mock.new
    worktrees.expect(:prepare_review, "/review/pr-167") { |task, pr, **options| true }
    def @config.reviewer_requires_green_checks? = true
    @github.pull_request_data["statusCheckRollup"] = [{"name" => "ci", "status" => "IN_PROGRESS", "conclusion" => ""}]
    reviewer_with(worktrees, review_roles("comment")).run(@task)
    assert @task.metadata["commented_review"]

    # Same head, nothing new, and again after the checks move on but are not done.
    skipped = Minitest::Mock.new
    @github.pull_request_data["statusCheckRollup"] = [
      {"name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
      {"name" => "win", "status" => "IN_PROGRESS", "conclusion" => ""}
    ]
    @task.clear_retry
    reviewer_with(worktrees, skipped).run(@task)
    refute @task.retry_due?
    skipped.verify

    # Checks finished: one more review of the same head.
    @github.pull_request_data["statusCheckRollup"] = [{"name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
    worktrees.expect(:prepare_review, "/review/pr-167") { |task, pr, **options| true }
    roles = review_roles("merge")
    reviewer_with(worktrees, roles).run(@task)
    roles.verify
    refute @task.metadata.key?("commented_review")
  end

  def test_a_commented_head_with_no_new_activity_is_not_reviewed_again
    worktrees = Minitest::Mock.new
    worktrees.expect(:prepare_review, "/review/pr-167") { |task, pr, **options| true }
    def @config.reviewer_requires_green_checks? = true
    @github.pull_request_data["statusCheckRollup"] = [{"name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
    reviewer_with(worktrees, review_roles("comment")).run(@task)

    skipped = Minitest::Mock.new
    @task.clear_retry
    reviewer_with(worktrees, skipped).run(@task)
    refute @task.retry_due?
    skipped.verify

    @github.pull_request_data["headRefOid"] = "pushed-head"
    worktrees.expect(:prepare_review, "/review/pr-167") { |task, pr, **options| true }
    roles = review_roles("comment")
    reviewer_with(worktrees, roles).run(@task)
    roles.verify
  end

  def test_each_review_run_logs_its_decision
    worktrees = Minitest::Mock.new
    worktrees.expect(:prepare_review, "/review/pr-167") { |task, pr, **options| true }
    roles = Minitest::Mock.new
    outcome = Ghwatch::RoleRunner::Outcome.new(success: true, role: "deep_reviewer", runner: "test", model: "test",
      data: {"status" => "changes_requested", "body" => "", "reason" => "CI step fails on macOS\nmore"},
      error_kind: nil, error: nil, raw_output: "")
    roles.expect(:run, outcome) { |role, **options| true }
    log = StringIO.new
    reviewer = Ghwatch::Actions::Reviewer.new(
      worktrees: worktrees, project: nil, config: @config, state: @state,
      github: @github, roles: roles, context_builder: Ghwatch::ContextBuilder.new(config: @config),
      human_channel: nil, issue_triage: nil, log: Ghwatch::Log.new(log)
    )
    reviewer.run(@task)
    assert_includes log.string, "[pr-167] deep_reviewer -> changes_requested: CI step fails on macOS\n"
  end

  def test_a_passed_test_of_the_reviewed_head_goes_to_merge_without_another_review
    posts = answered_test
    roles = judge_roles("passed", "Both Windows versions passed every step.") do |context|
      assert_includes context, "Windows 11 and 10: all steps succeeded."
      assert_includes context, "judge only the person's answer"
    end
    # No workspace, branch update or review: the worktrees mock expects nothing.
    reviewer_with(Minitest::Mock.new, roles).check_test_result(@task)
    roles.verify
    assert_equal "ready_to_merge", @task.state
    assert @task.retry_due?
    assert_equal [[:pr, "review-ok"]], posts
    assert_equal @github.review_signature(@github.pull_request_data), @task.last_review_signature
  end

  def test_a_reported_problem_goes_back_to_the_worker
    posts = answered_test
    reviewer_with(Minitest::Mock.new, judge_roles("problem", "Quitting from the menu still drops the connection.")).check_test_result(@task)
    assert_equal "changes_requested", @task.state
    assert_equal 1, @task.metadata["rework_rounds"]
    assert_equal [[:pr, "changes-requested"]], posts
    assert @task.metadata["human_answer"], "the worker is given the report"
  end

  def test_an_incomplete_answer_asks_for_the_rest_and_comes_back_to_the_judge
    answered_test
    asked = []
    channel = Object.new
    channel.define_singleton_method(:wait) do |task:, body:, outcome:, kind:, target:|
      asked << [body, kind, target]
      task.human_marker = "<!-- ghwatch:human-test:again -->"
    end
    roles = judge_roles("incomplete", "", reporter_message: "Please also try step 5.")
    reviewer_with(Minitest::Mock.new, roles, human_channel: channel).check_test_result(@task)
    assert_equal [["Please also try step 5.", "human-test", :pull_request]], asked
    assert_equal "waiting_for_human_test", @task.state
    assert_equal "checking_test_result", @task.metadata["resume_state"]
  end

  def test_a_pr_changed_since_the_test_is_reviewed_again
    answered_test
    @github.pull_request_data["headRefOid"] = "pushed-head"
    worktrees = Minitest::Mock.new
    worktrees.expect(:same_changes?, false, [@task], base: "main", from: "tested-head", to: "pushed-head")
    roles = Minitest::Mock.new
    reviewer_with(worktrees, roles).check_test_result(@task)
    worktrees.verify
    roles.verify
    assert_equal "waiting_for_review", @task.state
    assert @task.retry_due?
  end

  def test_a_pr_that_only_merged_its_base_since_the_test_is_judged
    answered_test
    @github.pull_request_data["headRefOid"] = "updated-head"
    worktrees = Minitest::Mock.new
    worktrees.expect(:same_changes?, true, [@task], base: "main", from: "tested-head", to: "updated-head")
    reviewer_with(worktrees, judge_roles("passed", "Confirmed.")).check_test_result(@task)
    worktrees.verify
    assert_equal "ready_to_merge", @task.state
  end

  private

  # The reviewer asked for a test of "tested-head" and the person answered.
  def answered_test
    @task.state = "checking_test_result"
    @task.metadata["human_test_head"] = "tested-head"
    @github.pull_request_data["baseRefName"] = "main"
    @task.metadata["human_answer"] = {"question" => {"where" => "PR #167", "body" => "Please test on Windows"},
                                      "replies" => [{"where" => "PR #167", "author" => "reporter",
                                                     "body" => "Windows 11 and 10: all steps succeeded."}]}
    posts = []
    @github.define_singleton_method(:post_pr_comment) { |number, body, kind:, model_signature:| posts << [:pr, kind] }
    posts
  end

  def judge_roles(status, body, reporter_message: nil, &check)
    roles = Minitest::Mock.new
    outcome = Ghwatch::RoleRunner::Outcome.new(success: true, role: "test_judge", runner: "test", model: "test",
      data: {"status" => status, "body" => body, "reporter_message" => reporter_message}.compact,
      error_kind: nil, error: nil, raw_output: "")
    roles.expect(:run, outcome) do |role, **options|
      check&.call(options.fetch(:context))
      role == "test_judge" && options.fetch(:cwd) == "/project"
    end
    roles
  end

  def reviewer_with(worktrees, roles, human_channel: nil)
    Ghwatch::Actions::Reviewer.new(
      worktrees: worktrees, project: OpenStruct.new(root: "/project"), config: @config, state: @state,
      github: @github, roles: roles, context_builder: Ghwatch::ContextBuilder.new(config: @config),
      human_channel: human_channel, issue_triage: nil, log: Ghwatch::Log.new(StringIO.new)
    )
  end

  def review_roles(status)
    roles = Minitest::Mock.new
    outcome = Ghwatch::RoleRunner::Outcome.new(success: true, role: "reviewer", runner: "test", model: "test",
      data: {"status" => status, "body" => ""}, error_kind: nil, error: nil, raw_output: "")
    roles.expect(:run, outcome) { |role, **options| options.fetch(:cwd) == "/review/pr-167" }
    roles
  end
end
