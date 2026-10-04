# frozen_string_literal: true

module Ghwatch
  class RoleRunner
    Outcome = Data.define(:success, :role, :runner, :model, :data, :error_kind, :error, :raw_output) do
      def success?
        success
      end

      def signature
        [runner, model, role].compact.join(" / ")
      end
    end

    RUNNER_CLASSES = {
      "claude" => Runners::Claude,
      "codex" => Runners::Codex,
      "opencode" => Runners::OpenCode
    }.freeze

    def initialize(config:, command:, prompt_store:, log: Log.new)
      @config = config
      @command = command
      @prompt_store = prompt_store
      @log = log
    end

    def run(role, context:, cwd:, task: nil)
      role_config = @config.role(role)
      prompt = @prompt_store.compose(role, context: context)
      last_outcome = nil

      role_config.models.each_with_index do |target, index|
        runner = build_runner(target.runner)
        task_details = if task
          " [#{task.id}] Issue #{task.issue_number ? "##{task.issue_number}" : "none"}, " \
            "PR #{task.pr_number ? "##{task.pr_number}" : "none"}; state=#{task.state}"
        end
        @log.info("[#{role}] starting #{target.runner}:#{target.model}#{task_details}")
        invocation = runner.run(
          model: target.model,
          prompt: prompt,
          cwd: cwd,
          extra_args: target.args
        )

        if invocation.success?
          begin
            data = Result.parse(invocation.output)
            return Outcome.new(
              success: true,
              role: role.to_s,
              runner: target.runner,
              model: target.model,
              data: data,
              error_kind: nil,
              error: nil,
              raw_output: invocation.output
            )
          rescue Result::ProtocolError => e
            last_outcome = failure(role, target, "protocol", e.message, invocation.output)
          end
        else
          last_outcome = failure(
            role,
            target,
            invocation.error_kind,
            invocation.diagnostics.strip,
            invocation.output
          )
        end

        next_target_exists = index < role_config.models.length - 1
        can_fallback = target.fallback_on.include?(last_outcome.error_kind)
        break unless next_target_exists && can_fallback

        @log.warn("[#{role}] #{target.runner}:#{target.model} failed with #{last_outcome.error_kind}; trying fallback")
      end

      last_outcome || Outcome.new(
        success: false,
        role: role.to_s,
        runner: nil,
        model: nil,
        data: nil,
        error_kind: "configuration",
        error: "no model target configured",
        raw_output: ""
      )
    end

    private

    def build_runner(name)
      klass = RUNNER_CLASSES.fetch(name) { raise Config::Error, "unsupported runner: #{name}" }
      klass.new(settings: @config.runner(name), command: @command, log: @log)
    end

    def failure(role, target, kind, message, output)
      @log.warn("[#{role}] #{target.runner}:#{target.model} failed: #{kind} #{message}")
      Outcome.new(
        success: false,
        role: role.to_s,
        runner: target.runner,
        model: target.model,
        data: nil,
        error_kind: kind,
        error: message,
        raw_output: output
      )
    end
  end
end
