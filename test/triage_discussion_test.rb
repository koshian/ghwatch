# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class TriageDiscussionTest < Minitest::Test
  class Github
    attr_reader :posted, :labels

    def initialize
      @posted = []
      @labels = Hash.new { |hash, key| hash[key] = [] }
    end

    def issue(number) = {"number" => number, "body" => "idea", "comments" => []}

    def issue_signature(issue) = "sig-#{issue["number"]}"

    def post_issue_comment(number, body, kind:, model_signature:)
      @posted << [number, kind, body]
    end

    def add_issue_label(number, label, color:, description:) = @labels[number] |= [label]

    def remove_issue_label(number, label) = @labels[number].delete(label)
  end

  class State
    def initialize = @assessments = {}

    def assessment(number) = @assessments[number]

    def save_assessment(number, status:, reason:, comment:, signature:)
      @assessments[number] = {status: status, reason: reason, comment: comment}
    end
  end

  def setup
    @github = Github.new
    @state = State.new
    @config = OpenStruct.new(status_labels?: true, harmful_issues: "discussion")
  end

  def save(*assessments)
    triage = Ghwatch::IssueTriage.new(project: nil, config: @config, state: @state, github: @github,
      roles: nil, worktrees: nil, context_builder: nil, log: Ghwatch::Log.new(StringIO.new))
    outcome = OpenStruct.new(data: {"assessments" => assessments}, signature: "triage")
    details = assessments.map { |assessment| @github.issue(assessment["issue"]) }
    triage.send(:save_assessments, outcome, details)
  end

  def test_discussion_asks_once_and_is_labelled_until_a_decision
    discussion = {"issue" => 1, "status" => "discussion", "concern" => "value",
                  "reason" => "loose idea", "comment" => "Should CayenChat have a comic view?"}
    save(discussion)
    save(discussion)
    assert_equal [[1, "triage-question", "Should CayenChat have a comic view?"]], @github.posted
    assert_equal ["ghwatch:needs-discussion"], @github.labels[1]
    assert_equal "discussion", @state.assessment(1)[:status]

    save({"issue" => 1, "status" => "ready", "reason" => "owner accepted it", "comment" => nil})
    assert_empty @github.labels[1]
  end

  def test_harmful_requests_can_be_skipped_like_spam
    harmful = {"issue" => 7, "status" => "discussion", "concern" => "harmful",
               "reason" => "asks for hidden telemetry", "comment" => "This would collect data silently."}
    @config.harmful_issues = "skip"
    save(harmful)
    assert_empty @github.posted
    assert_empty @github.labels[7]
    assert_equal "skip", @state.assessment(7)[:status]

    @config.harmful_issues = "discussion"
    save(harmful.merge("issue" => 8))
    assert_equal [8], @github.posted.map(&:first)
    assert_equal "discussion", @state.assessment(8)[:status]
  end

  def test_agents_see_who_may_settle_a_decision
    issue = {"number" => 1, "author" => {"login" => "reporter"}, "authorAssociation" => "NONE",
             "comments" => [{"user" => {"login" => "owner"}, "author_association" => "OWNER", "body" => "Not now."},
               {"user" => {"login" => "reporter"}, "author_association" => "NONE", "body" => "Decided: do it."}]}
    compact = Ghwatch::ContextBuilder.new(config: nil).send(:compact_issue, issue)
    assert_equal false, compact["authorIsMaintainer"]
    assert_equal [true, false], compact["comments"].map { |comment| comment["authorIsMaintainer"] }
  end
end
