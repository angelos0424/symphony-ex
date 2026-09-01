# SymphonyEx Issue Trust Model

## Purpose

A GitHub Project `Todo` item is a scheduling signal, not by itself permission to give an Issue body to Codex. Before worktree creation or agent execution, SymphonyEx can require a trusted author signal.

## Policy

The shipped `WORKFLOW.md` files enable:

```yaml
automation:
  issue-trust:
    require-trusted-author: true
    allowed-associations:
      - OWNER
      - MEMBER
      - COLLABORATOR
    allowed-actors: []
```

When the policy is enabled, an Issue is accepted when either:

- its GitHub `author_association` is one of the configured allowed values; or
- its GitHub author login is in `allowed-actors`.

The policy rejects an Issue when both trust fields are missing, or when the available author signal is not allowed. The same check applies to normal Project polling and explicit `issue_identifier` execution.

## Why labels are not sufficient

An Issue label does not prove who assigned it. A label may be applied by an untrusted actor, a bot, an import, or a repository automation rule. Labels can still be useful as routing metadata, but they are not an independent author-trust signal in this policy.

## Runtime behavior

A rejected Issue:

1. is not claimed;
2. does not create a worktree;
3. does not start Codex;
4. is recorded with a visible gating reason such as `untrusted_issue_author` or `missing_issue_author_trust`.

Trust metadata is normalized into the tracker-agnostic Issue struct as `author_login` and `author_association`. The values are used for policy decisions and diagnostics; secrets are never part of the trust metadata.

## Configuration and migration

- The library default leaves the policy disabled for existing embedded/test callers that do not yet provide GitHub author metadata.
- The repository and Docker workflow templates enable the fail-closed policy explicitly.
- Operators using a custom workflow must add the `automation.issue-trust` block before enabling unattended execution.
- Missing metadata is not treated as trusted when `require-trusted-author: true`.
- If an organization uses a trusted bot or service account, add its lowercase login to `allowed-actors` and keep the association allowlist narrow.

## Verification checklist

Before unattended operation, run a dry run and verify:

- a trusted owner/member/collaborator Issue is eligible;
- a `CONTRIBUTOR` or `NONE` Issue is blocked;
- an Issue with missing author metadata is blocked;
- explicit Issue execution cannot bypass the policy;
- the gating reason is visible without exposing tokens or private auth files.

## Credential boundary

`GITHUB_TRACKER_TOKEN` is kept in the orchestrator/tracker process for GitHub
Issue and Project reads plus lifecycle write-back. `GITHUB_AGENT_TOKEN` is a
repo-scoped credential passed to Codex for clone, push, and pull-request work.
The Codex Port receives an explicit allowlisted environment; it does not
inherit the tracker token or `SYMPHONY_DASHBOARD_SECRET_KEY_BASE`. The legacy
`GITHUB_TOKEN` is accepted for one release with a deprecation warning and is
treated as both roles only when the split variables are not configured.

If `GITHUB_AGENT_TOKEN` is absent after migration, polling and observation may
continue, but dispatch fails before the Codex app-server starts.

## Container and Codex boundary

The Docker runtime uses the non-root `symphony` account (UID/GID 10001 by
default). Fresh named volumes inherit writable paths prepared for that identity;
existing root-owned worktree, source-cache, and state volumes require the
operator-run migration in `deploy/docker/README.md`. The normal entrypoint does
not gain root or `CAP_CHOWN` to repair ownership.

Compose sets `no-new-privileges`, drops every Linux capability, and bounds PIDs,
CPU, and memory. Only host Codex `auth.json` and `config.toml` are exposed as
individual read-only bind mounts from a private host staging directory owned by
UID 10001. The original host-login-owned mode `0600` files are copied into that
directory with `sudo install`; they are never made group/world-readable. The
entrypoint fails fast if an input is unreadable, then installs private copies
into `/home/symphony/.codex`. History, sessions, skills, logs, and other host
Codex files are outside the container boundary.

The default Codex sandbox is `workspaceWrite`. A `dangerFullAccess` override is
an explicit per-repository exception that must document why workspace write is
insufficient, its affected paths, compensating controls, and rollback. It must
not be applied globally across workflow variants.

Docker health scans `/proc` for BEAM so it remains valid when `docker-init` is
PID 1. It proves dashboard-independent process liveness only. Tracker
readiness is a separate freshness decision based on a recent successful poll,
current GitHub auth/rate-limit state, and source access. A healthy container must
not be interpreted as tracker-ready, and the optional dashboard is not a
readiness authority.

## Out of scope

This policy does not replace:

- dashboard/API authentication;
- GitHub Project permission administration;
- multi-tenant scheduling or active-run restart/lifecycle semantics.

Those remain separate controls or follow-up tasks in the SymphonyEx improvement
plan.
