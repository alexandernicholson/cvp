#!/usr/bin/env bash
# cvp — Claude (Code) Profile manager
# https://github.com/alexandernicholson/cvp
#
# A cvm plugin that manages named "profiles" of environment variables
# (ANTHROPIC_BASE_URL, CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS,
# and any others) and applies the active one to every `claude` invocation via
# the ~/.cvm/env.d/cvp.sh hook installed by cvm's wrapper.
#
# Design: the global "active profile" is just an ALIAS — a name stored in
# ~/.cvm/active-profile — pointing at a profile definition in
# ~/.cvm/profiles/<name>.env. Switching profiles only rewrites the alias; the
# profile settings are never moved or lost, so you can switch freely.

set -euo pipefail

CVP_VERSION="0.1.3"

CVP_DIR="${CVM_DIR:-$HOME/.cvm}"
CVP_PROFILES="$CVP_DIR/profiles"
CVP_ACTIVE_FILE="$CVP_DIR/active-profile"
CVP_ENV_D="$CVP_DIR/env.d"
CVP_RESOLVER="$CVP_ENV_D/cvp.sh"

# Claude Code's user-scope settings. cvp merges the active (global) profile's
# vars into the `env` block here so that TEAMMATES (separate claude instances
# that bypass the ~/.cvm/bin/claude shim) still pick up the gateway/keys at
# startup. Only the `env` sub-object is touched; all other settings are
# preserved. Set CVP_NO_SETTINGS_SYNC=1 to disable.
CVP_CLAUDE_DIR="${CVP_CLAUDE_DIR:-$HOME/.claude}"
CVP_CLAUDE_SETTINGS="$CVP_CLAUDE_DIR/settings.json"
CVP_MANAGED_VARS="$CVP_PROFILES/.settings-managed"

# Vars cvp knows about (used as prompts in `add`). Any KEY=VALUE line is allowed.
# ANTHROPIC_AUTH_TOKEN is preferred over CLAUDE_CODE_OAUTH_TOKEN: it sets the
# raw `Authorization: Bearer <value>` header and takes precedence over your
# logged-in claude.ai session in BOTH interactive and -p mode (whereas
# CLAUDE_CODE_OAUTH_TOKEN only overrides keychain creds and is ignored in
# interactive mode when a session is active).
CVP_KNOWN_VARS=(
  ANTHROPIC_BASE_URL
  ANTHROPIC_AUTH_TOKEN
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
)
# Vars whose values are masked in `show` (name contains one of these tokens).
CVP_SECRET_RE='TOKEN|KEY|SECRET|PASSWD|PASSWORD|CREDENTIAL'

