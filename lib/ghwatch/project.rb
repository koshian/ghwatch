# frozen_string_literal: true

require "open3"
require "pathname"
require "fileutils"

module Ghwatch
  class Project
    class NotARepository < StandardError; end

    attr_reader :root, :git_dir

    def self.discover(from: Dir.pwd)
      stdout, stderr, status = Open3.capture3("git", "-C", from.to_s, "rev-parse", "--show-toplevel")
      raise NotARepository, stderr.strip unless status.success?

      root = Pathname(stdout.strip).expand_path
      git_dir_output, git_dir_error, git_dir_status = Open3.capture3("git", "-C", root.to_s, "rev-parse", "--git-dir")
      raise NotARepository, git_dir_error.strip unless git_dir_status.success?

      git_dir = Pathname(git_dir_output.strip)
      git_dir = root.join(git_dir) unless git_dir.absolute?
      new(root: root, git_dir: git_dir.expand_path)
    end

    def initialize(root:, git_dir:)
      @root = Pathname(root)
      @git_dir = Pathname(git_dir)
    end

    def config_dir
      root.join(".ghwatch")
    end

    def config_path
      config_dir.join("config.toml")
    end

    def prompt_dir
      config_dir.join("prompts")
    end

    def runtime_dir
      git_dir.join("ghwatch")
    end

    def state_path
      runtime_dir.join("state.sqlite3")
    end

    def result_dir
      runtime_dir.join("results")
    end

    def ensure_runtime_dirs
      FileUtils.mkdir_p(runtime_dir)
      FileUtils.mkdir_p(result_dir)
    end
  end
end
