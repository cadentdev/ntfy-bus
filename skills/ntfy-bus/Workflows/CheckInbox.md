# CheckInbox

Pull recent bus messages addressed to this agent (or `ALL`).

## Step 1: Load Config

Resolve the config path through the shared guard, then extract fields:

```bash
# Host-locked (LifeOS) hosts always get the host-global config; vanilla opt-in
# hosts get the repo-local config when present.
. "$HOME/.claude/skills/ntfy-bus/lib/resolve-config.sh"
CONFIG="$NTFY_CONFIG"
AGENT_ID=$(jq -r '.agent_id' "$CONFIG")
RECIPIENT_FILTERS=$(jq -c '.recipient_filters' "$CONFIG")
ENDPOINT=$(jq -r '.endpoint' "$CONFIG")
TOPIC=$(jq -r '.topic' "$CONFIG")
AUTH_USER_VAR=$(jq -r '.auth_env.username' "$CONFIG")
AUTH_PASS_VAR=$(jq -r '.auth_env.password' "$CONFIG")
INBOX_JSONL=$(jq -r '.inbox_jsonl // ""' "$CONFIG")
# Config paths may carry "~/" — bash won't expand a tilde inside a variable,
# and an unexpanded one silently fails the -f test in Step 2 (dropping you to
# the slow HTTP path). ntfy_expand_home comes from resolve-config.sh above.
INBOX_JSONL=$(ntfy_expand_home "$INBOX_JSONL")
```

If `$CONFIG` is missing or unreadable, refer the user to the `Setup` workflow.

## Step 2: Choose Read Path

**Prefer JSONL when available** (LifeOS hosts have a systemd watcher writing to it):

```bash
if [ -f "$INBOX_JSONL" ]; then
  read_from_jsonl
else
  read_from_http
fi
```

## Step 3a: Read from JSONL (LifeOS host path)

Read the last N lines (default 50) from `$INBOX_JSONL`. Filter by Title routing:

The recipient match comes from the shared routing routine (`lib/routing.sh`), the single
source of truth for the pointer-agnostic, header-scoped, `\b`-token matcher (see that file
for why). Source it, then call `addressed_to($filters)`:

```bash
. "$HOME/.claude/skills/ntfy-bus/lib/routing.sh"
FILTERS=$(printf '%s' "$RECIPIENT_FILTERS" | jq -r 'join("|")')
tail -n 200 "$INBOX_JSONL" \
  | jq -c --arg filters "$FILTERS" "$BUS_ROUTING_DEFS"'
      select(.event == "message") |
      select(.title != null) |
      select(addressed_to($filters))
    '
```

Note: the `select(.title != null)` guard is required — JSONL watcher entries with `event != "message"` may have null titles even after the event filter (e.g. heartbeats that occasionally leak through), and `test()` against null throws `null (null) cannot be matched`. Same guard applies to the HTTP path in Step 3b.

Drop messages where `.topic == "system"` (those are watcher breadcrumbs).

## Step 3b: Read from HTTP (vanilla host path)

Load auth from env, then poll:

```bash
set -a; . "$HOME/.env" 2>/dev/null; . "$HOME/.claude/.env" 2>/dev/null; set +a
# Resolve the env-var NAMES to their values portably. bash's ${!VAR} indirect
# expansion is a parse error in zsh ("bad substitution"); eval works in bash,
# zsh, and POSIX sh. The names come from the trusted config.
NTFY_USER=$(eval "printf '%s' \"\${$AUTH_USER_VAR}\"")
NTFY_PASS=$(eval "printf '%s' \"\${$AUTH_PASS_VAR}\"")
curl -s -u "${NTFY_USER}:${NTFY_PASS}" \
  "$ENDPOINT/$TOPIC/json?poll=1&since=10m"
```

Filter the resulting JSONL stream by Title routing identically to Step 3a.

## Step 4: Format Output

Show each matched message as:

```
[<received-iso>] <title>
<body>
─────────
```

Sort newest-first. Cap at 20 messages unless the user asks for more.

## Step 5: Suggest Next Action

If any new message is addressed to this agent specifically (not just `ALL`), suggest replying via the `Send` workflow.