# ── Colors / logging (reuse cvm's if present, else define) ──────────────────────
if [[ -z "${RED:-}" ]]; then
  if [[ -t 1 ]]; then
    RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m' BOLD=$'\033[1m'      DIM=$'\033[2m'    RESET=$'\033[0m'
  else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
  fi
fi

err()  { echo -e "${RED}error:${RESET} $*" >&2; }
info() { echo -e "${BLUE}→${RESET} $*"; }
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
warn() { echo -e "${YELLOW}warn:${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────

_cvp_setup() {
  mkdir -p "$CVP_PROFILES" "$CVP_ENV_D"
}

_cvp_profile_file() {
  printf '%s/%s.env' "$CVP_PROFILES" "$1"
}

# Validate a profile name: [A-Za-z0-9._-]+, must not start with '.' or '-'.
_cvp_valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# Single-quote-escape a value for safe embedding in `export KEY='value'`.
_cvp_squote() {
  local s="$1"
  s="${s//\'/\'\\\'\'}"
  printf '%s' "$s"
}

# True if the var name looks secret-y.
_cvp_is_secret() {
  [[ "$1" =~ $CVP_SECRET_RE ]]
}

# Resolve the active profile name (alias) — does NOT read the profile contents.
# Order: $CVM_PROFILE > .claude-profile (walk up to /) > ~/.cvm/active-profile.
# Prints the name and returns 0, or prints nothing and returns 1 if none.
_cvp_resolve() {
  if [[ -n "${CVM_PROFILE:-}" ]]; then
    printf '%s' "$CVM_PROFILE"
    return 0
  fi
  local dir="$PWD"
  while true; do
    if [[ -f "$dir/.claude-profile" ]]; then
      local n
      n=$(tr -d '[:space:]' < "$dir/.claude-profile")
      [[ -n "$n" ]] && { printf '%s' "$n"; return 0; }
    fi
    [[ "$dir" == "/" ]] && break
    dir=$(dirname "$dir")
  done
  if [[ -f "$CVP_ACTIVE_FILE" ]]; then
    local n
    n=$(tr -d '[:space:]' < "$CVP_ACTIVE_FILE")
    [[ -n "$n" ]] && { printf '%s' "$n"; return 0; }
  fi
  return 1
}

# Parse a profile .env file and emit null-delimited KEY=VALUE pairs on stdout.
# Skips blank lines and # comments; strips one pair of surrounding quotes.
_cvp_parse_env() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim leading/trailing whitespace so indented comments/vars are handled
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    # strip one pair of surrounding matching quotes (single or double)
    local _q="${val:0:1}"
    if [[ ( "$_q" == '"' || "$_q" == "'" ) && ${#val} -ge 2 && "${val: -1}" == "$_q" ]]; then
      val="${val#?}"; val="${val%?}"
    fi
    printf '%s=%s\0' "$key" "$val"
  done < "$file"
}

# Ensure the built-in `default` profile (official Claude Code endpoints) exists.
# Non-destructive: never overwrites an existing default.env.
_cvp_seed_default() {
  local file; file="$(_cvp_profile_file "default")"
  [[ -f "$file" ]] && return 0
  cat > "$file" <<'EOF'
# Profile: default
# The default Claude Code profile — uses Anthropic's official endpoints and your
# normal login. No custom base URL or token override. Add vars with:
#   cvm profile edit default
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='1'
EOF
}

# Install/refresh the env.d resolver script. Idempotent; content is static.
_cvp_install_resolver() {
  _cvp_setup
  _cvp_seed_default
  cat > "$CVP_RESOLVER" <<'RESOLVER'
# Auto-generated by cvp — do not edit.
# Sourced by cvm's `claude` wrapper. Resolves the active profile
# ($CVM_PROFILE > .claude-profile walk-up > ~/.cvm/active-profile) and exports
# its variables for the current claude invocation only. The active profile is an
# alias; profile definition files are never modified by switching.
_cvp_dir="${CVM_DIR:-$HOME/.cvm}"
_cvp_resolve_profile() {
  if [[ -n "${CVM_PROFILE:-}" ]]; then printf '%s' "$CVM_PROFILE"; return 0; fi
  local dir="$PWD"
  while true; do
    if [[ -f "$dir/.claude-profile" ]]; then
      local n; n=$(tr -d '[:space:]' < "$dir/.claude-profile")
      [[ -n "$n" ]] && { printf '%s' "$n"; return 0; }
    fi
    [[ "$dir" == "/" ]] && break
    dir=$(dirname "$dir")
  done
  if [[ -f "$_cvp_dir/active-profile" ]]; then
    tr -d '[:space:]' < "$_cvp_dir/active-profile"; return 0
  fi
  return 1
}
_cvp_name=$(_cvp_resolve_profile) || { unset -f _cvp_resolve_profile 2>/dev/null; unset _cvp_dir _cvp_name _cvp_file _cvp_k _cvp_v _cvp_line 2>/dev/null; return 0; }
[[ -n "$_cvp_name" ]] || { unset -f _cvp_resolve_profile 2>/dev/null; unset _cvp_dir _cvp_name 2>/dev/null; return 0; }
_cvp_file="$_cvp_dir/profiles/$_cvp_name.env"
if [[ ! -f "$_cvp_file" ]]; then unset -f _cvp_resolve_profile 2>/dev/null; unset _cvp_dir _cvp_name _cvp_file 2>/dev/null; return 0; fi
while IFS= read -r _cvp_line || [[ -n "$_cvp_line" ]]; do
  _cvp_line="${_cvp_line#"${_cvp_line%%[![:space:]]*}"}"
  _cvp_line="${_cvp_line%"${_cvp_line##*[![:space:]]}"}"
  [[ -z "$_cvp_line" || "$_cvp_line" == \#* || "$_cvp_line" != *=* ]] && continue
  _cvp_k="${_cvp_line%%=*}"
  _cvp_v="${_cvp_line#*=}"
  _cvp_q="${_cvp_v:0:1}"
  if [[ ( "$_cvp_q" == '"' || "$_cvp_q" == "'" ) && ${#_cvp_v} -ge 2 && "${_cvp_v: -1}" == "$_cvp_q" ]]; then
    _cvp_v="${_cvp_v#?}"; _cvp_v="${_cvp_v%?}"
  fi
  export "$_cvp_k=$_cvp_v"
done < "$_cvp_file"
unset -f _cvp_resolve_profile 2>/dev/null
unset _cvp_dir _cvp_name _cvp_file _cvp_k _cvp_v _cvp_q _cvp_line 2>/dev/null
RESOLVER
}

# ── ~/.claude/settings.json sync (for teammates) ──────────────────────────────
# Teammates are separate Claude Code instances spawned by the lead that bypass
# the ~/.cvm/bin/claude shim, so they never source env.d. Claude Code reads the
# `env` block from ~/.claude/settings.json at startup "no matter how claude was
# launched", so we merge the active GLOBAL profile's vars there. Only the `env`
# sub-object is touched; cvp tracks the var names it owns in a sidecar so it can
# replace them on switch without clobbering user-added env vars. Per-directory
# profiles still apply to the LEAD via the shim at runtime.

# Parse a profile .env file into KEY=VALUE lines (stdout), stripping comments
# and one pair of surrounding quotes. Shared by the python sync below.
_cvp_settings_parse() {
  _cvp_parse_env "$1"
}

# Sync the global active profile (or $1) into ~/.claude/settings.json env.
_cvp_settings_sync() {
  [[ "${CVP_NO_SETTINGS_SYNC:-}" == "1" ]] && return 0
  command -v python3 &>/dev/null || { warn "python3 not found — skipping ~/.claude/settings.json sync (teammates won't get the profile)"; return 0; }

  local name="${1:-}"
  if [[ -z "$name" ]]; then
    [[ -f "$CVP_ACTIVE_FILE" ]] || { _cvp_settings_clear; return 0; }
    name=$(tr -d '[:space:]' < "$CVP_ACTIVE_FILE")
    [[ -n "$name" ]] || { _cvp_settings_clear; return 0; }
  fi
  local file; file="$(_cvp_profile_file "$name")"
  [[ -f "$file" ]] || { warn "Profile '$name' has no file; skipping settings sync"; return 0; }

  mkdir -p "$CVP_CLAUDE_DIR" "$CVP_PROFILES"
  # One-time backup of the user's settings so the merge is reversible.
  if [[ -f "$CVP_CLAUDE_SETTINGS" && ! -f "$CVP_CLAUDE_SETTINGS.cvp-backup" ]]; then
    cp -p "$CVP_CLAUDE_SETTINGS" "$CVP_CLAUDE_SETTINGS.cvp-backup" 2>/dev/null || true
  fi

  # Hand the profile vars to python via a temp file (null-delimited, safe).
  local pairs_file
  pairs_file=$(mktemp)
  _cvp_settings_parse "$file" > "$pairs_file"

  python3 - "$CVP_CLAUDE_SETTINGS" "$pairs_file" "$CVP_MANAGED_VARS" <<'PYEOF'
import sys, json, os
settings_path, pairs_path, sidecar_path = sys.argv[1:4]

# Read current settings (preserve everything).
try:
    with open(settings_path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}
except Exception:
    # Corrupt/invalid JSON — don't clobber. Fall back to empty and warn.
    sys.stderr.write("cvp: warning: %s is not valid JSON; overwriting an empty env block\n" % settings_path)
    settings = {}
if not isinstance(settings, dict):
    settings = {}

# Previously managed vars (remove before re-adding).
managed = []
try:
    with open(sidecar_path) as f:
        managed = [l.strip() for l in f if l.strip()]
except FileNotFoundError:
    pass

# New profile vars (null-delimited KEY=VALUE).
newvars = {}
with open(pairs_path, 'rb') as f:
    for pair in f.read().split(b'\0'):
        if not pair:
            continue
        k, _, v = pair.decode('utf-8', 'replace').partition('=')
        newvars[k] = v

env = settings.get('env', {})
if not isinstance(env, dict):
    env = {}
for k in managed:
    env.pop(k, None)
env.update(newvars)

if env:
    settings['env'] = dict(sorted(env.items()))
else:
    settings.pop('env', None)

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write('\n')

with open(sidecar_path, 'w') as f:
    for k in newvars:
        f.write(k + '\n')
PYEOF
  rm -f "$pairs_file"
}

# Remove all cvp-managed vars from ~/.claude/settings.json env (and the sidecar).
_cvp_settings_clear() {
  [[ "${CVP_NO_SETTINGS_SYNC:-}" == "1" ]] && return 0
  [[ -f "$CVP_MANAGED_VARS" ]] || return 0
  command -v python3 &>/dev/null || { rm -f "$CVP_MANAGED_VARS"; return 0; }
  [[ -f "$CVP_CLAUDE_SETTINGS" ]] || { rm -f "$CVP_MANAGED_VARS"; return 0; }

  python3 - "$CVP_CLAUDE_SETTINGS" "$CVP_MANAGED_VARS" <<'PYEOF'
import sys, json
settings_path, sidecar_path = sys.argv[1], sys.argv[2]
managed = []
try:
    with open(sidecar_path) as f:
        managed = [l.strip() for l in f if l.strip()]
except FileNotFoundError:
    pass
try:
    with open(settings_path) as f:
        settings = json.load(f)
except Exception:
    settings = {}
if not isinstance(settings, dict):
    settings = {}
env = settings.get('env', {})
if isinstance(env, dict):
    for k in managed:
        env.pop(k, None)
    if env:
        settings['env'] = dict(sorted(env.items()))
    else:
        settings.pop('env', None)
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write('\n')
PYEOF
  rm -f "$CVP_MANAGED_VARS"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cvp_add() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: cvm profile add <name>"
  _cvp_valid_name "$name" || die "Invalid profile name: $name (use letters, digits, . _ -)"
  _cvp_setup
  _cvp_install_resolver

  local file; file="$(_cvp_profile_file "$name")"
  local existed=0
  [[ -f "$file" ]] && existed=1

  echo -e "${BOLD}Configuring profile '${name}'${RESET}"
  [[ $existed -eq 1 ]] && echo -e "  ${DIM}(existing values shown in [] — press Enter to keep)${RESET}"
  echo ""

  # Read existing values into an associative array (bash 4+).
  declare -A cur=()
  if [[ $existed -eq 1 ]]; then
    local pair
    while IFS= read -r -d '' pair; do
      cur["${pair%%=*}"]="${pair#*=}"
    done < <(_cvp_parse_env "$file")
  fi

  # Prompt for each known var.
  for var in "${CVP_KNOWN_VARS[@]}"; do
    local def="${cur[$var]:-}"
    local hint=""
    [[ -n "$def" ]] && hint=" ${DIM}[${def}]${RESET}"
    if _cvp_is_secret "$var"; then
      printf '%s%s%s (secret, leave blank to skip/keep)%s: ' "$BOLD" "$var" "$hint" "$RESET"
    else
      printf '%s%s%s%s: ' "$BOLD" "$var" "$hint" "$RESET"
    fi
    local val
    read -r val || val=""
    if [[ -n "$val" ]]; then
      cur[$var]="$val"
    fi
  done

  # Prompt for any extra custom vars.
  echo ""
  echo -e "${DIM}Add custom variables (blank line to finish):${RESET}"
  while true; do
    printf 'VAR NAME (blank=done): '; read -r k || k=""
    [[ -z "$k" ]] && break
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { warn "'$k' is not a valid env var name (letters/digits/_), skipping"; continue; }
    local def="${cur[$k]:-}"
    local hint=""; [[ -n "$def" ]] && hint=" ${DIM}[${def}]${RESET}"
    printf '  value for %s%s: ' "$k" "$hint"; read -r v || v=""
    if [[ -n "$v" ]]; then cur[$k]="$v"; fi
  done

  # Write the file: known vars first (in declared order), then extras sorted.
  : > "$file"
  echo "# Profile: $name" >> "$file"
  echo "# Managed by cvp — edit with: cvm profile edit $name" >> "$file"
  local written=()
  for var in "${CVP_KNOWN_VARS[@]}"; do
    if [[ -n "${cur[$var]:-}" ]]; then
      printf "%s='%s'\n" "$var" "$(_cvp_squote "${cur[$var]}")" >> "$file"
      written+=("$var")
    fi
  done
  # Extras (anything in cur() not already written), sorted for stability.
  local extras=()
  for k in "${!cur[@]}"; do
    local seen=0
    for w in "${written[@]}"; do [[ "$k" == "$w" ]] && { seen=1; break; }; done
    [[ $seen -eq 0 ]] && extras+=("$k")
  done
  if [[ ${#extras[@]} -gt 0 ]]; then
    printf '%s\n' "${extras[@]}" | LC_ALL=C sort | while IFS= read -r k; do
      printf "%s='%s'\n" "$k" "$(_cvp_squote "${cur[$k]}")" >> "$file"
    done
  fi

  # If this profile is the active global one, re-sync settings.json so
  # teammates pick up the edited vars.
  local g=""; [[ -f "$CVP_ACTIVE_FILE" ]] && g=$(tr -d '[:space:]' < "$CVP_ACTIVE_FILE")
  [[ "$g" == "$name" ]] && _cvp_settings_sync "$name"

  ok "Saved profile '$name' → $file"
  echo -e "  ${DIM}Activate with:${RESET} cvm profile use $name"
}

cvp_use() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: cvm profile use <name>"
  _cvp_valid_name "$name" || die "Invalid profile name: $name"
  local file; file="$(_cvp_profile_file "$name")"
  [[ -f "$file" ]] || die "Profile '$name' does not exist. Create it with: cvm profile add $name"

  _cvp_setup
  _cvp_install_resolver
  # Only the alias is rewritten — the profile definition is never touched.
  printf '%s\n' "$name" > "$CVP_ACTIVE_FILE"
  _cvp_settings_sync "$name"
  ok "Now using profile '$name' (global)"
  echo -e "  ${DIM}Alias only — settings in $file are untouched.${RESET}"
  echo -e "  ${DIM}Lead: env.d shim at runtime. Teammates: ~/.claude/settings.json env.${RESET}"
}

cvp_local() {
  case "${1:-}" in
    --unset|-u)
      if [[ -f ".claude-profile" ]]; then
        rm -f ".claude-profile"; ok "Removed .claude-profile"
      else
        ok "No .claude-profile in this directory"
      fi
      return 0
      ;;
  esac
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: cvm profile local <name|--unset>"
  _cvp_valid_name "$name" || die "Invalid profile name: $name"
  local file; file="$(_cvp_profile_file "$name")"
  [[ -f "$file" ]] || warn "Profile '$name' does not exist yet (create later with: cvm profile add $name)"
  _cvp_setup
  _cvp_install_resolver
  printf '%s\n' "$name" > ".claude-profile"
  ok "Wrote .claude-profile: $name"
  echo -e "  ${DIM}Commit it to share this profile pin with your team.${RESET}"
}

cvp_current() {
  local name
  if name=$(_cvp_resolve 2>/dev/null); then
    echo "$name"
  else
    echo "none"
    return 1
  fi
}

cvp_list() {
  _cvp_setup
  local resolved=""
  resolved=$(_cvp_resolve 2>/dev/null || echo "")
  local global=""
  [[ -f "$CVP_ACTIVE_FILE" ]] && global=$(tr -d '[:space:]' < "$CVP_ACTIVE_FILE")

  if [[ ! -d "$CVP_PROFILES" ]] || [[ -z "$(ls -A "$CVP_PROFILES" 2>/dev/null)" ]]; then
    echo "No profiles defined."
    echo "Create one with: cvm profile add <name>"
    return 0
  fi

  echo "Profiles:"
  local found=0 f name
  for f in "$CVP_PROFILES"/*.env; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .env)"
    found=1
    local tag=""
    if [[ "$name" == "$resolved" ]]; then
      tag="${GREEN}→ ${RESET}"
    fi
    printf "  %s%s%s" "$tag" "$name" "$RESET"
    [[ -n "$tag" ]] && printf "  ${DIM}(active)${RESET}"
    [[ "$name" == "$global" && "$name" != "$resolved" ]] && printf "  ${DIM}(global)${RESET}"
    printf "\n"
  done
  [[ $found -eq 1 ]] || echo "  (none)"
}

cvp_show() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name=$(_cvp_resolve 2>/dev/null) || die "No profile active. Specify one: cvm profile show <name>"
  fi
  _cvp_valid_name "$name" || die "Invalid profile name: $name"
  local file; file="$(_cvp_profile_file "$name")"
  [[ -f "$file" ]] || die "Profile '$name' does not exist"

  echo -e "${BOLD}Profile:${RESET} $name"
  echo -e "${DIM}Source:  $file${RESET}"
  local pair k v masked
  local any=0
  while IFS= read -r -d '' pair; do
    k="${pair%%=*}"; v="${pair#*=}"
    if _cvp_is_secret "$k"; then
      masked="***"
    else
      masked="$v"
    fi
    printf "  %s=%s\n" "$k" "$masked"
    any=1
  done < <(_cvp_parse_env "$file")
  [[ $any -eq 1 ]] || echo "  (no variables defined)"
}

# Print real `export KEY='value'` lines for the resolved (or named) profile.
# Intended for `eval "$(cvm profile env)"`. Secrets are NOT masked here.
cvp_env() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name=$(_cvp_resolve 2>/dev/null) || return 0
  fi
  _cvp_valid_name "$name" || return 1
  local file; file="$(_cvp_profile_file "$name")"
  [[ -f "$file" ]] || return 0
  local pair k v
  while IFS= read -r -d '' pair; do
    k="${pair%%=*}"; v="${pair#*=}"
    printf "export %s='%s'\n" "$k" "$(_cvp_squote "$v")"
  done < <(_cvp_parse_env "$file")
}

cvp_edit() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: cvm profile edit <name>"
  _cvp_valid_name "$name" || die "Invalid profile name: $name"
  _cvp_setup
  _cvp_install_resolver
  local file; file="$(_cvp_profile_file "$name")"
  [[ -f "$file" ]] || warn "Creating new profile '$name'"
  local editor="${EDITOR:-vi}"
  command -v "$editor" &>/dev/null || die "Editor '$editor' not found (set \$EDITOR)"
  "$editor" "$file"
  # Re-sync settings.json if the edited profile is the active global one.
  local g=""; [[ -f "$CVP_ACTIVE_FILE" ]] && g=$(tr -d '[:space:]' < "$CVP_ACTIVE_FILE")
  [[ "$g" == "$name" ]] && _cvp_settings_sync "$name"
  ok "Edited profile '$name'"
}

cvp_remove() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: cvm profile remove <name>"
  _cvp_valid_name "$name" || die "Invalid profile name: $name"
  local file; file="$(_cvp_profile_file "$name")"
  [[ -f "$file" ]] || die "Profile '$name' does not exist"

  rm -f "$file"
  ok "Removed profile '$name'"

  # If it was the global alias, clear the alias + cvp-managed settings vars.
  local global=""
  [[ -f "$CVP_ACTIVE_FILE" ]] && global=$(tr -d '[:space:]' < "$CVP_ACTIVE_FILE")
  if [[ "$global" == "$name" ]]; then
    rm -f "$CVP_ACTIVE_FILE"
    _cvp_settings_clear
    warn "It was the global active profile — alias and settings.json env cleared."
  fi
}

# (Re)install the env.d resolver, sync settings.json, and report state.
cvp_apply() {
  _cvp_setup
  _cvp_install_resolver
  _cvp_settings_sync
  ok "Resolver installed at $CVP_RESOLVER"
  ok "Settings synced to $CVP_CLAUDE_SETTINGS"
  local name
  if name=$(_cvp_resolve 2>/dev/null); then
    echo -e "  ${DIM}active profile:${RESET} $name"
  else
    echo -e "  ${DIM}no profile active${RESET}"
  fi
}

# One-shot setup: seed the default profile, install the resolver, and — if no
# profile is active — activate `default` (official Claude Code). Run by cvm's
# plugin manager on install/update, and available as `cvm profile init`.
cvp_init() {
  _cvp_setup
  _cvp_seed_default
  _cvp_install_resolver
  if [[ ! -f "$CVP_ACTIVE_FILE" ]] || [[ -z "$(tr -d '[:space:]' < "$CVP_ACTIVE_FILE")" ]]; then
    printf 'default\n' > "$CVP_ACTIVE_FILE"
  fi
  _cvp_settings_sync
  ok "cvp initialised"
  echo -e "  ${DIM}default profile:${RESET} $(_cvp_profile_file default)"
  echo -e "  ${DIM}resolver:${RESET}        $CVP_RESOLVER"
  echo -e "  ${DIM}settings sync:${RESET}   $CVP_CLAUDE_SETTINGS"
  local active=""
  [[ -f "$CVP_ACTIVE_FILE" ]] && active=$(tr -d '[:space:]' < "$CVP_ACTIVE_FILE")
  echo -e "  ${DIM}active:${RESET}           ${active:-none}"
}

cvp_help() {
  cat <<EOF
${BOLD}cvm profile${RESET} ${DIM}(cvp v${CVP_VERSION})${RESET} — Claude Code profile manager

${BOLD}USAGE${RESET}
  cvm profile <command> [args]

${BOLD}COMMANDS${RESET}
  ${BOLD}add${RESET} <name>            Create or edit a profile (prompts for known + custom vars)
  ${BOLD}use${RESET} <name>            Set the global active profile (alias only — settings untouched)
  ${BOLD}local${RESET} <name>          Pin this directory to a profile (writes .claude-profile)
  ${BOLD}local --unset${RESET}         Remove the directory's .claude-profile
  ${BOLD}current${RESET}               Print the resolved profile name (or "none")
  ${BOLD}ls${RESET}, ${BOLD}list${RESET}               List profiles (marks the active one)
  ${BOLD}show${RESET} [name]           Display a profile's vars (secrets masked)
  ${BOLD}edit${RESET} <name>           Open a profile in \`\$EDITOR\` (default: vi)
  ${BOLD}remove${RESET} <name>         Delete a profile (clears the alias if active)
  ${BOLD}env${RESET} [name]            Print \`export\` lines for \`eval\`\` (real values)
  ${BOLD}apply${RESET}                 (Re)install resolver + sync ~/.claude/settings.json
  ${BOLD}sync${RESET}                  Re-sync the active profile into ~/.claude/settings.json env
  ${BOLD}init${RESET}                  Seed the default profile + install resolver (run on install)
  ${BOLD}help${RESET}, ${BOLD}--help${RESET}          Show this help

${BOLD}PROFILE RESOLUTION ORDER${RESET}  (applied per \`claude\` run via the env hook)
  1. \$CVM_PROFILE environment variable
  2. .claude-profile file (walks up directory tree to /)
  3. ~/.cvm/active-profile (global alias, set by ${BOLD}cvm profile use${RESET})
  4. (none — no profile applied)

${BOLD}KNOWN VARS${RESET} (prompted by ${BOLD}add${RESET}; any KEY=VALUE is allowed)
EOF
  for v in "${CVP_KNOWN_VARS[@]}"; do
    printf '  %s\n' "$v"
  done
  cat <<EOF

${BOLD}DESIGN${RESET}
  The global "active profile" is just an alias (a name in ~/.cvm/active-profile)
  pointing at ~/.cvm/profiles/<name>.env. Switching profiles rewrites only the
  alias; the stored keys/URLs/flags are never moved or lost.

${BOLD}TWO INJECTION PATHS${RESET}
  ${BOLD}env.d shim${RESET} (~/.cvm/env.d/cvp.sh): sourced by cvm's \`claude\` wrapper at
    runtime → applies the RESOLVED profile (per-dir or global) to the LEAD.
  ${BOLD}~/.claude/settings.json env${RESET}: cvp merges the GLOBAL profile's vars here so
    TEAMMATES (separate claude instances that bypass the shim) still get them at
    startup. Only the \`env\` sub-object is touched; other settings are preserved.
    Per-directory profiles apply to the lead only; teammates use the global
    profile. Set CVP_NO_SETTINGS_SYNC=1 to disable.

${BOLD}EXAMPLES${RESET}
  cvm profile add my-gateway
  cvm profile use my-gateway
  cvm profile local work
  cvm profile show
  eval "\$(cvm profile env)"
EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

cvp_main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    add|new)        cvp_add "$@" ;;
    use)            cvp_use "$@" ;;
    local)          cvp_local "$@" ;;
    current)        cvp_current ;;
    ls|list)        cvp_list ;;
    show)           cvp_show "$@" ;;
    edit)           cvp_edit "$@" ;;
    rm|remove|delete) cvp_remove "$@" ;;
    env)            cvp_env "$@" ;;
    apply|refresh)  cvp_apply ;;
    sync)           _cvp_settings_sync; ok "Settings synced to $CVP_CLAUDE_SETTINGS" ;;
    init)           cvp_init ;;
    version|--version|-v) echo "cvp $CVP_VERSION" ;;
    help|--help|-h) cvp_help ;;
    *) err "Unknown profile command: $cmd"; echo ""; cvp_help; exit 1 ;;
  esac
}

# Allow running cvp.sh directly (outside the cvm plugin dispatch).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && cvp_main "$@"
