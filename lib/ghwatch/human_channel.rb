# frozen_string_literal: true

module Ghwatch
  class HumanChannel
    def initialize(github:)
      @github = github
    end

    def reply_received?(task)
      return false unless task.human_marker

      conversation = task.metadata["human_conversation_number"] || task.issue_number || task.pr_number
      return false unless conversation

      @github.human_comments_after(conversation, marker: task.human_marker).any?
    end

    def wait(task:, body:, outcome:, kind:, resume_state:, target: :issue)
      if kind == "human-test" && task.issue_number
        target = :issue
        author = @github.issue(task.issue_number).dig("author", "login")
        if author && !body.match?(/@#{Regexp.escape(author)}(?![A-Za-z0-9-])/)
          body = "@#{author}\n\n#{body}"
        end
      end
      conversation = (target == :pull_request) ? task.pr_number : task.issue_number || task.pr_number
      raise "cannot ask a human without an issue or PR" unless conversation

      marker = if target == :issue && task.issue_number
        @github.post_issue_comment(conversation, body, kind: kind, model_signature: outcome.signature)
      else
        @github.post_pr_comment(conversation, body, kind: kind, model_signature: outcome.signature)
      end

      task.human_marker = marker
      task.metadata["human_conversation_number"] = conversation
      task.metadata["resume_state"] = resume_state
      task.state = (kind == "human-test") ? "waiting_for_human_test" : "waiting_for_human_input"
      task.retry_at = nil
      task
    end
  end
end
