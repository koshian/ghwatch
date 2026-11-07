# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

# A maintainer plans work by milestone: issues in a milestone that is not
# active wait for later, however complete their specification is.
class ActiveMilestonesTest < Minitest::Test
  LATER = {"title" => "2.0"}.freeze
  NOW = {"title" => "1.1.0"}.freeze

  def test_only_another_milestone_than_the_active_ones_is_for_later
    assert Ghwatch::Github.later_milestone?({"milestone" => LATER}, active: ["1.1.0"])
    refute Ghwatch::Github.later_milestone?({"milestone" => NOW}, active: ["1.1.0"])
    refute Ghwatch::Github.later_milestone?({"milestone" => nil}, active: ["1.1.0"])
    refute Ghwatch::Github.later_milestone?({}, active: ["1.1.0"])
    refute Ghwatch::Github.later_milestone?({"milestone" => LATER}, active: []), "without the setting milestones do not matter"
    refute Ghwatch::Github.later_milestone?({"milestone" => LATER}, active: nil)
  end

  def test_triage_leaves_out_issues_for_a_later_milestone
    github = OpenStruct.new(viewer_login: "koshian", open_issues: [
      {"number" => 960, "milestone" => NOW}, {"number" => 961}, {"number" => 962, "milestone" => LATER}
    ])
    config = OpenStruct.new(candidate_limit: 2, active_milestones: ["1.1.0"])
    state = Struct.new(:tasks).new([])
    triage = Ghwatch::IssueTriage.new(project: nil, config: config, state: state, github: github,
      roles: nil, worktrees: nil, context_builder: nil, log: Ghwatch::Log.new(StringIO.new))
    assert_equal [960, 961], triage.send(:candidate_issues).map { |issue| issue["number"] }
  end

  def test_an_issue_for_later_shows_deferred_unless_a_task_is_on_it
    Dir.mktmpdir do |directory|
      state = Ghwatch::StateStore.new(File.join(directory, "state.sqlite3"))
      state.save_assessment(962, status: "ready", reason: "clear", comment: nil, signature: "s", at: 100)
      state.save_task(Ghwatch::Task.for_issue(963, branch: "b", worktree: nil))
      synced = []
      github = OpenStruct.new(viewer_login: "koshian", open_issues: [
        {"number" => 962, "labels" => [{"name" => "ghwatch:ready"}], "milestone" => LATER},
        {"number" => 963, "labels" => [{"name" => "ghwatch:implementing"}], "milestone" => LATER},
        {"number" => 964, "labels" => [{"name" => "ghwatch:hands-off"}], "milestone" => LATER}
      ])
      github.define_singleton_method(:sync_issue_state_label) { |number, label:, **| synced << [number, label] }
      config = Ghwatch::Config.new({"triage" => {"active_milestones" => ["1.1.0"]}})
      Ghwatch::StatusLabels.new(state: state, github: github, config: config, log: Ghwatch::Log.new(StringIO.new)).sync_all
      assert_equal [[962, "ghwatch:deferred"]], synced
    end
  end

  def test_the_setting_is_a_list_of_titles
    assert_equal [], Ghwatch::Config.new({}).active_milestones
    assert_equal ["1.1.0"], Ghwatch::Config.new({"triage" => {"active_milestones" => ["1.1.0"]}}).active_milestones
    ["1.1.0", [1.1]].each do |value|
      error = assert_raises(Ghwatch::Config::Error) { Ghwatch::Config.new({"triage" => {"active_milestones" => value}}).validate! }
      assert_includes error.message, "active_milestones"
    end
  end
end
