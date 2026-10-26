# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

# Problems a reviewer finds outside what the PR causes are filed as issues
# instead of blocking the PR or getting lost in the review.
class FoundIssuesTest < Minitest::Test
  class Github < Ghwatch::Github
    attr_reader :comments, :created
    attr_accessor :open_titles

    def initialize
      super(project: nil, command: nil)
      @comments = []
      @created = []
      @open_titles = {}
    end

    def review_signature(pr) = "review"

    def post_pr_comment(number, body, kind:, model_signature: nil) = @comments << body

    def open_issue_titled(title) = @open_titles[title] && {"number" => @open_titles[title], "title" => title}

    def create_issue(title, body, kind:, model_signature: nil)
      @created << [title, body, kind]
      100 + @created.size
    end
  end

  def setup
    @github = Github.new
    @config = OpenStruct.new(retry_after: 60, file_found_issues?: true, human_language: "en")
    @reviewer = Ghwatch::Actions::Reviewer.new(project: nil, config: @config, state: Struct.new(:x) { def save_task(task) = task }.new,
      github: @github, roles: nil, context_builder: nil, human_channel: nil, log: Ghwatch::Log.new(StringIO.new))
    @task = Ghwatch::Task.for_issue(4, branch: "b", worktree: nil)
    @task.pr_number = 5
    @task.state = "waiting_for_review"
  end

  def review(new_issues)
    data = {"status" => "merge", "body" => "Looks good.", "new_issues" => new_issues}
    @reviewer.send(:apply_result, @task, {"headRefOid" => "h"}, OpenStruct.new(data: data, signature: "codex"))
  end

  def test_found_problems_are_filed_once_and_linked_in_the_review
    @github.open_titles["Settings are lost when the file cannot be written"] = 77
    review([{"title" => "Saving credentials blocks the UI thread", "body" => "Steps: ..."},
      {"title" => "Settings are lost when the file cannot be written", "body" => "Steps: ..."}])

    assert_equal [["Saving credentials blocks the UI thread", "Steps: ...\n\nFound while reviewing PR #5.", "found-issue"]], @github.created
    assert_includes @github.comments.last, "Filed as separate issues:\n- #101 Saving credentials blocks the UI thread\n" \
      "- #77 Settings are lost when the file cannot be written"
    assert_equal "ready_to_merge", @task.state

    @task.state = "waiting_for_review"
    review([{"title" => "Saving credentials blocks the UI thread", "body" => "Steps again"}])
    assert_equal 1, @github.created.size, "a later round links the issue it already filed"
    assert_includes @github.comments.last, "- #101 Saving credentials blocks the UI thread"
  end

  def test_nothing_is_filed_when_turned_off
    @config[:file_found_issues?] = false
    review([{"title" => "Saving credentials blocks the UI thread", "body" => "Steps: ..."}])
    assert_empty @github.created
    assert_equal "Looks good.", @github.comments.last
  end

  def test_a_filed_issue_is_not_a_maintainer_decision_for_triage
    issue = {"number" => 101, "title" => "t", "authorAssociation" => "OWNER",
             "body" => "Steps\n\n<!-- ghwatch:found-issue:abc -->"}
    compact = Ghwatch::ContextBuilder.new(config: @config).send(:compact_issue, issue)
    assert_equal false, compact["authorIsMaintainer"]
    assert compact["filedByGhwatch"]
  end
end
