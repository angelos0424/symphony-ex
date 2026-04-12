# SymphonyEx

Elixir/OTP porting workspace for Symphony, with **Codex app-server** as the coding-agent runtime and **GitHub Issues + GitHub Project** as the intended tracking/orchestration direction.

## Status

- This Mix project is still an early prototype.
- Some current modules/config still reference **Linear** from the initial scaffold/prototype work.
- The planning direction has changed: future tracker/orchestrator work should target **GitHub Issues + GitHub Project**, not Linear.
- This repo now has **GitHub-shaped config loading**, a minimal **GitHub client/adapter** path for issue/project candidate selection, lifecycle-driven issue/project state sync, and bounded orchestrator scheduling with conflict-aware parallelism.

## Primary planning document

- `../CONVERSION_PLAN.md` — current TypeScript → Elixir conversion plan

## Example WORKFLOW.md front matter

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
        issue-state: closed
        project-status: Done
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
---
```

`tracker.lifecycle` is user-facing config for mapping orchestrator run states to GitHub issue/project lifecycle updates. After `SymphonyEx.Config.load!/1`, it is normalized into a `%SymphonyEx.Orchestrator.Lifecycle{}` runtime struct so tracker/orchestrator code can use it directly.

Environment variables override workflow values where present:

```bash
export GITHUB_TOKEN=ghp_xxx
export GITHUB_OWNER=example-org
export GITHUB_REPO=example-repo
export GITHUB_PROJECT_NUMBER=7
export WORKSPACE_ROOT=$HOME/Project/worktrees
export SOURCE_REPO_PATH=$HOME/Project/source-repo
export SYMPHONY_LOG_FORMAT=json
export SYMPHONY_LOG_LEVEL=info
export SYMPHONY_LOG_METADATA=issue_identifier,thread_id,turn_id,outcome_kind,gating_reason,class,conflict_keys
export SYMPHONY_LOG_REDACT_KEYS=api_key,authorization,token
export SYMPHONY_LOG_MAX_METADATA_VALUE_LENGTH=512
```

Legacy prototype support still exists for Linear env vars:

```bash
export LINEAR_API_KEY=lin_xxx
export TEAM_KEY=SYM
```

## Runtime bootstrap

The OTP app can now auto-bootstrap the orchestrator from a workflow file at startup.

```bash
export SYMPHONY_WORKFLOW_PATH=/path/to/WORKFLOW.md
export GITHUB_TOKEN=ghp_xxx
export GITHUB_OWNER=example-org
export GITHUB_REPO=example-repo
export GITHUB_PROJECT_NUMBER=7
export WORKSPACE_ROOT=$HOME/Project/worktrees
export SOURCE_REPO_PATH=$HOME/Project/source-repo

mix run --no-halt
```

`SOURCE_REPO_PATH` must be a real writable Git clone, not just an empty directory. The runtime uses
`git worktree add/remove`, so Git metadata is written both under `WORKSPACE_ROOT` and under the
source repo's `.git/worktrees` area.

At startup, `SymphonyEx.Application` calls `SymphonyEx.ensure_runtime_configured/0`, which loads the workflow/env config, converts it into orchestrator options, and stores both orchestrator + workflow-store startup config in application env for supervised children.

When `SYMPHONY_WORKFLOW_PATH` is set, the app also starts `SymphonyEx.WorkflowStore`, watches that file for changes, and hot-reloads the validated config/template in place. The orchestrator re-reads runtime scheduling/tracker settings on each tick, and `AgentRunner` uses the latest in-memory template body when building prompts.

If you want to bootstrap explicitly in code instead, use:

```elixir
SymphonyEx.configure_from_workflow!("/path/to/WORKFLOW.md")
```

## Development

```bash
mix deps.get
mix format
mix test
```

## Optional dashboard

The Phoenix/Bandit endpoint now includes a foundational LiveView dashboard at `/`
plus the JSON runtime API under `/api/v1/*`.

If you enable the dashboard, you must also provide `dashboard.secret_key_base`
(or `SYMPHONY_DASHBOARD_SECRET_KEY_BASE` via env). Startup now rejects an enabled
dashboard without that secret instead of failing later inside Phoenix.

The current dashboard slice is intentionally bounded around runtime visibility:

- summary cards for running / retry / completed / open slots
- operator controls for queue focus, free-text filtering, concurrency-class / outcome filters, shared retry/completed status + error-category filters, separate active/completed sorting, plus bounded completion-history window / row controls
- running issue list with class/workspace/conflict context plus live elapsed runtime
- retry queue list with countdown, scheduled retry time, backoff, and last failure details
- recent completed run history with runtime + session/thread/outcome drill-down metadata
- split-view run inspector plus an optional full-page `/runs/:identifier` detail route for deeper inspection
- bounded NDJSON breadcrumb tail preview in lists plus a fuller per-run event timeline
- orchestrator settings snapshot

It is driven from `SymphonyEx.RuntimeSnapshot` so the HTML and JSON views share
one normalized runtime payload shape.

## Notes

- Keep **Codex** as the agent execution backend.
- Do not overbuild GitHub tracker automation too early; start with a minimal issue-run flow, then add Project-based selection/state sync incrementally.
- The next major implementation focus is continued hardening of the **GitHub-backed runtime/orchestrator path**, not more Linear expansion.
- Current orchestrator parallel-dispatch assumptions:
  - bounded parallelism is enforced via concurrency classes
  - issues can declare serialization/conflict boundaries through labels with prefixes like `scope:`, `service:`, `path:`, `package:`, `release:`
  - the same conflict keys can also be declared in GitHub Issue bodies with simple hints such as `Service: api`, `Paths: lib/symphony_ex/orchestrator.ex, README.md`, `Release: 2026.03`
  - when no explicit conflict key exists, the orchestrator falls back to class-level conflict scope by default
  - tracker write-back is deduplicated per issue/payload so repeated identical state transitions do not re-write the same run record
  - GitHub lifecycle automation is idempotent: if issue state / project status / labels / assignees already match the desired lifecycle state, the adapter skips the redundant API write
  - assignee automation defaults to merge mode so Symphony can add runtime assignees without clobbering existing humans; `write_back: [assignee_mode: :replace]` opts into replacement
  - candidate ordering includes a bounded starvation bonus for repeatedly deferred eligible issues so low-priority work is not perpetually skipped behind hotter lanes
