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

For live agent stdout/stderr and a spinner with elapsed seconds, use `ghwatch -v`
or `ghwatch run --verbose`. The spinner appears only on a terminal; redirected output
contains agent text without animation. Only output emitted by the agent CLI can be
displayed: a CLI that buffers its answer will show a spinner until it emits output.
Normal invocation keeps the concise logs. Verbose display does not change result parsing.
The spinner runs while an agent subprocess is executing. Between cycles, a log reports
the next check time; the scheduler wakes at the earlier of the poll interval and the next
task retry deadline, rather than silently waiting past a retry.

Inspect durable state:

```sh
ghwatch status
```

## Updating

When ghwatch runs from an installed gem, installing a new version (for example
`rake install:user`) is enough: ghwatch notices the new files, waits until they stop
changing, and restarts into the new version with the same arguments at the next point
where no agent runs (between two actions, between cycles, or within a minute while it
waits). A run from a
source checkout does not restart itself.

## Durable state

The task state machine (states, transitions and reactions to outside events) is specified
in [ARCHITECTURE.md](ARCHITECTURE.md).

By default ghwatch reflects each task's state on its source Issue using a single managed
label, for example `ghwatch:implementing`, `ghwatch:changes-requested`,
`ghwatch:waiting-for-review`, `ghwatch:ready-to-merge`, `ghwatch:finalizing`, or `ghwatch:done`.
Human waits use `ghwatch:waiting-for-human-input` and `ghwatch:waiting-for-human-test`.
Other task states use the same names with underscores replaced by hyphens. `done` means
the task completed; the Issue may remain open if more work is needed.

