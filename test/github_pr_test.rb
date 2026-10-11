# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require "ostruct"

class GithubPrTest < Minitest::Test
  class Github < Ghwatch::Github
    def closing_issues_references(number) = []

    def issue_comments(number) = []

    def repo_name = "koshian/cayenchat"

    private

    def gh_api_paginated(path) = []
  end

  def fetch(payload)
    command = Minitest::Mock.new
    result = Ghwatch::Command::Result.new(
      argv: [], stdout: JSON.generate(payload), stderr: "", exit_code: 0, timed_out: false
    )
    command.expect(:run, result) do |*args, **options|
      args.first(5) == ["gh", "pr", "view", "164", "--json"] &&
        args.fetch(5).split(",").include?("headRepositoryOwner")
    end
    github = Github.new(project: OpenStruct.new(root: "."), command: command)
    pull_request = github.pull_request(164)
    command.verify
    pull_request
  end

  def test_cli_head_repository_is_normalized_using_owner_login
    pull_request = fetch(
      "number" => 164,
      "headRepository" => {"id" => "repository-id", "name" => "cayenchat"},
      "headRepositoryOwner" => {"name" => "Display Name", "login" => "koshian"}
    )
    assert_equal "koshian/cayenchat", pull_request.dig("headRepository", "nameWithOwner")
  end

  def test_fork_head_repository_uses_its_owner
    pull_request = fetch(
      "headRepository" => {"name" => "fork"},
      "headRepositoryOwner" => {"login" => "contributor"}
    )
    assert_equal "contributor/fork", pull_request.dig("headRepository", "nameWithOwner")
  end

  def test_deleted_head_repository_is_not_replaced_with_base_repository
    pull_request = fetch("headRepository" => nil, "headRepositoryOwner" => nil)
    assert_nil pull_request["headRepository"]
  end

  def test_latest_merge_is_read_from_recently_updated_prs
    command = Minitest::Mock.new
    result = Ghwatch::Command::Result.new(
      argv: [], stdout: JSON.generate([{"mergedAt" => "2026-10-09T07:51:13Z"}, {"mergedAt" => "2026-10-08T01:00:00Z"}]),
      stderr: "", exit_code: 0, timed_out: false
    )
    command.expect(:run, result) do |*args, **options|
      args.first(4) == ["gh", "pr", "list", "--state"] && args.each_cons(2).include?(["--search", "sort:updated-desc"])
    end
    github = Github.new(project: OpenStruct.new(root: "."), command: command)
    assert_equal Time.parse("2026-10-09T07:51:13Z").to_i, github.last_merged_at
    command.verify
  end

  def reference(payload)
    command = Minitest::Mock.new
    result = Ghwatch::Command::Result.new(argv: [], stdout: JSON.generate(payload), stderr: "", exit_code: 0, timed_out: false)
    command.expect(:run, result) { |*args, **options| args == ["gh", "api", "repos/koshian/cayenchat/issues/7"] }
    Github.new(project: OpenStruct.new(root: "."), command: command).reference(7)
  end

  def test_a_reference_tells_merged_prs_and_how_an_issue_was_closed
    assert_equal({"number" => 7, "kind" => "pull_request", "title" => "PR", "state" => "merged"},
      reference("title" => "PR", "state" => "closed", "pull_request" => {"merged_at" => "2026-10-11T00:53:48Z"}))
    assert_equal({"number" => 7, "kind" => "pull_request", "title" => "PR", "state" => "closed"},
      reference("title" => "PR", "state" => "closed", "pull_request" => {"merged_at" => nil}))
    assert_equal({"number" => 7, "kind" => "issue", "title" => "Issue", "state" => "closed", "closedAs" => "completed"},
      reference("title" => "Issue", "state" => "closed", "state_reason" => "completed"))
    assert_equal({"number" => 7, "kind" => "issue", "title" => "Issue", "state" => "open"},
      reference("title" => "Issue", "state" => "open", "state_reason" => nil))
  end
end
