# CVP User Guide

CVP (Claude Code Profile Manager) is a [cvm](https://github.com/alexandernicholson/cvm)
plugin that manages named **profiles** of environment variables and applies the
active one to every `claude` invocation — per-directory or globally — without
ever losing saved keys or URLs.

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Profiles](#profiles)
- [Switching Profiles](#switching-profiles)
- [Per-project Profiles](#per-project-profiles)
- [Inspecting Profiles](#inspecting-profiles)
- [The `env` command](#the-env-command)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)

---

## Requirements

- **cvm ≥ 0.2** — the version with the plugin manager and the `~/.cvm/env.d/*.sh`
  env-hook `claude` wrapper. (On Windows native/PowerShell the env-hook wrapper
  is not available; use `eval "$(cvm profile env)"` instead.)

## Installation

```bash
cvm plugin install alexandernicholson/cvp
cvm profile help
```

Or standalone:

```bash
curl -fsSL https://raw.githubusercontent.com/alexandernicholson/cvp/main/install.sh | bash
```

## Quick Start

```bash
cvm profile add my-gateway
#   ANTHROPIC_BASE_URL: https://my-gateway.example.com
#   CLAUDE_CODE_OAUTH_TOKEN: sk-...
#   CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1

cvm profile use my-gateway
claude --version      # picks up the gateway + token + flag automatically
```

## Profiles

A profile is a plain `.env` file at `~/.cvm/profiles/<name>.env`:

```bash
# Profile: my-gateway
ANTHROPIC_BASE_URL='https://my-gateway.example.com'
CLAUDE_CODE_OAUTH_TOKEN='sk-...'
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='1'
```

Create or edit one interactively:

```bash
cvm profile add my-gateway        # prompts for the known vars + any custom ones
cvm profile edit my-gateway       # open in $EDITOR
```

`add` prompts for `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_OAUTH_TOKEN`, and
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, then lets you add arbitrary custom
`KEY=VALUE` pairs. Any `KEY=VALUE` line is allowed.

## Switching Profiles

```bash
cvm profile use prod-gateway      # set the global active profile
cvm profile use my-gateway        # switch back instantly
```

Switching only rewrites the alias (`~/.cvm/active-profile`); the profile
definition files are **never** modified, so no keys/URLs are ever lost.

## Per-project Profiles

```bash
cd ~/work/prod-project
cvm profile local prod-gateway    # writes .claude-profile in this directory
```

A `.claude-profile` in the current directory (or any ancestor) overrides the
global alias. Commit it to share the pin with your team.

Clear a local pin:

```bash
cvm profile local --unset
```

## Inspecting Profiles

```bash
cvm profile ls                    # list profiles, mark the active one
cvm profile current               # print the resolved profile name
cvm profile show                  # active profile (secrets masked)
cvm profile show my-gateway       # a specific profile
cvm profile remove my-gateway     # delete a profile
```

## The `env` command

`cvm profile env` prints real `export` lines for the resolved profile. You don't
normally need it (the env-hook wrapper handles this automatically), but it's
useful for shells without the wrapper or for one-off application:

```bash
eval "$(cvm profile env)"
```

> `env` prints **real** (unmasked) values, including secrets — only run it when
> you intend to expose them to the current shell.

## How It Works

```
~/.cvm/
├── profiles/<name>.env    ← profile definitions (keys/URLs/flags) — never moved
├── active-profile         ← global alias: just the name
└── env.d/cvp.sh           ← resolver sourced by cvm's claude wrapper
```

1. `cvm profile use <name>` writes the name to `~/.cvm/active-profile` and
   installs the `env.d/cvp.sh` resolver. Profile data is untouched.
2. When you run `claude`, cvm's wrapper sources `env.d/cvp.sh`, which resolves
   the active profile (`$CVM_PROFILE` → `.claude-profile` walk-up →
   `active-profile`) and `export`s its variables for the current process.
3. `exec`s the real `claude` binary, which sees the injected environment.

Resolution happens at runtime, so per-directory changes take effect immediately
(no shell reload).

## Troubleshooting

### `cvm profile: command not found` / falls back to "Unknown command"

Either cvp isn't installed (`cvm plugin install alexandernicholson/cvp`) or your
cvm is older than 0.2 (upgrade with `cvm self-update`).

### Profile vars not applied to `claude`

- Run `cvm profile apply` to (re)install the resolver.
- Check the resolver exists: `ls ~/.cvm/env.d/cvp.sh`.
- Confirm the active profile: `cvm profile current`.
- On Windows native/PowerShell the env-hook wrapper isn't used; run
  `eval "$(cvm profile env)"` instead.

### Switching profiles didn't change the gateway

Resolution is `$CVM_PROFILE` → `.claude-profile` → global alias. A stale
`.claude-profile` or `$CVM_PROFILE` in your shell will override `cvm profile use`.
Check with `cvm profile current`.
