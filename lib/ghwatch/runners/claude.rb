# frozen_string_literal: true

module Ghwatch
  module Runners
    class Claude < Base
      private

      def runner_name
        "claude"
      end

      def build_argv(model:, extra_args:)
        [executable, "--model", model, "--permission-mode", "auto", *extra_args, "-p"]
      end
    end
  end
end
