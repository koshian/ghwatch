# frozen_string_literal: true

require "time"

module Ghwatch
  class Log
    def initialize(io = $stdout)
      @io = io
    end

    def info(message)
      write(message)
    end

    def warn(message)
      write("WARN #{message}")
    end

    def error(message)
      write("ERROR #{message}")
    end

    private

    def write(message)
      @io.puts("#{Time.now.iso8601} #{message}")
      @io.flush
    end
  end
end
