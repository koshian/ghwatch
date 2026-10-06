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

  private

  def reviewer_with(worktrees, roles)
    Ghwatch::Actions::Reviewer.new(
      worktrees: worktrees, project: nil, config: @config, state: @state,
      github: @github, roles: roles, context_builder: Ghwatch::ContextBuilder.new(config: @config),
      human_channel: nil, issue_triage: nil, log: Ghwatch::Log.new(StringIO.new)
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
