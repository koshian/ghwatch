# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class MergeChecksTest < Minitest::Test
  class Github < Ghwatch::Github
    attr_accessor :pr
    attr_reader :reruns, :comments

    def initialize(pr)
      super(project: nil, command: nil)
      @pr = pr
      @reruns = []
      @comments = []
    end

    def issue(number) = {"number" => number, "state" => "OPEN"}

    def issue_signature(issue) = "issue"

    def pull_request(number) = @pr

    def pr_signature(pr) = "pr"

    def review_signature(pr) = "review"

    def rerun_failed_checks(pr) = @reruns << pr["headRefOid"]

    def merge_pull_request(number, method:) = raise("must not merge")
  end

  class HumanChannel
    attr_reader :asked

    def initialize = @asked = []

    def wait(task:, body:, outcome:, kind:, target:)
      @asked << body
      task.human_marker = "marker"
    end
  end

  def checks(linux)
    [{"name" => "Linux x86_64", "status" => "COMPLETED", "conclusion" => linux,
      "detailsUrl" => "https://github.com/o/r/actions/runs/39/job/11"},
      {"name" => "Windows", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
  end

  def setup
    @github = Github.new({"number" => 5, "state" => "OPEN", "mergeable" => "MERGEABLE", "headRefOid" => "h1",
                          "statusCheckRollup" => checks("FAILURE")})
    @human = HumanChannel.new
    @task = Ghwatch::Task.for_issue(4, branch: "b", worktree: nil)
    @task.pr_number = 5
    @task.state = "ready_to_merge"
    @task.last_review_signature = "review"
    config = OpenStruct.new(auto_merge?: true, reviewer_requires_green_checks?: true, merge_method: "merge", retry_after: 60)
    @reviewer = Ghwatch::Actions::Reviewer.new(project: nil, config: config, state: Struct.new(:x) { def save_task(task) = task }.new,
      github: @github, roles: nil, context_builder: nil, human_channel: @human, log: Ghwatch::Log.new(StringIO.new))
  end

  def test_an_approved_pr_with_failed_checks_reruns_them_once_then_asks
    @reviewer.attempt_merge(@task)
    assert_equal ["h1"], @github.reruns
    assert_equal "ready_to_merge", @task.state
    assert @task.retry_at

    @github.pr["statusCheckRollup"].first["status"] = "IN_PROGRESS"
    @reviewer.attempt_merge(@task)
    assert_equal ["h1"], @github.reruns, "running checks are waited for"
    assert_empty @human.asked

    @github.pr["statusCheckRollup"] = checks("FAILURE")
    @reviewer.attempt_merge(@task)
    assert_equal ["h1"], @github.reruns
    assert_equal "waiting_for_human_input", @task.state
    assert_equal "waiting_for_review", @task.metadata["resume_state"]
    assert_includes @human.asked.first, "Linux x86_64"
  end

  def test_a_new_head_gets_its_own_rerun
    @reviewer.attempt_merge(@task)
    @github.pr["headRefOid"] = "h2"
    @reviewer.attempt_merge(@task)
    assert_equal %w[h1 h2], @github.reruns
    assert_empty @human.asked
  end

  def test_github_reruns_the_failed_jobs_of_each_failed_run_once
    command = Object.new
    calls = []
    command.define_singleton_method(:run) do |*args, **options|
      calls << args
      Ghwatch::Command::Result.new(argv: args, stdout: "", stderr: "", exit_code: 0, timed_out: false)
    end
    github = Ghwatch::Github.new(project: OpenStruct.new(root: "."), command: command)
    pr = {"statusCheckRollup" => checks("FAILURE") + checks("CANCELLED")}
    github.rerun_failed_checks(pr)
    assert_equal [%w[gh run rerun 39 --failed]], calls
  end
end
