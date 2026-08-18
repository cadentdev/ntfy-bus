#!/usr/bin/env bash
# daemons/ntfy-poll-to-jsonl.sh — durable bus CAPTURE for vanilla Claude Code hosts.
#
# This is the writer half of the receive path that daemons/bus-waker-daemon.sh
# (and the in-session daemons/ntfy-bus-waker.sh) FOLLOW. The repo previously
# shipped a follower with no writer. This closes that gap.
#
# Implements the fleet's "option 1" (bus thread 2026-06-22): every N minutes, poll the
# ntfy bus with ?poll=1&since=<last-seen> and append any NEW messages to a local
# JSONL inbox. Durable capture + catch-up even if no live monitor is running and
# even across a session/network flap — the LifeOS hosts' systemd-watcher safety net,
# reproduced for hosts without systemd. CheckInbox reads this file via the
# config's inbox_jsonl field.
#
# The inbox path comes from the identity's config (.inbox_jsonl, fail-loud) —
# never code-derived. On a shared-$HOME host each identity's config sets its own
# namespaced path (e.g. ~/.claude/ntfy-inbox.<agent>.jsonl): a shared inbox file
# would mean two uncoordinated writers -> interleaved/corrupt lines, so per-agent
# paths keep each writer sole-owner of its own capture.
#
#   <inbox_jsonl from config>            append-only raw ntfy message JSON
#   <inbox stem>.poll-state              last-seen epoch seconds
#   <inbox stem>.poll.log                run log
#
# PORTABLE: pure bash + curl/jq, mkdir-based lock (no flock), BSD/GNU-agnostic
# date(1)/find(1). Runs on macOS and Linux. The scheduler is OS-specific; the
# script is not. Pick the per-OS scheduler that won't silently die:
#
#   macOS  -> launchd LaunchAgent (preferred; cron needs Full Disk Access and
#             fails silently without it). See launchd/ntfy-poll.plist.example.
#             StartInterval 120, RunAtLoad.
#   Linux  -> systemd: ntfy-poll.timer (OnUnitActiveSec=2min) + ntfy-poll.service
#             (see systemd/); or cron:
#               */2 * * * * NTFY_POLL_REPO=/path/to/repo EXPECT_AGENT=foo \
#                            ~/.claude/skills/ntfy-bus/daemons/ntfy-poll-to-jsonl.sh
#
# Identity resolves from config FIRST (lib/resolve-config.sh). NTFY_POLL_REPO
# selects which repo's identity to poll as — but ONLY on an unlocked host,
# where the repo-local config IS the identity; on a host-locked host the
# resolver returns the host-global config before ever reading a repo path.
# EXPECT_AGENT is an optional guard that refuses to run as any other agent
# (compared case-insensitively — .agent_id spellings are typically capitalised).
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"

