# frozen_string_literal: true

require_relative "test_helper"

class VerboseCliTest < Minitest::Test
  class Scheduler
    def run = nil
  end

  class CLI < Ghwatch::CLI
    class << self
      attr_accessor :verbose
    end

    private

    def build_components
      self.class.verbose = options[:verbose]
      {scheduler: Scheduler.new}
    end
  end

  def test_verbose_option_supports_default_and_explicit_run
    [[], ["-v"], ["run", "-v"], ["run", "--verbose"]].each do |args|
      CLI.start(args)
      assert_equal !args.empty?, CLI.verbose
    end
  end
end
