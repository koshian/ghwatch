# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

# The tables in StateMachine are the specification. These expectations are
# written out by hand, independently of the tables, so a change to a table is
# a deliberate change to this file too.
class StateMachineTest < Minitest::Test
  class Github
    attr_reader :calls

    def initialize = @calls = []

    def close_pull_request(number, comment:) = @calls << [:close, number]

    def delete_branch(branch) = @calls << [:delete, branch]
  end

  class Worktrees
    attr_reader :calls

    def initialize = @calls = []

    def cleanup(task) = @calls << :cleanup

    def cleanup_review(task) = @calls << :cleanup_review
  end

  # A task with an issue in a representative state of each group.
  STATES = {
    worker: "changes_requested",
    review: "waiting_for_review",
    merge: "ready_to_merge",
    wait_work: "waiting_for_human_input",
    wait_final: "waiting_for_human_test",
    finalizing: "finalizing"
  }.freeze

  # Next state for a task with an issue; nil = no reaction. "same" = the
  # state does not change but the rule applies.
  REACTIONS = {
    "pr_merged" => {worker: "finalizing", review: "finalizing", merge: "finalizing", wait_work: "finalizing"},
    "issue_closed" => {worker: "done", review: "done", merge: "done", wait_work: "done", wait_final: "done", finalizing: "done"},
    "pr_closed" => {worker: "implementing", review: "implementing", merge: "implementing", wait_work: "implementing"},
    "pr_missing" => {review: "continuing", merge: "continuing", wait_work: "continuing", finalizing: "continuing"},
    "pr_found" => {worker: "waiting_for_review", wait_work: "same"},
    "conflict" => {worker: "same", review: "changes_requested", merge: "changes_requested", wait_work: "changes_requested"},
    "checks_failed" => {worker: "same", merge: "changes_requested", wait_work: "changes_requested"},
    "pushed" => {worker: "same", review: "same", merge: "waiting_for_review", wait_work: "waiting_for_review"},
    "reply" => {wait_work: "waiting_for_review", wait_final: "finalizing"},
    "activity" => {worker: "same", review: "same", merge: "waiting_for_review"}
  }.freeze

  RESULTS = {
    "worker" => {
      "waiting_for_review" => "waiting_for_review", "waiting_for_human_input" => "waiting_for_human_input",
      "continue" => "continuing", "done" => "waiting_for_review", "merged" => "finalizing", "deferred" => "done",
      "no_pr" => "continuing", "no_change" => "same", "failed" => "same"
    },
    "reviewer" => {
      "branch_updated" => "same", "merge" => "ready_to_merge", "changes_requested" => "changes_requested",
      "waiting_for_human_input" => "waiting_for_human_input", "waiting_for_human_test" => "waiting_for_human_test",
      "comment" => "same", "retry" => "same", "already_reviewed" => "same", "pr_changed" => "same", "failed" => "same"
    },
    "merge" => {
      "pr_changed" => "waiting_for_review", "pending" => "same", "manual" => "same",
      "refused" => "waiting_for_human_input", "merged" => "finalizing"
    },
    "finalizer" => {
      "not_merged" => "continuing", "no_issue" => "done", "done" => "done",
      "waiting_for_human_input" => "waiting_for_human_input", "waiting_for_human_test" => "waiting_for_human_test",
      "retry" => "same", "failed" => "same"
    }
  }.freeze

  RESULT_FROM = {"worker" => "implementing", "reviewer" => "waiting_for_review", "merge" => "ready_to_merge", "finalizer" => "finalizing"}.freeze

  def setup
    @github = Github.new
    @worktrees = Worktrees.new
    @machine = Ghwatch::StateMachine.new(github: @github, config: OpenStruct.new(retry_after: 60),
      worktrees: @worktrees, log: Ghwatch::Log.new(StringIO.new))
  end

  def task_in(group)
    task = Ghwatch::Task.for_issue(7, branch: "ghwatch/issue-7", worktree: "/w/7")
    task.pr_number = 9
    task.state = STATES.fetch(group)
    if %i[wait_work wait_final].include?(group)
      task.human_marker = "marker"
      task.metadata["human_conversation_number"] = 9
      task.metadata["resume_state"] = (group == :wait_final) ? "finalizing" : "waiting_for_review"
    end
    task
  end

  def context(event)
    {"pr_found" => {pr_number: 9, draft: false}, "checks_failed" => {head: "h", failed: ["macOS"], new: true},
     "conflict" => {new: true}, "pushed" => {head: "h2"}}.fetch(event, {})
  end

  def test_every_reaction_matches_the_specification
    STATES.each_key do |group|
      REACTIONS.each do |event, expected|
        task = task_in(group)
        before = task.state
        applied = @machine.react(task, {event => context(event)})
        want = expected[group]
        if want.nil?
          assert_nil applied, "#{event} in #{group} should not react"
          assert_equal before, task.state
        else
          assert_equal event, applied, "#{event} in #{group} should react"
          assert_equal((want == "same") ? before : want, task.state, "#{event} in #{group}")
        end
      end
    end
  end

  def test_the_tables_have_no_rules_the_specification_lacks
    Ghwatch::StateMachine::REACTIONS.each do |event, _description, rules|
      assert_equal REACTIONS.fetch(event).keys.sort, rules.keys.sort, event
    end
    assert_equal REACTIONS.keys, Ghwatch::StateMachine::REACTIONS.map(&:first)
    Ghwatch::StateMachine::RESULTS.each { |role, rules| assert_equal RESULTS.fetch(role).keys.sort, rules.keys.sort, role }
  end

  def test_every_result_matches_the_specification
    RESULTS.each do |role, results|
      results.each do |result, want|
        task = Ghwatch::Task.for_issue(7, branch: "b", worktree: nil)
        task.pr_number = 9
        task.state = RESULT_FROM.fetch(role)
        before = task.state
        @machine.apply_result(task, role, result, pull_request: nil)
        assert_equal((want == "same") ? before : want, task.state, "#{role} #{result}")
      end
    end
    assert_raises(ArgumentError) { @machine.apply_result(task_in(:review), "reviewer", "unheard_of") }
  end

  def test_the_first_event_in_table_order_wins
    task = task_in(:review)
    # Merging a PR that says "Fixes #7" closes the issue in the same moment.
    assert_equal "pr_merged", @machine.react(task, {"issue_closed" => {}, "pr_merged" => {}})
    assert_equal "finalizing", task.state
  end

  def test_leaving_a_wait_clears_it_and_a_reply_resumes_where_it_stopped
    task = task_in(:wait_work)
    task.metadata["resume_state"] = "ready_to_merge"
    @machine.react(task, {"reply" => {}})
    assert_equal "ready_to_merge", task.state
    assert_nil task.human_marker
    refute task.metadata.key?("resume_state")
    refute task.metadata.key?("human_conversation_number")
    assert task.retry_due?

    task = task_in(:wait_work)
    @machine.react(task, {"pr_merged" => {}})
    assert_nil task.human_marker
    refute task.metadata.key?("resume_state")
  end

  def test_starting_a_wait_records_where_to_resume
    task = Ghwatch::Task.for_issue(7, branch: "b", worktree: nil)
    task.state = "changes_requested"
    @machine.apply_result(task, "worker", "waiting_for_human_input")
    assert_equal "changes_requested", task.metadata["resume_state"]
    assert_nil task.retry_at
    task.state = "ready_to_merge"
    @machine.apply_result(task, "merge", "refused")
    assert_equal "waiting_for_review", task.metadata["resume_state"]
  end

  def test_closing_the_issue_abandons_the_pr_and_branch
    task = task_in(:review)
    @machine.react(task, {"issue_closed" => {}})
    assert_equal [[:close, 9], [:delete, "ghwatch/issue-7"]], @github.calls
    assert_includes @worktrees.calls, :cleanup
    assert task.done?
  end

  def test_tasks_without_an_issue_end_with_their_pr_and_keep_its_number
    task = Ghwatch::Task.for_pr(9)
    @machine.react(task, {"pr_closed" => {}})
    assert task.done?
    assert_equal 9, task.pr_number
    task = Ghwatch::Task.for_pr(9)
    @machine.react(task, {"pr_merged" => {}})
    assert task.done?
    task = Ghwatch::Task.for_pr(9)
    @machine.react(task, {"pr_missing" => {}})
    assert_equal "waiting_for_review", task.state
  end

  def test_guards_limit_repeated_reactions
    task = task_in(:worker)
    task.retry_at = Time.now.to_i + 600
    assert_nil @machine.react(task, {"conflict" => {new: false}})
    refute task.retry_due?
    assert_equal "conflict", @machine.react(task, {"conflict" => {new: true}})
    assert task.retry_due?

    task = task_in(:merge)
    @machine.react(task, {"checks_failed" => {head: "h", failed: ["macOS"]}})
    assert_equal "changes_requested", task.state
    assert_includes task.metadata["rework_reason"], "macOS"
    task.state = "ready_to_merge"
    assert_nil @machine.react(task, {"checks_failed" => {head: "h", failed: ["macOS"]}}), "once per head"
  end

  def test_a_draft_pr_is_only_recorded
    task = Ghwatch::Task.for_issue(7, branch: "b", worktree: nil)
    @machine.react(task, {"pr_found" => {pr_number: 9, draft: true}})
    assert_equal "implementing", task.state
    assert_equal 9, task.pr_number
  end

  def test_architecture_document_matches_the_tables
    document = File.read(File.expand_path("../ARCHITECTURE.md", __dir__))
    generated = document[/#{Regexp.escape(Ghwatch::StateMachine::DOC_BEGIN)}\n(.*?)#{Regexp.escape(Ghwatch::StateMachine::DOC_END)}/mo, 1]
    assert generated, "ARCHITECTURE.md lacks the generated section"
    assert_equal Ghwatch::StateMachine.markdown, generated, "run `rake docs` to regenerate ARCHITECTURE.md"
  end
end
