#!/usr/bin/env bash
# AgentKit — an interactive setup wizard for ClaudeCode-AgentKit.
#
# Walks you through the things you can turn on in this repo:
#   - Permissions: edit .claude/settings.json (e.g. grant full permissions)
#   - Settings inspector: see every Claude Code settings scope (global, project,
#     local, enterprise-managed) and how the same key resolves across them
#   - EC2 dev box: configure + deploy the Tailscale-reachable box (Terraform)
#   - EC2 dev box: control it (start / stop / ssh / status)
#   - Remote Terraform state: stand up an S3 backend
#   - Doctor: check that the prerequisites are installed
#
# Run it with no arguments for the menu, or jump straight to a section:
#   scripts/agentkit.sh                 # interactive menu
#   scripts/agentkit.sh permissions
#   scripts/agentkit.sh settings [report|full|json]   # inspect CC settings
#   scripts/agentkit.sh deploy
#   scripts/agentkit.sh box [start|stop|ssh|status]
#   scripts/agentkit.sh state
#   scripts/agentkit.sh doctor
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform/ec2-dev"
SETTINGS="$ROOT/.claude/settings.json"
BOX="$ROOT/scripts/box.sh"
BOOTSTRAP="$ROOT/scripts/bootstrap-state.sh"

# ---- pretty output --------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YEL=$'\033[33m'; BLU=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GRN=''; YEL=''; BLU=''; RST=''
fi
say()  { printf '%s\n' "$*"; }
head() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RST"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '%s✗%s %s\n' "$RED" "$RST" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# ask "Prompt" "default"  -> echoes the answer (default on empty)
ask() {
  local prompt="$1" def="${2:-}" ans
  if [ -n "$def" ]; then
    read -r -p "$prompt [$def]: " ans </dev/tty || true
    printf '%s' "${ans:-$def}"
  else
    read -r -p "$prompt: " ans </dev/tty || true
    printf '%s' "$ans"
  fi
}
# ask_secret "Prompt" -> echoes a hidden answer
ask_secret() {
  local prompt="$1" ans
  read -r -s -p "$prompt: " ans </dev/tty || true
  printf '\n' >&2
  printf '%s' "$ans"
}
# confirm "Question" -> returns 0 on yes
confirm() {
  local ans
  read -r -p "$1 [y/N]: " ans </dev/tty || true
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

pause() { read -r -p $'\nPress Enter to continue…' _ </dev/tty || true; }

# trunc "string" [width] -> string clipped to width with an ellipsis
trunc() {
  local s="$1" n="${2:-90}"
  if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$n}"; else printf '%s' "$s"; fi
}

# =====================================================================
# Doctor — prerequisite checks
# =====================================================================
check_tool() {
  local name="$1" hint="$2"
  if have "$name"; then ok "$name $(command -v "$name" | sed "s|$HOME|~|")"
  else warn "$name not found — $hint"; return 1; fi
}

doctor() {
  head "Doctor — checking prerequisites"
  local missing=0
  check_tool aws       "AWS CLI, needed to deploy/control the box: https://aws.amazon.com/cli/" || missing=1
  check_tool terraform "Terraform ≥1.5, needed to deploy: brew install terraform"               || missing=1
  check_tool jq        "jq, used to edit settings.json safely: brew install jq"                  || missing=1
  check_tool ssh       "OpenSSH client, to connect to the box"                                   || missing=1

  if have aws; then
    if aws sts get-caller-identity >/dev/null 2>&1; then
      local who; who="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
      ok "AWS credentials work: $who"
    else
      warn "AWS CLI is installed but no working credentials — run: aws configure"
      missing=1
    fi
  fi

  if have tailscale && tailscale status >/dev/null 2>&1; then
    ok "Tailscale is up on this machine"
  else
    warn "Tailscale not detected on this machine (only needed to SSH to the box)"
  fi

  [ -f "$SETTINGS" ] && ok "Found $SETTINGS" || warn "No .claude/settings.json yet (created on demand)"
  echo
  if [ "$missing" -eq 0 ]; then ok "All core tools present."
  else warn "Some tools/credentials are missing — see notes above."; fi
}

