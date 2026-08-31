# SymphonyEx User-Review Remediation Implementation Plan

> **For Hermes:** Use `subagent-driven-development` skill to implement this plan task-by-task. Every PR must receive spec-compliance review and code-quality review on one immutable SHA before merge.

**Goal:** 사용자 리뷰에서 확인된 보안·상태 의미·복구·배포·운영 UX 문제를 우선순위대로 해결해 SymphonyEx를 “신뢰된 내부 파일럿”에서 재현 가능하고 안전한 상시 운영 도구로 올린다.

**Architecture:** GitHub를 source of truth로 유지하되, 입력 신뢰 경계·agent 자격증명·dashboard control 권한을 분리한다. 실행 상태 전이는 “실행 결과 → 필수 GitHub write-back → 완료 확정 → cleanup” 순서로 재정의하고, restart/crash 후에도 retry와 session 의미가 유지되도록 durable store를 추가한다. 각 개선은 독립적인 PR로 나눠 회귀 테스트와 운영 문서를 같은 PR에서 갱신한다.

**Tech Stack:** Elixir 1.19 / Erlang OTP, Phoenix LiveView, Bandit, GitHub REST·GraphQL, Codex app-server JSON-RPC, Docker Compose, ExUnit, Credo, Dialyzer, GitHub Actions.

---

## 1. 기준 상태와 동기화 확인

### 확인 결과

2026-08-30 KST에 `git fetch --prune origin` 후 확인했다.

| 항목 | 결과 |
|---|---|
| 로컬 경로 | `/home/twkim/Project/symphony-ex/symphony_ex` |
| 원격 | `git@github.com:angelos0424/symphony-ex.git` |
| 기본 브랜치 | `main` |
| 로컬 HEAD | `39515d55148d3629587ef7626670175ffc2b87ef` |
| `origin/main` | `39515d55148d3629587ef7626670175ffc2b87ef` |
| GitHub API `main` SHA | `39515d55148d3629587ef7626670175ffc2b87ef` |
| ahead / behind | `0 / 0` |
| tracked 변경 | 없음 |
| 결론 | **로컬 main의 tracked 내용은 현재 GitHub main과 정확히 일치** |

### 로컬에만 있는 항목

다음은 `.gitignore` 대상이므로 GitHub 버전 차이는 아니다.

- `.env`
- `_build/`, `deps/`
- `deploy/docker/.env`
- `deploy/docker/env/common.env`, `repo-a.env`, `repo-b.env`, `repo-c.env`
- `erl_crash.dump`

또한 삭제된 `/tmp` 경로를 가리키는 **prunable worktree metadata 3개**가 있다. main 파일 내용에는 영향이 없지만 구현 시작 전 아래 명령으로 정리 여부를 확인한다.

```bash
git worktree prune --dry-run
```

실제 `git worktree prune`은 각 임시 branch의 보존 필요성을 확인한 뒤 별도 로컬 위생 작업으로 수행한다.

### 검증 기준선

| 명령 | 현재 결과 |
|---|---|
| `mix format --check-formatted` | PASS |
| `mix test` | PASS — 217 tests, 0 failures |
| `MIX_ENV=prod mix release --overwrite` | PASS — `symphony_ex 0.1.0` |
| Compose repo-a/b/c `config` | PASS |
| 실제 Docker image build | PASS — 416,551,732 bytes |
| image runtime | root, healthcheck 없음, Codex CLI 0.151.0 |
| `mix credo --strict` | FAIL — 56 findings |
| `mix dialyzer` | FAIL — 31 findings |
| `mix hex.audit` | PASS — retired package 없음 |
| GitHub Actions / tag / release | 없음 |
| main branch protection | status check 요구 없음; admin enforcement 꺼짐; CODEOWNERS review 옵션은 있으나 required approval count 0 |
| GitHub security | secret scanning/push protection 활성; Dependabot security updates 비활성 |
| Repository license | 없음 |

## 2. 상태 모델

| 상태 | 의미 |
|---|---|
| `Todo` | 아직 시작하지 않음 |
| `Picked Up` | 구현 branch/PR이 열림 |
| `Blocked` | 외부 결정·credential·정책 승인이 필요함 |
| `Review` | 구현 완료, 독립 리뷰 또는 CI 대기 |
| `Done` | merge 및 `main` CI 확인 완료 |
| `Deferred` | 이번 안정화 범위에서 명시적으로 제외 |

현재 활성 작업:

