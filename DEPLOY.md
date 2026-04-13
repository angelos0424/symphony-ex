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
| `GITHUB_TOKEN` | GitHub Personal Access Token (`repo`, `project` 권한) | `ghp_xxx` |
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
| `SYMPHONY_DASHBOARD_SECRET_KEY_BASE` | Phoenix 세션/서명용 secret. 대시보드 활성화 시 필수 | 없음 |

> [!IMPORTANT]
> 대시보드를 켜면 `SYMPHONY_DASHBOARD_SECRET_KEY_BASE`도 반드시 설정해야 합니다.

### 로깅

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `SYMPHONY_LOG_FORMAT` | 로그 포맷 (`pretty` / `json`) | `pretty` |
| `SYMPHONY_LOG_LEVEL` | 로그 레벨 | `info` |
| `SYMPHONY_LOG_REDACT_KEYS` | 민감 키 redaction (쉼표 구분) | (없음) |
| `SYMPHONY_LOG_MAX_METADATA_VALUE_LENGTH` | 메타데이터 값 최대 길이 | (무제한) |

## Docker Compose 배포

```dockerfile
FROM hexpm/elixir:1.19.0-erlang-28.0-debian-bookworm-20240612 AS build

WORKDIR /app
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib/
COPY config config/
COPY priv priv/
COPY WORKFLOW.md ./
RUN mix compile
RUN mix release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y git openssh-client && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/_build/prod/rel/symphony_ex ./

ENV LANG=en_US.UTF-8
CMD ["bin/symphony_ex", "start"]
```

```yaml
version: "3.8"

services:
  symphony:
    build: .
    restart: unless-stopped
    volumes:
      - ./WORKFLOW.md:/app/WORKFLOW.md:ro
      - worktrees:/opt/symphony/worktrees
      - source-cache:/opt/symphony/source-cache
    environment:
      - GITHUB_TOKEN=${GITHUB_TOKEN}
      - GITHUB_OWNER=${GITHUB_OWNER}
      - GITHUB_REPO=${GITHUB_REPO}
      - GITHUB_PROJECT_NUMBER=${GITHUB_PROJECT_NUMBER:-}
      - WORKSPACE_ROOT=/opt/symphony/worktrees
      - SOURCE_REPO_URL=git@github.com:my-org/my-repo.git
      - SOURCE_CACHE_ROOT=/opt/symphony/source-cache
      - SYMPHONY_DASHBOARD_ENABLED=true
      - SYMPHONY_DASHBOARD_PORT=4000
      - SYMPHONY_DASHBOARD_HOST=0.0.0.0
      - SYMPHONY_DASHBOARD_SECRET_KEY_BASE=replace-with-a-long-random-secret
      - SYMPHONY_LOG_FORMAT=json
    ports:
      - "4000:4000"

volumes:
  worktrees:
  source-cache:
```

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
GITHUB_TOKEN=ghp_xxx
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
workspace:
  root: /opt/symphony/worktrees
  source-repo-url: git@github.com:my-org/my-repo.git
  source-cache-root: /opt/symphony/source-cache
orchestrator:
  poll-interval-ms: 30000
  max-concurrent: 1
  max-retries: 3
codex:
  command: codex app-server
  stall-timeout-ms: 300000
dashboard:
  enabled: true
  secret-key-base: replace-with-a-long-random-secret
---
```
