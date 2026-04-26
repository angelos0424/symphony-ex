# SymphonyEx Docker deployment templates

This directory now follows a **repo-per-compose-file** layout.
Each compose file declares its own project name so repo-a and repo-b can be started, stopped, and logged independently without sharing the same compose project/network lifecycle.

## Files

- `Dockerfile` — common SymphonyEx runtime image
- `docker-compose.repo-a.yml` — repo-a container (`holywords`)
- `docker-compose.repo-b.yml` — repo-b container (`cp` / `church_platform`)
- `.env.example` — compose interpolation values (copy to `.env`)
- `env/common.env.example` — shared runtime env template like `GITHUB_TOKEN` and logging
- `env/repo-a.env.example` — repo-a specific env template
- `env/repo-b.env.example` — repo-b specific env template
- `env/*.env` — local runtime env files copied from examples; ignored by git
- `workflows/repo-a.WORKFLOW.md` — repo-a workflow
- `workflows/repo-b.WORKFLOW.md` — repo-b workflow
- `ssh/config.example` — SSH config example for the mounted key directory

## Directory conventions

- repo-a always means `holywords`
- repo-b always means `cp` / `church_platform`
- compose files are intentionally split so `up`, `down`, and `logs` stay repo-scoped
- each compose file declares its own project name and its own named volumes
- each repo gets two persistent volumes:
  - `<repo>_worktrees`
  - `<repo>_source_cache`

## Repository mapping

- repo-a = `angelos0424/holywords`, GitHub Project `3`
- repo-b = `angelos0424/church_platform`, GitHub Project `4`
- repo-b short name = `cp`

## Operating defaults

- one container per repo
- one workflow per repo
- one worktree volume per repo
- one source-cache volume per repo
- `poll-interval-ms: 60000`
- `max-concurrent: 1`
- dashboard disabled
- GitHub API auth via `GITHUB_TOKEN`
- git clone/fetch auth via SSH (`git@github.com:...`)

## Authentication

SymphonyEx does **not** require `gh` inside the container.

1. **GitHub API**
   - set `GITHUB_TOKEN` in `env/common.env`

2. **Git transport**
   - mount a dedicated SSH directory read-only into `/root/.ssh`
   - that directory should contain `id_ed25519`, `known_hosts`, and optionally `config`

## First-time setup

```bash
cd deploy/docker
cp .env.example .env
cp env/common.env.example env/common.env
cp env/repo-a.env.example env/repo-a.env
cp env/repo-b.env.example env/repo-b.env
```

Set `GITHUB_TOKEN` in `env/common.env`. The local `env/*.env` files are intentionally ignored by git.
Set `SYMPHONY_SSH_DIR` in `.env` only if a repo uses SSH transport.

## Validate config

```bash
cd deploy/docker
docker compose --env-file .env -f docker-compose.repo-a.yml config
docker compose --env-file .env -f docker-compose.repo-b.yml config
```

## Run repo-a (holywords)

```bash
cd deploy/docker
docker compose --env-file .env -f docker-compose.repo-a.yml up -d
```

## Run repo-b (cp)

```bash
cd deploy/docker
docker compose --env-file .env -f docker-compose.repo-b.yml up -d
```

## Logs

```bash
cd deploy/docker
docker compose --env-file .env -f docker-compose.repo-a.yml logs -f
docker compose --env-file .env -f docker-compose.repo-b.yml logs -f
```

## Stop

```bash
cd deploy/docker
docker compose --env-file .env -f docker-compose.repo-a.yml down
docker compose --env-file .env -f docker-compose.repo-b.yml down
```