# =====================================================================
# Permissions — edit .claude/settings.json
# =====================================================================
ensure_settings() {
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || printf '{\n  "permissions": {\n    "allow": []\n  }\n}\n' > "$SETTINGS"
}

# Apply a jq program to settings.json in place (with a .bak backup).
jq_edit() {
  if ! have jq; then err "jq is required to edit settings.json safely (brew install jq)."; return 1; fi
  ensure_settings
  local tmp; tmp="$(mktemp)"
  if jq "$@" "$SETTINGS" > "$tmp"; then
    cp "$SETTINGS" "$SETTINGS.bak"
    mv "$tmp" "$SETTINGS"
  else
    rm -f "$tmp"; err "Failed to edit settings.json (left unchanged)."; return 1
  fi
}

set_mode() {
  local mode="$1"
  jq_edit --arg m "$mode" '.permissions = (.permissions // {}) | .permissions.defaultMode = $m' \
    && ok "permissions.defaultMode = $mode  (backup at settings.json.bak)"
}

permissions_menu() {
  while true; do
    head "Permissions — .claude/settings.json"
    say "  Default permission mode controls how much Claude can do without asking."
    if have jq && [ -f "$SETTINGS" ]; then
      local cur; cur="$(jq -r '.permissions.defaultMode // "default"' "$SETTINGS" 2>/dev/null || echo default)"
      say "  ${DIM}Current defaultMode: ${cur}${RST}"
    fi
    cat <<EOF

  1) ${BOLD}Full permissions${RST}  — bypassPermissions (Claude won't ask; ${RED}use with care${RST})
  2) Auto-accept edits — acceptEdits (file edits run; other actions still ask)
  3) Reset to default  — default (ask on anything not allow-listed)
  4) Add an allow rule (e.g. "Bash(git push *)")
  5) Show current settings.json
  b) Back
EOF
    case "$(ask 'Choose')" in
      1)
        warn "bypassPermissions lets Claude run ANY command without confirmation."
        warn "Only enable this in a sandbox / box you're comfortable with (like the EC2 dev box)."
        confirm "Enable full (bypass) permissions?" && set_mode "bypassPermissions" || say "Cancelled."
        pause ;;
      2) set_mode "acceptEdits"; pause ;;
      3) set_mode "default"; pause ;;
      4)
        local rule; rule="$(ask 'Allow rule (e.g. Bash(npm run *))')"
        if [ -n "$rule" ]; then
          jq_edit --arg r "$rule" \
            '.permissions = (.permissions // {}) | .permissions.allow = ((.permissions.allow // []) + [$r] | unique)' \
            && ok "Added allow rule: $rule"
        else say "Nothing entered."; fi
        pause ;;
      5)
        ensure_settings
        head "$SETTINGS"; have jq && jq . "$SETTINGS" || cat "$SETTINGS"; pause ;;
      b|B|"") return ;;
      *) warn "Unknown choice." ;;
    esac
  done
}

# =====================================================================
# Settings inspector — show every Claude Code settings scope & how
# the same key in different scopes resolves (who overrides whom).
# =====================================================================

# OS-specific enterprise "managed" settings path (highest precedence).
managed_settings_path() {
  case "$(uname -s)" in
    Darwin) printf '%s' "/Library/Application Support/ClaudeCode/managed-settings.json" ;;
    *)      printf '%s' "/etc/claude-code/managed-settings.json" ;;
  esac
}

# Nearest ancestor of $PWD that contains a .claude directory (defaults to $PWD).
# Claude resolves project settings from the project root; this is the best proxy
# when the tool is run from a subdirectory.
project_dir() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -d "$d/.claude" ] && { printf '%s' "$d"; return; }
    d="$(dirname "$d")"
  done
  printf '%s' "$PWD"
}

