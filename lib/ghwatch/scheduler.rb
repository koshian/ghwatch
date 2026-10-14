# frozen_string_literal: true

module Ghwatch
  class Scheduler
    # How often a long wait checks whether a new ghwatch was installed.
    UPDATE_CHECK_INTERVAL = 60
    # A cycle at least this long is followed by another look at GitHub
    # before waiting.
    RECHECK_AFTER = 60

    def initialize(task_engine:, review_intake:, issue_triage:, config:, github:, status_labels: nil, log: Log.new,
      self_update: nil, argv: [])
      @task_engine = task_engine
      @review_intake = review_intake
      @issue_triage = issue_triage
      @config = config
      @github = github
      @status_labels = status_labels
      @log = log
      @self_update = self_update
      @argv = argv
      @running = true
      @wakeup_reader, @wakeup_writer = IO.pipe
    end

    def run
      trap_signals
      @log.info("ghwatch started for #{@github.repo_name}")
      # Changes found here happened while ghwatch was not running, e.g. an
      # interrupted git command.
      @task_engine.audit_review_workspaces(trigger: "at ghwatch startup")

      while @running
        started = Time.now
        cycle
        # Between cycles no agent runs, so this is where a new install takes over.
        return restart if updated?

        pause(started)
        return restart if updated?
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

    # A long cycle may have missed new PRs, replies and pushes made while
    # agents ran; look again so they do not wait out a whole poll.
    def pause(cycle_started)
      return unless @running

      triage_requested = Time.now - cycle_started >= RECHECK_AFTER && recheck
      wait(@config.poll_interval) if @running && !triage_requested
    end

    # What a cycle's first steps found, looked at again. Whatever needs work
    # is scheduled to run now, so the wait that follows ends at once. Returns
    # whether a changed issue asked for triage; one still due after a failed
    # run does not count, or the loop would retry it without pause.
    def recheck
      triage_was_due = @issue_triage.due?
      [
        -> { @task_engine.reconcile_all },
        -> { @review_intake.discover },
        -> { @issue_triage.request_if_watched_issue_changed }
      ].each do |step|
        break unless @running

        step.call
      end
      !triage_was_due && @issue_triage.due?
    rescue => e
      @log.error("recheck failed: #{e.class}: #{e.message}")
      false
    end

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
      deadline = Time.now + seconds
      checking = @self_update&.enabled?
      while @running && (remaining = deadline - Time.now) > 0
        break if IO.select([@wakeup_reader], nil, nil, checking ? [remaining, UPDATE_CHECK_INTERVAL].min : remaining)
        break if checking && updated?
      end
    end

    def updated?
      return false unless @running && @self_update
      return @updated if @updated

      @updated = @self_update.updated?
    rescue => e
      @log.warn("could not check for a newly installed ghwatch: #{e.message}")
      false
    end

    def restart
      @log.info("a new ghwatch was installed; restarting into it")
      @self_update.restart(@argv)
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
