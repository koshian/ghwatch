# frozen_string_literal: true

module Ghwatch
  # Runs one lane's actions on a thread of its own (parallel_review). It
  # does not look at GitHub itself: the scheduler does, and wakes it.
  class Lane
    # A lane with nothing due looks again at least this often.
    IDLE_CHECK = 60

    attr_reader :name

    # after runs when the lane has run what was due, with the number of
    # actions it ran.
    def initialize(name:, task_engine:, log: Log.new, after: nil)
      @name = name
      @task_engine = task_engine
      @log = log
      @after = after
      @busy = false
      @wakeup_reader, @wakeup_writer = IO.pipe
    end

    def start
      @stopping = false
      @thread = Thread.new { work until @stopping }
    end

    def wake
      @wakeup_writer.write_nonblock(".", exception: false)
    end

    # Stops after the current action; join waits for it.
    def stop
      @stopping = true
      wake
    end

    def join = @thread&.join

    def busy? = @busy

    private

    def work
      @busy = true
      actions = @task_engine.run_due(lane: @name, stop_requested: -> { @stopping })
      @after&.call(actions) unless @stopping
    rescue => e
      @log.error("#{@name} lane failed: #{e.class}: #{e.message}")
    ensure
      @busy = false
      wait unless @stopping || @task_engine.due?(lane: @name)
    end

    def wait
      retry_at = @task_engine.next_retry_at(lane: @name)
      seconds = retry_at ? (retry_at - Time.now.to_i).clamp(1, IDLE_CHECK) : IDLE_CHECK
      return unless IO.select([@wakeup_reader], nil, nil, seconds)

      @wakeup_reader.read_nonblock(1024, exception: false)
    end
  end
end
