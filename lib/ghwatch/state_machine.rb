# frozen_string_literal: true

module Ghwatch
  # The only place that changes a task's state. Actions report what they
  # decided (a result) and the engine reports what happened on GitHub (an
  # event); the tables below say what each one does in each state. The
  # tables are the specification: ARCHITECTURE.md renders them with
  # StateMachine.markdown, and a test keeps the two in step.
  class StateMachine
    WORKER_STATES = Task::WORKER_STATES

    # Groups of states that react alike. A human wait belongs to the work it
    # interrupted unless the finalizer asked.
    GROUPS = {
      worker: "Worker states",
      review: "`waiting_for_review`",
      merge: "`ready_to_merge`",
      wait_work: "Wait (work)",
      wait_final: "Wait (finalizer)",
      finalizing: "`finalizing`"
    }.freeze

    # to: the next state; nil keeps the current one. Symbols are resolved
    # against the task (see #target):
    #   :resume                  the state the human wait interrupted
    #   :finalizing_or_done      finalizing; done for a task without an issue
    #   :implementing_or_done    implementing; done for a task without an issue
    #   :continuing_or_keep      continuing; unchanged for a task without an issue
    #   :review_unless_draft     waiting_for_review unless the PR is a draft
    #   :review_or_continuing    waiting_for_review if a PR exists, else continuing
    # resume: for a human wait, the state to return to (:current = the state
    # the task is in when it starts waiting).
    # guard: :new applies only when the condition is newly observed;
    # :new_head applies once per PR head.
    Rule = Data.define(:to, :effects, :resume, :guard) do
      def initialize(to: nil, effects: [], resume: nil, guard: nil) = super
    end

    def self.rule(to = nil, *effects, resume: nil, guard: nil)
      Rule.new(to: to, effects: effects, resume: resume, guard: guard)
    end

    EFFECTS = {
      run_now: "run now",
      retry_later: "retry after `retry_after`",
      no_retry: "wait for an event",
      start_wait: "start waiting",
      clear_wait: "clear the wait",
      reset_review: "forget the last review",
      forget_pr: "forget the PR (tasks with an issue)",
      record_pr: "record the PR",
      cleanup_review: "remove the review workspace",
      cleanup: "remove worktrees",
      abandon_pr: "close the PR, delete the branch and worktrees",
      rework_conflict: "rework: conflict",
      rework_failed_checks: "rework: failed checks",
      request_triage: "triage again"
    }.freeze

    RESULTS = {
      "worker" => {
        "waiting_for_review" => rule("waiting_for_review", :reset_review, :run_now, :request_triage),
        "waiting_for_human_input" => rule("waiting_for_human_input", :start_wait, resume: :current),
        "continue" => rule("continuing", :retry_later),
        "done" => rule("waiting_for_review", :run_now),
        "merged" => rule(:finalizing_or_done, :run_now),
        "deferred" => rule("done", :cleanup, :request_triage),
        "no_pr" => rule("continuing", :retry_later),
        "no_change" => rule(nil, :retry_later),
        "failed" => rule(nil, :retry_later)
      },
      "reviewer" => {
        "branch_updated" => rule(nil, :run_now),
        "merge" => rule("ready_to_merge", :run_now),
        "changes_requested" => rule("changes_requested", :run_now),
        "waiting_for_human_input" => rule("waiting_for_human_input", :start_wait, resume: "waiting_for_review"),
        "waiting_for_human_test" => rule("waiting_for_human_test", :start_wait, resume: "waiting_for_review"),
        "comment" => rule(nil, :retry_later),
        "retry" => rule(nil, :retry_later),
        "already_reviewed" => rule(nil, :retry_later),
        "pr_changed" => rule(nil, :retry_later),
        "failed" => rule(nil, :retry_later)
      },
      "merge" => {
        "pr_changed" => rule("waiting_for_review", :run_now),
        "pending" => rule(nil, :retry_later),
        "manual" => rule(nil, :retry_later),
        "refused" => rule("waiting_for_human_input", :start_wait, resume: "waiting_for_review"),
        "merged" => rule(:finalizing_or_done, :cleanup_review, :request_triage, :run_now)
      },
      "finalizer" => {
        "not_merged" => rule(:review_or_continuing, :retry_later),
        "no_issue" => rule("done", :cleanup),
        "done" => rule("done", :cleanup, :request_triage),
        "waiting_for_human_input" => rule("waiting_for_human_input", :start_wait, resume: "finalizing"),
        "waiting_for_human_test" => rule("waiting_for_human_test", :start_wait, resume: "finalizing"),
        "retry" => rule(nil, :retry_later),
        "failed" => rule(nil, :retry_later)
      }
    }.freeze

    RESULT_NOTES = {
      ["worker", "waiting_for_review"] => "Also for `waiting_for_human_test`: the test request goes to the reviewer",
      ["worker", "done"] => "The PR is open",
      ["worker", "merged"] => "`done` reported and the PR is already merged",
      ["worker", "deferred"] => "The issue's assessment becomes `deferred`",
      ["worker", "no_pr"] => "Ready or done reported, but no PR exists",
      ["worker", "no_change"] => "`continue` without any change to the repository or the PR",
      ["reviewer", "branch_updated"] => "The PR was behind its base and was updated; review the new head",
      ["reviewer", "merge"] => "Approved; with `auto_merge` off a person merges",
      ["reviewer", "comment"] => "Non-blocking; the same head is not reviewed again until something changes",
      ["reviewer", "already_reviewed"] => "Nothing changed since the last review of this head",
      ["reviewer", "pr_changed"] => "The PR changed during the review",
      ["merge", "pr_changed"] => "The PR changed after the review",
      ["merge", "pending"] => "Checks still running, or GitHub has not computed mergeability",
      ["merge", "manual"] => "`auto_merge` is off; wait for a person to merge",
      ["merge", "refused"] => "GitHub refused the merge; ask on the PR with the reason",
      ["finalizer", "not_merged"] => "The PR is not merged after all",
      ["finalizer", "no_issue"] => "A task without an issue has nothing to finish"
    }.freeze

    # Evaluated in this order; the first event with a rule for the task's
    # group is applied. A merge comes before the issue closing, since merging
    # a PR that says "Fixes #N" closes the issue too.
    REACTIONS = [
      ["pr_merged", "PR merged", {
        worker: rule(:finalizing_or_done, :clear_wait, :cleanup_review, :run_now),
        review: rule(:finalizing_or_done, :clear_wait, :cleanup_review, :run_now),
        merge: rule(:finalizing_or_done, :clear_wait, :cleanup_review, :run_now),
        wait_work: rule(:finalizing_or_done, :clear_wait, :cleanup_review, :run_now)
      }],
      ["issue_closed", "Issue closed by someone (tasks ghwatch started)", {
        worker: rule("done", :clear_wait, :abandon_pr),
        review: rule("done", :clear_wait, :abandon_pr),
        merge: rule("done", :clear_wait, :abandon_pr),
        wait_work: rule("done", :clear_wait, :abandon_pr),
        wait_final: rule("done", :clear_wait, :cleanup),
        finalizing: rule("done", :clear_wait, :cleanup)
      }],
      ["pr_closed", "PR closed unmerged", {
        worker: rule(:implementing_or_done, :clear_wait, :forget_pr, :cleanup_review, :run_now),
        review: rule(:implementing_or_done, :clear_wait, :forget_pr, :cleanup_review, :run_now),
        merge: rule(:implementing_or_done, :clear_wait, :forget_pr, :cleanup_review, :run_now),
        wait_work: rule(:implementing_or_done, :clear_wait, :forget_pr, :cleanup_review, :run_now)
      }],
      ["pr_missing", "PR not found", {
        review: rule(:continuing_or_keep, :retry_later),
        merge: rule(:continuing_or_keep, :retry_later),
        wait_work: rule(:continuing_or_keep, :clear_wait, :retry_later),
        finalizing: rule(:continuing_or_keep, :retry_later)
      }],
      ["pr_found", "PR found", {
        worker: rule(:review_unless_draft, :record_pr, :run_now),
        wait_work: rule(nil, :record_pr)
      }],
      ["conflict", "Conflict with the base", {
        worker: rule(nil, :run_now, guard: :new),
        review: rule("changes_requested", :rework_conflict, :reset_review, :run_now),
        merge: rule("changes_requested", :rework_conflict, :reset_review, :run_now),
        wait_work: rule("changes_requested", :clear_wait, :rework_conflict, :reset_review, :run_now)
      }],
      ["checks_failed", "Required checks failed", {
        worker: rule(nil, :run_now, guard: :new),
        merge: rule("changes_requested", :rework_failed_checks, :reset_review, :run_now, guard: :new_head),
        wait_work: rule("changes_requested", :clear_wait, :rework_failed_checks, :reset_review, :run_now, guard: :new_head)
      }],
      ["pushed", "Someone pushed to the PR", {
        worker: rule(nil, :run_now),
        review: rule(nil, :run_now),
        merge: rule("waiting_for_review", :run_now),
        wait_work: rule("waiting_for_review", :clear_wait, :run_now)
      }],
      ["reply", "A person replied after the question (PR or issue)", {
        wait_work: rule(:resume, :clear_wait, :run_now),
        wait_final: rule(:resume, :clear_wait, :run_now)
      }],
      ["activity", "New comment or review by a person", {
        worker: rule(nil, :run_now),
        review: rule(nil, :run_now),
        merge: rule("waiting_for_review", :run_now)
      }]
    ].freeze

    DOC_BEGIN = "<!-- BEGIN GENERATED: rake docs -->"
    DOC_END = "<!-- END GENERATED -->"

    def self.group(task)
      case task.state
      when *WORKER_STATES then :worker
      when "waiting_for_review" then :review
      when "ready_to_merge" then :merge
      when *Task::HUMAN_STATES
        (task.metadata["resume_state"] == "finalizing") ? :wait_final : :wait_work
      when "finalizing" then :finalizing
      end
    end

    def self.reaction(event, group)
      REACTIONS.find { |name, _description, _rules| name == event }&.last&.fetch(group, nil)
    end

    def initialize(github:, config:, worktrees: nil, issue_triage: nil, log: Log.new)
      @github = github
      @config = config
      @worktrees = worktrees
      @issue_triage = issue_triage
      @log = log
    end

    attr_writer :worktrees, :issue_triage

    # Applies what an action decided. Raises for a result the table does not
    # know, so a new result cannot slip through unhandled.
    def apply_result(task, role, result, context = {})
      table = RESULTS.fetch((role == "deep_reviewer") ? "reviewer" : role)
      rule = table.fetch(result) { raise ArgumentError, "no transition for #{role} result #{result.inspect}" }
      apply(task, rule, context)
    end

    # Applies the first event (in table order) that has a rule for the task's
    # group and whose guard holds. Returns the event name, or nil.
    def react(task, events)
      group = self.class.group(task)
      return nil unless group

      REACTIONS.each do |name, _description, rules|
        context = events[name] or next
        rule = rules[group] or next
        next unless guard_holds?(task, rule.guard, context)

        apply(task, rule, context)
        return name
      end
      nil
    end

    def self.markdown
      ["### Results", "", results_markdown, "### Reactions", "", reactions_markdown].join("\n")
    end

    # Rewrites the generated section of an ARCHITECTURE.md text.
    def self.render_into(document)
      pattern = /#{Regexp.escape(DOC_BEGIN)}\n.*?#{Regexp.escape(DOC_END)}/mo
      raise ArgumentError, "missing #{DOC_BEGIN} ... #{DOC_END}" unless document.match?(pattern)

      document.sub(pattern) { "#{DOC_BEGIN}\n#{markdown}#{DOC_END}" }
    end

    def self.results_markdown
      RESULTS.map do |role, rules|
        rows = rules.map do |result, rule|
          note = RESULT_NOTES[[role, result]]
          "| `#{result}` | #{describe(rule)} | #{note} |"
        end
        ["**#{role}**", "", "| Result | Next state and effects | Notes |", "| --- | --- | --- |", *rows, ""].join("\n")
      end.join("\n")
    end

    def self.reactions_markdown
      header = "| Event | #{GROUPS.values.join(" | ")} |"
      divider = "| --- | #{GROUPS.map { "---" }.join(" | ")} |"
      rows = REACTIONS.map do |_name, description, rules|
        cells = GROUPS.keys.map { |group| rules[group] ? describe(rules[group]) : "—" }
        "| #{description} | #{cells.join(" | ")} |"
      end
      [header, divider, *rows, ""].join("\n")
    end

    def self.describe(rule)
      target = case rule.to
      when nil then "unchanged"
      when String then "`#{rule.to}`"
      when :resume then "the interrupted state"
      when :finalizing_or_done then "`finalizing` (no issue: `done`)"
      when :implementing_or_done then "`implementing` (no issue: `done`)"
      when :continuing_or_keep then "`continuing` (no issue: unchanged)"
      when :review_unless_draft then "`waiting_for_review` (draft: unchanged)"
      when :review_or_continuing then "`waiting_for_review` (no PR: `continuing`)"
      end
      resume = case rule.resume
      when nil then nil
      when :current then "resumes the current state"
      else "resumes `#{rule.resume}`"
      end
      guard = {new: "only when newly observed", new_head: "once per PR head"}[rule.guard]
      [target, resume, *rule.effects.map { |effect| EFFECTS.fetch(effect) }, guard].compact.join("; ")
    end

    private

    def guard_holds?(task, guard, context)
      case guard
      when :new then context.fetch(:new, true)
      when :new_head then task.metadata["failed_checks_head"] != context[:head]
      else true
      end
    end

    def apply(task, rule, context)
      resume = (rule.resume == :current) ? task.state : rule.resume
      previous = task.state
      # Decided before the effects, which may clear what it depends on.
      target = target(task, rule.to, context)
      rule.effects.each { |effect| perform(effect, task, context.merge(resume: resume)) }
      if target && target != task.state
        task.state = target
        task.metadata["state_since"] = Time.now.to_i
        @log.info("[#{task.id}] #{previous} -> #{target}")
      end
      task
    end

    def target(task, to, context)
      case to
      when nil, String then to
      when :resume then task.metadata["resume_state"] || "implementing"
      when :finalizing_or_done then (task.issue_number || task.worktree) ? "finalizing" : "done"
      when :implementing_or_done then task.issue_number ? "implementing" : "done"
      when :continuing_or_keep then task.issue_number ? "continuing" : nil
      when :review_unless_draft then context[:draft] ? nil : "waiting_for_review"
      when :review_or_continuing then context[:pull_request] ? "waiting_for_review" : "continuing"
      else raise ArgumentError, "unknown target #{to.inspect}"
      end
    end

    def perform(effect, task, context)
      case effect
      when :run_now then task.retry_at = Time.now.to_i
      when :retry_later then task.schedule_retry(after: @config.retry_after)
      when :no_retry then task.retry_at = nil
      when :start_wait
        task.metadata["resume_state"] = context.fetch(:resume)
        task.retry_at = nil
      when :clear_wait
        task.human_marker = nil
        task.metadata.delete("human_conversation_number")
        task.metadata.delete("resume_state")
      when :reset_review then task.last_review_signature = nil
      when :forget_pr
        # A task without an issue ends with its PR; keep the number on record.
        if task.issue_number
          task.pr_number = nil
          task.last_review_signature = nil
        end
      when :record_pr then task.pr_number = context.fetch(:pr_number)
      when :cleanup_review then @worktrees&.cleanup_review(task)
      when :cleanup then @worktrees&.cleanup(task)
      when :abandon_pr then abandon_pull_request(task)
      when :rework_conflict
        task.metadata["rework_reason"] = "Resolve conflicts with the PR base branch, test, and push updates to the existing PR."
      when :rework_failed_checks
        task.metadata["failed_checks_head"] = context[:head]
        task.metadata["rework_reason"] = "Required CI checks failed on #{context[:head]}: #{Array(context[:failed]).join(", ")}. " \
          "Read their logs, fix the cause, test, and push updates to the existing PR."
      when :request_triage then @issue_triage&.request!
      else raise ArgumentError, "unknown effect #{effect.inspect}"
      end
    end

    # The issue was closed without the work: nothing of it should remain.
    def abandon_pull_request(task)
      if task.pr_number
        @github.close_pull_request(task.pr_number,
          comment: "Closing: the related issue ##{task.issue_number} was closed before this PR was merged.")
      end
      @github.delete_branch(task.branch) if task.branch && task.issue_number
      @worktrees&.cleanup(task)
    rescue => e
      @log.warn("[#{task.id}] could not fully abandon the PR: #{e.message}")
    end
  end
end
