# frozen_string_literal: true

require "json"
require "time"

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
    # Issues and PRs an issue mentions whose state is looked up.
    MAX_REFERENCES = 10

    STATUS_QUESTION = {
      "type" => "choice",
      "instructions" => "Which option describes what should happen next with the GitHub issue in `issue`? " \
        "Only comments whose authorIsMaintainer is true can approve, decline or decide anything. " \
        "`open_pull_requests` lists the pull requests that are still open (not merged). " \
        "`referenced` gives the current state of the issues and pull requests the issue mentions as #N. " \
        "Comments are oldest first; `new` marks the ones posted since the issue was last assessed. " \
        "A maintainer's later comment overrides what the body or earlier comments say.",
      "criteria" => {
        "ready" => "A maintainer has accepted the work, the requirements are clear, and nothing it waits for is still pending " \
          "according to `referenced` and `open_pull_requests`.",
        "blocked" => "Work needs information or a decision from a person that the discussion does not contain yet.",
        "discussion" => "A maintainer has not yet decided whether to do it: a loose idea, doubtful value, " \
          "behavior that could harm users, or a large architectural change.",
        "deferred" => "The discussion says the work must wait for a specific event, such as a pull request " \
          "being merged, another issue being done, or a release, and that event has not happened yet: " \
          "what it waits for is still open in `referenced` or `open_pull_requests`, or is a release not made yet.",
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
    # references: number -> state of the issue or PR #number (nil if unknown).
    def settle(issues, open_pull_requests:, previous:, references: nil)
      return {} unless enabled? && !issues.empty?

      @references = references
      @reference_cache = {}

      client = @client || build_client
      return {} unless client

      issues.each_with_object({}) do |issue, settled|
        number = issue.fetch("number")
        # Conversations already under way need the LLM to read the replies.
        next if %w[blocked discussion].include?(previous[number]&.fetch(:status, nil))

        state = state_for(issue, open_pull_requests, previous[number])
        next if JSON.generate(state).bytesize > MAX_STATE_BYTES

        response = client.evaluate(state: state, questions: {"status" => STATUS_QUESTION})
        answer = response.dig("answers", "status") || {}
        status = answer["choice"]
        confidence = answer["confidence"].to_f
        @log.info("[issue-#{number}] screening: #{status} (confidence #{format("%.2f", confidence)})")
        next unless SETTLES.include?(status) && confidence >= min_confidence
        # The model is quick to read any open issue an issue mentions as what
        # it waits for. It may keep an issue waiting, but the LLM decides
        # that it starts to wait.
        next if status == "deferred" && previous[number]&.fetch(:status, nil) != "deferred"

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

    def state_for(issue, open_pull_requests, previous)
      comments = Array(issue["comments"]).last(20)
      assessed_at = previous && previous[:updated_at].to_i
      state = {
        "issue" => {
          "number" => issue["number"],
          "title" => issue["title"],
          "authorIsMaintainer" => maintainer?(issue["authorAssociation"]),
          "labels" => Array(issue["labels"]).map { |label| label["name"] },
          "body" => truncate(issue["body"], COMMENT_BYTES * 3),
          "comments" => comments.map do |comment|
            created_at = comment["created_at"] || comment["createdAt"]
            {
              "authorIsMaintainer" => maintainer?(comment["author_association"] || comment["authorAssociation"]),
              "createdAt" => created_at,
              "new" => assessed_at.nil? || created_at.nil? || Time.parse(created_at).to_i > assessed_at,
              "body" => truncate(comment["body"], COMMENT_BYTES)
            }.compact
          end
        },
        "open_pull_requests" => open_pull_requests.map { |pr| {"number" => pr["number"], "title" => pr["title"]} }
      }
      referenced = referenced_states(issue, comments)
      state["referenced"] = referenced unless referenced.empty?
      state
    end

    # What the issue waits for is usually named as #N; without its state the
    # model cannot tell whether the wait is over.
    def referenced_states(issue, comments)
      return [] unless @references

      text = ([issue["body"]] + comments.map { |comment| comment["body"] }).join("\n")
      numbers = text.scan(/(?<![\w\/&])#(\d+)\b/).flatten.map(&:to_i).uniq - [issue["number"]]
      numbers.first(MAX_REFERENCES).filter_map do |number|
        @reference_cache.fetch(number) { @reference_cache[number] = lookup_reference(number) }
      end
    end

    def lookup_reference(number)
      @references.call(number)
    rescue => e
      @log.warn("could not read the state of ##{number}: #{e.message}")
      nil
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