# jq program: flatten a settings object into "dotted.path<TAB>jsonvalue" leaf
# lines. Arrays (e.g. permissions.allow) are emitted whole, not descended into.
SETTINGS_FLATTEN_JQ='
def flat($p):
  if (type=="object" and length>0) then
    to_entries[] | . as $e | ($e.value | flat($p + [$e.key]))
  else
    {path:$p, value:.}
  end;
flat([]) | "\(.path|join("."))\t\(.value|tojson)"
'

# Permission rule arrays accumulate (union) across scopes instead of overriding.
is_accumulating_key() {
  case "$1" in
    permissions.allow|permissions.deny|permissions.ask|permissions.additionalDirectories) return 0 ;;
    *) return 1 ;;
  esac
}

# settings_inspect [report|full|json]
#   report (default) — scope table + resolved settings with source attribution
#   full             — report, then a pretty-printed dump of every scope file
#   json             — machine-readable {scopes, effective, attribution} for agents
settings_inspect() {
  local mode="${1:-report}"
  if ! have jq; then err "jq is required to inspect settings (brew install jq)."; return 1; fi

  local cfgdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local proj managed
  proj="$(project_dir)"
  managed="$(managed_settings_path)"

  # Scopes, HIGHEST precedence first. (Command-line args sit between managed and
  # project-local but can't be introspected from a file.)
  local -a LABELS=( "Enterprise managed" "Project local" "Project shared" "User (global)" )
  local -a FILES=(
    "$managed"
    "$proj/.claude/settings.local.json"
    "$proj/.claude/settings.json"
    "$cfgdir/settings.json"
  )

  # Build a leaf stream in LOW -> HIGH precedence order (so the last occurrence
  # of a path wins): "path \t scope \t value". Also remember which files are
  # present+valid (low->high) for the deep-merge in JSON mode.
  # (awk does the keyed resolution so this stays bash-3.2 compatible.)
  local tmp resolved j f label
  tmp="$(mktemp)"; resolved="$(mktemp)"
  local -a present_l2h=()
  for (( j=${#FILES[@]}-1; j>=0; j-- )); do
    f="${FILES[$j]}"; label="${LABELS[$j]}"
    [ -f "$f" ] || continue
    jq -e . "$f" >/dev/null 2>&1 || continue
    present_l2h+=("$f")
    jq -r "$SETTINGS_FLATTEN_JQ" "$f" | while IFS=$'\t' read -r path value; do
      [ -z "$path" ] && continue
      printf '%s\t%s\t%s\n' "$path" "$label" "$value"
    done >> "$tmp"
  done

  # Resolve per path: winner scope/value (last wins) + full scope chain, sorted.
  # Output columns: path \t winnerScope \t chain(low|..|high) \t value
  awk -F'\t' '
    { val[$1]=$3; scope[$1]=$2;
      chain[$1]=(($1 in chain) ? chain[$1] "|" $2 : $2) }
    END { for (p in val) printf "%s\t%s\t%s\t%s\n", p, scope[p], chain[p], val[p] }
  ' "$tmp" | sort > "$resolved"

  # ----------------------------- JSON mode ----------------------------------
  if [ "$mode" = "json" ]; then
    local i scopes_json effective attribution
    local -a sj=()
    for i in "${!FILES[@]}"; do
      f="${FILES[$i]}"
      local exists=false valid=false
      [ -f "$f" ] && { exists=true; jq -e . "$f" >/dev/null 2>&1 && valid=true; }
      sj+=("$(jq -n --arg label "${LABELS[$i]}" --arg path "$f" \
                    --argjson exists "$exists" --argjson valid "$valid" \
                    '{label:$label, path:$path, exists:$exists, valid:$valid}')")
    done
    scopes_json="$(printf '%s\n' "${sj[@]}" | jq -s .)"
    if [ "${#present_l2h[@]}" -gt 0 ]; then
      effective="$(jq -s 'reduce .[] as $x ({}; . * $x)' "${present_l2h[@]}")"
    else
      effective='{}'
    fi
    attribution="$(awk -F'\t' '{printf "%s\t%s\n", $1, $2}' "$resolved" \
      | jq -R 'split("\t")|{(.[0]):.[1]}' | jq -s 'add // {}')"
    jq -n --argjson scopes "$scopes_json" --argjson effective "$effective" \
          --argjson attribution "$attribution" --arg project "$proj" \
      '{project:$project, scopes:$scopes, effective:$effective, attribution:$attribution}'
    rm -f "$tmp" "$resolved"
    return 0
  fi

  # --------------------------- human report ---------------------------------
  head "Claude Code settings — scopes"
  say "  ${DIM}Precedence (highest wins): managed → CLI args → project local → project shared → user.${RST}"
  say "  ${DIM}Project resolved to: ${proj/#$HOME/~}${RST}"
  [ "${CLAUDE_CONFIG_DIR:-}" ] && say "  ${DIM}CLAUDE_CONFIG_DIR override: $cfgdir${RST}"
  echo
  printf '  %-20s %-9s %-5s %s\n' "SCOPE" "STATUS" "KEYS" "PATH"
  local i status keys disp
  for i in "${!FILES[@]}"; do
    f="${FILES[$i]}"
    disp="${f/#$HOME/~}"
    if [ -f "$f" ]; then
      if jq -e . "$f" >/dev/null 2>&1; then
        keys="$(jq -r "$SETTINGS_FLATTEN_JQ" "$f" | grep -c . || true)"
        status="ok"
      else
        keys="-"; status="INVALID"
      fi
    else
      keys="-"; status="absent"
    fi
    printf '  %-20s %-9s %-5s %s\n' "${LABELS[$i]}" "$status" "$keys" "$disp"
  done

  head "Effective settings (resolved)"
  if [ ! -s "$resolved" ]; then
    warn "No settings found in any scope."
    rm -f "$tmp" "$resolved"
    return 0
  fi
  say "  ${DIM}Each line: winning value and the scope that set it. ↳ marks shadowed scopes.${RST}"
  echo
  local p src chain v
  while IFS=$'\t' read -r p src chain v; do
    printf '  %s%s%s = %s  %s(%s)%s\n' "$BOLD" "$p" "$RST" "$(trunc "$v" 80)" "$DIM" "$src" "$RST"
    if [ "${chain#*|}" != "$chain" ]; then
      # chain is low|..|high; winner is the last field, the rest are shadowed.
      local -a sc; IFS='|' read -ra sc <<< "$chain"
      local joined
      joined="$(printf '%s, ' "${sc[@]:0:${#sc[@]}-1}")"; joined="${joined%, }"
      if is_accumulating_key "$p"; then
        printf '      %s↳ accumulates (union) across: %s%s\n' "$YEL" "$joined, $src" "$RST"
      else
        printf '      %s↳ overrides: %s%s\n' "$DIM" "$joined" "$RST"
      fi
    fi
  done < "$resolved"

  say ""
  say "  ${DIM}Note: permission rule arrays (allow/deny/ask) accumulate across scopes;${RST}"
  say "  ${DIM}all other keys are overridden by the highest-precedence scope.${RST}"

  # ------------------------------ full dump ---------------------------------
  if [ "$mode" = "full" ]; then
    for i in "${!FILES[@]}"; do
      f="${FILES[$i]}"
      [ -f "$f" ] || continue
      head "${LABELS[$i]} — ${f/#$HOME/~}"
      jq . "$f" 2>/dev/null || cat "$f"
    done
  fi
  rm -f "$tmp" "$resolved"
}

settings_menu() {
  while true; do
    head "Settings inspector — Claude Code configuration"
    cat <<EOF

  1) ${BOLD}Resolved view${RST}   — scopes + effective settings with source attribution
  2) Full dump        — resolved view, then every scope file pretty-printed
  3) JSON output      — machine-readable (for agents / piping to jq)
  b) Back
EOF
    case "$(ask 'Choose')" in
      1) settings_inspect report; pause ;;
      2) settings_inspect full | ${PAGER:-less} -R 2>/dev/null || settings_inspect full; pause ;;
      3) settings_inspect json; pause ;;
      b|B|"") return ;;
      *) warn "Unknown choice." ;;
    esac
  done
}

