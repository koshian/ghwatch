# frozen_string_literal: true

require "fileutils"
require "thor"

module Ghwatch
  class PromptCLI < Thor
    def self.exit_on_failure?
      true
    end

    desc "list", "List configurable role prompts"
    def list
      project, config = load_project_and_config
      PromptStore.new(project: project, config: config).available_roles.each { |role| puts role }
    end

    desc "eject ROLE", "Copy a built-in role prompt to .ghwatch/prompts for local editing"
    option :force, type: :boolean, default: false
    def eject(role)
      project, config = load_project_and_config
      path = PromptStore.new(project: project, config: config).eject(role, force: options[:force])
      puts "Created #{path.relative_path_from(project.root)}"
    end

    private

    def load_project_and_config
      project = Project.discover
      [project, Config.load(project.config_path)]
    rescue Project::NotARepository, Config::Error => e
      raise Thor::Error, e.message
    end
  end

  class CLI < Thor
    # "run" is a Thor reserved word, so the command is implemented as
    # run_foreground and exposed to users as "ghwatch run".
    map "run" => :run_foreground
    default_command :run_foreground

    def self.exit_on_failure?
      true
    end

    desc "init", "Create .ghwatch/config.toml in the current Git repository"
    option :force, type: :boolean, default: false
    option :with_prompts, type: :boolean, default: false, desc: "Also copy built-in prompts for local editing"
    def init
      project = Project.discover
      FileUtils.mkdir_p(project.config_dir)

      if File.exist?(project.config_path) && !options[:force]
        raise Thor::Error, "#{project.config_path} already exists (use --force to replace it)"
      end

      source = File.expand_path("default_config.toml", __dir__)
      FileUtils.cp(source, project.config_path)
      puts "Created #{project.config_path.relative_path_from(project.root)}"

      return unless options[:with_prompts]

      config = Config.load(project.config_path)
      prompts = PromptStore.new(project: project, config: config)
      prompts.available_roles.each do |role|
        path = prompts.eject(role, force: options[:force])
        puts "Created #{path.relative_path_from(project.root)}"
      end
    rescue Project::NotARepository, Config::Error => e
      raise Thor::Error, e.message
    end

    desc "run", "Run ghwatch in the foreground"
    option :verbose, aliases: "-v", type: :boolean, default: false, desc: "Show agent output and a terminal spinner"
    def run_foreground
      components = build_components
      components.fetch(:scheduler).run
    rescue Interrupt
      warn "ghwatch interrupted"
      exit 130
    rescue Project::NotARepository, Config::Error => e
      raise Thor::Error, e.message
    end

    desc "status", "Show durable task and issue state"
    def status
      project = Project.discover
      project.ensure_runtime_dirs
      StateStore.new(project.state_path).then { |state| Status.new(state: state).print }
    rescue Project::NotARepository => e
      raise Thor::Error, e.message
    end

    desc "doctor", "Check GitHub authentication, configuration, and configured agent CLIs"
    def doctor
      project = Project.discover
      config = Config.load(project.config_path)
      command = Command.new
      github = Github.new(project: project, command: command)
      checks = Doctor.new(project: project, config: config, command: command, github: github).checks

      checks.each do |check|
        puts "#{check.ok ? "✓" : "✗"} #{check.name}: #{check.detail}"
      end

      exit(1) unless checks.all?(&:ok)
    rescue Project::NotARepository, Config::Error => e
      raise Thor::Error, e.message
    end

    desc "prompt SUBCOMMAND ...ARGS", "Manage project-local prompt overrides"
    subcommand "prompt", PromptCLI

    private

    def build_components
      project = Project.discover
      project.ensure_runtime_dirs
      config = Config.load(project.config_path)
      log = Log.new
      command = Command.new(log: log)
      github = Github.new(project: project, command: command, log: log)
      state = StateStore.new(project.state_path)
      status_labels = StatusLabels.new(state: state, github: github, config: config, log: log)
      state.status_labels = status_labels
      prompts = PromptStore.new(project: project, config: config)
      roles = RoleRunner.new(config: config, command: command, prompt_store: prompts, log: log, verbose: options[:verbose])
      worktrees = WorktreeManager.new(project: project, config: config, github: github, command: command, log: log)
      context_builder = ContextBuilder.new(config: config)
      human_channel = HumanChannel.new(github: github, config: config)
      issue_triage = IssueTriage.new(
        project: project,
        config: config,
        state: state,
        github: github,
        roles: roles,
        worktrees: worktrees,
        context_builder: context_builder,
        log: log
      )
      review_intake = ReviewIntake.new(config: config, state: state, github: github, log: log)

      shared_action_dependencies = {
        project: project,
        config: config,
        state: state,
        github: github,
        roles: roles,
        context_builder: context_builder,
        human_channel: human_channel,
        issue_triage: issue_triage,
        log: log
      }
      worker_action = Actions::Worker.new(worktrees: worktrees, command: command, **shared_action_dependencies)
      reviewer_action = Actions::Reviewer.new(worktrees: worktrees, **shared_action_dependencies)
      finalizer_action = Actions::Finalizer.new(worktrees: worktrees, **shared_action_dependencies)
      task_engine = TaskEngine.new(
        state: state,
        github: github,
        human_channel: human_channel,
        worker_action: worker_action,
        reviewer_action: reviewer_action,
        finalizer_action: finalizer_action,
        worktrees: worktrees,
        config: config,
        log: log
      )
      scheduler = Scheduler.new(
        task_engine: task_engine,
        review_intake: review_intake,
        issue_triage: issue_triage,
        config: config,
        github: github,
        status_labels: status_labels,
        log: log
      )

      {scheduler: scheduler}
    end
  end
end
