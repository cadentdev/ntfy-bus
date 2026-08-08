# ntfy-bus

A Claude Code skill for sending and receiving messages on a private [ntfy](https://ntfy.sh/) bus, shared across agentic harnesses like LifeOS (formerly PAI) and vanilla Claude Code agents.

- Uses **Title-based routing** (`SENDER→RECIPIENT: subject`) for deterministic multi-agent communication. The body is pure payload — never repeats routing info.
- Agents communicate using the open-source, self-hosted **[ntfy](https://ntfy.sh/) messaging server** on a shared topic — the "bus" — that you can monitor in the browser or the ntfy mobile app.
- The optional **waker daemon** watches the bus in plain bash — zero model-token cost while idle; the agent wakes only when a message arrives for it.
- Optional **statusline indicator** displays the status of the bus monitor.
- Pairs with **Tailscale** (or any VPN/HTTPS) for an encrypted path to your bus from anywhere.
- Works in your **account-level** `~/.claude` configuration, or set up agent messaging in **multiple directories** or repos on the same machine.

## What it does

- **CheckInbox** — read recent messages addressed to this agent (or `ALL`). Prefers a local JSONL inbox written by the durable capture (see below); falls back to live HTTP polling.
- **Send** — emit a message with proper Title routing and body-size guard.
- **Watch** — long-poll for new traffic (foreground tail, or pointer to background daemon).
- **Setup** — one-time per-host config writer.

Optional components (activated per host, all config-driven):

- **Waker daemon** (`daemons/bus-waker-daemon.sh` + `systemd/bus-waker.service`) — durable, reaper-immune wake detector for systemd hosts. Follows the JSONL inbox, dedups by ntfy `.id` (`lib/dedup.sh`), logs wakes, fires an optional notify hook. NOTIFY-and-record only: a systemd process cannot re-invoke an idle in-session agent. Identity comes entirely from the host config — no agent name in the code.
- **Durable capture + in-session waker** (`daemons/ntfy-poll-to-jsonl.sh`, `daemons/ntfy-bus-waker.sh`, `hooks/arm-bus-waker.sh`) — the end-to-end receive path for hosts without a LifeOS systemd watcher. A scheduled poller (`ntfy-poll-to-jsonl.sh`, run by launchd on macOS or a systemd timer/cron on Linux) appends new bus messages to the per-agent JSONL inbox. The in-session waker (`ntfy-bus-waker.sh`) tails that inbox and *exits* on the first message addressed to the agent, which is what re-invokes an idle in-session Claude agent (the systemd daemon above can only notify). The SessionStart hook (`arm-bus-waker.sh`) detects a down waker and prompts the agent to re-arm it via the harness-tracked path. Identity comes entirely from host config.
- **Statusline segment** (`statusline/bus-segment.sh`) — emits `BUS: ⏻ armed` / `BUS: ⏚ DOWN` for the host statusline. Whether it appears, its label/icons, and what "armed" means (systemd daemon, in-session pidfile waker, or either) are all per-machine config.
- **Enforcement** (`bin/check.sh` portability gate, `bin/doctor.sh` host drift probe, repo `CLAUDE.md` doctrine) — keeps fleet code born-canonical.

## One config file per host (doctrine)

A **host**, throughout these docs, is one user account on one machine — everything anchors to `$HOME`, so a multi-user machine can carry several independent hosts. Everything host-specific lives in **one existing file**: `~/.claude/ntfy-bus.config.json`. Identity, waker mode, statusline appearance — same file. New knobs extend it with safe defaults; a config without the new blocks behaves exactly as before. On locked hosts (all LifeOS hosts, unconfigured vanilla hosts) **per-repo == per-host**: the host-global file is the single source of truth and repo-local configs are ignored. Never introduce a second config file for a per-host concern.

## Repo layout (plugin-shaped)

The skill proper lives at `skills/ntfy-bus/` (Claude Code plugin layout; manifest at `.claude-plugin/plugin.json`) — `SKILL.md`, `Workflows/`, `lib/`, `hooks/`, `daemons/`, `systemd/`, `launchd/`, and `statusline/` all live under it. Repo-root `bin/` holds maintainer tooling (the portability gate and host drift probe) and `tests/` the hermetic suite; neither is part of the installed skill. Install by symlinking `skills/ntfy-bus` into your skills directory (below) or via the plugin path.

## Installation

### LifeOS hosts

Your `~/.claude/` is typically owned by a LifeOS personal worktree using `showUntrackedFiles=no`, so a nested clone or symlink inside `~/.claude/skills/` won't pollute its status.

**Recommended pattern — canonical clone + symlink:**

```bash
# Canonical clone lives outside ~/.claude
git clone git@github.com:cadentdev/ntfy-bus.git ~/Repos/cadentdev/ntfy-bus

# Expose the skill (the skills/ntfy-bus subdirectory, not the repo root) via symlink
ln -s ~/Repos/cadentdev/ntfy-bus/skills/ntfy-bus ~/.claude/skills/ntfy-bus

# Optionally register the clone with whatever auto-sync your LifeOS setup runs
```

### Vanilla Claude Code hosts

Same pattern — clone anywhere, then symlink the skill subdirectory into your skills directory:

```bash
git clone git@github.com:cadentdev/ntfy-bus.git ~/Repos/cadentdev/ntfy-bus
ln -s ~/Repos/cadentdev/ntfy-bus/skills/ntfy-bus ~/.claude/skills/ntfy-bus
```

Updates: `git -C ~/.claude/skills/ntfy-bus pull` (git resolves the symlink to the clone).

### Plugin install (any harness that supports Claude Code plugins)

The repo is a valid Claude Code plugin with its own marketplace manifest:

```
/plugin marketplace add cadentdev/ntfy-bus
/plugin install ntfy-bus@cadentdev
```

The skill arrives namespaced as `ntfy-bus:ntfy-bus`. **Caveat (verified against the plugin docs):** installed plugins are *copied* to a versioned cache whose path changes on every update — fine for the skill and workflows, but do **not** point a systemd unit or statusline wiring into a plugin cache path. On plugin-installed hosts, copy `daemons/bus-waker-daemon.sh` (and wire the statusline segment) from a stable location instead — or just use the clone/symlink install, which avoids the cache entirely.

### Durable capture (the receive path — required on every receiving host)

Nothing is received until something writes the per-agent JSONL inbox that the wakers and CheckInbox read. `daemons/ntfy-poll-to-jsonl.sh` is that writer: a portable poller (bash + `curl`/`jq`) that appends new bus messages every couple of minutes. It is host-agnostic; only the scheduler is OS-specific. `NTFY_POLL_REPO` selects which repo's identity to poll as, and `EXPECT_AGENT` refuses to run as any other identity (shared-`$HOME` guard). Use **one scheduler entry per identity** on a shared-`$HOME` host — the inbox path comes from each identity's config (`.inbox_jsonl`, e.g. `~/.claude/ntfy-inbox.<agent>.jsonl`), never from code.

**macOS (launchd — cron fails silently without Full Disk Access):**

```bash
# Edit the __PLACEHOLDERS__ (agent, home, repo) in the template first.
cp ~/.claude/skills/ntfy-bus/launchd/ntfy-poll.plist.example \
   ~/Library/LaunchAgents/local.ntfy-poll.<agent>.plist
launchctl load ~/Library/LaunchAgents/local.ntfy-poll.<agent>.plist
launchctl list | grep ntfy-poll   # confirm it registered
```

**Linux (systemd timer):**

```bash
cp ~/.claude/skills/ntfy-bus/systemd/ntfy-poll.service ~/.config/systemd/user/
cp ~/.claude/skills/ntfy-bus/systemd/ntfy-poll.timer   ~/.config/systemd/user/
# Edit the two Environment= lines in ntfy-poll.service, then:
systemctl --user daemon-reload && systemctl --user enable --now ntfy-poll.timer
loginctl enable-linger $USER
```

### In-session waker (wakes an idle agent — any host)

The systemd waker daemon (below) can only *notify*; it cannot re-invoke an idle in-session Claude agent. `daemons/ntfy-bus-waker.sh` does that: the agent launches it as a **harness-tracked** background task, it tails the inbox, and it *exits* on the first message addressed to the agent — the exit is the wake. Wire `hooks/arm-bus-waker.sh` as a SessionStart hook so a down waker gets re-armed automatically. Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash ~/.claude/skills/ntfy-bus/hooks/arm-bus-waker.sh" } ] }
    ]
  }
}
```

The hook is detect-and-prompt only: it never launches the waker itself (a hook-spawned process is untracked by the harness and cannot wake the model) and never writes the pidfile. It points every host at the stable skill path — no host-local `~/.claude/bin` copy, which `bin/doctor.sh` would flag as drift.

### Waker daemon (durable notify — systemd or launchd)

**Order matters:** make sure your config carries the four required state
paths (`inbox_jsonl`, `waker.pidfile`, `waker.wakelog`, `waker.seen_ids` — see
the migration section below) **before** enabling the unit. A config missing any
of them makes the daemon exit `FATAL` and, with restart-on-exit, the unit
crash-loops — visible only in the unit's log, not on any terminal.

**Linux (systemd):**

```bash
cp ~/.claude/skills/ntfy-bus/systemd/bus-waker.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now bus-waker.service
loginctl enable-linger $USER
```

Crash-loop symptoms show in `journalctl --user -u bus-waker` (restarts every 5s).

**macOS (launchd):** the same daemon runs as a LaunchAgent —
`Type=simple` + `Restart=always` map to `RunAtLoad` + `KeepAlive`. Substitute
the placeholders in `launchd/bus-waker.plist.example` (its header documents
each one), then:

```bash
cp <edited copy> ~/Library/LaunchAgents/<label>.bus-waker.<agent>.plist
launchctl load ~/Library/LaunchAgents/<label>.bus-waker.<agent>.plist
launchctl list | grep bus-waker
```

Crash-loop symptoms show as a nonzero last-exit status in `launchctl list` and
`FATAL:` lines in the plist's `StandardErrorPath` log.

**Which config the daemon reads** — it follows normal config resolution, so
there are two supported shapes:

- **Single-identity host (the common case):** the daemon reads the
  **host-global** config, which carries the only `waker` block on the machine.
  Repo-local identity configs on such a host carry no `waker` block — don't
  launch the daemon from inside such a repo's working directory, or config
  resolution will hand it the repo-local file and it will fail loud.
- **Multi-identity host** (`per_repo_identity_allowed: true`): a per-repo
  identity can run its own waker. Put the `waker` block in that repo's
  `.claude/ntfy-bus.config.json` and pin `CLAUDE_PROJECT_DIR` to the repo in
  the unit/plist so resolution picks the repo-local config (the launchd
  example ships this as an optional key). One waker per identity, each with
  its own pidfile/wakelog/seen-ids paths — the configured paths are
  authoritative; nothing is derived from naming conventions.

The unit's `ExecStart` uses the stable `~/.claude/skills/ntfy-bus/...` path. All behavior knobs (`noise_senders`, `startup_tail`, file paths, notify hook) live in the host config's `waker` block. Its `Wants=ntfy-bridge-watcher.service` is soft: on a host whose capture is the poll timer above rather than a live LifeOS watcher, the daemon simply follows the inbox the timer writes.

The daemon **writes its PID to `.waker.pidfile` on start** (removed on exit) — that's how the statusline can report `armed` on hosts without systemd (macOS). It refuses to start if another live `bus-waker-daemon` already owns the pidfile.

### Config migration: state paths + pidfile

**State paths have no code defaults** (enforced by `bin/check.sh` section 6): a state path is a per-machine fact and lives only in the per-machine config. The daemon **fails loud** — refuses to start with a `FATAL:` naming the missing key — if any of these four are missing or empty: `inbox_jsonl`, `waker.pidfile`, `waker.wakelog`, `waker.seen_ids`. A leading `~/` in any of them is expanded to `$HOME`.

Fresh installs get working values from `config.example.json` via the Setup workflow. **Existing hosts must add the new/newly-required keys once** — merge (adjust paths to taste, keep your current wakelog/seen-ids paths if you already have them):

```bash
CFG=~/.claude/ntfy-bus.config.json
jq '.inbox_jsonl = (if (.inbox_jsonl // "") == "" then "~/.claude/ntfy-inbox.jsonl" else .inbox_jsonl end)
  | .waker.pidfile  = (if (.waker.pidfile  // "") == "" then "~/.claude/ntfy-bus.waker.pid" else .waker.pidfile end)
  | .waker.wakelog  = (if (.waker.wakelog  // "") == "" then "~/.claude/ntfy-bus.wake.log"  else .waker.wakelog end)
  | .waker.seen_ids = (if (.waker.seen_ids // "") == "" then "~/.claude/ntfy-bus.seen-ids"  else .waker.seen_ids end)' \
  "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
```

Hosts running their **own** waker scripts (not the shipped daemon): also set `waker.cmdline_match` to include your script's name — the shipped default now matches only `bus-waker-daemon` (fleet-private script names no longer ship in shared code).

### Statusline segment

Call the segment from your statusline script; it prints plain text (`BUS: ⏻ armed`) and stays silent (exit 2) when the host has no bus config or sets `statusline.enabled: false`:

```bash
seg=$("$HOME/.claude/skills/ntfy-bus/statusline/bus-segment.sh")
[ -n "$seg" ] && printf ' | %s' "$seg"   # position + colors are YOUR statusline's choice
```

Per-machine control, all in the one config file: `statusline.enabled` (whether it appears at all), `label` / `icon_armed` / `icon_down` (appearance), `show_when_down` (hide the DOWN state), and `waker.mode` (what "armed" means on this machine: `systemd`, `pidfile`, `auto` = either).

## Usage

There are two ways to drive the bus, and they are not interchangeable.

**From a Claude Code agent — the normal path.** The skill is auto-discovered from your skills directory. Ask for what you want in plain language and the agent picks the workflow:

```
"check the bus"                      → CheckInbox
"send Bob the gate results"          → Send
"watch the bus for new traffic"      → Watch
"set up the bus on this host"        → Setup
```

Or invoke it explicitly: `Skill("ntfy-bus")`.

**From the shell — for debugging, cron, and daemons.** Each workflow in `Workflows/` is a literal, copy-pasteable procedure. The snippets below are condensed; the workflow files are the source of truth and carry the failure modes.

### Your first message (smoke test)

If you can run this and see your own message come back, the install is good:

```bash
# 1. Resolve identity + auth exactly the way every workflow does
set -a; . "$HOME/.env" 2>/dev/null; . "$HOME/.claude/.env" 2>/dev/null; set +a
. "$HOME/.claude/skills/ntfy-bus/lib/resolve-config.sh"   # sets $NTFY_CONFIG
CONFIG="$NTFY_CONFIG"
AGENT_ID=$(jq -r '.agent_id'          "$CONFIG")
ENDPOINT=$(jq -r '.endpoint'          "$CONFIG")
TOPIC=$(jq -r '.topic'                "$CONFIG")
USER_VAR=$(jq -r '.auth_env.username' "$CONFIG")
PASS_VAR=$(jq -r '.auth_env.password' "$CONFIG")
NTFY_USER=$(eval "printf '%s' \"\${$USER_VAR}\"")   # NOT ${!VAR} — see "Shell portability"
NTFY_PASS=$(eval "printf '%s' \"\${$PASS_VAR}\"")

# 2. Send yourself a message
curl -s -u "${NTFY_USER}:${NTFY_PASS}" \
  -H "Title: ${AGENT_ID}→${AGENT_ID}: hello from $(hostname)" \
  --data-raw "install smoke test" \
  "${ENDPOINT}/${TOPIC}"

# 3. Read it back
curl -s -u "${NTFY_USER}:${NTFY_PASS}" "${ENDPOINT}/${TOPIC}/json?poll=1&since=2m"
```

Step 2 returns JSON containing an `id`. If step 3 shows that `id` with your Title, you are on the bus. If step 2 returns `40014 invalid request: attachments not allowed`, your body is over ~4096 bytes. If auth fails, your `.env` names don't match the `auth_env` names in your config.

### Send

Title is the routing carrier; body is pure payload.

```bash
curl -s -u "${NTFY_USER}:${NTFY_PASS}" \
  -H "Title: ${AGENT_ID}→${RECIPIENT}: ${SUBJECT}" \
  --data-raw "${BODY}" \
  "${ENDPOINT}/${TOPIC}"
```

- `RECIPIENT` is a known agent ID or `ALL`. **`ALL` is the broadcast address** — every agent's `recipient_filters` includes it, so `Dana→ALL: scope change` reaches the whole fleet.
- Group forms work: `Dana→Alice & Bob: ...` and `Dana→Bob, Alice: ...` both match Alice and Bob, because the matcher tokenizes the recipient half.
- **Never sign the body or prefix it with `[FROM→TO]`.** The Title already carries both endpoints. Repeating it in the body is the most common convention violation.
- **Bodies with apostrophes, quotes, `$`, backticks, or newlines must not be built as inline shell strings.** `BODY='today's gate is GREEN'` silently self-destructs — the apostrophe closes the quote, `$BODY` ends up empty, and curl cheerfully posts a title with an empty body, which *looks* like success. Write the body to a file and use `--data-binary @file` instead. See `Workflows/Send.md` Step 4.

### CheckInbox

Reads messages addressed to you (your `agent_id`) or to `ALL`, newest first. Two transports, same result — the workflow picks automatically:

- **JSONL path** — if `inbox_jsonl` is set and the file exists (a systemd watcher is filling it), it tails and filters locally. Fast, works offline.
- **HTTP path** — otherwise it polls `${ENDPOINT}/${TOPIC}/json?poll=1&since=10m`.

Filtering is not a naive substring match. It sources `lib/routing.sh` — the single source of truth — which scopes the match to the routing *header* (so a `->` in a subject line can't false-match), folds the pointer variants, and matches the recipient as a word token so group titles route correctly. **Don't hand-roll a matcher.**

### Watch

Long-poll for traffic as it arrives.

- **Foreground** (`curl` streaming `${ENDPOINT}/${TOPIC}/json` piped through the shared matcher) — for live debugging in a session. Ctrl-C to exit.
- **Background** — this skill does *not* install a daemon. On hosts with systemd, the optional waker daemon (see Installation) follows the watcher's JSONL. On vanilla hosts, a cron poll or a tmux pane running the foreground command is the pragmatic answer.

### The pointer character

`→` (U+2192) is canonical, but it's awkward to type. **Senders may use `→`, `➡️`, `👉`, plain ASCII `->`, or the word ` to `** (space-delimited, case-insensitive: `Alice to Bob:`, `Alice TO ALL:`) — all normalize to `→` before routing, so no message is ever dropped for using a substitute. Programmatic sends emit the canonical `→`.

The spaces around ` to ` are load-bearing: `Aliceto Bob:` doesn't route, and an agent named `Toby` is never split mid-word. One consequence is accepted by design: unlike the symbol pointers, ` to ` occurs naturally in English, so a plain-English header like `reply to Bob: draft attached` now routes to Bob (sender `reply`). The bus is private and the Title convention is the contract — the regression tests pin this as *routing*, deliberately.

## Per-host Configuration

All four workflows resolve the identity config through one shared guard (`lib/resolve-config.sh`). Resolution has two classes:

### Host-locked (LifeOS hosts, and unconfigured vanilla hosts)

If `~/.claude/PAI/` exists (the LifeOS marker directory — its on-disk name predates the rebrand) OR the host-global config does NOT set `per_repo_identity_allowed: true`, the host is **locked**: every workflow reads `~/.claude/ntfy-bus.config.json` and any repo-local identity config is ignored. There is one identity per machine, and it cannot be overridden by a cloned repo. This is the default-safe polarity — a fresh host you never reconfigured is locked.

### Vanilla opt-in (per-repo identity)

If a vanilla host's host-global config sets `per_repo_identity_allowed: true`, repo-local identity is unlocked: workflows prefer `<repo>/.claude/ntfy-bus.config.json` when present, falling back to host-global otherwise. This lets one machine carry per-repo identities — e.g. one repo sends as `Alice` while a sibling repo posts as its own agent.

### Why locked is the default

Without this guard, a LifeOS host that cloned an identity-bearing repo (one tracking `agent_id=Alice`) and ran Claude Code there would silently send bus messages as Alice — the resolver would pick up the repo-local config and the SENDER half of every Title would be wrong. The lock is enforced at two layers: the resolver IGNORES repo-local identity on locked hosts (read-time guard), and the Setup workflow REFUSES to write a repo-local identity config when `$HOME/.claude/PAI/` exists (write-time guard). Belt and suspenders.

### What the lock does and does not do

It is worth being precise, because a security property you misunderstand is worse than one you don't have.

**It blocks exactly one thing:** an untrusted repo's checked-in `.claude/ntfy-bus.config.json` silently making a locked host impersonate another agent on first clone-and-run. That is a real vector and the lock closes it.

**It does not defend against** a compromised host-global config, a modified resolver, or anyone simply calling `curl` against the ntfy topic directly. Identity here is a routing convention, not an authenticated claim — the Title is a string the sender asserts about itself. Every agent shares one set of ntfy credentials; the bus assumes a trusted set of hosts and defends the boundary *between repos on those hosts*, not the boundary between the fleet and the world. If you need cryptographic sender authentication, this design does not give it to you.

**There is no fourth install path.** LifeOS host + per-repo identity does not exist, by design — LifeOS hosts are always locked, and that is the security property the resolver enforces. The three paths are: LifeOS host (locked), vanilla host with one machine-wide identity, and vanilla host with per-repo identity (explicit opt-in).

### Generating the configs

Run the `Setup` workflow — it detects host class and writes the right shape:

- LifeOS hosts: writes ONLY `~/.claude/ntfy-bus.config.json` (host-global). Refuses to write a repo-local config even if asked.
- Vanilla hosts: prompts host-global-vs-per-repo at Step 0. Per-repo mode writes the tracked `<repo>/.claude/ntfy-bus.config.json` PLUS an untracked `<repo>/.claude/settings.local.json` (the hook wiring with the machine-specific bun path) PLUS a `.gitignore` entry.

Or copy the example files manually:

- `config.example.json` — the host-global schema (includes the `per_repo_identity_allowed` toggle)
- `config.repo-local.example.json` — the tracked per-repo schema (no toggle field; the toggle only lives host-global)

Secrets (`NTFY_USERNAME` / `NTFY_PASSWORD`) live in `~/.env` or `~/.claude/.env` and are referenced **by name** in the config. The config files carry no values. Use `.env.example` as a template:

```bash
cp ~/.claude/skills/ntfy-bus/.env.example ~/.claude/.env
$EDITOR ~/.claude/.env
chmod 600 ~/.claude/.env
```

In the current deployment every agent shares the same NTFY user/pass — per-agent identity rides in the Title routing convention, not in HTTP auth.

## Routing Convention (locked)

Every message uses the Title field as the sole routing carrier. Shape:

```
SENDER→RECIPIENT: subject
```

Examples:

| Title | Meaning |
|-------|---------|
| `Alice→Bob: Phase 0 results` | Alice talking to Bob |
| `Bob→Alice: ack — proceed` | Bob acknowledging Alice |
| `Dana→ALL: scope change` | Dana broadcasting to all agents |
| `Carol→Alice: status update` | Carol reporting to Alice |

The body is pure payload — never `[FROM→TO]`, never `—Alice` signature. The Title carries both endpoints.

## Body size

ntfy rejects bodies over ~4096 bytes with `40014 invalid request: attachments not allowed`. For long payloads, split into `(1/N)`, `(2/N)` titled messages and reassemble on the receive side.

**Two curl footguns when posting bodies to ntfy:**

1. **`-d @file` strips newlines.** When reading a body from file, the default `-d` flag silently collapses CR/LF, turning multi-line bodies (install snippets, code blocks, consolidation posts) into one wall of text. Use `--data-binary @file` instead — it preserves bytes exactly. Caught empirically: a multi-line install announcement shipped mangled because of this; the re-post used `--data-binary @file` to recover.
2. **`-d` and `--data-binary` treat a leading `@` as a filename.** If `${BODY}` starts with `@/some/path` (a pasted handle, a script artifact, anything), curl reads the file and POSTs its contents instead of the literal string — local file exfiltration via a bus message. For inline string bodies, prefer `--data-raw "${BODY}"`: it preserves newlines AND treats `@` literally. The Send workflow uses `--data-raw` for inline bodies and `--data-binary @file` for file-form payloads.

Inline string forms (`-d "$VAR"`, `--data-binary "$VAR"`, `--data-raw "$VAR"`) all preserve newlines — the strip behavior is specific to `-d`'s `@file` read path. The leading-`@` pitfall is the larger concern for inline content.

**Shell portability — no bash-only indirect expansion.** The config stores auth as env-var *names* (`NTFY_USERNAME`/`NTFY_PASSWORD`), so a workflow must dereference a name held in another variable. bash's `${!VAR}` indirect expansion is a **parse error in zsh** (`bad substitution`), and some vanilla hosts run zsh (the macOS default) — so `${!VAR}` in the documented curl auth line fails on exactly the hosts that use the HTTP path. The workflows resolve names to values with an `eval` form that works in bash, zsh, and POSIX sh:

```bash
NTFY_USER=$(eval "printf '%s' \"\${$USER_VAR}\"")
NTFY_PASS=$(eval "printf '%s' \"\${$PASS_VAR}\"")
curl -s -u "${NTFY_USER}:${NTFY_PASS}" ...
```

Placement matters: resolve *after* `~/.env` is sourced (CheckInbox loads env in Step 3b, so it resolves there, not in Step 1). The `eval` is safe because the variable names come from the trusted config, not user input. Caught empirically: the first attempt to send a bus message from a zsh host died on `${!USER_VAR}`.

## Hooks

Optional companion hooks ship alongside the skill in `hooks/`. They install separately from the skill code — adding a hook means editing `~/.claude/settings.json`, while the skill itself is auto-discovered by Claude Code from the skills directory.

### BridgeBodyGuard

PreToolUse hook on the `Bash` tool. Emits stderr WARN (never blocks) when a `curl` POST to the bus topic exceeds:

- body bytes > 4000 (ntfy ~4096 cap → `40014 invalid request: attachments not allowed`)
- Title header > 80 chars (bus convention)

Emits stderr INFO (also never blocks) when the body or title cannot be measured statically — shell-interpolated (`-d "$VAR"`), curl `@file` reference, or heredoc. Converts a silent miss into a visible "verify manually" signal at the cost of one extra stderr line.

The guard recognizes bus POSTs by matching `/<topic>` in the command, with the topic read from `~/.claude/ntfy-bus.config.json` (`.topic`) at hook time — not a hardcoded constant, so a fleet on any topic keeps the guard. Fail-open: missing/unreadable config or no `.topic` means the hook matches nothing and stays silent.

Always exits 0. Fails open on missing `bun`, malformed JSON, or unexpected error. Safe to install on LifeOS and vanilla hosts.

**Known limits** (caller should be aware; not enforced by the guard):

- Multiple `-d` / `--data*` flags on one curl: only the first match is measured. curl concatenates them with `&` in flight, so the guard under-counts.
- `--data-urlencode` post-encoding byte growth not modeled. Raw measurement can under-count borderline cases.

Three install paths, by host class and identity model. There is no fourth path (LifeOS host + per-repo identity) by design — LifeOS hosts are always host-locked, which is the security property the resolver enforces.

#### Install — LifeOS host (host-locked, host-global settings.json)

The canonical install pattern puts the repo at `~/Repos/cadentdev/ntfy-bus` with `~/.claude/skills/ntfy-bus` symlinked to its `skills/ntfy-bus` subdirectory. Wire the hook by adding this entry to `~/.claude/settings.json` under `hooks.PreToolUse[matcher="Bash"].hooks`:

```json
{
  "type": "command",
  "command": "$HOME/.claude/skills/ntfy-bus/hooks/BridgeBodyGuard.hook.ts"
}
```

LifeOS hosts are always host-locked (the resolver ignores any repo-local identity), so the hook lives at host-global scope and applies to every Claude Code session on the machine. Updates:

```bash
git -C ~/Repos/cadentdev/ntfy-bus pull --rebase
```

#### Install — vanilla host, one identity for the whole machine

Clone the repo and symlink the skill subdirectory, then add the same host-global settings entry as the LifeOS host:

```bash
git clone git@github.com:cadentdev/ntfy-bus.git ~/Repos/cadentdev/ntfy-bus
ln -s ~/Repos/cadentdev/ntfy-bus/skills/ntfy-bus ~/.claude/skills/ntfy-bus
```

Settings entry (same as LifeOS):

```json
{
  "type": "command",
  "command": "$HOME/.claude/skills/ntfy-bus/hooks/BridgeBodyGuard.hook.ts"
}
```

Updates: `git -C ~/.claude/skills/ntfy-bus pull --rebase`.

#### Install — vanilla host, per-repo identity

The `Setup` workflow handles this end-to-end. Run it (`Skill("ntfy-bus")` → Setup) and choose per-repo at Step 0. Setup writes three things:

1. **Tracked** `<repo>/.claude/ntfy-bus.config.json` — the repo's bus identity. Travels with the repo when other hosts clone it. No secrets (creds are env-var names).
2. **Untracked** `<repo>/.claude/settings.local.json` — the hook wiring entry, parameterized to the machine's bun interpreter path (e.g. `~/.bun/bin/bun` vs `/opt/homebrew/bin/bun`). Different on every host, so it stays out of git.
3. A `.gitignore` entry for `settings.local.json` so it can never be tracked by accident.

If you'd rather wire the hook by hand without the Setup workflow, see `Workflows/Setup.md` Step 6b for the jq-merge that adds the settings entry idempotently (re-running the merge against the same `settings.local.json` is a no-op).

#### All three install paths

The clone MUST be a real `git clone` of this repo at the path your settings entry points at — NOT a snapshot embedded inside another repo (e.g. `<project>/.claude/skills/ntfy-bus/`). Hooks ship as commits on `main` and updates arrive via `git pull`; a snapshot has no upstream remote and would silently miss bug fixes.

The snapshot-in-project-repo pattern (documented at `Workflows/Setup.md`) works for the skill *code* because the workflow files don't need live updates. It does NOT work for the hook code. If you already have a snapshot, leave it as a vendored fallback or remove it — your call — and create the standalone clone alongside.

## Running the tests

```bash
bash tests/run.sh      # exit 0 = all suites green
```

Hermetic — bash + jq only, no live bus, no network, no credentials, and no
installed skill: each suite builds a throwaway `$NTFY_HOME` with its own
config and hand-written inbox JSONL, and the scripts under test resolve their
libs relative to their own real location, so a fresh clone runs the whole
suite as-is. Suites cover the routing matcher, the dedup ledger, the
host-lock/identity resolver, the SessionStart arm hook, and the in-session
waker's gap recovery. A suite exiting 2 means SKIP (missing
dependency), reported without failing the run.

This sits beside `bin/check.sh`, not instead of it: `check.sh` is the
portability/doctrine lint ("is the code clean"), `tests/run.sh` is behavior
("does it work"). Run both before pushing.

Deferred by decision, not oversight: capabilities probe, statusline segment,
the bun BridgeBodyGuard hook, the systemd daemon's notify path, and
Workflows doc-drift checks.

## Why this design

- **One repo, many agents** — LifeOS hosts and vanilla Claude Code hosts all run the same skill code.
- **Hybrid read path** — LifeOS hosts read from the systemd-watcher JSONL (fast, offline-tolerant); vanilla hosts poll over HTTP. Same caller API, different transports.
- **Per-host config outside the repo** — agent identity and inbox path differ per host. The split is the actual important boundary, not the repo split.
- **No LifeOS dependency in the skill itself** — works on a clean vanilla Claude Code install.
- **Host-locked by default** — LifeOS hosts (and unconfigured vanilla hosts) always read their host-global identity; repo-local identity is ignored. This prevents one specific vector: an untrusted repo's checked-in `.claude/ntfy-bus.config.json` making a locked host impersonate another agent on its first clone+run. (It does NOT defend against a compromised host-global config, a modified resolver, or direct `curl` to ntfy — those are outside this guard's scope.) Opting INTO per-repo identity is explicit (`per_repo_identity_allowed: true` in the host-global config); the locked state is implicit.
- **Per-repo identity on vanilla (opt-in)** — when a vanilla host unlocks per-repo mode, the atomic unit of identity becomes the repo, not the machine. One machine can carry two repos with two identities simultaneously, with the bus correctly attributing each via the Title-routing convention.

## License

MIT — see [LICENSE](LICENSE).
