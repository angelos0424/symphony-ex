# SymphonyEx Docker deployment templates

This directory follows a **repo-per-compose-file** layout.
Each compose file declares its own project name so repo-a, repo-b, and repo-c can be started, stopped, and logged independently.

## Files

- `Dockerfile` — common SymphonyEx runtime image
- `docker-compose.repo-a.yml` — repo-a container (`activities`)
- `docker-compose.repo-b.yml` — repo-b container (`cp` / `church_platform`)
- `docker-compose.repo-c.yml` — repo-c container (`saju-adult`)
- `.env.example` — compose interpolation values
- `env/common.env.example` — shared runtime env template
- `env/repo-a.env.example` — repo-a template
- `env/repo-b.env.example` — repo-b template
- `env/repo-c.env.example` — repo-c template
- `env/*.env` — ignored local runtime files
- `workflows/repo-a.WORKFLOW.md` — repo-a workflow
- `workflows/repo-b.WORKFLOW.md` — repo-b workflow
- `workflows/repo-c.WORKFLOW.md` — repo-c workflow

## Repository mapping

- repo-a = `angelos0424/activities`, GitHub Project `5`
- repo-b = `angelos0424/church_platform`, GitHub Project `4`
- repo-c = `angelos0424/saju-adult`, GitHub Project `7`

Each repo has independent worktree/source-cache volumes. Compose files remain repo-scoped for build, start, logs, and stop.

## Operating defaults

- dashboard disabled
- GitHub API and Project write-back via `GITHUB_TRACKER_TOKEN`
- Codex clone/push/PR auth via `GITHUB_AGENT_TOKEN`
- HTTPS source URL with token-based git transport
- repo-c: `poll-interval-ms: 300000`, `max-concurrent: 1`, `max-retries: 0`

## Dashboard security

Dashboard access is disabled by default in every Compose variant. If it is
enabled, keep the container bound to loopback and use a Tailscale or SSH
tunnel for remote inspection. A non-loopback bind requires Basic Auth via
`SYMPHONY_DASHBOARD_USERNAME` and `SYMPHONY_DASHBOARD_PASSWORD`, and browser
origins should be restricted with `SYMPHONY_DASHBOARD_ALLOWED_ORIGINS`.

Runtime settings and restart controls remain disabled unless
`SYMPHONY_DASHBOARD_CONTROLS_ENABLED=true` is explicitly configured. Do not
publish an unauthenticated `4000:4000` port.

## First-time setup

```bash
cd deploy/docker
cp .env.example .env
cp env/common.env.example env/common.env
cp env/repo-a.env.example env/repo-a.env
cp env/repo-b.env.example env/repo-b.env
cp env/repo-c.env.example env/repo-c.env
```

Set `GITHUB_TRACKER_TOKEN` and the repo-scoped `GITHUB_AGENT_TOKEN` in ignored
`env/common.env`. The entrypoint resolves only the agent token at Git
credential-helper runtime; it does not persist a token-bearing URL rewrite.
The tracker token remains in the orchestrator process and is never included in
the Codex environment. `GITHUB_TOKEN` is retained only as a warning-producing
one-release compatibility alias.

## Validate

```bash
cd deploy/docker
docker compose --env-file .env -f docker-compose.repo-a.yml config
docker compose --env-file .env -f docker-compose.repo-b.yml config
docker compose --env-file .env -f docker-compose.repo-c.yml config
```

## Run

```bash
cd deploy/docker
docker compose --env-file .env -f docker-compose.repo-c.yml up -d --build
```

Replace `repo-c` with `repo-a` or `repo-b` for the other isolated runners.

## Inspect

```bash
docker compose --env-file .env -f docker-compose.repo-c.yml ps
docker compose --env-file .env -f docker-compose.repo-c.yml logs -f
docker top symphony-repo-c -eo pid,lstart,cmd
```

## Stop

```bash
docker compose --env-file .env -f docker-compose.repo-c.yml down
```
