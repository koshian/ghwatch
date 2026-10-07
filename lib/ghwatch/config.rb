# frozen_string_literal: true

require "toml-rb"

module Ghwatch
  class Config
    class Error < StandardError; end

    attr_reader :data, :path

    def self.load(path)
      raise Error, "missing config: #{path}" unless File.exist?(path)

      new(TomlRB.load_file(path.to_s), path: path)
    rescue TomlRB::ParseError => e
      raise Error, "invalid TOML in #{path}: #{e.message}"
    end

    def initialize(data, path: nil)
      @data = data
      @path = path
      @mtime = File.mtime(path) if path && File.exist?(path)
      validate!
    end

    def reload_if_changed!
      return false unless path && File.exist?(path)

      current_mtime = File.mtime(path)
      return false if @mtime && current_mtime <= @mtime

      candidate = self.class.new(TomlRB.load_file(path.to_s), path: path)
      @data = candidate.data
      @mtime = current_mtime
      true
    rescue TomlRB::ParseError => e
      raise Error, "invalid TOML in #{path}: #{e.message}"
    end

    def project
      data.fetch("project", {})
    end

    def github
      data.fetch("github", {})
    end

    # Logins mentioned in questions ghwatch asks on pull requests; empty means
    # the repository owner when it is a person.
    def human_mentions
      Array(github.fetch("human_mentions", []))
    end

    def status_labels?
      github.fetch("status_labels", true)
    end

    def role(name)
      roles = data.fetch("roles", {})
      role = roles[name.to_s] || raise(Error, "missing [roles.#{name}] configuration")
      Role.new(name.to_s, role)
    end

    def roles
      data.fetch("roles", {}).keys.map { |name| role(name) }
    end

    def runner(name)
      configured = data.fetch("runners", {}).fetch(name.to_s, {})
      defaults = DEFAULT_RUNNERS.fetch(name.to_s) do
        raise Error, "unknown runner #{name.inspect}; configure [runners.#{name}]"
      end
      defaults.merge(configured)
    end

    def poll_interval
      Duration.seconds(project.fetch("poll_interval", "10m"))
    end

    def discovery_interval
      Duration.seconds(project.fetch("discovery_interval", "2h"))
    end

    def retry_after
      Duration.seconds(project.fetch("retry_after", "10m"))
    end

    def max_workers
      Integer(project.fetch("max_workers", 2))
    end

    def candidate_limit
      Integer(project.fetch("candidate_limit", 20))
    end

    def worktree_root
      project.fetch("worktree_root", ".worktrees")
    end

    def branch_prefix
      project.fetch("branch_prefix", "ghwatch/issue-")
    end

    def human_wait_cleanup
      command = project.fetch("human_wait_cleanup", "git clean -fdX")
      command.strip.empty? ? nil : command
    end

    # "discussion" puts issues asking for harmful behavior in front of a
    # maintainer; "skip" ignores them silently, like a spam filter.
    def harmful_issues
      project.fetch("harmful_issues", "discussion")
    end

    def triage
      data.fetch("triage", {})
    end

    # An issue unchanged since its last assessment is not judged again until
    # this much time has passed (deferred ones also after any merge).
    def reassess_after
      Duration.seconds(triage.fetch("reassess_after", "1d"))
    end

    def screening
      triage.fetch("screening", {})
    end

    def review_all_open_prs?
      project.fetch("review_all_open_prs", true)
    end

    def auto_merge?
      github.fetch("auto_merge", true)
    end

    def update_pr_branches?
      github.fetch("update_pr_branches", true)
    end

    def merge_method
      github.fetch("merge_method", "merge")
    end

    def human_language(environment: ENV)
      configured = github.fetch("human_language", "auto")
      return configured unless configured == "auto"

      %w[LC_ALL LANGUAGE LC_MESSAGES LANG].each do |name|
        environment.fetch(name, "").split(":").each do |locale|
          locale = locale.strip.split(/[.@]/).first
          return "en" if %w[C POSIX].include?(locale)
          next unless locale&.match?(/\A[a-z]{2,3}(?:[_-][a-z0-9]+)*\z/i)

          return locale.tr("_", "-")
        end
      end

      "en"
    end

    def close_issue_after_merge?
      github.fetch("close_issue_after_merge", true)
    end

    def reviewer_requires_green_checks?
      github.fetch("require_green_checks", true)
    end

    private

    DEFAULT_RUNNERS = {
      "claude" => {
        "command" => "claude",
        "timeout" => "90m",
        "capacity_patterns" => [
          "usage limit",
          "usage limits",
          "quota",
          "capacity",
          "rate limit",
          "rate-limit",
          "too many requests",
          "429",
          "try again later"
        ]
      },
      "codex" => {
        "command" => "codex",
        "timeout" => "90m",
        "capacity_patterns" => [
          "usage limit",
          "quota",
          "capacity",
          "rate limit",
          "too many requests",
          "429"
        ]
      },
      "opencode" => {
        "command" => "opencode",
        "timeout" => "90m",
        "capacity_patterns" => [
          "usage limit",
          "quota",
          "capacity",
          "rate limit",
          "too many requests",
          "429"
        ]
      }
    }.freeze

    def validate!
      raise Error, "[project].max_workers must be positive" if max_workers < 1
      raise Error, "[project].candidate_limit must be positive" if candidate_limit < 1
      raise Error, "[project].human_wait_cleanup must be a string" unless project.fetch("human_wait_cleanup", "").is_a?(String)
      raise Error, "[project].harmful_issues must be discussion or skip" unless %w[discussion skip].include?(harmful_issues)
      reassess_after
      confidence = screening.fetch("min_confidence", 0.8)
      raise Error, "[triage.screening].min_confidence must be between 0 and 1" unless confidence.is_a?(Numeric) && confidence.between?(0, 1)
      language = github.fetch("human_language", "auto")
      unless language.is_a?(String) && !language.strip.empty?
        raise Error, "[github].human_language must be a non-empty language name, language tag, or auto"
      end

      roles.each do |role|
        raise Error, "role #{role.name} must define at least one [[roles.#{role.name}.models]] entry" if role.models.empty?
      end
    end

    class Role
      attr_reader :name, :data

      def initialize(name, data)
        @name = name
        @data = data
      end

      def prompt
        data.fetch("prompt", "#{name}.md")
      end

      def models
        Array(data["models"]).map { |entry| ModelTarget.new(entry) }
      end
    end

    class ModelTarget
      attr_reader :data

      def initialize(data)
        @data = data
      end

      def runner
        data.fetch("runner")
      end

      def model
        data.fetch("model")
      end

      def fallback_on
        Array(data.fetch("fallback_on", []))
      end

      def args
        Array(data.fetch("args", []))
      end
    end
  end
end
