# Changelog

All notable changes to ntfy-bus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). The project is **beta**: versions
stay 0.x until the fleet declares the surface stable, and minor versions may
change behavior (each such change is called out under **Security** or
**Changed** with its migration note).

The root `VERSION` file is the source of truth; `bin/check.sh` §10 enforces
that it, this file's top entry, and `.claude-plugin/plugin.json` agree.

## [0.3.3] — 2026-11-11

One bad inbox line, or one odd message id, no longer costs mail.

### Fixed
- **A corrupt line in the inbox JSONL no longer hides every message after
  it** (#52). The in-session waker (`daemons/ntfy-bus-waker.sh`) and
  CheckInbox's JSONL read fed the inbox to one `jq`, which stops at the first
  line it cannot parse; with stderr discarded, everything after that line was
  silently invisible — no wake, nothing listed — until the line scrolled out
  of the scan window (1000 lines for the waker, 200 for CheckInbox). Both now
  read line by line (`jq -R` + `fromjson?`) and skip a line that is not a
  JSON object. The bad line itself is skipped without a notice.
- **A message id starting with `-` is now remembered as seen** (#52).
  `bus_seen` (`lib/dedup.sh`) passed the id to `grep` without `--`, so it was
  read as options: the id never matched and the message re-woke on every
  arm, and an id of `-e` made grep read the caller's stdin, swallowing the
  rest of that scan. Real ntfy ids are alphanumeric; this is hardening.
- **Messages with no `.id` are each delivered once** (#52). The waker
  recorded a missing id as the literal `null`, so the first id-less message
  woke and every later one was suppressed. A missing or empty id now falls
  back to `time:title`, the same key the durable daemon already uses.

### Changed
- The waker and CheckInbox now require the inbox to be JSONL — one object per
  line — which is what the poller and the LifeOS watcher both write. A
  pretty-printed object spanning several lines was readable before and is
  skipped now.

## [0.3.2] — 2026-11-10

Plugin-only installs can run the Workflows.

### Fixed
- **Setup, Send, CheckInbox, and Watch no longer assume the skill is at
  `~/.claude/skills/ntfy-bus/`** (#55). On a plugin-only install that path
  does not exist — the skill lives in the plugin cache — so every Workflow
  stopped at its first line (Setup since 0.3.1, the others before). Snippets
  now look at the stable path first and, only when nothing at all is there,
  in `NTFY_SKILL_DIR`, which the agent sets to the skill's base directory
  (absolute; "Finding the skill directory" in `SKILL.md`). With neither, they
  stop; Setup still never continues as `vanilla`.
  **No change on a host with anything at the stable path** — a working
  install, a broken link, a stale copy: it wins, `NTFY_SKILL_DIR` is not
  read, and a broken install stops exactly as before.

### Changed
- Setup Step 6b wires the BridgeBodyGuard hook only when the hook file exists
  at the stable path, and says `NOT wiring` otherwise. It used to write the
  entry unconditionally; a hook entry naming a missing file fails on every
  Bash call. The plugin cache path is never wired (it moves on every update).
- `bin/check.sh` §12 fails a Workflow code block that spells the lib's fixed
  install path.
- Setup Step 8 skips `bin/doctor.sh` when no clone sits behind the stable
  path, instead of running whatever `bin/doctor.sh` is one directory up; it
  now also follows a relative install symlink correctly.

### Security
- On a plugin-only host the resolver — lock included — is whatever
  `NTFY_SKILL_DIR` names. A host that needs the lock to hold should keep the
  stable path, where the variable is never read (`SKILL.md`, "What this
  trusts").

### Known gaps (plugin-only)
- The durable poller, waker units, cron, statusline segment, and
  BridgeBodyGuard hook still need the stable path. Add a clone + symlink install for those.

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
  Anything by a marker's name counts — a directory, a file, or a symlink
  whose target is missing — because a lock should lean locked.
  **Migration:** a LifeOS host that opted into per-repo identity while
  misclassified becomes host-locked on upgrade. What the operator sees:
  - sessions in those repos resolve, send, and arm wakers as the
    **host-global** identity; the repo-local identity configs are no longer
    read;
  - a per-repo poller with `EXPECT_AGENT` refuses on every run (`identity
    guard: resolved '<host>' != expected '<repo agent>'`), so that agent's
    inbox stops growing; one without `EXPECT_AGENT` polls as the host agent;
  - `bin/doctor.sh` reports DRIFT naming the flag.

  To finish the move: set `per_repo_identity_allowed` to `false`, remove the
  per-repo poller units, and make sure the host identity has its own poller.

### Changed
- One predicate, `ntfy_lifeos_marker` (with `ntfy_host_class`) in
  `lib/resolve-config.sh`, now answers "is this a LifeOS host" for the
  resolver, Setup, `bin/onboard.sh`, and `bin/doctor.sh`. `bin/check.sh` §11
  fails a marker path spelled out in shared shell code or in a doc's code
  block (it does not catch a path assembled from parts).
- `ntfy_lock_reason` prints `lifeos-marker` where it printed `pai-marker`.
- Setup asks the lib for the host class in Steps 0, 5, and 6 — each on its
  own, since snippets may run in separate shells — and stops when it cannot
  tell, instead of defaulting to `vanilla`. Setup now needs the skill
  reachable at `~/.claude/skills/ntfy-bus/`, as Send, CheckInbox, and Watch
  already did.
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
