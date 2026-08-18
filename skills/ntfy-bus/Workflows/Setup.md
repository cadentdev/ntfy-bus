# Setup

Per-host (and, on vanilla hosts, per-repo) setup of the bus identity.

Identity resolution is governed by the shared guard in `lib/resolve-config.sh`.
This workflow writes the config(s) that guard reads. Two host classes:

- **LifeOS host** (`~/.claude/PAI/` exists — the marker directory keeps
  LifeOS's former name) — one identity per machine, host-locked.
  Setup writes ONLY the host-global config and **refuses** to create a
  repo-local identity config (write-time half of the hijack guard).
- **Vanilla host** — may opt in to per-repo identity, where the atomic unit of
  identity is the repo, not the machine.

## Step 0: Detect Host Class

```bash
if [ -d "$HOME/.claude/PAI" ]; then HOST_CLASS=pai; else HOST_CLASS=vanilla; fi
echo "host class: $HOST_CLASS"
```

On a **vanilla** host, ask the user:

- **Per-repo identity, or one identity for the whole machine?**
  - *Per-repo* (one identity per repo): the bus identity is
    tracked in each repo and travels with it. Requires `per_repo_identity_allowed: true`
    in the host-global config (this Setup sets it).
  - *Host-global*: a single identity for every repo on this machine.

On a **LifeOS** host there is no choice — always host-global, host-locked.

## Step 1: Gather Identity

Ask the user:

- **What is this agent's ID?** Examples: `Alice`, `Bob`, `Carol`. Appears in the
  `SENDER` half of the routing Title.
- **What recipient filters apply?** Default `[<agent_id>, "ALL"]`. The agent
  surfaces any message whose Title contains `<pointer><filter>:`, where `<pointer>`
  is any of `→ ➡️ 👉 ->` (all normalized to `→` by the matcher).

For a **per-repo** setup, this identity is for the *current repo*. Capture the
repo root:

```bash
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$REPO_ROOT" ] || { echo "Not inside a repo — per-repo identity needs one." >&2; }
```

## Step 2: Confirm Endpoint

Ask the user for their ntfy server endpoint (e.g. `https://ntfy.example.com`
— a self-hosted ntfy instance; there is no useful default). Suggest
`agent-bus` as the default topic. Remember the topic is a bus-wide contract:
every agent on the same bus must use the same topic, so a host joining an
existing fleet must use that fleet's topic, not the default.

## Step 3: Confirm Auth Env Vars

Default env-var names `NTFY_USERNAME` / `NTFY_PASSWORD`. Confirm they resolve:

```bash
( set -a; . "$HOME/.env" 2>/dev/null; . "$HOME/.claude/.env" 2>/dev/null; set +a; [ -n "$NTFY_USERNAME" ] && [ -n "$NTFY_PASSWORD" ] && echo "ok" )
```

If `ok` doesn't print, walk the user through adding the credentials to their
dotenv file. **Never accept the password as plaintext typed to the assistant.**

## Step 4: Detect Inbox Path

If `~/.claude/ntfy-inbox.jsonl` exists (LifeOS host), set `inbox_jsonl` to it.
Otherwise keep the template default below — the key must be PRESENT (the daemon
fails loud without it), and CheckInbox still falls through to HTTP polling
whenever the named file doesn't exist yet.

## Step 5: Write the Host-Global Config

Every host gets a host-global config. The `per_repo_identity_allowed` flag is the
single switch that unlocks repo-local identity, and it is **false on LifeOS hosts,
always**.

```bash
if [ "$HOST_CLASS" = pai ]; then PER_REPO=false; else PER_REPO="${PER_REPO:-false}"; fi

cat > "$HOME/.claude/ntfy-bus.config.json" <<EOF
{
  "agent_id": "${AGENT_ID}",
  "endpoint": "${ENDPOINT}",
  "topic": "${TOPIC}",
  "auth_env": {
    "username": "NTFY_USERNAME",
    "password": "NTFY_PASSWORD"
  },
  "recipient_filters": ${RECIPIENT_FILTERS_JSON},
  "inbox_jsonl": "${INBOX_JSONL:-~/.claude/ntfy-inbox.jsonl}",
  "per_repo_identity_allowed": ${PER_REPO},
  "waker": {
    "mode": "auto",
    "systemd_unit": "bus-waker.service",
    "pidfile": "~/.claude/ntfy-bus.waker.pid",
    "cmdline_match": "bus-waker-daemon",
    "wakelog": "~/.claude/ntfy-bus.wake.log",
    "seen_ids": "~/.claude/ntfy-bus.seen-ids"
  }
}
EOF
chmod 600 "$HOME/.claude/ntfy-bus.config.json"
```

The `waker` block's state paths are **required by the daemon** (it fails loud on
any missing one — state paths have no code defaults). Writing them at setup
time, even on hosts that never run the daemon, costs nothing and means enabling
the daemon later is just `systemctl --user enable --now`. A leading `~/` in any
config path is expanded to `$HOME` by every consumer (`ntfy_expand_home`).

