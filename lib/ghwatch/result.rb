# frozen_string_literal: true

require "json"

module Ghwatch
  module Result
    START_MARKER = "GHWATCH_RESULT_BEGIN"
    END_MARKER = "GHWATCH_RESULT_END"

    class ProtocolError < StandardError; end

    module_function

    def parse(output)
      bodies = output.to_s.scan(/#{Regexp.escape(START_MARKER)}\s*(\{.*?\})\s*#{Regexp.escape(END_MARKER)}/m).flatten
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
              "status": "ready|blocked|deferred|followup|skip",
              "reason": "short factual reason",
              "comment": "human-facing clarification request or null"
            }
          ]
        }
        #{END_MARKER}

        selected_issues may contain at most the number of slots stated in the context.
        A blocked issue needs human information or a human decision now. A deferred issue
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
          "status": "waiting_for_review|waiting_for_human_input|waiting_for_human_test|continue|done|deferred",
          "pr": 123,
          "question": "human-facing question or test request, when required",
          "reason": "short reason when useful"
        }
        #{END_MARKER}

        For waiting_for_review, include the PR number. For waiting_for_human_input or
        waiting_for_human_test, include a complete human-facing question/request. Use
        continue when useful work was made but another autonomous pass is needed. Do not
        claim waiting_for_review until the branch has been pushed and the PR exists.
      TEXT
    end

    def reviewer_contract(role)
      deep_option = role.to_s == "reviewer" ? "|deep_review" : ""
      <<~TEXT
        This is a read-only review role. Do not edit files, create commits, push branches,
        create worktrees, or merge the pull request yourself. Return the decision to ghwatch.

        Finish with exactly one result:

        #{START_MARKER}
        {
          "status": "merge|changes_requested|waiting_for_human_test|comment#{deep_option}|retry",
          "body": "concise human-facing review/comment",
          "issue": 123,
          "reason": "short internal reason"
        }
        #{END_MARKER}

        merge means the change is acceptable and all required human verification is already
        satisfied. changes_requested must explain actionable blocking problems.
        waiting_for_human_test must contain precise test instructions in body and identify
        the related issue when known. comment is non-blocking and does not authorize merge.
      TEXT
    end

    def finalizer_contract
      <<~TEXT
        Do not edit source code. Verify whether the merged work resolves the related issue.
        Return the final GitHub action to ghwatch.

        Finish with exactly one result:

        #{START_MARKER}
        {
          "status": "done|waiting_for_human_input|waiting_for_human_test|retry",
          "close_issue": true,
          "comment": "completion note, question, or test request",
          "reason": "short reason"
        }
        #{END_MARKER}
      TEXT
    end
  end
end
