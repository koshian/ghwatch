# frozen_string_literal: true

module Ghwatch
  module Actions
    class Worker < Base
      def initialize(worktrees:, command:, **kwargs)
        super(**kwargs)
        @worktrees = worktrees
        @command = command
      end

      def run(task)
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        repository_before = RepositoryState.capture(command: @command, cwd: task.worktree || @project.root)
        context = @context_builder.worker(
          task: task,
          issue: snapshot.issue,
          pull_request: snapshot.pull_request
        )
        outcome = @roles.run("worker", context: context, cwd: task.worktree || @project.root)
        remember_outcome(task, outcome)

        unless outcome.success?
          retry_failed_role(task, outcome)
          return
        end

        task.clear_retry
        if no_op_continue?(task, snapshot, repository_before, outcome)
          task.last_error = "worker returned continue without an observable repository or PR change"
          task.schedule_retry(after: @config.retry_after)
          @log.warn("[#{task.id}] worker returned a no-op continue; scheduling retry")
        else
          apply_result(task, outcome)
        end
        @state.save_task(task)
      end

      private

      def no_op_continue?(task, before_snapshot, repository_before, outcome)
        return false unless outcome.data["status"] == "continue"

        repository_after = RepositoryState.capture(command: @command, cwd: task.worktree || @project.root)
        after_snapshot = TaskSnapshot.capture(task: task, github: @github)

        repository_before == repository_after &&
          before_snapshot.pull_request_signature == after_snapshot.pull_request_signature &&
          before_snapshot.issue_signature == after_snapshot.issue_signature
      end

      def apply_result(task, outcome)
        data = outcome.data

        case data["status"]
        when "waiting_for_review"
          task.pr_number = data["pr"]&.to_i || TaskSnapshot.capture(task: task, github: @github).pull_request&.fetch("number", nil)
          raise "worker reported waiting_for_review but no PR exists" unless task.pr_number

          task.state = "waiting_for_review"
          task.last_review_signature = nil
          task.retry_at = Time.now.to_i
          @issue_triage.request!
        when "waiting_for_human_input"
          wait_for_human(task, data.fetch("question"), outcome, kind: "human-question", resume_state: task.state)
        when "waiting_for_human_test"
          wait_for_human(task, data.fetch("question"), outcome, kind: "human-test", resume_state: task.state)
        when "continue"
          task.state = "continuing"
          task.schedule_retry(after: @config.retry_after)
        when "done"
          task.state = "finalizing"
          task.retry_at = Time.now.to_i
        when "deferred"
          defer(task, data)
        else
          raise "unknown worker status #{data["status"].inspect}"
        end
      end

      def defer(task, data)
        task.state = "done"
        if task.issue_number
          issue = @github.issue(task.issue_number)
          @state.save_assessment(
            task.issue_number,
            status: "deferred",
            reason: data["reason"].to_s,
            comment: nil,
            signature: @github.issue_signature(issue)
          )
        end
        @worktrees.cleanup(task)
        @issue_triage.request!
      end
    end
  end
end