On a host-global setup, the `agent_id` above IS the machine's identity.

On a per-repo (opt-in) setup it is **not** a fallback for config-less repos —
there is no such fallback. Inside a repo with no `.claude/ntfy-bus.config.json`,
identity resolves to NOTHING (`NTFY_IDENTITY_SOURCE=none`, empty `NTFY_CONFIG`)
and every consumer refuses to act on the bus. The host-global `agent_id` is used
only where there is no repo context at all — the systemd/launchd daemon, which
sets no `WorkingDirectory` — so durable notification keeps working while nothing
can ever send or wake as an agent the repo never named.

## Step 6: (Vanilla, per-repo only) Write the Repo-Local Identity + Wiring

> **LifeOS guard:** if `$HOST_CLASS` is `pai`, STOP here. Do **not** write a
> repo-local identity config — an identity-bearing tracked config must not even
> be born on a LifeOS host. The read-time guard in `resolve-config.sh` would ignore
> it anyway; this is the belt-and-suspenders write-time half.

**6a. Untracked identity config** (per-contributor — never committed):

```bash
cat > "${REPO_ROOT}/.claude/ntfy-bus.config.json" <<EOF
{
  "agent_id": "${REPO_AGENT_ID}",
  "endpoint": "${ENDPOINT}",
  "topic": "${TOPIC}",
  "auth_env": {
    "username": "NTFY_USERNAME",
    "password": "NTFY_PASSWORD"
  },
  "recipient_filters": ${REPO_RECIPIENT_FILTERS_JSON},
  "inbox_jsonl": "~/.claude/ntfy-inbox.$(echo "$REPO_AGENT_ID" | tr '[:upper:]' '[:lower:]').jsonl"
}
EOF

# Fence FIRST, via the repo's local-only exclude file: same syntax as
# .gitignore, effective immediately, no commit and no PR to wait on
# (issue #23 — on a branch-protected repo the tracked-.gitignore PR was the
# one onboarding step that blocked on a human, and until it merged the live
# identity sat unfenced). --git-path handles worktrees, where .git is a file.
EXCL="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)/info/exclude"
mkdir -p "$(dirname "$EXCL")"
grep -qxF '.claude/ntfy-bus.config.json' "$EXCL" 2>/dev/null \
  || echo '.claude/ntfy-bus.config.json' >> "$EXCL"
```

Then, as a **follow-up** (not a blocker — the exclude above already protects
this clone): add the same entry to the repo's tracked `.gitignore`, via PR if
the repo is branch-protected. The tracked entry still has real value — it
protects every *other* clone's contributor, which `.git/info/exclude` cannot —
but the identity config must never sit unfenced while that PR waits.

```bash
IGN="${REPO_ROOT}/.gitignore"
grep -qxF '.claude/ntfy-bus.config.json' "$IGN" 2>/dev/null \
  || echo '.claude/ntfy-bus.config.json' >> "$IGN"
```

**Do not commit the identity config**, and do not encourage anyone else to. It
carries no secrets (creds are env-var *names*), but it does carry a live fleet
**identity**: committing it hands that agent's name to everyone who clones the
repo, and the first clone to run a workflow starts sending and arming wakers
as that agent. Identity is per-contributor, not per-project. On a locked host
the read-time guard would ignore a tracked config anyway — so committing it
buys nothing and risks a hijack.

`inbox_jsonl` must be a real path, not `""`. It is the one key that turns the
wake path on: `daemons/ntfy-bus-waker.sh` fails loud on an empty value, and both
the session pidfile (`${inbox%.jsonl}.waker.pid`) and the wake-private ledger
(`${inbox%.jsonl}.wake-seen`) derive from it. A leading `~/` is expanded by
`ntfy_expand_home`, so the value stays portable across hosts.

