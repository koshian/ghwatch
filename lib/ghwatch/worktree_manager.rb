# frozen_string_literal: true

require "fileutils"

module Ghwatch
  class WorktreeManager
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
      if path.exist?
        result = git_result("worktree", "remove", "--force", path.to_s)
        unless result.success?
          @log.warn("git worktree remove failed for #{path}; removing reserved ghwatch worktree directory")
          FileUtils.rm_rf(path)
        end
      end

      git_result("worktree", "prune")
      branch = task.metadata["local_branch"] || task.branch
      delete_branch(branch) if branch && branch_exists?(branch)
    end

    def prepare_review(task, pull_request, state:)
      path = @project.root.join(@config.worktree_root, "review-pr-#{task.pr_number}")
      owned = task.metadata["review_worktree"] == path.to_s
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

      if registered_worktree?(path)
        verify_review_workspace(path)
        git("worktree", "remove", "--force", path.to_s)
      elsif path.exist?
        raise "review workspace is no longer registered: #{path}"
      end
      task.metadata.delete("review_worktree")
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
