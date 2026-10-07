# frozen_string_literal: true

module Ghwatch
  class TaskEngine
    MAX_ACTIONS_PER_TASK = 6

    def initialize(state:, github:, human_channel:, worker_action:, reviewer_action:, finalizer_action:, config:, worktrees: nil, log: Log.new)
      @state = state
      @github = github
      @human_channel = human_channel
      @worker_action = worker_action
      @reviewer_action = reviewer_action
      @finalizer_action = finalizer_action
      @config = config
      @worktrees = worktrees
      @log = log
    end

    def reconcile_all
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

      active_tasks.reject(&:pr_number).each do |task|
        break if stop_requested.call

        run_task_safely(task, stop_requested: stop_requested)
      end
    end

    private

    def run_pull_requests(stop_requested:)
      processed = []
      until stop_requested.call
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

        if task.review_state? || task.state == "finalizing"
          snapshot = TaskSnapshot.capture(task: task, github: @github)
          return if recover_without_pull_request(task, snapshot.pull_request)

          task.pr_number = snapshot.pull_request.fetch("number")
          return_conflicting_pr_to_worker(task, snapshot.pull_request)
        end

        previous_state = task.state
        previous_retry_at = task.retry_at
        case task.state
        when "implementing", "changes_requested", "continuing"
          @worker_action.run(task)
        when "waiting_for_review", "waiting_for_re_review"
          @reviewer_action.run(task)
        when "ready_to_merge"
          @reviewer_action.attempt_merge(task)
        when "finalizing"
          @finalizer_action.run(task)
        end
        # An action that keeps the state but asks to run again now (e.g. after
        # updating the PR branch) continues here, before other work.
        @log.info("[#{task.id}] #{previous_state} -> #{task.state}") if task.state != previous_state
        return if task.state == previous_state && (task.retry_at == previous_retry_at || !action_due?(task))
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
      pull_request = snapshot.pull_request

      attach_discovered_pull_request(task, pull_request)
      return if recover_without_pull_request(task, pull_request)
      return if finish_merged_task(task, pull_request)
      return if recover_from_closed_pull_request(task, pull_request)
      return if return_conflicting_pr_to_worker(task, pull_request)
      return if return_failed_checks_to_worker(task, pull_request)

      resume_after_human_reply(task) if task.waiting_for_human? && @human_channel.reply_received?(task)
      release_for_human_wait(task) if task.waiting_for_human?
      resume_review_after_rework_reply(task, pull_request)
      schedule_review_when_needed(task, snapshot)

      task.last_issue_signature = snapshot.issue_signature
      task.last_pr_signature = snapshot.pull_request_signature
      @state.save_task(task)
    rescue => e
      @log.error("task #{task.id} reconciliation failed: #{e.class}: #{e.message}")
      task.last_error = e.message
      task.schedule_retry(after: @config.retry_after)
      @state.save_task(task)
    end

    def attach_discovered_pull_request(task, pull_request)
      return unless pull_request && task.pr_number.nil?

      task.pr_number = pull_request["number"]
      task.state = "waiting_for_review" if task.uses_worker_slot? && !pull_request["isDraft"]
      task.retry_at = Time.now.to_i
    end

    def return_conflicting_pr_to_worker(task, pull_request)
      return false unless pull_request && pull_request["state"] == "OPEN" && pull_request["mergeable"] == "CONFLICTING"
      return false if pull_request["isDraft"] || task.uses_worker_slot? || task.state == "waiting_for_human_input"
      return false if task.last_error && task.retry_at && !task.retry_due?

      @log.info("[#{task.id}] PR ##{task.pr_number} conflicts with its base; returning to worker")
      task.human_marker = nil
      task.metadata.delete("human_conversation_number")
      task.metadata.delete("resume_state")
      task.metadata["rework_reason"] = "Resolve conflicts with the PR base branch, test, and push updates to the existing PR."
      task.last_review_signature = nil
      task.transition_to("changes_requested", retry_at: Time.now.to_i)
      @state.save_task(task)
      true
    end

    # A PR whose checks fail cannot merge, but a task waiting for a person or
    # for its merge does not look at checks again. Send it back to the worker
    # instead of leaving it waiting for something that cannot unblock it.
    def return_failed_checks_to_worker(task, pull_request)
      return false unless task.issue_number && pull_request && pull_request["state"] == "OPEN"
      return false unless @config.reviewer_requires_green_checks?
      return false unless task.waiting_for_human? || task.state == "ready_to_merge"
      return false if task.metadata["resume_state"] == "finalizing"

      failed = @github.failed_checks(pull_request)
      head = pull_request["headRefOid"]
      return false if failed.empty? || task.metadata["failed_checks_head"] == head

      @log.info("[#{task.id}] PR ##{task.pr_number} checks failed (#{failed.join(", ")}); returning to worker")
      task.human_marker = nil
      task.metadata.delete("human_conversation_number")
      task.metadata.delete("resume_state")
      task.metadata["failed_checks_head"] = head
      task.metadata["rework_reason"] = "Required CI checks failed on #{head}: #{failed.join(", ")}. " \
        "Read their logs, fix the cause, test, and push updates to the existing PR."
      task.last_review_signature = nil
      task.transition_to("changes_requested", retry_at: Time.now.to_i)
      @state.save_task(task)
      true
    end

    def recover_without_pull_request(task, pull_request)
      return false if pull_request
      return false unless task.review_state? || task.state == "finalizing"

      task.transition_to("continuing") if task.issue_number
      task.schedule_retry(after: @config.retry_after)
      @state.save_task(task)
      true
    end

    def finish_merged_task(task, pull_request)
      return false unless pull_request && pull_request["mergedAt"]
      # Already past the merge: finalizing, or waiting on a human the finalizer
      # asked. Restarting it would ask the same question again every cycle.
      return false if task.state == "finalizing" || task.metadata["resume_state"] == "finalizing"

      @worktrees&.cleanup_review(task)
      task.state = (task.issue_number || task.worktree) ? "finalizing" : "done"
      task.retry_at = Time.now.to_i if task.state == "finalizing"
      @state.save_task(task)
      true
    end

    def recover_from_closed_pull_request(task, pull_request)
      return false unless pull_request && pull_request["state"] == "CLOSED" && !pull_request["mergedAt"]

      @worktrees&.cleanup_review(task)
      if task.issue_number
        @log.warn("[#{task.id}] PR ##{pull_request["number"]} closed without merge; returning task to worker")
        task.pr_number = nil
        task.last_review_signature = nil
        task.transition_to("implementing", retry_at: Time.now.to_i)
      else
        task.state = "done"
        task.retry_at = nil
      end

      @state.save_task(task)
      true
    end

    def resume_after_human_reply(task)
      resume_state = task.metadata.delete("resume_state") || "implementing"
      @log.info("[#{task.id}] human response received; resuming #{resume_state}")
      task.human_marker = nil
      task.metadata.delete("human_conversation_number")
      task.transition_to(resume_state, retry_at: Time.now.to_i)
    end

    def release_for_human_wait(task)
      @worktrees&.release_for_human_wait(task)
    rescue => e
      @log.warn("[#{task.id}] could not release workspaces during human wait: #{e.message}")
    end

    def resume_review_after_rework_reply(task, pull_request)
      return unless task.state == "changes_requested" && pull_request && pull_request["state"] == "OPEN"
      return if pull_request["mergeable"] == "CONFLICTING"

      comments = Array(pull_request["comments"])
      request = comments.select { |comment| comment.fetch("body", "").include?("<!-- ghwatch:changes-requested:") }
        .max_by { |comment| comment.fetch("id").to_i }
      return unless request

      last_reply = [request.fetch("id").to_i, task.metadata["last_rework_reply_id"].to_i].max
      reply = comments.select do |comment|
        comment.fetch("id").to_i > last_reply && !comment.fetch("body", "").include?(Github::MARKER_PREFIX)
      end.max_by { |comment| comment.fetch("id").to_i }
      return unless reply

      @log.info("[#{task.id}] new PR reply after requested changes; returning to review")
      task.metadata["last_rework_reply_id"] = reply.fetch("id").to_i
      task.last_review_signature = nil
      task.clear_retry
      task.transition_to("waiting_for_review", retry_at: Time.now.to_i)
    end

    def schedule_review_when_needed(task, snapshot)
      return unless task.review_state?

      if task.state == "ready_to_merge" && snapshot.review_signature != task.last_review_signature
        @log.info("[#{task.id}] review-relevant PR state changed; returning to review")
        task.transition_to("waiting_for_review", retry_at: Time.now.to_i)
      elsif snapshot.review_signature != task.last_review_signature
        task.retry_at = Time.now.to_i
      elsif task.state != "ready_to_merge" && snapshot.pull_request_signature != task.last_pr_signature
        task.retry_at = Time.now.to_i
      elsif task.retry_at.nil? && task.state != "ready_to_merge"
        task.schedule_retry(after: @config.retry_after)
      end
    end

    def action_due?(task)
      return false if task.waiting_for_human?
      return true if task.retry_at.nil? && %w[implementing changes_requested continuing finalizing].include?(task.state)

      task.retry_due?
    end
  end
end
