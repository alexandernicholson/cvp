#!/usr/bin/env bash
# cvp — plugin manifest for cvm
# https://github.com/alexandernicholson/cvp
#
# Registers the `cvm profile ...` subcommand. The implementation is loaded
# lazily (only when the command actually runs) so that command-discovery in
# cvm stays cheap: cvm sources this file just to read CVM_PLUGIN_COMMAND.

CVM_PLUGIN_NAME="cvp"
CVM_PLUGIN_COMMAND="profile"
CVM_PLUGIN_VERSION="0.1.3"
CVM_PLUGIN_DESCRIPION="Claude Code profile manager — switch gateway/keys per-dir or globally"

_CVP_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cvm_plugin_main() {
  # shellcheck disable=SC1091
  source "$_CVP_PLUGIN_DIR/cvp.sh"
  cvp_main "$@"
}

# Post-install/update hook (called by cvm's plugin manager). Seeds the built-in
# `default` profile (official Claude Code), installs the env.d resolver, and
# activates `default` only if no profile is active yet.
cvm_plugin_init() {
  # shellcheck disable=SC1091
  source "$_CVP_PLUGIN_DIR/cvp.sh"
  cvp_init
}
