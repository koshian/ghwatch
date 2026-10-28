# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"
require "uri"

module Ghwatch
  class Github
    MARKER_PREFIX = "<!-- ghwatch:"
    FOUND_ISSUE_KIND = "found-issue"

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

    # A maintainer hands an issue or PR to someone else by labelling it or by
    # assigning it to another account; ghwatch then leaves it alone.
    HANDS_OFF_LABEL = "ghwatch:hands-off"

    # viewer: the account ghwatch works as, asked only when the item has
    # assignees.
    # Filed by a reviewer for a problem it found: a report, not a
    # maintainer's decision to do the work.
    def self.found_issue?(issue)
      issue.is_a?(Hash) && issue["body"].to_s.include?("#{MARKER_PREFIX}#{FOUND_ISSUE_KIND}:")
    end

    def self.hands_off?(item, viewer:)
      return false unless item.is_a?(Hash)

      labels = Array(item["labels"]).map { |label| label.is_a?(Hash) ? label["name"] : label }
      return true if labels.include?(HANDS_OFF_LABEL)

      assignees = Array(item["assignees"]).map { |assignee| assignee.is_a?(Hash) ? assignee["login"] : assignee }
      !assignees.empty? && !(assignees - [viewer.call]).empty?
    end

    def viewer_login
      @viewer_login ||= gh_api("user").fetch("login")
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
        "--json", "number,title,body,state,updatedAt,closedAt,url,author,labels,assignees"
      ).merge(
        "authorAssociation" => gh_api("repos/#{repo_name}/issues/#{number}")["author_association"],
        "comments" => issue_comments(number)
      )
    end

    # The current state of an issue or PR another issue mentions as #N.
    def reference(number)
      item = gh_api("repos/#{repo_name}/issues/#{number}")
      pull = item["pull_request"]
      state = (pull && pull["merged_at"]) ? "merged" : item["state"]
      {"number" => number, "kind" => pull ? "pull_request" : "issue", "title" => item["title"], "state" => state,
       "closedAs" => (!pull && item["state"] == "closed") ? item["state_reason"] : nil}.compact
    end

    def issue_comments(number)
      gh_api_paginated("repos/#{repo_name}/issues/#{number}/comments?per_page=100")
    end

    # When the most recent merge happened, as epoch seconds (nil if none).
    # Merging updates a PR, so the latest merge is among the most recently
    # updated ones; listing by creation would miss a long-open PR merged now.
    def last_merged_at
      gh_json("pr", "list", "--state", "merged", "--search", "sort:updated-desc", "--limit", "20", "--json", "mergedAt")
        .filter_map { |pr| pr["mergedAt"] && Time.parse(pr["mergedAt"]).to_i }.max
    end

    def last_closed_issue_at
      gh_json("issue", "list", "--state", "closed", "--search", "sort:updated-desc", "--limit", "20", "--json", "closedAt")
        .filter_map { |issue| issue["closedAt"] && Time.parse(issue["closedAt"]).to_i }.max
    end

    def open_pull_requests(limit: 100)
      gh_json(
        "pr", "list", "--state", "open", "--limit", limit.to_s,
        "--json", "number,title,body,url,isDraft,headRefName,headRefOid,baseRefName,updatedAt,mergeable,statusCheckRollup," \
                  "labels,assignees"
      ).sort_by { |pull_request| pull_request.fetch("number") }
    end

    def pull_request(number)
      pull_request = gh_json(
        "pr", "view", number.to_s,
        "--json", "number,title,body,state,url,isDraft,headRefName,headRefOid,baseRefName,updatedAt,mergedAt," \
                  "mergeable,statusCheckRollup,reviewDecision,reviews,headRepository,headRepositoryOwner,labels,assignees,author"
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

    # since: ignore PRs opened before this time. A reopened issue's new task
    # uses the same branch name as the one whose PR already merged.
    def pull_request_for_branch(branch, since: nil)
      prs = gh_json(
        "pr", "list", "--state", "all", "--head", branch, "--limit", "5",
        "--json", "number,title,state,url,headRefName,headRefOid,mergedAt,updatedAt,createdAt"
      )
      prs.find { |pr| since.nil? || pr["createdAt"].nil? || Time.parse(pr["createdAt"]).to_i >= since }
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

    def workflow_run(id)
      gh_api("repos/#{repo_name}/actions/runs/#{Integer(id)}")
    end

    def successful_workflow_runs(workflow_id, limit:)
      gh_api("repos/#{repo_name}/actions/workflows/#{Integer(workflow_id)}/runs?status=success&per_page=#{limit}").fetch("workflow_runs", [])
    end

    def run_artifacts(id)
      gh_api("repos/#{repo_name}/actions/runs/#{Integer(id)}/artifacts?per_page=100").fetch("artifacts", [])
    end

    def artifact_url(run_id, artifact_id)
      "https://github.com/#{repo_name}/actions/runs/#{run_id}/artifacts/#{artifact_id}"
    end

    # Returns the new issue's number.
    def create_issue(title, body, kind:, model_signature: nil)
      url = gh("issue", "create", "--title", title, "--body", human_body(body, marker: marker_for(kind), model_signature: model_signature))
      Integer(url[%r{/issues/(\d+)}, 1])
    end

    def open_issue_titled(title)
      issues = gh_json("issue", "list", "--state", "open", "--search", "#{title} in:title", "--json", "number,title", "--limit", "20")
      issues.find { |issue| issue["title"].strip == title.strip }
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

    def close_pull_request(number, comment: nil)
      gh("pr", "close", number.to_s, *(comment ? ["--comment", comment] : []))
    end

    # Deletes a branch on GitHub; a branch already gone is fine.
    def delete_branch(branch)
      encoded = branch.split("/").map { |part| URI.encode_www_form_component(part) }.join("/")
      gh("api", "--method", "DELETE", "repos/#{repo_name}/git/refs/heads/#{encoded}")
    rescue => e
      raise unless e.message.match?(/Reference does not exist|Not Found|422|404/)
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

    # What triage judges an issue by. Unlike issue_signature it leaves out
    # updatedAt, which changes whenever ghwatch relabels the issue.
    def issue_content_signature(issue)
      digest(
        "state" => issue["state"],
        "title" => issue["title"],
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

    # Reruns the failed jobs of each workflow run with a failed check.
    def rerun_failed_checks(pr)
      runs = Array(pr["statusCheckRollup"]).filter_map do |check|
        conclusion = (check["conclusion"] || check["state"]).to_s.upcase
        check["detailsUrl"].to_s[%r{/actions/runs/(\d+)}, 1] if FAILED_CONCLUSIONS.include?(conclusion)
      end
      runs.uniq.each { |run| gh("run", "rerun", run, "--failed") }
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
