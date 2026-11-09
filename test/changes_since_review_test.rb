# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

# A role reviews the whole PR once; later reviews cover what came after the
# commit it reviewed, so each rework round does not repeat the whole review.
class ChangesSinceReviewTest < Minitest::Test
  class Github
    def pull_request(number) = nil

    def review_signature(pr) = "review"

    def post_pr_comment(number, body, kind:, model_signature: nil) = nil
  end

  def setup
    @config = OpenStruct.new(retry_after: 60, file_found_issues?: false, human_language: "en")
    @reviewer = Ghwatch::Actions::Reviewer.new(project: nil, config: @config, state: Struct.new(:x) { def save_task(task) = task }.new,
      github: Github.new, roles: nil, context_builder: nil, human_channel: nil, log: Ghwatch::Log.new(StringIO.new))
    @task = Ghwatch::Task.for_issue(4, branch: "b", worktree: nil)
    @task.pr_number = 5
    @task.state = "waiting_for_review"
  end

  def review(head, status: "changes_requested", role: "reviewer")
    @task.state = "waiting_for_review"
    @reviewer.send(:apply_result, @task, {"headRefOid" => head}, OpenStruct.new(data: {"status" => status, "body" => "Body"}, signature: "codex", role: role))
  end

  def context(head, role: "reviewer")
    Ghwatch::ContextBuilder.new(config: @config).reviewer(task: @task, issue: nil, pull_request: {"headRefOid" => head}, role: role)
  end

  def test_the_first_review_covers_the_whole_pr
    refute_includes context("h1"), "last reviewed this PR"
  end

  def test_the_next_review_covers_what_came_after_the_reviewed_commit
    review("h1")

    text = context("h2")
    assert_includes text, "last reviewed this PR at commit h1"
    assert_includes text, "git diff h1 h2"
  end

  def test_the_same_commit_has_nothing_after_it
    review("h1")
    refute_includes context("h1"), "last reviewed this PR"
  end

  def test_a_normal_review_does_not_stand_in_for_the_deep_reviewers_first_look
    review("h1")
    refute_includes context("h2", role: "deep_reviewer"), "last reviewed this PR"
  end

  def test_the_deep_reviewer_starts_from_its_own_last_review
    review("h1", role: "deep_reviewer")
    review("h2")

    assert_includes context("h3", role: "deep_reviewer"), "git diff h1 h3"
    assert_includes context("h3"), "git diff h2 h3"
  end

  def test_a_deep_review_counts_for_the_normal_reviewer
    review("h1", role: "deep_reviewer")
    assert_includes context("h2"), "git diff h1 h2"
  end

  def test_a_review_that_asked_to_retry_does_not_count
    review("h1", status: "retry")
    refute_includes context("h2"), "last reviewed this PR"
  end

  def test_another_pull_request_starts_over
    review("h1")
    @task.pr_number = 6
    refute_includes context("h2"), "last reviewed this PR"

    review("h2")
    assert_equal({"pr" => 6, "reviewer" => "h2"}, @task.metadata["reviewed_heads"])
  end
end
