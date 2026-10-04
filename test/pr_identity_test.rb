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
      {"number" => number, "state" => "OPEN", "author" => {"login" => "reporter"}}
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

  def test_worker_cannot_replace_an_assigned_pr_or_request_review_with_conflicts
    create_pr
    @task.pr_number = 164
    @task.state = "changes_requested"
    worker = Ghwatch::Actions::Worker.new(worktrees: nil, command: nil, **action_options)
    @github.pr["mergeable"] = "CONFLICTING"
    outcome = OpenStruct.new(data: {"status" => "waiting_for_review", "pr" => 164})
    assert_raises(RuntimeError) { worker.send(:apply_result, @task, outcome) }
    @github.pr["number"] = 165
    @github.pr["mergeable"] = "MERGEABLE"
    outcome.data["pr"] = 165
    assert_raises(RuntimeError) { worker.send(:apply_result, @task, outcome) }
    assert_equal 164, @task.pr_number
    assert_equal "changes_requested", @task.state
    assert_empty @github.comments
  end

  def test_reviewer_environment_request_waits_on_the_pr_and_reply_resumes_review
    create_pr
    @task.pr_number = 164
    triage = Object.new
    def triage.request! = nil
    reviewer = Ghwatch::Actions::Reviewer.new(**action_options.merge(issue_triage: triage))
    body = "Install fontconfig and fonts-dejavu-core: sudo apt install fontconfig fonts-dejavu-core. Verify with fc-match, then reply on this PR."
    reviewer.send(:apply_result, @task, @github.pr, OpenStruct.new(
      data: {"status" => "waiting_for_human_input", "body" => body}, signature: "reviewer"
    ))
    assert_equal "waiting_for_human_input", @task.state
    assert_equal 164, @task.metadata["human_conversation_number"]
    assert_equal "waiting_for_review", @task.metadata["resume_state"]
    assert_nil @task.retry_at
    assert_equal [[:pr, 164, body]], @github.comments
    @engine.run_due
    assert_empty @reviewer.calls
    @engine.reconcile_all
    assert_equal "waiting_for_review", @task.state
    @engine.run_due
    assert_equal [164], @reviewer.calls
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
    %w[done waiting_for_review waiting_for_human_test].each do |status|
      worker.send(:apply_result, @task, OpenStruct.new(data: {"status" => status}))
      assert_equal "continuing", @task.state
      assert @task.retry_at
      assert_nil @task.pr_number
    end
  end

  def test_worker_human_test_proposal_is_persisted_and_reviewed_before_notifying_a_person
    create_pr
    triage = Object.new
    def triage.request! = nil
    preparation = {
      "commit" => "tested-sha", "verified" => ["automated checks passed"],
      "remaining" => ["native OS behavior"], "test_subject" => "build URL and startup instructions",
      "steps" => ["Enable the feature and check the expected result"]
    }
    worker = Ghwatch::Actions::Worker.new(worktrees: nil, command: nil, **action_options.merge(issue_triage: triage))
    outcome = OpenStruct.new(data: {
      "status" => "waiting_for_human_test", "pr" => 164,
      "question" => "Please test native OS behavior", "test_preparation" => preparation
    })
    worker.send(:apply_result, @task, outcome)
    assert_equal "waiting_for_review", @task.state
    assert_equal 164, @task.pr_number
    assert @task.retry_due?
    assert_nil @task.human_marker
    assert_empty @github.comments

    restored = Ghwatch::Task.from_row(@task.to_row)
    assert_equal preparation, restored.metadata["test_preparation"]
    context = Ghwatch::ContextBuilder.new(config: @config).reviewer(
      task: restored, issue: @github.issue(160), pull_request: @github.pr
    )
    assert_includes context, "tested-sha"
    assert_includes context, "Please test native OS behavior"

    reviewer = Ghwatch::Actions::Reviewer.new(**action_options.merge(issue_triage: triage))
    reviewer.send(:apply_result, restored, @github.pr, OpenStruct.new(
      data: {"status" => "changes_requested", "body" => "Prepare the required test build first"},
      signature: "reviewer"
    ))
    assert_equal "changes_requested", restored.state
    assert restored.uses_worker_slot?
    assert_nil restored.human_marker
    assert_equal [[:pr, 164, "Prepare the required test build first"]], @github.comments
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

  def test_review_test_request_mentions_reporter_on_the_issue_and_detects_issue_reply
    create_pr
    @task.pr_number = 164
    triage = Object.new
    def triage.request! = nil
    reviewer = Ghwatch::Actions::Reviewer.new(**action_options.merge(issue_triage: triage))
    outcome = OpenStruct.new(data: {"status" => "waiting_for_human_test", "body" => "Test this PR"}, signature: "reviewer")
    reviewer.send(:apply_result, @task, @github.pr, outcome)
    assert_equal [[:issue, 160, "@reporter\n\nTest this PR"]], @github.comments
    assert_equal "waiting_for_human_test", @task.state
    restored = Ghwatch::Task.from_row(@task.to_row)
    assert @human_channel.reply_received?(restored)
    assert_equal [160], @github.lookups
  end

  def test_pr_only_test_request_uses_pr_and_existing_mention_is_not_duplicated
    task = Ghwatch::Task.for_pr(164)
    outcome = OpenStruct.new(signature: "reviewer")
    @human_channel.wait(task: task, body: "Test this PR", outcome: outcome,
      kind: "human-test", resume_state: "waiting_for_review", target: :pull_request)
    assert_equal [[:pr, 164, "Test this PR"]], @github.comments
    @human_channel.wait(task: @task, body: "@reporter please test", outcome: outcome,
      kind: "human-test", resume_state: "waiting_for_review")
    assert_equal [:issue, 160, "@reporter please test"], @github.comments.last
  end

  def test_deleted_reporter_does_not_prevent_issue_test_request
    def @github.issue(number) = {"number" => number, "state" => "OPEN", "author" => nil}
    outcome = OpenStruct.new(signature: "reviewer")
    @human_channel.wait(task: @task, body: "Test build: https://example.com/build", outcome: outcome,
      kind: "human-test", resume_state: "waiting_for_review", target: :pull_request)
    assert_equal [[:issue, 160, "Test build: https://example.com/build"]], @github.comments
    assert_equal 160, @task.metadata["human_conversation_number"]
  end

  def test_existing_issue_waits_still_detect_replies_on_the_issue
    @task.human_marker = "old-marker"
    assert @human_channel.reply_received?(@task)
    assert_equal [160], @github.lookups
  end

  def test_non_blocking_review_comments_schedule_another_review
    create_pr
    @task.pr_number = 164
    triage = Object.new
    def triage.request! = nil
    reviewer = Ghwatch::Actions::Reviewer.new(**action_options.merge(issue_triage: triage))
    reviewer.send(:apply_result, @task, @github.pr, OpenStruct.new(
      data: {"status" => "comment", "body" => "Wait for CI completion"}, signature: "reviewer"
    ))
    assert_equal "waiting_for_review", @task.state
    assert @task.retry_at
    refute @task.retry_due?
  end

  def test_existing_review_wait_without_retry_is_recovered
    create_pr
    @task.pr_number = 164
    @task.state = "waiting_for_review"
    @task.last_review_signature = "review"
    @task.last_pr_signature = "pr"
    @engine.reconcile_all
    assert @task.retry_at
    refute @task.retry_due?
    @engine.run_due
    assert_empty @reviewer.calls
  end

  def test_ci_completion_wakes_pending_review_without_invalidating_accepted_review
    github = Ghwatch::Github.new(project: nil, command: nil)
    before = {"state" => "OPEN", "headRefOid" => "same", "statusCheckRollup" => [
      {"status" => "IN_PROGRESS", "conclusion" => ""}
    ]}
    after = before.merge("statusCheckRollup" => [{"status" => "COMPLETED", "conclusion" => "SUCCESS"}])
    @task.last_review_signature = github.review_signature(before)
    @task.last_pr_signature = github.pr_signature(before)
    snapshot = Ghwatch::TaskSnapshot.new(
      issue: nil, pull_request: after, issue_signature: nil,
      pull_request_signature: github.pr_signature(after), review_signature: github.review_signature(after)
    )
    @task.state = "waiting_for_review"
    @task.schedule_retry(after: 3600)
    @engine.send(:schedule_review_when_needed, @task, snapshot)
    assert @task.retry_due?

    @task.state = "ready_to_merge"
    @task.schedule_retry(after: 3600)
    retry_at = @task.retry_at
    @engine.send(:schedule_review_when_needed, @task, snapshot)
    assert_equal "ready_to_merge", @task.state
    assert_equal retry_at, @task.retry_at
  end
end
