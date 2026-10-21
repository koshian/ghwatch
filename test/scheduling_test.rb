# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "minitest/mock"
require "stringio"

class SchedulingTest < Minitest::Test
  def test_cycle_looks_for_issues_once_everything_that_could_run_has_run
    engine = Minitest::Mock.new
    intake = Minitest::Mock.new
    triage = Minitest::Mock.new
    events = []
    engine.expect(:reconcile_all, nil) { events << :reconcile }
    intake.expect(:discover, nil) { events << :discover }
    engine.expect(:run_due, nil) { |**options|
      events << options.fetch(:scope)
      true
    }
    triage.expect(:run, nil) { events << :triage }
    scheduler = Ghwatch::Scheduler.new(
      task_engine: engine, review_intake: intake, issue_triage: triage,
      config: OpenStruct.new(reload_if_changed!: false), github: nil
    )
    scheduler.cycle
    assert_equal %i[reconcile discover all triage], events
    [engine, intake, triage].each(&:verify)
  end

  def test_existing_pr_rework_runs_before_issue_work_and_waits_do_not_block_issues
    issue = Ghwatch::Task.for_issue(1, branch: "issue-1", worktree: nil)
    rework = Ghwatch::Task.for_issue(2, branch: "issue-2", worktree: nil)
    rework.pr_number = 20
    rework.state = "changes_requested"
    waiting = Ghwatch::Task.for_pr(30)
    waiting.state = "waiting_for_human_test"
    later = Ghwatch::Task.for_pr(40)
    later.retry_at = Time.now.to_i + 3600
    worker = Minitest::Mock.new
    events = []
    worker.expect(:run, nil) { |task|
      events << :rework
      task.equal?(rework)
    }
    worker.expect(:run, nil) { |task|
      events << :issue
      task.equal?(issue)
    }
    github = Object.new
    def github.issue(number) = {"number" => number, "state" => "OPEN", "comments" => []}
    def github.issue_signature(issue) = "issue"
    def github.pull_request(number) = {"number" => number, "state" => "OPEN", "headRefOid" => "head", "comments" => []}
    def github.pr_signature(pr) = "pr"
    def github.pull_request_for_branch(branch, since: nil) = nil
    def github.review_signature(pr) = "review"
    engine = Ghwatch::TaskEngine.new(
      state: Struct.new(:tasks) { def save_task(task) = task }.new([issue, waiting, rework, later]), github: github,
      human_channel: nil, worker_action: worker, reviewer_action: nil,
      finalizer_action: nil, config: OpenStruct.new(retry_after: 60), log: Ghwatch::Log.new(StringIO.new)
    )
    engine.run_due
    assert_equal %i[rework issue], events
    worker.verify
  end

  def test_new_prs_are_looked_for_with_the_periodic_look_between_actions
    first = Ghwatch::Task.for_issue(1, branch: "issue-1", worktree: nil)
    second = Ghwatch::Task.for_issue(2, branch: "issue-2", worktree: nil)
    events = []
    worker = Object.new
    worker.define_singleton_method(:run) do |task|
      events << task.id
      task.transition_to("waiting_for_human_input")
    end
    github = Object.new
    def github.issue(number) = {"number" => number, "state" => "OPEN", "comments" => []}
    def github.issue_signature(issue) = "issue"
    def github.pull_request_for_branch(branch, since: nil) = nil
    engine = Ghwatch::TaskEngine.new(
      state: Struct.new(:tasks) { def save_task(task) = task }.new([first, second]), github: github,
      human_channel: nil, worker_action: worker, reviewer_action: nil,
      finalizer_action: nil, config: OpenStruct.new(retry_after: 60), log: Ghwatch::Log.new(StringIO.new)
    )
    engine.run_due(look_again: -> { events << :look_again })
    assert_equal ["issue-1", :look_again, "issue-2"], events
  end

  def test_a_new_install_takes_over_between_actions
    update = OpenStruct.new(updated?: false)
    answers = []
    engine = Object.new
    engine.define_singleton_method(:reconcile_all) {}
    engine.define_singleton_method(:run_due) do |stop_requested:, **|
      answers << stop_requested.call
      update[:updated?] = true # installed while the first action ran
      answers << stop_requested.call
    end
    triage = Object.new
    def triage.run = raise("triage must wait for the new ghwatch")
    scheduler = Ghwatch::Scheduler.new(
      task_engine: engine, review_intake: OpenStruct.new(discover: nil), issue_triage: triage,
      config: OpenStruct.new(reload_if_changed!: false), github: nil, log: Ghwatch::Log.new(log = StringIO.new),
      self_update: update
    )
    scheduler.cycle
    assert_equal [false, true], answers, "the next action is not started once a new ghwatch is installed"
    refute_includes log.string, "cycle failed"
  end

  def test_wait_wakes_at_retry_deadline_and_logs_next_check
    [[1_100, 100], [999, 1], [nil, 600]].each do |retry_at, expected|
      log = StringIO.new
      scheduler = Ghwatch::Scheduler.new(
        task_engine: OpenStruct.new(next_retry_at: retry_at), review_intake: nil,
        issue_triage: nil, config: nil, github: nil, log: Ghwatch::Log.new(log)
      )
      observed = nil
      Time.stub(:now, Time.at(1_000)) do
        IO.stub(:select, ->(readers, writers, errors, timeout) { observed = timeout }) do
          scheduler.send(:wait, 600)
        end
      end
      assert_equal expected, observed
      assert_includes log.string, "waiting until"
      assert_includes log.string, "(#{expected}s)"
      scheduler.instance_variable_get(:@wakeup_reader).close
      scheduler.instance_variable_get(:@wakeup_writer).close
    end
  end

  class Recheck
    attr_reader :events

    def initialize = @events = []

    def reconcile_all = @events << :reconcile

    def discover = @events << :discover
  end

  def pausing_scheduler(recheck)
    scheduler = Ghwatch::Scheduler.new(task_engine: recheck, review_intake: recheck, issue_triage: recheck,
      config: OpenStruct.new(poll_interval: 600), github: nil, log: Ghwatch::Log.new(StringIO.new))
    waits = []
    scheduler.define_singleton_method(:wait) { |seconds| waits << seconds }
    [scheduler, waits]
  end

  def test_a_long_cycle_looks_at_github_again_before_waiting
    recheck = Recheck.new
    scheduler, waits = pausing_scheduler(recheck)
    scheduler.send(:pause, Time.now - Ghwatch::Scheduler::RECHECK_AFTER)
    assert_equal %i[reconcile discover], recheck.events
    assert_equal [600], waits, "found work is scheduled to run now, which ends the wait"

    recheck = Recheck.new
    scheduler, waits = pausing_scheduler(recheck)
    scheduler.send(:pause, Time.now)
    assert_empty recheck.events, "a short cycle has just looked"
    assert_equal [600], waits
  end
end
