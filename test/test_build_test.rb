# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

# A reviewer that needs a person to run a test build starts it and hands
# ghwatch the request; ghwatch waits for the build and posts the request
# with links to it, or sends the PR back to the reviewer if it fails.
class TestBuildTest < Minitest::Test
  class Github < Ghwatch::Github
    attr_reader :comments
    attr_accessor :runs, :history, :artifacts

    def initialize
      super(project: nil, command: nil)
      @comments = []
      @runs = {}
      @history = []
      @artifacts = []
    end

    def repo_name = "o/r"

    def review_signature(pr) = "review"

    def post_pr_comment(number, body, kind:, model_signature: nil) = @comments << [:pr, body]

    def workflow_run(id) = @runs.fetch(Integer(id))

    def successful_workflow_runs(workflow_id, limit:) = @history

    def run_artifacts(id) = @artifacts
  end

  class HumanChannel
    attr_reader :asked

    def initialize = @asked = []

    def wait(task:, body:, outcome:, kind:, target:)
      @asked << [target, body]
      task.human_marker = "marker"
    end
  end

  class State
    def initialize = @tasks = {}

    def save_task(task) = @tasks[task.id] = task

    def task(id) = @tasks[id]

    def tasks = @tasks.values
  end

  def setup
    @now = 1_000_000
    @github = Github.new
    @github.runs[42] = {"id" => 42, "workflow_id" => 7, "status" => "queued", "conclusion" => nil,
                        "html_url" => "https://github.com/o/r/actions/runs/42", "display_title" => "Test Build e8cf171 (linux-x86_64)"}
    @human = HumanChannel.new
    @state = State.new
    @test_builds = Ghwatch::TestBuilds.new(github: @github, clock: -> { @now })
    config = OpenStruct.new(retry_after: 60, human_language: "en")
    @reviewer = Ghwatch::Actions::Reviewer.new(project: nil, config: config, state: @state, github: @github, roles: nil,
      context_builder: nil, human_channel: @human, log: Ghwatch::Log.new(StringIO.new), test_builds: @test_builds)
    @watcher = Ghwatch::TestBuildWatcher.new(state: @state, reviewer: @reviewer, test_builds: @test_builds,
      lock: Mutex.new, log: Ghwatch::Log.new(StringIO.new), clock: -> { @now })
    @task = Ghwatch::Task.for_issue(656, branch: "b", worktree: nil)
    @task.pr_number = 663
    @task.state = "waiting_for_review"
  end

  def review
    data = {"status" => "waiting_for_human_test", "body" => "Please try SCRAM.", "reporter_message" => "Please try SCRAM on IRCnet.",
            "human_check" => "run", "test_build_runs" => [42]}
    @reviewer.send(:apply_result, @task, {"headRefOid" => "h"}, OpenStruct.new(data: data, signature: "codex"))
    @state.save_task(@task)
  end

  def span(minutes) = {"created_at" => "2026-10-28T01:00:00Z", "updated_at" => format("2026-10-28T01:%02d:00Z", minutes)}

  def test_the_request_waits_for_the_build_and_goes_out_with_its_links
    @github.history = [span(12), span(10), span(11)]
    review
    assert_equal "waiting_for_test_build", @task.state
    assert_empty @github.comments, "nothing is posted before the build is done"
    assert_empty @human.asked
    assert_equal @now + 11 * 60, @task.metadata.dig("test_build", "check_at"), "the usual time of the workflow"

    @now += 11 * 60
    @watcher.check_due
    assert_equal "waiting_for_test_build", @task.state
    assert_equal @now + Ghwatch::TestBuildWatcher::POLL, @state.task(@task.id).metadata.dig("test_build", "check_at")

    @now += Ghwatch::TestBuildWatcher::POLL
    @github.runs[42].merge!("status" => "completed", "conclusion" => "success")
    @github.artifacts = [{"id" => 9, "name" => "cayenchat-test-e8cf171-linux-x86_64-isolated.deb"}]
    @watcher.check_due

    task = @state.task(@task.id)
    assert_equal "waiting_for_human_test", task.state
    assert_equal "checking_test_result", task.metadata["resume_state"]
    refute task.metadata.key?("test_build")
    target, body = @human.asked.last
    assert_equal :issue, target
    assert_includes body, "Please try SCRAM on IRCnet."
    assert_includes body, "- [Test Build e8cf171 (linux-x86_64)](https://github.com/o/r/actions/runs/42)\n" \
      "  - [cayenchat-test-e8cf171-linux-x86_64-isolated.deb](https://github.com/o/r/actions/runs/42/artifacts/9)"
    assert_includes @github.comments.last.last, "Please try SCRAM.\n\n**Test build**"
  end

  def test_without_earlier_runs_the_first_look_is_after_five_minutes
    review
    assert_equal @now + 5 * 60, @task.metadata.dig("test_build", "check_at")
  end

  def test_a_failed_build_goes_back_to_the_reviewer_with_why
    review
    @now += 5 * 60
    @github.runs[42].merge!("status" => "completed", "conclusion" => "failure")
    @watcher.check_due

    task = @state.task(@task.id)
    assert_equal "waiting_for_review", task.state
    assert_nil task.last_review_signature
    assert_includes task.metadata["test_build_failure"], "https://github.com/o/r/actions/runs/42 (failure)"
    assert_empty @human.asked
    context = Ghwatch::ContextBuilder.new(config: OpenStruct.new).send(:test_build_failure, task)
    assert_includes context, "Read its logs"
  end

  def test_a_build_that_never_finishes_goes_back_to_the_reviewer
    review
    @now = @task.metadata.dig("test_build", "deadline") + 1
    @github.runs[42]["status"] = "in_progress"
    @watcher.check_due
    assert_equal "waiting_for_review", @state.task(@task.id).state
    assert_includes @state.task(@task.id).metadata["test_build_failure"], "did not finish in time"
  end

  def test_the_watcher_thread_stops_when_asked
    @watcher.start
    @watcher.stop
    refute @watcher.instance_variable_get(:@thread).alive?
  end
end