- `PR-1A / TRUST-01·02` — **Done**
- Issue: [#32](https://github.com/angelos0424/symphony-ex/issues/32)
- 구현/리뷰/merge: 완료
- PR: [#33](https://github.com/angelos0424/symphony-ex/pull/33)
- merge commit: `0ddbc0558d31392d18279c9b596f7a6820b90cf4`
- main 검증: `0ddbc0558d31392d18279c9b596f7a6820b90cf4`에서 format PASS, focused `67 tests/0 failures`, full `225 tests/0 failures`; GitHub Actions workflow 없음
- 다음 정확한 작업: `PR-1B / TRUST-03`을 새 GitHub Issue로 등록하고, Issue 기준 branch에서만 pick/구현 시작

그 외 구현 Task는 `Todo`이며, 각 Task는 Issue와 branch를 만든 뒤 순차적으로 pick한다.

완료된 후속 작업:

- `PR-1A-FU / TRUST-01·02` — **Done**
- Issue: [#34](https://github.com/angelos0424/symphony-ex/issues/34)
- Parent PR: [#33](https://github.com/angelos0424/symphony-ex/pull/33)
- PR: [#35](https://github.com/angelos0424/symphony-ex/pull/35)
- 구현/리뷰/merge: 완료
- merge commit: `d7a64c14352e48611a7fced969f3ab99587191e2`
- main 검증: `d7a64c14352e48611a7fced969f3ab99587191e2`에서 format PASS, focused `60 tests/0 failures`, full `227 tests/0 failures`; GitHub Actions workflow 없음

- `PR-1B / TRUST-03` — **Done**
- Issue: [#36](https://github.com/angelos0424/symphony-ex/issues/36)
- PR: [#37](https://github.com/angelos0424/symphony-ex/pull/37)
- 구현/리뷰/merge: 완료
- merge commit: `16d16b419d42b5eaddac36ce1ac64d5f1d57887b`
- main 검증: `16d16b419d42b5eaddac36ce1ac64d5f1d57887b`에서 format PASS, full `234 tests/0 failures`; GitHub Actions workflow 없음

현재 활성 작업:

- `PR-0 / SEC-01·02·03` — **Picked Up**
- Issue: [#38](https://github.com/angelos0424/symphony-ex/issues/38)
- Branch: `fix/issue-38-pr0-dashboard-security`
- Objective: Dashboard/API를 인증된 read-only observer로 만들고 runtime control을 명시적으로 분리
- 다음 action: branch에서 RED 테스트와 현행 auth 경계 조사

## 3. 설계 원칙

1. **Fail closed:** 신뢰되지 않은 issue, 인증 없는 remote control, 불완전한 write-back은 실행/완료로 처리하지 않는다.
2. **GitHub truth 일치:** Project가 `Todo`라면 실행 가능해야 한다. 실행 불가능하면 GitHub에 `Failed/Blocked`로 명확히 표현한다.
3. **증거 후 정리:** PR/artifact와 필수 write-back이 확인되기 전에는 성공 worktree/session을 삭제하지 않는다.
4. **Restart는 상태 전이:** 단순 process restart가 아니라 drain/cancel/fence를 포함한 운영 명령으로 취급한다.
5. **Backward compatibility를 명시:** 기존 workflow가 새 보안 설정 때문에 어떻게 바뀌는지 migration note를 제공한다.
6. **한 PR, 한 위험 경계:** 인증, lifecycle, persistence, parser, pagination을 한 PR에 섞지 않는다.
7. **기능보다 gate 우선:** P0/P1을 해결하기 전 dashboard 미관·새 자동화 모드를 추가하지 않는다.

## 4. Milestone Overview

| Milestone | PR | 우선순위 | 범위 | Exit criterion |
|---|---:|---|---|---|
| M0 | PR-0 | P0 | 안전 기본값·배포 경고 | 외부 bind가 인증 없이 시작되지 않고 control은 기본 비활성 |
| M1A | PR-1A | P0 | Issue trust gate | 비신뢰·metadata 누락 Issue와 명시 실행 우회가 dispatch 전에 차단됨 |
| M1B | PR-1B | P0 | Credential boundary | agent와 tracker/dashboard secret이 분리됨 |
| M1C | PR-1C | P0 | Container hardening | non-root, 최소 sandbox, health/resource guard 적용 |
| M2 | PR-2 | P0 | Active-run restart 안전성 | active run 중 orchestrator restart가 fail-closed로 거부됨 |
| M3 | PR-3 | P1 | 실패 `Todo` 재실행 의미 | GitHub `Todo`와 내부 eligibility가 일치 |
| M4 | PR-4 | P1 | Write-back-before-cleanup | 필수 write-back 실패 시 증거 보존 및 reconciliation 가능 |
| M5 | PR-5A/5B | P1 | Crash-safe persistence | session atomic write + retry/completion state 재구성 |
| M6 | PR-6 | P1 | Codex stream integrity | 분할 stdout/UTF-8/긴 JSON-RPC가 유실되지 않음 |
| M7 | PR-7 | P1 | Project pagination | 100개 초과 Project도 모든 후보를 조회 |
| M8A | PR-8A | P1 | CI visibility baseline | 현재 green 계약 required, 정적 debt는 비차단 artifact로 가시화 |
| M8B | PR-8B | P1 | 정적 품질 debt | Credo/Dialyzer strict 0 |
| M8C | PR-8C | P1 | Release policy | exact-SHA tag/image/release 추적 가능 |
| M9 | PR-9 | P2 | Operator-first health UX | 고장/빈 queue가 구분되고 GitHub 복귀 동선 제공 |
| M10 | PR-10 | P2 | Canonical docs·doctor·canary | 신규 운영자가 한 경로로 설치·검증 가능 |

## 5. Task Board

| ID | 상태 | PR | Task | 주요 파일 |
|---|---|---:|---|---|
| SEC-01 | Todo | PR-0 | Dashboard read-only/control 분리 | `config/schema.ex`, `dashboard_live.ex` |
| SEC-02 | Todo | PR-0 | Dashboard/API 인증 및 non-loopback fail-closed | `router.ex`, 새 auth plug, `symphony_ex.ex` |
| SEC-03 | Todo | PR-0 | `check_origin`·배포 예시 강화 | `symphony_ex.ex`, `DEPLOY.md` |
| TRUST-01 | Done | PR-1A | Issue author/association domain 필드 | `domain/issue.ex`, `github/adapter.ex` |
| TRUST-02 | Done | PR-1A | Trusted association/actor gate | `automation.ex`, `config/schema.ex`, `orchestrator.ex` |
| TRUST-01-FU | Done | PR-1A-FU | lifecycle-comments 비활성 시 gated record write-back | `github/adapter.ex`, adapter tests |
| TRUST-02-FU | Done | PR-1A-FU | `Gated only` dashboard queue filter | `dashboard_live.ex`, dashboard tests |
| TRUST-03 | Todo | PR-1B | Agent/orchestrator token 분리 | `config.ex`, `github/client.ex`, app-server, Docker env/entrypoint |
| TRUST-04 | Todo | PR-1C | Non-root container·sandbox·health migration | `Dockerfile`, Compose, workflows |
| CTRL-01 | Todo | PR-2 | Active-run restart guard | `runtime_control.ex`, `orchestrator.ex` |
| CTRL-02 | Todo | PR-2 | Active-run restart 거부 UX·audit | `dashboard_live.ex`, `runtime_snapshot.ex` |
| CTRL-03 | Todo | PR-2 | 설정 상한·확인 UX | `runtime_control.ex`, dashboard tests |
| LIFE-01 | Todo | PR-3 | 실패 release와 completed 의미 분리 | `orchestrator.ex`, lifecycle tests |
| LIFE-02 | Todo | PR-3 | `Retry now/Stop retrying/Resume` API contract | `runtime_control.ex`, API/LiveView |
| WB-01 | Todo | PR-4 | Essential write-back 완료 gate | `orchestrator.ex`, `github/adapter.ex` |
| WB-02 | Todo | PR-4 | Reconciliation queue·증거 보존 | 새 store 또는 orchestrator state, snapshot |
| PERSIST-01 | Todo | PR-5A | Atomic session file publication | `session_store.ex` |
| PERSIST-02 | Todo | PR-5A | Corrupt session quarantine/recovery | `workspace.ex`, session tests |
| PERSIST-03 | Todo | PR-5B | Durable retry/completion state store | 새 `runtime_state_store.ex`, `application.ex` |
| STREAM-01 | Todo | PR-6 | `:noeol` buffer 구현 | `codex/app_server.ex` |
| STREAM-02 | Todo | PR-6 | 긴 line·UTF-8·exit 회귀 테스트 | 새/기존 app-server test |
| PAGE-01 | Todo | PR-7 | ProjectV2 cursor pagination | `github/client.ex` |
| PAGE-02 | Todo | PR-7 | truncation/rate-limit telemetry | `github/adapter.ex`, `runtime_snapshot.ex` |
| CI-01 | Todo | PR-8A | GitHub Actions visibility baseline | `.github/workflows/ci.yml` |
| CI-02 | Todo | PR-8B | Credo/Dialyzer debt 폐쇄 | 핵심 모듈과 `mix.exs` |
| CI-03 | Todo | PR-8C | Pinned release·provenance | release workflow, `mix.exs`, release docs |
| UX-01 | Todo | PR-9 | Health/degraded 모델 | `observability.ex`, `runtime_snapshot.ex` |
| UX-02 | Todo | PR-9 | Operator-first dashboard hierarchy | `dashboard_live.ex` |
| UX-03 | Todo | PR-9 | GitHub Issue/PR direct links·diagnostic copy | dashboard/API |
| DOC-01 | Todo | PR-10 | Canonical quickstart·stale 문서 제거 | `README.md`, `DEPLOY.md`, Docker README |
| DOC-02 | Todo | PR-10 | `bin/doctor`와 dry-run | 새 script/module, tests |
| DOC-03 | Todo | PR-10 | One-issue canary runbook | `docs/operations/*.md` |

---

## 6. PR별 구현 계획

### PR-0: Dashboard를 안전한 read-only observer로 복원

**Objective:** remote dashboard/API가 인증 없이 노출되지 않고, runtime control은 명시적으로 켜야만 사용할 수 있게 한다.

**Files:**
- Modify: `lib/symphony_ex/config/schema.ex`
- Modify: `lib/symphony_ex/config.ex`
- Modify: `lib/symphony_ex.ex`
- Modify: `lib/symphony_ex_web/router.ex`
- Modify: `lib/symphony_ex_web/live/dashboard_live.ex`
- Create: `lib/symphony_ex_web/plugs/dashboard_auth.ex`
- Test: `test/symphony_ex/config_test.exs`
- Test: `test/symphony_ex_web/dashboard_live_test.exs`
- Test: `test/symphony_ex_web/api_controller_test.exs`
- Modify: `.env.example`, `DEPLOY.md`, `deploy/docker/README.md`

**Configuration contract:**

```yaml
dashboard:
  enabled: true
  host: 127.0.0.1
  controls-enabled: false
  auth:
    mode: basic
    username: operator
    password: $SYMPHONY_DASHBOARD_PASSWORD
  allowed-origins:
    - https://symphony.example.internal
```

**Steps:**

1. RED: 인증 없이 `/`와 `/api/v1/status`가 401을 반환하고, 인증 없는 `/live` WebSocket handshake/LiveView mount도 거부되며, `controls-enabled: false`에서 control form/button이 렌더링되지 않는 테스트를 추가한다.
2. RED: `host: 0.0.0.0`인데 auth가 없으면 config load가 실패하는 테스트를 추가한다.
3. GREEN: `DashboardAuth` plug, LiveView socket/session auth 검증, schema/env normalization을 구현한다.
4. GREEN: `controls-enabled` 기본값을 false로 두고 LiveView event handler에서도 서버 측으로 거부한다. UI 숨김만으로 끝내지 않는다.
5. GREEN: `check_origin: false`를 제거하고 configured origin 또는 loopback-safe 기본값을 사용한다.
6. 문서에서 public `4000:4000` 예시를 제거하고 Tailscale/SSH tunnel 또는 인증된 reverse proxy만 안내한다.
7. focused → full gate → immutable review 후 commit한다.

**Verification:**

```bash
mix test test/symphony_ex/config_test.exs
mix test test/symphony_ex_web/dashboard_live_test.exs test/symphony_ex_web/api_controller_test.exs
mix format --check-formatted
mix test
```

**Acceptance:**
- loopback이 아닌 bind는 auth 없이 시작 불가.
- browser/API 모두 동일한 auth boundary를 통과.
- read-only mode에서는 settings write/restart가 서버 측에서 거부됨.
- secret 값이 log/HTML/API response에 나타나지 않음.

**Compatibility/Rollback:** 기존 dashboard 사용자는 auth 또는 loopback을 선택해야 한다. migration error에 정확한 env 이름을 제시한다. 긴급 rollback 시 dashboard를 비활성화하며 인증 없는 public bind로 되돌리지 않는다.

---

### PR-1A: 승인되지 않은 Issue 실행 차단

**Objective:** Project `Todo`만으로 Issue를 신뢰하지 않고 dispatch 직전에 fail-closed trust gate를 적용한다. 가장 먼저 merge한다.

**Files:**
- Modify: `lib/symphony_ex/domain/issue.ex`
- Modify: `lib/symphony_ex/github/client.ex`
- Modify: `lib/symphony_ex/github/adapter.ex`
- Modify: `lib/symphony_ex/automation.ex`
- Modify: `lib/symphony_ex/config/schema.ex`, `lib/symphony_ex/config.ex`
- Modify: `lib/symphony_ex/orchestrator.ex`
- Modify: `lib/symphony_ex/runtime_snapshot.ex`, `lib/symphony_ex_web/controllers/api_controller.ex`, `lib/symphony_ex_web/live/dashboard_live.ex`
- Test: `config_test.exs`, `github/client_test.exs`, `github/adapter_test.exs`, `github_issue_flow_test.exs`, `orchestrator_test.exs`
- Test: `runtime_snapshot_test.exs`, `web/api_controller_test.exs`, `web/dashboard_live_test.exs`
- Create: `docs/security-model.md`

**Configuration contract:**

```yaml
automation:
  issue-trust:
    allowed-associations: [OWNER, MEMBER, COLLABORATOR]
    allowed-actors: []
    require-trusted-author: true
```

**Steps:**

1. RED: `CONTRIBUTOR/NONE` 또는 trust metadata가 없는 Issue가 Project `Todo`여도 worktree/claimed/Codex 전에 `:untrusted_issue_author`로 차단되는 테스트를 추가한다.
2. RED: 명시 Issue 실행도 trust gate를 우회하지 못하는 테스트를 추가한다.
3. Domain Issue에 `author_login`, `author_association`을 추가하고 REST/GraphQL hydration에서 보존한다.
4. allowed actor와 OWNER/MEMBER/COLLABORATOR 허용을 구현한다.
5. gating reason을 managed status, API, dashboard snapshot에 노출한다.
6. 단순 trusted label은 “누가 붙였는지” 증명하지 못하므로 독립 trust evidence로 사용하지 않는다.

**Verification:**

```bash
mix test test/symphony_ex/config_test.exs test/symphony_ex/github/client_test.exs \
  test/symphony_ex/github/adapter_test.exs test/symphony_ex/github_issue_flow_test.exs \
  test/symphony_ex/orchestrator_test.exs
mix format --check-formatted
```

**Acceptance:** 비신뢰/metadata 누락 Issue와 명시 실행 우회가 모두 agent 시작 전에 차단되고, 허용 actor/association만 기존 경로로 실행된다.

**Compatibility/Rollback:** 외부 contributor Issue 자동 실행은 차단된다. 보안 기능이므로 “설정 누락 시 허용” fallback은 두지 않고, 배포 전 dry-run으로 차단 대상을 보여준다.

---

### PR-1A-FU: Review findings — gated write-back과 dashboard filter

**Objective:** PR-1A review에서 발견된 두 concrete gap을 닫는다. `lifecycle-comments: false`인 배포에서도 gated Issue의 안전한 차단 사유를 GitHub에 남기고, dashboard의 `Gated only` URL filter를 실제 동작시킨다.

**Issue:** [#34](https://github.com/angelos0424/symphony-ex/issues/34)

**Files:**
- Modify: `lib/symphony_ex/github/adapter.ex`
- Modify: `lib/symphony_ex_web/live/dashboard_live.ex`
- Test: `test/symphony_ex/github/adapter_test.exs`
- Test: `test/symphony_ex_web/dashboard_live_test.exs`

**Steps:**

1. `status: :gated`만 normal `lifecycle-comments` 설정과 독립된 managed comment path로 기록한다.
2. 기존 claimed/running/retry/released의 `lifecycle-comments: false` 동작은 유지한다.
3. gated record에는 reason과 operator context만 포함하고 token/raw author login은 포함하지 않는다.
4. RuntimeSnapshot의 gated entry를 dashboard `Gated only` queue로 연결한다.
5. `normalize_queue/1`에서 `"gated"`를 허용하고 URL regression test를 추가한다.

**Acceptance:**
- gated write-back이 lifecycle comments disabled template에서도 visible하다.
- normal lifecycle comments disabled behavior가 회귀하지 않는다.
- `/?queue=gated`가 gated section만 렌더링한다.
- focused/full test와 정적 분석 baseline 확인이 완료된다.

**Compatibility/Rollback:** gated write-back은 운영자가 차단 이유를 확인할 수 있도록 의도적으로 항상 기록한다. 문제 발생 시 PR-1A-FU commit만 revert하며 PR-1A trust gate 자체는 유지한다.

---

### PR-1B: Agent와 orchestrator 자격증명 분리

**Objective:** Codex subprocess가 tracker/project write-back token과 dashboard/Phoenix secret에 접근하지 못하게 한다.

**Files:**
- Modify: `lib/symphony_ex/config.ex`, `lib/symphony_ex/config/schema.ex`
- Modify: `lib/symphony_ex/github/client.ex`
- Modify: `lib/symphony_ex/agent_runner.ex`, `lib/symphony_ex/codex/app_server.ex`
- Modify: `deploy/docker/entrypoint.sh`, env examples, Compose 3종
- Test: `config_test.exs`, `github/client_test.exs`, `agent_runner_test.exs`
- Create: `test/symphony_ex/codex/app_server_test.exs`

```text
GITHUB_TRACKER_TOKEN  # Project 조회·write-back 전용
GITHUB_AGENT_TOKEN    # clone/push/PR 전용, repo-scoped
```

**Steps:**

1. RED: Codex Port environment에 tracker token/dashboard secret이 없고 agent token만 명시적으로 전달되는 테스트를 추가한다.
2. Tracker client는 tracker token만 사용한다.
3. agent token 누락 시 poll/observer는 가능하지만 dispatch preflight가 명확히 실패하게 한다.
4. 기존 `GITHUB_TOKEN`은 한 릴리스 동안 warning을 포함한 alias로만 유지한다.
5. git global URL rewrite에 장기 tracker token이 남지 않게 entrypoint를 수정한다.

**Acceptance:** tracker token은 Codex process env/config/log에 없고, agent token만으로 clone/push/PR canary가 통과한다.

---

### PR-1C: Non-root container와 최소 sandbox

**Objective:** container root·무제한 capability·전체 host Codex home 복사 경계를 축소한다.

**Files:**
- Modify: `deploy/docker/Dockerfile`, `deploy/docker/entrypoint.sh`
- Modify: Compose 3종, env examples, workflow 3종
- Modify: `DEPLOY.md`, `deploy/docker/README.md`, `docs/security-model.md`

**Steps:**

1. runtime user `symphony`를 만들고 writable worktree/source-cache/state volume ownership을 정의한다.
2. 전체 `~/.codex` 대신 필요한 auth/config 파일만 `/home/symphony/.codex`로 복사한다.
3. 기본 sandbox를 `workspaceWrite`로 낮추고 `dangerFullAccess`는 repo별 명시 예외로만 허용한다.
4. Compose에 `no-new-privileges`, `cap_drop`, PID/CPU/memory 한도를 추가한다.
5. root 소유 기존 volume용 사전 `chown` migration과 rollback 절차를 문서화한다.
6. dashboard disabled에서도 동작하는 liveness와 tracker freshness readiness를 분리한다.

**Verification:**

```bash
docker build -t symphony-ex:hardening -f deploy/docker/Dockerfile .
docker image inspect symphony-ex:hardening --format 'user={{json .Config.User}} health={{json .Config.Healthcheck}}'
docker run --rm --entrypoint sh symphony-ex:hardening -lc 'id; codex --version; gh --version'
```

**Acceptance:** UID 0이 아니고, healthcheck가 존재하며, worktree/clone/Codex canary가 non-root로 통과한다.

---

### PR-2: Active-run restart와 설정 변경 안전화

**Objective:** durable state와 safe cancellation이 준비되기 전까지 active run 중 orchestrator restart를 fail-closed로 거부하고, 과도한 polling/concurrency 설정으로 자원 폭주가 발생하지 않게 한다.

**Files:**
- Modify: `lib/symphony_ex/runtime_control.ex`
- Modify: `lib/symphony_ex/orchestrator.ex`
- Modify: `lib/symphony_ex/runtime_snapshot.ex`
- Modify: `lib/symphony_ex_web/live/dashboard_live.ex`
- Test: `runtime_control_test.exs`, `orchestrator_test.exs`, dashboard tests

**Steps:**

1. RED: active run 중 `restart_component(:orchestrator)`가 `{:error, {:active_runs, identifiers}}`를 반환하고 child PID가 바뀌지 않는 테스트.
2. Orchestrator snapshot/call API로 active identifiers를 제공한다.
3. RuntimeControl은 active run이 하나라도 있으면 restart를 거부한다. 이 PR에는 force/drain/cancel을 넣지 않는다.
4. UI에 active run 목록과 차단 이유를 표시하고, 거부 audit event를 남긴다.
5. endpoint restart는 orchestrator task와 무관한 별도 정책으로 유지한다.
6. `poll_interval_ms`, `max_concurrent`, retry backoff에 schema와 UI의 합리적 상한을 둔다. 작은 호스트 기본은 1을 유지한다.
7. durable state와 cancellation fence가 PR-5B 이후 검증되기 전에는 forced restart 기능을 추가하지 않는다.

**Verification:**

```bash
mix test test/symphony_ex/runtime_control_test.exs test/symphony_ex/orchestrator_test.exs
mix test test/symphony_ex_web/dashboard_live_test.exs
mix test
```

**Acceptance:** idle restart는 성공하고, active run 중에는 orchestrator PID·task·worktree가 그대로 유지되며 명확한 차단 사유와 audit event가 남는다.

---

### PR-3: 실패 lifecycle과 재실행 의미 일치

**Objective:** GitHub `Todo`가 실제로 재실행 가능하며, 재실행 불가 실패는 GitHub에서도 별도 상태로 보이게 한다.

**Files:**
- Modify: `lib/symphony_ex/orchestrator.ex`
- Modify: `lib/symphony_ex/orchestrator/lifecycle.ex`
- Modify: `lib/symphony_ex/runtime_control.ex`
- Modify: `lib/symphony_ex_web/controllers/api_controller.ex`
- Modify: `lib/symphony_ex_web/live/dashboard_live.ex`
- Test: `orchestrator_test.exs`, `github_issue_flow_test.exs`, API/dashboard tests

**Decision:**
- 성공 → `released/success → In Review`, completed dedupe set에 포함.
- retry exhausted 또는 deterministic failure → 기본 `Failed`(또는 명시된 비활성 상태), completed dedupe set에는 포함하지 않음.
- 운영자가 `Failed → Todo`로 이동하면 같은 프로세스에서도 새 실행 가능.
- 실패를 자동으로 계속 `Todo`에 두어 무한 재실행하는 설정은 validation에서 거부.
- 취소는 `Cancelled` 또는 별도 비활성 상태로 표현.

**Steps:**

1. RED: retry exhausted 후 `Failed`로 이동하고 동일 issue가 자동 재선택되지 않는 테스트.
2. RED: 운영자가 Project 상태를 `Failed → Todo`로 바꾸면 orchestrator restart 없이 다시 eligible한 테스트.
3. RED: 필요한 Project status option이 없으면 시작 preflight가 정확한 생성/매핑 안내와 함께 실패하는 테스트.
4. completion history와 dispatch suppression을 분리한다. 실패 기록이 곧 영구 suppression을 뜻하지 않게 한다.
5. `Retry now`, `Stop retrying`, `Resume workspace` runtime command를 idempotent API로 추가한다.
6. GitHub status/comment와 dashboard action 결과가 동일한 상태 전이를 보이는 integration test를 추가한다.

**Acceptance:** GitHub-visible state와 in-memory eligibility가 일치하며 orchestrator restart 없이 복구 가능.

---

### PR-4: 필수 write-back 성공 후 cleanup

**Objective:** GitHub truth 확정 전에 성공 증거를 삭제하지 않는다.

**Files:**
- Modify: `lib/symphony_ex/orchestrator.ex`
- Modify: `lib/symphony_ex/github/adapter.ex`
- Modify: `lib/symphony_ex/runtime_snapshot.ex`
- Modify: `lib/symphony_ex/observability.ex`
- Test: `orchestrator_test.exs`, `github/adapter_test.exs`, `github_issue_flow_test.exs`

**New sequence:**

```text
agent success
→ validate branch/commit/PR artifact
→ persist local completion evidence
→ essential GitHub write-back
→ verify released state
→ mark completed
→ cleanup according to retention policy
```

**Steps:**

1. RED: workspace remove가 essential write-back보다 먼저 호출되지 않는 call-order 테스트.
2. RED: issue body success + Project status failure에서 workspace/session이 보존되고 `reconciliation_required`가 생성되는 테스트.
3. Adapter write-back 결과를 essential/optional stage typed result로 반환한다.
4. Orchestrator에 reconciliation queue를 추가하고 retry/idempotency marker를 둔다.
5. cleanup policy를 `immediate_after_verified`, `retain_success_hours`, `retain_on_partial_writeback`으로 명시한다.
6. dashboard에서 partial write-back의 failed stage와 “Retry reconciliation”을 제공한다.

**Acceptance:** 필수 write-back 실패 시 completed 처리·worktree 삭제가 일어나지 않으며 재시도해도 중복 comment/status corruption이 없음.

---

### PR-5A: Session breadcrumb 원자 저장과 손상 격리

**Objective:** 전원 장애가 session JSON을 깨뜨려 workspace를 영구 차단하지 않게 한다.

**Files:**
- Modify: `lib/symphony_ex/session_store.ex`
- Modify: `lib/symphony_ex/workspace.ex`
- Test: `test/symphony_ex/session_store_test.exs`
- Test: `test/symphony_ex/workspace_test.exs`

**Steps:**

1. RED: partial temp write가 canonical session을 손상하지 않는 테스트.
2. RED: corrupt canonical JSON을 `.corrupt-<timestamp>`로 보존하고 typed recovery result를 반환하는 테스트.
3. same-directory temp file에 write → `:file.sync` → atomic rename → directory sync를 구현한다.
4. file mode를 0600으로 고정하고 secret-like keys 저장 금지 contract를 추가한다.
5. corrupt file은 자동 삭제하지 않고 quarantine path와 recovery action을 dashboard/로그에 남긴다.

**Acceptance:** crash simulation 후 이전 valid session 또는 명확한 quarantine 상태로 복구됨.

---

### PR-5B: Retry·completion runtime state 지속화

**Objective:** orchestrator restart 후 retry count, due-at, reconciliation, 최근 completion 의미를 재구성한다.

**Files:**
- Create: `lib/symphony_ex/runtime_state_store.ex`
- Modify: `lib/symphony_ex/application.ex`
- Modify: `lib/symphony_ex/orchestrator.ex`
- Modify: `lib/symphony_ex/runtime_snapshot.ex`
- Test: 새 `runtime_state_store_test.exs`, orchestrator restart tests

**Persist only:** retry attempt/due-at, reconciliation entries, completion dedupe keys와 retention deadline. Task PID나 monotonic timestamp는 저장하지 않는다.

**Steps:**

1. RED: restart 후 retry가 남은 wall-clock delay를 유지하는 테스트.
2. RED: 이미 검증된 completion이 restart 후 duplicate dispatch되지 않는 테스트.
3. versioned JSON schema와 atomic publication을 구현한다.
4. boot 시 wall-clock timestamp를 monotonic schedule로 재계산한다.
5. unknown future schema는 fail closed하고 backup/quarantine한다.

**Acceptance:** kill/restart integration test에서 duplicate agent launch 없이 상태가 복원됨.

---

### PR-6: Codex app-server stream 무결성

**Objective:** `{:noeol, chunk}`를 잃지 않고 JSON-RPC line을 정확히 복원한다.

**Files:**
- Modify: `lib/symphony_ex/codex/app_server.ex`
- Create or modify: `test/symphony_ex/codex/app_server_test.exs`
- Test: `agent_runner_test.exs`

**Steps:**

1. RED: 한 JSON response가 2~4개의 `:noeol`과 마지막 `:eol`로 분할되는 테스트.
2. RED: UTF-8 multibyte boundary, 10MB 근접 line, 여러 line 연속, exit 직전 partial line 테스트.
3. state에 bounded `stdout_buffer`를 추가하고 complete line만 parser에 전달한다.
4. 최대 buffer 초과는 `protocol_line_too_large` typed failure와 breadcrumb를 남긴다.
5. process exit 시 남은 non-empty buffer는 diagnostic artifact로 보존한다.

**Acceptance:** 분할 방식과 관계없이 동일 event sequence/result가 생성되고 가짜 stall이 발생하지 않음.

---

### PR-7: GitHub ProjectV2 cursor pagination

**Objective:** Project item 100개 제한으로 후보가 누락되지 않게 한다.

**Files:**
- Modify: `lib/symphony_ex/github/client.ex`
- Modify: `lib/symphony_ex/github/adapter.ex`
- Modify: `lib/symphony_ex/runtime_snapshot.ex`
- Test: `github/client_test.exs`, `github/adapter_test.exs`

**Steps:**

1. RED: 2페이지(100 + 1) fixture에서 101번째 eligible issue를 반환하는 테스트.
2. Query에 `after`, `pageInfo { hasNextPage endCursor }`를 추가한다.
3. fields는 첫 page에서만 또는 별도 query로 가져와 중복 fanout을 피한다.
4. max pages/items safeguard와 `truncated: true` telemetry를 추가한다. truncation은 조용히 성공 처리하지 않는다.
5. rate-limit이 낮으면 다음 cursor와 retry-after를 보존한다.

**Acceptance:** 250-item fixture에서 중복·누락 없이 모든 item을 처리하고 bounded API call count를 만족.

---

### PR-8A: 재현 가능한 CI 기반

**Objective:** 현재 성공하는 format/test/release/Docker 계약을 먼저 자동화하고, 실패 중인 정적 분석은 숨기지 않고 artifact로 게시한다.

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `Makefile`, `mise.toml`, `deploy/docker/Dockerfile`, `README.md`, `DEPLOY.md`

**Steps:**

1. blocking jobs: format, test, release, Compose 3종 config, Docker build.
2. non-blocking visibility jobs: Credo/Dialyzer full output와 fingerprint artifact. 현재 실패를 PASS로 바꾸지 않는다.
3. Elixir/OTP/Codex를 pin하고 GH CLI tarball checksum을 검증한다.
4. `mix hex.audit`, dependency update report, image digest/SBOM을 추가한다.
5. CI job 이름을 안정화한 뒤 branch protection required checks로 등록한다.

**Acceptance:** fresh clone에서 현재 green 계약은 required CI로 통과하고, Credo/Dialyzer debt가 매 PR에서 비교 가능한 artifact로 남는다.

---

### PR-8B: Credo·Dialyzer debt 소진

**Objective:** 의미 변경과 단순 리팩터링을 섞지 않고 정적 분석 baseline을 0으로 닫는다.

**Files:**
- Modify: `agent_runner.ex`, `github/adapter.ex`, `orchestrator.ex`, `config.ex`, `runtime_snapshot.ex`, `runtime_control.ex`, `source_repo.ex`, `workspace.ex`, `single_active_guard.ex`, `issue_body_metadata.ex`, `automation.ex`
- Test: 각 모듈의 기존 test와 `github_issue_flow_test.exs`

**Steps:**

1. Dialyzer contract/pattern defect를 먼저 모듈군별 PR로 수정한다.
2. Credo warning/readability를 수정한다.
3. complexity refactor는 behavior characterization test를 먼저 추가하고 2~4개 작은 PR로 나눈다.
4. broad ignore baseline으로 0을 가장하지 않는다.
5. 0 달성 후 Credo/Dialyzer jobs를 required blocking으로 전환한다.

**Acceptance:** `make all`이 strict green이며 새 warning을 허용하지 않는다.

---

### PR-8C: 첫 release candidate와 정책

**Objective:** exact SHA와 pinned toolchain으로 추적 가능한 release를 발행할 수 있게 한다.

**Files:**
- Create: `.github/workflows/release.yml`, `CHANGELOG.md`, `SECURITY.md`, `SUPPORT.md`, `docs/upgrade.md`
- Create: `LICENSE`는 프로젝트 소유자가 라이선스를 선택·승인한 뒤
- Modify: `mix.exs`, `README.md`, `DEPLOY.md`

**Steps:**

1. semver tag에서만 release/image publication을 수행한다.
2. release metadata에 commit SHA, image digest, SBOM, 지원 matrix, migration/known issues를 기록한다.
3. branch protection의 관리자 우회 정책과 최소 approval 수를 명시한다.
4. Dependabot security updates 활성화를 검토한다.
5. `v0.2.0-rc.1` exact-SHA smoke 후 release를 발행한다.

**Acceptance:** 운영 문서는 tag/digest 배포만 권장하며 release artifact와 source SHA가 역추적 가능하다.

---

### PR-9: Operator-first health dashboard

**Objective:** “할 일이 없음”과 “tracker가 고장남”을 즉시 구분하고 GitHub truth로 바로 이동할 수 있게 한다.

**Files:**
- Modify: `lib/symphony_ex/observability.ex`
- Modify: `lib/symphony_ex/runtime_snapshot.ex`
- Modify: `lib/symphony_ex_web/live/dashboard_live.ex`
- Modify: API controller
- Test: runtime snapshot, dashboard, API tests

**Health model:** `healthy | degraded | draining | stopped`, last successful poll, last error category, next poll, credential/rate-limit state, reconciliation count.

**Steps:**

1. RED: tracker poll failure 시 0 candidates가 아니라 `degraded` banner를 렌더링하는 테스트.
2. 최상단 순서를 Health → Action required → Running → Retry/Reconciliation → Recent completion으로 바꾼다.
3. “Phase 3.4.4 / This slice…” 개발 문구를 제거하고 고급 필터는 접는다.
4. issue/PR URL을 card/detail/API에 포함하고 새 창 direct link를 제공한다.
5. 내부 오류 category마다 operator action text와 diagnostics copy를 제공한다.

**Acceptance:** 인증 실패, rate limit, empty queue, active run, partial write-back을 5초 안에 구분 가능한 화면.

---

### PR-10: Canonical onboarding, doctor, dry-run, canary

**Objective:** 독립 clone 사용자가 하나의 문서 경로로 설치하고 실제 write를 하기 전에 문제를 발견한다.

**Files:**
- Modify: `README.md`, `DEPLOY.md`, `deploy/docker/README.md`
- Move/Create: `docs/plans/` 안의 tracked plan
- Create: `docs/operations/quickstart.md`
- Create: `docs/operations/one-issue-canary.md`
- Create: `bin/doctor` 또는 Mix task `lib/mix/tasks/symphony.doctor.ex`
- Add tests for doctor output/config checks

**Doctor checks:** pinned tool versions, GitHub auth, repo/project read, project Status options, source clone/fetch, workspace write, Codex login/version/model, dashboard bind/auth, token separation, Docker volume ownership.

**Dry-run output:** selected candidates, trust/gating reason, target branch/PR, intended lifecycle updates. Agent 실행·GitHub mutation은 0건.

**Steps:**

1. broken `../CONVERSION_PLAN.md`, stale Dockerfile, SSH/HTTPS 설명 충돌을 제거한다.
2. limited/full-auto 모드의 권한·state transition·merge 조건 표를 추가한다.
3. `doctor`는 secret 값을 출력하지 않고 pass/fail/action 명령을 반환한다.
4. canary는 명시 Issue 하나, expected branch/PR/status, rollback/cleanup을 검증한다.
5. docs link checker와 command smoke를 CI에 추가한다.

**Acceptance:** 새 checkout에서 문서만 따라 `doctor → dry-run → one-issue canary`를 완료할 수 있고 stale path/명령이 없음.

## 7. Suggested PR Sequence and Merge Gates

| 순서 | PR | 선행 조건 | Merge gate |
|---:|---|---|---|
| 1 | PR-1A Issue trust gate | 없음 | untrusted/missing metadata/explicit issue negative tests |
| 2 | PR-1B Credential split | PR-1A config contract | subprocess env secrecy + agent canary |
| 3 | PR-0 Dashboard safety | PR-1A와 schema rebase | HTTP/API/LiveView auth·control negative tests |
| 4 | PR-8A CI visibility | 앞선 job 이름 확정 | 현재 green 계약 required + debt artifacts |
| 5 | PR-1C Container hardening | PR-1B env contract | non-root image + volume/auth smoke |
| 6 | PR-2 Restart refusal | PR-0 control model | active-run child PID 불변 테스트 |
| 7 | PR-3 Lifecycle semantics | PR-2 이후 순차 | Failed→Todo 수동 redispatch integration |
| 8 | PR-4 Write-back ordering | PR-3 | partial write-back + evidence retention |
| 9 | PR-5A Atomic session | 독립, PR-5B 전 | crash/quarantine tests |
| 10 | PR-5B Durable runtime state | PR-3, PR-4, PR-5A | kill/restart integration |
| 11 | PR-6 Stream integrity | 독립 | chunk/UTF-8/size tests |
| 12 | PR-7 Pagination | 독립 | 250-item fixture + rate-limit behavior |
| 13 | PR-8B Static debt | PR-0~7 기능 SHA | `make all` strict green |
| 14 | PR-9 Health UX | PR-2, PR-4, PR-5B, PR-7 | degraded/action UI tests |
| 15 | PR-10 Docs/doctor | PR-0~9 | fresh-clone quickstart rehearsal |
| 16 | PR-8C Release | 모든 required gate green | exact-SHA `v0.2.0-rc.1` smoke/release |

### 병렬화 가능 범위

- PR-6(stream)과 PR-7(pagination)은 서로 독립적으로 병렬 가능.
- PR-5A(session atomic)는 보안/control/lifecycle 작업과 병렬 가능하나 PR-5B 전에 merge.
- PR-1B(credential)와 PR-0(dashboard)은 PR-1A의 config 계약 이후 병렬 개발 가능하지만 env/schema 문서는 rebase 필요.
- PR-2/3/4와 PR-5B는 모두 `orchestrator.ex` 핵심 상태를 바꾸므로 반드시 순차.
- PR-8A는 조기에 넣어 이후 PR의 현재-green 계약과 정적 debt를 계속 가시화한다.
- PR-8B는 기능 의미가 안정된 뒤 수행하고, PR-8C release는 모든 required gate가 green인 마지막 단계다.
- PR-9/10은 안정화된 runtime semantics를 기준으로 마지막에 수행.

## 8. Global Verification Gates

각 PR의 focused test 이후 다음 순서로 검증한다.

```bash
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
MIX_ENV=prod mix release --overwrite
cd deploy/docker
docker compose --env-file .env.example -f docker-compose.repo-a.yml config
docker compose --env-file .env.example -f docker-compose.repo-b.yml config
docker compose --env-file .env.example -f docker-compose.repo-c.yml config
```

Docker 관련 PR:

```bash
docker build -t symphony-ex:review -f deploy/docker/Dockerfile .
docker image inspect symphony-ex:review
docker run --rm --entrypoint sh symphony-ex:review -lc 'id; codex --version; gh --version'
```

GitHub canary 관련 PR은 별도 test repository/project에서 다음을 확인한다.

1. trusted `Todo` 1개만 선택.
2. untrusted issue 1개는 명확한 gating reason으로 차단.
3. PR branch/head 검증.
4. required check 대기.
5. essential write-back 후 cleanup.
6. failure→retry→restart→resume 의미.
7. secret/token이 logs, comments, dashboard, artifacts에 없음.

### 기존 정적 분석 debt 처리

PR-8B 이전에는 현재 baseline(`Credo 56`, `Dialyzer 31`) 때문에 전체 정적 gate가 실패한다. 이를 PASS로 오표기하지 않는다.

- PR-8A부터 Credo/Dialyzer 결과를 non-blocking artifact로 게시한다.
- PR-0~7과 PR-1A/B/C는 매번 실행하고, **새 finding 0개 / 총 finding 수 증가 없음**을 merge 조건으로 둔다.
- 변경한 파일·함수에서 발생한 관련 finding은 해당 PR에서 제거한다.
- PR-8B에서 baseline 전체를 0으로 닫고 이후 required CI를 strict green으로 전환한다.
- snapshot 숫자만 비교하지 말고 finding fingerprint(파일, line, check/type)를 보존해 기존 finding 교체로 새 결함이 숨지 않게 한다.

## 9. Review and Delivery Policy

각 PR은 아래 절차를 따른다.

1. 최신 `origin/main`에서 branch 생성.
2. RED test와 expected failure 기록.
3. 최소 구현 후 focused GREEN.
4. 전체 gate 실행.
5. immutable SHA를 고정하고 spec-compliance 독립 리뷰.
6. 같은 SHA에 code-quality/security 독립 리뷰.
7. findings 수정 시 새 SHA로 두 리뷰를 다시 받음.
8. PR push 후 GitHub 파일/base/head 확인.
9. CI green 후 merge.
10. `main` CI 확인 후 다음 PR 시작.

문서·status checkpoint에는 항상 다음을 기록한다.

- 검증 SHA
- 통과/실패 명령과 실제 결과
- 닫힌 review finding
- 남은 blocking debt
- 다음 정확한 Task ID

## 10. Non-goals

이번 안정화에서는 다음을 구현하지 않는다.

- multi-orchestrator/distributed lease
- Linear 재도입
- dashboard를 GitHub 대신 primary source of truth로 승격
- Qdrant/장기 memory 기능
- 새로운 full-auto 기능·서비스 mapping 확장
- 외부 multi-tenant SaaS 인증/계정 체계

## 11. 완료 정의

아래가 모두 충족돼야 리뷰 개선 계획이 완료된 것으로 본다.

- remote dashboard/API가 인증되고 control은 기본 비활성.
- 비신뢰 Issue가 agent를 시작할 수 없음.
- orchestrator token과 agent token이 분리됨.
- active run restart가 고아/중복 task를 만들지 않음.
- GitHub `Todo`와 실제 redispatch 가능성이 일치.
- essential write-back 전 성공 증거가 삭제되지 않음.
- restart/crash 후 retry/session/reconciliation 의미가 복구됨.
- partial Codex stdout과 100개 초과 Project가 정상 처리됨.
- format/test/Credo/Dialyzer/release/Docker gates가 CI에서 green.
- 신규 운영자가 canonical quickstart와 doctor/canary로 설치 가능.
- 첫 release candidate가 exact SHA, pinned versions, changelog와 함께 발행 가능.
