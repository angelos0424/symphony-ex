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
- GitHub API auth via `GITHUB_TOKEN`
- HTTPS source URL with token-based git transport
- repo-c: `poll-interval-ms: 300000`, `max-concurrent: 1`, `max-retries: 0`

## First-time setup

```bash
cd deploy/docker
cp .env.example .env
cp env/common.env.example env/common.env
cp env/repo-a.env.example env/repo-a.env
cp env/repo-b.env.example env/repo-b.env
cp env/repo-c.env.example env/repo-c.env
```

Set `GITHUB_TOKEN` in ignored `env/common.env`. Host Codex state is mounted read-only and copied into the runtime home by the entrypoint.

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
