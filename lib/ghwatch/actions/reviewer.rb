# frozen_string_literal: true

module Ghwatch
  module Actions
    class Reviewer < Base
      def run(task, role: "reviewer")
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        pull_request = snapshot.pull_request || raise("PR ##{task.pr_number} is unavailable")
        task.issue_number ||= linked_issue_number(pull_request)
        issue = task.issue_number && @github.issue(task.issue_number)
        context = @context_builder.reviewer(task: task, issue: issue, pull_request: pull_request)
        outcome = @roles.run(role, context: context, cwd: @project.root, task: task)
        remember_outcome(task, outcome)

        unless outcome.success?
          retry_failed_role(task, outcome)
          return
        end

        if outcome.data["status"] == "deep_review" && role == "reviewer"
          @state.save_task(task)
          return run(task, role: "deep_reviewer")
        end

        task.clear_retry
        apply_result(task, pull_request, outcome)
        @state.save_task(task)
      end

      def attempt_merge(task)
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        pull_request = snapshot.pull_request || raise("PR ##{task.pr_number} is unavailable")

        if task.last_review_signature != snapshot.review_signature
          task.transition_to("waiting_for_review", retry_at: Time.now.to_i)
          @state.save_task(task)
          return
        end

        checks_ready = !@config.reviewer_requires_green_checks? || @github.checks_green?(pull_request)
        unless checks_ready && @github.mergeable?(pull_request)
          task.schedule_retry(after: @config.retry_after)
          @state.save_task(task)
          return
        end

        @github.merge_pull_request(task.pr_number, method: @config.merge_method)
        task.state = (task.issue_number || task.worktree) ? "finalizing" : "done"
        task.retry_at = (task.state == "finalizing") ? Time.now.to_i : nil
        @state.save_task(task)
        @issue_triage.request!
      rescue => e
        task.last_error = e.message
        task.schedule_retry(after: @config.retry_after)
        @state.save_task(task)
      end

      private

      def linked_issue_number(pull_request)
        Array(pull_request["closingIssuesReferences"]).first&.fetch("number", nil)
      end

      def apply_result(task, pull_request, outcome)
        data = outcome.data
        initial_signature = @github.review_signature(pull_request)

        case data["status"]
        when "merge"
          post_review_body(task, data["body"], outcome, kind: "review-ok")
          task.last_review_signature = refreshed_review_signature(task, fallback: initial_signature)
          if @config.auto_merge?
            task.state = "ready_to_merge"
            task.retry_at = Time.now.to_i
          else
            task.state = "waiting_for_review"
          end
        when "changes_requested"
          post_review_body(task, data.fetch("body"), outcome, kind: "changes-requested")
          task.last_review_signature = refreshed_review_signature(task, fallback: initial_signature)
          task.state = "changes_requested"
          task.retry_at = Time.now.to_i
        when "waiting_for_human_test"
          task.last_review_signature = initial_signature
          wait_for_human(task, data.fetch("body"), outcome, kind: "human-test", resume_state: "waiting_for_review", target: :pull_request)
        when "comment"
          post_review_body(task, data.fetch("body"), outcome, kind: "review-comment")
          task.last_review_signature = refreshed_review_signature(task, fallback: initial_signature)
          task.state = "waiting_for_review"
          task.schedule_retry(after: @config.retry_after)
        when "retry"
          task.schedule_retry(after: @config.retry_after)
        else
          raise "unknown review status #{data["status"].inspect}"
        end
      end

      def post_review_body(task, body, outcome, kind:)
        return if body.to_s.strip.empty?

        @github.post_pr_comment(
          task.pr_number,
          body,
          kind: kind,
          model_signature: outcome.signature
        )
      end

      def refreshed_review_signature(task, fallback:)
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        snapshot.review_signature || fallback
      rescue => e
        @log.warn("[#{task.id}] could not refresh review signature after comment: #{e.message}")
        fallback
      end
    end
  end
end
