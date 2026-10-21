# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class HandoffTest < Minitest::Test
  class Github
    attr_accessor :pr

    def pull_request(number) = pr
  end

  class HumanChannel
    attr_reader :asked

    def initialize = @asked = []

    def wait(task:, body:, outcome:, kind:, target:)
      @asked << [target, body]
      task.human_marker = "marker"
    end
  end

  def setup
    @directory = Dir.mktmpdir("ghwatch-handoff")
    @root = Pathname(@directory).join("repository")
    origin = Pathname(@directory).join("origin.git")
    git("init", "-q", "--bare", origin.to_s, chdir: @directory)
    git("init", "-q", "-b", "master", @root.to_s, chdir: @directory)
    @root.join("file.txt").write("base\n")
    git("add", "file.txt")
    commit("Base")
    git("remote", "add", "origin", origin.to_s)
    git("push", "-q", "origin", "master")
    config = OpenStruct.new(worktree_root: ".worktrees", branch_prefix: "ghwatch/issue-", retry_after: 60)
    @manager = Ghwatch::WorktreeManager.new(
      project: Ghwatch::Project.new(root: @root, git_dir: @root.join(".git")), config: config,
      github: OpenStruct.new(default_branch: "master"), command: Ghwatch::Command.new, log: Ghwatch::Log.new(StringIO.new)
    )
    branch, worktree = @manager.prepare(160)
    @path = Pathname(worktree)
    @path.join("file.txt").write("fix\n")
    commit("Fix", chdir: @path)
    @github = Github.new
    push_pr
    @task = Ghwatch::Task.for_issue(160, branch: branch, worktree: worktree)
    @task.state = "implementing"
    @human = HumanChannel.new
    @worker = Ghwatch::Actions::Worker.new(
      worktrees: @manager, command: Ghwatch::Command.new, project: OpenStruct.new(root: @root), config: config,
      state: nil, github: @github, roles: nil, context_builder: nil, human_channel: @human,
      log: Ghwatch::Log.new(StringIO.new)
    )
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def git(*args, chdir: @root)
    result = Ghwatch::Command.new.run("git", *args, chdir: chdir)
    raise result.text unless result.success?

    result.stdout
  end

  def commit(message, chdir: @root)
    git("add", "-A", chdir: chdir)
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", message, chdir: chdir)
  end

  def push_pr
    head = git("rev-parse", "HEAD", chdir: @path).strip
    git("push", "-q", "-f", "origin", "HEAD:refs/pull/7/head", chdir: @path)
    @github.pr = {"number" => 7, "headRefOid" => head, "headRefName" => "ghwatch/issue-160", "mergeable" => "MERGEABLE"}
  end

  def hand_over
    outcome = OpenStruct.new(data: {"status" => "waiting_for_review", "pr" => 7}, signature: "worker")
    @worker.send(:apply_result, @task, outcome)
  end

  def test_a_pushed_worktree_may_keep_untracked_files
    @path.join("notes.log").write("scratch\n")
    assert_nil @manager.handoff_problem(@task, @github.pr)
    hand_over
    assert_equal "waiting_for_review", @task.state
  end

  def test_what_the_pr_lacks_sends_the_worker_back_once_then_a_person_decides
    @path.join("file.txt").write("more\n")
    hand_over
    assert_equal "continuing", @task.state
    assert_includes @task.metadata["rework_reason"], "file.txt"
    assert @task.retry_at

    commit("More", chdir: @path)
    hand_over
    assert_equal "waiting_for_human_input", @task.state
    assert_equal "waiting_for_review", @task.metadata["resume_state"]
    target, body = @human.asked.last
    assert_equal :pull_request, target
    assert_includes body, "More"

    @task.state = "implementing"
    push_pr
    hand_over
    assert_equal "waiting_for_review", @task.state
    assert_nil @task.metadata["rework_reason"]
    assert_nil @task.metadata["handoff_returns"]
  end
end
