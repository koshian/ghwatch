# frozen_string_literal: true

module Ghwatch
  class Doctor
    Check = Data.define(:ok, :name, :detail)

    def initialize(project:, config:, command:, github:)
      @project = project
      @config = config
      @command = command
      @github = github
    end

    def checks
      [
        Check.new(ok: true, name: "git repository", detail: @project.root.to_s),
        Check.new(ok: File.exist?(@project.config_path), name: "config", detail: @project.config_path.to_s),
        Check.new(ok: @command.executable?("gh"), name: "gh executable", detail: "gh"),
        Check.new(ok: @github.authenticated?, name: "gh authentication", detail: @github.repo_name),
        *runner_checks,
        *screening_checks
      ]
    rescue => e
      [Check.new(ok: false, name: "doctor", detail: e.message)]
    end

    def healthy?
      checks.all?(&:ok)
    end

    private

    def screening_checks
      return [] unless @config.screening.fetch("enabled", false)

      variable = @config.screening.fetch("api_key_env", "TYPESAFE_API_KEY")
      [Check.new(ok: !ENV[variable].to_s.empty?, name: "triage screening key", detail: variable)]
    end

    def runner_checks
      @config.roles.flat_map { |role| role.models.map(&:runner) }.uniq.map do |name|
        executable = @config.runner(name).fetch("command")
        Check.new(
          ok: @command.executable?(executable),
          name: "runner #{name}",
          detail: executable
        )
      end
    end
  end
end
