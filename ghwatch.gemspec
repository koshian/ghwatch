# frozen_string_literal: true

require_relative "lib/ghwatch/version"

Gem::Specification.new do |spec|
  spec.name = "ghwatch"
  spec.version = Ghwatch::VERSION
  spec.authors = ["ghwatch contributors"]
  spec.summary = "Autonomous GitHub issue and pull-request agent orchestrator"
  spec.description = <<~TEXT.strip
    ghwatch coordinates coding agents, reviewers, GitHub issues, pull requests,
    and asynchronous human feedback through a durable project-local state machine.
  TEXT
  spec.homepage = "https://github.com/koshian/ghwatch"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  # Everything under lib/ ships, including the non-Ruby files that are read at
  # runtime: lib/ghwatch/default_config.toml (ghwatch init) and
  # lib/ghwatch/prompts/*.md (built-in prompts). Both are located via __dir__.
  spec.files = Dir["lib/**/*"].select { |path| File.file?(path) } +
    ["bin/ghwatch", "README.md", "LICENSE"]
  spec.bindir = "bin"
  spec.executables = ["ghwatch"]
  spec.require_paths = ["lib"]

  spec.add_dependency "childprocess", ">= 5.0", "< 6"
  spec.add_dependency "sequel", ">= 5.70", "< 6"
  spec.add_dependency "sqlite3", ">= 1.7", "< 3"
  spec.add_dependency "thor", ">= 1.3", "< 2"
  spec.add_dependency "toml-rb", ">= 2.2", "< 4"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
end
