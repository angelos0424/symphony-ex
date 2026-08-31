#!/bin/sh
set -eu

agent_token="${GITHUB_AGENT_TOKEN:-}"
if [ -z "$agent_token" ] && [ -z "${GITHUB_TRACKER_TOKEN:-}" ]; then
  agent_token="${GITHUB_TOKEN:-}"
fi

if [ -n "$agent_token" ]; then
  git config --global url."https://x-access-token:${agent_token}@github.com/".insteadOf "https://github.com/"
fi

if [ -d /run/host-codex ]; then
  rm -rf /root/.codex
  mkdir -p /root/.codex
  cp -a /run/host-codex/. /root/.codex/
  find /root/.codex -type d -exec chmod u+rwx {} +
  find /root/.codex -type f -name 'auth.json' -exec chmod 600 {} +
fi

if [ -n "${CODEX_MODEL:-}" ] && [ -f /root/.codex/config.toml ]; then
  sed -i "s/^model = .*/model = \"${CODEX_MODEL}\"/" /root/.codex/config.toml
fi

exec /app/bin/symphony_ex start
