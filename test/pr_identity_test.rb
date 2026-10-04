# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "minitest/mock"

class PrIdentityTest < Minitest::Test
  class Github
    attr_accessor :pr
    attr_reader :comments, :lookups

    def initialize
      @comments = []
      @lookups = []
    end

    def issue(number)
      {"number" => number, "state" => "OPEN"}
    end

    def pull_request(number)
      @lookups << number
      raise "not a pull request" unless pr && pr["number"] == number

      pr
    end

    def pull_request_for_branch(branch)
      pr if pr && pr["headRefName"] == branch
    end

    def issue_signature(issue)
      "issue"
    end

    def pr_signature(pr)
      "pr"
    end

    def review_signature(pr)
      "review"
    end

    def post_issue_comment(number, body, **options)
      @comments << [:issue, number, body]
      "marker"
    end

    def post_pr_comment(number, body, **options)
      @comments << [:pr, number, body]
      "marker"
    end

    def human_comments_after(number, marker:)
      @lookups << number
      ["reply"]
    end
  end

  class State
    attr_reader :tasks

    def initialize(task)
      @tasks = [task]
    end

    def save_task(task)
      task
    end
  end

  class Action
    attr_reader :calls

    def initialize
      @calls = []
    end

    def run(task)
      @calls << task.pr_number
    end
  end

  def setup
    @task = Ghwatch::Task.for_issue(160, branch: "ghwatch/issue-160", worktree: nil)
    @github = Github.new
    @state = State.new(@task)
    @config = OpenStruct.new(retry_after: 60)
    @reviewer = Action.new
    @finalizer = Action.new
    @human_channel = Ghwatch::HumanChannel.new(github: @github)
    @engine = Ghwatch::TaskEngine.new(
      state: @state, github: @github, config: @config, human_channel: @human_channel,
      worker_action: Action.new, reviewer_action: @reviewer, finalizer_action: @finalizer
    )
  end

  def create_pr
    @github.pr = {"number" => 164, "headRefName" => @task.branch, "state" => "OPEN", "isDraft" => false}
  end

  def action_options
    {
      project: OpenStruct.new(root: "."), config: @config, state: @state, github: @github,
      roles: nil, context_builder: nil, human_channel: @human_channel, issue_triage: nil
    }
  end

  def test_missing_pr_prevents_review_and_finalization_and_a_later_pr_resumes_review
    %w[waiting_for_review waiting_for_re_review ready_to_merge finalizing].each do |state|
      @task.transition_to(state, retry_at: 0)
      @engine.run_due
      assert_equal "continuing", @task.state
      assert @task.retry_at
      assert_nil @task.pr_number
    end
    assert_empty @reviewer.calls
    assert_empty @finalizer.calls
    assert_empty @github.comments

    create_pr
    @engine.reconcile_all
    @engine.run_due
    assert_equal 160, @task.issue_number
    assert_equal 164, @task.pr_number
    assert_equal [164], @reviewer.calls
  end

  def test_worker_does_not_store_an_issue_number_as_a_pr_number
    worker = Ghwatch::Actions::Worker.new(worktrees: nil, command: nil, **action_options)
    outcome = OpenStruct.new(data: {"status" => "waiting_for_review", "pr" => 160})
    assert_raises(RuntimeError) { worker.send(:apply_result, @task, outcome) }
    assert_nil @task.pr_number
    assert_equal "implementing", @task.state
    assert_equal [160], @github.lookups
    assert_empty @github.comments
  end

  def test_reconciliation_recovers_a_review_wait_without_a_retry_or_a_pr
    @task.transition_to("waiting_for_review")
    @engine.reconcile_all
    assert_equal "continuing", @task.state
    assert @task.retry_at
    assert_empty @reviewer.calls
  end

  def test_github_uses_pr_lookup_and_does_not_fall_back_to_the_issues_api
    command = Minitest::Mock.new
    result = Ghwatch::Command::Result.new(argv: [], stdout: "", stderr: "not a pull request", exit_code: 1, timed_out: false)
    command.expect(:run, result) do |*args, **options|
      args.first(4) == ["gh", "pr", "view", "160"]
    end
    github = Ghwatch::Github.new(project: OpenStruct.new(root: "."), command: command)
    assert_raises(RuntimeError) { github.pull_request(160) }
    command.verify
  end

  def test_invalid_worker_pr_result_is_retried_without_poisoning_the_task
    command = Minitest::Mock.new
    result = Ghwatch::Command::Result.new(argv: [], stdout: "head", stderr: "", exit_code: 0, timed_out: false)
    2.times { command.expect(:run, result) { |*args, **options| args.first == "git" } }
    outcome = Ghwatch::RoleRunner::Outcome.new(
      success: true, role: "worker", runner: "test", model: "test",
      data: {"status" => "waiting_for_review", "pr" => 160},
      error_kind: nil, error: nil, raw_output: ""
    )
    roles = Minitest::Mock.new
    roles.expect(:run, outcome) { |role, **options| role == "worker" }
    worker = Ghwatch::Actions::Worker.new(
      worktrees: nil, command: command,
      **action_options.merge(roles: roles, context_builder: Ghwatch::ContextBuilder.new(config: @config))
    )
    engine = Ghwatch::TaskEngine.new(
      state: @state, github: @github, config: @config, human_channel: @human_channel,
      worker_action: worker, reviewer_action: @reviewer, finalizer_action: @finalizer,
      log: Ghwatch::Log.new(StringIO.new)
    )
    engine.run_due
    assert_nil @task.pr_number
    assert_equal "implementing", @task.state
    assert @task.retry_at
    assert_match(/not a pull request/, @task.last_error)
    assert_empty @reviewer.calls
    assert_empty @github.comments
    command.verify
    roles.verify
  end

  def test_worker_retries_when_done_or_ready_for_review_without_a_pr
    worker = Ghwatch::Actions::Worker.new(worktrees: nil, command: nil, **action_options)
    %w[done waiting_for_review].each do |status|
      worker.send(:apply_result, @task, OpenStruct.new(data: {"status" => status}))
      assert_equal "continuing", @task.state
      assert @task.retry_at
      assert_nil @task.pr_number
    end
  end

  def test_worker_validates_branch_before_storing_pr_identity
    create_pr
    worker = Ghwatch::Actions::Worker.new(worktrees: nil, command: nil, **action_options)
    outcome = OpenStruct.new(data: {"status" => "waiting_for_review", "pr" => "164"})
    @github.pr["headRefName"] = "unrelated"
    assert_raises(RuntimeError) { worker.send(:apply_result, @task, outcome) }
    assert_nil @task.pr_number
    @github.pr["headRefName"] = @task.branch
    triage = Object.new
    def triage.request! = nil
    worker = Ghwatch::Actions::Worker.new(worktrees: nil, command: nil, **action_options.merge(issue_triage: triage))
    worker.send(:apply_result, @task, outcome)
    assert_equal 164, @task.pr_number
    assert_equal "waiting_for_review", @task.state
  end

  def test_finalizer_does_not_run_for_a_missing_or_unmerged_pr
    finalizer = Ghwatch::Actions::Finalizer.new(worktrees: nil, **action_options)
    finalizer.run(@task)
    assert_equal "continuing", @task.state
    create_pr
    @task.pr_number = 164
    finalizer.run(@task)
    assert_equal "waiting_for_review", @task.state
    assert_empty @github.comments
  end

  def test_review_test_request_and_reply_use_the_pr_conversation
    create_pr
    @task.pr_number = 164
    triage = Object.new
    def triage.request! = nil
    reviewer = Ghwatch::Actions::Reviewer.new(**action_options.merge(issue_triage: triage))
    outcome = OpenStruct.new(data: {"status" => "waiting_for_human_test", "body" => "Test this PR"}, signature: "reviewer")
    reviewer.send(:apply_result, @task, @github.pr, outcome)
    assert_equal [[:pr, 164, "Test this PR"]], @github.comments
    assert_equal "waiting_for_human_test", @task.state
    restored = Ghwatch::Task.from_row(@task.to_row)
    assert @human_channel.reply_received?(restored)
    assert_equal [164], @github.lookups
  end

  def test_existing_issue_waits_still_detect_replies_on_the_issue
    @task.human_marker = "old-marker"
    assert @human_channel.reply_received?(@task)
    assert_equal [160], @github.lookups
  end
end
