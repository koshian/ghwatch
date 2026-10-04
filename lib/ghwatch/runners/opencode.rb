# frozen_string_literal: true

module Ghwatch
  module Runners
    class OpenCode < Base
      private

      def runner_name
        "opencode"
      end

      def build_argv(model:, extra_args:)
        [executable, "run", "--standalone", "--model", model, *extra_args]
      end
    end
  end
end
