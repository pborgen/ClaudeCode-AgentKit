#!/usr/bin/env bash
# Cron entrypoint for pr-fixer. Activates the venv, loads secrets, runs one tick.
# Designed to be safe to invoke every N minutes from crontab.
set -euo pipefail

# Resolve the agent root (this script lives in <root>/deploy/).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

# Load secrets (ANTHROPIC_API_KEY, GH_TOKEN) from .env if present.
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

# Activate the venv created by install.sh.
if [[ -f "$ROOT/.venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/.venv/bin/activate"
fi

export PR_FIXER_CONFIG="${PR_FIXER_CONFIG:-$ROOT/config.yaml}"

exec python -m pr_fixer "$@"
