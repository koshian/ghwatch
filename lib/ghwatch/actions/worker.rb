# frozen_string_literal: true

module Ghwatch
  module Actions
    class Worker < Base
      NO_PR_LIMIT = 3

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
        follow_pull_request(task, snapshot.pull_request)
        head_before = snapshot.pull_request&.fetch("headRefOid", nil)
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
          post_summary(task, outcome, head_before)
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
        task.metadata.delete("no_pr_streak") unless %w[waiting_for_review waiting_for_human_test done].include?(data["status"])

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
          return if unready_handoff(task, pull_request, outcome)

          decide(task, "worker", "waiting_for_review")
        when "waiting_for_human_input"
          wait_for_human(task, data.fetch("question"), outcome, kind: "human-question")
          decide(task, "worker", "waiting_for_human_input")
        when "continue"
          decide(task, "worker", "continue")
        when "done"
          pull_request = TaskSnapshot.capture(task: task, github: @github).pull_request
          return hand_findings_over(task, data, outcome) unless pull_request

          task.pr_number = pull_request.fetch("number")
          decide(task, "worker", pull_request["mergedAt"] ? "merged" : "done")
        when "deferred"
          defer(task, data)
        else
          raise "unknown worker status #{data["status"].inspect}"
        end
      end

      # The worktree catches up with what others pushed to the PR (ghwatch
      # merging the base in, a rebase), as long as nothing is lost; anything
      # else is the worker's to integrate.
      def follow_pull_request(task, pull_request)
        return unless pull_request && task.worktree && @worktrees

        followed = @worktrees.follow_pull_request(task, pull_request)
        @log.info("[#{task.id}] the worktree followed PR ##{pull_request["number"]} (#{followed})") if %i[fast_forward reset].include?(followed)
      rescue => e
        @log.warn("[#{task.id}] could not bring the worktree to the PR head: #{e.message}")
      end

      # A PR goes to review only as it could be merged: the review may run in
      # this worktree and must see what the PR has. A worker that left
      # something behind is sent back once; then a person decides.
      def unready_handoff(task, pull_request, outcome)
        problem = @worktrees&.handoff_problem(task, pull_request)
        unless problem
          task.metadata.delete("handoff_returns")
          task.metadata.delete("rework_reason") if task.metadata.delete("handoff_rework")
          return false
        end

        details = handoff_details(problem)
        @log.warn("[#{task.id}] handed to review but not ready to merge as it is: #{details.tr("\n", " ")}")
        if task.metadata["handoff_returns"].to_i < 1
          task.metadata["handoff_returns"] = 1
          task.metadata["handoff_rework"] = true
          task.metadata["rework_reason"] = "The PR was handed to review but could not be merged as it is.\n#{details}\n" \
            "Commit and push what belongs in the PR, and restore (git restore) what does not. " \
            "Do not commit temporary files; they may stay untracked."
          decide(task, "worker", "not_handed_off")
        else
          task.metadata.delete("handoff_returns")
          body = <<~TEXT
            The worker handed this PR to review again without it being ready to merge as it is:

            #{details}

            Please decide what belongs in the PR (push the commits, or commit or discard the changes in that worktree) and reply here; the PR will then be reviewed.
          TEXT
          wait_for_human(task, body, Struct.new(:signature).new("ghwatch"), kind: "human-question", target: :pull_request)
          decide(task, "worker", "handoff_failed")
        end
        true
      end

      def handoff_details(problem)
        lines = []
        lines << "Tracked changes in #{problem[:path]}: #{problem[:changed].map(&:strip).join(", ")}" unless problem[:changed].empty?
        lines << "Commits not pushed to the PR: #{problem[:unpushed].join("; ")}" unless problem[:unpushed].empty?
        lines.join("\n")
      end

      # Every push is explained on the PR: the worker's summary, and the new
      # commits, which are listed even when the summary is missing.
      def post_summary(task, outcome, head_before)
        return unless task.pr_number

        pull_request = @github.pull_request(task.pr_number)
        head = pull_request&.fetch("headRefOid", nil)
        summary = outcome.data["summary"].to_s.strip
        return if head.nil? || (head == head_before && summary.empty?)

        commits = (head == head_before) ? [] : new_commits(task, head_before || "origin/#{pull_request["baseRefName"]}", head)
        body = [summary.empty? ? nil : summary, commits.empty? ? nil : commits.map { |line| "- #{line}" }.join("\n")]
        @github.post_pr_comment(task.pr_number, body.compact.join("\n\n"), kind: "worker-summary", model_signature: outcome.signature)
      rescue => e
        @log.warn("[#{task.id}] could not post the worker summary: #{e.message}")
      end

      def new_commits(task, since, head)
        cwd = task.worktree || @project.root
        result = @command.run("git", "-C", cwd.to_s, "log", "--format=%h %s", "--max-count=20", "#{since}..#{head}")
        result.success? ? result.stdout.lines.map(&:strip).reject(&:empty?) : []
      end

      # Ready for review, yet no PR: tried again a few times, then a person
      # is asked rather than the worker run on and on.
      def retry_without_pull_request(task)
        streak = task.metadata["no_pr_streak"] = task.metadata["no_pr_streak"].to_i + 1
        if streak >= NO_PR_LIMIT && task.issue_number
          task.metadata.delete("no_pr_streak")
          body = japanese? ? "ワーカーが #{streak} 回続けて「レビューに渡せる」と報告しましたが、PR がありません。どう進めるかを返信してください。返信すると作業を再開します。" :
            "The worker reported #{streak} times in a row that the work is ready for review, but there is no PR. Please reply how to go on; a reply resumes the work."
          wait_for_human(task, body, Struct.new(:signature).new("ghwatch"), kind: "human-question", target: :issue)
          return decide(task, "worker", "no_pr_limit")
        end
        task.last_error = "worker finished without a pull request; scheduling retry"
        decide(task, "worker", "no_pr")
      end

      # The work needs no change (an investigation that found nothing to do,
      # or an issue that allows closing with a reason). What the worker found
      # goes on the issue and a person decides; running it again would only
      # repeat the same investigation.
      def hand_findings_over(task, data, outcome)
        findings = [data["summary"], data["reason"]].map(&:to_s).map(&:strip).reject(&:empty?).uniq.join("\n\n")
        return retry_without_pull_request(task) if findings.empty? || task.issue_number.nil?

        note = japanese? ? "ワーカーは変更を加えず、PR も作らずに作業を終えました。Issue を閉じるか、どう進めるかを判断してください。返信すると作業を再開します。" :
          "The worker finished without changing anything or opening a PR. Please decide whether to close the issue or how to go on; a reply resumes the work."
        wait_for_human(task, "#{findings}\n\n#{note}", outcome, kind: "human-question", target: :issue)
        decide(task, "worker", "no_change_needed")
      end

      def japanese? = @config.respond_to?(:human_language) && @config.human_language.to_s.start_with?("ja")

      def defer(task, data)
        if task.issue_number
          issue = @github.issue(task.issue_number)
          @state.save_assessment(
            task.issue_number,
            status: "deferred",
            reason: data["reason"].to_s,
            comment: nil,
            signature: @github.issue_content_signature(issue),
            issue_updated_at: issue["updatedAt"]
          )
        end
        decide(task, "worker", "deferred")
      end
    end
  end
end
