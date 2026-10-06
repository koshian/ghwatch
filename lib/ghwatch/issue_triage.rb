# frozen_string_literal: true

module Ghwatch
  class IssueTriage
    DISCUSSION_LABEL = "ghwatch:needs-discussion"
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
      @force = true
    end

    def due?
      return true if @force

      last = @state.setting("last_discovery_at").to_i
      Time.now.to_i - last >= @config.discovery_interval
    end

    def request!
      @force = true
      @state.set_setting("last_discovery_at", 0)
    end

    def request_if_watched_issue_changed
      watched_assessments.each do |number, assessment|
        issue = @github.issue(number)
        next if @github.issue_signature(issue) == assessment[:issue_signature]

        @log.info("[issue-#{number}] discussion changed; scheduling triage")
        request!
        break
      rescue => e
        @log.warn("could not refresh watched issue ##{number}: #{e.message}")
      end
    end

    def run
      # Assessments are stamped with when the run started: a PR merged while
      # the model was thinking may not be in what it saw.
      @started_at = Time.now.to_i
      candidates = candidate_issues
      if candidates.empty?
        mark_complete
        return
      end

      details = candidates.map { |summary| @github.issue(summary["number"]) }
      available_slots = available_worker_slots
      previous = details.to_h { |issue| [issue["number"], @state.assessment(issue["number"])] }

      unchanged, changed = details.partition { |issue| unchanged?(issue, previous[issue["number"]]) }
      @log.info("triage: #{unchanged.size} unchanged issue(s) kept as assessed") unless unchanged.empty?
      changed = screen(changed, previous)

      selected = []
      unless changed.empty?
        context = @context_builder.triage(
          candidates: changed,
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

      # Issues already judged ready but not started for lack of a slot.
      ready = unchanged.map { |issue| issue["number"] }.select { |number| previous[number]&.fetch(:status) == "ready" }
      start_issues((selected + ready).uniq.first(available_slots))
      mark_complete
    end

    private

    def unchanged?(issue, previous)
      return false unless previous && previous[:issue_signature] == @github.issue_signature(issue)
      return false if Time.now.to_i - previous[:updated_at].to_i >= @config.reassess_after
      return true unless previous[:status] == "deferred"

      # What a deferred issue waits for is usually a merge elsewhere.
      merged_at = last_merged_at
      merged_at.nil? || merged_at < previous[:updated_at].to_i
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
    def screen(issues, previous)
      return issues unless @screening.enabled? && !issues.empty?

      settled = @screening.settle(issues, open_pull_requests: @github.open_pull_requests, previous: previous)
      issues.reject do |issue|
        number = issue["number"]
        decision = settled[number] or next false

        prior = previous[number]
        reason = (prior && prior[:status] == decision[:status]) ? prior[:reason] : "settled by #{decision[:model]} screening"
        @state.save_assessment(number, status: decision[:status], reason: reason, comment: nil,
          signature: @github.issue_signature(issue), at: assessed_at)
        sync_discussion_label(number, decision[:status], prior)
        true
      end
    end

    def assessed_at = @started_at || Time.now.to_i

    def watched_assessments
      @state.assessments.select do |_number, assessment|
        %w[blocked discussion followup].include?(assessment[:status])
      end
    end

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
          signature: @github.issue_signature(issue),
          at: assessed_at
        )
        sync_discussion_label(number, status, previous)
      end
    end

    def sync_discussion_label(number, status, previous)
      return unless @config.status_labels?

      if status == "discussion"
        @github.add_issue_label(number, DISCUSSION_LABEL, color: "fbca04",
          description: "ghwatch: waiting for a maintainer's decision")
      elsif previous && previous[:status] == "discussion"
        @github.remove_issue_label(number, DISCUSSION_LABEL)
      end
    rescue => e
      @log.warn("[issue-#{number}] could not sync discussion label: #{e.message}")
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

    def mark_complete
      @force = false
      @state.set_setting("last_discovery_at", Time.now.to_i)
    end
  end
end
