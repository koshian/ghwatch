# frozen_string_literal: true

require "json"

module Ghwatch
  module Result
    START_MARKER = "GHWATCH_RESULT_BEGIN"
    END_MARKER = "GHWATCH_RESULT_END"

    class ProtocolError < StandardError; end

    module_function

    def parse(output)
      bodies = output.to_s.scan(/#{Regexp.escape(START_MARKER)}\s*(\{.*?\})\s*#{Regexp.escape(END_MARKER)}/mo).flatten
      raise ProtocolError, "agent did not emit a ghwatch result" if bodies.empty?

      JSON.parse(bodies.last)
    rescue JSON::ParserError => e
      raise ProtocolError, "invalid ghwatch result JSON: #{e.message}"
    end

    def contract_for(role)
      case role.to_s
      when "triage"
        triage_contract
      when "worker"
        worker_contract
      when "reviewer", "deep_reviewer"
        reviewer_contract(role)
      when "finalizer"
        finalizer_contract
      else
        generic_contract
      end
    end

    def generic_contract
      <<~TEXT
        Finish by emitting exactly one machine-readable result between these markers:

        #{START_MARKER}
        {"status":"done"}
        #{END_MARKER}

        Text outside the markers is treated only as diagnostic output.
      TEXT
    end

    def triage_contract
      <<~TEXT
        Do not write to GitHub. Return your decision to ghwatch.

        Finish with exactly one result using this shape:

        #{START_MARKER}
        {
          "selected_issues": [123],
          "assessments": [
            {
              "issue": 123,
              "status": "ready|blocked|discussion|deferred|followup|skip",
              "concern": "value|harmful|architecture|other, only for discussion",
              "reason": "short factual reason",
              "comment": "human-facing clarification request, discussion points, or null"
            }
          ]
        }
        #{END_MARKER}

        selected_issues may contain at most the number of slots stated in the context.
        A blocked issue needs human information or a human decision now. A discussion issue
        needs a maintainer to decide whether and how to do it; its comment states the concern
        and the decision needed, with options. Mark it ready only after a maintainer
        (authorIsMaintainer: true) has settled that; a decision from anyone else, including
        the reporter, does not count. Use skip when a maintainer declined it. A deferred issue
        is intentionally waiting for a future dependency or event and should not ask the
        human to repeat a decision already recorded. followup means implementation is not
        the next action, but ghwatch should continue watching for a response or verification.
      TEXT
    end

    def worker_contract
      <<~TEXT
        The GitHub issue is the asynchronous human communication channel, but do not post
        questions yourself. Return the question to ghwatch and ghwatch will post it with a
        durable marker. Never merely print a question and exit.

        Finish with exactly one result using one of these statuses:

        #{START_MARKER}
        {
          "status": "waiting_for_review|waiting_for_human_input|continue|done|deferred",
          "pr": 123,
          "question": "human-facing question, for waiting_for_human_input",
          "summary": "for the PR: what you changed and why, which review points or failed checks it answers, and what you verified",
          "test_preparation": {
            "commit": "full tested commit SHA",
            "verified": ["checks you performed and their results"],
            "remaining": ["checks you think only a person can do, and why"]
          },
          "reason": "short reason when useful"
        }
        #{END_MARKER}

        Once the change is implemented, verified with the project's own tools and pushed,
        return waiting_for_review with the PR number; do not claim it before the branch is
        pushed and the PR exists. Use continue only when the implementation itself is not
        finished and another pass of yours is needed, never to prepare testing. Use
        waiting_for_human_input, with a complete question, for information, decisions or
        access you cannot obtain yourself.

        Whenever you pushed to the PR, write summary for the reviewers and maintainers who
        read the PR: what changed and why, how it answers each review point or failed check of
        this round, and what you verified. ghwatch posts it on the PR together with the list of
        new commits, so do not post PR comments yourself.

        Human testing is the reviewer's decision: do not start or wait for test builds and do
        not write test requests. Record what you verified in test_preparation and, under
        remaining, what you think only a person can check; the reviewer decides. Do not infer
        that a check needs a person merely because it involves a GUI. Never merge the PR.
        While a person is being waited on, ghwatch removes ignored build outputs from the
        task worktree, so human instructions must obtain or build the test subject
        themselves rather than point at files there.
      TEXT
    end

    # Issues are where reporters follow their report; most are users, not
    # reviewers of the code.
    REPORTER_GUIDANCE = <<~TEXT
      Text for the issue is read by the person who reported it, who may not be a developer.
      Write it for them, not as a code review: no review headings (good points, risks,
      blocking), no file paths, workspace paths or internal tool names, and code identifiers
      only when the reporter needs them. Say, in plain terms:
      - what the problem was, in the reporter's own terms;
      - what changed in the application, as they will notice it;
      - if they reported or tested before, what they reported and what was changed in
        response to it, so they can see their report was acted on;
      - for a test request: how to get the build (link, file name, how to start it), the steps
        to try with what they should see, and exactly what to reply (what worked, what did
        not, and logs or screenshots when something fails);
      - for a completion note: what is now fixed and, if the issue stays open, why.
      Keep it short and concrete; link the PR for details instead of repeating the review.
    TEXT

    def reviewer_contract(role)
      deep_option = (role.to_s == "reviewer") ? "|deep_review" : ""
      <<~TEXT
        This is a review role. You may build and run verification in the prepared workspace,
        creating build outputs, logs and screenshots, and you may start CI or test-build
        workflows for the PR commit. Do not edit source, create commits, push branches,
        create worktrees, or merge the pull request yourself. Return the decision to ghwatch.

        Finish with exactly one result:

        #{START_MARKER}
        {
          "status": "merge|changes_requested|waiting_for_human_input|waiting_for_human_test|comment#{deep_option}|retry",
          "body": "human-facing review in the form the role instructions describe",
          "reporter_message": "for waiting_for_human_test with a related issue: the request to the reporter",
          "issue": 123,
          "test_preparation": {
            "commit": "full tested commit SHA",
            "verified": ["checks performed and their results"],
            "remaining": ["checks that require a person and why"],
            "test_subject": "build/run link, artifact name, access and startup instructions, or why no artifact is needed",
            "steps": ["human test steps and expected results"]
          },
          "reason": "short internal reason"
        }
        #{END_MARKER}

        merge means the change is acceptable and all required human verification is already
        satisfied; non-blocking suggestions belong in a merge review's body and are no reason
        to choose comment instead. changes_requested must explain actionable blocking problems.
        waiting_for_human_test must contain precise test instructions in body and identify
        the related issue when known. With a related issue, body (the review) is posted on the
        PR and reporter_message is posted on the issue as the request to the reporter; write
        reporter_message as described below. Read the issue's earlier ghwatch test requests and
        the reporter's replies first: when this is a new round after their feedback, open with
        what they reported and what was changed because of it.

        #{REPORTER_GUIDANCE} comment is for a review that cannot decide yet and does
        not authorize merge; the same head is not reviewed again until something changes.
        Do not wait for CI and do not return comment or retry only because checks are still
        running: judge the change. ghwatch merges only after the required checks pass and
        sends the PR back to the worker if they fail. Mention unfinished checks in the body.

        For development-environment blockers such as missing OS packages, use
        waiting_for_human_input, not changes_requested or waiting_for_human_test. In body,
        list the exact apt package names for the detected Debian/Ubuntu system, explain
        what each supplies and the observed failure, and provide a copyable
        sudo apt install command for the human to run. Check project instructions and
        available package metadata; do not confuse an executable name with a package name
        or claim unverified dependencies are required. On other systems give the appropriate
        package-manager instructions. Do not install system packages yourself. Include
        post-install verification commands and ask the human to reply on this PR once ready;
        ghwatch will resume the review and the reviewer will rerun the blocked checks.

        Before waiting_for_human_test, check the project's development and verification
        instructions and verify the preparation evidence for the current PR commit.
        Run available autonomous checks and preparation yourself. Use changes_requested
        for defects or test preparation that requires implementation changes, and
        waiting_for_human_input for environment setup requiring human intervention.
        Do not waive a project requirement. Only request checks that actually require a person.
        For waiting_for_human_test, include test_preparation and make body a self-contained
        request with the tested commit, what was verified, what remains, how to obtain and
        start the test subject, and steps with expected results. Explain when no artifact
        is needed. Include the PR URL and direct build/artifact links when applicable.
        ghwatch posts this request on the source Issue and mentions its reporter; ask for
        results on that Issue. PR-only tasks use the PR conversation. Environment setup
        requests (waiting_for_human_input) continue to ask for a reply on the PR.
        While a person is being waited on, ghwatch removes the review workspace and ignored
        build outputs in the task worktree. Human instructions must use a CI/test-build link
        or include the commands to build the test subject, not point at files there.
        When all required checks are verified and the change is acceptable,
        return merge rather than asking for redundant human testing.
      TEXT
    end

    def finalizer_contract
      <<~TEXT
        Do not edit source code. Verify whether the merged work resolves the related issue.
        Return the final GitHub action to ghwatch.
        For waiting_for_human_test, make comment a complete request with the PR link,
        tested SHA, direct test-build links and artifact/startup instructions when needed,
        what was already verified, remaining steps and expected results. ghwatch posts
        this request on the source Issue and mentions its reporter; ask for results there.
        A task without a source Issue uses the PR conversation instead.

        Finish with exactly one result:

        #{START_MARKER}
        {
          "status": "done|waiting_for_human_input|waiting_for_human_test|retry",
          "close_issue": true,
          "comment": "completion note, question, or test request",
          "reason": "short reason"
        }
        #{END_MARKER}

        comment is posted on the issue.

        #{REPORTER_GUIDANCE}
      TEXT
    end
  end
end
