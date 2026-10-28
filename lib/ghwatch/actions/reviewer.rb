# frozen_string_literal: true

module Ghwatch
  module Actions
    class Reviewer < Base
      def initialize(worktrees: nil, test_builds: nil, **kwargs)
        super(**kwargs)
        @worktrees = worktrees
        @test_builds = test_builds
      end

      # The test build the request waited for is done: the request goes out
      # as the reviewer wrote it, with links to what was built.
      def announce_test_build(task, status)
        build = task.metadata.delete("test_build")
        section = test_build_section(status)
        data = %w[body reporter_message].to_h { |key| [key, build[key].to_s.strip.empty? ? build[key] : "#{build[key].rstrip}\n\n#{section}"] }
        @log.info("[#{task.id}] the test build is ready; asking for the test")
        ask_for_human_test(task, data, Struct.new(:signature).new(build["signature"]))
        decide(task, "test_build", "ready")
        @state.save_task(task)
      end

      # The reviewer reads why on its next run.
      def test_build_failed(task, reason)
        task.metadata.delete("test_build")
        task.metadata["test_build_failure"] = reason
        @log.info("[#{task.id}] #{reason}; reviewing again")
        decide(task, "test_build", "failed")
        @state.save_task(task)
      end

      def run(task, role: "reviewer")
        snapshot = TaskSnapshot.capture(task: task, github: @github)
        pull_request = snapshot.pull_request || raise("PR ##{task.pr_number} is unavailable")
        task.issue_number ||= linked_issue_number(pull_request)
        issue = task.issue_number && @github.issue(task.issue_number)
        return if update_behind_branch(task, pull_request)
        return if skip_repeat_review(task, snapshot, pull_request)

        workspace = review_workspace(task, pull_request) or return
        context = @context_builder.reviewer(task: task, issue: issue, pull_request: pull_request)
        outcome = begin
          @roles.run(role, context: context, cwd: workspace, task: task)
        ensure
          finish_shared_review(task, "after the #{role} run")
        end
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
        apply_result(task, pull_request, outcome, workspace: workspace)
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
        return rerun_failed_checks(task, pull_request) if !checks_ready && checks_failed?(pull_request)
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

      def checks_failed?(pull_request)
        !@github.checks_pending?(pull_request) && !@github.failed_checks(pull_request).empty?
      end

      # The PR was approved with its checks failing: the worker found nothing
      # in its changes to fix. The failed jobs are run once more, and a person
      # is asked if they fail again.
      def rerun_failed_checks(task, pull_request)
        head = pull_request["headRefOid"]
        failed = @github.failed_checks(pull_request).sort
        if task.metadata["rerun_checks_head"] != head
          @github.rerun_failed_checks(pull_request)
          task.metadata["rerun_checks_head"] = head
          @log.info("[#{task.id}] reran the failed checks of PR ##{task.pr_number}: #{failed.join(", ")}")
          return "pending"
        end

        body = <<~TEXT
          This PR was approved, but its required checks failed on #{head}, and failed again after ghwatch reran them: #{failed.join(", ")}.

          Please look at the failures (fix them, rerun the checks, or merge by hand) and reply here; the PR will be reviewed again.
        TEXT
        outcome = Struct.new(:signature).new("ghwatch")
        wait_for_human(task, body, outcome, kind: "human-question", target: :pull_request)
        "checks_failed"
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

      # The task worktree, at the PR head, so the review reuses what the
      # worker built; a separate workspace for a PR ghwatch only reviews. A
      # task worktree that cannot follow the PR without losing something
      # means the work went astray, and a person decides.
      def review_workspace(task, pull_request)
        return @worktrees.prepare_review(task, pull_request, state: @state) unless @worktrees.shared_review?(task)

        followed = @worktrees.follow_pull_request(task, pull_request)
        if followed.is_a?(String)
          ask_about_diverged_worktree(task, pull_request, followed)
          return nil
        end

        release_separate_workspace(task)
        @worktrees.begin_shared_review(task, state: @state)
      end

      def ask_about_diverged_worktree(task, pull_request, reason)
        @log.warn("[#{task.id}] the task worktree cannot follow PR ##{task.pr_number}: #{reason}")
        body = <<~TEXT
          Before reviewing this PR, ghwatch could not bring the task worktree to the PR head #{pull_request["headRefOid"]}: #{reason}.

          The review runs in that worktree to reuse what the worker built, so it has to match the PR. Please decide which is right (push the worktree's commits to the PR, or discard them so the worktree follows the PR) and reply here; the PR will then be reviewed.
        TEXT
        wait_for_human(task, body, Struct.new(:signature).new("ghwatch"), kind: "human-question", target: :pull_request)
        decide(task, "reviewer", "workspace_diverged")
        @state.save_task(task)
      end

      # A workspace from before reviews moved into the task worktree.
      def release_separate_workspace(task)
        @worktrees.cleanup_review(task)
      rescue => e
        @log.warn("[#{task.id}] could not remove the separate review workspace: #{e.message}")
      end

      def finish_shared_review(task, trigger)
        @worktrees.end_shared_review(task, trigger: trigger)
      rescue => e
        @log.error("[#{task.id}] could not put the task worktree back after the review: #{e.message}")
      end

      def linked_issue_number(pull_request)
        Array(pull_request["closingIssuesReferences"]).first&.fetch("number", nil)
      end

      def apply_result(task, pull_request, outcome, workspace: nil)
        task.metadata.delete("test_build_failure")
        data = with_found_issues(task, outcome.data, outcome)
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
          return leave_to_author(task, pull_request, role) if task.metadata["review_only"]
        when "waiting_for_human_input"
          task.last_review_signature = initial_signature
          wait_for_human(task, data.fetch("body"), outcome, kind: "human-question", target: :pull_request)
        when "waiting_for_human_test"
          data = with_screenshots(task, data, workspace)
          return decide(task, role, "failed") unless data

          task.last_review_signature = initial_signature
          task.metadata["human_test_head"] = pull_request["headRefOid"]
          runs = Array(data["test_build_runs"]).filter_map { |id| Integer(id, exception: false) }
          return wait_for_test_build(task, role, data, outcome, runs) if !runs.empty? && @test_builds

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
        decide(task, role, data["status"], rework_context(data, "review"))
      end

      # What the worker is sent back for, kept for later rounds and for the
      # person asked once the rounds run out.
      def rework_context(data, source)
        return {} unless %w[changes_requested problem].include?(data["status"])

        rework = data["rework"].is_a?(Hash) ? data["rework"] : {}
        summary = rework["summary"] || data["reason"] || data["body"].to_s.lines.find { |line| !line.strip.empty? }
        {rework: rework.slice("main_problem_solved", "simplify", "theme", "repeats_theme", "options").merge("source" => source, "summary" => summary)}
      end

      # Someone else's PR: its author makes the changes. The review is not
      # repeated for this head until they push or comment.
      def leave_to_author(task, pull_request, role)
        remember_comment(task, pull_request)
        decide(task, role, "author_changes")
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
        when "problem", "changes_requested"
          post_review_body(task, data.fetch("body"), outcome, kind: "changes-requested")
          return leave_to_author(task, pull_request, "test_judge") if task.metadata["review_only"]
        when "incomplete"
          message = data["reporter_message"].to_s.strip.empty? ? data.fetch("body") : data["reporter_message"]
          wait_for_human(task, message, outcome, kind: "human-test", target: task.issue_number ? :issue : :pull_request)
        when "delegated", "retry"
          nil
        else
          raise "unknown test result status #{data["status"].inspect}"
        end
        decide(task, "test_judge", data["status"], rework_context(data, "test"))
      end

      # Problems the review found outside what the PR causes are filed as
      # issues, so they outlive the review; each title once per task, and not
      # when an open issue already has it.
      def with_found_issues(task, data, outcome)
        found = Array(data["new_issues"]).select { |issue| issue.is_a?(Hash) && !issue["title"].to_s.strip.empty? && !issue["body"].to_s.strip.empty? }
        return data if found.empty? || !@config.file_found_issues? || data["body"].to_s.strip.empty?

        filed = task.metadata["found_issues"] ||= {}
        lines = found.filter_map do |issue|
          title = issue["title"].strip
          number = filed[title] || @github.open_issue_titled(title)&.fetch("number") || file_found_issue(task, issue, title, outcome)
          next unless number

          filed[title] = number
          "- ##{number} #{title}"
        end
        return data if lines.empty?

        heading = japanese? ? "別の Issue にしたもの:" : "Filed as separate issues:"
        data.merge("body" => "#{data["body"].rstrip}\n\n#{heading}\n#{lines.join("\n")}")
      end

      def file_found_issue(task, issue, title, outcome)
        origin = japanese? ? "PR ##{task.pr_number} のレビューで見つかりました。" : "Found while reviewing PR ##{task.pr_number}."
        number = @github.create_issue(title, "#{issue["body"].rstrip}\n\n#{origin}", kind: Github::FOUND_ISSUE_KIND,
          model_signature: outcome.signature)
        @log.info("[#{task.id}] filed issue ##{number}: #{title}")
        number
      rescue => e
        @log.warn("[#{task.id}] could not file the issue #{title.inspect}: #{e.message}")
        nil
      end

      def japanese? = @config.respond_to?(:human_language) && @config.human_language.to_s.start_with?("ja")

      # The reviewer's screenshots, published and shown under the request. A
      # request to judge by looking that has nothing to look at is not sent:
      # the review runs again.
      def with_screenshots(task, data, workspace)
        screenshots = Array(data["screenshots"])
        needed = data["human_check"] == "screenshots"
        raise WorktreeManager::ScreenshotError, "a screenshot check came without screenshots" if needed && screenshots.empty?
        return data if screenshots.empty?

        published = @worktrees.publish_screenshots(task, workspace, screenshots)
        gallery = published.each_with_index.map do |screenshot, index|
          "**#{index + 1}. #{screenshot[:caption]}**\n\n![#{screenshot[:caption]}](#{screenshot[:url]})"
        end.join("\n\n")
        data.merge(%w[body reporter_message].filter_map { |key| [key, "#{data[key].to_s.rstrip}\n\n#{gallery}"] unless data[key].to_s.strip.empty? }.to_h)
      rescue WorktreeManager::ScreenshotError, RuntimeError => e
        unless needed
          @log.warn("[#{task.id}] could not publish the screenshots: #{e.message}; asking without them")
          return data
        end

        task.last_error = "screenshots could not be shown: #{e.message}"
        @log.warn("[#{task.id}] #{task.last_error}; reviewing again")
        nil
      end

      # The request waits for the build; TestBuildWatcher looks at it.
      def wait_for_test_build(task, role, data, outcome, runs)
        task.metadata["test_build"] = @test_builds.plan(runs).merge(
          "body" => data["body"], "reporter_message" => data["reporter_message"], "signature" => outcome.signature
        )
        @log.info("[#{task.id}] waiting for test build run #{runs.join(", ")} before asking for the test")
        decide(task, role, "test_build")
      end

      def test_build_section(status)
        lines = status.runs.map do |run|
          artifacts = status.artifacts.select { |each_run, _| each_run["id"] == run["id"] }
            .map { |_, artifact| "  - [#{artifact["name"]}](#{@github.artifact_url(run["id"], artifact["id"])})" }
          ["- [#{run["display_title"] || run["name"]}](#{run["html_url"]})", *artifacts].join("\n")
        end
        heading = japanese? ? "**テストビルド**(取得には GitHub へのログインが必要です)" : "**Test build** (sign in to GitHub to download)"
        "#{heading}\n#{lines.join("\n")}"
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
