# frozen_string_literal: true

require "fileutils"
require "find"
require "time"

module Ghwatch
  class WorktreeManager
    WORKSPACE_CHANGE_RECORDS = 5

    def initialize(project:, config:, github:, command:, log: Log.new)
      @project = project
      @config = config
      @github = github
      @command = command
      @log = log
    end

    def branch_for(issue_number)
      "#{@config.branch_prefix}#{issue_number}"
    end

    def path_for(issue_number)
      @project.root.join(@config.worktree_root, "issue-#{issue_number}")
    end

    def prepare(issue_number)
      branch = branch_for(issue_number)
      path = path_for(issue_number)
      FileUtils.mkdir_p(path.dirname)

      return [branch, path.to_s] if registered_worktree?(path)

      if path.exist?
        @log.warn("removing orphaned ghwatch worktree directory #{path}")
        FileUtils.rm_rf(path)
      end

      fetch_default_branch

      if branch_exists?(branch)
        git("worktree", "add", path.to_s, branch)
      else
        git("worktree", "add", "-b", branch, path.to_s, "origin/#{@github.default_branch}")
      end

      [branch, path.to_s]
    end

    def cleanup(task)
      cleanup_review(task)
      return unless task.worktree

      path = Pathname(task.worktree)
      remove_worktree(path) if path.exist?
      git_result("worktree", "prune")
      branch = task.metadata["local_branch"] || task.branch
      delete_branch(branch) if branch && branch_exists?(branch)
    end

    def prepare_review(task, pull_request, state:)
      path = @project.root.join(@config.worktree_root, "review-pr-#{task.pr_number}")
      owned = task.metadata["review_worktree"] == path.to_s
      remove_leftover(path) if owned && path.exist? && !registered_worktree?(path)
      registered = registered_worktree?(path)
      raise "reserved review workspace already exists: #{path}" if !owned && (path.exist? || registered)
      verify_review_workspace(path) if registered

      git("fetch", "origin", pull_request["baseRefName"]) if pull_request["baseRefName"]
      git("fetch", "origin", "refs/pull/#{task.pr_number}/head")
      head = git("rev-parse", "FETCH_HEAD").strip
      raise "PR head changed while preparing review; retry" unless head == pull_request.fetch("headRefOid")

      task.metadata["review_worktree"] = path.to_s
      state.save_task(task)
      if registered
        git("-C", path.to_s, "checkout", "--detach", head)
      else
        raise "reserved review workspace directory already exists: #{path}" if path.exist?

        FileUtils.mkdir_p(path.dirname)
        git("worktree", "add", "--detach", path.to_s, head)
      end
      @log.info("[#{task.id}] prepared review workspace #{path} at #{head}")
      path.to_s
    end

    def cleanup_review(task)
      stored_path = task.metadata["review_worktree"]
      return unless stored_path

      path = @project.root.join(@config.worktree_root, "review-pr-#{task.pr_number}")
      raise "review workspace ownership changed" unless stored_path == path.to_s

      if registered_worktree?(path) && path.exist?
        verify_review_workspace(path)
        remove_worktree(path)
      elsif path.exist?
        remove_leftover(path)
      end
      git_result("worktree", "prune")
      task.metadata.delete("review_worktree")
    end

    # Reviewers must not change tracked files, yet review workspaces have been
    # found with some deleted. Each finding is kept on the task (newest last,
    # with what had just happened) so the cause can be traced; nothing is
    # reverted, since that would erase the evidence.
    def record_workspace_changes(task, trigger:)
      path = task.metadata["review_worktree"] && Pathname(task.metadata["review_worktree"])
      return false unless path&.exist? && registered_worktree?(path)

      files = git("-C", path.to_s, "status", "--porcelain", "--untracked-files=no").lines.map(&:chomp)
      records = Array(task.metadata["workspace_changes"])
      return false if files.empty? || records.last&.fetch("files", nil) == files

      records << {"at" => Time.now.utc.iso8601, "trigger" => trigger, "files" => files}
      task.metadata["workspace_changes"] = records.last(WORKSPACE_CHANGE_RECORDS)
      @log.warn("[#{task.id}] review workspace #{path} has tracked changes #{trigger}: #{files.first(5).map(&:strip).join(", ")}" \
        "#{", ..." if files.size > 5}")
      true
    end

    # Recreates a task worktree whose directory has gone (removed by hand or
    # by an interrupted cleanup) from its local branch, or else from the PR
    # head or the pushed task branch, so the next agent has a workspace again.
    def restore_task_worktree(task)
      return unless task.worktree

      path = Pathname(task.worktree)
      return if path.exist? && registered_worktree?(path)
      raise "task worktree is outside #{@config.worktree_root}: #{path}" unless inside_worktree_root?(path)
      raise "task worktree directory exists but is not a registered worktree: #{path}" if path.exist?

      git_result("worktree", "prune")
      branch = task.metadata["local_branch"] || task.branch
      FileUtils.mkdir_p(path.dirname)
      if branch_exists?(branch)
        git("worktree", "add", path.to_s, branch)
      else
        git("fetch", "origin", task.pr_number ? "refs/pull/#{task.pr_number}/head" : task.branch)
        git("worktree", "add", "-b", branch, path.to_s, "FETCH_HEAD")
      end
      @log.info("[#{task.id}] restored missing task worktree #{path} on #{branch}")
    end

    # True when the PR head does not contain its base branch's current head,
    # so reviewing it would miss newer base changes (including test tools).
    def behind_base?(task, pull_request)
      base = pull_request["baseRefName"]
      return false unless base

      git("fetch", "origin", base)
      git("fetch", "origin", "refs/pull/#{task.pr_number}/head")
      head = git("rev-parse", "FETCH_HEAD").strip
      return false unless head == pull_request.fetch("headRefOid")

      result = git_result("merge-base", "--is-ancestor", "refs/remotes/origin/#{base}", head)
      raise "git merge-base failed: #{result.text.strip}" unless [0, 1].include?(result.exit_code)

      result.exit_code == 1
    end

    # Frees disk while a person is expected to respond. The review workspace is
    # recreated by the next review; the task worktree keeps its source and commits.
    def release_for_human_wait(task)
      cleanup_review(task)
      return if task.metadata["human_wait_cleanup_marker"] == task.human_marker

      command = @config.human_wait_cleanup
      path = task.worktree && Pathname(task.worktree)
      if command && path && inside_worktree_root?(path) && registered_worktree?(path)
        result = @command.run("sh", "-c", command, chdir: path, timeout: 600)
        if result.success?
          @log.info("[#{task.id}] released build outputs in #{path} while waiting for a person")
        else
          @log.warn("[#{task.id}] human wait cleanup failed in #{path}: #{result.text.strip}")
        end
      end
      task.metadata["human_wait_cleanup_marker"] = task.human_marker
    end

    def prepare_pull_request(task, pull_request, state:)
      raise "cannot prepare a PR without its head repository" unless pull_request.dig("headRepository", "nameWithOwner")

      branch = "ghwatch/pr-#{task.pr_number}"
      path = @project.root.join(@config.worktree_root, "pr-#{task.pr_number}")
      owned = task.metadata["pr_workspace_path"] == path.to_s && task.metadata["local_branch"] == branch
      if owned && registered_worktree?(path)
        raise "PR workspace branch changed: #{path}" unless git("-C", path.to_s, "symbolic-ref", "--short", "HEAD").strip == branch

        task.worktree = path.to_s
        return
      end
      raise "reserved PR workspace or branch already exists: #{path}" if path.exist? || (!owned && branch_exists?(branch))

      FileUtils.mkdir_p(path.dirname)
      git("fetch", "origin", "refs/pull/#{task.pr_number}/head")
      head = git("rev-parse", "FETCH_HEAD").strip
      raise "PR head changed while preparing its workspace; retry" unless head == pull_request.fetch("headRefOid")

      task.branch = pull_request.fetch("headRefName")
      task.metadata["local_branch"] = branch
      task.metadata["pr_workspace_path"] = path.to_s
      task.metadata["pr_head_repository"] = pull_request.dig("headRepository", "nameWithOwner")
      state.save_task(task)
      if branch_exists?(branch)
        git("worktree", "add", path.to_s, branch)
      else
        git("worktree", "add", "-b", branch, path.to_s, head)
      end
      task.worktree = path.to_s
      @log.info("[#{task.id}] prepared PR workspace #{path}")
    end

    private

    def verify_review_workspace(path)
      raise "review workspace is on a branch: #{path}" if git_result("-C", path.to_s, "symbolic-ref", "--quiet", "HEAD").success?
      raise "review workspace has tracked changes: #{path}" unless git("-C", path.to_s, "status", "--porcelain", "--untracked-files=no").strip.empty?
    end

    # Some tools write read-only files (Go's module cache), which make both
    # git worktree remove and rm_rf stop halfway; make them writable first.
    def remove_worktree(path)
      return if git_result("worktree", "remove", "--force", path.to_s).success?

      make_writable(path)
      return if git_result("worktree", "remove", "--force", path.to_s).success?

      @log.warn("git worktree remove failed for #{path}; removing reserved ghwatch worktree directory")
      FileUtils.rm_rf(path)
      raise "could not remove #{path}" if path.exist?
    end

    # A directory left after git forgot the worktree. Removed only when its
    # .git file still names this worktree's (now missing) administrative
    # directory, so unrelated directories are never deleted.
    def remove_leftover(path)
      link = path.join(".git")
      gitdir = link.file? && link.read[/\Agitdir: (.+)$/, 1]
      unless gitdir && File.basename(gitdir) == path.basename.to_s &&
          File.basename(File.dirname(gitdir)) == "worktrees" && !File.exist?(gitdir)
        raise "review workspace is no longer registered: #{path}"
      end

      @log.warn("removing leftover of an unregistered ghwatch worktree #{path}")
      make_writable(path)
      FileUtils.rm_rf(path)
    end

    def make_writable(path)
      Find.find(path.to_s) do |entry|
        stat = File.lstat(entry)
        File.chmod(stat.mode | 0o700, entry) if stat.directory?
      end
    end

    def inside_worktree_root?(path)
      root = @project.root.join(@config.worktree_root).expand_path
      path.expand_path.to_s.start_with?("#{root}/")
    end

    def fetch_default_branch
      git("fetch", "origin", @github.default_branch)
    end

    def branch_exists?(branch)
      git_result("show-ref", "--verify", "--quiet", "refs/heads/#{branch}").success?
    end

    def registered_worktree?(path)
      result = git_result("worktree", "list", "--porcelain")
      result.success? && result.stdout.lines.any? { |line| line.strip == "worktree #{path.expand_path}" }
    end

    def delete_branch(branch)
      result = git_result("branch", "-D", branch)
      @log.warn("could not delete branch #{branch}: #{result.text.strip}") unless result.success?
    end

    def git(*args)
      result = git_result(*args)
      raise "git #{args.join(" ")} failed: #{result.text.strip}" unless result.success?

      result.stdout
    end

    def git_result(*args)
      @command.run("git", *args, chdir: @project.root, timeout: 300)
    end
  end
end
