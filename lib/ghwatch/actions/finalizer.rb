# frozen_string_literal: true

module Ghwatch
  module Actions
    class Finalizer < Base
      def initialize(worktrees:, **kwargs)
        super(**kwargs)
        @worktrees = worktrees
      end

      def run(task)
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        unless snapshot.pull_request && snapshot.pull_request["mergedAt"]
          task.transition_to(snapshot.pull_request ? "waiting_for_review" : "continuing")
          task.schedule_retry(after: @config.retry_after)
          @state.save_task(task)
          return
        end

        unless task.issue_number
          @worktrees.cleanup(task)
          task.state = "done"
          task.retry_at = nil
          @state.save_task(task)
          return
        end

        context = @context_builder.finalizer(
          task: task,
          issue: snapshot.issue,
          pull_request: snapshot.pull_request
        )
        outcome = @roles.run("finalizer", context: context, cwd: task.worktree || @project.root, task: task)
        remember_outcome(task, outcome)

        unless outcome.success?
          retry_failed_role(task, outcome)
          return
        end

        apply_result(task, snapshot, outcome)
        @state.save_task(task)
      end

      private

      def apply_result(task, snapshot, outcome)
        data = outcome.data

        case data["status"]
        when "done"
          complete(task, snapshot, outcome, data)
        when "waiting_for_human_input"
          wait_for_human(task, data.fetch("comment"), outcome, kind: "human-question", resume_state: "finalizing")
        when "waiting_for_human_test"
          wait_for_human(task, data.fetch("comment"), outcome, kind: "human-test", resume_state: "finalizing")
        when "retry"
          task.schedule_retry(after: @config.retry_after)
        else
          raise "unknown finalizer status #{data["status"].inspect}"
        end
      end

      def complete(task, snapshot, outcome, data)
        comment = data["comment"]
        should_close = data.fetch("close_issue", @config.close_issue_after_merge?)
        issue = snapshot.issue

        if should_close && issue["state"] == "OPEN"
          @github.close_issue(task.issue_number, comment: comment, model_signature: outcome.signature)
        elsif comment && !comment.strip.empty?
          @github.post_issue_comment(task.issue_number, comment, kind: "completion", model_signature: outcome.signature)
        end

        task.state = "done"
        task.retry_at = nil
        @worktrees.cleanup(task)
        @issue_triage.request!
      end
    end
  end
end
