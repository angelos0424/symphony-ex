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

## Out of scope

This policy does not replace:

- dashboard/API authentication;
- separation of tracker and agent credentials;
- Codex sandbox restrictions;
- container non-root hardening;
- GitHub Project permission administration.

Those are separate hardening tasks in the SymphonyEx improvement plan.
