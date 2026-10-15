# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

# A maintainer gives an issue or PR to someone else by assigning it to them
# or labelling it ghwatch:hands-off; ghwatch then leaves it alone.
class HandsOffTest < Minitest::Test
  VIEWER = -> { "koshian" }

  def test_an_assignee_other_than_ghwatch_or_the_label_marks_an_item
    assert Ghwatch::Github.hands_off?({"labels" => [{"name" => "ghwatch:hands-off"}]}, viewer: -> { raise "not needed" })
    assert Ghwatch::Github.hands_off?({"assignees" => [{"login" => "alice"}]}, viewer: VIEWER)
    assert Ghwatch::Github.hands_off?({"assignees" => [{"login" => "koshian"}, {"login" => "alice"}]}, viewer: VIEWER)
    refute Ghwatch::Github.hands_off?({"assignees" => [{"login" => "koshian"}]}, viewer: VIEWER)
    refute Ghwatch::Github.hands_off?({"labels" => [{"name" => "bug"}], "assignees" => []}, viewer: -> { raise "not needed" })
    refute Ghwatch::Github.hands_off?(nil, viewer: VIEWER)
  end

  def test_a_task_whose_issue_or_pr_was_handed_off_is_told_so
    github = OpenStruct.new(viewer_login: "koshian")
    observer = Ghwatch::Observer.new(github: github, config: OpenStruct.new(reviewer_requires_green_checks?: false))
    task = Ghwatch::Task.for_issue(380, branch: "b", worktree: nil)
    task.state = "implementing"
    [[{"number" => 380, "state" => "OPEN", "assignees" => [{"login" => "alice"}]}, nil],
      [{"number" => 380, "state" => "OPEN"}, {"number" => 386, "state" => "OPEN", "labels" => [{"name" => "ghwatch:hands-off"}]}]].each do |issue, pr|
      snapshot = Ghwatch::TaskSnapshot.new(issue: issue, pull_request: pr, issue_signature: "i", pull_request_signature: "p", review_signature: "r")
      assert observer.events(task, snapshot).key?("handed_off")
    end
    snapshot = Ghwatch::TaskSnapshot.new(issue: {"number" => 380, "state" => "OPEN"}, pull_request: nil,
      issue_signature: "i", pull_request_signature: nil, review_signature: nil)
    refute observer.events(task, snapshot).key?("handed_off")
  end

  class State
    attr_reader :saved
    attr_accessor :tasks

    def initialize(tasks = [])
      @tasks = tasks
      @saved = []
    end

    def task_for_pr(number) = nil

    def save_task(task) = @saved << task.pr_number

    def assessment(number) = nil
  end

  def test_prs_of_handed_off_tasks_or_marked_for_others_are_not_reviewed
    handed = Ghwatch::Task.for_issue(380, branch: "b", worktree: nil)
    handed.state = "done"
    handed.pr_number = 386
    handed.metadata["handed_off"] = true
    state = State.new([handed])
    github = OpenStruct.new(viewer_login: "koshian", open_pull_requests: [
      {"number" => 386}, {"number" => 392, "assignees" => [{"login" => "alice"}]}, {"number" => 393}
    ])
    def github.pull_request(number) = {"number" => number}
    def github.pr_signature(pull_request) = "sig"
    Ghwatch::ReviewIntake.new(config: OpenStruct.new(review_all_open_prs?: true), state: state, github: github,
      log: Ghwatch::Log.new(StringIO.new)).discover
    assert_equal [393], state.saved
  end

  def test_triage_leaves_out_issues_marked_for_others
    github = OpenStruct.new(viewer_login: "koshian", open_issues: [
      {"number" => 370, "labels" => [{"name" => "ghwatch:hands-off"}]}, {"number" => 371, "assignees" => [{"login" => "koshian"}]}
    ])
    triage = Ghwatch::IssueTriage.new(project: nil, config: OpenStruct.new(candidate_limit: 50), state: State.new, github: github,
      roles: nil, worktrees: nil, context_builder: nil, log: Ghwatch::Log.new(StringIO.new))
    assert_equal [371], triage.send(:candidate_issues).map { |issue| issue["number"] }
  end

  def test_an_issue_someone_else_took_carries_no_ghwatch_label
    handed = Ghwatch::Task.for_issue(380, branch: "b", worktree: nil)
    handed.state = "done"
    handed.metadata["handed_off"] = true
    handed.metadata["state_since"] = 100
    state = State.new([handed])
    synced = []
    github = OpenStruct.new(viewer_login: "koshian", open_issues: [
      {"number" => 370, "labels" => [{"name" => "ghwatch:hands-off"}, {"name" => "ghwatch:deferred"}]},
      {"number" => 380, "labels" => [{"name" => "ghwatch:waiting-for-human-input"}]}
    ])
    github.define_singleton_method(:sync_issue_state_label) { |number, label:, **| synced << [number, label] }
    Ghwatch::StatusLabels.new(state: state, github: github, config: OpenStruct.new(status_labels?: true),
      log: Ghwatch::Log.new(StringIO.new)).sync_all
    assert_equal [[370, nil], [380, nil]], synced
  end
end
