# frozen_string_literal: true

require "fileutils"
require "find"
require "time"

module Ghwatch
  class WorktreeManager
    WORKSPACE_CHANGE_RECORDS = 5
    SCREENSHOT_TYPES = %w[.png .jpg .jpeg .gif .webp].freeze
    SCREENSHOT_LIMIT = 10 * 1024 * 1024

    class ScreenshotError < StandardError; end

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

    # True when two heads of a PR make the same change to its base, as after
    # "Update branch" merged the base in. Compared by the patch id of each
    # head's diff from its fork point, so a base change next to the PR's own
    # lines, or any other edit, counts as a change; so does a head Git lacks.
    def same_changes?(task, base:, from:, to:)
      return true if from == to
      return false unless base && from && to

      git("fetch", "origin", base)
      git("fetch", "origin", "refs/pull/#{task.pr_number}/head")
      ids = [from, to].map { |head| change_id(base, head) }
      !ids.first.nil? && ids.first == ids.last
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

    # The review runs in the task worktree, reusing what the worker built,
    # unless ghwatch only reviews the PR (no worktree of its own).
    def shared_review?(task)
      !task.metadata["review_only"] && !task_worktree(task).nil?
    end

    # What keeps a hand-off from being merged as it is: tracked changes left
    # in the task worktree, or commits the PR does not have. nil when there is
    # nothing, or no worktree to look at.
    def handoff_problem(task, pull_request)
      path = task_worktree(task) or return nil

      head = fetch_pull_request_head(task, pull_request)
      changed = tracked_changes(path)
      unpushed = git("-C", path.to_s, "log", "--format=%h %s", "#{head}..HEAD").lines.map(&:strip).reject(&:empty?)
      return nil if changed.empty? && unpushed.empty?

      {path: path.to_s, changed: changed, unpushed: unpushed}
    end

    # Brings the task worktree to the PR head when nothing is lost: it is
    # behind, or its commits are all in the PR in another form (a rebase
    # someone pushed). Returns :same, :fast_forward or :reset, or why it
    # could not.
    def follow_pull_request(task, pull_request)
      path = task_worktree(task) or return "the task has no worktree"

      branch = task.metadata["local_branch"] || task.branch
      current = git_result("-C", path.to_s, "symbolic-ref", "--quiet", "--short", "HEAD")
      return "#{path} is not on its branch #{branch}" unless current.success? && current.stdout.strip == branch

      changed = tracked_changes(path)
      return "#{path} has tracked changes: #{changed.map(&:strip).join(", ")}" unless changed.empty?

      head = fetch_pull_request_head(task, pull_request)
      local = git("-C", path.to_s, "rev-parse", "HEAD").strip
      return :same if local == head

      if ancestor?(path, local, head)
        result = git_result("-C", path.to_s, "merge", "--ff-only", "--quiet", head)
        return result.success? ? :fast_forward : "#{path} could not be fast-forwarded to #{head}: #{result.text.strip}"
      end
      unless git("-C", path.to_s, "cherry", head, local).lines.all? { |line| line.start_with?("-") }
        commits = git("-C", path.to_s, "log", "--format=%h %s", "#{head}..#{local}").lines.map(&:strip)
        return "#{path} has commits the PR does not: #{commits.join("; ")}"
      end

      git("-C", path.to_s, "reset", "--hard", "--quiet", head)
      @log.info("[#{task.id}] moved #{path} from #{local} to the PR head #{head}, which has its commits")
      :reset
    end

    # A review in the task worktree starts from what is recorded here, and
    # whatever it changes is put back afterwards (see #end_shared_review).
    def begin_shared_review(task, state:)
      path = task_worktree(task) or raise "the task has no worktree to review in"

      task.metadata["shared_review"] = {
        "path" => path.to_s,
        "branch" => git("-C", path.to_s, "symbolic-ref", "--short", "HEAD").strip,
        "head" => git("-C", path.to_s, "rev-parse", "HEAD").strip,
        "untracked" => untracked_files(path)
      }
      state.save_task(task)
      path.to_s
    end

    # Reviewers must leave the worker's worktree as they found it. Tracked
    # changes are saved as a patch and reverted, new untracked files are moved
    # out, and a moved branch or HEAD is put back; all of it is recorded on the
    # task and kept under the runtime directory. Returns whether anything was.
    def end_shared_review(task, trigger:)
      # The record goes only once all is back, so a failure is retried at
      # the next start.
      review = task.metadata["shared_review"] or return false

      path = Pathname(review["path"])
      unless path.exist? && registered_worktree?(path)
        task.metadata.delete("shared_review")
        return false
      end

      keep = @project.runtime_dir.join("review-leftovers", task.id, Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
      record = {"at" => Time.now.utc.iso8601, "trigger" => trigger, "kept" => keep.to_s}
      changed = tracked_changes(path)
      unless changed.empty?
        FileUtils.mkdir_p(keep)
        keep.join("changes.patch").write(git("-C", path.to_s, "diff", "--binary", "HEAD"))
        record["changed"] = changed
      end
      added = untracked_files(path) - review["untracked"]
      unless added.empty?
        added.each do |file|
          FileUtils.mkdir_p(keep.join("files", file).dirname)
          FileUtils.mv(path.join(file), keep.join("files", file))
        end
        record["moved"] = added
      end
      branch = git_result("-C", path.to_s, "symbolic-ref", "--quiet", "--short", "HEAD").stdout.strip
      head = git("-C", path.to_s, "rev-parse", "HEAD").strip
      record["branch"] = branch unless branch == review["branch"]
      if head != review["head"]
        record["head"] = head
        record["commits"] = git("-C", path.to_s, "log", "--format=%h %s", "#{review["head"]}..#{head}").lines.map(&:strip)
      end
      if !changed.empty? || record.key?("branch") || record.key?("head")
        git("-C", path.to_s, "checkout", "--force", "--quiet", review["branch"])
        git("-C", path.to_s, "reset", "--hard", "--quiet", review["head"])
      end
      task.metadata.delete("shared_review")
      return false unless (%w[changed moved branch head] & record.keys).any?

      task.metadata["shared_review_changes"] = (Array(task.metadata["shared_review_changes"]) << record).last(WORKSPACE_CHANGE_RECORDS)
      @log.warn("[#{task.id}] the review left #{path} changed #{trigger}; put it back and kept what it left in #{keep}")
      true
    end

    # Publishes a reviewer's screenshots for a person to look at: one commit
    # with only the images, on a new branch, made without touching any
    # worktree. Returns each caption with a link fixed to that commit.
    def publish_screenshots(task, workspace, screenshots)
      prefix = @config.screenshot_branch_prefix
      raise ScreenshotError, "publishing screenshots is turned off ([github].screenshot_branch_prefix)" if prefix.to_s.empty?

      entries = Array(screenshots).each_with_index.map do |screenshot, index|
        file = screenshot_file(task, workspace, screenshot["path"].to_s)
        name = format("%02d-%s", index + 1, File.basename(file).gsub(/[^\w.-]/, "_"))
        blob = git("hash-object", "-w", file.to_s).strip
        {name: name, blob: blob, caption: screenshot["caption"].to_s}
      end
      raise ScreenshotError, "no screenshots were given" if entries.empty?

      tree = git_result("mktree", stdin: entries.map { |entry| "100644 blob #{entry[:blob]}\t#{entry[:name]}\n" }.join)
      raise ScreenshotError, "git mktree failed: #{tree.text.strip}" unless tree.success?

      commit = git("commit-tree", tree.stdout.strip, "-m", "Screenshots for #{task.pr_number ? "PR ##{task.pr_number}" : task.id}").strip
      branch = "#{prefix}#{task.id}-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}"
      git("push", "origin", "#{commit}:refs/heads/#{branch}")
      @log.info("[#{task.id}] published #{entries.size} screenshot(s) on #{branch}")
      entries.map do |entry|
        {caption: entry[:caption], url: "https://github.com/#{@github.repo_name}/blob/#{commit}/#{entry[:name]}?raw=true"}
      end
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

    def task_worktree(task)
      path = task.worktree && Pathname(task.worktree)
      path if path&.exist? && registered_worktree?(path)
    end

    # A screenshot inside the review workspace, or moved out of the task
    # worktree after the review (see #end_shared_review).
    def screenshot_file(task, workspace, path)
      root = Pathname(workspace).realpath
      relative = Pathname(path).absolute? ? Pathname(path).expand_path.relative_path_from(root) : Pathname(path)
      raise ScreenshotError, "screenshot #{path} is outside the review workspace" if relative.each_filename.first == ".."

      kept = Array(task.metadata["shared_review_changes"]).last&.fetch("kept", nil)
      file = [root.join(relative), kept && Pathname(kept).join("files", relative)].compact.find(&:file?)
      raise ScreenshotError, "screenshot #{path} does not exist" unless file
      allowed = [root, kept && Pathname(kept).realpath].compact.map { |dir| "#{dir}/" }
      raise ScreenshotError, "screenshot #{path} is outside the review workspace" unless file.realpath.to_s.start_with?(*allowed)
      raise ScreenshotError, "screenshot #{path} is not an image (#{SCREENSHOT_TYPES.join(", ")})" unless SCREENSHOT_TYPES.include?(file.extname.downcase)
      raise ScreenshotError, "screenshot #{path} is larger than #{SCREENSHOT_LIMIT / 1024 / 1024} MiB" if file.size > SCREENSHOT_LIMIT

      file
    end

    def ancestor?(path, ancestor, descendant)
      git_result("-C", path.to_s, "merge-base", "--is-ancestor", ancestor, descendant).success?
    end

    def untracked_files(path)
      git("-C", path.to_s, "ls-files", "--others", "--exclude-standard", "-z").split("\0").reject(&:empty?)
    end

    def tracked_changes(path)
      git("-C", path.to_s, "status", "--porcelain", "--untracked-files=no").lines.map(&:chomp).reject(&:empty?)
    end

    def fetch_pull_request_head(task, pull_request)
      git("fetch", "origin", "refs/pull/#{task.pr_number || pull_request.fetch("number")}/head")
      head = git("rev-parse", "FETCH_HEAD").strip
      raise "PR head changed while looking at it; retry" unless head == pull_request.fetch("headRefOid")

      head
    end

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

    def git_result(*args, stdin: nil)
      @command.run("git", *args, chdir: @project.root, timeout: 300, stdin: stdin)
    end

    def change_id(base, head)
      fork_point = git_result("merge-base", "refs/remotes/origin/#{base}", head)
      return nil unless fork_point.success?

      diff = git("diff", "--no-color", "--no-ext-diff", fork_point.stdout.strip, head)
      result = git_result("patch-id", "--stable", stdin: diff)
      raise "git patch-id failed: #{result.text.strip}" unless result.success?

      result.stdout.split.first.to_s
    end
  end
end
