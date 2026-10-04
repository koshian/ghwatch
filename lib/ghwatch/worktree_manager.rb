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
      delete_branch(task.branch) if task.branch && branch_exists?(task.branch)
    end

    private

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
      raise "git #{args.join(' ')} failed: #{result.text.strip}" unless result.success?

      result.stdout
    end

    def git_result(*args)
      @command.run("git", *args, chdir: @project.root, timeout: 300)
    end
  end
end
