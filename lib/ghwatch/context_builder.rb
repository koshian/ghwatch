# frozen_string_literal: true

require "json"

module Ghwatch
  class ContextBuilder
    def initialize(config:)
      @config = config
    end

    def triage(candidates:, available_slots:, previous_assessments:)
      <<~TEXT
        You are triaging GitHub issues for autonomous work.

        Available autonomous worker slots: #{available_slots}

        Assess every candidate independently. `ready` means enough is known to implement now.
        Do not mark an issue blocked merely because it is large; blocked is specifically for
        missing human information or a human decision. Use deferred when the issue explicitly
        waits for a future dependency, upgrade, release, external event, or other condition.
        Do not ask humans to repeat decisions already present in the issue discussion.

        Previous assessments may be stale; re-evaluate them against the current discussion.

        Previous assessments:
        #{JSON.pretty_generate(previous_assessments)}

        Candidates:
        #{JSON.pretty_generate(candidates.map { |issue| compact_issue(issue) })}
      TEXT
    end

    def worker(task:, issue:, pull_request:)
      <<~TEXT
        You are the implementation worker for one durable ghwatch task.

        Task state: #{task.state}
        Assigned issue: #{task.issue_number || "none"}
        Current pull request: #{task.pr_number || "none"}
        Branch: #{task.branch || "none"}

        Read the repository's AGENTS.md and relevant project/specification files before changing
        code. The existing worktree is the task's durable workspace; do not create another
        worktree. Resume from current repository and GitHub state rather than starting over.

        You may edit files, run tests, commit, push, and create or update the task's pull request.
        Keep unrelated changes out of the diff. Do not merge your own pull request.

        If a human decision, clarification, reproduction detail, or environment-specific answer
        is required, do not guess. Return waiting_for_human_input with a concise complete
        question. If implementation is ready but needs real-person verification, return
        waiting_for_human_test with precise instructions and what remains unverified.

        Current issue:
        #{JSON.pretty_generate(compact_issue(issue))}

        Current pull request:
        #{JSON.pretty_generate(compact_pull_request(pull_request))}
      TEXT
    end

    def reviewer(task:, issue:, pull_request:)
      <<~TEXT
        Review the pull request as an independent reviewer. Read AGENTS.md and relevant project
        specifications. Inspect the current PR diff, CI/check state, review discussion, and the
        related issue when present. Compare the change with current main where useful.

        Do not edit code or create a worktree. Do not approve a change merely because tests pass.
        Check correctness, regressions, error handling, concurrency/resources where relevant,
        maintainability, test coverage, and whether the implementation actually satisfies the
        issue. If project policy requires human verification, do not authorize merge until that
        report exists.

        Task state: #{task.state}
        Related issue: #{task.issue_number || "none"}
        Pull request: #{task.pr_number}

        Issue snapshot:
        #{JSON.pretty_generate(compact_issue(issue))}

        Pull request snapshot:
        #{JSON.pretty_generate(compact_pull_request(pull_request))}
      TEXT
    end

    def finalizer(task:, issue:, pull_request:)
      <<~TEXT
        The implementation phase is over or the pull request has merged. Verify whether the
        related issue is actually resolved and whether any promised human verification is still
        outstanding. Do not edit source code.

        Related issue: #{task.issue_number || "none"}
        Pull request: #{task.pr_number || "none"}

        Issue snapshot:
        #{JSON.pretty_generate(compact_issue(issue))}

        Pull request snapshot:
        #{JSON.pretty_generate(compact_pull_request(pull_request))}
      TEXT
    end

    private

    # GitHub payloads carry many URLs, ids, reactions and diff hunks that agents
    # don't need; keep only what describes the discussion so prompts stay small.
    def compact_issue(issue)
      return issue unless issue.is_a?(Hash)

      issue.slice("number", "title", "state", "url", "body", "updatedAt").merge(
        "author" => login(issue["author"]),
        "labels" => Array(issue["labels"]).map { |label| label["name"] },
        "assignees" => Array(issue["assignees"]).map { |assignee| login(assignee) },
        "comments" => compact_comments(issue["comments"])
      ).compact
    end

    def compact_pull_request(pr)
      return pr unless pr.is_a?(Hash)

      pr.slice(
        "number", "title", "state", "url", "isDraft", "body", "headRefName", "headRefOid", "baseRefName",
        "updatedAt", "mergedAt", "mergeable", "reviewDecision"
      ).merge(
        "closingIssues" => Array(pr["closingIssuesReferences"]).map { |ref| ref["number"] },
        "checks" => Array(pr["statusCheckRollup"]).map { |check| check.slice("name", "workflowName", "status", "conclusion") },
        "reviews" => Array(pr["reviews"]).map do |review|
          {"author" => login(review["author"]), "state" => review["state"], "submittedAt" => review["submittedAt"], "body" => review["body"]}
        end,
        "comments" => compact_comments(pr["comments"]),
        "inlineComments" => Array(pr["inlineComments"]).map do |comment|
          {
            "id" => comment["id"],
            "inReplyTo" => comment["in_reply_to_id"],
            "author" => login(comment["user"]),
            "path" => comment["path"],
            "line" => comment["line"] || comment["original_line"],
            "createdAt" => comment["created_at"],
            "body" => comment["body"]
          }.compact
        end
      ).compact
    end

    def compact_comments(comments)
      return nil if comments.nil?

      Array(comments).map do |comment|
        {
          "id" => comment["id"],
          "author" => login(comment["user"] || comment["author"]),
          "createdAt" => comment["created_at"] || comment["createdAt"],
          "body" => comment["body"]
        }.compact
      end
    end

    def login(user)
      user.is_a?(Hash) ? user["login"] : user
    end
  end
end
