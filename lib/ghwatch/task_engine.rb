# frozen_string_literal: true

module Ghwatch
  class TaskEngine
    def initialize(state:, github:, human_channel:, worker_action:, reviewer_action:, finalizer_action:, config:, log: Log.new)
      @state = state
      @github = github
      @human_channel = human_channel
      @worker_action = worker_action
      @reviewer_action = reviewer_action
      @finalizer_action = finalizer_action
      @config = config
      @log = log
    end

    def reconcile_all
      active_tasks.each { |task| reconcile(task) }
    end

    def run_due(stop_requested: -> { false }, scope: :all)
      pull_request_tasks, issue_tasks = active_tasks.partition { |task| task.pr_number }
      tasks = case scope
      when :pull_requests then pull_request_tasks
      when :issues then issue_tasks
      when :all then pull_request_tasks + issue_tasks
      else raise ArgumentError, "unknown task scope #{scope.inspect}"
      end

      tasks.each do |task|
        break if stop_requested.call
        next unless action_due?(task)
        if task.review_state? || task.state == "finalizing"
          snapshot = TaskSnapshot.capture(task: task, github: @github)
          next if recover_without_pull_request(task, snapshot.pull_request)

          task.pr_number = snapshot.pull_request.fetch("number")
        end

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
      rescue => e
        @log.error("task #{task.id} action failed: #{e.class}: #{e.message}")
        task.last_error = e.message
        task.schedule_retry(after: @config.retry_after)
        @state.save_task(task)
      end
    end

    private

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

      resume_after_human_reply(task) if task.waiting_for_human? && @human_channel.reply_received?(task)
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

      task.state = task.issue_number ? "finalizing" : "done"
      task.retry_at = Time.now.to_i if task.issue_number
      @state.save_task(task)
      true
    end

    def recover_from_closed_pull_request(task, pull_request)
      return false unless pull_request && pull_request["state"] == "CLOSED" && !pull_request["mergedAt"]

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
