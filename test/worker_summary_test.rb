# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class WorkerSummaryTest < Minitest::Test
  class Github
    attr_accessor :head
    attr_reader :posted

    def initialize = @posted = []

    def pull_request(number) = {"number" => number, "headRefOid" => head, "baseRefName" => "main"}

    def post_pr_comment(number, body, kind:, model_signature:) = @posted << [number, kind, body]
  end

  def setup
    @repo = Dir.mktmpdir("ghwatch-summary")
    git("init", "-q", "-b", "main")
    @base = commit("base")
    git("update-ref", "refs/remotes/origin/main", @base)
    @first = commit("Fix the caret in dark inputs")
    @second = commit("Cover settings fields too")
    @github = Github.new
    @worker = Ghwatch::Actions::Worker.new(
      worktrees: nil, command: Ghwatch::Command.new(log: Ghwatch::Log.new(StringIO.new)),
      project: OpenStruct.new(root: @repo), config: OpenStruct.new(retry_after: 60), state: nil,
      github: @github, roles: nil, context_builder: nil, human_channel: nil, issue_triage: nil,
      log: Ghwatch::Log.new(StringIO.new)
    )
    @task = Ghwatch::Task.for_issue(219, branch: "b", worktree: @repo)
    @task.pr_number = 230
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  def git(*args) = Ghwatch::Command.new(log: Ghwatch::Log.new(StringIO.new)).run("git", "-C", @repo, *args).stdout.strip

  def commit(message)
    File.write(File.join(@repo, "file.txt"), message)
    git("add", "file.txt")
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", message)
    git("rev-parse", "HEAD")
  end

  def outcome(summary) = OpenStruct.new(data: {"status" => "waiting_for_review", "summary" => summary}, signature: "worker")

  def test_a_push_is_explained_with_the_summary_and_its_commits
    @github.head = @second
    @worker.send(:post_summary, @task, outcome("Settings fields now use the light caret."), @first)
    number, kind, body = @github.posted.last
    assert_equal [230, "worker-summary"], [number, kind]
    assert body.start_with?("Settings fields now use the light caret.")
    assert_includes body, "Cover settings fields too"
    refute_includes body, "Fix the caret in dark inputs", "only commits of this push"
  end

  def test_a_new_pr_lists_its_commits_from_the_base_and_a_missing_summary_still_lists_them
    @github.head = @second
    @worker.send(:post_summary, @task, outcome(nil), nil)
    body = @github.posted.last.last
    assert_includes body, "Fix the caret in dark inputs"
    assert_includes body, "Cover settings fields too"
    refute_includes body, " base"
  end

  def test_nothing_is_posted_without_a_push_or_a_summary
    @github.head = @second
    @worker.send(:post_summary, @task, outcome(""), @second)
    assert_empty @github.posted
  end
end
