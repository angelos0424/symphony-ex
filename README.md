# SymphonyEx

Elixir/OTP port of Symphony oriented around **Codex app-server** and a **GitHub Issue + GitHub Project** operating model.

## Current operating model

- GitHub is the primary operating surface.
- GitHub Issue is the execution unit.
- GitHub Project provides queue state and lifecycle fields.
- The dashboard is an observer for runtime visibility, not the source of truth.
- Each project runs exactly one active orchestrator process.
- The initial product target is **strict-gated limited autonomy**, not full autonomy.

## Status

The current repo already includes the main GitHub runtime path:

- `SymphonyEx.GitHub.Client` for issue/project reads and write-back
- `SymphonyEx.GitHub.Adapter` for tracker behavior integration
- `SymphonyEx.Orchestrator` for bounded scheduling, retry, and conflict-aware dispatch
- `SymphonyEx.Workspace` for source-repo bootstrap and `git worktree` isolation
- `SymphonyEx.AgentRunner` for Codex app-server turn execution
- `SymphonyEx.SessionStore` for workspace session persistence and recovery
- Phoenix/Bandit dashboard + JSON API for observer-only runtime inspection

The current wedge is:

`Todo issue 1개 자동 픽업 -> worktree 준비 -> Codex app-server 실행 -> GitHub write-back -> Project 상태 반영`

By default, a successful unattended run moves the issue to `In Review` and
keeps the GitHub issue open. Human review is what moves work to `Done`.

## Primary plan

- [`../CONVERSION_PLAN.md`](../CONVERSION_PLAN.md) — current state, operating decisions, and next engineering gaps

## Example `WORKFLOW.md` front matter

```yaml
---
tracker:
  kind: github
  owner: openai
  repo: symphony
  project-number: 7
  active-states:
    - Todo
    - In Progress
  terminal-states:
    - Done
  lifecycle:
    claimed:
      issue-state: open
      project-status: In Progress
    running:
      issue-state: open
      project-status: In Progress
    retry-queued:
      issue-state: open
      project-status: Todo
    released:
      success:
        issue-state: open
        project-status: In Review
      failed:
        issue-state: open
        project-status: Todo
      cancelled:
        issue-state: open
        project-status: Todo
workspace:
  root: /tmp/symphony-worktrees
  source-repo-path: /path/to/source-repo
codex:
  command: codex app-server
logging:
  format: json
  level: info
  metadata:
    - issue_identifier
    - thread_id
    - turn_id
    - outcome_kind
    - gating_reason
    - class
    - conflict_keys
  redact_keys:
    - api_key
    - authorization
    - token
  max_metadata_value_length: 512
dashboard:
  enabled: true
  secret-key-base: replace-with-a-long-random-secret
---
```

`tracker.lifecycle` is normalized into `%SymphonyEx.Orchestrator.Lifecycle{}` at runtime so tracker and orchestrator code can use one stable struct.

## Environment variables

```bash
export GITHUB_TOKEN=ghp_xxx
export GITHUB_OWNER=example-org
export GITHUB_REPO=example-repo
export GITHUB_PROJECT_NUMBER=7
export WORKSPACE_ROOT=$HOME/Project/worktrees
export SOURCE_REPO_URL=git@github.com:example-org/example-repo.git
export SOURCE_CACHE_ROOT=$HOME/Project/source-cache
export SYMPHONY_LOG_FORMAT=json
export SYMPHONY_LOG_LEVEL=info
export SYMPHONY_LOG_METADATA=issue_identifier,thread_id,turn_id,outcome_kind,gating_reason,class,conflict_keys
export SYMPHONY_LOG_REDACT_KEYS=api_key,authorization,token
export SYMPHONY_LOG_MAX_METADATA_VALUE_LENGTH=512
```

## Runtime bootstrap

The OTP app can bootstrap itself from a workflow file:

```bash
export SYMPHONY_WORKFLOW_PATH=/path/to/WORKFLOW.md
export GITHUB_TOKEN=ghp_xxx
export GITHUB_OWNER=example-org
export GITHUB_REPO=example-repo
export GITHUB_PROJECT_NUMBER=7
export WORKSPACE_ROOT=$HOME/Project/worktrees
export SOURCE_REPO_URL=git@github.com:example-org/example-repo.git

mix run --no-halt
```

For local runs in this repository, you can also use:

```bash
./bin/run-no-halt.sh
```

That script loads `.env` when present, defaults `SYMPHONY_WORKFLOW_PATH` to
the repository's `WORKFLOW.md`, and executes `mise exec -- mix run --no-halt`.

Runtime precedence for the source repo is:

1. `SOURCE_REPO_PATH`
2. auto-bootstrap from `SOURCE_REPO_URL`
3. startup error if neither is provided

When `SYMPHONY_WORKFLOW_PATH` is set, `SymphonyEx.Application` loads the workflow/env config, stores orchestrator and workflow-store startup options in application env, and starts the supervised runtime.

## Dashboard

The Phoenix/Bandit endpoint exposes:

- LiveView dashboard at `/`
- JSON runtime API under `/api/v1/*`

The dashboard is intentionally bounded:

- summary cards for running, retry queued, completed, success rate, open slots, and GitHub rate limit
- queue filtering and run inspection
- retry/completion history with breadcrumb previews
- orchestrator settings snapshot

If enabled, `dashboard.secret_key_base` or `SYMPHONY_DASHBOARD_SECRET_KEY_BASE` is required at startup.

## Development

```bash
mix deps.get
mix format
mix test
```

## Notes

- Keep **Codex app-server** as the execution backend.
- Keep **GitHub** as the operational truth surface.
- Keep the dashboard as an observer, not a second control plane.
- Keep orchestration scoped to **single active orchestrator per project**.
- Prefer strict gating and explicit GitHub write-back over aggressive autonomous dispatch.
