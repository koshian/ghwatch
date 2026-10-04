# frozen_string_literal: true

module Ghwatch
  module Runners
    class Base
      Invocation = Data.define(:runner, :model, :command_result, :error_kind) do
        def success?
          command_result.success? && error_kind.nil?
        end

        def output
          command_result.stdout
        end

        def diagnostics
          command_result.text
        end

        def signature
          "#{runner}:#{model}"
        end
      end

      def initialize(settings:, command:, log: Log.new)
        @settings = settings
        @command = command
        @log = log
      end

      def run(model:, prompt:, cwd:, extra_args: [], progress: nil)
        # The prompt goes through stdin: as a single argv entry it can exceed
        # Linux's per-argument limit (128KiB) and fail with E2BIG.
        argv = build_argv(model: model, extra_args: extra_args)
        timeout = Duration.seconds(@settings.fetch("timeout", "90m"))
        options = {chdir: cwd, timeout: timeout, stdin: prompt}
        options[:progress] = progress if progress
        result = @command.run(*argv, **options)
        error_kind = classify(result)

        Invocation.new(
          runner: runner_name,
          model: model,
          command_result: result,
          error_kind: error_kind
        )
      end

      def executable
        @settings.fetch("command")
      end

      private

      def classify(result)
        return "timeout" if result.timed_out
        return nil if result.success? && valid_result?(result.stdout)

        text = result.text.downcase
        return "quota" if ["usage limit", "usage limits", "quota", "no weighted tokens left", "no tokens left"].any? { |pattern| text.include?(pattern) }
        return "capacity" if capacity_patterns.any? { |pattern| text.include?(pattern.downcase) }
        return nil if result.success?

        "command"
      end

      def valid_result?(output)
        Result.parse(output)
        true
      rescue Result::ProtocolError
        false
      end

      def capacity_patterns
        Array(@settings.fetch("capacity_patterns", []))
      end
    end
  end
end
