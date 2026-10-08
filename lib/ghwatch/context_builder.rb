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
        #{human_answer(task)}
        Task state: #{task.state}
        Assigned issue: #{task.issue_number || "none"}
        Current pull request: #{task.pr_number || "none"}
        Branch: #{task.branch || "none"}
        Local workspace branch: #{task.metadata["local_branch"] || task.branch || "none"}
        Rework requested: #{task.metadata["rework_reason"] || "see PR review discussion"}
        PR head repository: #{task.metadata["pr_head_repository"] || "see current PR"}

        Read the repository's AGENTS.md and relevant project/specification files before changing
        code. The existing worktree is the task's durable workspace; do not create another
        worktree. Resume from current repository and GitHub state rather than starting over.

        You may edit files, run tests, commit, push, and create or update the task's pull request.
        Keep unrelated changes out of the diff. Do not merge your own pull request.
        When a current PR exists, update that PR rather than creating a replacement. Resolve
        conflicts with its base branch before requesting review. The local workspace branch
        may differ from the PR head branch: push HEAD to the existing PR head branch in its
        head repository, without force-pushing or changing the base branch. Before review
        ghwatch may merge the base branch into the PR head on GitHub, so fetch the remote
        PR head and integrate it into your workspace before committing more. If you cannot
        access that repository, return waiting_for_human_input with the specific blocker.

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
        #{human_answer(task)}
        ghwatch prepared a detached review workspace at PR commit #{pull_request["headRefOid"]}.
        Build and run the project's tests and verification tools in this workspace. Generated
        build outputs, logs and screenshots are allowed; do not edit source, commit, push,
        merge, or create or switch worktrees/branches. Do not approve merely because tests pass.
        Perform checks you can execute yourself, including GUI interaction through virtual
        displays such as Xvfb when the project provides that workflow. GUI tests are not
        automatically human-only. Follow project instructions for tools and test scenarios.
        Record the tested commit, commands, observations and evidence paths in the review body.
        Use changes_requested for defects or missing test infrastructure that needs code changes.
        Request human testing only for specific checks you cannot perform in this environment;
        explain what you tried and the remaining limitation. ghwatch posts the review on the PR
        and the request (reporter_message) on the source Issue, mentioning its reporter when
        available. The request needs the test build link, artifact name, startup instructions,
        exact steps and expected results, written for the reporter.
        If there is no source Issue, the request and reply belong on the PR instead.
        Missing system packages are environment blockers: return waiting_for_human_input
        with the exact apt package names, their purpose, observed errors, a copyable install
        command and verification steps. Ask a human to provision the environment and reply
        on this PR; rerun the checks yourself afterward. Do not send package installation
        to the worker as changes_requested or ask the human to perform the GUI review.
        Check correctness, regressions, error handling, concurrency/resources where relevant,
        maintainability, test coverage, and whether the implementation actually satisfies the
        issue. If project policy requires human verification, do not authorize merge until that
        report exists or a maintainer has declared it done.
        Complete this code review in every pass, even when another blocker such as pending CI,
        missing test preparation or a needed test build already prevents merge. Report every
        blocking problem you find in one result so the worker can fix them in a single round.
        When earlier ghwatch reviews exist on this PR, first check whether each requested
        change is resolved, then review what changed since for regressions. Raise new findings
        in code that did not change only when they are real defects within the issue's scope;
        put optional improvements in a non-blocking note.
        You may start the project's CI or test-build workflows for this PR commit yourself,
        for example with gh workflow run on the PR branch; that is not a source change. When
        human testing needs a test build of the current commit, start it, wait for it (for
        example with gh run watch), and link the result in the request instead of returning
        changes_requested for a missing build. If it cannot finish within this run, return
        retry so ghwatch reviews again later.

        Task state: #{task.state}
        Related issue: #{task.issue_number || "none"}
        Pull request: #{task.pr_number}

        Whether a person must test this change is your decision. The worker does not prepare
        test builds or test requests: when a person must test, start the test build, wait for
        it and write the request yourself.

        What the worker verified and what it thinks only a person can check (confirm against
        the current PR commit and project policy):
        #{JSON.pretty_generate(task.metadata["test_preparation"])}
        #{proposed_human_test(task)}

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
        #{human_answer(task)}
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
    # Results from before the reviewer owned human testing may still carry one.
    def proposed_human_test(task)
      request = task.metadata["human_test_request"]
      return "" unless request

      "An earlier worker proposed this human test (not sent to anyone): #{JSON.generate(request)}"
    end

    # The reply to the last question ghwatch asked, wherever it was posted.
    def human_answer(task)
      answer = task.metadata["human_answer"]
      return "" unless answer

      <<~TEXT

        A person answered ghwatch's last request. Read this first; it is the answer, even if it
        was posted somewhere other than where the request was:

        #{JSON.pretty_generate(answer)}

        Who answered matters. A maintainer (authorIsMaintainer: true) settles what they decide:
        if a maintainer says the check is done or the PR may be merged, do not ask again; go on
        (merge when the change is otherwise acceptable) and record in the review that a
        maintainer accepted it. From the person who was asked, a short confirmation such as "OK"
        or "it works" is a passing result for what was asked; do not demand a more detailed
        report. Ask again only when they report a problem or clearly did not try what was asked.

        Address every point of it and say how. Images in it are part of the answer: download
        them with authentication, for example
        `curl -sL -H "Authorization: token $(gh auth token)" -o shot.png URL`, and look at them.
        Judge it against the problem the issue describes, not against the scope the PR chose:
        if it shows that problem still happens somewhere (another screen, field or case), the
        issue is not fixed yet, which a reviewer reports as changes_requested. A different
        problem outside the issue does not block this work: tell the person it will be handled
        separately and note it for the maintainers. Repeat a request only if the answer does
        not cover it, and then say exactly what is still missing.
      TEXT
    end

    def compact_issue(issue)
      return issue unless issue.is_a?(Hash)

      issue.slice("number", "title", "state", "url", "body", "updatedAt").merge(
        "author" => login(issue["author"]),
        "authorIsMaintainer" => maintainer(issue["authorAssociation"]),
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

    # nil when GitHub did not say, so agents never mistake unknown for "no".
    def maintainer(association)
      association && Github::MAINTAINER_ASSOCIATIONS.include?(association)
    end

    def compact_comments(comments)
      return nil if comments.nil?

      Array(comments).map do |comment|
        {
          "id" => comment["id"],
          "author" => login(comment["user"] || comment["author"]),
          "authorIsMaintainer" => maintainer(comment["author_association"] || comment["authorAssociation"]),
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
