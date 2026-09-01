# Symphony-Ex 배포 가이드

## 운영 원칙

- 운영 truth는 GitHub Issue + GitHub Project다.
- 대시보드는 관찰면이다. 운영 판단의 최종 기준이 아니다.
- 프로젝트당 active orchestrator는 하나만 둔다.
- 현재 범위는 GitHub-only다.

## 환경 변수 레퍼런스

### 필수

| 변수 | 설명 | 예시 |
|------|------|------|
| `GITHUB_TRACKER_TOKEN` | Orchestrator용 GitHub Issue/Project Personal Access Token | `ghp_tracker_xxx` |
| `GITHUB_AGENT_TOKEN` | Codex용 repo-scoped clone/push/PR Personal Access Token | `ghp_agent_xxx` |
| `GITHUB_TOKEN` | Deprecated one-release alias for both tokens | (legacy only) |
| `GITHUB_OWNER` | GitHub 조직/사용자명 | `openai` |
| `GITHUB_REPO` | 대상 저장소명 | `symphony` |
| `WORKSPACE_ROOT` | 워크스페이스 루트 디렉토리 | `/opt/symphony/worktrees` |
| `SOURCE_REPO_PATH` | 소스 Git 저장소 경로, 명시 시 최우선 | `/opt/symphony/source-repo` |
| `SOURCE_REPO_URL` | 소스 저장소 Git URL, 자동 bootstrap 입력 | `git@github.com:my-org/my-repo.git` |

### 선택

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `GITHUB_PROJECT_NUMBER` | GitHub Project v2 번호 | (없음) |
| `SOURCE_CACHE_ROOT` | `SOURCE_REPO_URL`용 로컬 clone 캐시 루트 | `./.symphony/source-cache` |
| `SYMPHONY_REPO_PATH` | Symphony 설정 저장소 경로 | (없음) |
| `GITHUB_ISSUE_IDENTIFIER` (`ISSUE_IDENTIFIER` legacy alias) | 특정 이슈만 실행 | (없음, 폴링 모드) |

### 대시보드

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `SYMPHONY_DASHBOARD_ENABLED` | 대시보드 활성화 | `false` |
| `SYMPHONY_DASHBOARD_PORT` | HTTP 포트 | `4000` |
| `SYMPHONY_DASHBOARD_HOST` | 바인드 주소 | `127.0.0.1` |
| `SYMPHONY_DASHBOARD_CONTROLS_ENABLED` | runtime settings/restart control 허용 | `false` |
| `SYMPHONY_DASHBOARD_AUTH_MODE` | 대시보드 인증 방식 (`basic`) | `basic` |
| `SYMPHONY_DASHBOARD_USERNAME` | Basic Auth 사용자명. non-loopback bind에서 필수 | 없음 |
| `SYMPHONY_DASHBOARD_PASSWORD` | Basic Auth 비밀번호. non-loopback bind에서 필수 | 없음 |
| `SYMPHONY_DASHBOARD_ALLOWED_ORIGINS` | LiveView browser origin 쉼표 목록 | loopback origins |
| `SYMPHONY_DASHBOARD_SECRET_KEY_BASE` | Phoenix 세션/서명용 secret. 대시보드 활성화 시 필수 | 없음 |

> [!IMPORTANT]
> `127.0.0.1`/`localhost` loopback에서는 기본적으로 인증 없는 read-only observer로 사용할 수 있습니다. `0.0.0.0` 또는 다른 non-loopback 주소를 사용하려면 `SYMPHONY_DASHBOARD_USERNAME`과 `SYMPHONY_DASHBOARD_PASSWORD`를 반드시 설정해야 하며, controls는 별도로 명시적으로 켜야 합니다.

> [!WARNING]
> 대시보드를 `0.0.0.0`에 바인드할 때 인증 없는 `4000:4000` public 포트 매핑을 사용하지 마십시오. Tailscale/SSH tunnel 또는 인증된 reverse proxy를 사용하고, `SYMPHONY_DASHBOARD_ALLOWED_ORIGINS`를 실제 browser origin으로 제한하십시오.

### 로깅

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `SYMPHONY_LOG_FORMAT` | 로그 포맷 (`pretty` / `json`) | `pretty` |
| `SYMPHONY_LOG_LEVEL` | 로그 레벨 | `info` |
| `SYMPHONY_LOG_REDACT_KEYS` | 민감 키 redaction (쉼표 구분) | (없음) |
| `SYMPHONY_LOG_MAX_METADATA_VALUE_LENGTH` | 메타데이터 값 최대 길이 | (무제한) |

## Docker Compose 배포

