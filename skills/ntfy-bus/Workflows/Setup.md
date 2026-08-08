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

On a host-global setup, the `agent_id` above IS the machine's identity. On a
per-repo setup, it is the **fallback** identity used in repos that carry no
config of their own.

## Step 6: (Vanilla, per-repo only) Write the Repo-Local Identity + Wiring

> **LifeOS guard:** if `$HOST_CLASS` is `pai`, STOP here. Do **not** write a
> repo-local identity config — an identity-bearing tracked config must not even
> be born on a LifeOS host. The read-time guard in `resolve-config.sh` would ignore
> it anyway; this is the belt-and-suspenders write-time half.

**6a. Tracked identity config** (travels with the repo — commit it):

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
  "inbox_jsonl": ""
}
EOF
```

This file carries NO secrets (creds are env-var *names*), so it is safe to track.

**6b. Untracked hook wiring** (machine-specific bun path — never tracked):

```bash
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
HOOK_CMD="${BUN} ${HOME}/.claude/skills/ntfy-bus/hooks/BridgeBodyGuard.hook.ts"
SETTINGS="${REPO_ROOT}/.claude/settings.local.json"

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

The `settings.local.json` is machine-specific (the bun interpreter path differs
across hosts) so it must stay **untracked**. Ensure the repo ignores it:

```bash
IGN="${REPO_ROOT}/.gitignore"
grep -qxF '.claude/settings.local.json' "$IGN" 2>/dev/null \
  || echo '.claude/settings.local.json' >> "$IGN"
```

## Step 7: Smoke Test

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

## Step 8: (Optional) Register for auto-sync

If this host has infrastructure that auto-syncs git repos, register the skill
repo (`cadentdev/ntfy-bus`) with it so updates arrive automatically. Skip on
hosts without such infrastructure.
