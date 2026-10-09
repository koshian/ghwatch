# frozen_string_literal: true

module Ghwatch
  # Turns what GitHub shows about a task's issue and PR into the events the
  # state machine reacts to. What was seen last time is kept on the task
  # (metadata "observed"), so a push or a comment is reported once, and the
  # task's own work (recorded right after each action) is not mistaken for
  # someone else's.
  class Observer
    def initialize(github:, config:)
      @github = github
      @config = config
    end

    def events(task, snapshot)
      pull_request = snapshot.pull_request
      observed = task.metadata["observed"] || {}
      events = {}

      events["issue_closed"] = {} if issue_closed?(task, snapshot.issue)
      if pull_request
        pull_request_events(task, pull_request, observed, events)
      elsif needs_pull_request?(task)
        events["pr_missing"] = {}
      end
      if task.waiting_for_human? && (answer = reply(task, snapshot))
        events["reply"] = answer
      end
      events["activity"] = {} if activity?(task, snapshot, observed)
      events
    end

    # Remembers what was just seen; called after reacting and after actions.
    # After an action (own_work) the comment id stays where it was when the
    # agent was given the task: a person's comment posted while it ran was
    # never read by it, so it is still news.
    def record(task, snapshot, own_work: false)
      pull_request = snapshot.pull_request
      latest = own_work ? (task.metadata["observed"] || {})["comment_id"] : latest_human_comment_id(snapshot)
      observed = {"comment_id" => latest}
      if pull_request
        observed["head"] = pull_request["headRefOid"]
        observed["conflict"] = conflicting?(pull_request)
        observed["failed"] = failed_checks(pull_request)
      end
      task.metadata["observed"] = observed.compact
    end

    private

    def pull_request_events(task, pull_request, observed, events)
      if pull_request["mergedAt"]
        events["pr_merged"] = {}
      elsif pull_request["state"] == "CLOSED"
        events["pr_closed"] = {}
      end
      events["pr_found"] = {pr_number: pull_request["number"], draft: pull_request["isDraft"]} if task.pr_number.nil?
      return unless pull_request["state"] == "OPEN"

      events["conflict"] = {new: !observed["conflict"]} if conflicting?(pull_request)
      failed = failed_checks(pull_request)
      unless failed.empty?
        events["checks_failed"] = {head: pull_request["headRefOid"], failed: failed, new: observed["failed"] != failed}
      end
      head = pull_request["headRefOid"]
      events["pushed"] = {head: head} if observed["head"] && head && observed["head"] != head
    end

    def conflicting?(pull_request)
      pull_request["mergeable"] == "CONFLICTING" && !pull_request["isDraft"]
    end

    def failed_checks(pull_request)
      return [] unless @config.reviewer_requires_green_checks?

      @github.failed_checks(pull_request).sort
    end

    # Only tasks ghwatch started abandon their work when the issue closes.
    # After the merge, closing counts only when it happened after the task got
    # there: merging a PR that says "Fixes #N" closes the issue by itself.
    def issue_closed?(task, issue)
      return false unless task.issue_number && issue && !task.metadata["external_pr"]
      return false unless issue["state"].to_s.upcase == "CLOSED"
      return true unless %i[wait_final finalizing].include?(StateMachine.group(task))

      since = task.metadata["state_since"]
      closed_at = issue["closedAt"] && Time.parse(issue["closedAt"]).to_i
      since && closed_at && closed_at > since
    end

    def needs_pull_request?(task)
      return true if task.review_state? || task.state == "finalizing"

      task.waiting_for_human? && Task::REVIEW_STATES.include?(task.metadata["resume_state"])
    end

    # A reply is any comment by a person after the question, on the PR or the
    # issue: no agent of this task runs while it waits. A comment posted while
    # the agent that asked was running counts too, since it never saw it.
    # Returns the question and the replies, which the next agent run is given
    # as the answer.
    def reply(task, snapshot)
      return nil unless task.human_marker

      comments = labelled_comments(task, snapshot)
      question = comments.find { |comment| comment.fetch("body", "").include?(task.human_marker.to_s) }
      return nil unless question

      seen = [question.fetch("id").to_i, (task.metadata["observed"] || {})["comment_id"]].compact.min
      replies = comments.select { |comment| comment.fetch("id").to_i > seen && human?(comment) }
      return nil if replies.empty?

      {
        question: {"where" => question["where"], "body" => question["body"]},
        replies: replies.sort_by { |comment| comment.fetch("id").to_i }.map do |comment|
          association = comment["author_association"] || comment["authorAssociation"]
          {"where" => comment["where"], "author" => comment.dig("user", "login") || comment.dig("author", "login"),
           "authorIsMaintainer" => association && Github::MAINTAINER_ASSOCIATIONS.include?(association),
           "createdAt" => comment["created_at"] || comment["createdAt"], "body" => comment["body"]}.compact
        end
      }
    end

    def labelled_comments(task, snapshot)
      issue = Array(snapshot.issue&.fetch("comments", nil)).map { |comment| comment.merge("where" => "issue ##{task.issue_number}") }
      pull_request = Array(snapshot.pull_request&.fetch("comments", nil)).map do |comment|
        comment.merge("where" => "PR ##{snapshot.pull_request["number"]}")
      end
      issue + pull_request
    end

    def activity?(task, snapshot, observed)
      group = StateMachine.group(task)
      if %i[review merge].include?(group) && snapshot.review_signature != task.last_review_signature
        return true
      end
      # A review waits on checks too; the merge step looks at them itself.
      return true if group == :review && task.last_pr_signature && snapshot.pull_request_signature != task.last_pr_signature
      return false unless observed["comment_id"]

      latest = latest_human_comment_id(snapshot)
      latest && latest > observed["comment_id"]
    end

    def latest_human_comment_id(snapshot)
      all_comments(snapshot).select { |comment| human?(comment) }.map { |comment| comment.fetch("id").to_i }.max
    end

    def all_comments(snapshot)
      Array(snapshot.issue&.fetch("comments", nil)) + Array(snapshot.pull_request&.fetch("comments", nil))
    end

    def human?(comment)
      !comment.fetch("body", "").include?(Github::MARKER_PREFIX)
    end
  end
end
