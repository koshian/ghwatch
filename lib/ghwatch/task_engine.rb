# frozen_string_literal: true

module Ghwatch
  class TaskEngine
    MAX_ACTIONS_PER_TASK = 6
    # Between actions, everything is looked at again when this much time has
    # passed, so a reply on one task is not stuck behind a backlog of others.
    RECONCILE_INTERVAL = 60

    def initialize(state:, github:, human_channel:, worker_action:, reviewer_action:, finalizer_action:, config:,
      worktrees: nil, log: Log.new, machine: nil, observer: nil)
      @state = state
      @github = github
      @human_channel = human_channel
      @worker_action = worker_action
      @reviewer_action = reviewer_action
      @finalizer_action = finalizer_action
      @config = config
      @worktrees = worktrees
      @log = log
      @machine = machine || StateMachine.new(github: github, config: config, worktrees: worktrees, log: log)
      @observer = observer || Observer.new(github: github, config: config)
    end

    def reconcile_all
      @reconciled_at = Time.now
      active_tasks.each { |task| reconcile(task) }
    end

    def audit_review_workspaces(trigger:)
      active_tasks.each do |task|
        @state.save_task(task) if @worktrees&.record_workspace_changes(task, trigger: trigger)
      rescue => e
        @log.warn("[#{task.id}] could not check the review workspace: #{e.message}")
      end
    end

    def next_retry_at
      active_tasks.reject(&:waiting_for_human?).filter_map(&:retry_at).min
    end

    def run_due(stop_requested: -> { false }, scope: :all)
      raise ArgumentError, "unknown task scope #{scope.inspect}" unless %i[all pull_requests issues].include?(scope)

      run_pull_requests(stop_requested: stop_requested) unless scope == :issues
      return if scope == :pull_requests

      ran_issue = false
      active_tasks.reject(&:pr_number).each do |task|
        break if stop_requested.call

        # Work on PRs, and replies that arrived meanwhile, goes before the
        # next issue.
        run_pull_requests(stop_requested: stop_requested, after_other_work: ran_issue) unless scope == :issues
        break if stop_requested.call
        next if task.pr_number || task.done?

        run_task_safely(task, stop_requested: stop_requested)
        ran_issue = true
      end
    end

    private

    def run_pull_requests(stop_requested:, after_other_work: false)
      processed = []
      until stop_requested.call
        if (processed.any? || after_other_work) && (@reconciled_at.nil? || Time.now - @reconciled_at >= RECONCILE_INTERVAL)
          reconcile_all
        end
        task = active_tasks.select { |candidate| candidate.pr_number && !processed.include?(candidate.id) && action_due?(candidate) }
          .min_by(&:pr_number)
        break unless task

        processed << task.id
        run_task_safely(task, stop_requested: stop_requested)
      end
    end

    def run_task_safely(task, stop_requested:)
      run_task(task, stop_requested: stop_requested)
    rescue => e
      @log.error("task #{task.id} action failed: #{e.class}: #{e.message}")
      task.last_error = e.message
      task.schedule_retry(after: @config.retry_after)
      @state.save_task(task)
    end

    def run_task(task, stop_requested:)
      limit = task.pr_number ? MAX_ACTIONS_PER_TASK : 1
      limit.times do
        return if stop_requested.call || task.done? || !action_due?(task)

        # What happened since the last look decides first; it may make the
        # action unnecessary or a different one.
        reconcile(task) if task.pr_number || task.review_state? || task.state == "finalizing"
        return if task.done? || !action_due?(task)

        previous_state = task.state
        # The action's result schedules the next run; start from nothing so
        # an action that schedules nothing is caught below.
        task.retry_at = nil
        case task.state
        when "implementing", "changes_requested", "continuing"
          @worker_action.run(task)
        when "waiting_for_review"
          @reviewer_action.run(task)
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
        # A task that asked to run again now (e.g. after updating the PR
        # branch) continues here, before other work.
        return if task.state == previous_state && !task.retry_due?
      end

      if limit > 1 && !task.done? && action_due?(task)
        task.schedule_retry(after: @config.retry_after)
        @state.save_task(task)
      end
    end

    def active_tasks
      @state.tasks.reject(&:done?)
    end

    def reconcile(task)
      snapshot = TaskSnapshot.capture(task: task, github: @github)
      @machine.react(task, @observer.events(task, snapshot))
      release_for_human_wait(task) if task.waiting_for_human?
      # A review wait with nothing scheduled would never be looked at again;
      # the reviewer itself skips a head it has already reviewed.
      task.schedule_retry(after: @config.retry_after) if task.state == "waiting_for_review" && task.retry_at.nil?
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

    # Pushes and comments made by the action itself are not news.
    def observe_own_work(task)
      return if task.done?

      @observer.record(task, TaskSnapshot.capture(task: task, github: @github))
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
      return false if task.waiting_for_human?
      return true if task.retry_at.nil? && %w[implementing changes_requested continuing finalizing].include?(task.state)

      task.retry_due?
    end
  end
end
