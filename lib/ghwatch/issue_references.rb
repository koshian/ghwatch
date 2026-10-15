# frozen_string_literal: true

module Ghwatch
  # The current state of the issues and pull requests an issue mentions as
  # #N. What an issue waits for is usually named that way; without its state
  # a model cannot tell whether the wait is over. One instance serves one
  # triage run, so each mention is looked up once.
  class IssueReferences
    MAX = 10
    MENTION = /(?<![\w\/&])#(\d+)\b/

    # lookup: number -> state of the issue or PR #number.
    def initialize(lookup:, log: Log.new)
      @lookup = lookup
      @log = log
      @cache = {}
    end

    def for(issue, comments: Array(issue["comments"]))
      text = ([issue["body"]] + comments.map { |comment| comment["body"] }).join("\n")
      numbers = text.scan(MENTION).flatten.map(&:to_i).uniq - [issue["number"]]
      numbers.first(MAX).filter_map do |number|
        @cache.fetch(number) { @cache[number] = lookup(number) }
      end
    end

    private

    def lookup(number)
      @lookup.call(number)
    rescue => e
      @log.warn("could not read the state of ##{number}: #{e.message}")
      nil
    end
  end
end
