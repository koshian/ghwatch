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
        Human-facing GitHub text should use: #{(@config.human_language == "auto") ? "the language already used by the issue/project" : @config.human_language}

        Assess every candidate independently. `ready` means enough is known to implement now.
        Do not mark an issue blocked merely because it is large; blocked is specifically for
        missing human information or a human decision. Use deferred when the issue explicitly
        waits for a future dependency, upgrade, release, external event, or other condition.
        Do not ask humans to repeat decisions already present in the issue discussion.

        Previous assessments may be stale; re-evaluate them against the current discussion.

        Previous assessments:
        #{JSON.pretty_generate(previous_assessments)}

        Candidates:
        #{JSON.pretty_generate(candidates)}
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
        #{JSON.pretty_generate(issue)}

        Current pull request:
        #{JSON.pretty_generate(pull_request)}
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
        #{JSON.pretty_generate(issue)}

        Pull request snapshot:
        #{JSON.pretty_generate(pull_request)}
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
        #{JSON.pretty_generate(issue)}

        Pull request snapshot:
        #{JSON.pretty_generate(pull_request)}
      TEXT
    end
  end
end
