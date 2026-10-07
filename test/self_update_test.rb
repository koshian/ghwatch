# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"
require "minitest/mock"

class SelfUpdateTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("ghwatch-lib")
    File.write(File.join(@root, "ghwatch.rb"), "1")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def touch(name, content)
    path = File.join(@root, name)
    File.write(path, content)
    File.utime(Time.now + 10, Time.now + 10, path)
  end

  def test_a_settled_install_is_noticed_and_one_still_changing_is_not
    changing = true
    update = Ghwatch::SelfUpdate.new(root: @root, enabled: true, sleeper: ->(_) { touch("half.rb", "more") if changing })
    refute update.updated?

    touch("ghwatch.rb", "22")
    refute update.updated?, "files changed again while settling"
    changing = false
    assert update.updated?
  end

  def test_running_from_source_never_restarts
    update = Ghwatch::SelfUpdate.new(root: @root, enabled: false)
    touch("ghwatch.rb", "22")
    refute update.updated?
    refute Ghwatch::SelfUpdate.installed_gem?(File.expand_path("../lib", __dir__))
    assert Ghwatch::SelfUpdate.installed_gem?(File.join(File.expand_path(Gem.path.first), "gems", "ghwatch-0.1.0", "lib"))
  end

  def test_the_scheduler_restarts_between_cycles_with_the_same_arguments
    engine = Object.new
    def engine.audit_review_workspaces(trigger:) = nil
    def engine.next_retry_at = nil
    restarted = nil
    update = Object.new
    update.define_singleton_method(:enabled?) { true }
    update.define_singleton_method(:updated?) { true }
    update.define_singleton_method(:restart) { |argv| restarted = argv }
    github = OpenStruct.new(repo_name: "owner/project")
    scheduler = Ghwatch::Scheduler.new(task_engine: engine, review_intake: nil, issue_triage: nil,
      config: OpenStruct.new(poll_interval: 600), github: github, log: Ghwatch::Log.new(StringIO.new),
      self_update: update, argv: ["-v"])
    cycles = 0
    scheduler.define_singleton_method(:cycle) { cycles += 1 }
    scheduler.define_singleton_method(:trap_signals) {}
    scheduler.run
    assert_equal 1, cycles
    assert_equal ["-v"], restarted
  end
end
