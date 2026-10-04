# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class PrWorktreeTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("ghwatch-pr-worktree")
    @root = Pathname(@directory).join("repository")
    @origin = Pathname(@directory).join("origin.git")
    @command = Ghwatch::Command.new
    git("init", "--bare", @origin.to_s, chdir: @directory)
    git("init", "-b", "master", @root.to_s, chdir: @directory)
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    @root.join("file.txt").write("base\n")
    git("add", "file.txt")
    git("commit", "-m", "Base")
    git("remote", "add", "origin", @origin.to_s)
    git("switch", "-c", "agent/issue-160")
    @root.join("file.txt").write("PR\n")
    git("commit", "-am", "PR")
    @head = git("rev-parse", "HEAD").strip
    git("push", "origin", "HEAD:refs/pull/164/head")
    git("switch", "master")
    @root.join("user.txt").write("user work\n")
    @task = Ghwatch::Task.for_pr(164)
    @pr = {"headRefName" => "agent/issue-160", "headRefOid" => @head,
           "headRepository" => {"nameWithOwner" => "owner/project"}}
    @state = Object.new
    def @state.save_task(task) = task
    @manager = Ghwatch::WorktreeManager.new(
      project: Ghwatch::Project.new(root: @root, git_dir: @root.join(".git")),
      config: OpenStruct.new(worktree_root: ".worktrees"), github: nil,
      command: @command, log: Ghwatch::Log.new(StringIO.new)
    )
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_prepares_existing_pr_and_preserves_local_work_on_resume_and_cleanup
    @manager.prepare_pull_request(@task, @pr, state: @state)
    path = Pathname(@task.worktree)
    assert_equal @head, git("rev-parse", "HEAD", chdir: path).strip
    assert_equal "ghwatch/pr-164", git("branch", "--show-current", chdir: path).strip
    assert_equal "agent/issue-160", @task.branch
    assert_equal "master", git("branch", "--show-current").strip
    assert_equal "user work\n", @root.join("user.txt").read

    path.join("file.txt").write("unfinished repair\n")
    @task.worktree = nil
    @manager.prepare_pull_request(@task, @pr, state: @state)
    assert_equal "unfinished repair\n", path.join("file.txt").read
    @manager.cleanup(@task)
    refute path.exist?
    assert_equal @head, git("rev-parse", "agent/issue-160").strip
    assert_equal "user work\n", @root.join("user.txt").read
  end

  def test_refuses_unowned_branch
    git("branch", "ghwatch/pr-164")
    assert_raises(RuntimeError) { @manager.prepare_pull_request(@task, @pr, state: @state) }
    assert_nil @task.worktree
    assert_equal git("rev-parse", "master"), git("rev-parse", "ghwatch/pr-164")
  end

  def test_refuses_head_that_changed_since_snapshot
    @pr["headRefOid"] = "stale-head"
    assert_raises(RuntimeError) { @manager.prepare_pull_request(@task, @pr, state: @state) }
    assert_nil @task.worktree
    refute @root.join(".worktrees/pr-164").exist?
  end

  private

  def git(*args, chdir: @root)
    result = @command.run("git", *args, chdir: chdir)
    raise result.text unless result.success?

    result.stdout
  end
end
