# Changelog

All notable changes to ntfy-bus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). The project is **beta**: versions
stay 0.x until the fleet declares the surface stable, and minor versions may
change behavior (each such change is called out under **Security** or
**Changed** with its migration note).

The root `VERSION` file is the source of truth; `bin/check.sh` §10 enforces
that it, this file's top entry, and `.claude-plugin/plugin.json` agree.

## [0.3.1] — 2026-11-10

LifeOS hosts are recognized again.

### Security
- **Host-class detection accepts the current LifeOS marker** (#46). Detection
  looked only for `~/.claude/PAI/`, which current LifeOS no longer creates (it
  creates `~/.claude/LIFEOS/`). Such a host was classed `vanilla`: Setup offered
  it per-repo identity, `bin/onboard.sh` skipped its LifeOS refusal, and once
  `per_repo_identity_allowed: true` was written the read-time lock was off too
  — a cloned repo carrying a tracked identity config could then send as that
  agent. Either marker now counts, and the marker wins over the opt-in flag.
  **Migration:** a LifeOS host that opted into per-repo identity while
  misclassified becomes host-locked on upgrade — its repo-local identity
  configs stop being read and every session resolves the host-global identity.
  `bin/doctor.sh` warns on that state; set `per_repo_identity_allowed` to
  `false` there.

### Changed
- One predicate, `ntfy_lifeos_marker` (with `ntfy_host_class`) in
  `lib/resolve-config.sh`, now answers "is this a LifeOS host" for the
  resolver, Setup, `bin/onboard.sh`, and `bin/doctor.sh`. `bin/check.sh` §11
  fails any inline marker-directory probe elsewhere.
- `ntfy_lock_reason` prints `lifeos-marker` where it printed `pai-marker`.
- Setup Step 0 asks the lib for the host class and stops if it cannot tell,
  instead of defaulting to `vanilla`; `HOST_CLASS` is `lifeos`, not `pai`.
- `bin/doctor.sh` prints the detected host class and the marker (or lock
  state) that produced it.

## [0.3.0] — 2026-11-10

The in-session waker drains instead of single-stepping.

### Changed
- **One wake now retires every addressed, unseen message, and reports a
  count** (#44, #49). The wake line is now a summary followed by dated titles:

  ```
  WAKE: 3 messages (3 backlog, 0 new)
    [2026-11-10] Dana→Gus: first
    [2026-11-10] Dana→ALL: second
    [2026-11-10] Dana→Gus: third
    (backlog = found waiting at arm time, not live arrivals; check the dates — some may already be handled)
  ```

  `backlog` = found by the arm-time gap scan; `new` = landed while the arm was
  live. At most `NTFY_WAKER_LIST_MAX` titles (default 20, newest) are listed;
  the count always covers everything retired, and the overflow line names the
  inbox file and scan window so the unlisted ones can be found. **Migration:** anything that
  parsed `WAKE: <title>` must read the title lines below the summary instead.
  The first line still starts with `WAKE:` and there is still exactly one per
  wake.

### Fixed
- **Silent loss of live traffic** (#49): one arm retired one message, so when
  arrivals outpaced re-arms the remainder stayed queued and never woke anyone.
- **Backlog replayed one agent turn per message** (#44): a re-arm after a long
  unarmed stretch stepped through already-handled mail one arm at a time,
  which read as the waker crashing on startup.

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
