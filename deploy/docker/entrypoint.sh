#!/bin/sh
set -eu

agent_token="${GITHUB_AGENT_TOKEN:-}"
if [ -z "$agent_token" ] && [ -z "${GITHUB_TRACKER_TOKEN:-}" ]; then
  agent_token="${GITHUB_TOKEN:-}"
fi

# Remove stale token-bearing configuration even when agent dispatch is blocked.
remove_legacy_git_auth_config() {
  config_file="${GIT_CONFIG_GLOBAL:-${HOME:-/root}/.gitconfig}"

  if [ ! -f "$config_file" ]; then
    return 0
  fi

  temp_config="$(mktemp "${config_file}.tmp.XXXXXX")"
  in_token_url_section=0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '[url "https://x-access-token:'*'@github.com/"]')
        in_token_url_section=1
        continue
        ;;
      \[*\])
        in_token_url_section=0
        ;;
    esac

    if [ "$in_token_url_section" -eq 0 ]; then
      printf "%s\\n" "$line" >> "$temp_config"
    fi
  done < "$config_file"

  if ! cmp -s "$config_file" "$temp_config"; then
    chmod 600 "$temp_config"
    mv "$temp_config" "$config_file"
  else
    rm -f "$temp_config"
  fi
}

remove_legacy_git_auth_config
git config --global --unset-all credential.helper 2>/dev/null || true

if [ -n "$agent_token" ]; then
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
