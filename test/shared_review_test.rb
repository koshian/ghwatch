# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class SharedReviewTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("ghwatch-shared-review")
    @root = Pathname(@directory).join("repository")
    @origin = Pathname(@directory).join("origin.git")
    git("init", "-q", "--bare", @origin.to_s, chdir: @directory)
    git("init", "-q", "-b", "master", @root.to_s, chdir: @directory)
    @root.join(".gitignore").write("target/\n")
    @root.join("file.txt").write("base\n")
    commit("Base")
    git("remote", "add", "origin", @origin.to_s)
    git("push", "-q", "origin", "master")
    @manager = Ghwatch::WorktreeManager.new(
      project: Ghwatch::Project.new(root: @root, git_dir: @root.join(".git")),
      config: OpenStruct.new(worktree_root: ".worktrees", branch_prefix: "ghwatch/issue-", screenshot_branch_prefix: "issue-assets/"),
      github: OpenStruct.new(default_branch: "master", repo_name: "owner/project"), command: Ghwatch::Command.new,
      log: Ghwatch::Log.new(StringIO.new)
    )
    branch, worktree = @manager.prepare(160)
    @path = Pathname(worktree)
    @path.join("file.txt").write("fix\n")
    commit("Fix", chdir: @path)
    publish(@path)
    @task = Ghwatch::Task.for_issue(160, branch: branch, worktree: worktree)
    @task.pr_number = 7
    @state = Object.new
    def @state.save_task(task) = task
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
    git("rev-parse", "HEAD", chdir: chdir).strip
  end

  def head(chdir = @path) = git("rev-parse", "HEAD", chdir: chdir).strip

  # Someone else's checkout of the PR, which pushes to it.
  def elsewhere
    other = Pathname(@directory).join("other")
    git("clone", "-q", @origin.to_s, other.to_s, chdir: @directory) unless other.exist?
    git("fetch", "-q", "origin", "refs/pull/7/head", chdir: other)
    git("checkout", "-q", "--detach", "FETCH_HEAD", chdir: other)
    other
  end

  def publish(from)
    git("push", "-q", "-f", "origin", "HEAD:refs/pull/7/head", chdir: from)
    @pr = {"number" => 7, "headRefOid" => head(from)}
  end

  def test_a_worktree_at_the_pr_head_or_behind_it_follows_it
    assert_equal :same, @manager.follow_pull_request(@task, @pr)

    other = elsewhere
    other.join("merged.txt").write("from the base\n")
    commit("Merge the base in", chdir: other)
    publish(other)
    @path.join("notes.log").write("scratch\n")
    assert_equal :fast_forward, @manager.follow_pull_request(@task, @pr)
    assert_equal @pr["headRefOid"], head
    assert_equal "ghwatch/issue-160", git("branch", "--show-current", chdir: @path).strip
    assert @path.join("notes.log").exist?
  end

  def test_a_rebase_that_kept_the_worker_commits_is_followed
    other = elsewhere
    git("checkout", "-q", "--detach", "origin/master", chdir: other)
    other.join("base.txt").write("newer base\n")
    commit("Newer base", chdir: other)
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "cherry-pick", head, chdir: other)
    publish(other)
    assert_equal :reset, @manager.follow_pull_request(@task, @pr)
    assert_equal @pr["headRefOid"], head
  end

  def test_what_would_be_lost_is_not_followed
    other = elsewhere
    other.join("theirs.txt").write("theirs\n")
    commit("Theirs", chdir: other)
    publish(other)
    @path.join("mine.txt").write("mine\n")
    mine = commit("Mine", chdir: @path)
    assert_match(/commits the PR does not: .*Mine/, @manager.follow_pull_request(@task, @pr))
    assert_equal mine, head

    git("reset", "-q", "--hard", "HEAD~1", chdir: @path)
    @path.join("file.txt").write("edited\n")
    assert_match(/tracked changes/, @manager.follow_pull_request(@task, @pr))
    git("checkout", "-q", "--", "file.txt", chdir: @path)

    git("checkout", "-q", "--detach", chdir: @path)
    assert_match(/not on its branch/, @manager.follow_pull_request(@task, @pr))
  end

  def test_what_a_review_leaves_behind_is_put_back_and_kept
    @path.join("notes.log").write("the worker's\n")
    before = head
    assert_equal @path.to_s, @manager.begin_shared_review(@task, state: @state)

    @path.join("target").mkpath
    @path.join("target/build.out").write("build\n")
    @path.join("evidence.png").write("png\n")
    @path.join("file.txt").write("reviewer edit\n")
    @path.join("other.txt").write("committed by the reviewer\n")
    git("add", "other.txt", chdir: @path)
    git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "Reviewer commit", chdir: @path)
    assert @manager.end_shared_review(@task, trigger: "after the reviewer run")

    assert_equal before, head
    assert_equal "ghwatch/issue-160", git("branch", "--show-current", chdir: @path).strip
    assert_equal "fix\n", @path.join("file.txt").read
    refute @path.join("other.txt").exist?
    refute @path.join("evidence.png").exist?
    assert_equal "the worker's\n", @path.join("notes.log").read
    assert_equal "build\n", @path.join("target/build.out").read, "build outputs stay for the next build"
    record = @task.metadata["shared_review_changes"].last
    assert_equal ["evidence.png"], record["moved"]
    assert_equal ["Reviewer commit"], record["commits"].map { |line| line.split(" ", 2).last }
    kept = Pathname(record["kept"])
    assert_includes kept.join("changes.patch").read, "reviewer edit"
    assert_equal "png\n", kept.join("files/evidence.png").read
    assert_nil @task.metadata["shared_review"]
  end

  def test_a_review_that_left_nothing_records_nothing
    @manager.begin_shared_review(@task, state: @state)
    @path.join("target").mkpath
    @path.join("target/build.out").write("build\n")
    refute @manager.end_shared_review(@task, trigger: "after the reviewer run")
    assert_nil @task.metadata["shared_review_changes"]
  end

  def test_the_review_runs_in_the_task_worktree_and_a_diverged_one_goes_to_a_person
    asked = []
    human = Object.new
    human.define_singleton_method(:wait) { |task:, body:, **| asked << body }
    roles = Object.new
    roles.define_singleton_method(:run) do |role, context:, cwd:, task:|
      cwd_seen = cwd
      Pathname(cwd_seen).join("left.txt").write("left\n")
      define_singleton_method(:cwd) { cwd_seen }
      Ghwatch::RoleRunner::Outcome.new(success: true, role: role, runner: "t", model: "t",
        data: {"status" => "comment", "body" => "ok"}, error_kind: nil, error: nil, raw_output: "")
    end
    github = Object.new
    pr = @pr.merge("state" => "OPEN", "headRefName" => "ghwatch/issue-160")
    github.define_singleton_method(:pull_request) { |number| pr }
    %i[issue_signature pr_signature review_signature].each { |name| github.define_singleton_method(name) { |*| "s" } }
    github.define_singleton_method(:issue) { |number| {"number" => number, "state" => "OPEN", "comments" => []} }
    github.define_singleton_method(:post_pr_comment) { |*args, **options| nil }
    config = OpenStruct.new(retry_after: 60, update_pr_branches?: false)
    reviewer = Ghwatch::Actions::Reviewer.new(worktrees: @manager, project: OpenStruct.new(root: @root), config: config,
      state: @state, github: github, roles: roles, context_builder: Ghwatch::ContextBuilder.new(config: config),
      human_channel: human, log: Ghwatch::Log.new(StringIO.new))
    @task.state = "waiting_for_review"
    reviewer.run(@task)
    assert_equal @path.to_s, roles.cwd
    refute @path.join("left.txt").exist?, "what the review left is moved out"

    @path.join("mine.txt").write("mine\n")
    commit("Mine", chdir: @path)
    other = elsewhere
    other.join("theirs.txt").write("theirs\n")
    commit("Theirs", chdir: other)
    publish(other)
    pr.replace(@pr.merge("state" => "OPEN", "headRefName" => "ghwatch/issue-160"))
    @task.state = "waiting_for_review"
    @task.metadata.delete("commented_review")
    reviewer.run(@task)
    assert_equal "waiting_for_human_input", @task.state
    assert_equal "waiting_for_review", @task.metadata["resume_state"]
    assert_includes asked.last, "Mine"
  end

  # A reviewer whose run returns data, recording what it posts and asks.
  def reviewer_returning(data)
    @posted = []
    @asked = []
    posted = @posted
    asked = @asked
    human = Object.new
    human.define_singleton_method(:wait) { |task:, body:, target:, **| asked << [target, body] }
    roles = Object.new
    roles.define_singleton_method(:run) do |role, context:, cwd:, task:|
      Pathname(cwd).join("target/shots").mkpath
      Pathname(cwd).join("target/shots/dark.png").write("png")
      Pathname(cwd).join("light.png").write("png")
      Ghwatch::RoleRunner::Outcome.new(success: true, role: role, runner: "t", model: "t", data: data,
        error_kind: nil, error: nil, raw_output: "")
    end
    github = Object.new
    pr = @pr.merge("state" => "OPEN", "headRefName" => "ghwatch/issue-160")
    github.define_singleton_method(:pull_request) { |number| pr }
    %i[issue_signature pr_signature review_signature].each { |name| github.define_singleton_method(name) { |*| "s" } }
    github.define_singleton_method(:issue) { |number| {"number" => number, "state" => "OPEN", "comments" => []} }
    github.define_singleton_method(:post_pr_comment) { |number, body, **options| posted << body }
    config = OpenStruct.new(retry_after: 60, update_pr_branches?: false)
    @task.state = "waiting_for_review"
    Ghwatch::Actions::Reviewer.new(worktrees: @manager, project: OpenStruct.new(root: @root), config: config,
      state: @state, github: github, roles: roles, context_builder: Ghwatch::ContextBuilder.new(config: config),
      human_channel: human, log: Ghwatch::Log.new(StringIO.new))
  end

  def screenshot_check(**changes)
    {"status" => "waiting_for_human_test", "human_check" => "screenshots", "body" => "Look at 1 and 2.",
     "reporter_message" => "Please look at screenshots 1 and 2.",
     "screenshots" => [{"path" => "target/shots/dark.png", "caption" => "Dark menu"},
       {"path" => "light.png", "caption" => "Light menu"}]}.merge(changes)
  end

  def test_screenshots_to_look_at_are_published_and_shown_in_the_request
    reviewer_returning(screenshot_check).run(@task)
    assert_equal "waiting_for_human_test", @task.state
    target, message = @asked.last
    assert_equal :issue, target
    commit = message[%r{blob/(\h{40})/}, 1]
    assert commit, message
    assert_includes message, "**1. Dark menu**"
    assert_includes message, "![Light menu](https://github.com/owner/project/blob/#{commit}/02-light.png?raw=true)"
    assert_includes @posted.last, "01-dark.png"
    branch = git("ls-remote", "--heads", @origin.to_s, "issue-assets/*").split.last
    assert_match %r{\Arefs/heads/issue-assets/issue-160-}, branch
    assert_equal %w[01-dark.png 02-light.png], git("ls-tree", "--name-only", commit).split
    refute @path.join("light.png").exist?, "moved out of the worktree, yet still published"
  end

  def test_a_screenshot_check_with_nothing_to_show_is_reviewed_again
    [screenshot_check("screenshots" => []),
      screenshot_check("screenshots" => [{"path" => "../outside.png", "caption" => "x"}]),
      screenshot_check("screenshots" => [{"path" => "file.txt", "caption" => "x"}])].each do |data|
      reviewer_returning(data).run(@task)
      assert_equal "waiting_for_review", @task.state
      assert_match(/screenshots could not be shown/, @task.last_error)
      assert @task.retry_at
      assert_empty @asked
      assert_empty @posted
    end
  end

  def test_a_run_check_is_asked_even_when_its_screenshots_cannot_be_published
    data = screenshot_check("human_check" => "run", "screenshots" => [{"path" => "missing.png", "caption" => "x"}])
    reviewer_returning(data).run(@task)
    assert_equal "waiting_for_human_test", @task.state
    assert_equal "Please look at screenshots 1 and 2.", @asked.last.last
  end
end
