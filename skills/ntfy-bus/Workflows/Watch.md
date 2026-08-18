# Watch

Long-poll the bus for new messages and surface them immediately. Two modes: foreground (for live debugging) and background daemon (for normal operation).

## Foreground (live tail)

For quick interactive monitoring during a session:

```bash
set -a; . "$HOME/.env" 2>/dev/null; . "$HOME/.claude/.env" 2>/dev/null; set +a
# Resolve identity via the shared guard (host-locked LifeOS vs vanilla per-repo).
. "$HOME/.claude/skills/ntfy-bus/lib/resolve-config.sh"
# GATE (issue #8): an unresolved identity refuses here, loudly. If this exits,
# STOP the workflow — do not source another config or improvise an identity;
# run the Setup workflow instead.
ntfy_require_config || exit 1
. "$HOME/.claude/skills/ntfy-bus/lib/routing.sh"   # shared pointer-agnostic matcher
CONFIG="$NTFY_CONFIG"
ENDPOINT=$(jq -r '.endpoint' "$CONFIG")
TOPIC=$(jq -r '.topic' "$CONFIG")
USER_VAR=$(jq -r '.auth_env.username' "$CONFIG")
PASS_VAR=$(jq -r '.auth_env.password' "$CONFIG")
FILTERS=$(jq -r '.recipient_filters | join("|")' "$CONFIG")
# Resolve the env-var NAMES to their values portably. bash's ${!VAR} indirect
# expansion is a parse error in zsh ("bad substitution"); eval works in bash,
# zsh, and POSIX sh. The names come from the trusted config.
NTFY_USER=$(eval "printf '%s' \"\${$USER_VAR}\"")
NTFY_PASS=$(eval "printf '%s' \"\${$PASS_VAR}\"")

curl -s -u "${NTFY_USER}:${NTFY_PASS}" \
  "${ENDPOINT}/${TOPIC}/json" \
  | jq -c --arg filters "$FILTERS" "$BUS_ROUTING_DEFS"'select(.event == "message") | select(.title != null) | select(addressed_to($filters))'
```

Ctrl-C to exit. Useful for ad-hoc tailing.

## Background Daemon (LifeOS hosts)

On LifeOS hosts a systemd user unit already runs the watcher and writes to `~/.claude/ntfy-inbox.jsonl`. Check that it's active:

```bash
systemctl --user status ntfy-bridge-watcher.service
```

If it's not running but should be, refer the user to the watcher script in their LifeOS infrastructure (e.g. `~/.claude/bin/ntfy-bridge-watcher.sh`). This skill does NOT install that systemd unit — it is LifeOS infrastructure, owned by the host's LifeOS setup.

## Background Daemon (vanilla hosts)

For vanilla Claude Code hosts that want continuous capture, two options:

1. **Cron polling every N minutes** — schedule the foreground command above with output redirected to a local JSONL file
2. **tmux pane running the foreground command** — simplest, restarts on Ctrl-C

The skill itself doesn't manage the daemon — it just defines the read paths in `CheckInbox`.
