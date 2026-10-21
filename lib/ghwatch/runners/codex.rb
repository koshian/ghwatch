# frozen_string_literal: true

module Ghwatch
  module Runners
    class Codex < Base
      private

      def runner_name
        "codex"
      end

      # Agents build, test, push and call gh, which Codex's default sandbox
      # forbids (no network, no writes outside the working directory, where a
      # worktree's Git data lives). "none" runs them as the other runners do.
      SANDBOXES = %w[none read-only workspace-write danger-full-access].freeze

      def build_argv(model:, extra_args:)
        sandbox = @settings.fetch("sandbox", "none")
        sandbox_args = (sandbox == "none") ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--sandbox", sandbox]
        [executable, "exec", "--model", model, *sandbox_args, "--color", "never", *extra_args, "-"]
      end
    end
  end
end
