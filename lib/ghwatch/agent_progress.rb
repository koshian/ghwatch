# frozen_string_literal: true

module Ghwatch
  class AgentProgress
    FRAMES = %w[| / - \\].freeze

    def initialize(label:, io: $stderr)
      @label = label
      @io = io
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @frame = 0
      @buffers = {stdout: +"", stderr: +""}
    end

    def output(stream, text)
      buffer = @buffers.fetch(stream)
      buffer << text
      while (newline = buffer.index("\n"))
        write_line(stream, buffer.slice!(0..newline).chomp)
      end
    end

    def tick
      return unless @io.tty?

      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at).to_i
      @io.print("\r\e[2K#{FRAMES[@frame % FRAMES.length]} #{@label} running (#{elapsed}s)")
      @io.flush
      @frame += 1
    end

    def finish
      @buffers.each do |stream, buffer|
        write_line(stream, buffer) unless buffer.empty?
        buffer.clear
      end
      clear_spinner
      @io.flush
    end

    private

    def write_line(stream, line)
      clear_spinner
      @io.puts("#{@label} #{stream}: #{line}")
      @io.flush
    end

    def clear_spinner
      @io.print("\r\e[2K") if @io.tty?
    end
  end
end
