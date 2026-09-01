#!/bin/sh
set -eu

agent_token="${GITHUB_AGENT_TOKEN:-}"
if [ -z "$agent_token" ] && [ -z "${GITHUB_TRACKER_TOKEN:-}" ]; then
  agent_token="${GITHUB_TOKEN:-}"
fi

# Remove stale token-bearing configuration even when agent dispatch is blocked.
remove_legacy_git_auth_config() {
  config_file="${GIT_CONFIG_GLOBAL:-${HOME:?HOME must be set}/.gitconfig}"

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
      printf "%s\n" "$line" >> "$temp_config"
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
        printf "%s\n" \
          "protocol=https" \
          "host=github.com" \
          "username=x-access-token" \
          "password=$token"
      fi
    }; f'
fi

codex_home="${CODEX_HOME:-${HOME:?HOME must be set}/.codex}"
mkdir -p "$codex_home"
chmod 700 "$codex_home"

# Stage an explicit allowlist. Never copy the host Codex directory recursively.
rm -f "$codex_home/auth.json" "$codex_home/config.toml"
if [ -f /run/host-codex/auth.json ]; then
  install -m 0600 /run/host-codex/auth.json "$codex_home/auth.json"
fi
if [ -f /run/host-codex/config.toml ]; then
  install -m 0600 /run/host-codex/config.toml "$codex_home/config.toml"
fi

if [ -n "${CODEX_MODEL:-}" ] && [ -f "$codex_home/config.toml" ]; then
  escaped_model="$(printf '%s' "$CODEX_MODEL" | sed 's/[\\&|]/\\&/g')"
  sed -i "s|^model = .*|model = \"${escaped_model}\"|" "$codex_home/config.toml"
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

exec /app/bin/symphony_ex start
