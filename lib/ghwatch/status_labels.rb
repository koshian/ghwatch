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
      "waiting_for_re_review" => "waiting_for_review",
      "ready_to_merge" => "ready_to_merge",
      "waiting_for_human_input" => "waiting_for_human_input",
      "waiting_for_human_test" => "waiting_for_human_test"
    }.freeze

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
      tasks.select(&:issue_number).group_by(&:issue_number).each_value { |group| sync_issue(group.last) }
      tasks.select(&:pr_number).reject(&:done?).group_by(&:pr_number).each_value { |group| sync_pull_request(group.last) }
    end

    def sync(task)
      return unless @config.status_labels?

      sync_issue(task) if task.issue_number
      sync_pull_request(task)
    end

    private

    def sync_issue(task)
      active = @state.tasks.reverse.find { |candidate| candidate.issue_number == task.issue_number && !candidate.done? }
      status = (active || task).state
      return if @synced[task.issue_number] == status

      @github.sync_issue_state_label(task.issue_number, label: LABELS.fetch(status),
        managed_labels: LABELS.values, color: color_for(status), description: "ghwatch task state: #{status}")
      @synced[task.issue_number] = status
    rescue => e
      @log.warn("[issue-#{task.issue_number}] could not sync status label: #{e.message}")
    end

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

      @github.sync_issue_state_label(number, label: status && LABELS.fetch(status), managed_labels: LABELS.values,
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
