# frozen_string_literal: true

module Ghwatch
  class Scheduler
    def initialize(task_engine:, review_intake:, issue_triage:, config:, github:, log: Log.new)
      @task_engine = task_engine
      @review_intake = review_intake
      @issue_triage = issue_triage
      @config = config
      @github = github
      @log = log
      @running = true
    end

    def run
      trap_signals
      @log.info("ghwatch started for #{@github.repo_name}")

      while @running
        cycle
        sleep @config.poll_interval if @running
      end

      @log.info("ghwatch stopped")
    end

    def cycle
      reload_config_if_changed
      @task_engine.reconcile_all
      @review_intake.discover
      @issue_triage.request_if_watched_issue_changed
      @issue_triage.run if @issue_triage.due?
      @task_engine.run_due
    rescue => e
      @log.error("cycle failed: #{e.class}: #{e.message}")
    end

    private

    def reload_config_if_changed
      @log.info("reloaded .ghwatch/config.toml") if @config.reload_if_changed!
    rescue Config::Error => e
      @log.error("config reload failed; keeping previous configuration: #{e.message}")
    end

    def trap_signals
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { @running = false }
      rescue ArgumentError
        nil
      end
    end
  end
end
