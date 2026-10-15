# frozen_string_literal: true

module Ghwatch
  class IssueTriage
    QUESTION_STATUSES = %w[blocked discussion].freeze
    def initialize(project:, config:, state:, github:, roles:, worktrees:, context_builder:, log: Log.new, screening: nil)
      @project = project
      @config = config
      @state = state
      @github = github
      @roles = roles
      @worktrees = worktrees
      @context_builder = context_builder
      @log = log
      @screening = screening || IssueScreening.new(config: config, log: log)
    end

    # Runs whenever ghwatch has nothing else to do: issues are looked for
    # when a worker can take one, and only those that changed since they
    # were last judged reach a model.
    def run
      available_slots = available_worker_slots
      return if available_slots.zero?

      # Assessments are stamped with when the run started: a PR merged while
      # the model was thinking may not be in what it saw.
      @started_at = Time.now.to_i
      # The latest merge is read once per run; the triage object lives as
      # long as ghwatch does.
      remove_instance_variable(:@last_merged_at) if defined?(@last_merged_at)
      @done_at = nil
      candidates = candidate_issues
      return if candidates.empty?

      previous = candidates.to_h { |summary| [summary["number"], @state.assessment(summary["number"])] }
      # The issue list says when each issue last changed; one unchanged since
      # it was judged need not be read again.
      quiet, maybe = candidates.partition do |summary|
        assessment = previous[summary["number"]]
        assessment && summary["updatedAt"] && assessment[:issue_updated_at] == summary["updatedAt"] &&
          current?(summary["number"], assessment)
      end
      details = maybe.map { |summary| @github.issue(summary["number"]) }
      relabeled, changed = details.partition { |issue| unchanged?(issue, previous[issue["number"]]) }
      relabeled.each do |issue|
        @state.touch_assessment(issue["number"], signature: @github.issue_content_signature(issue), issue_updated_at: issue["updatedAt"])
      end
      unchanged = quiet.map { |summary| summary["number"] } + relabeled.map { |issue| issue["number"] }
      return start_issues(ready_numbers(unchanged, previous).first(available_slots)) if changed.empty?

      @log.info("triage: #{changed.size} changed issue(s); #{unchanged.size} kept as assessed")
      references = IssueReferences.new(lookup: ->(number) { @github.reference(number) }, log: @log)
      changed = screen(changed, previous, references)

      selected = []
      unless changed.empty?
        context = @context_builder.triage(
          candidates: changed.map { |issue| issue.merge("referenced" => references.for(issue)) },
          available_slots: available_slots,
          previous_assessments: changed.to_h { |issue| [issue["number"], previous[issue["number"]]] }
        )
        outcome = @roles.run("triage", context: context, cwd: @project.root)
        unless outcome.success?
          @log.warn("triage failed; will retry later")
          return
        end

        save_assessments(outcome, changed)
        selected = selected_issues(outcome)
      end

      # Issues already judged ready but not started for lack of a slot, and
      # the ones just selected, start oldest first; the model only decides
      # which are ready, not the order.
      start_issues((ready_numbers(unchanged, previous) + selected).uniq.sort.first(available_slots))
    end

    private

    def unchanged?(issue, previous)
      return false unless previous && previous[:issue_signature] == @github.issue_content_signature(issue)

      current?(issue["number"], previous)
    end

    # Whether an assessment still holds for an issue that did not change.
    def current?(number, previous)
      assessed = previous[:updated_at].to_i
      return false if Time.now.to_i - assessed >= @config.reassess_after
      # Its task finished since, yet the issue is open: reopened, or waiting
      # for a person to verify.
      return false if done_at[number].to_i > assessed
      return true unless previous[:status] == "deferred"

      # What a deferred issue waits for is usually a merge elsewhere.
      merged_at = last_merged_at
      merged_at.nil? || merged_at < assessed
    end

    def done_at
      @done_at ||= @state.tasks.select { |task| task.done? && task.issue_number }.each_with_object({}) do |task, times|
        times[task.issue_number] = [times[task.issue_number].to_i, task.metadata["state_since"].to_i].max
      end
    end

    def ready_numbers(numbers, previous)
      numbers.select { |number| previous[number]&.fetch(:status) == "ready" }.sort
    end

    def last_merged_at
      return @last_merged_at if defined?(@last_merged_at)

      @last_merged_at = begin
        @github.last_merged_at
      rescue => e
        @log.warn("could not read the latest merge time: #{e.message}")
        Time.now.to_i
      end
    end

    # Saves what the decision model settles and returns the rest.
    def screen(issues, previous, references)
      return issues unless @screening.enabled? && !issues.empty?

      settled = @screening.settle(issues, open_pull_requests: @github.open_pull_requests, previous: previous,
        references: references)
      issues.reject do |issue|
        number = issue["number"]
        decision = settled[number] or next false

        prior = previous[number]
        reason = (prior && prior[:status] == decision[:status]) ? prior[:reason] : "settled by #{decision[:model]} screening"
        @state.save_assessment(number, status: decision[:status], reason: reason, comment: nil,
          signature: @github.issue_content_signature(issue), at: assessed_at, issue_updated_at: issue["updatedAt"])
        true
      end
    end

    def assessed_at = @started_at || Time.now.to_i

    def candidate_issues
      active_issue_numbers = @state.tasks.reject(&:done?).filter_map(&:issue_number)
      candidates = @github.open_issues.reject do |issue|
        active_issue_numbers.include?(issue["number"])
      end

      candidates.first(@config.candidate_limit)
    end

    def available_worker_slots
      used = @state.tasks.count { |task| !task.done? && task.uses_worker_slot? }
      [@config.max_workers - used, 0].max
    end

    def save_assessments(outcome, details)
      details_by_number = details.to_h { |issue| [issue["number"], issue] }

      Array(outcome.data["assessments"]).each do |assessment|
        number = assessment["issue"].to_i
        issue = details_by_number[number]
        next unless issue

        previous = @state.assessment(number)
        status = assessment["status"].to_s
        reason = assessment["reason"].to_s
        comment = assessment["comment"]&.to_s
        if status == "discussion" && assessment["concern"] == "harmful" && @config.harmful_issues == "skip"
          status = "skip"
          reason = "harmful request skipped by configuration: #{reason}"
          comment = nil
        end

        if should_post_blocker?(status, comment, previous, reason)
          @github.post_issue_comment(
            number,
            comment,
            kind: "triage-question",
            model_signature: outcome.signature
          )
          issue = @github.issue(number)
        end

        @state.save_assessment(
          number,
          status: status,
          reason: reason,
          comment: comment,
          signature: @github.issue_content_signature(issue),
          at: assessed_at,
          issue_updated_at: issue["updatedAt"]
        )
      end
    end

    def should_post_blocker?(status, comment, previous, reason)
      return false unless QUESTION_STATUSES.include?(status)
      return false if comment.to_s.strip.empty?

      previous.nil? || previous[:reason] != reason || previous[:comment] != comment
    end

    def selected_issues(outcome)
      assessments = Array(outcome.data["assessments"])
      Array(outcome.data["selected_issues"]).map(&:to_i).uniq.select do |number|
        assessments.any? { |item| item["issue"].to_i == number && item["status"] == "ready" }
      end
    end

    def start_issues(numbers)
      numbers.each do |number|
        next if @state.task_for_issue(number)

        start_issue(number)
      end
    end

    def start_issue(number)
      branch, worktree = @worktrees.prepare(number)
      task = Task.for_issue(number, branch: branch, worktree: worktree)
      task.retry_at = Time.now.to_i
      @state.save_task(task)
      @log.info("[#{task.id}] selected for implementation")
    rescue => e
      @log.error("could not start issue ##{number}: #{e.message}")
    end
  end
end
