#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

if ! command -v mise >/dev/null 2>&1; then
  echo "error: mise is required to run SymphonyEx" >&2
  exit 1
fi

cd "$REPO_ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

if [[ -z "${SYMPHONY_WORKFLOW_PATH:-}" && -z "${WORKFLOW_PATH:-}" && -f "$REPO_ROOT/WORKFLOW.md" ]]; then
  export SYMPHONY_WORKFLOW_PATH="$REPO_ROOT/WORKFLOW.md"
fi

exec mise exec -- mix run --no-halt "$@"
