# frozen_string_literal: true

module Ghwatch
  module Runners
    class Codex < Base
      private

      def runner_name
        "codex"
      end

      def build_argv(model:, prompt:, extra_args:)
        [executable, "exec", "--model", model, *extra_args, prompt]
      end
    end
  end
end
