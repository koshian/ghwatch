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
      config: OpenStruct.new(worktree_root: ".worktrees", human_wait_cleanup: "git clean -fdX"), github: nil,
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

  def test_review_workspace_is_detached_updates_to_new_head_and_preserves_worker_work
    @manager.prepare_pull_request(@task, @pr, state: @state)
    worker_path = Pathname(@task.worktree)
    worker_path.join("file.txt").write("unfinished worker repair\n")
    review_path = Pathname(@manager.prepare_review(@task, @pr, state: @state))
    assert_equal "", git("branch", "--show-current", chdir: review_path).strip
    assert_equal @head, git("rev-parse", "HEAD", chdir: review_path).strip
    review_path.join("test.log").write("review evidence\n")

    git("switch", "agent/issue-160")
    @root.join("file.txt").write("updated PR\n")
    git("commit", "-am", "Update PR")
    @pr["headRefOid"] = git("rev-parse", "HEAD").strip
    git("push", "origin", "HEAD:refs/pull/164/head")
    git("switch", "master")
    assert_equal review_path.to_s, @manager.prepare_review(@task, @pr, state: @state)
    assert_equal @pr["headRefOid"], git("rev-parse", "HEAD", chdir: review_path).strip
    assert_equal "updated PR\n", review_path.join("file.txt").read
    assert_equal "review evidence\n", review_path.join("test.log").read
    assert_equal "unfinished worker repair\n", worker_path.join("file.txt").read
    @manager.cleanup_review(@task)
    refute review_path.exist?
    assert worker_path.exist?
    refute @task.metadata.key?("review_worktree")
  end

  def test_review_workspace_refuses_unowned_paths_and_preserves_tracked_changes
    path = @root.join(".worktrees/review-pr-164")
    FileUtils.mkdir_p(path)
    path.join("user.txt").write("unrelated\n")
    assert_raises(RuntimeError) { @manager.prepare_review(@task, @pr, state: @state) }
    assert_equal "unrelated\n", path.join("user.txt").read
    FileUtils.remove_entry(path)
    @manager.prepare_review(@task, @pr, state: @state)
    path.join("file.txt").write("unexpected source edit\n")
    assert_raises(RuntimeError) { @manager.prepare_review(@task, @pr, state: @state) }
    assert_raises(RuntimeError) { @manager.cleanup_review(@task) }
    assert_equal "unexpected source edit\n", path.join("file.txt").read
  end

  def test_human_wait_removes_review_workspace_and_ignored_outputs_once
    @root.join(".git/info/exclude").write("target/\n")
    @manager.prepare_pull_request(@task, @pr, state: @state)
    worker_path = Pathname(@task.worktree)
    review_path = Pathname(@manager.prepare_review(@task, @pr, state: @state))
    worker_path.join("target").mkpath
    worker_path.join("target/app").write("binary\n")
    worker_path.join("file.txt").write("unfinished repair\n")
    worker_path.join("notes.txt").write("untracked\n")
    @task.human_marker = "first"

    @manager.release_for_human_wait(@task)
    refute review_path.exist?
    refute @task.metadata.key?("review_worktree")
    refute worker_path.join("target").exist?
    assert_equal "unfinished repair\n", worker_path.join("file.txt").read
    assert_equal "untracked\n", worker_path.join("notes.txt").read

    worker_path.join("target").mkpath
    @manager.release_for_human_wait(@task)
    assert worker_path.join("target").exist?
    @task.human_marker = "second"
    @manager.release_for_human_wait(@task)
    refute worker_path.join("target").exist?
  end

  def test_human_wait_cleanup_can_be_disabled_and_never_runs_outside_worktrees
    @root.join(".git/info/exclude").write("target/\n")
    @root.join("target").mkpath
    @task.worktree = @root.to_s
    @task.human_marker = "marker"
    @manager.release_for_human_wait(@task)
    assert @root.join("target").exist?

    @task.worktree = nil
    @task.metadata.clear
    @manager.prepare_pull_request(@task, @pr, state: @state)
    worker_path = Pathname(@task.worktree)
    worker_path.join("target").mkpath
    @manager.instance_variable_get(:@config).human_wait_cleanup = nil
    @manager.release_for_human_wait(@task)
    assert worker_path.join("target").exist?
  end

  def test_review_cleanup_removes_read_only_outputs
    path = Pathname(@manager.prepare_review(@task, @pr, state: @state))
    cache = path.join("target/tmp/gopath/pkg/mod/example")
    cache.mkpath
    cache.join("go.mod").write("module example\n")
    FileUtils.chmod(0o444, cache.join("go.mod"))
    FileUtils.chmod(0o555, cache)
    @manager.cleanup_review(@task)
    refute path.exist?
    refute @task.metadata.key?("review_worktree")
  end

  def test_review_leftover_after_git_forgot_it_is_removed_and_recreated
    path = Pathname(@manager.prepare_review(@task, @pr, state: @state))
    FileUtils.rm_rf(@root.join(".git/worktrees/review-pr-164"))
    assert_equal path.to_s, @manager.prepare_review(@task, @pr, state: @state)
    assert_equal @head, git("rev-parse", "HEAD", chdir: path).strip

    FileUtils.rm_rf(@root.join(".git/worktrees/review-pr-164"))
    @manager.cleanup_review(@task)
    refute path.exist?
  end

  def test_review_cleanup_keeps_unrelated_unregistered_directories
    @manager.prepare_review(@task, @pr, state: @state)
    path = @root.join(".worktrees/review-pr-164")
    git("worktree", "remove", "--force", path.to_s)
    path.mkpath
    path.join("notes.txt").write("someone else's\n")
    assert_raises(RuntimeError) { @manager.cleanup_review(@task) }
    assert_equal "someone else's\n", path.join("notes.txt").read
  end

  def test_restores_a_removed_task_worktree_with_its_commits
    @manager.prepare_pull_request(@task, @pr, state: @state)
    path = Pathname(@task.worktree)
    path.join("file.txt").write("local repair\n")
    git("commit", "-am", "Local repair", chdir: path)
    FileUtils.rm_rf(path)
    @manager.restore_task_worktree(@task)
    assert_equal "local repair\n", path.join("file.txt").read
    assert_equal "ghwatch/pr-164", git("branch", "--show-current", chdir: path).strip

    FileUtils.rm_rf(path)
    git("worktree", "prune")
    git("branch", "-D", "ghwatch/pr-164")
    @manager.restore_task_worktree(@task)
    assert_equal @head, git("rev-parse", "HEAD", chdir: path).strip
  end

  def test_tracked_changes_in_a_review_workspace_are_recorded_not_reverted
    path = Pathname(@manager.prepare_review(@task, @pr, state: @state))
    refute @manager.record_workspace_changes(@task, trigger: "after the reviewer run (test)")

    path.join("file.txt").delete
    assert @manager.record_workspace_changes(@task, trigger: "after the reviewer run (test)")
    refute @manager.record_workspace_changes(@task, trigger: "at ghwatch startup")
    record = @task.metadata["workspace_changes"].last
    assert_equal [" D file.txt"], record["files"]
    assert_equal "after the reviewer run (test)", record["trigger"]
    refute path.join("file.txt").exist?

    7.times do |index|
      path.join("extra-#{index}.txt").write("x")
      git("add", "extra-#{index}.txt", chdir: path)
      @manager.record_workspace_changes(@task, trigger: "run #{index}")
    end
    assert_equal Ghwatch::WorktreeManager::WORKSPACE_CHANGE_RECORDS, @task.metadata["workspace_changes"].size
  end

  def test_detects_a_pr_head_behind_its_base
    @pr["baseRefName"] = "master"
    git("push", "origin", "master")
    refute @manager.behind_base?(@task, @pr)

    @root.join("tools.txt").write("newer test tools\n")
    git("add", "tools.txt")
    git("commit", "-m", "Add tools")
    git("push", "origin", "master")
    assert @manager.behind_base?(@task, @pr)

    @pr["headRefOid"] = "stale-head"
    refute @manager.behind_base?(@task, @pr)
  end

  def test_review_workspace_rejects_a_stale_snapshot
    @pr["headRefOid"] = "stale-head"
    assert_raises(RuntimeError) { @manager.prepare_review(@task, @pr, state: @state) }
    refute @task.metadata.key?("review_worktree")
    refute @root.join(".worktrees/review-pr-164").exist?
  end

  private

  def git(*args, chdir: @root)
    result = @command.run("git", *args, chdir: chdir)
    raise result.text unless result.success?

    result.stdout
  end
end
