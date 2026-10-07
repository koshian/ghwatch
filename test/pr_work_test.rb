# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"
require "minitest/mock"

class PrWorkTest < Minitest::Test
  class Github < Ghwatch::Github
    attr_reader :prs

    def initialize(prs)
      super(project: nil, command: nil)
      @prs = prs.to_h { |pr| [pr.fetch("number"), pr] }
    end

    def pull_request(number) = prs.fetch(number)

    def issue(number) = {"number" => number, "state" => "OPEN"}
  end

  class State
    attr_reader :tasks

    def initialize(tasks) = @tasks = tasks

    def save_task(task) = task
  end

  class Action
    def initialize(&block) = @block = block

    def run(task) = @block.call(task)

    def attempt_merge(task) = @block.call(task)
  end

  def pr(number, mergeable: "MERGEABLE")
    {"number" => number, "state" => "OPEN", "mergeable" => mergeable, "headRefOid" => "head-#{number}", "isDraft" => false}
  end

  def engine(tasks, github:, worker:, reviewer: nil, finalizer: nil)
    Ghwatch::TaskEngine.new(
      state: State.new(tasks), github: github, worker_action: worker,
      reviewer_action: reviewer, finalizer_action: finalizer,
      human_channel: OpenStruct.new(reply_received?: false),
      config: OpenStruct.new(retry_after: 60), log: Ghwatch::Log.new(StringIO.new)
    )
  end

  def test_failed_checks_end_a_human_wait_or_a_merge_wait_once_per_head
    waiting = Ghwatch::Task.for_issue(227, branch: "b", worktree: nil)
    waiting.pr_number = 231
    waiting.state = "waiting_for_human_input"
    waiting.human_marker = "marker"
    waiting.metadata["resume_state"] = "waiting_for_review"
    waiting.metadata["human_conversation_number"] = 231
    merging = Ghwatch::Task.for_issue(228, branch: "c", worktree: nil)
    merging.pr_number = 232
    merging.state = "ready_to_merge"
    external = Ghwatch::Task.for_pr(233)
    external.state = "ready_to_merge"
    failing = [{"name" => "Linux", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
      {"name" => "macOS ARM64", "status" => "COMPLETED", "conclusion" => "FAILURE"}]
    github = Github.new([pr(231), pr(232), pr(233)])
    github.prs.each_value { |item| item["statusCheckRollup"] = failing }
    machine = Ghwatch::TaskEngine.new(
      state: State.new([waiting, merging, external]), github: github, worker_action: nil,
      reviewer_action: nil, finalizer_action: nil,
      human_channel: OpenStruct.new(reply_received?: false),
      config: OpenStruct.new(retry_after: 60, reviewer_requires_green_checks?: true), log: Ghwatch::Log.new(StringIO.new)
    )
    machine.reconcile_all
    assert_equal "changes_requested", waiting.state
    assert_nil waiting.human_marker
    assert_includes waiting.metadata["rework_reason"], "macOS ARM64"
    assert_equal "changes_requested", merging.state
    refute_equal "changes_requested", external.state, "an external PR has no worker to return to"

    # The worker could not push a fix and a person is asked again: not repeated for the same head.
    waiting.state = "waiting_for_human_input"
    waiting.metadata["resume_state"] = "waiting_for_review"
    machine.reconcile_all
    assert_equal "waiting_for_human_input", waiting.state
  end

  def test_a_merged_pr_does_not_restart_finalizing_or_its_human_wait
    task = Ghwatch::Task.for_issue(138, branch: "b", worktree: nil)
    task.pr_number = 175
    task.state = "waiting_for_human_test"
    task.human_marker = "marker"
    task.metadata["resume_state"] = "finalizing"
    task.metadata["human_conversation_number"] = 138
    merged = pr(175).merge("state" => "MERGED", "mergedAt" => "2026-10-06T01:22:19Z")
    machine = engine([task], github: Github.new([merged]), worker: nil)
    machine.reconcile_all
    assert_equal "waiting_for_human_test", task.state

    task.state = "finalizing"
    task.metadata.delete("resume_state")
    task.retry_at = Time.now.to_i + 600
    machine.reconcile_all
    refute task.retry_due?
  end

  def test_a_pr_asking_to_run_again_now_is_reviewed_before_other_prs
    updated = Ghwatch::Task.for_pr(172)
    updated.state = "waiting_for_review"
    updated.retry_at = 0
    other = Ghwatch::Task.for_pr(200)
    other.state = "waiting_for_review"
    other.retry_at = 0
    events = []
    reviewer = Action.new do |task|
      if task.pr_number == 172 && !task.metadata["branch_updated_from"]
        events << [:update_branch, 172]
        task.metadata["branch_updated_from"] = "old"
        task.retry_at = Time.now.to_i
      else
        events << [:review, task.pr_number]
        task.transition_to("done")
      end
    end
    machine = engine([other, updated], github: Github.new([pr(172), pr(200)]), worker: nil, reviewer: reviewer)
    machine.run_due(scope: :pull_requests)
    assert_equal [[:update_branch, 172], [:review, 172], [:review, 200]], events
  end

  def test_conflicting_human_test_wait_returns_to_worker_and_finishes_before_newer_prs
    older = Ghwatch::Task.for_pr(164)
    older.state = "waiting_for_human_test"
    older.human_marker = "marker"
    older.metadata["resume_state"] = "waiting_for_review"
    older.metadata["human_conversation_number"] = 164
    newer = Ghwatch::Task.for_pr(170)
    newer.retry_at = 0
    github = Github.new([pr(164, mergeable: "CONFLICTING"), pr(170)])
    events = []
    worker = Action.new do |task|
      events << [:worker, task.pr_number]
      github.prs[task.pr_number]["mergeable"] = "MERGEABLE"
      task.transition_to("waiting_for_review", retry_at: 0)
    end
    reviewer = Action.new do |task|
      if task.state == "ready_to_merge"
        events << [:merge, task.pr_number]
        task.transition_to("done")
      else
        events << [:review, task.pr_number]
        task.transition_to("ready_to_merge", retry_at: 0)
      end
    end
    machine = engine([newer, older], github: github, worker: worker, reviewer: reviewer)
    machine.reconcile_all
    assert_equal "changes_requested", older.state
    assert_nil older.human_marker
    refute older.metadata.key?("human_conversation_number")
    machine.run_due(scope: :pull_requests)
    assert_equal [[:worker, 164], [:review, 164], [:merge, 164], [:review, 170], [:merge, 170]], events
    assert older.done?
    assert newer.done?
  end

  def test_retry_becoming_due_during_another_pr_runs_before_newer_prs_and_issues
    now = Time.at(1_000)
    older = Ghwatch::Task.for_pr(164)
    older.state = "changes_requested"
    older.retry_at = 1_010
    current = Ghwatch::Task.for_pr(174)
    current.retry_at = 0
    newer = Ghwatch::Task.for_pr(175)
    newer.retry_at = 0
    issue = Ghwatch::Task.for_issue(71, branch: "issue-71", worktree: nil)
    events = []
    action = Action.new do |task|
      events << (task.pr_number || :issue)
      now = Time.at(1_020) if task.pr_number == 174
      task.transition_to("done")
    end
    machine = engine([issue, newer, older, current], github: Github.new([pr(164), pr(174), pr(175)]), worker: action, reviewer: action)
    Time.stub(:now, -> { now }) { machine.run_due }
    assert_equal [174, 164, 175, :issue], events
    assert older.done?
  end

  def test_only_waiting_prs_allow_issue_work_without_starting_pr_actions
    human_wait = Ghwatch::Task.for_pr(164)
    human_wait.state = "waiting_for_human_test"
    ci_wait = Ghwatch::Task.for_pr(170)
    ci_wait.state = "ready_to_merge"
    ci_wait.retry_at = Time.now.to_i + 3_600
    retry_wait = Ghwatch::Task.for_pr(174)
    retry_wait.state = "changes_requested"
    retry_wait.retry_at = Time.now.to_i + 3_600
    issue = Ghwatch::Task.for_issue(71, branch: "issue-71", worktree: nil)
    events = []
    action = Action.new { |task| events << task.id }
    machine = engine([human_wait, ci_wait, retry_wait, issue], github: nil, worker: action, reviewer: action)
    machine.run_due
    assert_equal ["issue-71"], events
  end

  def test_scheduler_drains_retries_before_triage_and_checks_again_before_issue_work
    now = Time.at(1_000)
    older = Ghwatch::Task.for_pr(164)
    older.state = "changes_requested"
    older.retry_at = 1_010
    after_triage = Ghwatch::Task.for_pr(170)
    after_triage.state = "changes_requested"
    after_triage.retry_at = 1_030
    current = Ghwatch::Task.for_pr(174)
    current.retry_at = 0
    issue = Ghwatch::Task.for_issue(71, branch: "issue-71", worktree: nil)
    events = []
    action = Action.new do |task|
      events << (task.pr_number || :issue)
      now = Time.at(1_020) if task.pr_number == 174
      task.transition_to("done")
    end
    machine = engine([older, after_triage, current, issue], github: Github.new([pr(164), pr(170), pr(174)]), worker: action, reviewer: action)
    # Keep the initial reconciliation from waking reviews: this test exercises scheduling.
    machine.define_singleton_method(:reconcile_all) {}
    intake = Object.new
    intake.define_singleton_method(:discover) {}
    triage = Object.new
    triage.define_singleton_method(:request_if_watched_issue_changed) {}
    triage.define_singleton_method(:due?) { true }
    triage.define_singleton_method(:run) do
      events << :triage
      now = Time.at(1_040)
    end
    scheduler = Ghwatch::Scheduler.new(
      task_engine: machine, review_intake: intake, issue_triage: triage,
      config: OpenStruct.new(reload_if_changed!: false), github: nil
    )
    Time.stub(:now, -> { now }) { scheduler.cycle }
    assert_equal [174, 164, :triage, 170, :issue], events
  end

  def test_unknown_draft_and_actual_human_input_waits_do_not_trigger_conflict_rework
    %w[UNKNOWN CONFLICTING].each do |mergeable|
      task = Ghwatch::Task.for_pr(164)
      task.state = "waiting_for_human_input"
      machine = engine([task], github: Github.new([pr(164, mergeable: mergeable)]), worker: nil)
      machine.reconcile_all
      assert_equal "waiting_for_human_input", task.state
    end
    task = Ghwatch::Task.for_pr(164)
    task.state = "waiting_for_human_test"
    github = Github.new([pr(164, mergeable: "UNKNOWN")])
    machine = engine([task], github: github, worker: nil)
    machine.reconcile_all
    assert_equal "waiting_for_human_test", task.state
    github.prs[164]["mergeable"] = "CONFLICTING"
    github.prs[164]["isDraft"] = true
    machine.reconcile_all
    assert_equal "waiting_for_human_test", task.state
  end

  def test_conflict_repair_failure_retains_retry_delay
    task = Ghwatch::Task.for_pr(164)
    task.state = "changes_requested"
    github = Github.new([pr(164, mergeable: "CONFLICTING")])
    calls = 0
    worker = Action.new { |item|
      calls += 1
      raise "repair failed"
    }
    machine = engine([task], github: github, worker: worker)
    machine.run_due(scope: :pull_requests)
    retry_at = task.retry_at
    machine.reconcile_all
    machine.run_due(scope: :pull_requests)
    assert_equal 1, calls
    assert_equal retry_at, task.retry_at
    assert_equal "changes_requested", task.state
  end

  def test_repeated_review_rework_cycles_are_bounded_and_persist_a_retry
    task = Ghwatch::Task.for_pr(164)
    task.retry_at = 0
    calls = 0
    worker = Action.new { |item|
      calls += 1
      item.transition_to("waiting_for_review", retry_at: 0)
    }
    reviewer = Action.new { |item|
      calls += 1
      item.transition_to("changes_requested", retry_at: 0)
    }
    machine = engine([task], github: Github.new([pr(164)]), worker: worker, reviewer: reviewer)
    machine.run_due(scope: :pull_requests)
    assert_equal Ghwatch::TaskEngine::MAX_ACTIONS_PER_TASK, calls
    assert task.retry_at
    refute task.retry_due?
  end

  def test_unchanged_state_runs_once_and_merges_can_continue_to_finalization
    task = Ghwatch::Task.for_pr(164)
    task.retry_at = 0
    calls = 0
    action = Action.new { |item| calls += 1 }
    machine = engine([task], github: Github.new([pr(164)]), worker: nil, reviewer: action)
    machine.run_due(scope: :pull_requests)
    assert_equal 1, calls
    task.state = "ready_to_merge"
    task.retry_at = 0
    action = Action.new { |item| item.transition_to("finalizing", retry_at: 0) }
    finalizer = Action.new { |item| item.transition_to("done") }
    machine = engine([task], github: Github.new([pr(164)]), worker: nil, reviewer: action, finalizer: finalizer)
    machine.run_due(scope: :pull_requests)
    assert task.done?
  end

  def test_new_pr_reply_resumes_review_despite_worker_retry_and_is_not_replayed
    task = Ghwatch::Task.for_pr(167)
    task.state = "changes_requested"
    task.last_error = "protocol: agent did not emit a ghwatch result"
    task.retry_at = Time.now.to_i + 3_600
    pull_request = pr(167).merge("comments" => [
      {"id" => 1, "body" => "old human reply"},
      {"id" => 2, "body" => "Prepare environment <!-- ghwatch:changes-requested:marker -->"},
      {"id" => 3, "body" => "Please review again"}
    ])
    github = Github.new([pull_request])
    reviews = 0
    reviewer = Action.new do |item|
      reviews += 1
      item.transition_to("changes_requested", retry_at: Time.now.to_i + 60)
    end
    machine = engine([task], github: github, worker: nil, reviewer: reviewer)
    machine.reconcile_all
    assert_equal "waiting_for_review", task.state
    assert_nil task.last_error
    assert task.retry_due?
    machine.run_due
    assert_equal 1, reviews
    assert_equal 3, task.metadata["last_rework_reply_id"]
    machine.reconcile_all
    assert_equal "changes_requested", task.state
    refute task.retry_due?
  end

  def test_old_or_ghwatch_comments_and_conflicts_do_not_interrupt_rework
    task = Ghwatch::Task.for_pr(167)
    task.state = "changes_requested"
    task.retry_at = Time.now.to_i + 3_600
    pull_request = pr(167).merge("comments" => [
      {"id" => 1, "body" => "old human reply"},
      {"id" => 2, "body" => "Fix code <!-- ghwatch:changes-requested:marker -->"},
      {"id" => 3, "body" => "Automated feedback <!-- ghwatch:review-comment:marker -->"}
    ])
    machine = engine([task], github: Github.new([pull_request]), worker: nil)
    machine.reconcile_all
    assert_equal "changes_requested", task.state
    pull_request["comments"] << {"id" => 4, "body" => "review again"}
    pull_request["mergeable"] = "CONFLICTING"
    machine.reconcile_all
    assert_equal "changes_requested", task.state
    refute task.retry_due?
  end

  def test_reconcile_releases_workspaces_only_for_human_waits_and_tolerates_failures
    waiting = Ghwatch::Task.for_pr(164)
    waiting.state = "waiting_for_human_test"
    waiting.human_marker = "marker"
    reviewing = Ghwatch::Task.for_pr(170)
    released = []
    worktrees = Object.new
    worktrees.define_singleton_method(:release_for_human_wait) do |task|
      released << task.id
      raise "review workspace has tracked changes"
    end
    log = StringIO.new
    machine = Ghwatch::TaskEngine.new(
      state: State.new([waiting, reviewing]), github: Github.new([pr(164), pr(170)]),
      worker_action: nil, reviewer_action: nil, finalizer_action: nil,
      human_channel: Object.new.tap { |channel| def channel.reply_received?(task) = false },
      config: OpenStruct.new(retry_after: 60), worktrees: worktrees, log: Ghwatch::Log.new(log)
    )
    machine.reconcile_all
    assert_equal ["pr-164"], released
    assert_equal "waiting_for_human_test", waiting.state
    assert_nil waiting.last_error
    assert_includes log.string, "could not release workspaces"
  end

  def test_next_retry_excludes_human_waits_and_completed_tasks
    waiting = Ghwatch::Task.for_pr(164)
    waiting.state = "waiting_for_human_input"
    waiting.retry_at = 1
    done = Ghwatch::Task.for_pr(166)
    done.state = "done"
    done.retry_at = 2
    ready = Ghwatch::Task.for_pr(167)
    ready.retry_at = 1_100
    machine = engine([waiting, done, ready], github: nil, worker: nil)
    assert_equal 1_100, machine.next_retry_at
  end
end
