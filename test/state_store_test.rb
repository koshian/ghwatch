# frozen_string_literal: true

require_relative "test_helper"

class StateStoreTest < Minitest::Test
  def test_task_round_trip
    Dir.mktmpdir do |dir|
      state = Ghwatch::StateStore.new(File.join(dir, "state.sqlite3"))
      task = Ghwatch::Task.for_issue(7, branch: "ghwatch/issue-7", worktree: ".worktrees/issue-7")
      task.metadata["resume_state"] = "implementing"
      state.save_task(task)

      loaded = state.task("issue-7")
      assert_equal 7, loaded.issue_number
      assert_equal "implementing", loaded.metadata.fetch("resume_state")
    end
  end
end
