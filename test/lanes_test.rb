# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

# With parallel_review, reviews run on a lane of their own while the worker
# runs, and the look at GitHub leaves alone a task another thread acts on.
class LanesTest < Minitest::Test
  class State
    attr_reader :tasks

    def initialize(tasks) = @tasks = tasks

    def save_task(task) = task

    def task(id) = tasks.find { |task| task.id == id }
  end

  class Github
    def issue(number) = {"number" => number, "state" => "OPEN", "comments" => []}

    def issue_signature(issue) = "issue"

    def pull_request(number) = {"number" => number, "state" => "OPEN", "headRefOid" => "head", "comments" => []}

    def pr_signature(pr) = "pr"

    def review_signature(pr) = "review"

    def pull_request_for_branch(branch, since: nil) = nil
  end

  def setup
    @issue = Ghwatch::Task.for_issue(1, branch: "issue-1", worktree: nil)
    @review = Ghwatch::Task.for_issue(2, branch: "issue-2", worktree: nil)
    @review.pr_number = 20
    @review.state = "waiting_for_review"
    @review.retry_at = Time.now.to_i
    @events = Queue.new
    @release = Queue.new
    events = @events
    release = @release
    worker = Object.new
    worker.define_singleton_method(:run) do |task|
      events << [:worker_started, task.id]
      release.pop
      task.transition_to("waiting_for_human_input")
    end
    reviewer = Object.new
    reviewer.define_singleton_method(:run) do |task|
      events << [:reviewed, task.id]
      task.transition_to("waiting_for_human_test")
    end
    @locks = Ghwatch::TaskLocks.new
    @engine = Ghwatch::TaskEngine.new(
      state: State.new([@issue, @review]), github: Github.new, human_channel: nil, worker_action: worker,
      reviewer_action: reviewer, finalizer_action: nil, config: OpenStruct.new(retry_after: 60),
      log: Ghwatch::Log.new(StringIO.new), locks: @locks
    )
  end

  def test_a_review_runs_while_the_worker_is_busy
    worker = Ghwatch::Lane.new(name: :worker, task_engine: @engine, log: Ghwatch::Log.new(StringIO.new))
    review = Ghwatch::Lane.new(name: :review, task_engine: @engine, log: Ghwatch::Log.new(StringIO.new))
    worker.start
    assert_equal [:worker_started, "issue-1"], @events.pop(timeout: 5)
    assert worker.busy?

    review.start
    assert_equal [:reviewed, "issue-2"], @events.pop(timeout: 5), "the review does not wait for the worker"
    assert_equal "waiting_for_human_test", @review.state

    @release << true
    [worker, review].each(&:stop)
    [worker, review].each(&:join)
    assert_equal "waiting_for_human_input", @issue.state
  end

  def test_each_lane_runs_only_its_own_states
    assert_equal 1, @engine.run_due(lane: :review)
    assert_equal [:reviewed, "issue-2"], @events.pop(timeout: 1)
    assert_equal "implementing", @issue.state
    refute @engine.due?(lane: :review)
    assert @engine.due?(lane: :worker)
  end

  def test_looking_at_github_leaves_a_task_another_thread_acts_on
    held = Queue.new
    done = Queue.new
    holder = Thread.new do
      @locks.synchronize(@review.id) do
        held << true
        done.pop
      end
    end
    held.pop
    looked_at = []
    capture = ->(task:, github:) do
      looked_at << task.id
      raise "stop here"
    end
    Ghwatch::TaskSnapshot.stub(:capture, capture) { @engine.reconcile_all }
    done << true
    holder.join
    assert_equal ["issue-1"], looked_at
  end

  def test_the_scheduler_looks_at_github_while_the_lanes_run_and_waits_for_them_to_stop
    looks = Queue.new
    engine = Object.new
    engine.define_singleton_method(:audit_review_workspaces) { |trigger:| nil }
    engine.define_singleton_method(:reconcile_all) { looks << :reconcile }
    engine.define_singleton_method(:run_due) { |**options| 0 }
    engine.define_singleton_method(:due?) { |lane:| false }
    engine.define_singleton_method(:next_retry_at) { |lane: nil| nil }
    intake = Object.new
    intake.define_singleton_method(:discover) {}
    triage = Object.new
    triage.define_singleton_method(:run) { looks << :triage }
    config = OpenStruct.new(parallel_review?: true, poll_interval: 60, reload_if_changed!: false)
    scheduler = Ghwatch::Scheduler.new(task_engine: engine, review_intake: intake, issue_triage: triage, config: config,
      github: OpenStruct.new(repo_name: "o/r"), log: Ghwatch::Log.new(StringIO.new))
    scheduler.define_singleton_method(:trap_signals) {}
    runner = Thread.new { scheduler.run }
    assert_equal [:reconcile, :triage].sort, [looks.pop(timeout: 5), looks.pop(timeout: 5)].sort

    scheduler.instance_variable_set(:@running, false)
    scheduler.instance_variable_get(:@wakeup_writer).write(".")
    assert runner.join(5), "the scheduler stops once the lanes have"
  end

  def test_the_looks_while_agents_run_check_every_label_once_a_poll
    engine = Object.new
    engine.define_singleton_method(:reconcile_all) {}
    intake = Object.new
    intake.define_singleton_method(:discover) {}
    labels = Object.new
    syncs = []
    labels.define_singleton_method(:sync_all) { syncs << :all }
    config = OpenStruct.new(poll_interval: 600, reload_if_changed!: false)
    scheduler = Ghwatch::Scheduler.new(task_engine: engine, review_intake: intake, issue_triage: nil, config: config,
      github: nil, status_labels: labels, log: Ghwatch::Log.new(StringIO.new))
    3.times { scheduler.send(:look_at_github) }
    assert_equal 1, syncs.size

    scheduler.instance_variable_set(:@labels_synced_at, Time.now - 600)
    scheduler.send(:look_at_github)
    assert_equal 2, syncs.size
  end
end
