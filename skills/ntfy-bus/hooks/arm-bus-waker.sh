#!/usr/bin/env bash
# hooks/arm-bus-waker.sh — SessionStart DETECTOR for the in-session bus waker.
# Detect-and-prompt, NOT launch. Companion to daemons/ntfy-bus-waker.sh.
#
# WHY NOT LAUNCH: a SessionStart hook runs as a detached process, so anything it
# spawns (`nohup ... &`) is UNTRACKED by the Claude Code harness. An untracked
# waker can poll and exit(0) on a match but produces NO task-notification, so it
# can never re-invoke the idle agent. Worse, it writes the waker pidfile and
# thereby CLAIMS the lock, so the agent's own wake-capable re-arm (a Bash tool
# call with run_in_background:true) then no-ops on the idempotency guard. Net:
# waking silently DISABLED. (Verified on a vanilla macOS host 2026-07-01: the
# tracked Bash-tool launch wakes; a hook nohup does not. Fleet-corroborated
# live on their systemd hosts.)
#
# WHAT THIS DOES INSTEAD: detect the waker's armed state READ-ONLY (never touch
# the pidfile), and if it's down, PROMPT the agent via stdout — which a
# SessionStart hook injects into the agent's context — to arm the waker through
# the wake-capable path (a run_in_background Bash tool call). That launch IS
# harness-tracked, so its exit-on-match re-invokes the agent.
#
# All agent-facing output goes to STDOUT so it actually reaches context; a
# missing durable inbox is surfaced there too (not silently skipped).
#
# Wired as a SessionStart hook in ~/.claude/settings.json. See the README.
set -u

# Libs and the waker resolve relative to this file's REAL location
# — the same symlink-safe bootstrap the daemons use, byte-identical by gate
# (check.sh section 5). On an installed host that is the canonical skill tree
# this hook was wired from; in tests/CI it is the fresh clone, no install
# needed. Never a host-local ~/.claude/bin copy — that is exactly the shadow
# doctor.sh flags as DRIFT.
bus_resolve() {
  local t="$1" d
  while [ -L "$t" ]; do
    d=$(cd -P "$(dirname "$t")" && pwd -P); t=$(readlink "$t")
    case "$t" in /*) ;; *) t="$d/$t" ;; esac
  done
  printf '%s/%s' "$(cd -P "$(dirname "$t")" && pwd -P)" "$(basename "$t")"
}
SKILL_DIR="$(cd -P "$(dirname "$(bus_resolve "${BASH_SOURCE[0]}")")/.." && pwd -P)"
RESOLVER="$SKILL_DIR/lib/resolve-config.sh"
[ -f "$RESOLVER" ] || exit 0
# shellcheck source=/dev/null
source "$RESOLVER" >/dev/null 2>&1 || exit 0
[ -n "${NTFY_CONFIG:-}" ] || exit 0

WAKER="$SKILL_DIR/daemons/ntfy-bus-waker.sh"

# Identity = the canonical .agent_id (fallback recipient_filters[0] only for a
# pre-backfill config). Used to locate this identity's inbox + pidfile and to
# tell the agent which waker to arm.
ID=$(jq -r '.agent_id // .recipient_filters[0] // empty' "$NTFY_CONFIG" 2>/dev/null)
[ -n "$ID" ] || exit 0

# Same contract as the waker: inbox from config (.inbox_jsonl), session pidfile
# derived from that configured path — this hook must probe the exact files the
# waker uses, or armed-state detection silently diverges from reality.
INBOX=$(jq -r '.inbox_jsonl // ""' "$NTFY_CONFIG")
if [ -z "$INBOX" ]; then
  echo "[bus-waker] Config $NTFY_CONFIG has no .inbox_jsonl — state paths are per-host config, not code defaults. Bus wake is OFF until it is set (see README config migration)."
  exit 0
fi
INBOX=$(ntfy_expand_home "$INBOX")
# The SESSION waker's pidfile, via the shared helper (issue #27). The durable
# daemon's pidfile (.waker.pidfile) is deliberately NOT consulted here: a
# running daemon can only notify, never re-invoke an idle agent, so it must
# not read as "armed" to the one hook whose whole job is prompting the
# wake-capable arm.
PIDFILE=$(ntfy_session_pidfile "$INBOX")

# Gate: only prompt where a durable capture exists. Surface a missing inbox on
# STDOUT (=> agent context) so a dead capture can't fail silent — a silent skip
# reads as "armed" when it isn't (fleet review). The capture is written by
# daemons/ntfy-poll-to-jsonl.sh under its OS scheduler (launchd/systemd/cron).
if [ ! -f "$INBOX" ]; then
  echo "[bus-waker] No durable inbox for ${ID} at ${INBOX} — the capture (daemons/ntfy-poll-to-jsonl.sh) may be down. Bus wake is OFF until it is restored; investigate before relying on the bus."
  exit 0
fi

# DETECT armed state — READ-ONLY. Live pid + our own cmdline; NEVER write the
# pidfile (writing it is exactly the squat that disables the agent's re-arm).
if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
     && ps -p "$pid" -o command= 2>/dev/null | grep -q "ntfy-bus-waker"; then
    exit 0   # already armed — nothing to say
  fi
fi

# NOT armed → prompt the agent to arm via the wake-capable, harness-tracked path.
# No identity arg: the waker self-resolves .agent_id from this repo's cwd (single
# source of truth), which is the same cwd the agent runs the Bash tool from.
cat <<EOF
[bus-waker] Your ntfy bus waker (identity: ${ID}) is NOT armed, so new bus
messages cannot wake you while you are idle. As your FIRST action this turn, arm
it via the harness-tracked path so its exit-on-match can re-invoke you:

  run, with run_in_background = true:
    bash ${WAKER}

Launch it exactly that way, from this repo's cwd (it self-resolves identity
'${ID}'). Do NOT background it with nohup or '&' or from a subshell — a detached
launch is untracked by the harness and cannot deliver a wake. After a wake fires
(the waker exits when a message arrives), re-arm it the same way.
EOF
exit 0
