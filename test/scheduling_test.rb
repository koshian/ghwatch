# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "minitest/mock"
require "stringio"

class SchedulingTest < Minitest::Test
  def test_cycle_processes_prs_before_issue_triage_and_issue_actions
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
    engine.expect(:run_due, nil) { |**options|
      events << options.fetch(:scope)
      true
    }
    triage.expect(:request_if_watched_issue_changed, nil) { events << :watch }
    triage.expect(:due?, true)
    triage.expect(:run, nil) { events << :triage }
    scheduler = Ghwatch::Scheduler.new(
      task_engine: engine, review_intake: intake, issue_triage: triage,
      config: OpenStruct.new(reload_if_changed!: false), github: nil
    )
    scheduler.cycle
    assert_equal %i[reconcile discover pull_requests watch triage all], events
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
    def github.pull_request_for_branch(branch) = nil
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
end
