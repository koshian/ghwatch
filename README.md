# ghwatch

`ghwatch` is a project-local orchestrator for GitHub issues, pull requests, coding agents,
review agents, and asynchronous human feedback.

It runs as one durable foreground state machine. GitHub is the shared conversation surface:
implementation questions and worker test requests are posted to issues, human replies
wake the task again, and pull-request discussion drives review and rework.

The agent CLIs and models used for each role are configured per project. Built-in prompts can
also be overridden per project while the machine-readable ghwatch result protocol remains
stable.

> Status: early implementation. The core architecture, durable state, runner adapters,
> prompt overrides, issue triage, worker/reviewer/finalizer state transitions, human-response
> wakeups, worktree lifecycle, and CLI are implemented. Treat it as alpha until it has been
> exercised against several real repositories and agent CLI versions.

## Requirements

- Ruby 3.2+
- Git
- GitHub CLI (`gh`) authenticated for the repository
- at least the agent CLI(s) selected in `.ghwatch/config.toml`

The default configuration uses Claude, Codex, and OpenCode, but none is hard-coded to a role.
You can configure any supported runner/model combination.

## Install

Build and install the gem from a checkout. `--user-install` installs into your RubyGems user
directory, so it works with a distribution Ruby (e.g. Debian's `ruby` package) without root:

```sh
gem build ghwatch.gemspec
gem install --user-install ./ghwatch-*.gem
ghwatch --help
```

The same thing via Rake (builds into `pkg/`):

```sh
rake install:user    # gem install --user-install (no bundle install needed)
rake install:local   # gem install into the default GEM_HOME
```

The installed gem does not need Bundler or the source checkout.

### Putting `ghwatch` on your PATH

With `--user-install`, RubyGems puts the `ghwatch` executable in the `bin` directory of its
user gem directory, which is usually *not* `~/.local/bin`. On Debian with Ruby 3.3 it is
`~/.local/share/gem/ruby/3.3.0/bin`. Ask RubyGems where it is:

```sh
ruby -r rubygems -e 'puts Gem.user_dir'
```

and add its `bin` subdirectory to your PATH, e.g. in `~/.profile` or `~/.bashrc`:

```sh
export PATH="$(ruby -r rubygems -e 'puts Gem.user_dir')/bin:$PATH"
```

### Native extensions

The `sqlite3` dependency ships precompiled binaries for common platforms, and on Ruby 3.3
the `racc` gem needed by `toml-rb` is already bundled with Ruby, so a normal install does
not compile anything. If RubyGems does need to build a native extension (unusual platform,
or an isolated `GEM_HOME` that hides the bundled gems), install a compiler and the Ruby
headers first, e.g. `sudo apt install build-essential ruby-dev` on Debian.

### From a checkout (development)

```sh
bundle config set --local path vendor/bundle
bundle install
bundle exec ruby bin/ghwatch --help
```

Setting `path` keeps the bundle inside the checkout. Without it, Bundler tries to install into
the system gem directory, which is not writable without root on a distribution Ruby.

## Start a project

From a Git repository:

```sh
ghwatch init
```

This creates:

```text
.ghwatch/
└── config.toml
```

The configuration is intended to be committed with the project.

Then verify the local tools:

```sh
ghwatch doctor
```

Run ghwatch in the foreground:

```sh
ghwatch
```

or explicitly:

```sh
ghwatch run
```

Inspect durable state:

```sh
ghwatch status
```

## Durable state

Runtime state is not stored under `.ghwatch/`. It lives inside the repository's Git directory:

```text
.git/ghwatch/state.sqlite3
```

That means:

- `.ghwatch/` is project configuration and may be committed.
- `.git/ghwatch/` is machine-local runtime state.
- stopping `ghwatch`, logging out, or rebooting does not lose task state.
- worktrees can be resumed after a restart.

State is written through SQLite at each meaningful transition rather than only when the main
loop exits.

## Worktrees

By default implementation tasks use:

```text
.worktrees/issue-123
```

and branches such as:

```text
ghwatch/issue-123
```

The worktree survives repeated agent invocations. After finalization, ghwatch removes the
worktree, prunes Git worktree metadata, and removes the local task branch.

## Roles and models

Everything is configured per project in `.ghwatch/config.toml`.

Example:

```toml
[roles.worker]
prompt = "worker.md"

[[roles.worker.models]]
runner = "claude"
model = "sonnet"
fallback_on = ["capacity", "quota"]

[[roles.worker.models]]
runner = "codex"
model = "gpt-5.6-luna"

[roles.reviewer]
prompt = "reviewer.md"

[[roles.reviewer.models]]
runner = "opencode"
model = "openai/gpt-6-luna"
```

The first worker is preferred. In this example Codex is used only when Claude reports a
capacity/quota condition. Ordinary command failures do not silently fall through.

The built-in runners currently are:

- `claude`
- `codex`
- `opencode`

Runner executable paths and timeouts can also be overridden:

```toml
[runners.claude]
command = "claude"
timeout = "90m"
```

## Prompt overrides

Built-in prompts ship inside the gem. A project only needs to store prompts that it wants to
customize, so upgrading ghwatch can improve the defaults without freezing every repository on
an old copied prompt.

List roles:

```sh
ghwatch prompt list
```

Copy one prompt into the project:

```sh
ghwatch prompt eject worker
```

This creates:

```text
.ghwatch/prompts/worker.md
```

From then on that file overrides the built-in worker prompt.

To start with all prompts editable:

```sh
ghwatch init --with-prompts
```

The machine-readable result contract is appended by ghwatch after the project prompt. A local
prompt can change policy and style without accidentally removing the protocol that the state
machine needs.

Prompt files are read for every invocation, so edits take effect immediately. `config.toml` is
also reloaded when its modification time changes; model assignments, timeouts, and most policy
knobs can therefore be tuned while ghwatch is running. Invalid edited TOML is reported and the
last valid configuration remains active.

## Humans are asynchronous participants

When an agent cannot safely proceed, it does not wait for terminal input. It returns a
structured `waiting_for_human_input` result. ghwatch posts the question to the related issue
with a hidden durable marker.

The flow is:

```text
agent
  -> waiting_for_human_input
  -> ghwatch posts an Issue comment
  -> human replies on the Issue
  -> ghwatch detects a later non-ghwatch comment
  -> the durable task resumes
```

Real-person verification uses the separate `waiting_for_human_test` state.

This keeps product decisions, reproduction details, and test reports next to the GitHub work
that motivated them.

## State model

The important task states are:

```text
implementing
changes_requested
continuing
waiting_for_review
waiting_for_re_review
waiting_for_human_input
waiting_for_human_test
ready_to_merge
finalizing
done
```

Only implementation/rework states consume `max_workers`. A task that already has a PR and is
waiting for review does not block another issue from starting.

Failures and protocol no-ops get a persisted retry time. A task does not become permanently
silent merely because a subprocess exited without producing the required ghwatch result.

## Triage

The triage role classifies issues as:

- `ready` — autonomous implementation can start now
- `blocked` — a human answer is required now
- `deferred` — intentionally waiting for a future dependency/event
- `followup` — no new implementation now, but human verification or another response is worth watching
- `skip` — not actionable for ghwatch

A blocked issue may receive a concise clarification request. ghwatch avoids reposting the same
blocker when the reason and question have not changed.

## Pull requests

When `review_all_open_prs = true`, ghwatch also creates review tasks for open non-draft pull
requests that were not created by one of its own issue tasks. This lets Dependabot or
human-created PRs use the same review pipeline.

Review agents are instructed to be read-only. ghwatch, rather than the reviewer process,
performs comments and merges from the structured review result.

The originating issue number and PR number are separate task identities. Worker-reported
PR numbers are fetched as pull requests and checked against the task branch before being
attached. Otherwise ghwatch discovers the PR by its head branch. An issue's existence never
substitutes for a PR. Without a PR, review and finalization wait and issue tasks return to
the existing worker retry flow; finalization requires a merged PR. Workers never merge.

Reviewer test requests are posted to the PR, and replies are watched on that same PR.
Worker and finalizer questions remain on the related issue. Existing pending issue requests
continue watching their original conversation after an upgrade.

When `require_green_checks = true`, an accepted PR waits in `ready_to_merge` until GitHub checks
are green and GitHub reports the PR mergeable. A code/review-discussion change invalidates the
previous review and sends the PR back through review.

## Default project configuration

Run `ghwatch init` to get the exact current defaults. The main knobs are:

```toml
[project]
poll_interval = "10m"
discovery_interval = "2h"
retry_after = "10m"
max_workers = 2
candidate_limit = 20
worktree_root = ".worktrees"
branch_prefix = "ghwatch/issue-"
review_all_open_prs = true

[github]
auto_merge = true
merge_method = "squash"
human_language = "auto"
close_issue_after_merge = true
require_green_checks = true
```

`human_language = "auto"` tells prompts to follow the language already used by the issue or
project.

## Development

```sh
bundle exec rake
bundle exec standardrb
```

The code intentionally favors small concern-specific Ruby classes and explicit English-like
method names over metaprogramming.
