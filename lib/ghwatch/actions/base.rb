# frozen_string_literal: true

module Ghwatch
  module Actions
    class Base
      def initialize(project:, config:, state:, github:, roles:, context_builder:, human_channel:, issue_triage:, log: Log.new)
        @project = project
        @config = config
        @state = state
        @github = github
        @roles = roles
        @context_builder = context_builder
        @human_channel = human_channel
        @issue_triage = issue_triage
        @log = log
      end

      private

      def retry_failed_role(task, outcome)
        task.last_error = "#{outcome.error_kind}: #{outcome.error}"
        task.schedule_retry(after: @config.retry_after)
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

      def wait_for_human(task, body, outcome, kind:, resume_state:, target: :issue)
        @human_channel.wait(
          task: task,
          body: body,
          outcome: outcome,
          kind: kind,
          resume_state: resume_state,
          target: target
        )
        @issue_triage.request!
      end
    end
  end
end
