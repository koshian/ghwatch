# frozen_string_literal: true

module Ghwatch
  class StatusLabels
    STATES = (Task::WORKER_STATES + Task::REVIEW_STATES + Task::HUMAN_STATES + ["finalizing", "done"]).freeze
    LABELS = STATES.to_h { |state| [state, "ghwatch:#{state.tr("_", "-")}"] }.freeze

    def initialize(state:, github:, config:, log: Log.new)
      @state = state
      @github = github
      @config = config
      @log = log
      @synced = {}
    end

    def sync_all
      @synced.clear
      @state.tasks.select(&:issue_number).group_by(&:issue_number).each_value do |tasks|
        sync(tasks.last)
      end
    end

    def sync(task)
      return unless @config.status_labels? && task.issue_number

      active = @state.tasks.reverse.find { |candidate| candidate.issue_number == task.issue_number && !candidate.done? }
      status = (active || task).state
      return if @synced[task.issue_number] == status

      @github.sync_issue_state_label(task.issue_number, label: LABELS.fetch(status),
        managed_labels: LABELS.values, color: color_for(status), description: "ghwatch task state: #{status}")
      @synced[task.issue_number] = status
    rescue => e
      @log.warn("[issue-#{task.issue_number}] could not sync status label: #{e.message}")
    end

    private

    def color_for(state)
      return "d876e3" if Task::HUMAN_STATES.include?(state)
      return "0e8a16" if state == "done"

      "1d76db"
    end
  end
end
