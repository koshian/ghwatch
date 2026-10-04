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
    sh "gem", "install", "--user-install", "--local", "--no-document", gem_path
  end
end

task default: :test
