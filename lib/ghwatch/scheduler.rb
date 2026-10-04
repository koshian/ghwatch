# frozen_string_literal: true

module Ghwatch
  class Scheduler
    def initialize(task_engine:, review_intake:, issue_triage:, config:, github:, status_labels: nil, log: Log.new)
      @task_engine = task_engine
      @review_intake = review_intake
      @issue_triage = issue_triage
      @config = config
      @github = github
      @status_labels = status_labels
      @log = log
      @running = true
      @wakeup_reader, @wakeup_writer = IO.pipe
    end

    def run
      trap_signals
      @log.info("ghwatch started for #{@github.repo_name}")

      while @running
        cycle
        wait(@config.poll_interval) if @running
      end

      @log.info("ghwatch stopped")
    end

    def cycle
      steps = [
        -> { reload_config_if_changed },
        -> { @status_labels&.sync_all },
        -> { @task_engine.reconcile_all },
        -> { @review_intake.discover },
        -> { @task_engine.run_due(scope: :pull_requests, stop_requested: -> { !@running }) },
        -> { @issue_triage.request_if_watched_issue_changed },
        -> { @issue_triage.run if @issue_triage.due? },
        -> { @task_engine.run_due(scope: :all, stop_requested: -> { !@running }) }
      ]
      steps.each do |step|
        break unless @running

        step.call
      end
    rescue => e
      @log.error("cycle failed: #{e.class}: #{e.message}")
    end

    private

    def reload_config_if_changed
      @log.info("reloaded .ghwatch/config.toml") if @config.reload_if_changed!
    rescue Config::Error => e
      @log.error("config reload failed; keeping previous configuration: #{e.message}")
    end

    # Sleeps for the poll interval, but returns as soon as a stop is requested.
    # A trapped signal does not interrupt Kernel#sleep, so wait on a self-pipe.
    def wait(seconds)
      retry_at = @task_engine.next_retry_at
      if retry_at
        retry_delay = [retry_at - Time.now.to_i, 1].max
        seconds = [seconds, retry_delay].min
      end
      @log.info("waiting until #{(Time.now + seconds).iso8601} for the next check (#{seconds}s)")
      IO.select([@wakeup_reader], nil, nil, seconds)
    end

    # The first INT/TERM stops ghwatch after the current step. The handler then
    # restores Ruby's default, so a second one interrupts immediately.
    def trap_signals
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { request_stop(signal) }
      rescue ArgumentError
        nil
      end
    end

    def request_stop(signal)
      @running = false
      @wakeup_writer.write_nonblock(".", exception: false)
      Signal.trap(signal, "DEFAULT")
      @log.info("stopping after the current step (#{signal} again to quit immediately)")
    end
  end
end
