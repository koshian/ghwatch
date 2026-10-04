# frozen_string_literal: true

module Ghwatch
  class ReviewIntake
    def initialize(config:, state:, github:, log: Log.new)
      @config = config
      @state = state
      @github = github
      @log = log
    end

    def discover
      return unless @config.review_all_open_prs?

      @github.open_pull_requests.each do |summary|
        next if summary["isDraft"]
        next if @state.task_for_pr(summary["number"])

        pull_request = @github.pull_request(summary["number"])
        task = Task.for_pr(summary["number"], branch: summary["headRefName"])
        task.last_pr_signature = @github.pr_signature(pull_request)
        task.retry_at = Time.now.to_i
        @state.save_task(task)
        @log.info("[#{task.id}] discovered open PR for review")
      end
    end
  end
end