# Libs resolve relative to this file's REAL location — the same symlink-safe
# bootstrap the wakers use, byte-identical by gate (check.sh section 5). The
# old $HOME-anchored source path made this script depend on an installed skill
# even when run from a clone (tests, CI).
bus_resolve() {
  local t="$1" d
  while [ -L "$t" ]; do
    d=$(cd -P "$(dirname "$t")" && pwd -P); t=$(readlink "$t")
    case "$t" in /*) ;; *) t="$d/$t" ;; esac
  done
  printf '%s/%s' "$(cd -P "$(dirname "$t")" && pwd -P)" "$(basename "$t")"
}
LIB_DIR="$(dirname "$(bus_resolve "${BASH_SOURCE[0]}")")/../lib"
# shellcheck source=/dev/null
. "$LIB_DIR/resolve-config.sh"

if [ "${NTFY_HOST_LOCKED:-0}" = "1" ]; then
  # Host-locked: identity is host-global and a repo path cannot influence it,
  # so a stale NTFY_POLL_REPO (e.g. after the documented clone rename) must not
  # abort capture — that turned a dead Environment= line into silent capture
  # loss (issue #12). Surface the staleness so the operator cleans it up.
  if [ -n "${NTFY_POLL_REPO:-}" ] && [ ! -d "$NTFY_POLL_REPO" ]; then
    echo "note: NTFY_POLL_REPO='$NTFY_POLL_REPO' does not exist — ignored (identity is host-global on this host-locked host); remove the stale path from the scheduler unit" >&2
  fi
else
  # Unlocked: the repo genuinely selects identity. Resolve it most-specific
  # first, so the same script is host-agnostic: schedulers pass NTFY_POLL_REPO;
  # interactive runs fall back to CLAUDE_PROJECT_DIR or the surrounding git
  # work tree. `[ -n ] ||` (not `[ -z ] &&`): the `&&` form returns non-zero
  # when REPO is already set and would abort the whole script under `set -e`.
  REPO="${NTFY_POLL_REPO:-${CLAUDE_PROJECT_DIR:-}}"
  [ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  # Fail loudly rather than guess a host-local default: a wrong guess
  # resolves as the wrong agent and silently captures into the wrong inbox.
  if [ -z "$REPO" ]; then
    echo "FATAL: cannot resolve which repo's identity to poll as. Set NTFY_POLL_REPO=/path/to/repo (schedulers must pass it explicitly), or run from inside a git work tree whose repo carries an ntfy-bus config." >&2
    exit 1
  fi
  cd "$REPO" 2>/dev/null || { echo "repo not found: $REPO" >&2; exit 1; }
  # Pin identity deterministically: resolve-config prefers CLAUDE_PROJECT_DIR
  # over `git rev-parse`, so this works even under cron's minimal PATH and
  # guarantees we resolve THIS repo's identity.
  export CLAUDE_PROJECT_DIR="$REPO"
  ntfy_resolve_config
fi
CONFIG="${NTFY_CONFIG:-}"
if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
  echo "FATAL: no resolvable ntfy-bus config (identity source: ${NTFY_IDENTITY_SOURCE:-?}) — run the Setup workflow" >&2
  exit 1
fi
AGENT=$(jq -r '.agent_id' "$CONFIG" | tr '[:upper:]' '[:lower:]')
# Identity guard: if an EXPECT_AGENT is declared, refuse to run as anyone else
# (defends against a silent resolve-as-wrong-agent on a shared-$HOME host).
# Fold BOTH sides: .agent_id spellings are typically capitalised, and a guard
# that refuses the correct identity kills capture as silently as a wrong one
# (issue #5).
EXPECT=$(printf '%s' "${EXPECT_AGENT:-}" | tr '[:upper:]' '[:lower:]')
if [ -n "$EXPECT" ] && [ "$AGENT" != "$EXPECT" ]; then
  echo "identity guard: resolved '$AGENT' != expected '${EXPECT_AGENT}' (compared case-insensitively); refusing" >&2
  exit 1
fi
ENDPOINT=$(jq -r '.endpoint' "$CONFIG")
TOPIC=$(jq -r '.topic' "$CONFIG")
USER_VAR=$(jq -r '.auth_env.username' "$CONFIG")
PASS_VAR=$(jq -r '.auth_env.password' "$CONFIG")

# The inbox path comes from THIS identity's config (.inbox_jsonl, fail-loud) —
# the same key every consumer (waker daemon, in-session waker, CheckInbox)
# reads, so writer and followers can never disagree on the file. Per-identity
# isolation on a shared-$HOME host = each identity's config sets its own
# namespaced path (e.g. ~/.claude/ntfy-inbox.<agent>.jsonl); never code-derived.
JSONL=$(jq -r '.inbox_jsonl // ""' "$CONFIG")
if [ -z "$JSONL" ]; then
  echo "FATAL: .inbox_jsonl missing/empty in $CONFIG — state paths are per-host config, not code defaults" >&2
  exit 1
fi
JSONL=$(ntfy_expand_home "$JSONL")
# Capture-private state derives from the configured inbox path: config-anchored
# and per-identity unique without extra migration keys. The run log too:
# it was the one path here still guessed from a home-anchored dir — the exact
# indirection pattern check.sh section 6b now flags. Old logs at
# ~/.local/state/ntfy-poll.<agent>.log are simply left behind on upgrade.
STATE="${JSONL%.jsonl}.poll-state"
LOCK="${JSONL%.jsonl}.poll-lock"
LOG="${JSONL%.jsonl}.poll.log"

mkdir -p "$(dirname "$JSONL")"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

# Atomic lock via mkdir — portable (flock is absent on macOS; mkdir works on both
# macOS and Linux). Break a >30min stale lock (-mmin works on BSD and GNU find).
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -d "$LOCK" ] && find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null | grep -q .; then
    log "breaking stale lock"
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || { log "lock contended; exit"; exit 0; }
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Source only files that exist: in non-interactive bash, `source <missing-file>`
# is FATAL and aborts the script even with `|| true` (zsh tolerates it, which is
# why interactive runs worked but launchd/cron silently died here). The `if`
# guards also keep a missing file from tripping `set -e`.
set -a
if [ -f "$HOME/.env" ]; then . "$HOME/.env" 2>/dev/null || true; fi
if [ -f "$HOME/.claude/.env" ]; then . "$HOME/.claude/.env" 2>/dev/null || true; fi
set +a
# ":-" inside the eval: under `set -u` a credential var that is UNSET (not
# merely empty) would abort the subshell at the expansion itself, killing the
# script before the "missing ntfy credentials" log line below could fire —
# the graceful branch was only reachable for set-but-empty vars.
NTFY_USER=$(eval "printf '%s' \"\${$USER_VAR:-}\"")
NTFY_PASS=$(eval "printf '%s' \"\${$PASS_VAR:-}\"")
if [ -z "$NTFY_USER" ] || [ -z "$NTFY_PASS" ]; then
  log "missing ntfy credentials ($USER_VAR/$PASS_VAR); exit"
  exit 1
fi

# since = last-seen epoch; first run defaults to 12h ago (server retention).
if [ -f "$STATE" ] && [ -s "$STATE" ]; then
  SINCE=$(cat "$STATE")
else
  SINCE=$(( $(date +%s) - 43200 ))
fi

RESP=$(curl -s --max-time 30 -u "${NTFY_USER}:${NTFY_PASS}" \
  "${ENDPOINT}/${TOPIC}/json?poll=1&since=${SINCE}") || { log "curl failed (since=$SINCE)"; exit 1; }

touch "$JSONL"
appended=0
maxtime=$SINCE
# `since` is inclusive, so the boundary message reappears each run — id dedup
# (grep -F against the existing inbox) keeps the append idempotent. poll=1 never
# returns keepalive/open events, so this file stays message-only and clean.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  id=$(printf '%s' "$line" | jq -r '.id')
  t=$(printf '%s' "$line" | jq -r '.time')
  [ -z "$id" ] && continue
  if grep -qF "\"id\":\"$id\"" "$JSONL" 2>/dev/null; then
    continue
  fi
  printf '%s\n' "$line" >> "$JSONL"
  appended=$((appended + 1))
  [ "$t" -gt "$maxtime" ] && maxtime=$t
done < <(printf '%s\n' "$RESP" | jq -c 'select(.event == "message")' 2>/dev/null)

echo "$maxtime" > "$STATE"
log "ok since=$SINCE appended=$appended newmax=$maxtime"
