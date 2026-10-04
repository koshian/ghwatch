# frozen_string_literal: true

module Ghwatch
  class RepositoryState
    attr_reader :head, :status

    def self.capture(command:, cwd:)
      head = command.run("git", "rev-parse", "HEAD", chdir: cwd, timeout: 30)
      status = command.run("git", "status", "--porcelain=v1", chdir: cwd, timeout: 30)

      new(
        head: head.success? ? head.stdout.strip : nil,
        status: status.success? ? status.stdout : nil
      )
    end

    def initialize(head:, status:)
      @head = head
      @status = status
    end

    def ==(other)
      other.is_a?(RepositoryState) && head == other.head && status == other.status
    end
  end
end
