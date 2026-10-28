# frozen_string_literal: true

require "time"

module Ghwatch
  # The test builds a reviewer started for a person, as GitHub Actions runs:
  # how long to wait before looking, whether they are done, and links to what
  # they built. Failures are not analysed here; the reviewer reads them.
  class TestBuilds
    # Without successful runs of the workflow to go by.
    DEFAULT_WAIT = 5 * 60
    # Earlier successful runs of the same workflow that set the wait.
    SAMPLES = 10
    # How long past its usual time a build may run before the reviewer is
    # told it did not finish.
    DEADLINE_FACTOR = 3
    MIN_DEADLINE = 30 * 60

    Status = Data.define(:state, :runs, :artifacts)

    def initialize(github:, clock: -> { Time.now.to_i })
      @github = github
      @clock = clock
    end

    # When to look first and when to give up, from how long the runs'
    # workflows usually take, queueing included.
    def plan(run_ids)
      wait = run_ids.map { |id| usual_seconds(id) }.max || DEFAULT_WAIT
      now = @clock.call
      {"runs" => run_ids, "check_at" => now + wait, "deadline" => now + [wait * DEADLINE_FACTOR, MIN_DEADLINE].max}
    end

    def status(run_ids)
      runs = run_ids.map { |id| @github.workflow_run(id) }
      return Status.new(state: :pending, runs: runs, artifacts: []) unless runs.all? { |run| run["status"] == "completed" }
      return Status.new(state: :failed, runs: runs, artifacts: []) unless runs.all? { |run| run["conclusion"] == "success" }

      artifacts = runs.flat_map { |run| @github.run_artifacts(run["id"]).reject { |artifact| artifact["expired"] }.map { |artifact| [run, artifact] } }
      Status.new(state: :success, runs: runs, artifacts: artifacts)
    end

    private

    def usual_seconds(run_id)
      run = @github.workflow_run(run_id)
      spans = @github.successful_workflow_runs(run["workflow_id"], limit: SAMPLES).filter_map do |earlier|
        next unless earlier["created_at"] && earlier["updated_at"]

        span = Time.parse(earlier["updated_at"]) - Time.parse(earlier["created_at"])
        span if span.positive?
      end
      return if spans.empty?

      spans.sort[spans.size / 2].ceil
    end
  end
end
