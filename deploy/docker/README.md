# SymphonyEx Docker deployment templates

This directory uses one Compose project per repository. The three variants share
the same hardened image but keep workflows, worktrees, source caches, and Codex
runtime-state volumes isolated.

## Security and resource defaults

Every variant:

- runs as image user `symphony` (UID/GID `10001` by default), never root;
- sets `no-new-privileges`, drops all Linux capabilities, and bounds the
  container to 256 PIDs, 1 CPU, and 2 GiB memory;
- uses the image's dashboard-independent BEAM liveness healthcheck;
- mounts only host Codex `auth.json` and `config.toml`, read-only, then stages
  private copies in `/home/symphony/.codex`;
- uses independent writable worktree, source-cache, and Codex-state volumes; and
- defaults Codex `thread-sandbox` to `workspaceWrite`.

`dangerFullAccess` is not a global toggle. If one repository genuinely requires
it, change only that repository's tracked workflow after documenting the reason,
paths affected, compensating controls, and rollback. Keep the other workflows on
`workspaceWrite`.

## Files and repository mapping

- `Dockerfile` / `entrypoint.sh` — common hardened runtime
- `docker-compose.repo-a.yml` — `angelos0424/activities`, Project 5
- `docker-compose.repo-b.yml` — `angelos0424/church_platform`, Project 4
- `docker-compose.repo-c.yml` — `angelos0424/saju-adult`, Project 7
- `.env.example` — host-side Compose interpolation, including Codex input path
- `env/*.env.example` — tracked runtime templates; `env/*.env` stays ignored
- `workflows/*.WORKFLOW.md` — repository-scoped policy and prompt

Dashboard access remains disabled by default. If enabled, publish only a
loopback host port and use a tunnel or authenticated reverse proxy. Non-loopback
binding requires Basic Auth and restricted allowed origins. Runtime controls
remain a separate explicit opt-in.

## First-time setup

```bash
cd deploy/docker
cp .env.example .env
cp env/common.env.example env/common.env
cp env/repo-a.env.example env/repo-a.env
cp env/repo-b.env.example env/repo-b.env
cp env/repo-c.env.example env/repo-c.env
```

Do not bind the original host `~/.codex` files directly. A mode `0600` file
owned by the host login is intentionally unreadable to container UID 10001.
Stage private copies owned by the runtime UID, then point `SYMPHONY_CODEX_HOME`
in `.env` at that directory. Compose binds only these two files and never
exposes the rest of the host Codex tree:

```bash
sudo install -d -o 10001 -g 10001 -m 0700 /var/lib/symphony/codex
sudo install -o 10001 -g 10001 -m 0600 \
  "$HOME/.codex/auth.json" /var/lib/symphony/codex/auth.json

if [ -f "$HOME/.codex/config.toml" ]; then
  sudo install -o 10001 -g 10001 -m 0600 \
    "$HOME/.codex/config.toml" /var/lib/symphony/codex/config.toml
else
  sudo install -o 10001 -g 10001 -m 0600 \
    /dev/null /var/lib/symphony/codex/config.toml
fi

printf 'SYMPHONY_CODEX_HOME=/var/lib/symphony/codex\n' > .env
```

Never make credential inputs group/world-readable. Compose uses long bind syntax
with `create_host_path: false`, so a missing input fails instead of becoming a
root-owned directory. The entrypoint also rejects missing, wrong-type, or
unreadable auth inputs before boot.

Each repository has a persistent `/home/symphony/.codex` named volume. The
staged files seed an empty volume; normal restarts and recreates preserve a
runtime-refreshed `auth.json` instead of overwriting it with a stale staged copy.
To intentionally replace a persisted copy after updating the host staging file,
run a one-shot forced seed for that repository, then recreate it:

```bash
docker compose --env-file .env -f docker-compose.repo-a.yml run --rm \
  -e SYMPHONY_CODEX_FORCE_SEED=true symphony-repo-a true
docker compose --env-file .env -f docker-compose.repo-a.yml up -d --force-recreate
```

