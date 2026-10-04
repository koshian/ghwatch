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
      [read(role), context, Result.contract_for(role)].join("\n\n---\n\n")
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
