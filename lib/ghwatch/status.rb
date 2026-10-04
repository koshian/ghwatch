# frozen_string_literal: true

require "time"

module Ghwatch
  class Status
    def initialize(state:, io: $stdout)
      @state = state
      @io = io
    end

    def print
      tasks = @state.tasks
      assessments = @state.assessments

      if tasks.empty? && assessments.empty?
        @io.puts("No ghwatch state yet.")
        return
      end

      @io.puts("Tasks")
      @io.puts("-----")
      tasks.each do |task|
        subject = task.issue_number ? "##{task.issue_number}" : "PR ##{task.pr_number}"
        pr = task.pr_number ? " PR ##{task.pr_number}" : ""
        retry_text = task.retry_at ? " retry=#{Time.at(task.retry_at).iso8601}" : ""
        @io.puts(format("%-10s %-24s%s%s", subject, task.state, pr, retry_text))
      end

      ready = assessments.select { |_number, item| %w[ready blocked deferred followup].include?(item[:status]) }
      return if ready.empty?

      @io.puts
      @io.puts("Issue assessments")
      @io.puts("-----------------")
      ready.sort.each do |number, item|
        @io.puts(format("#%-9d %-10s %s", number, item[:status], item[:reason].to_s.lines.first.to_s.strip))
      end
    end
  end
end
