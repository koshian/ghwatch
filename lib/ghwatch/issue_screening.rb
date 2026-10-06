# frozen_string_literal: true

require "json"

module Ghwatch
  # First stage of triage: a cheap decision model settles issues that need
  # no action now (deferred, followup, skip) when it is confident. Anything
  # that could start work or needs a comment goes on to the LLM triage.
  class IssueScreening
    SETTLES = %w[deferred followup skip].freeze
    # Jev reads at most 32k tokens of state; Japanese runs near a token per
    # character, so keep well below that and let larger issues go to the LLM.
    MAX_STATE_BYTES = 60_000
    COMMENT_BYTES = 4_000

    STATUS_QUESTION = {
      "type" => "choice",
      "instructions" => "Which option describes what should happen next with the GitHub issue in `issue`? " \
        "Only comments whose authorIsMaintainer is true can approve, decline or decide anything. " \
        "`open_pull_requests` lists the pull requests that are still open (not merged).",
      "criteria" => {
        "ready" => "A maintainer has accepted the work, the requirements are clear, and nothing it waits for is still pending.",
        "blocked" => "Work needs information or a decision from a person that the discussion does not contain yet.",
        "discussion" => "A maintainer has not yet decided whether to do it: a loose idea, doubtful value, " \
          "behavior that could harm users, or a large architectural change.",
        "deferred" => "The discussion says the work must wait for a specific event, such as a pull request " \
          "being merged or a release, and that event has not happened yet.",
        "followup" => "The implementation is done; the issue stays open only for a person to verify, release or reply.",
        "skip" => "A maintainer declined it, or it needs no work at all."
      }
    }.freeze

    def initialize(config:, log: Log.new, client: nil, env: ENV)
      @config = config
      @log = log
      @client = client
      @env = env
    end

    def enabled?
      @config.screening.fetch("enabled", false)
    end

    # Returns {issue number => {status:, confidence:, model:}} for the issues
    # the model settled; an empty hash when screening is off or fails.
    def settle(issues, open_pull_requests:, previous:)
      return {} unless enabled? && !issues.empty?

      client = @client || build_client
      return {} unless client

      issues.each_with_object({}) do |issue, settled|
        number = issue.fetch("number")
        # Conversations already under way need the LLM to read the replies.
        next if %w[blocked discussion].include?(previous[number]&.fetch(:status, nil))

        state = state_for(issue, open_pull_requests)
        next if JSON.generate(state).bytesize > MAX_STATE_BYTES

        response = client.evaluate(state: state, questions: {"status" => STATUS_QUESTION})
        answer = response.dig("answers", "status") || {}
        status = answer["choice"]
        confidence = answer["confidence"].to_f
        @log.info("[issue-#{number}] screening: #{status} (confidence #{format("%.2f", confidence)})")
        next unless SETTLES.include?(status) && confidence >= min_confidence

        settled[number] = {status: status, confidence: confidence, model: response["model"]}
      end
    rescue Jev::Error => e
      @log.warn("issue screening failed; triaging every issue with the LLM: #{e.message}")
      {}
    end

    private

    def min_confidence
      @config.screening.fetch("min_confidence", 0.8).to_f
    end

    def build_client
      variable = @config.screening.fetch("api_key_env", "TYPESAFE_API_KEY")
      key = @env[variable].to_s
      if key.empty?
        @log.warn("issue screening is enabled but #{variable} is not set; triaging every issue with the LLM")
        return nil
      end

      Jev.new(url: @config.screening.fetch("url", "https://api.typesafe.ai/v1/systemone"),
        api_key: key, model: @config.screening.fetch("model", "jev-latest"),
        timeout: Duration.seconds(@config.screening.fetch("timeout", "60s")))
    end

    def state_for(issue, open_pull_requests)
      {
        "issue" => {
          "number" => issue["number"],
          "title" => issue["title"],
          "authorIsMaintainer" => maintainer?(issue["authorAssociation"]),
          "labels" => Array(issue["labels"]).map { |label| label["name"] },
          "body" => truncate(issue["body"], COMMENT_BYTES * 3),
          "comments" => Array(issue["comments"]).last(20).map do |comment|
            {
              "authorIsMaintainer" => maintainer?(comment["author_association"] || comment["authorAssociation"]),
              "body" => truncate(comment["body"], COMMENT_BYTES)
            }
          end
        },
        "open_pull_requests" => open_pull_requests.map { |pr| {"number" => pr["number"], "title" => pr["title"]} }
      }
    end

    def maintainer?(association)
      Github::MAINTAINER_ASSOCIATIONS.include?(association)
    end

    def truncate(text, bytes)
      text = text.to_s
      return text if text.bytesize <= bytes

      text.byteslice(0, bytes).scrub("") + " …"
    end
  end
end
