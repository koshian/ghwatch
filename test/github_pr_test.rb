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
end
