# frozen_string_literal: true

module Ghwatch
  class TaskEngine
    MAX_ACTIONS_PER_TASK = 6
    # Between actions, everything is looked at again when this much time has
    # passed, so a reply on one task is not stuck behind a backlog of others.
    RECONCILE_INTERVAL = 60
    # With parallel_review, each lane runs its own tasks' actions on a thread
    # of its own; without it, one loop runs them all.
    LANES = {
      worker: Task::WORKER_STATES,
      review: %w[waiting_for_review checking_test_result ready_to_merge finalizing]
    }.freeze

    def initialize(state:, github:, human_channel:, worker_action:, reviewer_action:, finalizer_action:, config:,
      worktrees: nil, log: Log.new, machine: nil, observer: nil, locks: TaskLocks.new)
      @state = state
      @github = github
      @human_channel = human_channel
      @worker_action = worker_action
      @reviewer_action = reviewer_action
      @finalizer_action = finalizer_action
      @config = config
      @worktrees = worktrees
      @log = log
      @machine = machine || StateMachine.new(github: github, config: config, worktrees: worktrees,
        human_channel: human_channel.respond_to?(:wait) ? human_channel : nil, log: log)
      @observer = observer || Observer.new(github: github, config: config)
      @locks = locks
    end

    def reconcile_all
      @reconciled_at = Time.now
      active_tasks.each { |task| reconcile(task) }
    end

    def audit_review_workspaces(trigger:)
      active_tasks.each do |task|
        # A review that ghwatch did not see finish left the task worktree as
        # it was at that moment.
        shared = task.metadata.key?("shared_review")
        @worktrees&.end_shared_review(task, trigger: trigger) if shared
        changed = @worktrees&.record_workspace_changes(task, trigger: trigger)
        @state.save_task(task) if shared || changed
      rescue => e
        @log.warn("[#{task.id}] could not check the review workspace: #{e.message}")
      end
    end

    def next_retry_at(lane: nil)
      active_tasks.select { |task| in_lane?(task, lane) }.reject(&:waiting_for_human?).filter_map(&:retry_at).min
    end

    # When each task not waiting for a person is looked at next, as [time,
    # what] pairs, soonest first: a retry or a check by its state, a test
    # build by the watcher's next look.
    def upcoming
      active_tasks.reject(&:waiting_for_human?).filter_map do |task|
        if (check_at = task.metadata.dig("test_build", "check_at"))
          [check_at.to_i, "#{task.id} test build"]
        elsif task.retry_at
          [task.retry_at, "#{task.id} #{task.state.tr("_", " ")}"]
        end
      end.sort
    end

    def due?(lane: nil)
      active_tasks.any? { |task| in_lane?(task, lane) && action_due?(task) }
    end

    # Runs agent work one action at a time, choosing again before every
    # action: the oldest task that can run now goes first, whatever kind of
    # work it needs, so older work is finished before newer work is touched.
    # Age is the number of the issue a task came from (the PR's for an
    # external PR); GitHub numbers issues and PRs in one sequence.
    # look_again runs with each of those looks, for what else GitHub may
    # have (new PRs). A lane runs only its own tasks and leaves the looks to
    # the scheduler. Returns how many actions ran.
    def run_due(stop_requested: -> { false }, scope: :all, look_again: -> {}, lane: nil)
      raise ArgumentError, "unknown task scope #{scope.inspect}" unless %i[all pull_requests issues].include?(scope)
      raise ArgumentError, "unknown lane #{lane.inspect}" unless lane.nil? || LANES.key?(lane)

      actions = Hash.new(0)
      until stop_requested.call
        if lane.nil? && actions.any? && (@reconciled_at.nil? || Time.now - @reconciled_at >= RECONCILE_INTERVAL)
          reconcile_all
          look_again.call
        end
        task = active_tasks.select do |candidate|
          in_scope?(candidate, scope) && in_lane?(candidate, lane) && actions[candidate.id] < MAX_ACTIONS_PER_TASK && action_due?(candidate)
        end.min_by { |candidate| [age(candidate), candidate.id] }
        break unless task

        actions[task.id] += 1
        run_task_safely(task, lane: lane)
      end
      # A task that used up its actions in this call waits for the next poll
      # instead of starting over immediately.
      active_tasks.each do |task|
        next unless actions[task.id] >= MAX_ACTIONS_PER_TASK && action_due?(task)

        task.schedule_retry(after: @config.retry_after)
        @state.save_task(task)
      end
      actions.values.sum
    end

    def self.age(task) = task.issue_number || task.pr_number || Float::INFINITY

    private

    def age(task) = self.class.age(task)

    def in_scope?(task, scope)
      case scope
      when :pull_requests then !task.pr_number.nil?
      when :issues then task.pr_number.nil?
      else true
      end
    end

    def in_lane?(task, lane)
      lane.nil? || LANES.fetch(lane).include?(task.state)
    end

    # Under the task's lock, as the task is now: another thread may have
    # moved it on since it was chosen.
    def run_task_safely(task, lane:)
      @locks.synchronize(task.id) do
        task = @state.task(task.id) || task
        run_task(task) if in_lane?(task, lane)
      end
    rescue => e
      @log.error("task #{task.id} action failed: #{e.class}: #{e.message}")
      task.last_error = e.message
      task.schedule_retry(after: @config.retry_after)
      @state.save_task(task)
    end

    # One action. What happened since the last look decides first; it may
    # make the action unnecessary or a different one.
    def run_task(task)
      reconcile_now(task) if task.pr_number || task.review_state? || task.state == "finalizing"
      return if task.done? || !action_due?(task)

      previous_state = task.state
      # The action's result schedules the next run; start from nothing so an
      # action that schedules nothing is caught below.
      task.retry_at = nil
      case task.state
      when "implementing", "changes_requested", "continuing"
        @worker_action.run(task)
      when "waiting_for_review"
        @reviewer_action.run(task)
      when "checking_test_result"
        @reviewer_action.check_test_result(task)
      when "ready_to_merge"
        @reviewer_action.attempt_merge(task)
      when "finalizing"
        @finalizer_action.run(task)
      end
      if task.state == previous_state && task.retry_at.nil?
        @log.warn("[#{task.id}] #{previous_state} action scheduled nothing; retrying later")
        task.schedule_retry(after: @config.retry_after)
      end
      observe_own_work(task)
    end

    def active_tasks
      @state.tasks.reject(&:done?)
    end

    # A task another thread is acting on is left to it: its action looks at
    # GitHub first anyway.
    def reconcile(task)
      @locks.try(task.id) { reconcile_now(@state.task(task.id) || task) }
    end

    def reconcile_now(task)
      snapshot = TaskSnapshot.capture(task: task, github: @github)
      mark_review_only(task, snapshot.pull_request)
      @machine.react(task, @observer.events(task, snapshot))
      release_for_human_wait(task) if task.waiting_for_human?
      # A review wait with nothing scheduled would never be looked at again;
      # the reviewer itself skips a head it has already reviewed.
      if %w[waiting_for_review checking_test_result].include?(task.state) && task.retry_at.nil?
        task.schedule_retry(after: @config.retry_after)
      end
      @observer.record(task, snapshot)
      task.last_issue_signature = snapshot.issue_signature
      task.last_pr_signature = snapshot.pull_request_signature
      @state.save_task(task)
    rescue => e
      @log.error("task #{task.id} reconciliation failed: #{e.class}: #{e.message}")
      task.last_error = e.message
      task.schedule_retry(after: @config.retry_after)
      @state.save_task(task)
    end

    # A PR ghwatch did not open is only reviewed when someone else wrote it:
    # their branch is theirs to change. ghwatch's own account may have opened
    # it by hand, and then the worker reworks it as usual.
    def mark_review_only(task, pull_request)
      return unless task.metadata["external_pr"] && !task.metadata.key?("review_only")

      author = pull_request&.dig("author", "login")
      task.metadata["review_only"] = author != @github.viewer_login if author
    end

    # Pushes and comments made by the action itself are not news.
    def observe_own_work(task)
      return if task.done?

      @observer.record(task, TaskSnapshot.capture(task: task, github: @github), own_work: true)
      @state.save_task(task)
    rescue => e
      @log.warn("[#{task.id}] could not record the state after the action: #{e.message}")
    end

    def release_for_human_wait(task)
      @worktrees&.release_for_human_wait(task)
    rescue => e
      @log.warn("[#{task.id}] could not release workspaces during human wait: #{e.message}")
    end

    def action_due?(task)
      return false if task.waiting_for_human? || task.state == TestBuildWatcher::STATE
      return true if task.retry_at.nil? && %w[implementing changes_requested continuing finalizing].include?(task.state)

      task.retry_due?
    end
  end
end
