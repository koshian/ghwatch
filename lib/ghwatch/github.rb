# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"
require "uri"

module Ghwatch
  class Github
    MARKER_PREFIX = "<!-- ghwatch:"

    def initialize(project:, command:, log: Log.new)
      @project = project
      @command = command
      @log = log
      @repo_name = nil
      @default_branch = nil
    end

    def authenticated?
      @command.run("gh", "auth", "status", chdir: @project.root, timeout: 30).success?
    end

    def repo_name
      @repo_name ||= gh_json("repo", "view", "--json", "nameWithOwner").fetch("nameWithOwner")
    end

    # The repository owner when it is a person (organizations cannot be
    # mentioned usefully), so questions on PRs reach someone.
    def owner_login
      return @owner_login if defined?(@owner_login)

      owner = gh_api("repos/#{repo_name}").fetch("owner", {})
      @owner_login = (owner["type"] == "User") ? owner["login"] : nil
    end

    def default_branch
      @default_branch ||= gh_json("repo", "view", "--json", "defaultBranchRef").dig("defaultBranchRef", "name")
    end

    def open_issues(limit: 100)
      gh_json(
        "issue", "list", "--state", "open", "--limit", limit.to_s,
        "--json", "number,title,updatedAt,url,labels,assignees"
      ).sort_by { |issue| issue.fetch("number") }
    end

    # Associations that may speak for the project: their comments can settle a
    # decision; anyone else's (including the reporter's) cannot.
    MAINTAINER_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze

    def issue(number)
      gh_json(
        "issue", "view", number.to_s,
        "--json", "number,title,body,state,updatedAt,url,author,labels,assignees"
      ).merge(
        "authorAssociation" => gh_api("repos/#{repo_name}/issues/#{number}")["author_association"],
        "comments" => issue_comments(number)
      )
    end

    def issue_comments(number)
      gh_api_paginated("repos/#{repo_name}/issues/#{number}/comments?per_page=100")
    end

    # When the most recent merge happened, as epoch seconds (nil if none).
    def last_merged_at
      gh_json("pr", "list", "--state", "merged", "--limit", "20", "--json", "mergedAt")
        .filter_map { |pr| pr["mergedAt"] && Time.parse(pr["mergedAt"]).to_i }.max
    end

    def open_pull_requests(limit: 100)
      gh_json(
        "pr", "list", "--state", "open", "--limit", limit.to_s,
        "--json", "number,title,body,url,isDraft,headRefName,headRefOid,baseRefName,updatedAt,mergeable,statusCheckRollup"
      ).sort_by { |pull_request| pull_request.fetch("number") }
    end

    def pull_request(number)
      pull_request = gh_json(
        "pr", "view", number.to_s,
        "--json", "number,title,body,state,url,isDraft,headRefName,headRefOid,baseRefName,updatedAt,mergedAt," \
                  "mergeable,statusCheckRollup,reviewDecision,reviews,headRepository,headRepositoryOwner"
      )
      head_repository = pull_request["headRepository"]
      owner = pull_request.dig("headRepositoryOwner", "login")
      if head_repository && owner && head_repository["name"]
        head_repository["nameWithOwner"] = "#{owner}/#{head_repository.fetch("name")}"
      end
      pull_request.merge(
        "closingIssuesReferences" => closing_issues_references(number),
        "comments" => issue_comments(number),
        "inlineComments" => gh_api_paginated("repos/#{repo_name}/pulls/#{number}/comments?per_page=100")
      )
    end

    # Fetched via GraphQL because `gh pr view --json closingIssuesReferences`
    # is not available in older gh releases (e.g. Debian's 2.46.0).
    def closing_issues_references(number)
      owner, name = repo_name.split("/", 2)
      query = <<~GRAPHQL
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              closingIssuesReferences(first: 10) { nodes { number url } }
            }
          }
        }
      GRAPHQL
      data = gh_json(
        "api", "graphql",
        "-f", "owner=#{owner}", "-f", "name=#{name}", "-F", "number=#{number}",
        "-f", "query=#{query}"
      )
      Array(data.dig("data", "repository", "pullRequest", "closingIssuesReferences", "nodes"))
    end

    def pull_request_for_branch(branch)
      prs = gh_json(
        "pr", "list", "--state", "all", "--head", branch, "--limit", "1",
        "--json", "number,title,state,url,headRefName,headRefOid,mergedAt,updatedAt"
      )
      prs.first
    end

    def post_issue_comment(number, body, kind:, model_signature: nil)
      marker = marker_for(kind)
      signed_body = human_body(body, marker: marker, model_signature: model_signature)
      gh("issue", "comment", number.to_s, "--body", signed_body)
      marker
    end

    def post_pr_comment(number, body, kind:, model_signature: nil)
      marker = marker_for(kind)
      signed_body = human_body(body, marker: marker, model_signature: model_signature)
      gh("pr", "comment", number.to_s, "--body", signed_body)
      marker
    end

    def close_issue(number, comment: nil, model_signature: nil)
      post_issue_comment(number, comment, kind: "completion", model_signature: model_signature) if comment && !comment.strip.empty?
      gh("issue", "close", number.to_s)
    end

    def sync_issue_state_label(number, label:, managed_labels:, color:, description:)
      current = gh_api_paginated("repos/#{repo_name}/issues/#{number}/labels?per_page=100").map { |item| item.fetch("name") }
      stale = (current & managed_labels) - [label]
      unless label.nil? || current.include?(label)
        available = gh_api_paginated("repos/#{repo_name}/labels?per_page=100").map { |item| item.fetch("name") }
        gh("label", "create", label, "--repo", repo_name, "--color", color, "--description", description) unless available.include?(label)
        gh("api", "--method", "POST", "repos/#{repo_name}/issues/#{number}/labels", "-f", "labels[]=#{label}")
      end
      stale.each do |name|
        encoded = URI.encode_www_form_component(name).gsub("+", "%20")
        gh("api", "--method", "DELETE", "repos/#{repo_name}/issues/#{number}/labels/#{encoded}")
      end
    end

    def add_issue_label(number, label, color:, description:)
      current = gh_api_paginated("repos/#{repo_name}/issues/#{number}/labels?per_page=100").map { |item| item.fetch("name") }
      return if current.include?(label)

      available = gh_api_paginated("repos/#{repo_name}/labels?per_page=100").map { |item| item.fetch("name") }
      gh("label", "create", label, "--repo", repo_name, "--color", color, "--description", description) unless available.include?(label)
      gh("api", "--method", "POST", "repos/#{repo_name}/issues/#{number}/labels", "-f", "labels[]=#{label}")
    end

    def remove_issue_label(number, label)
      current = gh_api_paginated("repos/#{repo_name}/issues/#{number}/labels?per_page=100").map { |item| item.fetch("name") }
      return unless current.include?(label)

      encoded = URI.encode_www_form_component(label).gsub("+", "%20")
      gh("api", "--method", "DELETE", "repos/#{repo_name}/issues/#{number}/labels/#{encoded}")
    end

    def merge_pull_request(number, method: "merge")
      gh("pr", "merge", number.to_s, "--#{method}")
    end

    # Merges the base branch into the PR head on GitHub; refused when the head
    # moved past expected_head or the merge conflicts.
    def update_pull_request_branch(number, expected_head:)
      gh("api", "--method", "PUT", "repos/#{repo_name}/pulls/#{number}/update-branch",
        "-f", "expected_head_sha=#{expected_head}")
    end

    def human_comments_after(number, marker:)
      comments = issue_comments(number)
      marker_comment = comments.find { |comment| comment.fetch("body", "").include?(marker.to_s) }
      return [] unless marker_comment

      comments.select do |comment|
        comment.fetch("id").to_i > marker_comment.fetch("id").to_i &&
          !ghwatch_comment?(comment.fetch("body", ""))
      end
    end

    def issue_signature(issue)
      digest(
        "state" => issue["state"],
        "updatedAt" => issue["updatedAt"],
        "body" => issue["body"],
        "comments" => normalized_comments(issue["comments"])
      )
    end

    def review_signature(pr)
      return nil unless pr

      digest(
        "state" => pr["state"],
        "mergedAt" => pr["mergedAt"],
        "headRefOid" => pr["headRefOid"],
        "reviewDecision" => pr["reviewDecision"],
        "reviews" => Array(pr["reviews"]).map { |review| review.slice("state", "submittedAt", "body") },
        "comments" => normalized_comments(pr["comments"]),
        "inlineComments" => Array(pr["inlineComments"]).map { |comment| comment.slice("id", "updated_at", "body") }
      )
    end

    def pr_signature(pr)
      return nil unless pr

      digest(
        "state" => pr["state"],
        "mergedAt" => pr["mergedAt"],
        "headRefOid" => pr["headRefOid"],
        "mergeable" => pr["mergeable"],
        "reviewDecision" => pr["reviewDecision"],
        "checks" => normalized_checks(pr["statusCheckRollup"]),
        "reviews" => Array(pr["reviews"]).map { |review| review.slice("state", "submittedAt", "body") },
        "comments" => normalized_comments(pr["comments"]),
        "inlineComments" => Array(pr["inlineComments"]).map { |comment| comment.slice("id", "updated_at", "body") }
      )
    end

    FAILED_CONCLUSIONS = %w[FAILURE TIMED_OUT CANCELLED ACTION_REQUIRED STARTUP_FAILURE ERROR].freeze

    # Names of the PR's checks that finished unsuccessfully.
    def failed_checks(pr)
      Array(pr["statusCheckRollup"]).filter_map do |check|
        conclusion = (check["conclusion"] || check["state"]).to_s.upcase
        check["name"] || check["context"] if FAILED_CONCLUSIONS.include?(conclusion)
      end
    end

    def checks_pending?(pr)
      Array(pr["statusCheckRollup"]).any? { |check| check["status"].to_s.upcase != "COMPLETED" }
    end

    def checks_green?(pr)
      checks = Array(pr["statusCheckRollup"])
      return false if checks.empty?

      checks.all? do |check|
        status = check["status"].to_s.upcase
        conclusion = check["conclusion"].to_s.upcase
        status == "COMPLETED" && %w[SUCCESS SKIPPED NEUTRAL].include?(conclusion)
      end
    end

    def mergeable?(pr)
      pr["mergeable"].to_s.upcase == "MERGEABLE"
    end

    private

    def gh(*args)
      result = @command.run("gh", *args, chdir: @project.root, timeout: 300)
      raise "gh #{args.join(" ")} failed: #{result.text.strip}" unless result.success?

      result.stdout
    end

    def gh_json(*args)
      JSON.parse(gh(*args))
    end

    def gh_api(path)
      JSON.parse(gh("api", path))
    end

    # Avoids `--slurp`, which older gh releases lack; `--jq '.[]'` emits one
    # compact JSON item per line across all pages.
    def gh_api_paginated(path)
      gh("api", "--paginate", "--jq", ".[]", path).each_line.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
    end

    def marker_for(kind)
      "#{MARKER_PREFIX}#{kind}:#{SecureRandom.uuid} -->"
    end

    def human_body(body, marker:, model_signature:)
      parts = [body.to_s.strip]
      parts << "— ghwatch / #{model_signature}" if model_signature
      parts << marker
      parts.reject(&:empty?).join("\n\n")
    end

    def ghwatch_comment?(body)
      body.include?(MARKER_PREFIX)
    end

    def normalized_comments(comments)
      Array(comments).map do |comment|
        {
          "id" => comment["id"],
          "author" => comment.dig("user", "login") || comment.dig("author", "login"),
          "createdAt" => comment["created_at"] || comment["createdAt"],
          "updatedAt" => comment["updated_at"] || comment["updatedAt"],
          "body" => comment["body"]
        }
      end
    end

    def normalized_checks(checks)
      Array(checks).map do |check|
        check.slice("name", "status", "conclusion", "workflowName")
      end
    end

    def digest(object)
      Digest::SHA256.hexdigest(JSON.generate(object))
    end
  end
end
