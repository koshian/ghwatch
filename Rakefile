# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

namespace :install do
  desc "Build and install #{Bundler::GemHelper.gemspec.full_name}.gem into the RubyGems user directory (no root needed)"
  task user: :build do
    gem_path = File.join("pkg", "#{Bundler::GemHelper.gemspec.full_name}.gem")
    # Under `bundle exec`, GEM_HOME points at the bundle, which would make
    # RubyGems treat runtime dependencies as already installed and skip them.
    Bundler.with_unbundled_env do
      sh "gem", "install", "--user-install", "--no-document", gem_path
    end
  end
end

desc "Regenerate the state machine tables in ARCHITECTURE.md"
task :docs do
  require_relative "lib/ghwatch"
  path = File.expand_path("ARCHITECTURE.md", __dir__)
  File.write(path, Ghwatch::StateMachine.render_into(File.read(path)))
end

task default: :test
