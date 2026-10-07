# frozen_string_literal: true

module Ghwatch
  module Actions
    class Base
      def initialize(project:, config:, state:, github:, roles:, context_builder:, human_channel:, issue_triage:, log: Log.new, machine: nil)
        @project = project
        @config = config
        @state = state
        @github = github
        @roles = roles
        @context_builder = context_builder
        @human_channel = human_channel
        @issue_triage = issue_triage
        @log = log
        @machine = machine
      end

      private

      # Actions decide; the state machine changes the state.
      def machine
        @machine ||= StateMachine.new(github: @github, config: @config, worktrees: @worktrees,
          issue_triage: @issue_triage, log: @log)
      end

      def decide(task, role, result, context = {})
        machine.apply_result(task, role, result, context)
      end

      def retry_failed_role(task, outcome, role)
        task.last_error = "#{outcome.error_kind}: #{outcome.error}"
        decide(task, role, "failed")
        @state.save_task(task)
      end

      def remember_outcome(task, outcome)
        task.attempts += 1
        task.last_model = outcome.signature
        log_outcome(task, outcome)
      end

      # One line per role run, so the log says what each run decided.
      def log_outcome(task, outcome)
        role = outcome.respond_to?(:role) ? outcome.role : "role"
        unless outcome.success?
          @log.info("[#{task.id}] #{role} failed (#{outcome.error_kind})")
          return
        end

        data = outcome.data || {}
        reason = data["reason"].to_s.lines.first.to_s.strip
        @log.info("[#{task.id}] #{role} -> #{data["status"]}#{": #{reason}" unless reason.empty?}")
      end

      # Posts the question; the caller then reports the wait as its result.
      def wait_for_human(task, body, outcome, kind:, target: :issue)
        @human_channel.wait(task: task, body: body, outcome: outcome, kind: kind, target: target)
        @issue_triage&.request!
      end
    end
  end
end