# =====================================================================
# EC2 dev box — configure tfvars + deploy
# =====================================================================
require_for_deploy() {
  local ok=1
  have terraform || { err "terraform not found — brew install terraform"; ok=0; }
  have aws       || { err "aws CLI not found — https://aws.amazon.com/cli/"; ok=0; }
  if have aws && ! aws sts get-caller-identity >/dev/null 2>&1; then
    err "AWS credentials not configured — run: aws configure"; ok=0
  fi
  [ "$ok" -eq 1 ]
}

write_tfvars() {
  local tfvars="$TF_DIR/terraform.tfvars"
  head "Configure the EC2 dev box"
  say "These values are written to ${DIM}$tfvars${RST} (gitignored)."
  echo
  local region itype hostname idle gname gemail tskey
  region="$(ask 'AWS region' 'us-east-1')"
  itype="$(ask 'Instance type' 't3.small')"
  hostname="$(ask 'Tailscale hostname (you SSH to ubuntu@<this>)' 'claude-dev')"
  idle="$(ask 'Idle auto-shutdown minutes (0 = never)' '30')"
  gname="$(ask 'git user.name (optional)' '')"
  gemail="$(ask 'git user.email (optional)' '')"
  echo
  say "Tailscale auth key — make a ${BOLD}reusable, NON-ephemeral${RST} key at"
  say "  https://login.tailscale.com/admin/settings/keys"
  tskey="$(ask_secret 'Paste tailscale_auth_key (hidden)')"
  if [ -z "$tskey" ]; then err "A Tailscale auth key is required to deploy."; return 1; fi

  {
    echo "region         = \"$region\""
    echo "instance_type  = \"$itype\""
    echo "hostname       = \"$hostname\""
    echo "idle_shutdown_minutes = $idle"
    [ -n "$gname" ]  && echo "git_user_name  = \"$gname\""
    [ -n "$gemail" ] && echo "git_user_email = \"$gemail\""
    echo "tailscale_auth_key = \"$tskey\""
  } > "$tfvars"
  ok "Wrote $tfvars"
}

