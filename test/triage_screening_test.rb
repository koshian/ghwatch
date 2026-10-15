# frozen_string_literal: true

require_relative "test_helper"
require "ostruct"
require "stringio"

class TriageScreeningTest < Minitest::Test
  class Github
    attr_accessor :issues, :merged_at
    attr_reader :read

    def initialize(issues)
      @issues = issues.to_h { |issue| [issue["number"], issue] }
      @merged_at = nil
      @read = []
    end

    def open_issues = @issues.values.map { |issue| issue.slice("number", "updatedAt") }

    def issue(number)
      @read << number
      @issues.fetch(number)
    end

    def issue_content_signature(issue) = "#{issue["number"]}:#{issue["body"]}"

    def open_pull_requests = [{"number" => 172, "title" => "Start at login"}]

    def last_merged_at = @merged_at

    def reference(number) = {"number" => number, "kind" => "issue", "state" => "open"}
  end

  class State
    attr_reader :started
    attr_accessor :tasks

    def initialize
      @assessments = {}
      @started = []
      @tasks = []
    end

    def assessment(number) = @assessments[number]

    def save_assessment(number, status:, reason:, comment:, signature:, at: Time.now.to_i, issue_updated_at: nil)
      @assessments[number] = {status: status, reason: reason, comment: comment,
                              issue_signature: signature, issue_updated_at: issue_updated_at, updated_at: at}
    end

    def touch_assessment(number, signature:, issue_updated_at:)
      @assessments[number].merge!(issue_signature: signature, issue_updated_at: issue_updated_at)
    end

    def backdate(number, seconds) = @assessments[number][:updated_at] -= seconds

    def task_for_issue(number) = nil

    def save_task(task) = @started << task.issue_number

    def set_setting(key, value) = nil

    def setting(key) = nil
  end

  class Roles
    attr_reader :calls, :contexts

    def initialize(&decide)
      @decide = decide
      @calls = []
      @contexts = []
    end

    def run(role, context:, cwd:)
      @contexts << context
      numbers = context.scan(/"number": (\d+)/).flatten.map(&:to_i).uniq
      @calls << numbers
      data = @decide.call(numbers)
      OpenStruct.new(success?: true, data: data, signature: "llm")
    end
  end

  class Client
    attr_reader :calls, :states

    def initialize(answers) = (@answers = answers) && (@calls = []) && (@states = [])

    def evaluate(state:, questions:)
      number = state.dig("issue", "number")
      @calls << number
      @states << state
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
    client = Client.new(1 => ["followup", 0.93], 2 => ["deferred", 0.5], 3 => ["ready", 0.99])
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

  def test_one_triage_sees_merges_made_after_its_earlier_runs
    client = Client.new(1 => ["deferred", 0.95], 2 => ["skip", 0.95], 3 => ["followup", 0.95])
    roles = Roles.new { |numbers| assessed(numbers) }
    running = triage(roles, client)
    running.run
    @state.backdate(1, 10)
    running.run
    assert_equal [1, 2, 3], client.calls

    @github.merged_at = Time.now.to_i - 5
    running.run
    assert_equal [1, 2, 3, 1], client.calls
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

  def test_ready_issues_start_oldest_first_whoever_the_model_selects
    client = Client.new(5 => ["ready", 0.99], 3 => ["ready", 0.99], 4 => ["ready", 0.99])
    @github.issues = {5 => issue(5)}
    roles = Roles.new { |numbers| {"selected_issues" => numbers.reverse, "assessments" => numbers.map { |n| {"issue" => n, "status" => "ready", "reason" => "clear"} }} }
    triage(roles, client).tap { |t| def t.available_worker_slots = 0 }.run

    @github.issues[3] = issue(3)
    @github.issues[4] = issue(4)
    triage(roles, client).tap { |t| def t.available_worker_slots = 2 }.run
    assert_equal [3, 4], @state.started
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
    [1, 2, 3].each do |number|
      @state.save_assessment(number, status: "ready", reason: "clear", comment: nil, signature: @github.issue_content_signature(issue(number)))
    end
    triage(roles, client).tap { |t| def t.available_worker_slots = 0 }.run
    assert_empty @state.started
    assert_empty roles.calls, "with no worker free, issues are not looked at"

    triage(roles, client).tap { |t| def t.available_worker_slots = 2 }.run
    assert_equal [1, 2], @state.started
    assert_empty roles.calls
    assert_empty client.calls
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

  def test_screening_is_given_the_state_of_what_the_issue_mentions_and_which_comments_are_new
    states = []
    client = Object.new
    client.define_singleton_method(:evaluate) do |state:, questions:|
      states << state
      {"model" => "jev-1.13.0", "answers" => {"status" => {"choice" => "ready", "confidence" => 0.9}}}
    end
    looked_up = []
    references = lambda do |number|
      looked_up << number
      raise "HTTP 404" if number == 404
      {"number" => number, "kind" => "issue", "state" => "closed", "closedAs" => "completed"}
    end
    assessed_at = Time.parse("2026-10-11T01:00:00Z").to_i
    first = issue(280, body: "Start after #268 is done and #279 is merged; not #280, https://example.com/#12 or &#38;.")
    first["comments"] = [
      {"author_association" => "OWNER", "created_at" => "2026-10-10T00:00:00Z", "body" => "See #404"},
      {"author_association" => "OWNER", "created_at" => "2026-10-11T01:08:15Z", "body" => "Go ahead"}
    ]
    second = issue(281, body: "Needs #268 too")
    screening = Ghwatch::IssueScreening.new(config: @config, log: Ghwatch::Log.new(@log), client: client)
    screening.settle([first, second], open_pull_requests: [], references: references,
      previous: {280 => {status: "deferred", updated_at: assessed_at}})

    assert_equal [268, 279], states.first["referenced"].map { |item| item["number"] }
    assert_equal "completed", states.first["referenced"].first["closedAs"]
    assert_equal [false, true], states.first.dig("issue", "comments").map { |comment| comment["new"] }
    assert_equal "2026-10-11T01:08:15Z", states.first.dig("issue", "comments").last["createdAt"]
    assert_equal [268], states.last["referenced"].map { |item| item["number"] }
    assert_equal [268, 279, 404], looked_up, "each mention is looked up once per run"
    assert_includes @log.string, "could not read the state of #404"
  end

  def test_triage_looks_up_what_issues_mention_for_screening
    @github.issues[1] = issue(1, body: "After #5")
    client = Client.new(1 => ["deferred", 0.95], 2 => ["skip", 0.95], 3 => ["skip", 0.95])
    triage(Roles.new { |numbers| assessed(numbers) }, client).run
    assert_equal [{"number" => 5, "kind" => "issue", "state" => "open"}], client.states.first["referenced"]
  end

  def test_screening_keeps_issues_waiting_but_only_the_llm_starts_a_wait
    client = Client.new(1 => ["deferred", 0.98], 2 => ["deferred", 0.98], 3 => ["skip", 0.95])
    roles = Roles.new { |numbers| assessed(numbers, status: "ready") }
    @state.save_assessment(2, status: "deferred", reason: "waits for #5", comment: nil, signature: "old")
    triage(roles, client).run
    assert_equal [[1]], roles.calls, "a new deferred answer goes to the LLM; a kept one does not"
    assert_equal "waits for #5", @state.assessment(2)[:reason], "kept waiting for the reason the LLM gave"
    assert_equal "ready", @state.assessment(1)[:status]
  end

  def test_the_llm_is_told_whether_what_an_issue_waits_for_is_done
    @github.issues = {370 => issue(370, body: "Wait for #364 to be merged")}
    @github.define_singleton_method(:reference) { |number| {"number" => number, "kind" => "pull_request", "state" => "merged"} }
    roles = Roles.new { {"selected_issues" => [], "assessments" => []} }
    triage(roles, Client.new(370 => ["ready", 0.5])).run
    candidate = JSON.parse(roles.contexts.first[/Candidates:\n(.*)\z/m, 1]).first
    assert_equal [{"number" => 364, "kind" => "pull_request", "state" => "merged"}], candidate["referenced"]
    assert_includes roles.contexts.first, "a wait for a pull request that is merged"
  end

  def test_relabeling_does_not_make_an_issue_judged_again_and_a_quiet_list_reads_nothing
    @github.issues = {1 => issue(1).merge("updatedAt" => "t1")}
    client = Client.new(1 => ["skip", 0.95])
    triage(Roles.new { |numbers| assessed(numbers) }, client).run
    assert_equal [1], client.calls

    # ghwatch labels the issue, which changes its updatedAt and nothing else.
    @github.issues[1]["updatedAt"] = "t2"
    @github.read.clear
    triage(Roles.new { |numbers| assessed(numbers) }, client).run
    assert_equal [1], client.calls, "not judged again"
    assert_equal [1], @github.read
    assert_equal "t2", @state.assessment(1)[:issue_updated_at]

    @github.read.clear
    triage(Roles.new { |numbers| assessed(numbers) }, client).run
    assert_empty @github.read, "the list shows nothing changed, so the issue is not read"
  end

  def test_an_issue_still_open_after_its_task_finished_is_judged_again
    @github.issues = {1 => issue(1).merge("updatedAt" => "t1")}
    client = Client.new(1 => ["followup", 0.95])
    triage(Roles.new { |numbers| assessed(numbers) }, client).run
    @state.backdate(1, 10)
    done = Ghwatch::Task.for_issue(1, branch: "b", worktree: nil)
    done.state = "done"
    done.metadata["state_since"] = Time.now.to_i - 5
    @state.tasks = [done]
    triage(Roles.new { |numbers| assessed(numbers) }, client).run
    assert_equal [1, 1], client.calls, "reopened, or waiting for a person: judged again"
  end
end
