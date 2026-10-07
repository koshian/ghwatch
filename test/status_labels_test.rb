# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class StatusLabelsTest < Minitest::Test
  class Github
    attr_reader :calls
    attr_accessor :fail

    def initialize = @calls = []

    def sync_issue_state_label(number, **options)
      raise "permission denied" if fail

      @calls << [number, options.fetch(:label)]
    end
  end

  def test_state_changes_and_restart_sync_human_waits_and_preserve_active_tasks
    Dir.mktmpdir do |directory|
      state = Ghwatch::StateStore.new(File.join(directory, "state.sqlite3"))
      github = Github.new
      labels = Ghwatch::StatusLabels.new(state: state, github: github, config: Ghwatch::Config.new({}))
      state.status_labels = labels
      task = Ghwatch::Task.for_issue(7, branch: "issue-7", worktree: nil)
      state.save_task(task)
      task.state = "waiting_for_human_input"
      state.save_task(task)
      state.save_task(task)
      assert_equal [[7, "ghwatch:implementing"], [7, "ghwatch:waiting-for-human-input"]], github.calls
      labels.sync_all
      assert_equal [7, "ghwatch:waiting-for-human-input"], github.calls.last

      old = Ghwatch::Task.for_pr(8)
      old.issue_number = 7
      old.state = "done"
      state.save_task(old)
      assert_equal [[7, "ghwatch:waiting-for-human-input"], [8, nil]], github.calls.last(2)
      task.state = "waiting_for_human_test"
      state.save_task(task)
      assert_equal [7, "ghwatch:waiting-for-human-test"], github.calls.last
    end
  end

  def test_permission_failure_does_not_prevent_persistence_and_is_retried
    Dir.mktmpdir do |directory|
      state = Ghwatch::StateStore.new(File.join(directory, "state.sqlite3"))
      github = Github.new
      github.fail = true
      log = StringIO.new
      state.status_labels = Ghwatch::StatusLabels.new(state: state, github: github, config: Ghwatch::Config.new({}), log: Ghwatch::Log.new(log))
      task = Ghwatch::Task.for_issue(7, branch: "issue-7", worktree: nil)
      state.save_task(task)
      assert_equal "implementing", state.task(task.id).state
      assert_includes log.string, "could not sync status label"
      github.fail = false
      state.save_task(task)
      assert_equal [[7, "ghwatch:implementing"]], github.calls
    end
  end

  def test_disabled_sync_does_not_write
    state = Object.new
    github = Github.new
    labels = Ghwatch::StatusLabels.new(state: state, github: github, config: Ghwatch::Config.new({"github" => {"status_labels" => false}}))
    labels.sync(Ghwatch::Task.for_issue(7, branch: "issue-7", worktree: nil))
    labels.sync_all
    assert_empty github.calls
  end

  def test_pull_requests_carry_their_task_state_until_merged
    Dir.mktmpdir do |directory|
      state = Ghwatch::StateStore.new(File.join(directory, "state.sqlite3"))
      github = Github.new
      state.status_labels = Ghwatch::StatusLabels.new(state: state, github: github, config: Ghwatch::Config.new({}))

      external = Ghwatch::Task.for_pr(8)
      state.save_task(external)
      assert_equal [[8, "ghwatch:waiting-for-review"]], github.calls

      task = Ghwatch::Task.for_issue(7, branch: "issue-7", worktree: nil)
      state.save_task(task)
      task.pr_number = 9
      task.state = "waiting_for_human_input"
      state.save_task(task)
      assert_equal [[7, "ghwatch:waiting-for-human-input"], [9, "ghwatch:waiting-for-human-input"]], github.calls.last(2)

      task.state = "continuing"
      state.save_task(task)
      assert_equal [9, "ghwatch:changes-requested"], github.calls.last

      # The PR was closed and the task went back to the worker: the old PR is cleared.
      task.pr_number = nil
      task.state = "implementing"
      state.save_task(task)
      assert_equal [[7, "ghwatch:implementing"], [9, nil]], github.calls.last(2)

      task.pr_number = 10
      task.state = "finalizing"
      state.save_task(task)
      assert_equal [10, nil], github.calls.last
    end
  end

  class Api < Ghwatch::Github
    attr_accessor :current, :available
    attr_reader :writes

    def initialize
      super(project: nil, command: nil)
      @writes = []
      @available = []
    end

    def repo_name = "owner/project"

    private

    def gh_api_paginated(path)
      names = path.include?("/issues/") ? current : available
      names.map { |name| {"name" => name} }
    end

    def gh(*args)
      @writes << args
      ""
    end
  end

  def test_api_adds_new_label_and_removes_only_managed_old_labels
    api = Api.new
    api.current = ["bug", "ghwatch:priority", "ghwatch:implementing"]
    api.sync_issue_state_label(7, label: "ghwatch:waiting-for-human-test", managed_labels: Ghwatch::StatusLabels::LABELS.values, color: "d876e3", description: "state")
    assert_equal "label", api.writes[0][0]
    assert_equal ["api", "--method", "POST", "repos/owner/project/issues/7/labels", "-f", "labels[]=ghwatch:waiting-for-human-test"], api.writes[1]
    assert_equal ["api", "--method", "DELETE", "repos/owner/project/issues/7/labels/ghwatch%3Aimplementing"], api.writes[2]
    assert_equal 3, api.writes.length
    api.current = ["bug", "ghwatch:waiting-for-human-test"]
    api.writes.clear
    api.sync_issue_state_label(7, label: "ghwatch:waiting-for-human-test", managed_labels: Ghwatch::StatusLabels::LABELS.values, color: "d876e3", description: "state")
    assert_empty api.writes
  end
end
