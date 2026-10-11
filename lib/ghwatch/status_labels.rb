# frozen_string_literal: true

module Ghwatch
  class StatusLabels
    STATES = (Task::WORKER_STATES + Task::REVIEW_STATES + Task::HUMAN_STATES + ["finalizing", "done"]).freeze
    LABELS = STATES.to_h { |state| [state, "ghwatch:#{state.tr("_", "-")}"] }.freeze
    # The label a PR carries for each task state, from the same set as issues.
    # Merged or closed PRs (finalizing, done) carry none.
    PR_STATES = {
      "implementing" => "implementing",
      "continuing" => "changes_requested",
      "changes_requested" => "changes_requested",
      "waiting_for_review" => "waiting_for_review",
      "checking_test_result" => "checking_test_result",
      "ready_to_merge" => "ready_to_merge",
      "waiting_for_human_input" => "waiting_for_human_input",
      "waiting_for_human_test" => "waiting_for_human_test"
    }.freeze
    # An open issue without an active task carries what triage decided, or
    # that it was not judged yet, so no issue is left without a reason.
    TRIAGE_LABELS = {
      "ready" => ["ghwatch:ready", "0e8a16", "ghwatch triage: ready; starts when a worker is free"],
      "blocked" => ["ghwatch:blocked", "d876e3", "ghwatch triage: needs information or a decision from a person"],
      "discussion" => ["ghwatch:needs-discussion", "fbca04", "ghwatch: waiting for a maintainer's decision"],
      "deferred" => ["ghwatch:deferred", "c5def5", "ghwatch triage: waits for another PR, issue or release"],
      "followup" => ["ghwatch:followup", "c5def5", "ghwatch triage: waits for a person to verify, release or reply"],
      "skip" => ["ghwatch:skip", "c5def5", "ghwatch triage: declined or needs no work"],
      nil => ["ghwatch:untriaged", "ededed", "ghwatch has not judged this issue yet"]
    }.freeze
    MANAGED = (LABELS.values + TRIAGE_LABELS.values.map(&:first)).uniq.freeze

    def initialize(state:, github:, config:, log: Log.new)
      @state = state
      @github = github
      @config = config
      @log = log
      @synced = {}
      @labelled_prs = {}
    end

    def sync_all
      return unless @config.status_labels?

      @synced.clear
      tasks = @state.tasks
      open_issues.each { |issue| sync_issue_number(issue["number"], current: issue["labels"]) }
      tasks.filter_map(&:issue_number).uniq.each { |number| sync_issue_number(number) }
      tasks.select(&:pr_number).reject(&:done?).group_by(&:pr_number).each_value { |group| sync_pull_request(group.last) }
    end

    def sync_assessment(number)
      return unless @config.status_labels?

      sync_issue_number(number)
    end

    def sync(task)
      return unless @config.status_labels?

      sync_issue_number(task.issue_number) if task.issue_number
      sync_pull_request(task)
    end

    private

    def open_issues
      @github.open_issues
    rescue => e
      @log.warn("could not list open issues for status labels: #{e.message}")
      []
    end

    # current: the issue's labels when already known, to skip a write that
    # would change nothing.
    def sync_issue_number(number, current: nil)
      label, color, description = issue_label(number)
      return if @synced[number] == label

      names = current&.map { |item| item.is_a?(Hash) ? item["name"] : item }
      unless names && (names & MANAGED) == [label]
        @github.sync_issue_state_label(number, label: label, managed_labels: MANAGED, color: color, description: description)
      end
      @synced[number] = label
    rescue => e
      @log.warn("[issue-#{number}] could not sync status label: #{e.message}")
    end

    # An active task shows its state. Otherwise the newer of the last task's
    # end and the triage assessment wins: triage judges an issue again after
    # its task, and a task started from an assessment ends after it.
    def issue_label(number)
      tasks = @state.tasks.select { |task| task.issue_number == number }
      active = tasks.reverse.find { |task| !task.done? }
      return task_label(active.state) if active

      last = tasks.last
      assessment = @state.assessment(number)
      if assessment && (last.nil? || assessment[:updated_at].to_i >= last.metadata["state_since"].to_i)
        TRIAGE_LABELS.fetch(assessment[:status], TRIAGE_LABELS[nil])
      elsif last
        task_label(last.state)
      else
        TRIAGE_LABELS[nil]
      end
    end

    def task_label(state) = [LABELS.fetch(state), color_for(state), "ghwatch task state: #{state}"]

    def sync_pull_request(task)
      previous = @labelled_prs[task.id]
      # A task that moved to another PR (or lost its PR) leaves the old one.
      label_pull_request(previous, nil) if previous && previous != task.pr_number
      @labelled_prs[task.id] = task.pr_number
      return unless task.pr_number

      active = @state.tasks.reverse.find { |candidate| candidate.pr_number == task.pr_number && !candidate.done? }
      label_pull_request(task.pr_number, PR_STATES[(active || task).state])
    end

    def label_pull_request(number, status)
      key = "pr-#{number}"
      return if @synced.key?(key) && @synced[key] == status

      @github.sync_issue_state_label(number, label: status && LABELS.fetch(status), managed_labels: MANAGED,
        color: color_for(status.to_s), description: "ghwatch task state: #{status}")
      @synced[key] = status
    rescue => e
      @log.warn("[pr-#{number}] could not sync status label: #{e.message}")
    end

    def color_for(state)
      return "d876e3" if Task::HUMAN_STATES.include?(state)
      return "0e8a16" if state == "done"

      "1d76db"
    end
  end
end
