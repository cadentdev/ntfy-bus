# ntfy-bus — contributor doctrine

This repo ships code that runs on many machines at once — LifeOS hosts and
vanilla Claude Code installs, macOS and Linux, bash and zsh. These rules bind
every contributor (human or agent) authoring code here.

## Born canonical

If it will run on more than one host, its **first commit is here** — never a
private copy in one host's `~/.claude/`. Host-side hotfixes are allowed during
incidents, but must land canonical promptly. Hosts carry only untracked
per-host state: `ntfy-bus.config.json`, inbox JSONL, wake-log/seen-ids,
installed systemd unit copies, notify hooks.

## Portability floor

- `lib/`, `daemons/`, `statusline/`, Workflows: **bash + jq only**. POSIX/zsh-safe
  (no `${!VAR}` indirection — it is a parse error in zsh and has broken real
  hosts).
- bun/TypeScript permitted only in `hooks/`, and only fail-open.
- No hardcoded homes, hostnames, or agent names in shared code. Identity comes
  from `lib/resolve-config.sh`; host differences from `lib/capabilities.sh`
  (capabilities, never host class).

## Config is the only per-host surface

One host-global file — `~/.claude/ntfy-bus.config.json` — is the source of
truth for everything host-specific: identity, waker mode, statusline
appearance. New per-host knobs extend that file (with safe defaults);
never invent a second config file. On locked hosts, per-repo == per-host.

**Exception — state paths have NO defaults.** Identity (`agent_id`) and state
paths (pidfile, inbox, wake-log, seen-ids, locks) are per-host FACTS, not
knobs: code must read them from config and **fail loud** when absent, never
fall back to a baked-in path (`bin/check.sh` section 6 enforces this). A knob
with a safe default degrades gracefully; a defaulted state path points shared
code at one specific host's filesystem layout — a real bug class this repo
has already hit once.

## Security carve-out (never refactor away)

The host-locked identity guard in `lib/resolve-config.sh` is a **security
property**, not a capability or a portability wart. Default polarity is
locked. Read-time and write-time guards stay. See the README's "What the lock
does and does not do" before touching anything near it.

## Before pushing main

Run `bin/check.sh` (portability/doctrine gate) and `bash tests/run.sh`
(behavior). Both must be green.
