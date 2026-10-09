# frozen_string_literal: true

module Ghwatch
  module Actions
    class Reviewer < Base
      def initialize(worktrees: nil, **kwargs)
        super(**kwargs)
        @worktrees = worktrees
      end

      def run(task, role: "reviewer")
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        pull_request = snapshot.pull_request || raise("PR ##{task.pr_number} is unavailable")
        task.issue_number ||= linked_issue_number(pull_request)
        issue = task.issue_number && @github.issue(task.issue_number)
        return if update_behind_branch(task, pull_request)
        return if skip_repeat_review(task, snapshot, pull_request)

        workspace = @worktrees.prepare_review(task, pull_request, state: @state)
        context = @context_builder.reviewer(task: task, issue: issue, pull_request: pull_request)
        outcome = @roles.run(role, context: context, cwd: workspace, task: task)
        remember_outcome(task, outcome)
        record_workspace_changes(task, "after the #{role} run (#{outcome.signature})")

        unless outcome.success?
          retry_failed_role(task, outcome, role)
          return
        end

        current = TaskSnapshot.capture(task: task, github: @github).pull_request
        unless current && current["headRefOid"] == pull_request.fetch("headRefOid") && current["state"] == "OPEN"
          task.last_error = "PR changed during review; retry against its current head"
          decide(task, role, "pr_changed")
          @state.save_task(task)
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

      # A person answered a test request. The PR they tested was reviewed
      # already, so it is not reviewed again: the answer decides, as long as
      # the PR still makes the changes they tested (merging the base in since
      # does not count).
      def check_test_result(task)
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        pull_request = snapshot.pull_request || raise("PR ##{task.pr_number} is unavailable")
        unless tested_changes?(task, pull_request)
          @log.info("[#{task.id}] PR ##{task.pr_number} changed since it was tested; reviewing it again")
          decide(task, "test_judge", "pr_changed")
          @state.save_task(task)
          return
        end

        issue = task.issue_number && @github.issue(task.issue_number)
        context = @context_builder.test_judge(task: task, issue: issue, pull_request: pull_request)
        # The judge reads and builds nothing; any existing checkout will do.
        cwd = (task.worktree && File.directory?(task.worktree)) ? task.worktree : @project.root
        outcome = @roles.run("test_judge", context: context, cwd: cwd, task: task)
        remember_outcome(task, outcome)
        unless outcome.success?
          retry_failed_role(task, outcome, "test_judge")
          return
        end

        task.clear_retry
        apply_test_result(task, pull_request, outcome)
        @state.save_task(task)
      end

      def attempt_merge(task)
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        pull_request = snapshot.pull_request || raise("PR ##{task.pr_number} is unavailable")

        result = merge_result(task, snapshot, pull_request)
        decide(task, "merge", result)
        @state.save_task(task)
      end

      private

      def merge_result(task, snapshot, pull_request)
        return "pr_changed" if task.last_review_signature != snapshot.review_signature
        return "manual" unless @config.auto_merge?

        checks_ready = !@config.reviewer_requires_green_checks? || @github.checks_green?(pull_request)
        return "pending" unless checks_ready && @github.mergeable?(pull_request)

        begin
          @github.merge_pull_request(task.pr_number, method: @config.merge_method)
        rescue => e
          task.last_error = "merge refused: #{e.message}"
          ask_about_refused_merge(task, e.message)
          return "refused"
        end
        task.last_error = nil
        "merged"
      end

      def ask_about_refused_merge(task, message)
        body = <<~TEXT
          This PR was approved and its required checks passed, but GitHub refused to merge it:

          ```
          #{message.strip}
          ```

          Please resolve what blocks the merge (for example a required approval or branch protection) and reply here; the PR will be reviewed again and merged.
        TEXT
        outcome = Struct.new(:signature).new("ghwatch")
        wait_for_human(task, body, outcome, kind: "human-question", target: :pull_request)
      end

      # Reviews the PR as it would merge: a head behind its base is first
      # updated on GitHub, and the review runs against the new head. A refused
      # update (conflict, fork permissions) is not retried for the same head,
      # nor is an update requested twice while GitHub has not applied it yet.
      def update_behind_branch(task, pull_request)
        return false unless @config.update_pr_branches?

        head = pull_request.fetch("headRefOid")
        return false if [task.metadata["branch_update_failed_head"], task.metadata["branch_updated_from"]].include?(head)
        return false unless @worktrees.behind_base?(task, pull_request)

        @github.update_pull_request_branch(task.pr_number, expected_head: head)
        @log.info("[#{task.id}] PR ##{task.pr_number} was behind its base; updated it before review")
        wait_for_new_head(task.pr_number, head)
        task.metadata["branch_updated_from"] = head
        decide(task, "reviewer", "branch_updated")
        @state.save_task(task)
        true
      rescue => e
        @log.warn("[#{task.id}] could not update PR ##{task.pr_number} from its base; reviewing it as is: #{e.message}")
        task.metadata["branch_update_failed_head"] = head
        false
      end

      # GitHub applies the update asynchronously; reviewing before the new head
      # appears would review the old one and be discarded.
      def wait_for_new_head(number, head)
        deadline = Time.now + branch_update_wait
        while Time.now < deadline
          return if @github.pull_request(number)&.fetch("headRefOid", head) != head

          sleep 2
        end
      end

      def branch_update_wait = 60

      def record_workspace_changes(task, trigger)
        @worktrees.record_workspace_changes(task, trigger: trigger)
      rescue => e
        @log.warn("[#{task.id}] could not check the review workspace: #{e.message}")
      end

      def linked_issue_number(pull_request)
        Array(pull_request["closingIssuesReferences"]).first&.fetch("number", nil)
      end

      def apply_result(task, pull_request, outcome)
        data = outcome.data
        initial_signature = @github.review_signature(pull_request)
        task.metadata.delete("commented_review")

        role = outcome.respond_to?(:role) ? (outcome.role || "reviewer") : "reviewer"
        case data["status"]
        when "merge"
          post_review_body(task, data["body"], outcome, kind: "review-ok")
          task.last_review_signature = refreshed_review_signature(task, fallback: initial_signature)
        when "changes_requested"
          post_review_body(task, data.fetch("body"), outcome, kind: "changes-requested")
          task.last_review_signature = refreshed_review_signature(task, fallback: initial_signature)
        when "waiting_for_human_input"
          task.last_review_signature = initial_signature
          wait_for_human(task, data.fetch("body"), outcome, kind: "human-question", target: :pull_request)
        when "waiting_for_human_test"
          task.last_review_signature = initial_signature
          task.metadata["human_test_head"] = pull_request["headRefOid"]
          ask_for_human_test(task, data, outcome)
        when "comment"
          post_review_body(task, data.fetch("body"), outcome, kind: "review-comment")
          task.last_review_signature = refreshed_review_signature(task, fallback: initial_signature)
          remember_comment(task, pull_request)
        when "retry"
          nil
        else
          raise "unknown review status #{data["status"].inspect}"
        end
        decide(task, role, data["status"])
      end

      def tested_changes?(task, pull_request)
        tested = task.metadata["human_test_head"]
        head = pull_request["headRefOid"]
        return false unless tested && head
        return true if tested == head

        @worktrees.same_changes?(task, base: pull_request["baseRefName"], from: tested, to: head)
      rescue => e
        @log.warn("[#{task.id}] could not compare the PR with the tested head: #{e.message}")
        false
      end

      def apply_test_result(task, pull_request, outcome)
        data = outcome.data
        case data["status"]
        when "passed"
          post_review_body(task, data["body"], outcome, kind: "review-ok")
          task.last_review_signature = refreshed_review_signature(task, fallback: @github.review_signature(pull_request))
        when "problem"
          post_review_body(task, data.fetch("body"), outcome, kind: "changes-requested")
        when "incomplete"
          message = data["reporter_message"].to_s.strip.empty? ? data.fetch("body") : data["reporter_message"]
          wait_for_human(task, message, outcome, kind: "human-test", target: task.issue_number ? :issue : :pull_request)
        when "retry"
          nil
        else
          raise "unknown test result status #{data["status"].inspect}"
        end
        decide(task, "test_judge", data["status"])
      end

      # The review stays on the PR; the reporter gets a request written for
      # them on the issue they follow.
      def ask_for_human_test(task, data, outcome)
        unless task.issue_number
          wait_for_human(task, data.fetch("body"), outcome, kind: "human-test", target: :pull_request)
          return
        end

        message = data["reporter_message"].to_s
        raise "waiting_for_human_test for issue ##{task.issue_number} needs reporter_message" if message.strip.empty?

        post_review_body(task, data["body"], outcome, kind: "review-comment")
        wait_for_human(task, message, outcome, kind: "human-test", target: :issue)
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

      # A non-blocking comment changes nothing by itself, so reviewing the same
      # head again only repeats it. Wait for something to change instead: new
      # activity on the PR, or, while checks are still running, their end.
      def skip_repeat_review(task, snapshot, pull_request)
        last = task.metadata["commented_review"]
        return false unless last && last["head"] == pull_request["headRefOid"]

        unchanged = last["review"] == snapshot.review_signature && last["pr"] == snapshot.pull_request_signature
        pending = @config.reviewer_requires_green_checks? && @github.checks_pending?(pull_request)
        return false unless unchanged || pending

        @log.info("[#{task.id}] PR ##{task.pr_number} already reviewed at this head; waiting for " \
          "#{unchanged ? "new activity" : "its checks to finish"}")
        decide(task, "reviewer", "already_reviewed")
        @state.save_task(task)
        true
      end

      def remember_comment(task, pull_request)
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        task.metadata["commented_review"] = {
          "head" => pull_request["headRefOid"],
          "review" => snapshot.review_signature,
          "pr" => snapshot.pull_request_signature
        }
      rescue => e
        @log.warn("[#{task.id}] could not remember the review comment: #{e.message}")
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
