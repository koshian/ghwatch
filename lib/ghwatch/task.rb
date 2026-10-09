# frozen_string_literal: true

require "json"

module Ghwatch
  class Task
    WORKER_STATES = %w[implementing changes_requested continuing].freeze
    REVIEW_STATES = %w[waiting_for_review checking_test_result ready_to_merge].freeze
    HUMAN_STATES = %w[waiting_for_human_input waiting_for_human_test].freeze
    TERMINAL_STATES = %w[done].freeze

    ATTRIBUTES = %i[
      id issue_number pr_number state branch worktree last_issue_signature
      last_pr_signature last_review_signature human_marker retry_at attempts
      last_model last_error metadata
    ].freeze

    attr_accessor(*ATTRIBUTES)

    def self.for_issue(number, branch:, worktree:)
      new(
        id: "issue-#{number}",
        issue_number: number,
        state: "implementing",
        branch: branch,
        worktree: worktree,
        attempts: 0,
        metadata: {}
      )
    end

    def self.for_pr(number, branch: nil)
      new(
        id: "pr-#{number}",
        pr_number: number,
        state: "waiting_for_review",
        branch: branch,
        attempts: 0,
        metadata: {"external_pr" => true}
      )
    end

    def self.from_row(row)
      new(
        id: row[:id],
        issue_number: row[:issue_number],
        pr_number: row[:pr_number],
        state: row[:state],
        branch: row[:branch],
        worktree: row[:worktree],
        last_issue_signature: row[:last_issue_signature],
        last_pr_signature: row[:last_pr_signature],
        last_review_signature: row[:last_review_signature],
        human_marker: row[:human_marker],
        retry_at: row[:retry_at],
        attempts: row[:attempts],
        last_model: row[:last_model],
        last_error: row[:last_error],
        metadata: JSON.parse(row[:metadata_json] || "{}")
      )
    end

    def initialize(**attributes)
      ATTRIBUTES.each { |attribute| public_send("#{attribute}=", attributes[attribute]) }
      self.metadata ||= {}
      self.attempts ||= 0
    end

    def to_row
      {
        id: id,
        issue_number: issue_number,
        pr_number: pr_number,
        state: state,
        branch: branch,
        worktree: worktree,
        last_issue_signature: last_issue_signature,
        last_pr_signature: last_pr_signature,
        last_review_signature: last_review_signature,
        human_marker: human_marker,
        retry_at: retry_at,
        attempts: attempts,
        last_model: last_model,
        last_error: last_error,
        metadata_json: JSON.generate(metadata)
      }
    end

    def uses_worker_slot?
      WORKER_STATES.include?(state)
    end

    def review_state?
      REVIEW_STATES.include?(state)
    end

    def waiting_for_human?
      HUMAN_STATES.include?(state)
    end

    def done?
      TERMINAL_STATES.include?(state)
    end

    def retry_due?(now = Time.now.to_i)
      retry_at && retry_at <= now
    end

    def schedule_retry(after:)
      self.retry_at = Time.now.to_i + after
    end

    def clear_retry
      self.retry_at = nil
      self.last_error = nil
    end

    def transition_to(new_state, retry_at: nil)
      self.state = new_state
      self.retry_at = retry_at
      self
    end
  end
end
