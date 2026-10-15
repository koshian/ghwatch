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

  def test_assessments_remember_when_the_issue_was_read_even_in_an_older_database
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.sqlite3")
      db = Sequel.sqlite(path)
      db.create_table(:issue_assessments) do
        Integer :issue_number, primary_key: true
        String :status, null: false
        String :reason, text: true
        String :comment, text: true
        String :issue_signature
        Integer :updated_at, null: false
      end
      db[:issue_assessments].insert(issue_number: 3, status: "deferred", issue_signature: "old", updated_at: 1)
      db.disconnect

      state = Ghwatch::StateStore.new(path)
      assert_nil state.assessment(3)[:issue_updated_at]
      state.save_assessment(4, status: "ready", reason: "r", comment: nil, signature: "s", at: 5, issue_updated_at: "t1")
      state.touch_assessment(4, signature: "s2", issue_updated_at: "t2")
      assert_equal({status: "ready", reason: "r", comment: nil, issue_signature: "s2", issue_updated_at: "t2", updated_at: 5},
        state.assessment(4))
    end
  end
end
