#!/usr/bin/env bash
# cvp installer — installs the cvp profile-manager plugin into ~/.cvm/plugins/cvp/
# Usage: curl -fsSL https://raw.githubusercontent.com/alexandernicholson/cvp/main/install.sh | bash
set -euo pipefail

CVM_DIR="${CVM_DIR:-$HOME/.cvm}"
CVP_DIR="$CVM_DIR/plugins/cvp"
CVP_REPO="https://github.com/alexandernicholson/cvp.git"

RED='\033[0;31m' GREEN='\033[0;32m' BLUE='\033[0;34m' BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
info() { echo -e "${BLUE}→${RESET} $*"; }
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
die()  { echo -e "${RED}error:${RESET} $*" >&2; exit 1; }

echo -e "${BOLD}Installing cvp — Claude Code profile manager (cvm plugin)${RESET}"
echo ""

if [[ -d "$CVP_DIR" ]] && [[ -n "$(ls -A "$CVP_DIR" 2>/dev/null)" ]]; then
  info "cvp already installed at $CVP_DIR — updating"
  git -C "$CVP_DIR" pull --ff-only || die "Failed to update. Remove $CVP_DIR and re-run."
else
  command -v git &>/dev/null || die "git is required to install cvp"
  mkdir -p "$CVM_DIR/plugins"
  rm -rf "$CVP_DIR"
  info "Cloning cvp from $CVP_REPO"
  git clone --depth 1 "$CVP_REPO" "$CVP_DIR"
fi
[[ -f "$CVP_DIR/plugin.sh" ]] || die "Installation incomplete: $CVP_DIR/plugin.sh missing"

echo ""
ok "cvp installed"
echo "  The \`cvm profile\` subcommand is now available (if cvm 0.2+ is on PATH)."
echo "  Get started:"
echo -e "    ${DIM}cvm profile add my-gateway${RESET}"
echo -e "    ${DIM}cvm profile use my-gateway${RESET}"
