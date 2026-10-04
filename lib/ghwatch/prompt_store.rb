# frozen_string_literal: true

require "fileutils"

module Ghwatch
  class PromptStore
    BUILTIN_DIR = File.expand_path("prompts", __dir__)

    def initialize(project:, config:)
      @project = project
      @config = config
    end

    def read(role)
      filename = @config.role(role).prompt
      override = @project.prompt_dir.join(filename)
      return File.read(override) if File.exist?(override)

      File.read(File.join(BUILTIN_DIR, filename))
    end

    def compose(role, context:)
      language_instruction = <<~TEXT
        Write all human-facing GitHub text in #{@config.human_language}, including issue and
        pull request titles, descriptions, comments, review feedback, questions, and test
        requests. This language setting takes precedence over the language of this prompt
        and the existing GitHub discussion. Keep code identifiers, machine-readable JSON
        keys, and protocol status values unchanged.

        Format URLs in human-facing GitHub prose as Markdown links: [descriptive label](URL).
        Use this format for issues, pull requests, workflow runs, test builds and artifacts.
        Do not enclose bare URLs in Japanese full-width parentheses or rely on automatic
        URL linking. For example: Reply to [Issue #123](https://github.com/owner/repo/issues/123).
        Preserve literal URLs in code, commands, reproduction examples and machine-readable
        JSON fields that require a URL value. This formatting rule also applies to local
        prompt overrides, regardless of the requested language.
      TEXT
      [read(role), context, Result.contract_for(role), language_instruction].join("\n\n---\n\n")
    end

    def eject(role, force: false)
      filename = @config.role(role).prompt
      source = File.join(BUILTIN_DIR, filename)
      raise Config::Error, "no built-in prompt for #{role}" unless File.exist?(source)

      destination = @project.prompt_dir.join(filename)
      if File.exist?(destination) && !force
        raise Config::Error, "prompt already exists: #{destination}"
      end

      FileUtils.mkdir_p(destination.dirname)
      FileUtils.cp(source, destination)
      destination
    end

    def available_roles
      @config.roles.map(&:name)
    end
  end
end
