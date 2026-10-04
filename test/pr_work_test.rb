# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

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
end
