# frozen_string_literal: true

require_relative "test_helper"

class TaskTest < Minitest::Test
  def test_review_wait_does_not_consume_worker_slot
    task = Ghwatch::Task.for_issue(123, branch: "ghwatch/issue-123", worktree: ".worktrees/issue-123")
    assert task.uses_worker_slot?

    task.state = "waiting_for_review"
    refute task.uses_worker_slot?
  end

  def test_retry_is_durable_data
    task = Ghwatch::Task.for_pr(42)
    task.schedule_retry(after: 60)

    assert task.retry_at
    refute task.retry_due?(task.retry_at - 1)
    assert task.retry_due?(task.retry_at)
  end
end