deploy() {
  head "Deploy the EC2 dev box (Terraform)"
  require_for_deploy || { pause; return; }

  local tfvars="$TF_DIR/terraform.tfvars"
  if [ -f "$tfvars" ]; then
    say "Found existing $tfvars."
    confirm "Reconfigure it now?" && { write_tfvars || { pause; return; }; }
  else
    write_tfvars || { pause; return; }
  fi

  head "terraform init"
  ( cd "$TF_DIR" && terraform init -input=false )

  echo
  if confirm "Run 'terraform apply' now (this creates billable AWS resources)?"; then
    ( cd "$TF_DIR" && terraform apply )
    echo
    ok "Apply finished. First-boot provisioning takes ~3–5 min."
    say "Watch your Tailscale admin console for the node, then: ${BOLD}scripts/agentkit.sh box ssh${RST}"
  else
    say "Skipped apply. When ready: cd terraform/ec2-dev && terraform apply"
  fi
  pause
}

destroy() {
  head "Tear down the EC2 dev box"
  require_for_deploy || { pause; return; }
  warn "This destroys the instance, VPC, and disk created by Terraform."
  if confirm "Run 'terraform destroy'?"; then
    ( cd "$TF_DIR" && terraform destroy )
  else say "Cancelled."; fi
  pause
}

# =====================================================================
# EC2 dev box — control (delegates to box.sh)
# =====================================================================
box() {
  local sub="${1:-}"
  if [ ! -x "$BOX" ]; then chmod +x "$BOX" 2>/dev/null || true; fi
  case "$sub" in
    start|stop|status|ssh) BOX_NAME="$(box_name)" "$BOX" "$sub"; return ;;
  esac
  while true; do
    head "EC2 dev box — control"
    say "  ${DIM}Targets the box named '$(box_name)'${RST}"
    cat <<EOF

  1) Status
  2) Start
  3) SSH in (starts it first if needed)
  4) Stop
  b) Back
