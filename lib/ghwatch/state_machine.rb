# frozen_string_literal: true

module Ghwatch
  # The only place that changes a task's state. Actions report what they
  # decided (a result) and the engine reports what happened on GitHub (an
  # event); the tables below say what each one does in each state. The
  # tables are the specification: ARCHITECTURE.md renders them with
  # StateMachine.markdown, and a test keeps the two in step.
  class StateMachine
    WORKER_STATES = Task::WORKER_STATES
    # Rounds of rework a PR may go through (review changes or failed checks;
    # conflicts do not count) and passes a worker may report `continue` in a
    # row, before a person is asked how to go on.
    REWORK_LIMIT = 3
    CONTINUE_LIMIT = 3
    # Each round's reason is kept short; the history only has to show where
    # the rounds went.
    REWORK_SUMMARY_LENGTH = 300

    # Groups of states that react alike. A human wait belongs to the work it
    # interrupted unless the finalizer asked.
    GROUPS = {
      worker: "Worker states",
      review: "`waiting_for_review`",
      checking: "`checking_test_result`",
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
    #   :rework_or_escalate      changes_requested, or after REWORK_LIMIT
    #                            rounds a question to a person on the PR
    #   :continuing_or_escalate  continuing, or after CONTINUE_LIMIT passes in
    #                            a row a question to a person
    # resume: for a human wait, the state to return to (:current = the state
    # the task is in when it starts waiting).
    # guard: :new applies only when the condition is newly observed;
    # :new_head applies once per PR head; :changes_pr applies unless the push
    # only merged the base in, which leaves what a person checked unchanged;
    # :worker_may_push applies unless ghwatch only reviews the PR (someone
    # else's PR, which their author changes). Several guards must all hold.
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
      remember_answer: "give the answer to the next runs",
      clear_wait: "clear the wait",
      reset_review: "forget the last review",
      forget_pr: "forget the PR (tasks with an issue)",
      record_pr: "record the PR",
      cleanup_review: "remove the review workspace",
      cleanup: "remove worktrees",
      abandon_pr: "close the PR, delete the branch and worktrees",
      hand_off: "leave the PR and its branch to them",
      rework_conflict: "rework: conflict",
      rework_failed_checks: "rework: failed checks",
      rework_review: "rework: the latest review",
      count_rework: "count a rework round",
      count_continue: "count a `continue`",
      reset_rounds: "reset the rework and `continue` counts"
    }.freeze

    RESULTS = {
      "worker" => {
        "waiting_for_review" => rule("waiting_for_review", :reset_review, :run_now),
        "waiting_for_human_input" => rule("waiting_for_human_input", :start_wait, resume: :current),
        "continue" => rule(:continuing_or_escalate, :count_continue, :retry_later),
        "done" => rule("waiting_for_review", :run_now),
        "merged" => rule(:finalizing_or_done, :run_now),
        "deferred" => rule("done", :cleanup),
        "no_pr" => rule("continuing", :retry_later),
        "no_change" => rule(nil, :retry_later),
        "not_handed_off" => rule("continuing", :run_now),
        "handoff_failed" => rule("waiting_for_human_input", :start_wait, resume: "waiting_for_review"),
        "failed" => rule(nil, :retry_later)
      },
      "reviewer" => {
        "branch_updated" => rule(nil, :run_now),
        "merge" => rule("ready_to_merge", :run_now),
        "changes_requested" => rule(:rework_or_escalate, :rework_review, :count_rework, :run_now),
        "author_changes" => rule("waiting_for_review", :retry_later),
        "workspace_diverged" => rule("waiting_for_human_input", :start_wait, resume: "waiting_for_review"),
        "waiting_for_human_input" => rule("waiting_for_human_input", :start_wait, resume: "waiting_for_review"),
        "waiting_for_human_test" => rule("waiting_for_human_test", :start_wait, resume: "checking_test_result"),
        "comment" => rule(nil, :retry_later),
        "retry" => rule(nil, :retry_later),
        "already_reviewed" => rule(nil, :retry_later),
        "pr_changed" => rule(nil, :retry_later),
        "failed" => rule(nil, :retry_later)
      },
      "test_judge" => {
        "passed" => rule("ready_to_merge", :run_now),
        "problem" => rule(:rework_or_escalate, :rework_review, :count_rework, :run_now),
        "author_changes" => rule("waiting_for_review", :retry_later),
        "incomplete" => rule("waiting_for_human_test", :start_wait, resume: "checking_test_result"),
        "delegated" => rule("waiting_for_review", :reset_review, :run_now),
        "pr_changed" => rule("waiting_for_review", :run_now),
        "retry" => rule(nil, :retry_later),
        "failed" => rule(nil, :retry_later)
      },
      "merge" => {
        "pr_changed" => rule("waiting_for_review", :run_now),
        "pending" => rule(nil, :retry_later),
        "manual" => rule(nil, :retry_later),
        "refused" => rule("waiting_for_human_input", :start_wait, resume: "waiting_for_review"),
        "checks_failed" => rule("waiting_for_human_input", :start_wait, resume: "waiting_for_review"),
        "merged" => rule(:finalizing_or_done, :cleanup_review, :run_now)
      },
      "finalizer" => {
        "not_merged" => rule(:review_or_continuing, :retry_later),
        "no_issue" => rule("done", :cleanup),
        "done" => rule("done", :cleanup),
        "not_resolved" => rule("done", :cleanup),
        "waiting_for_human_input" => rule("waiting_for_human_input", :start_wait, resume: "finalizing"),
        "waiting_for_human_test" => rule("waiting_for_human_test", :start_wait, resume: "finalizing"),
        "retry" => rule(nil, :retry_later),
        "failed" => rule(nil, :retry_later)
      }
    }.freeze

    RESULT_NOTES = {
      ["worker", "waiting_for_review"] => "Human testing is the reviewer's decision; an older `waiting_for_human_test` result is treated alike",
      ["worker", "done"] => "The PR is open",
      ["worker", "merged"] => "`done` reported and the PR is already merged",
      ["worker", "deferred"] => "The issue's assessment becomes `deferred`",
      ["worker", "no_pr"] => "Ready or done reported, but no PR exists",
      ["worker", "no_change"] => "`continue` without any change to the repository or the PR",
      ["worker", "not_handed_off"] => "Handed to review with tracked changes or unpushed commits left; sent back once to finish",
      ["worker", "handoff_failed"] => "Still not ready to merge as handed over after being sent back; ask on the PR",
      ["reviewer", "branch_updated"] => "The PR was behind its base and was updated; review the new head",
      ["reviewer", "author_changes"] => "Changes requested on a PR ghwatch only reviews; its author makes them",
      ["reviewer", "workspace_diverged"] => "The task worktree cannot follow the PR head without losing something; ask on the PR",
      ["test_judge", "author_changes"] => "The problem remains on a PR ghwatch only reviews; its author fixes it",
      ["reviewer", "merge"] => "Approved; with `auto_merge` off a person merges",
      ["reviewer", "comment"] => "Non-blocking; the same head is not reviewed again until something changes",
      ["reviewer", "already_reviewed"] => "Nothing changed since the last review of this head",
      ["reviewer", "pr_changed"] => "The PR changed during the review",
      ["test_judge", "passed"] => "Everything asked was confirmed, or a maintainer accepted it",
      ["test_judge", "problem"] => "The answer reports that the problem remains",
      ["test_judge", "incomplete"] => "Part of the request is unanswered; ask for that part only",
      ["test_judge", "delegated"] => "The person asked ghwatch to do the check itself; the reviewer does it, with their reply",
      ["test_judge", "pr_changed"] => "The head is not the one the person tested; ghwatch checks this before the judge runs",
      ["merge", "pr_changed"] => "The PR changed after the review",
      ["merge", "pending"] => "Checks still running, or GitHub has not computed mergeability",
      ["merge", "manual"] => "`auto_merge` is off; wait for a person to merge",
      ["merge", "refused"] => "GitHub refused the merge; ask on the PR with the reason",
      ["merge", "checks_failed"] => "Checks failed again after ghwatch reran them once for this head; ask on the PR",
      ["finalizer", "not_merged"] => "The PR is not merged after all",
      ["finalizer", "not_resolved"] => "The merge did not resolve the issue; triage judges it again and new work starts with a new PR",
      ["finalizer", "no_issue"] => "A task without an issue has nothing to finish"
    }.freeze

    # Evaluated in this order; the first event with a rule for the task's
    # group is applied. A merge comes before the issue closing, since merging
    # a PR that says "Fixes #N" closes the issue too.
    REACTIONS = [
      ["pr_merged", "PR merged", {
        worker: rule(:finalizing_or_done, :clear_wait, :reset_rounds, :cleanup_review, :run_now),
        review: rule(:finalizing_or_done, :clear_wait, :reset_rounds, :cleanup_review, :run_now),
        checking: rule(:finalizing_or_done, :clear_wait, :reset_rounds, :cleanup_review, :run_now),
        merge: rule(:finalizing_or_done, :clear_wait, :reset_rounds, :cleanup_review, :run_now),
        wait_work: rule(:finalizing_or_done, :clear_wait, :reset_rounds, :cleanup_review, :run_now)
      }],
      ["issue_closed", "Issue closed by someone (tasks ghwatch started)", {
        worker: rule("done", :clear_wait, :abandon_pr),
        review: rule("done", :clear_wait, :abandon_pr),
        checking: rule("done", :clear_wait, :abandon_pr),
        merge: rule("done", :clear_wait, :abandon_pr),
        wait_work: rule("done", :clear_wait, :abandon_pr),
        wait_final: rule("done", :clear_wait, :cleanup),
        finalizing: rule("done", :clear_wait, :cleanup)
      }],
      ["handed_off", "Someone else took the issue or PR (assigned to them, or labelled `ghwatch:hands-off`)", {
        worker: rule("done", :clear_wait, :hand_off, :cleanup),
        review: rule("done", :clear_wait, :hand_off, :cleanup),
        checking: rule("done", :clear_wait, :hand_off, :cleanup),
        merge: rule("done", :clear_wait, :hand_off, :cleanup),
        wait_work: rule("done", :clear_wait, :hand_off, :cleanup),
        wait_final: rule("done", :clear_wait, :hand_off, :cleanup),
        finalizing: rule("done", :clear_wait, :hand_off, :cleanup)
      }],
      ["pr_closed", "PR closed unmerged", {
        worker: rule(:implementing_or_done, :clear_wait, :reset_rounds, :forget_pr, :cleanup_review, :run_now),
        review: rule(:implementing_or_done, :clear_wait, :reset_rounds, :forget_pr, :cleanup_review, :run_now),
        checking: rule(:implementing_or_done, :clear_wait, :reset_rounds, :forget_pr, :cleanup_review, :run_now),
        merge: rule(:implementing_or_done, :clear_wait, :reset_rounds, :forget_pr, :cleanup_review, :run_now),
        wait_work: rule(:implementing_or_done, :clear_wait, :reset_rounds, :forget_pr, :cleanup_review, :run_now)
      }],
      ["pr_missing", "PR not found", {
        review: rule(:continuing_or_keep, :retry_later),
        checking: rule(:continuing_or_keep, :retry_later),
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
        review: rule("changes_requested", :rework_conflict, :reset_review, :run_now, guard: :worker_may_push),
        checking: rule("changes_requested", :rework_conflict, :reset_review, :run_now, guard: :worker_may_push),
        merge: rule("changes_requested", :rework_conflict, :reset_review, :run_now, guard: :worker_may_push)
      }],
      ["checks_failed", "Required checks failed", {
        worker: rule(nil, :run_now, guard: :new),
        merge: rule(:rework_or_escalate, :rework_failed_checks, :count_rework, :reset_review, :run_now,
          guard: [:new_head, :worker_may_push]),
        wait_work: rule(:rework_or_escalate, :clear_wait, :rework_failed_checks, :count_rework, :reset_review, :run_now,
          guard: [:new_head, :worker_may_push])
      }],
      ["pushed", "Someone pushed to the PR", {
        worker: rule(nil, :run_now),
        review: rule(nil, :run_now),
        checking: rule("waiting_for_review", :run_now, guard: :changes_pr),
        merge: rule("waiting_for_review", :run_now),
        wait_work: rule("waiting_for_review", :clear_wait, :run_now, guard: :changes_pr)
      }],
      ["reply", "A person replied after the question (PR or issue)", {
        wait_work: rule(:resume, :clear_wait, :reset_rounds, :remember_answer, :run_now),
        wait_final: rule(:resume, :clear_wait, :reset_rounds, :remember_answer, :run_now)
      }],
      ["activity", "New comment or review by a person", {
        worker: rule(nil, :run_now),
        review: rule(nil, :run_now),
        merge: rule("waiting_for_review", :run_now)
      }]
    ].freeze

    # Effects that say why a PR goes back to the worker.
    REASON_EFFECTS = %i[rework_review rework_conflict rework_failed_checks].freeze

    DOC_BEGIN = "<!-- BEGIN GENERATED: rake docs -->"
    DOC_END = "<!-- END GENERATED -->"

    def self.group(task)
      case task.state
      when *WORKER_STATES then :worker
      when "waiting_for_review" then :review
      when "checking_test_result" then :checking
      when "ready_to_merge" then :merge
      when *Task::HUMAN_STATES
        (task.metadata["resume_state"] == "finalizing") ? :wait_final : :wait_work
      when "finalizing" then :finalizing
      end
    end

    def self.reaction(event, group)
      REACTIONS.find { |name, _description, _rules| name == event }&.last&.fetch(group, nil)
    end

    def initialize(github:, config:, worktrees: nil, human_channel: nil, log: Log.new)
      @github = github
      @config = config
      @worktrees = worktrees
      @human_channel = human_channel
      @log = log
    end

    attr_writer :worktrees, :human_channel

    # Applies what an action decided. Raises for a result the table does not
    # know, so a new result cannot slip through unhandled.
    def apply_result(task, role, result, context = {})
      table = RESULTS.fetch((role == "deep_reviewer") ? "reviewer" : role)
      rule = table.fetch(result) { raise ArgumentError, "no transition for #{role} result #{result.inspect}" }
      # Only an unbroken run of `continue` counts.
      task.metadata.delete("continue_streak") if role == "worker" && result != "continue"
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
      when :resume then "the interrupted state (`waiting_for_review` for a worker state on a PR ghwatch only reviews)"
      when :finalizing_or_done then "`finalizing` (no issue: `done`)"
      when :implementing_or_done then "`implementing` (no issue: `done`)"
      when :continuing_or_keep then "`continuing` (no issue: unchanged)"
      when :review_unless_draft then "`waiting_for_review` (draft: unchanged)"
      when :review_or_continuing then "`waiting_for_review` (no PR: `continuing`)"
      when :rework_or_escalate then "`changes_requested` (after #{REWORK_LIMIT} rounds: ask a person, resuming `changes_requested`)"
      when :continuing_or_escalate then "`continuing` (after #{CONTINUE_LIMIT} in a row: ask a person, resuming `continuing`)"
      end
      resume = case rule.resume
      when nil then nil
      when :current then "resumes the current state"
      else "resumes `#{rule.resume}`"
      end
      guards = {new: "only when newly observed", new_head: "once per PR head",
                changes_pr: "unless only the base was merged in", worker_may_push: "not for PRs ghwatch only reviews"}
      guard = Array(rule.guard).map { |each| guards.fetch(each) }
      [target, resume, *rule.effects.map { |effect| EFFECTS.fetch(effect) }, *guard].compact.join("; ")
    end

    # One line per round in the order they happened, for agents and people.
    def self.rework_history_lines(task, japanese: false)
      sources = japanese ? {"review" => "レビュー", "test" => "テスト結果", "checks" => "CI"} : {}
      Array(task.metadata["rework_history"]).map do |round|
        source = sources.fetch(round["source"], round["source"])
        summary = round["summary"] || (japanese ? "(要約なし)" : "(no summary)")
        "#{round["round"]}. #{source}: #{summary}"
      end
    end

    # The newest reviewer's view of the round: whether the issue's own problem
    # is solved, and what simpler course it sees.
    def self.rework_outlook(task)
      history = Array(task.metadata["rework_history"])
      solved = history.reverse.find { |round| round.key?("main_problem_solved") }&.fetch("main_problem_solved")
      simplify = history.filter_map { |round| round["simplify"] }.uniq
      [solved, simplify]
    end

    private

    def guard_holds?(task, guard, context)
      return guard.all? { |each| guard_holds?(task, each, context) } if guard.is_a?(Array)

      case guard
      when :new then context.fetch(:new, true)
      when :new_head then task.metadata["failed_checks_head"] != context[:head]
      when :changes_pr then !same_changes?(task, context)
      when :worker_may_push then !task.metadata["review_only"]
      else true
      end
    end

    def same_changes?(task, context)
      return false unless @worktrees

      @worktrees.same_changes?(task, base: context[:base], from: context[:from], to: context[:head])
    rescue => e
      @log.warn("[#{task.id}] could not compare the PR's changes; taking the push as a change: #{e.message}")
      false
    end

    def apply(task, rule, context)
      resume = (rule.resume == :current) ? task.state : rule.resume
      previous = task.state
      # Decided before the effects, which may clear what it depends on.
      target = target(task, rule.to, context)
      if target == :escalate
        # The question says why the work went back this time.
        (rule.effects & REASON_EFFECTS).each { |effect| perform(effect, task, context) }
        record_rework(task, context) if rule.effects.include?(:count_rework)
        return escalate(task, rule.to, previous)
      end

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
      when :resume
        resume = task.metadata["resume_state"] || "implementing"
        # A worker never takes up a PR ghwatch only reviews.
        (task.metadata["review_only"] && WORKER_STATES.include?(resume)) ? "waiting_for_review" : resume
      when :finalizing_or_done then (task.issue_number || task.worktree) ? "finalizing" : "done"
      when :implementing_or_done then task.issue_number ? "implementing" : "done"
      when :continuing_or_keep then task.issue_number ? "continuing" : nil
      when :review_unless_draft then context[:draft] ? nil : "waiting_for_review"
      when :review_or_continuing then context[:pull_request] ? "waiting_for_review" : "continuing"
      when :rework_or_escalate then (task.metadata["rework_rounds"].to_i >= REWORK_LIMIT) ? :escalate : "changes_requested"
      when :continuing_or_escalate then (task.metadata["continue_streak"].to_i + 1 >= CONTINUE_LIMIT) ? :escalate : "continuing"
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
        task.metadata.delete("human_answer")
        task.retry_at = nil
      when :remember_answer
        task.metadata["human_answer"] = {"question" => context[:question], "replies" => context[:replies]}
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
      # The PR is not reviewed or picked up again; its branch stays on GitHub.
      when :hand_off then task.metadata["handed_off"] = true
      when :rework_conflict
        task.metadata["rework_reason"] = "Resolve conflicts with the PR base branch, test, and push updates to the existing PR."
      # The review on the PR says what to change; an older reason (a conflict
      # long resolved) must not linger.
      when :rework_review then task.metadata.delete("rework_reason")
      when :rework_failed_checks
        task.metadata["failed_checks_head"] = context[:head]
        task.metadata["rework_reason"] = "Required CI checks failed on #{context[:head]}: #{Array(context[:failed]).join(", ")}. " \
          "Read their logs, fix the cause, test, and push updates to the existing PR."
      when :count_rework
        task.metadata["rework_rounds"] = task.metadata["rework_rounds"].to_i + 1
        record_rework(task, context)
      when :count_continue then task.metadata["continue_streak"] = task.metadata["continue_streak"].to_i + 1
      when :reset_rounds
        task.metadata.delete("rework_rounds")
        task.metadata.delete("rework_history")
        task.metadata.delete("continue_streak")
      else raise ArgumentError, "unknown effect #{effect.inspect}"
      end
    end

    # Why the PR went back this time. Reviewers and the test judge pass their
    # view as context[:rework]; failed checks are named by the event.
    def record_rework(task, context)
      entry = context[:rework] || {}
      entry = {"source" => "checks", "summary" => "Required CI checks failed: #{Array(context[:failed]).join(", ")}"} if context.key?(:failed)
      history = Array(task.metadata["rework_history"])
      summary = entry["summary"].to_s.strip.gsub(/\s+/, " ")
      summary = "#{summary[0, REWORK_SUMMARY_LENGTH]} …" if summary.length > REWORK_SUMMARY_LENGTH
      task.metadata["rework_history"] = history + [{
        "round" => history.size + 1,
        "source" => entry["source"] || "review",
        "summary" => summary.empty? ? nil : summary,
        "main_problem_solved" => [true, false].include?(entry["main_problem_solved"]) ? entry["main_problem_solved"] : nil,
        "simplify" => entry["simplify"].to_s.strip.empty? ? nil : entry["simplify"].to_s.strip
      }.compact]
    end

    # Too many rounds without converging: a person decides how to go on. The
    # counts are reset when they reply, so they get a fresh set of rounds.
    def escalate(task, to, previous)
      rework = to == :rework_or_escalate
      resume = rework ? "changes_requested" : "continuing"
      if @human_channel
        @human_channel.wait(task: task, body: escalation_message(task, rework), outcome: Struct.new(:signature).new("ghwatch"),
          kind: "human-question", target: task.pr_number ? :pull_request : :issue)
      else
        @log.warn("[#{task.id}] cannot ask a person: no human channel")
      end
      task.metadata["resume_state"] = resume
      task.retry_at = nil
      task.state = "waiting_for_human_input"
      task.metadata["state_since"] = Time.now.to_i
      @log.info("[#{task.id}] #{previous} -> waiting_for_human_input (#{rework ? "#{REWORK_LIMIT} rework rounds" : "#{CONTINUE_LIMIT} continues"} reached)")
      task
    end

    def escalation_message(task, rework)
      japanese = @config.respond_to?(:human_language) && @config.human_language.to_s.start_with?("ja")
      reason = task.metadata["rework_reason"] || (japanese ? "直前のレビュー" : "the latest review")
      if rework
        history = self.class.rework_history_lines(task, japanese: japanese)
        solved, simplify = self.class.rework_outlook(task)
        if japanese
          message = "このPRはレビューやCIの指摘で #{REWORK_LIMIT} 回ワーカーに差し戻されましたが、まだ収束していません。" \
            "このまま続けるか、方針を変えるか、PRを閉じるかを判断してください。返信すると、差し戻しの回数を数え直して作業を再開します。" \
            "\n\n最後の差し戻しの理由: #{reason}"
          message += "\n\n差し戻しの経緯:\n#{history.join("\n")}" unless history.empty?
          message += "\n\n本題(Issue の問題)は、レビュアーの見立てでは#{solved ? "解決済みです" : "まだ解決していません"}。" unless solved.nil?
          message += "\n\n単純化の候補:\n#{simplify.map { |idea| "- #{idea}" }.join("\n")}" unless simplify.empty?
        else
          message = "This PR went back to the worker #{REWORK_LIMIT} times for review changes or failed checks and has not converged. " \
            "Please decide whether to continue, change the approach, or close the PR. A reply resumes the work with a fresh count." \
            "\n\nLast reason: #{reason}"
          message += "\n\nRework rounds:\n#{history.join("\n")}" unless history.empty?
          message += "\n\nAs the reviewer sees it, the issue's own problem is #{solved ? "solved" : "not solved yet"}." unless solved.nil?
          message += "\n\nWays to simplify:\n#{simplify.map { |idea| "- #{idea}" }.join("\n")}" unless simplify.empty?
        end
        message
      elsif japanese
        "ワーカーが #{CONTINUE_LIMIT} 回続けて「作業継続」を報告し、終わりが見えません。このまま続けるか、方針を示すかを判断してください。返信すると作業を再開します。"
      else
        "The worker reported `continue` #{CONTINUE_LIMIT} times in a row without finishing. " \
          "Please decide whether it should go on or give it direction. A reply resumes the work."
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