**6b. BridgeBodyGuard hook — verify the HOST-GLOBAL wiring** (once per host,
not per repo — issue #24):

Nothing in the hook is repo-specific; the only host-specific part is the bun
interpreter path. It belongs in `~/.claude/settings.json`, exactly like
`arm-bus-waker.sh` already is — one entry covers every repo on the host,
present and future, where per-repo copies meant every unwired repo silently
lost the byte-cap guard. The hook no-ops cheaply on non-bus Bash calls, so
host-global scope costs nothing on repos that never touch the bus.

First check whether it is already wired:

```bash
grep -q 'BridgeBodyGuard' "$HOME/.claude/settings.json" 2>/dev/null \
  && echo "already wired host-globally" || echo "NOT wired"
```

If NOT wired, add it host-globally:

```bash
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
HOOK_CMD="${BUN} ${HOME}/.claude/skills/ntfy-bus/hooks/BridgeBodyGuard.hook.ts"
SETTINGS="$HOME/.claude/settings.json"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
tmp=$(mktemp)
jq --arg cmd "$HOOK_CMD" '
  .hooks //= {} |
  .hooks.PreToolUse //= [] |
  if any(.hooks.PreToolUse[]?; any(.hooks[]?; .command == $cmd))
  then .
  else .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":$cmd}]}]
  end
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
```

An agent may be blocked from editing hook config in settings files (the
permission classifier sensibly gates hook self-modification). If the edit is
refused, print the `HOOK_CMD` value and the jq snippet above and hand the step
to the human — it is pure boilerplate and needs doing once per host, ever.

## Step 7: Smoke Test (capture path)

```bash
echo "smoke test from $(hostname)" \
  | curl -s -u "${NTFY_USERNAME}:${NTFY_PASSWORD}" \
      -H "Title: ${AGENT_ID}→${AGENT_ID}: setup smoke" \
      --data-binary @- \
      "${ENDPOINT}/${TOPIC}" \
  | jq .
```

A successful response shows `id`, `time`, `topic`. Then run `CheckInbox` — the
smoke message should appear, addressed from this agent to itself. For a per-repo
setup, confirm `CheckInbox` resolves the repo-local identity (the resolver
exports `NTFY_IDENTITY_SOURCE=repo-local`).

> **What this validates — and deliberately does NOT** (issue #25): a
> **self-sent** message exercises send → capture → CheckInbox only. The waker
> drops `msg_sender == me` **by design**, so a self-sent message can NEVER
> produce a wake. Do not test the wake path by messaging yourself, and do not
> report "the waker failed" when it correctly ignores one — that mis-diagnosis
> has happened in a real onboarding.

## Step 7b: Wake-Path Test (only if a waker is armed)

Send with an **external sender header** so the waker's self-skip does not
apply. `Setup` as the sender also stays clear of the noise-sender mute list,
which `cron`/`bot`-style names would trip:

```bash
echo "wake test from $(hostname)" \
  | curl -s -u "${NTFY_USERNAME}:${NTFY_PASSWORD}" \
      -H "Title: Setup→${AGENT_ID}: wake test" \
      --data-binary @- \
      "${ENDPOINT}/${TOPIC}" \
  | jq .
```

Expect, in order: durable capture within one poll interval (the inbox JSONL
grows), then the armed session waker prints `WAKE: Setup→...` and **exits** —
exit-on-match is the wake mechanism, not a crash. Re-arm it afterwards.

## Step 8: Finish With a Green Doctor Run

The smoke test validates one path; `bin/doctor.sh` probes the rest of what
Setup just configured — skill path resolution, config parse + identity source,
shadow scan, and the identity-config tracking state (tracked = DRIFT,
unignored = warn; Step 6a's fence should make it report `ok ... ignored`).

It lives in repo-root `bin/` (host tooling, not part of the installed skill),
so run it from the clone — on the recommended clone+symlink install:

```bash
cd "$(dirname "$(readlink "$HOME/.claude/skills/ntfy-bus")")/.." && bash bin/doctor.sh
```

For a per-repo setup, run it from the identity repo's directory so the
tracking-state section checks THAT repo. Onboarding is done when doctor exits
green (the `repo has uncommitted changes` line is expected while a fence PR is
in flight). On a plugin-only install there is no clone to run it from — skip,
and note the gap.

## Step 9: (Optional) Register for auto-sync

If this host has infrastructure that auto-syncs git repos, register the skill
repo (`cadentdev/ntfy-bus`) with it so updates arrive automatically. Skip on
hosts without such infrastructure.
