# frozen_string_literal: true

module Ghwatch
  class IssueTriage
    def initialize(project:, config:, state:, github:, roles:, worktrees:, context_builder:, log: Log.new)
      @project = project
      @config = config
      @state = state
      @github = github
      @roles = roles
      @worktrees = worktrees
      @context_builder = context_builder
      @log = log
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
      candidates = candidate_issues
      if candidates.empty?
        mark_complete
        return
      end

      details = candidates.map { |summary| @github.issue(summary["number"]) }
      available_slots = available_worker_slots
      previous = details.to_h { |issue| [issue["number"], @state.assessment(issue["number"])] }
      context = @context_builder.triage(
        candidates: details,
        available_slots: available_slots,
        previous_assessments: previous
      )

      outcome = @roles.run("triage", context: context, cwd: @project.root)
      unless outcome.success?
        @log.warn("triage failed; will retry later")
        return
      end

      save_assessments(outcome, details)
      start_selected_issues(outcome, available_slots)
      mark_complete
    end

    private

    def watched_assessments
      @state.assessments.select do |_number, assessment|
        %w[blocked followup].include?(assessment[:status])
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
          signature: @github.issue_signature(issue)
        )
      end
    end

    def should_post_blocker?(status, comment, previous, reason)
      return false unless status == "blocked"
      return false if comment.to_s.strip.empty?

      previous.nil? || previous[:reason] != reason || previous[:comment] != comment
    end

    def start_selected_issues(outcome, available_slots)
      assessments = Array(outcome.data["assessments"])
      selected = Array(outcome.data["selected_issues"]).map(&:to_i).uniq.first(available_slots)

      selected.each do |number|
        assessment = assessments.find { |item| item["issue"].to_i == number }
        next unless assessment && assessment["status"] == "ready"
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
