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
        if snapshot.pull_request && !task.worktree
          @worktrees.prepare_pull_request(task, snapshot.pull_request, state: @state)
          @state.save_task(task)
        end
        @worktrees&.restore_task_worktree(task)
        repository_before = RepositoryState.capture(command: @command, cwd: task.worktree || @project.root)
        context = @context_builder.worker(
          task: task,
          issue: snapshot.issue,
          pull_request: snapshot.pull_request
        )
        outcome = @roles.run("worker", context: context, cwd: task.worktree || @project.root, task: task)
        remember_outcome(task, outcome)

        unless outcome.success?
          retry_failed_role(task, outcome, "worker")
          return
        end

        task.clear_retry
        if no_op_continue?(task, snapshot, repository_before, outcome)
          task.last_error = "worker returned continue without an observable repository or PR change"
          @log.warn("[#{task.id}] worker returned a no-op continue; scheduling retry")
          decide(task, "worker", "no_change")
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
        when "waiting_for_review", "waiting_for_human_test"
          pull_request = if data["pr"]
            @github.pull_request(Integer(data["pr"].to_s, 10))
          else
            TaskSnapshot.capture(task: task, github: @github).pull_request
          end
          return retry_without_pull_request(task) unless pull_request
          raise "worker reported a different PR from the assigned PR" if task.pr_number && pull_request["number"] != task.pr_number
          raise "worker reported a PR for a different branch" unless pull_request["headRefName"] == task.branch
          raise "worker reported review readiness but the PR still has conflicts" if pull_request["mergeable"] == "CONFLICTING"

          task.pr_number = pull_request.fetch("number")
          task.metadata["test_preparation"] = data["test_preparation"]
          task.metadata["human_test_request"] = (data["status"] == "waiting_for_human_test") ? data.fetch("question") : nil
          decide(task, "worker", "waiting_for_review")
        when "waiting_for_human_input"
          wait_for_human(task, data.fetch("question"), outcome, kind: "human-question")
          decide(task, "worker", "waiting_for_human_input")
        when "continue"
          decide(task, "worker", "continue")
        when "done"
          pull_request = TaskSnapshot.capture(task: task, github: @github).pull_request
          return retry_without_pull_request(task) unless pull_request

          task.pr_number = pull_request.fetch("number")
          decide(task, "worker", pull_request["mergedAt"] ? "merged" : "done")
        when "deferred"
          defer(task, data)
        else
          raise "unknown worker status #{data["status"].inspect}"
        end
      end

      def retry_without_pull_request(task)
        task.last_error = "worker finished without a pull request; scheduling retry"
        decide(task, "worker", "no_pr")
      end

      def defer(task, data)
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
        decide(task, "worker", "deferred")
      end
    end
  end
end
