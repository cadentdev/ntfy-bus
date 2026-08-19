# Changelog

All notable changes to ntfy-bus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). The project is **beta**: versions
stay 0.x until the fleet declares the surface stable, and minor versions may
change behavior (each such change is called out under **Security** or
**Changed** with its migration note).

The root `VERSION` file is the source of truth; `bin/check.sh` §10 enforces
that it, this file's top entry, and `.claude-plugin/plugin.json` agree.

## [0.2.0] — 2026-08-18

The identity-hardening wave: seventeen issues closed via PRs #30–#40,
completing ROADMAP Phase 1 ("close the identity layer").

### Security
- **Unmarked outside-repo resolution now refuses on opt-in hosts** (#9 phase 2,
  #37, PR #40): outside any git work tree, without `NTFY_DAEMON_CONTEXT=1`, the
  resolver returns source `none` instead of silently resolving the host-global
  identity. Host-locked hosts are unaffected by construction (the lock
  short-circuits first) and need no unit edits. **Migration:** daemons on
  opt-in hosts must set `NTFY_DAEMON_CONTEXT=1` in their installed units (the
  shipped systemd/launchd templates already do); cron/interactive runs declare
  identity via a repo cwd or `CLAUDE_PROJECT_DIR`.
- Explicit daemon-context marker introduced, phase 1 warn-and-allow (#9,
  PR #35); all shipped unit templates carry it.
- `Send`/`CheckInbox`/`Watch` now hard-gate on a resolved identity via
  `ntfy_require_config` — an unresolved identity refuses instead of acting
  with empty variables (#8, PR #33); the source-implies-gate pairing is
  enforced by `bin/check.sh` §8 (extended to README snippets in PR #40).
- Waker pidfile claims are atomic (noclobber `O_CREAT|O_EXCL`), eliminating a
  reproduced check-then-write race that let two wakers share one pidfile
  (#29, PR #32).

### Added
- `bin/onboard.sh` — idempotent per-repo onboarding for opt-in hosts: writes
  the untracked repo config from the host's fleet settings, fences it via the
  worktree-safe local exclude *before* writing, wires the BridgeBodyGuard
  hook, installs the scheduler unit, and prints the steps needing a human
  (#21, PR #39).
- `ntfy-waker-status.sh` reports the two waker JOBS distinctly — session waker
  (wake-capable) vs durable daemon (notify-only) — so the healthy pair no
  longer reads as a duplicate; the daemon pidfile is config-declared evidence
  (#27, PR #32).
- Versioning and this changelog: root `VERSION` file as source of truth, with
  a `bin/check.sh` §10 consistency gate across VERSION / CHANGELOG /
  plugin.json (#42).

### Fixed
- Poller: `EXPECT_AGENT` folds case on both sides, so a correctly-resolved
  identity is never refused for capitalization (#5, PR #30).
- Poller: a repo path is required only on hosts where the repo selects
  identity; a stale `NTFY_POLL_REPO` on a locked host logs a cleanup note
  instead of killing capture (#12, PR #30).
- Doctor: shadow scan follows symlinked roots (`find -L`) and flags a tracked
  identity config on any host (#13, #19, PR #31).
- `ntfy-poll-install.sh` ships inside the skill (`skills/ntfy-bus/bin/`), so
  plugin installs carry it and PATH shims resolve (#22, PR #34).
- Source-aware error messages in the waker daemon, waker status, and doctor:
  an unresolved identity names the marker or repo cwd as the remedy instead
  of the wrong "run the Setup workflow" (PR #40).

### Docs
- Setup workflow onboarding rewritten: fence-first config write, host-global
  hook install, honest self-send smoke test, green-doctor finish
  (#23–#26, PR #36).
- README/SKILL.md teach the post-PR#7 identity model; per-machine → per-host
  terminology sweep; Send recipient shape validation documented
  (#3, #10, #18, PR #38).
- Cron recipes declare identity explicitly (`NTFY_DAEMON_CONTEXT=1` or
  `CLAUDE_PROJECT_DIR`) (PR #40).

## [0.1.0] — 2026-08-11

Retroactive baseline: the state of `main` at 23ba08c, before the hardening
wave. Core bus as deployed on the first fleet hosts:

- `SENDER→RECIPIENT:` Title routing with `→ALL` broadcast and pointer-character
  normalization.
- Shared identity resolver (`lib/resolve-config.sh`) with the host-locked
  guard: locked by default, per-repo identity as explicit opt-in.
- Durable capture poller (`ntfy-poll-to-jsonl.sh`), in-session waker,
  durable notify daemon, statusline segment, BridgeBodyGuard hook.
- Workflows: Send, CheckInbox, Watch, Setup.
- Portability/doctrine gate (`bin/check.sh`), host drift probe
  (`bin/doctor.sh`), hermetic test suite.
- Linux `INBOX AGE` fix and waker-status moved into the skill (PRs #16, #20).
