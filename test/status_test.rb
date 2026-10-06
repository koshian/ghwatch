# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class StatusTest < Minitest::Test
  def test_shows_errors_workspace_changes_and_discussions
    task = Ghwatch::Task.for_issue(132, branch: "b", worktree: nil)
    task.state = "waiting_for_review"
    task.pr_number = 166
    task.last_error = "reserved review workspace already exists: /x/review-pr-166\nmore"
    task.metadata["workspace_changes"] = [{"at" => "2026-10-06T00:00:00Z", "trigger" => "at ghwatch startup",
                                           "files" => [" D .github/a.yml", " D .github/b.yml", " D .github/c.yml", " D .github/d.yml"]}]
    done = Ghwatch::Task.for_issue(1, branch: "c", worktree: nil)
    done.state = "done"
    done.last_error = "old"
    state = OpenStruct.new(tasks: [task, done], assessments: {1 => {status: "discussion", reason: "loose idea"}})
    io = StringIO.new
    Ghwatch::Status.new(state: state, io: io).print
    assert_includes io.string, "error: reserved review workspace already exists: /x/review-pr-166"
    assert_includes io.string, "review workspace changed at ghwatch startup at 2026-10-06T00:00:00Z: " \
      "D .github/a.yml, D .github/b.yml, D .github/c.yml (+1 more)"
    refute_includes io.string, "error: old"
    assert_match(/#1\s+discussion loose idea/, io.string)
  end
end
