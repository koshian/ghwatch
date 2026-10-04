# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "ostruct"

class DiscoveryOrderTest < Minitest::Test
  def test_issue_and_pr_lists_sort_the_fetched_hundred_oldest_first
    %w[issue pr].each do |kind|
      command = Minitest::Mock.new
      payload = [{"number" => 160}, {"number" => 71}, {"number" => 132}]
      result = Ghwatch::Command::Result.new(
        argv: [], stdout: JSON.generate(payload), stderr: "", exit_code: 0, timed_out: false
      )
      command.expect(:run, result) do |*args, **options|
        args.first(7) == ["gh", kind, "list", "--state", "open", "--limit", "100"]
      end
      github = Ghwatch::Github.new(project: OpenStruct.new(root: "."), command: command)
      summaries = (kind == "issue") ? github.open_issues : github.open_pull_requests
      assert_equal [71, 132, 160], summaries.map { |summary| summary.fetch("number") }
      command.verify
    end
  end

  def test_triage_takes_oldest_eligible_candidates_before_newer_blocked_issues
    github = OpenStruct.new(open_issues: [71, 132, 138, 160].map { |number| {"number" => number} })
    active = Ghwatch::Task.for_issue(132, branch: "issue-132", worktree: nil)
    state = OpenStruct.new(tasks: [active], assessments: {160 => {status: "blocked"}})
    triage = Ghwatch::IssueTriage.new(
      project: nil, config: OpenStruct.new(candidate_limit: 2), state: state,
      github: github, roles: nil, worktrees: nil, context_builder: nil
    )
    assert_equal [71, 138], triage.send(:candidate_issues).map { |issue| issue.fetch("number") }
  end
end
