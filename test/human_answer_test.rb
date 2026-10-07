# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class HumanAnswerTest < Minitest::Test
  def test_a_reply_on_the_pr_to_a_question_on_the_issue_reaches_the_next_run
    task = Ghwatch::Task.for_issue(219, branch: "b", worktree: nil)
    task.pr_number = 230
    task.state = "waiting_for_human_test"
    task.human_marker = "<!-- ghwatch:human-test:q -->"
    task.metadata["resume_state"] = "waiting_for_review"
    issue = {"number" => 219, "state" => "OPEN", "comments" => [
      {"id" => 10, "user" => {"login" => "koshian"}, "body" => "Please try the build <!-- ghwatch:human-test:q -->"}
    ]}
    pull_request = {"number" => 230, "state" => "OPEN", "headRefOid" => "h", "comments" => [
      {"id" => 5, "user" => {"login" => "cosepi"}, "body" => "before the question"},
      {"id" => 11, "user" => {"login" => "cosepi"}, "created_at" => "2026-10-07T04:55:26Z",
       "body" => "![](https://github.com/user-attachments/assets/a) Settings: cannot see the cursor."},
      {"id" => 12, "user" => {"login" => "koshian"}, "body" => "review <!-- ghwatch:review-comment:x -->"}
    ]}
    snapshot = Ghwatch::TaskSnapshot.new(issue: issue, pull_request: pull_request, issue_signature: "i",
      pull_request_signature: "p", review_signature: "r")
    config = OpenStruct.new(retry_after: 60)
    events = Ghwatch::Observer.new(github: nil, config: config).events(task, snapshot)
    answer = events.fetch("reply")
    assert_equal "issue #219", answer[:question]["where"]
    assert_equal [{"where" => "PR #230", "author" => "cosepi", "createdAt" => "2026-10-07T04:55:26Z",
                   "body" => "![](https://github.com/user-attachments/assets/a) Settings: cannot see the cursor."}], answer[:replies]

    machine = Ghwatch::StateMachine.new(github: nil, config: config, log: Ghwatch::Log.new(StringIO.new))
    machine.react(task, events)
    assert_equal "waiting_for_review", task.state
    context = Ghwatch::ContextBuilder.new(config: config).reviewer(task: task, issue: issue, pull_request: pull_request)
    assert_includes context, "A person answered ghwatch's last request"
    assert_includes context, "Settings: cannot see the cursor."
    assert_includes context, "not against the scope the PR chose"

    # A new question supersedes the old answer.
    task.state = "waiting_for_review"
    machine.apply_result(task, "reviewer", "waiting_for_human_test")
    refute task.metadata.key?("human_answer")
    refute_includes Ghwatch::ContextBuilder.new(config: config).worker(task: task, issue: issue, pull_request: pull_request),
      "A person answered"
  end
end