Replace `repo-a` as needed. Before deleting or restoring a Codex-state volume,
copy its current runtime `auth.json` back to the private staging path with
`docker cp` plus `sudo install -o 10001 -g 10001 -m 0600`; never print it or
write it to logs. A deleted empty volume is reseeded from the staged files.

Set `GITHUB_TRACKER_TOKEN` and the repo-scoped `GITHUB_AGENT_TOKEN` in ignored
`env/common.env`. The entrypoint resolves only the agent token at Git credential
helper runtime and does not persist a token-bearing URL. The tracker token stays
with the orchestrator and is excluded from Codex's allowlisted environment. The
legacy `GITHUB_TOKEN` remains a one-release compatibility alias only.

## Existing root-owned volume migration

A non-root entrypoint cannot safely repair root-owned mounts. Stop all three
projects and back up named volumes before the one-time migration. Confirm the
actual names with `docker volume ls`; the defaults below follow the Compose
project names.

```bash
cd deploy/docker
docker compose -f docker-compose.repo-a.yml down
docker compose -f docker-compose.repo-b.yml down
docker compose -f docker-compose.repo-c.yml down

docker build -t symphony-ex:hardening -f Dockerfile ../..

for repo in a b c; do
  docker run --rm --user 0 --entrypoint sh \
    -v "symphony-repo-${repo}_repo_${repo}_worktrees:/mnt/worktrees" \
    -v "symphony-repo-${repo}_repo_${repo}_source_cache:/mnt/source-cache" \
    symphony-ex:hardening -c \
    'chown -R 10001:10001 /mnt/worktrees /mnt/source-cache'
done
```

This is an operator-run migration, not a normal startup mode. Do not add root,
`CAP_CHOWN`, or a privileged entrypoint to avoid it.

Rollback preserves data: stop the hardened containers, restore the volume
backup, and redeploy the previous image. UID 0 can read UID 10001-owned files;
only if the previous runtime explicitly requires root ownership, reverse the
ownership after backing up by rerunning the loop with
`chown -R 0:0 ...`. Never roll back by restoring broad capabilities or mounting
the whole host Codex directory.

Application breadcrumbs currently live under the worktree volume; there is no
separate `SYMPHONY_STATE_ROOT` runtime contract yet. Durable orchestrator state
remains a later persistence milestone and must not be inferred from Compose.

## Validate and run

```bash
cd deploy/docker
docker compose --env-file .env.example -f docker-compose.repo-a.yml config
docker compose --env-file .env.example -f docker-compose.repo-b.yml config
docker compose --env-file .env.example -f docker-compose.repo-c.yml config

docker compose --env-file .env -f docker-compose.repo-c.yml up -d --build
docker compose --env-file .env -f docker-compose.repo-c.yml ps
docker compose --env-file .env -f docker-compose.repo-c.yml logs -f
```

Replace `repo-c` with `repo-a` or `repo-b` as needed.

The immutable release disables tzdata's in-place updater because `/app` is
read-only to the runtime user. Rebuild the image after tzdata/IANA database
updates (and at least on the normal monthly dependency-refresh cadence), verify
night-worker timezone windows in staging, and deploy the rebuilt image. Do not
re-enable runtime writes under `/app` as a freshness workaround.

## Liveness versus readiness

Docker `HEALTHCHECK` scans `/proc` for a live BEAM runtime. This remains correct
when Compose `init: true` makes `docker-init` PID 1, does not use Phoenix, and
works when the dashboard is disabled. A `healthy` container therefore means
**process live**, not **tracker ready**.

Tracker-freshness readiness is an operator-level condition: require a recent
successful GitHub poll within the repository's configured poll interval plus an
allowed grace period, no current auth/rate-limit error, and successful source
access. Until a stable readiness endpoint is introduced, verify this from
structured logs and GitHub Project state. Do not put tracker network access or
credentials in Docker `HEALTHCHECK`, and do not route it through the optional
dashboard.

## Stop

```bash
cd deploy/docker
docker compose --env-file .env -f docker-compose.repo-c.yml down
```