EOF
    case "$(ask 'Choose')" in
      1) BOX_NAME="$(box_name)" "$BOX" status; pause ;;
      2) BOX_NAME="$(box_name)" "$BOX" start;  pause ;;
      3) BOX_NAME="$(box_name)" "$BOX" ssh ;;
      4) BOX_NAME="$(box_name)" "$BOX" stop;   pause ;;
      b|B|"") return ;;
      *) warn "Unknown choice." ;;
    esac
  done
}

# Best-effort: read hostname from tfvars so control targets the right box.
box_name() {
  local tfvars="$TF_DIR/terraform.tfvars" name
  if [ -f "$tfvars" ]; then
    name="$(sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$tfvars" | head -1)"
  fi
  printf '%s' "${BOX_NAME:-${name:-claude-dev}}"
}

# =====================================================================
# Remote Terraform state (S3 backend)
# =====================================================================
state() {
  head "Remote Terraform state (S3 backend)"
  say "Backs up Terraform state to a versioned, encrypted, private S3 bucket."
  say "Only needed if you run Terraform from more than one machine."
  require_for_deploy || { pause; return; }
  [ -x "$BOOTSTRAP" ] || chmod +x "$BOOTSTRAP" 2>/dev/null || true

  local bucket region
  bucket="$(ask 'Globally-unique S3 bucket name')"
  [ -z "$bucket" ] && { say "Cancelled."; pause; return; }
  region="$(ask 'Region' 'us-east-1')"

  if confirm "Create bucket s3://$bucket in $region?"; then
    "$BOOTSTRAP" "$bucket" "$region"
    local backend="$TF_DIR/backend.tf"
    if [ ! -f "$backend" ] && confirm "Write $backend pointing at this bucket?"; then
      sed -e "s|REPLACE-ME-globally-unique-bucket|$bucket|" \
          -e "s|region       = \"us-east-1\"|region       = \"$region\"|" \
          "$TF_DIR/backend.tf.example" > "$backend"
      ok "Wrote $backend"
      confirm "Run 'terraform init -migrate-state' now?" \
        && ( cd "$TF_DIR" && terraform init -migrate-state )
    fi
  else say "Cancelled."; fi
  pause
}

# =====================================================================
# Main menu
# =====================================================================
banner() {
  cat <<EOF
${BOLD}${BLU}ClaudeCode-AgentKit${RST} — setup wizard
${DIM}Turn on the pieces of this kit, one at a time.${RST}
EOF
}

menu() {
  while true; do
    clear 2>/dev/null || true
    banner
    cat <<EOF

  1) Permissions       — edit .claude/settings.json (e.g. full permissions)
  2) Settings inspector — show all Claude Code settings & how they resolve
  3) Deploy dev box    — configure + 'terraform apply' the EC2 box
  4) Control dev box   — start / stop / ssh / status
  5) Remote state      — S3 backend for Terraform
  6) Doctor            — check prerequisites
  7) Tear down dev box — terraform destroy
  q) Quit
EOF
    case "$(ask 'Choose')" in
      1) permissions_menu ;;
      2) settings_menu ;;
      3) deploy ;;
      4) box ;;
      5) state ;;
      6) doctor; pause ;;
      7) destroy ;;
      q|Q|"") say "Bye."; exit 0 ;;
      *) warn "Unknown choice." ;;
    esac
  done
}

# ---- entrypoint -----------------------------------------------------------
# Print the leading comment block (after the shebang) as help text.
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

case "${1:-}" in
  permissions|perms) permissions_menu ;;
  settings|config)   shift
                     case "${1:-}" in
                       full)        settings_inspect full ;;
                       json)        settings_inspect json ;;
                       ""|report)   settings_inspect report ;;
                       *)           settings_inspect report ;;
                     esac ;;
  deploy|apply)      deploy ;;
  box)               shift; box "${1:-}" ;;
  state|backend)     state ;;
  destroy)           destroy ;;
  doctor|check)      doctor ;;
  -h|--help|help)    usage ;;
  "" )               menu ;;
  *) err "Unknown command: $1"; usage; exit 1 ;;
esac