Every open Issue carries one of these labels, so none is left without a reason. Without an
active task it shows the triage assessment (or the task's end, whichever is newer):
`ghwatch:ready` (starts when a worker is free), `ghwatch:blocked`,
`ghwatch:needs-discussion`, `ghwatch:deferred`, `ghwatch:followup`, `ghwatch:skip`, or
`ghwatch:untriaged` when triage has not judged it yet (for example beyond
`project.candidate_limit`). `ghwatch status` shows the reasons.

To give an Issue or PR to someone else, assign it to them (any account other than the one
ghwatch works as) or label it `ghwatch:hands-off`. ghwatch then leaves it alone: triage
skips the Issue, the PR is not reviewed, and a task already working on either stops,
removing its worktrees but leaving the PR and its branch for them to take over. Such an
Issue carries none of ghwatch's status labels. Removing the mark makes the Issue a triage
candidate again; a PR of a stopped task stays out of review.

Open PRs that ghwatch works on carry a label from the same set: `implementing` (draft),
`changes-requested` (the worker is reworking it), `waiting-for-review`, `waiting-for-test-build`,
`ready-to-merge`,
`waiting-for-human-input` and `waiting-for-human-test`. PRs without a source Issue are
labelled too. When the PR merges or closes, or the task moves to another PR, its labels are
removed. Questions ghwatch asks on a PR mention `github.human_mentions`, or the repository
owner when that list is empty and the owner is a person, since nobody else is notified.

A task waiting for a person, or for its merge, goes back to the worker when the PR's
required checks fail (once per PR head), with the failed check names as the reason; the
pending question is dropped, since it is asked again after the rework if still needed.

Labels are synchronized on task saves and each cycle, including existing waiting tasks
after restart. Only the known state labels are replaced; other labels remain intact.
An active task takes precedence over completed tasks for the same Issue. API failures
warn and retry on later synchronization without discarding saved task state.
Set `github.status_labels = false` to disable synchronization; existing labels remain.
The GitHub credential needs permission to create repository labels and edit Issue and PR labels.

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

If a task worktree directory has disappeared (removed by hand, for example), the worker
recreates it from the local task branch, or from the PR head or pushed branch when the
local branch is gone; the finalizer, which edits nothing, runs from the repository root
instead. Removal makes read-only build outputs (such as Go's module cache) writable when
`git worktree remove` stops on them. A review workspace directory that Git no longer
knows about is removed only when its `.git` file still names that workspace's missing
administrative directory; other directories are refused.

While a task waits for a person (`waiting_for_human_input` or `waiting_for_human_test`),
ghwatch frees disk space: it removes the review workspace and runs
`project.human_wait_cleanup` in the task worktree, once per wait. The default,
`git clean -fdX`, deletes only Git-ignored files such as build outputs; commits, tracked
changes and other untracked files remain. Set it to `""` to keep everything, for example
when people test a build from the task worktree, or to another shell command such as
`cargo clean`. Existing waits are released on the next reconciliation. Agents are told
that human test instructions must not depend on files in these workspaces.

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
runner = "codex"
model = "gpt-6-luna"
```

The first worker is preferred. In this example Codex is used only when Claude reports a
capacity/quota condition. Ordinary command failures do not silently fall through.
Claude's weekly and session limit messages are classified as `quota`, so they also
trigger a fallback when `quota` is listed in `fallback_on`.

`test_judge` reads a person's answer to a reviewer's test request (see below). It needs no
build or workspace, so a light model will do; without `[roles.test_judge]` it runs on the
reviewer's models.

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

Agents build, test, push and call `gh`. Codex's own sandbox forbids the network and writes
outside the working directory (where a worktree's Git data lives), so ghwatch runs Codex
without it by default, as the other runners run. `[runners.codex] sandbox` chooses
`read-only`, `workspace-write` or `danger-full-access` instead of `none`.

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

Workers prepare human testing according to the project's own development/test workflow:
complete available autonomous checks, prepare the required test subject, and record evidence
and usable instructions for the tested commit. Their `waiting_for_human_test` result is a
proposal: ghwatch persists its preparation information and sends the task to review first.
The reviewer runs applicable verification itself, returns preparation requiring code changes
to the worker with `changes_requested`, and requests
human testing only when the project requirements are met. Requests include the commit,
verified and remaining checks, access/startup instructions and expected results; no artifact
is required when the request explains why. These are agent instructions, not automatic
validation of builds or evidence. Existing human waits are not migrated.

An answer to the reviewer's test request is not reviewed again: in `checking_test_result`
the test judge reads it and the PR goes to the merge step when everything asked was
confirmed, back to the worker when the problem remains or a maintainer asked for code
changes instead (the check is asked again for the new head), or the person is asked for what
is missing. Only a PR whose changes differ from the tested head goes back to review; merging
the base in ("Update branch") neither does that nor ends a wait for a person.

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
checking_test_result
ready_to_merge
finalizing
done
```

Only implementation/rework states consume `max_workers`. A task that already has a PR and is
waiting for review does not block another issue from starting.

Between actions, at most once a minute, ghwatch looks at its tasks on GitHub again and
looks for new PRs, so a long backlog of agent work does not hide them until the cycle ends.

Each cycle discovers and processes existing PR tasks before triaging issues and running
tasks without a PR. PR rework, review, merging and finalization take precedence over new
issue implementation. Human waits and future retries are still respected, so a blocked PR
does not prevent unrelated issues from progressing. Issue tasks retain their registration
order; PR tasks run in ascending PR number order. Each PR can progress
through rework, review, merge and finalization in the same cycle, with at most six actions.
After each PR, runnable PR tasks are selected again from oldest to newest, including tasks
whose retry time arrived during another PR's execution. Issue triage starts only after
this pass has no remaining runnable PR tasks. PR tasks are checked again after triage,
before issue implementation, to account for retry times reached while triage was running.
Each PR is processed at most once per pass so an unchanged result cannot cause a busy loop.
An unchanged state stops that pass; repeated transitions reach the limit and schedule a
retry. Priority does not bypass review, checks or required human verification.

An open non-draft PR reported as `CONFLICTING` returns to its worker before human testing;
`UNKNOWN` is not treated as a conflict. Actual human-input blockers and failed-action retry
times remain respected. Externally discovered PRs get a reserved `.worktrees/pr-N` workspace
and local `ghwatch/pr-N` branch from their verified GitHub head. The task retains the original
PR head identity; the worker updates that existing head repository/branch without merging
or force-pushing. Existing unrelated workspace paths or branches are refused. Workspace
ownership is persisted so interrupted setup can resume without overwriting local work.

The normal reviewer first decides whether a PR needs the deep reviewer (subtle state or
concurrency, untrusted input or other security-sensitive behavior, performance-critical
paths, architectural changes, hard-to-verify platform behavior) and hands it over before
running long verification; routine changes it reviews itself. Both reviewers evaluate
correctness, security, performance, design and tests, and write the review as what is
good, what is wrong or risky, and concrete improvements, followed by what was checked.
Project-specific review concerns belong in the project's own instructions (AGENTS.md).

Before normal or deep review, ghwatch checks whether the PR head contains the current head
of its base branch. If not, it merges the base into the PR on GitHub (the "Update branch"
API, guarded by the expected head SHA) and reviews the new head on a later pass, so reviews
see what would merge, including newer verification tools on the base branch. A refused
update, such as a conflict or a fork without maintainer edits, is logged and the PR is
reviewed as is; the same head is not updated again. Workers are told to integrate the
remote PR head before committing more. Set `github.update_pr_branches = false` to disable.

A worker hands a PR to review only as it could be merged: when it does, ghwatch checks that
the task worktree has no tracked changes and no commits the PR lacks. Untracked files may
stay. A worker that left something is sent back once with the files and commits named; if
it hands over the same way again, a person is asked on the PR.

The review then runs in the task worktree, so it reuses what the worker built (`target/`
and the like) instead of building everything again. ghwatch first brings that worktree to
the PR head when nothing is lost: it fast-forwards a worktree that is behind (for example
after the branch update above), and moves one whose commits are all in the PR in another
form (a rebase someone pushed). A worktree that is not on its branch, has tracked changes,
or has commits the PR does not, means the work went astray: a person is asked on the PR,
and the review resumes when they reply. Before each worker run the worktree follows the PR
the same way, and is otherwise left for the worker to integrate.

Reviewers must leave the shared worktree as they found it. ghwatch records its branch, HEAD
and untracked files before the review and puts it back afterwards: tracked changes are saved
as a patch and reverted, new untracked files are moved out, and a moved branch or HEAD is
reset. What it finds is recorded on the task (the latest five) and kept under
`.git/ghwatch/review-leftovers/<task>/`; a review ghwatch did not see finish is put back when
ghwatch starts. Ignored files, such as build outputs, stay.

A PR ghwatch only reviews has no task worktree; ghwatch prepares a separate detached worktree
at `.worktrees/review-pr-N` for it, fetching the PR head and checking it matches the snapshot
SHA. An existing owned review workspace is updated to that SHA. Reviewers may build, run tests and use project-provided GUI verification tools
such as Xvfb; they cannot edit source, commit, push or merge. Review feedback must describe
the tested SHA, commands, observations and evidence paths. Human requests are limited to
checks the reviewer cannot perform. Reviewers may start CI or test-build workflows for the
PR commit, so a missing test build does not by itself send the PR back to the worker.

A reviewer that needs a person to run a test build starts it and does not wait for it: it
returns the request with the build's Actions run ids, and the task waits in
`waiting_for_test_build`. A thread of its own looks at those runs, so it is not held up by an
agent running meanwhile. The first look comes after the workflow's usual time (the median of
its last ten successful runs, queueing included; five minutes when there are none), then
every 30 seconds. When the build succeeds, ghwatch posts the reviewer's request with links to
the run and its artifacts. When it fails, or runs three times its usual time (at least 30
minutes), the PR goes back to the reviewer, which reads why. A push in the meantime ends the
wait and the PR is reviewed again.

Every review pass completes the code review, even when pending CI or test preparation
already blocks merge, and reports all blocking problems together. Re-reviews first check
the previously requested changes and the changes since, raising new findings in unchanged
code only for real defects within the issue's scope. Only a defect or regression the PR
introduces or worsens, or an unmet completion condition of the issue, blocks a PR. Problems
the base branch already has, and rare failure paths outside the issue that lose no data in
ordinary use, are filed as separate issues and linked in the review (`file_found_issues`,
default on; an open issue with the same title is linked instead). Triage treats such an issue
as a report, not a maintainer's decision to do it. When rework added a mechanism,
reviewers first ask whether a simpler form would do. After two review rounds in a row on one
theme, ghwatch asks a person to choose a direction instead of sending the PR back a third
time. Human test requests are posted on the source Issue
with its reporter mentioned, PR and test-build links, the tested SHA, artifact/startup
instructions, and steps with expected results. Replies are monitored on that Issue.
PR-only tasks use the PR conversation; existing waits retain their recorded reply channel.

The reviewer chooses how a person checks. When only a judgment of how it looks is left, it
asks them to look at screenshots it took under Xvfb instead of running a test build; when
they have to run it, it asks as above. ghwatch publishes the reviewer's screenshots as one
commit holding only the images, on a new branch named after `github.screenshot_branch_prefix`
(default `ghwatch-assets/`; empty turns this off), and appends them, numbered and linked to
that commit, to both the PR review and the request. A screenshot check whose screenshots
cannot be published is not sent; the review runs again.

Missing development-environment packages use reviewer `waiting_for_human_input` rather
than worker rework or human testing. The PR request lists verified package names, their
purpose, observed errors, a copyable apt installation command and verification steps.
The human provisions the environment and replies on the PR; ghwatch then resumes review
so the reviewer performs the blocked checks itself. ghwatch does not install OS packages.

Separate review workspaces survive retries and CI waits. ghwatch removes them when the task starts
waiting for a person, and after confirming merge or closure, including externally
merged/closed PRs during reconciliation. The next review recreates the workspace.
Unowned directories, attached branches and tracked source changes are refused rather than
overwritten or deleted. Generated build outputs may be removed with the owned workspace;
publish evidence elsewhere if it must remain available after the PR closes. A PR changed
during review is retried against its new head before accepting the review result.

Reviewers must not change tracked files. After every review run in a separate workspace,
and when ghwatch starts, ghwatch checks each such workspace for tracked changes and, when it finds some, records
the time, what had just happened (which role and model ran, or the startup) and the changed
files on the task, keeping the latest five. Nothing is reverted, so the evidence stays;
the review stops as before until a person has looked. `ghwatch status` shows each active
task's last error and latest workspace change.

Agents often start servers, virtual displays and apps that detach into their own
sessions and outlive the agent. ghwatch marks every agent run with a `GHWATCH_RUN_ID`
environment variable, which such descendants inherit, and after the run stops (TERM,
then KILL) every process that still carries the mark. This uses `/proc` and does
nothing on systems without it.

Failures and protocol no-ops get a persisted retry time. A task does not become permanently
silent merely because a subprocess exited without producing the required ghwatch result.
Non-blocking review comments also schedule a retry, and CI/mergeability changes wake pending
reviews. Check changes alone do not invalidate an accepted review in `ready_to_merge`.
In `changes_requested`, a new non-ghwatch PR comment after the latest requested-changes
comment returns the task to review, even during a failed worker's retry delay. This lets
the reviewer consider new instructions or an environment fix. Each reply is consumed
once; confirmed conflicts stay with the worker and actual human-input waits retain their
existing reply channel.

## Triage

Discovery fetches up to 100 open issues and 100 open pull requests, then processes each
list in ascending number order (oldest first). Triage takes the oldest eligible issues
up to `candidate_limit`; previous assessment status does not change that order. The
triage agent still decides which candidates are ready to implement.

The triage role classifies issues as:

- `ready` — autonomous implementation can start now
- `blocked` — a human answer is required now
- `discussion` — a maintainer must first decide whether and how to do it
- `deferred` — intentionally waiting for a future dependency/event
- `followup` — no new implementation now, but human verification or another response is worth watching
- `skip` — not actionable for ghwatch
- `close` — nothing left to do or watch, such as a parent issue whose child issues are all
  completed; ghwatch closes it with a note. It does so only when every issue it mentions is
  closed as completed, or a maintainer wrote the last comment; otherwise it stays `followup`

Triage runs at the end of every poll, once everything that could run has run and what is
left waits for CI or a person, and only while a worker slot is free: issues are looked for
when a worker can take one. New, reopened and newly discussed issues are therefore picked
up on the next idle poll. It runs in up to three stages and skips work it has already done:

1. An issue unchanged since its last assessment is not judged again until
   `triage.reassess_after` (default `1d`) has passed. Unchanged means the same state,
   title, body and comments; ghwatch relabeling an issue does not count, and an issue
   whose `updatedAt` in the issue list is the one last seen is not read at all. An issue
   that is still open after its task finished (reopened, or waiting for verification) is
   judged again. A `deferred` or `followup` issue is also judged again after any PR
   merge or issue close, since that is usually what it waits for. An unchanged
   `ready` issue starts as soon as a worker slot opens. Issues that are ready start oldest
   (lowest number) first; the model decides which are ready, not the order.
2. With `[triage.screening]` enabled, a decision model (TypeSafe Jev, `POST /v1/systemone`)
   judges each changed issue. It is given the issue, its comments (dated, with the ones
   posted since the last assessment marked), the open PRs, and the current state of the
   issues and PRs it mentions as `#N`, so it can tell whether what a `deferred` issue waits
   for is done. Only a confident (`min_confidence`, default 0.8) `deferred`,
   `followup` or `skip` is settled there, and `deferred` only for an issue already
   assessed `deferred`: the model tends to take any open issue an issue mentions as what
   it waits for, so the LLM decides when an issue starts to wait. Issues it would start or comment on, issues with
   a `blocked` or `discussion` conversation under way, and large issues go on. If the API
   key (`TYPESAFE_API_KEY` by default) is missing or the call fails, everything goes on.
   Screening is off by default because the API is paid and needs a key.
3. The triage role (an LLM, with model fallbacks as for any role) judges the rest. It is
   given the same states of what each issue mentions as `#N`.

Triage asks whether an issue should be done before whether it can be. Proposals of
doubtful value or outside the project's goals, requests for behavior that could harm users
or third parties (hidden data collection, weakened security, malware-like behavior), and
large architectural changes become `discussion`, never `ready`, until a maintainer has
decided. ghwatch posts the concern and the decision needed once, labels the issue
`ghwatch:needs-discussion` (one of the status labels), and triages it again when the
discussion changes. Only comments
by the repository's owner, members and collaborators settle a decision: every issue and
comment given to agents says whether its author is one (`authorIsMaintainer`), so a
reporter cannot approve their own request. A maintainer's refusal turns it into `skip`.
Set `project.harmful_issues = "skip"` to ignore harmful requests silently, like a spam
filter, instead of putting them in front of a maintainer (the default, `"discussion"`).

A blocked issue may receive a concise clarification request. ghwatch avoids reposting the same
blocker when the reason and question have not changed.

## Pull requests

When `review_all_open_prs = true`, ghwatch also creates review tasks for open non-draft pull
requests that were not created by one of its own issue tasks. This lets Dependabot or
human-created PRs use the same review pipeline.

A PR written by someone other than the account ghwatch works as is only reviewed: its
branch is its author's. Changes the review or a test asks for are posted for the author and
the PR waits for them to push or comment; conflicts and failed checks are theirs to fix
too, and an answer to a question goes back to the reviewer, never to the worker. A PR
opened by hand from ghwatch's own account is reworked by the worker as usual.

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
are green and GitHub reports the PR mergeable. It looks at them again every
`checks_poll_interval` (default `10m`); set it to about how often your CI may finish. A code/review-discussion change invalidates the
previous review and sends the PR back through review.

## Default project configuration

Run `ghwatch init` to get the exact current defaults. The main knobs are:

```toml
[project]
poll_interval = "10m"
retry_after = "10m"
max_workers = 2
candidate_limit = 20
worktree_root = ".worktrees"
human_wait_cleanup = "git clean -fdX"
branch_prefix = "ghwatch/issue-"
review_all_open_prs = true

[github]
auto_merge = true
merge_method = "merge"
update_pr_branches = true
human_language = "auto"
close_issue_after_merge = true
screenshot_branch_prefix = "ghwatch-assets/"
require_green_checks = true
checks_poll_interval = "10m"
file_found_issues = true
```

`human_language` controls human-facing GitHub text for every role, including PR titles
and descriptions, review comments, questions, and test requests. Set it explicitly to
`"ja"`, `"en"`, or a language name such as `"Japanese"` in `[github]`.

The default, `"auto"` (also used when omitted), infers the language from the ghwatch
process environment in this order: `LC_ALL`, `LANGUAGE`, `LC_MESSAGES`, `LANG`.
Empty or unrecognized values are skipped; colon-separated preferences use the first
recognized locale. For example, `ja_JP.UTF-8` becomes `ja-JP`. `C` / `POSIX` locales
and environments without a recognizable locale use English (`en`). Explicit configuration
takes precedence over the environment and the language of the existing discussion.
Protocol keys and status values remain unchanged.

## Development

```sh
bundle exec rake
bundle exec standardrb
```

The code intentionally favors small concern-specific Ruby classes and explicit English-like
method names over metaprogramming.
