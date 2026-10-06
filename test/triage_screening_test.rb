# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class TriageScreeningTest < Minitest::Test
  class Github
    attr_accessor :issues, :merged_at

    def initialize(issues)
      @issues = issues.to_h { |issue| [issue["number"], issue] }
      @merged_at = nil
    end

    def open_issues = @issues.values.map { |issue| {"number" => issue["number"]} }

    def issue(number) = @issues.fetch(number)

    def issue_signature(issue) = "#{issue["number"]}:#{issue["body"]}"

    def open_pull_requests = [{"number" => 172, "title" => "Start at login"}]

    def last_merged_at = @merged_at
  end

  class State
    attr_reader :started

    def initialize
      @assessments = {}
      @started = []
    end

    def tasks = []

    def assessment(number) = @assessments[number]

    def save_assessment(number, status:, reason:, comment:, signature:, at: Time.now.to_i)
      @assessments[number] = {status: status, reason: reason, comment: comment,
                              issue_signature: signature, updated_at: at}
    end

    def backdate(number, seconds) = @assessments[number][:updated_at] -= seconds

    def task_for_issue(number) = nil

    def save_task(task) = @started << task.issue_number

    def set_setting(key, value) = nil

    def setting(key) = nil
  end

  class Roles
    attr_reader :calls

    def initialize(&decide)
      @decide = decide
      @calls = []
    end

    def run(role, context:, cwd:)
      numbers = context.scan(/"number": (\d+)/).flatten.map(&:to_i).uniq
      @calls << numbers
      data = @decide.call(numbers)
      OpenStruct.new(success?: true, data: data, signature: "llm")
    end
  end

  class Client
    attr_reader :calls

    def initialize(answers) = (@answers = answers) && (@calls = [])

    def evaluate(state:, questions:)
      number = state.dig("issue", "number")
      @calls << number
      raise Ghwatch::Jev::Error, "HTTP 529: overloaded" if @answers[number] == :error

      choice, confidence = @answers.fetch(number)
      {"model" => "jev-1.13.0", "answers" => {"status" => {"type" => "choice", "choice" => choice, "confidence" => confidence}}}
    end
  end

  def setup
    @github = Github.new([issue(1), issue(2), issue(3)])
    @state = State.new
    @log = StringIO.new
    @config = Ghwatch::Config.new(TomlRB.load_file(File.expand_path("../lib/ghwatch/default_config.toml", __dir__)).merge(
      "triage" => {"reassess_after" => "1d", "screening" => {"enabled" => true, "min_confidence" => 0.8}}
    ))
    @worktrees = Object.new
    def @worktrees.prepare(number) = ["ghwatch/issue-#{number}", "/w/#{number}"]
  end

  def issue(number, body: "body") = {"number" => number, "title" => "Issue #{number}", "body" => body, "comments" => []}

  def triage(roles, client)
    screening = Ghwatch::IssueScreening.new(config: @config, log: Ghwatch::Log.new(@log), client: client)
    Ghwatch::IssueTriage.new(project: OpenStruct.new(root: "."), config: @config, state: @state, github: @github,
      roles: roles, worktrees: @worktrees, context_builder: Ghwatch::ContextBuilder.new(config: @config),
      log: Ghwatch::Log.new(@log), screening: screening)
  end

  def assessed(numbers, status: "deferred")
    {"selected_issues" => [], "assessments" => numbers.map { |number| {"issue" => number, "status" => status, "reason" => "llm"} }}
  end

  def test_only_unsettled_issues_reach_the_llm_and_unchanged_ones_are_not_judged_again
    client = Client.new(1 => ["deferred", 0.93], 2 => ["deferred", 0.5], 3 => ["ready", 0.99])
    roles = Roles.new { |numbers| assessed(numbers) }
    triage(roles, client).run
    assert_equal [1, 2, 3], client.calls
    assert_equal [[2, 3]], roles.calls
    assert_equal "settled by jev-1.13.0 screening", @state.assessment(1)[:reason]

    triage(roles, client).run
    assert_equal [1, 2, 3], client.calls, "unchanged issues must not be screened again"
    assert_equal [[2, 3]], roles.calls

    @github.issues[2] = issue(2, body: "edited")
    triage(roles, client).run
    assert_equal [1, 2, 3, 2], client.calls
    assert_equal [[2, 3], [2]], roles.calls
  end

  def test_deferred_issues_are_judged_again_after_a_merge_or_when_stale
    client = Client.new(1 => ["deferred", 0.95], 2 => ["skip", 0.95], 3 => ["followup", 0.95])
    roles = Roles.new { |numbers| assessed(numbers) }
    triage(roles, client).run
    assert_equal [1, 2, 3], client.calls

    @state.backdate(1, 10)
    @github.merged_at = Time.now.to_i - 5
    triage(roles, client).run
    assert_equal [1, 2, 3, 1], client.calls, "only the deferred issue waits on a merge"

    @state.backdate(2, 2 * 86_400)
    triage(roles, client).run
    assert_equal [1, 2, 3, 1, 2], client.calls
  end

  def test_a_merge_while_triage_was_running_is_not_missed
    client = Client.new(1 => ["deferred", 0.95], 2 => ["deferred", 0.95], 3 => ["deferred", 0.95])
    roles = Roles.new { |numbers| assessed(numbers) }
    github = @github
    # The PR merges after triage began but before its answer is saved.
    github.define_singleton_method(:open_pull_requests) do
      github.merged_at = Time.now.to_i
      [{"number" => 172, "title" => "Start at login"}]
    end
    triage(roles, client).run
    assert_operator @state.assessment(1)[:updated_at], :<=, github.merged_at
    triage(roles, client).run
    assert_equal [1, 2, 3, 1, 2, 3], client.calls
  end

  def test_issues_ready_for_longer_start_before_newly_selected_ones
    client = Client.new(1 => ["ready", 0.99], 2 => ["ready", 0.99], 3 => ["ready", 0.99], 4 => ["ready", 0.99])
    @github.issues = {1 => issue(1), 2 => issue(2)}
    roles = Roles.new { |numbers| {"selected_issues" => numbers, "assessments" => numbers.map { |n| {"issue" => n, "status" => "ready", "reason" => "clear"} }} }
    triage(roles, client).tap { |t| def t.available_worker_slots = 0 }.run
    assert_empty @state.started

    @github.issues[3] = issue(3)
    @github.issues[4] = issue(4)
    triage(roles, client).tap { |t| def t.available_worker_slots = 2 }.run
    assert_equal [1, 2], @state.started
  end

  def test_unchanged_ready_issues_start_when_a_slot_opens
    roles = Roles.new { |numbers| {"selected_issues" => [], "assessments" => numbers.map { |n| {"issue" => n, "status" => "ready", "reason" => "clear"} }} }
    client = Client.new(1 => ["ready", 0.99], 2 => ["ready", 0.99], 3 => ["ready", 0.99])
    triage(roles, client).tap { |t| def t.available_worker_slots = 0 }.run
    assert_empty @state.started

    triage(roles, client).tap { |t| def t.available_worker_slots = 2 }.run
    assert_equal [1, 2], @state.started
    assert_equal 1, roles.calls.size
  end

  def test_a_screening_failure_or_missing_key_sends_every_issue_to_the_llm
    roles = Roles.new { |numbers| assessed(numbers) }
    triage(roles, Client.new(1 => :error)).run
    assert_equal [[1, 2, 3]], roles.calls
    assert_includes @log.string, "screening failed"

    @state = State.new
    Roles.new { |numbers| assessed(numbers) }
    screening = Ghwatch::IssueScreening.new(config: @config, log: Ghwatch::Log.new(@log), env: {})
    assert_empty screening.settle([issue(1)], open_pull_requests: [], previous: {})
    assert_includes @log.string, "TYPESAFE_API_KEY is not set"
  end

  def test_conversations_under_way_are_left_to_the_llm
    @state.save_assessment(1, status: "discussion", reason: "idea", comment: "q", signature: "old")
    client = Client.new(2 => ["skip", 0.99], 3 => ["skip", 0.99])
    roles = Roles.new { |numbers| assessed(numbers, status: "discussion") }
    triage(roles, client).run
    assert_equal [2, 3], client.calls
    assert_equal [[1]], roles.calls
  end
end
