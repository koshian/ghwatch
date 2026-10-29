# frozen_string_literal: true

require "monitor"

module Ghwatch
  # One lock per task, for the threads that may act on the same task: the
  # lanes running its actions, the engine looking at GitHub for it, and the
  # test build watcher. Whoever holds it reads the task afresh first.
  class TaskLocks
    def initialize
      @guard = Mutex.new
      @locks = {}
    end

    def synchronize(id, &)
      lock_for(id).synchronize(&)
    end

    # Runs the block unless another thread holds the task; returns whether
    # it ran.
    def try(id)
      lock = lock_for(id)
      return false unless lock.try_enter

      begin
        yield
      ensure
        lock.exit
      end
      true
    end

    private

    def lock_for(id)
      @guard.synchronize { @locks[id] ||= Monitor.new }
    end
  end
end
