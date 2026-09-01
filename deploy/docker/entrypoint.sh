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
auth_source=/run/host-codex/auth.json
config_source=/run/host-codex/config.toml
force_seed="${SYMPHONY_CODEX_FORCE_SEED:-false}"

if [ ! -e "$auth_source" ]; then
  echo "Codex auth input is required at $auth_source" >&2
  exit 1
fi
if [ ! -f "$auth_source" ] || [ -L "$auth_source" ]; then
  echo "Codex auth input must be a regular file" >&2
  exit 1
fi
if [ ! -r "$auth_source" ]; then
  echo "Codex auth input is not readable by runtime UID $(id -u); stage a private UID-compatible copy" >&2
  exit 1
fi

if [ -e "$codex_home/auth.json" ] && { [ ! -f "$codex_home/auth.json" ] || [ -L "$codex_home/auth.json" ]; }; then
  echo "Runtime Codex auth destination must be a regular file" >&2
  exit 1
fi
if [ ! -f "$codex_home/auth.json" ] || [ "$force_seed" = true ]; then
  install -m 0600 "$auth_source" "$codex_home/auth.json"
fi

if [ -e "$config_source" ]; then
  if [ ! -f "$config_source" ] || [ -L "$config_source" ]; then
    echo "Codex config input must be a regular file" >&2
    exit 1
  fi
  if [ ! -r "$config_source" ]; then
    echo "Codex config input is not readable by runtime UID $(id -u); stage a private UID-compatible copy" >&2
    exit 1
  fi
  if [ -e "$codex_home/config.toml" ] && { [ ! -f "$codex_home/config.toml" ] || [ -L "$codex_home/config.toml" ]; }; then
    echo "Runtime Codex config destination must be a regular file" >&2
    exit 1
  fi
  if [ ! -f "$codex_home/config.toml" ] || [ "$force_seed" = true ]; then
    install -m 0600 "$config_source" "$codex_home/config.toml"
  fi
fi

if [ -n "${CODEX_MODEL:-}" ] && [ -f "$codex_home/config.toml" ]; then
  escaped_model="$(printf '%s' "$CODEX_MODEL" | sed 's/[\\&|]/\\&/g')"
  sed -i "s|^model = .*|model = \"${escaped_model}\"|" "$codex_home/config.toml"
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

exec /app/bin/symphony_ex start
