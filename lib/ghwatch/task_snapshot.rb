# frozen_string_literal: true

module Ghwatch
  class TaskSnapshot
    attr_reader :issue, :pull_request, :issue_signature, :pull_request_signature, :review_signature

    def self.capture(task:, github:)
      issue = task.issue_number && github.issue(task.issue_number)
      pull_request = find_pull_request(task, github)

      new(
        issue: issue,
        pull_request: pull_request,
        issue_signature: issue && github.issue_signature(issue),
        pull_request_signature: pull_request && github.pr_signature(pull_request),
        review_signature: pull_request && github.review_signature(pull_request)
      )
    end

    def self.find_pull_request(task, github)
      return github.pull_request(task.pr_number) if task.pr_number
      return nil unless task.branch

      summary = github.pull_request_for_branch(task.branch)
      summary && github.pull_request(summary["number"])
    end

    def initialize(issue:, pull_request:, issue_signature:, pull_request_signature:, review_signature:)
      @issue = issue
      @pull_request = pull_request
      @issue_signature = issue_signature
      @pull_request_signature = pull_request_signature
      @review_signature = review_signature
    end
  end
end
