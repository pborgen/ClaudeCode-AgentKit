#!/usr/bin/env bash
# Grant Claude Code permissions by merging allow-rules into a settings.json.
# Lets Claude run common commands without prompting — handy on a fresh box.
#
#   scripts/grant-permissions.sh                       # apply the curated default set
#   scripts/grant-permissions.sh 'Bash(npm *)' 'Bash(git push *)'
#   scripts/grant-permissions.sh --project 'Bash(make *)'   # write .claude/settings.json (cwd)
#   scripts/grant-permissions.sh --file ~/x/settings.json 'Read(*)'
#   scripts/grant-permissions.sh --list                # show effective allow-list, no changes
#
# Rules use Claude Code's permission syntax, e.g. Bash(git *), Read(*), Edit(*).
# Merges into .permissions.allow: existing settings are preserved, dupes dropped.
# Default target: ~/.claude/settings.json   Override: --project | --file <path>
set -euo pipefail

command -v jq >/dev/null || { echo "jq is required (brew install jq / apt-get install jq)" >&2; exit 1; }

# Curated default set: routine, low-risk commands Claude shouldn't have to ask about.
DEFAULTS=(
  'Bash(git status *)'
  'Bash(git diff *)'
  'Bash(git log *)'
  'Bash(git add *)'
  'Bash(git commit *)'
  'Bash(git checkout *)'
  'Bash(git branch *)'
  'Bash(git pull *)'
  'Bash(git push *)'
  'Bash(git merge *)'
  'Bash(git fetch *)'
  'Bash(git stash *)'
  'Bash(ls *)'
  'Bash(cat *)'
  'Bash(grep *)'
  'Bash(rg *)'
  'Bash(find *)'
  'Bash(mkdir *)'
  'Bash(npm install *)'
  'Bash(npm run *)'
  'Bash(npm test *)'
  'Bash(pnpm *)'
  'Bash(node *)'
  'Bash(gh pr view *)'
  'Bash(gh pr list *)'
  'Bash(gh run view *)'
)

TARGET="$HOME/.claude/settings.json"
LIST_ONLY=0
RULES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --project)        TARGET="$PWD/.claude/settings.json"; shift ;;
    --file)           TARGET="${2:?--file needs a path}"; shift 2 ;;
    --list)           LIST_ONLY=1; shift ;;
    -h|--help)        grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do RULES+=("$1"); shift; done ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  RULES+=("$1"); shift ;;
  esac
done

[ "${#RULES[@]}" -eq 0 ] && RULES=("${DEFAULTS[@]}")

if [ "$LIST_ONLY" -eq 1 ]; then
  if [ -f "$TARGET" ]; then
    jq -r '.permissions.allow[]? // empty' "$TARGET"
  else
    echo "(no file yet at $TARGET)"
  fi
  exit 0
fi

mkdir -p "$(dirname "$TARGET")"
[ -f "$TARGET" ] || echo '{}' > "$TARGET"

# Bail early on a malformed file rather than clobbering it.
jq empty "$TARGET" 2>/dev/null || { echo "Not valid JSON: $TARGET" >&2; exit 1; }

before="$(jq '(.permissions.allow // []) | length' "$TARGET")"

# Merge: union existing allow-list with new rules, drop dupes, keep sorted.
tmp="$(mktemp)"
jq -n \
  --slurpfile cur "$TARGET" \
  --slurpfile new <(printf '%s\n' "${RULES[@]}" | jq -R .) \
  '
  ($cur[0] // {})
  | .permissions = (.permissions // {})
  | .permissions.allow = (((.permissions.allow // []) + $new) | unique)
  ' > "$tmp"
mv "$tmp" "$TARGET"

after="$(jq '.permissions.allow | length' "$TARGET")"
echo "Updated $TARGET  (allow: $before -> $after rules)"
