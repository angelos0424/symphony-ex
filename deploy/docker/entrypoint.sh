#!/bin/sh
set -eu

agent_token="${GITHUB_AGENT_TOKEN:-}"
if [ -z "$agent_token" ] && [ -z "${GITHUB_TRACKER_TOKEN:-}" ]; then
  agent_token="${GITHUB_TOKEN:-}"
fi

if [ -n "$agent_token" ]; then
  # Remove URL rewrites from older images without exposing their token value.
  git config --global --unset-regexp \
    '^url\.https://x-access-token:.*@github\.com/\.insteadOf$' 2>/dev/null || true
  git config --global --unset-all credential.helper 2>/dev/null || true
  # Resolve the token at credential-helper runtime, not while configuring Git.
  git config --global credential.helper \
    '!f() {
      if [ "$1" = get ]; then
        token="${GITHUB_AGENT_TOKEN:-}"
        if [ -z "$token" ] && [ -z "${GITHUB_TRACKER_TOKEN:-}" ]; then
          token="${GITHUB_TOKEN:-}"
        fi
        printf "%s\\n" \
          "protocol=https" \
          "host=github.com" \
          "username=x-access-token" \
          "password=$token"
      fi
    }; f'
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
