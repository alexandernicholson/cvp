# CVP — Claude (Code) Profile Manager

A [cvm](https://github.com/alexandernicholson/cvm) plugin that manages named
**profiles** of environment variables — a custom inference gateway's
`ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, and
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, plus any others — and applies the active
one to every `claude` invocation, **per-directory or globally, without ever
losing saved keys or URLs**.

```bash
cvm plugin install alexandernicholson/cvp
cvm profile add my-gateway     # prompts for base URL, token, flags
cvm profile use my-gateway     # global alias (settings untouched)
cvm profile local work         # pin this directory to another profile
claude                         # picks up the right gateway/keys automatically
```

The global "active profile" is just an **alias** — a name stored in
`~/.cvm/active-profile` pointing at `~/.cvm/profiles/<name>.env`. Switching
profiles only rewrites the alias; the profile definition files are never moved
or modified, so you can switch back and forth freely.

> Requires **cvm ≥ 0.2** (the version that ships the plugin manager + the
> `~/.cvm/env.d/*.sh` env-hook wrapper).

---

## Table of Contents

- [Install](#install)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Profile Resolution](#profile-resolution)
- [How it works (design)](#how-it-works-design)
- [Per-project profiles](#per-project-profiles)
- [Secrets & security](#secrets--security)
- [Standalone use (without cvm)](#standalone-use-without-cvm)
- [Development](#development)

---

## Install

```bash
cvm plugin install alexandernicholson/cvp
```

Or, if you don't have the cvm plugin manager yet:

```bash
curl -fsSL https://raw.githubusercontent.com/alexandernicholson/cvp/main/install.sh | bash
```

Verify:

```bash
cvm profile help
```

## Quick Start

```bash
# 1. Define a profile (interactive prompts for the known gateway vars)
cvm profile add my-gateway
#   ANTHROPIC_BASE_URL: https://my-gateway.example.com
#   ANTHROPIC_API_KEY: sk-...
#   CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1

# 2. Activate it globally
cvm profile use my-gateway

# 3. Run claude — the wrapper sources the profile's env vars automatically
claude --version
```

Switch to another profile without losing `my-gateway`:

```bash
cvm profile add prod-gateway
cvm profile use prod-gateway        # only the alias changes
cvm profile use my-gateway          # instant — keys/URLs intact
```

## Commands

| Command | Description |
|---|---|
| `cvm profile add <name>` | Create or edit a profile (prompts for known + custom vars) |
| `cvm profile use <name>` | Set the global active profile (alias only — settings untouched) |
| `cvm profile local <name>` | Pin this directory to a profile (writes `.claude-profile`) |
| `cvm profile local --unset` | Remove the directory's `.claude-profile` |
| `cvm profile current` | Print the resolved profile name (or `none`) |
| `cvm profile ls` | List profiles (marks the active one) |
| `cvm profile show [name]` | Display a profile's vars (secrets masked) |
| `cvm profile edit <name>` | Open a profile in `$EDITOR` (default `vi`) |
| `cvm profile remove <name>` | Delete a profile (clears the alias if active) |
| `cvm profile env [name]` | Print `export` lines for `eval` (real values) |
| `cvm profile apply` | (Re)install the `~/.cvm/env.d/cvp.sh` resolver |
| `cvm profile help` | Show help |

### Adding custom variables

`add` prompts for the three known gateway vars, then lets you add any number of
custom `KEY=VALUE` pairs. You can also edit the file directly:

```bash
cvm profile edit my-gateway
```

Profile files are simple `.env`:

```bash
# Profile: my-gateway
ANTHROPIC_BASE_URL='https://my-gateway.example.com'
ANTHROPIC_API_KEY='sk-...'
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='1'
```

> **Why `ANTHROPIC_API_KEY` and not `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_AUTH_TOKEN`?**
> `ANTHROPIC_API_KEY` is the only auth var that works in **both** the env.d shim
> (real env var, for the lead) **and** `~/.claude/settings.json` `env` (for
> teammates, which bypass the shim). Claude Code's docs say it "is used instead
> of your subscription even if you are logged in." `CLAUDE_CODE_OAUTH_TOKEN` only
> overrides keychain creds and is ignored when a session is active.
> `ANTHROPIC_AUTH_TOKEN` (raw `Authorization: Bearer`) works as a real env var
> but is **ignored** when set via `settings.json` `env` — so teammates wouldn't
> get it. You can still add either manually via `cvm profile edit` if your
> gateway specifically needs them (lead-only).

## Profile Resolution

Resolution happens **at `claude` runtime** inside cvm's env-hook wrapper, so a
per-directory change takes effect immediately (no shell reload):

```
$CVM_PROFILE env var          (highest priority)
    ↓
.claude-profile file          (walks up from $PWD to /)
    ↓
~/.cvm/active-profile         (global alias, set by cvm profile use)
    ↓
(none — no profile applied)
```

Override for a single command:

```bash
CVM_PROFILE=prod-gateway claude
```

## How it works (design)

```
~/.cvm/
├── profiles/
│   ├── my-gateway.env        ← profile definition (keys/URLs/flags) — never moved
│   └── prod-gateway.env
├── active-profile            ← global alias: just the name, e.g. "my-gateway"
└── env.d/
    └── cvp.sh                ← resolver sourced by cvm's claude wrapper
~/.claude/
└── settings.json             ← `env` block cvp merges the GLOBAL profile into
                                (so teammates — separate claude instances that
                                bypass the shim — still get the gateway/keys)
```

cvp uses **two injection paths** so both the lead and teammates get the profile:

1. **`env.d` shim** (`~/.cvm/env.d/cvp.sh`, sourced by cvm's `claude` wrapper):
   applies the **resolved** profile (`$CVM_PROFILE` → `.claude-profile` walk-up →
   global alias) to the **lead** at runtime — this is what makes per-directory
   profiles work with no shell reload.
2. **`~/.claude/settings.json` `env` block**: cvp merges the **global** profile's
   vars here. Claude Code reads this at startup *"no matter how `claude` was
   launched"*, so **teammates** (separate Claude Code instances the lead spawns,
   which bypass the shim) still pick up `ANTHROPIC_BASE_URL` /
   `ANTHROPIC_API_KEY` / flags. Only the `env` sub-object is touched; all
   other settings (`model`, `permissions`, `statusLine`, …) are preserved, and a
   one-time `settings.json.cvp-backup` is kept. cvp tracks the var names it owns
   (in `~/.cvm/profiles/.settings-managed`) so switching profiles replaces its
   own vars without clobbering user-added `env` entries.

> **Per-directory caveat for teammates**: the `env.d` shim resolves per-dir for
> the lead, but teammates read the **global** `settings.json` env. So a
> per-directory profile applies to the lead only; teammates use the global
> profile. Set `CVP_NO_SETTINGS_SYNC=1` to disable settings sync entirely.

1. `cvm profile use <name>` writes the name to `~/.cvm/active-profile` and
   (re)installs the `env.d/cvp.sh` resolver. **It never touches profile data.**
2. When you run `claude`, cvm's wrapper sources `env.d/cvp.sh`, which resolves
   the active profile (env > `.claude-profile` walk-up > `active-profile`) and
   `export`s that profile's variables for the current process only.
3. `exec`s the real `claude` binary, which sees the injected environment.

Because the alias is decoupled from the profile settings, switching is O(1) and
non-destructive — this is the "global profile is an alias" design.

## Per-project profiles

```bash
cd ~/work/prod-project
cvm profile local prod-gateway     # writes .claude-profile in this dir
```

Commit `.claude-profile` to share the pin across your team. (The `.env` files
under `~/.cvm/profiles/` are per-machine secrets — don't commit those.)

## Secrets & security

- Profile `.env` files live under `~/.cvm/profiles/` with mode `0700`-ish
  permissions inherited from your home dir; treat them as secrets.
- `cvm profile show` masks values whose variable name matches
  `TOKEN|KEY|SECRET|PASSWD|PASSWORD|CREDENTIAL`.
- `cvm profile env` prints **real** values (it's meant for `eval`) — only run it
  when you intend to expose them to the current shell.

## Standalone use (without cvm)

You can use cvp without the cvm plugin dispatcher:

```bash
~/.cvm/plugins/cvp/cvp.sh profile use my-gateway
```

or install just the resolver and use `eval`:

```bash
~/.cvm/plugins/cvp/cvp.sh profile apply
eval "$(~/.cvm/plugins/cvp/cvp.sh profile env)"
```

## Development

```bash
make test           # run the bats suite
make test-verbose   # tap output
make lint           # bash -n syntax check
```

Tests use [bats-core](https://github.com/bats-core/bats-core) and run in an
isolated `$CVM_DIR` temp directory — they never touch `~/.cvm`.
