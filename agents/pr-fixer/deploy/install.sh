#!/usr/bin/env bash
# One-time setup for pr-fixer on a host (EC2 or local).
# Creates a venv, installs the package, and prints the crontab line to add.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

PYTHON="${PYTHON:-python3}"

echo "==> Creating venv at $ROOT/.venv"
"$PYTHON" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate

echo "==> Installing pr-fixer + dependencies"
pip install --quiet --upgrade pip
pip install --quiet -e .

# Preflight: external CLIs the agent shells out to.
command -v gh  >/dev/null || echo "WARN: 'gh' (GitHub CLI) not found on PATH — required."
command -v git >/dev/null || echo "WARN: 'git' not found on PATH — required."

if [[ ! -f "$ROOT/config.yaml" ]]; then
  echo "==> Creating config.yaml from example (edit it before first run)"
  cp config.example.yaml config.yaml
fi
if [[ ! -f "$ROOT/.env" ]]; then
  echo "==> Creating .env from example (add your keys)"
  cp .env.example .env
  chmod 600 .env
fi

chmod +x "$HERE/run.sh"

cat <<EOF

==> Done.

Next:
  1. Edit $ROOT/config.yaml      (your repos + caps)
  2. Edit $ROOT/.env             (ANTHROPIC_API_KEY, GH_TOKEN)  — or run 'gh auth login'
  3. Test once (no pushes):      $HERE/run.sh --dry-run
  4. Add to crontab (every 15m): crontab -e, then add:

     */15 * * * * $HERE/run.sh >> $ROOT/pr-fixer.log 2>&1

EOF
