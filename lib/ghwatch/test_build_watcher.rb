# frozen_string_literal: true

module Ghwatch
  # Looks at the test builds tasks wait for, on a thread of its own, so a
  # build is announced as soon as it is done even while an agent runs. It
  # only reads GitHub and posts the reviewer's request; no git and no agent.
  # The lock is shared with the task engine, which reloads a waiting task
  # under it before reacting to GitHub.
  class TestBuildWatcher
    POLL = 30
    STATE = "waiting_for_test_build"

    def initialize(state:, reviewer:, test_builds:, lock:, log: Log.new, clock: -> { Time.now.to_i })
      @state = state
      @reviewer = reviewer
      @test_builds = test_builds
      @lock = lock
      @log = log
      @clock = clock
      @wakeup_reader, @wakeup_writer = IO.pipe
    end

    def start
      @stopping = false
      @thread = Thread.new do
        until @stopping
          begin
            check_due
          rescue => e
            @log.warn("could not check the test builds: #{e.message}")
          end
          IO.select([@wakeup_reader], nil, nil, POLL)
        end
      end
    end

    def stop
      @stopping = true
      @wakeup_writer.write_nonblock(".", exception: false)
      @thread&.join(60)
    end

    def check_due
      @state.tasks.select { |task| task.state == STATE }.each do |task|
        next if task.metadata.dig("test_build", "check_at").to_i > @clock.call

        @lock.synchronize { check(@state.task(task.id)) }
      rescue => e
        @log.warn("[#{task.id}] could not check the test build: #{e.message}")
      end
    end

    private

    def check(task)
      return unless task&.state == STATE

      build = task.metadata["test_build"]
      return @reviewer.test_build_failed(task, "no test build was recorded for this request") unless build

      status = @test_builds.status(build["runs"])
      case status.state
      when :success
        @reviewer.announce_test_build(task, status)
      when :failed
        @reviewer.test_build_failed(task, "the test build failed: #{describe(status.runs)}")
      else
        return @reviewer.test_build_failed(task, "the test build did not finish in time: #{describe(status.runs)}") if @clock.call > build["deadline"].to_i

        build["check_at"] = @clock.call + POLL
        @state.save_task(task)
      end
    end

    def describe(runs)
      runs.map { |run| "#{run["html_url"]} (#{run["conclusion"] || run["status"]})" }.join(", ")
    end
  end
end
