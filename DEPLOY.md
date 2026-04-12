# Symphony-Ex 배포 가이드

## 환경 변수 레퍼런스

### 필수 (GitHub 트래커)

| 변수 | 설명 | 예시 |
|------|------|------|
| `GITHUB_TOKEN` | GitHub Personal Access Token (repo, project 권한) | `ghp_xxx` |
| `GITHUB_OWNER` | GitHub 조직/사용자명 | `openai` |
| `GITHUB_REPO` | 대상 저장소명 | `symphony` |
| `WORKSPACE_ROOT` | 워크스페이스 루트 디렉토리 | `/opt/symphony/worktrees` |
| `SOURCE_REPO_PATH` | 소스 Git 저장소 경로 | `/opt/symphony/source-repo` |

### 선택

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `GITHUB_PROJECT_NUMBER` | GitHub Project v2 번호 | (없음) |
| `TRACKER_KIND` | 트래커 종류 (`github` / `linear`) | `github` |
| `SYMPHONY_REPO_PATH` | Symphony 설정 저장소 경로 | (없음) |
| `ISSUE_IDENTIFIER` | 특정 이슈만 실행 (예: `#42`) | (없음, 폴링 모드) |

### Linear 트래커 (선택)

| 변수 | 설명 |
|------|------|
| `LINEAR_API_KEY` | Linear API 키 |
| `TEAM_KEY` | Linear 팀 키 (예: `SYM`) |

### 대시보드

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `SYMPHONY_DASHBOARD_ENABLED` | 대시보드 활성화 | `false` |
| `SYMPHONY_DASHBOARD_PORT` | HTTP 포트 | `4000` |
| `SYMPHONY_DASHBOARD_HOST` | 바인드 주소 | `127.0.0.1` |
| `SYMPHONY_DASHBOARD_SECRET_KEY_BASE` | Phoenix 세션/서명용 secret. `SYMPHONY_DASHBOARD_ENABLED=true`일 때 필수 | 없음 |

> [!IMPORTANT]
> 대시보드를 켜면 `SYMPHONY_DASHBOARD_SECRET_KEY_BASE`도 반드시 설정해야 합니다.
> 설정하지 않으면 런타임이 부팅 전에 명시적으로 실패합니다.

### 로깅

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `SYMPHONY_LOG_FORMAT` | 로그 포맷 (`pretty` / `json`) | `pretty` |
| `SYMPHONY_LOG_LEVEL` | 로그 레벨 | `info` |
| `SYMPHONY_LOG_REDACT_KEYS` | 민감 키 redaction (쉼표 구분) | (없음) |
| `SYMPHONY_LOG_MAX_METADATA_VALUE_LENGTH` | 메타데이터 값 최대 길이 | (무제한) |

---

## Docker Compose 배포

### Dockerfile

```dockerfile
FROM hexpm/elixir:1.19.0-erlang-28.0-debian-bookworm-20240612 AS build

WORKDIR /app

# Install build deps
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy and install deps
ENV MIX_ENV=prod
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

# Copy app and compile
COPY lib lib/
COPY WORKFLOW.md ./
RUN mix compile

# Build release
RUN mix release

# --- Runtime ---
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y git openssh-client && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/_build/prod/rel/symphony_ex ./

ENV LANG=en_US.UTF-8
CMD ["bin/symphony_ex", "start"]
```

### docker-compose.yml

> [!IMPORTANT]
> `SOURCE_REPO_PATH` cannot be an empty named volume. It must already contain a real writable Git
> clone, because SymphonyEx runs `git worktree add/remove` against that repo and Git writes
> metadata under `.git/worktrees` there.

```yaml
version: "3.8"

services:
  symphony:
    build: .
    restart: unless-stopped
    volumes:
      - ./WORKFLOW.md:/app/WORKFLOW.md:ro
      - worktrees:/opt/symphony/worktrees
      - /srv/my-repo:/opt/symphony/source-repo
    environment:
      - GITHUB_TOKEN=${GITHUB_TOKEN}
      - GITHUB_OWNER=${GITHUB_OWNER}
      - GITHUB_REPO=${GITHUB_REPO}
      - GITHUB_PROJECT_NUMBER=${GITHUB_PROJECT_NUMBER:-}
      - WORKSPACE_ROOT=/opt/symphony/worktrees
      - SOURCE_REPO_PATH=/opt/symphony/source-repo
      - SYMPHONY_DASHBOARD_ENABLED=true
      - SYMPHONY_DASHBOARD_PORT=4000
      - SYMPHONY_DASHBOARD_HOST=0.0.0.0
      - SYMPHONY_DASHBOARD_SECRET_KEY_BASE=replace-with-a-long-random-secret
      - SYMPHONY_LOG_FORMAT=json
    ports:
      - "4000:4000"

volumes:
  worktrees:
```

---

## systemd 배포

### /etc/systemd/system/symphony-ex.service

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

# If the dashboard is enabled in the env file, make sure
# SYMPHONY_DASHBOARD_SECRET_KEY_BASE is set there too.

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/opt/symphony/worktrees /opt/symphony/source-repo

[Install]
WantedBy=multi-user.target
```

### 설치 순서

```bash
# 1. Elixir release 빌드
MIX_ENV=prod mix release

# 2. 배포 디렉토리로 복사
sudo mkdir -p /opt/symphony-ex
sudo cp -r _build/prod/rel/symphony_ex/* /opt/symphony-ex/

# 3. source repo 준비 (git worktree metadata가 여기에도 기록됨)
sudo mkdir -p /opt/symphony
sudo git clone git@github.com:my-org/my-repo.git /opt/symphony/source-repo
sudo chown -R symphony:symphony /opt/symphony/source-repo

# 4. 환경변수 파일 생성
sudo cat > /opt/symphony-ex/.env << 'EOF'
GITHUB_TOKEN=ghp_xxx
GITHUB_OWNER=my-org
GITHUB_REPO=my-repo
WORKSPACE_ROOT=/opt/symphony/worktrees
# Must be a real writable clone, not an empty directory.
SOURCE_REPO_PATH=/opt/symphony/source-repo
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

---

## WORKFLOW.md 예시

```yaml
---
tracker:
  owner: my-org
  repo: my-repo
  project-number: 7
workspace:
  root: /opt/symphony/worktrees
  source-repo-path: /opt/symphony/source-repo
orchestrator:
  poll-interval-ms: 30000
  max-concurrent: 2
  max-retries: 3
codex:
  command: codex app-server
  stall-timeout-ms: 300000
---

You are an autonomous coding agent working on issue <%= issue.identifier %>: <%= issue.title %>

<%= issue.description %>

<%= if context_docs != "" do %>
## Context
<%= context_docs %>
<% end %>

## Instructions
1. Read the issue carefully
2. Make the required changes
3. Run tests if possible
4. Output your summary
```
