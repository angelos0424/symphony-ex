#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
image="${SYMPHONY_HARDENING_IMAGE:-symphony-ex:hardening}"
container="symphony-hardening-runtime-$$"
codex_volume="symphony-hardening-codex-$$"
fixture="$(mktemp -d)"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$codex_volume" >/dev/null 2>&1 || true
  if [ -d "$fixture" ]; then
    docker run --rm --user 0 --entrypoint sh \
      -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
      -v "$fixture:/fixture" "$image" \
      -c 'chown -R "$HOST_UID:$HOST_GID" /fixture' >/dev/null 2>&1 || true
    rm -rf "$fixture"
  fi
}
trap cleanup EXIT INT TERM

docker build --load -t "$image" -f "$repo_root/deploy/docker/Dockerfile" "$repo_root"
docker image inspect "$image" --format '{{json .Config.User}} {{json .Config.Healthcheck}}' |
  grep -q 'symphony:symphony'

# Create private host-side inputs owned by the runtime UID. They remain mode 0600.
docker run --rm --user 0 --entrypoint sh -v "$fixture:/fixture" "$image" -c '
  printf "{}\n" > /fixture/unreadable-auth.json
  chown 0:0 /fixture/unreadable-auth.json
  chmod 0600 /fixture/unreadable-auth.json
  printf "seed-auth\n" > /fixture/auth.json
  printf "model = \"fixture\"\n" > /fixture/config.toml
  printf "must-not-copy\n" > /fixture/history.jsonl
  chown 10001:10001 /fixture/auth.json /fixture/config.toml
  chmod 0600 /fixture/auth.json /fixture/config.toml
  chmod 0644 /fixture/history.jsonl
'

if docker run --rm "$image" true >"$fixture/missing.log" 2>&1; then
  echo "expected missing credential input to fail" >&2
  exit 1
fi
grep -q 'Codex auth input is required' "$fixture/missing.log"

if docker run --rm \
  -v "$fixture:/run/host-codex/auth.json:ro" \
  "$image" true >"$fixture/wrong-type.log" 2>&1; then
  echo "expected wrong-type credential input to fail" >&2
  exit 1
fi
grep -q 'Codex auth input must be a regular file' "$fixture/wrong-type.log"

if docker run --rm \
  -v "$fixture/unreadable-auth.json:/run/host-codex/auth.json:ro" \
  "$image" true >"$fixture/unreadable.log" 2>&1; then
  echo "expected unreadable credential input to fail" >&2
  exit 1
fi
grep -q 'not readable by runtime UID 10001' "$fixture/unreadable.log"

printf 'mode=%s uid=%s gid=%s\n' \
  "$(stat -c %a "$fixture/auth.json")" \
  "$(stat -c %u "$fixture/auth.json")" \
  "$(stat -c %g "$fixture/auth.json")"

docker volume create "$codex_volume" >/dev/null

# First startup seeds the private volume, then simulate a Codex OAuth refresh.
docker run --rm \
  -v "$fixture/auth.json:/run/host-codex/auth.json:ro" \
  -v "$fixture/config.toml:/run/host-codex/config.toml:ro" \
  -v "$codex_volume:/home/symphony/.codex" \
  "$image" sh -c '
    test "$(id -u)" = 10001
    test "$(stat -c %a "$CODEX_HOME/auth.json")" = 600
    test "$(stat -c %a "$CODEX_HOME/config.toml")" = 600
    grep -q seed-auth "$CODEX_HOME/auth.json"
    test ! -e "$CODEX_HOME/history.jsonl"
    printf "runtime-refreshed-auth\n" > "$CODEX_HOME/auth.json"
  '

# A normal restart/recreate must preserve the runtime-refreshed credential.
docker run --rm \
  -v "$fixture/auth.json:/run/host-codex/auth.json:ro" \
  -v "$fixture/config.toml:/run/host-codex/config.toml:ro" \
  -v "$codex_volume:/home/symphony/.codex" \
  "$image" sh -c 'grep -q runtime-refreshed-auth "$CODEX_HOME/auth.json"'

# Explicit force seeding is the only path that replaces the persisted runtime copy.
docker run --rm --user 0 --entrypoint sh -v "$fixture:/fixture" "$image" -c '
  printf "operator-reseed-auth\n" > /fixture/auth.json
  chown 10001:10001 /fixture/auth.json
  chmod 0600 /fixture/auth.json
'
docker run --rm -e SYMPHONY_CODEX_FORCE_SEED=true \
  -v "$fixture/auth.json:/run/host-codex/auth.json:ro" \
  -v "$fixture/config.toml:/run/host-codex/config.toml:ro" \
  -v "$codex_volume:/home/symphony/.codex" \
  "$image" sh -c 'grep -q operator-reseed-auth "$CODEX_HOME/auth.json"'

# Match Compose init:true: docker-init is PID 1 and BEAM is its live child.
docker run -d --name "$container" --init \
  --health-interval=1s --health-timeout=2s --health-start-period=1s --health-retries=5 \
  -e SYMPHONY_WORKFLOW_PATH=/app/workflows/repo-a.WORKFLOW.md \
  -e SOURCE_REPO_URL=file:///fixture-source \
  -e GITHUB_TRACKER_TOKEN=fixture-tracker \
  -e GITHUB_AGENT_TOKEN=fixture-agent \
  -v "$fixture/auth.json:/run/host-codex/auth.json:ro" \
  -v "$fixture/config.toml:/run/host-codex/config.toml:ro" \
  -v "$codex_volume:/home/symphony/.codex" \
  -v "$repo_root/deploy/docker/workflows/repo-a.WORKFLOW.md:/app/workflows/repo-a.WORKFLOW.md:ro" \
  -v "$repo_root:/fixture-source:ro" \
  "$image" >/dev/null

status=starting
for _ in $(seq 1 20); do
  status="$(docker inspect --format '{{.State.Health.Status}}' "$container")"
  [ "$status" = healthy ] && break
  [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || break
  sleep 1
done

[ "$(docker exec "$container" cat /proc/1/comm)" = docker-init ]
[ "$status" = healthy ]
logs="$(docker logs "$container" 2>&1 || true)"
if printf '%s' "$logs" | grep -Eqi 'tzdata_release_updater|permission denied|eacces'; then
  printf '%s\n' "$logs" >&2
  exit 1
fi

printf 'health=healthy init=docker-init runtime_uid=10001 private_codex_inputs=pass refresh_preserved=pass\n'
