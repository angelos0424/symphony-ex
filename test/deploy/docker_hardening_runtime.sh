#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
image="${SYMPHONY_HARDENING_IMAGE:-symphony-ex:hardening}"
container="symphony-hardening-runtime-$$"
fixture="$(mktemp -d)"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
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
  printf "{}\n" > /fixture/auth.json
  printf "model = \"fixture\"\n" > /fixture/config.toml
  printf "must-not-copy\n" > /fixture/history.jsonl
  chown 10001:10001 /fixture/auth.json /fixture/config.toml
  chmod 0600 /fixture/auth.json /fixture/config.toml
  chmod 0644 /fixture/history.jsonl
'

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

docker run --rm \
  -v "$fixture/auth.json:/run/host-codex/auth.json:ro" \
  -v "$fixture/config.toml:/run/host-codex/config.toml:ro" \
  "$image" sh -c '
    test "$(id -u)" = 10001
    test "$(stat -c %a "$CODEX_HOME/auth.json")" = 600
    test "$(stat -c %a "$CODEX_HOME/config.toml")" = 600
    test ! -e "$CODEX_HOME/history.jsonl"
    test -w /srv/symphony/repo-a/worktrees
    test -w /srv/symphony/repo-a/source-cache
    test -w /var/lib/symphony/repo-a
  '

# Match Compose init:true: docker-init is PID 1 and BEAM is its live child.
docker run -d --name "$container" --init \
  --health-interval=1s --health-timeout=2s --health-start-period=1s --health-retries=5 \
  -e SYMPHONY_WORKFLOW_PATH=/app/workflows/repo-a.WORKFLOW.md \
  -e SOURCE_REPO_URL=file:///fixture-source \
  -e GITHUB_TRACKER_TOKEN=fixture-tracker \
  -e GITHUB_AGENT_TOKEN=fixture-agent \
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

printf 'health=healthy init=docker-init runtime_uid=10001 private_codex_inputs=pass\n'