Canonical production templates live under `deploy/docker/`; do not copy the
older inline examples into production. The image runs as `symphony` UID/GID
10001, stages only host Codex `auth.json` and `config.toml`, and declares a
BEAM-process liveness healthcheck that does not depend on the dashboard.

All three Compose variants enforce `no-new-privileges`, drop all capabilities,
and bound PIDs, CPU, and memory. They provide separate writable named volumes
for worktrees, source cache, and state. The tracked workflows default Codex to
`workspaceWrite`; `dangerFullAccess` requires a documented change to only the
specific repository workflow, with rationale and rollback.

```bash
cd deploy/docker
cp .env.example .env
cp env/common.env.example env/common.env
cp env/repo-a.env.example env/repo-a.env
cp env/repo-b.env.example env/repo-b.env
cp env/repo-c.env.example env/repo-c.env

# Point SYMPHONY_CODEX_HOME in .env at the absolute host Codex directory.
docker compose --env-file .env -f docker-compose.repo-a.yml config
docker compose --env-file .env -f docker-compose.repo-b.yml config
docker compose --env-file .env -f docker-compose.repo-c.yml config
```

Before first hardened startup on existing named volumes, stop all variants,
back up the volumes, and perform the explicit one-time UID migration documented
in `deploy/docker/README.md`. The non-root entrypoint intentionally never
`chown`s mounts. Rollback is stop → restore backup → previous image; reverse
ownership to `0:0` only if the previous runtime actually requires it, and never
restore privileged capabilities or a whole-host-Codex-home mount.

Docker health is **liveness only**: PID 1 must be the live BEAM process.
Tracker-freshness readiness is separate and requires a recent successful GitHub
poll, no current auth/rate-limit failure, and usable source access. Until there
is a stable readiness endpoint, assess freshness through structured logs and
GitHub Project truth rather than the optional dashboard or Docker health.

See `deploy/docker/README.md` for exact migration, rollback, validation, and run
commands.

## systemd 배포

```ini
[Unit]
Description=Symphony-Ex Autonomous Issue Pipeline
After=network.target

[Service]
Type=exec
User=symphony
Group=symphony
WorkingDirectory=/opt/symphony-ex
ExecStart=/opt/symphony-ex/bin/symphony_ex start
ExecStop=/opt/symphony-ex/bin/symphony_ex stop
Restart=on-failure
RestartSec=5

EnvironmentFile=/opt/symphony-ex/.env

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/opt/symphony/worktrees /opt/symphony/source-cache /opt/symphony/source-repo

[Install]
WantedBy=multi-user.target
```

```bash
# 1. release 빌드
MIX_ENV=prod mix release

# 2. 배포 디렉토리 준비
sudo mkdir -p /opt/symphony-ex
sudo cp -r _build/prod/rel/symphony_ex/* /opt/symphony-ex/

# 3. 캐시/워크스페이스 디렉토리 준비
sudo mkdir -p /opt/symphony/worktrees /opt/symphony/source-cache
sudo chown -R symphony:symphony /opt/symphony/worktrees /opt/symphony/source-cache

# 4. 환경변수 파일 생성
sudo cat > /opt/symphony-ex/.env << 'EOF'
GITHUB_TRACKER_TOKEN=ghp_tracker_xxx
GITHUB_AGENT_TOKEN=ghp_agent_xxx
GITHUB_OWNER=my-org
GITHUB_REPO=my-repo
WORKSPACE_ROOT=/opt/symphony/worktrees
SOURCE_REPO_URL=git@github.com:my-org/my-repo.git
SOURCE_CACHE_ROOT=/opt/symphony/source-cache
SYMPHONY_LOG_FORMAT=json
EOF

# 5. 서비스 등록 및 시작
sudo systemctl daemon-reload
sudo systemctl enable symphony-ex
sudo systemctl start symphony-ex

# 6. 상태 확인
sudo systemctl status symphony-ex
sudo journalctl -u symphony-ex -f
```

## `WORKFLOW.md` 예시

```yaml
---
tracker:
  kind: github
  owner: my-org
  repo: my-repo
  project-number: 7
  active-states:
    - Todo
    - In Progress
  terminal-states:
    - In Review
    - Done
workspace:
  root: /opt/symphony/worktrees
  source-repo-url: git@github.com:my-org/my-repo.git
  source-cache-root: /opt/symphony/source-cache
orchestrator:
  poll-interval-ms: 60000
  max-concurrent: 1
  max-retries: 3
codex:
  command: codex app-server
  thread-sandbox: workspaceWrite
  stall-timeout-ms: 300000
dashboard:
  enabled: true
  secret-key-base: replace-with-a-long-random-secret
---
```
