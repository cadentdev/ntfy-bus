#!/bin/bash
# daemons/bus-waker-daemon.sh — canonical bus WAKER daemon (systemd hosts).
#
# WHY: harness-launched in-session wakers get killed by the background-task
# reaper. On hosts with systemd --user (+ Linger), this daemon is the durable
# detector: it FOLLOWS the JSONL inbox the ntfy watcher already writes (no
# second long-poll), filters to messages addressed to this agent via the shared
# routing lib, dedups by ntfy .id (rotation of the inbox REPLAYS the kept
# window — see lib/dedup.sh), appends matches to a wake-log, and fires an
# optional notify hook.
#
# LIMITATION (honest): a systemd process cannot re-invoke an in-session Claude
# agent — exit-to-wake belongs to harness-tracked tasks. This daemon is
# NOTIFY + durable-record. The wake channel is whatever the notify hook does.
#
# IDENTITY: entirely from the resolved host config (lib/resolve-config.sh).
# No agent name is hardcoded here; this file is host-agnostic by construction.
#
# CONFIG (host-global ntfy-bus.config.json — one source of truth per machine):
#   .recipient_filters      -> wake filters (joined with |); REQUIRED (or .agent_id)
#   .agent_id               -> self-skip (lowercased);       REQUIRED
#   .inbox_jsonl            -> inbox path; REQUIRED (arg $1 overrides)
#   .waker.pidfile          -> pidfile path; REQUIRED (statusline reads it)
#   .waker.wakelog          -> wake-log path; REQUIRED
#   .waker.seen_ids         -> seen-ids path; REQUIRED
#   .waker.noise_senders    -> sender-anchored mute regex (default below)
#   .waker.startup_tail     -> catch-up window on (re)start (default 200)
#   .waker.notify_hook      -> optional notify hook (not state; has a default)
#
# STATE PATHS HAVE NO DEFAULTS. A state path is a per-machine fact; shared code
# carrying one is exactly the leak class the state-path doctrine forbids (bin/check.sh section 6
# enforces this). Missing/empty => FATAL with a pointer to the migration note.
# A leading "~/" in any config path is expanded to $HOME.
set -u

# Resolve shared libs relative to this file's REAL location (symlink-safe:
# hosts may reach us through ~/.claude/skills/ntfy-bus -> repo compat links —
# a DOUBLE hop, so one-level readlink isn't enough; readlink -f is GNU/newer-
# macOS only). Duplicated in bin/* and statusline/* (pre-lib bootstrap).
bus_resolve() {
  local t="$1" d
  while [ -L "$t" ]; do
    d=$(cd -P "$(dirname "$t")" && pwd -P); t=$(readlink "$t")
    case "$t" in /*) ;; *) t="$d/$t" ;; esac
  done
  printf '%s/%s' "$(cd -P "$(dirname "$t")" && pwd -P)" "$(basename "$t")"
}
SELF_DIR=$(dirname "$(bus_resolve "${BASH_SOURCE[0]}")")
LIB_DIR="$SELF_DIR/../lib"
. "$LIB_DIR/routing.sh"        || { echo "FATAL: cannot source routing.sh" >&2; exit 1; }
. "$LIB_DIR/resolve-config.sh" || { echo "FATAL: cannot source resolve-config.sh" >&2; exit 1; }
. "$LIB_DIR/dedup.sh"          || { echo "FATAL: cannot source dedup.sh" >&2; exit 1; }
. "$LIB_DIR/capabilities.sh"   || { echo "FATAL: cannot source capabilities.sh" >&2; exit 1; }

[ -f "$NTFY_CONFIG" ] || { echo "FATAL: no host config at $NTFY_CONFIG — run the Setup workflow" >&2; exit 1; }

# Fail LOUD on missing identity: a waker that silently filters on the wrong
# agent is worse than one that refuses to start.
AGENT_ID=$(jq -re '.agent_id' "$NTFY_CONFIG") || { echo "FATAL: .agent_id missing in $NTFY_CONFIG" >&2; exit 1; }
FILTERS=$(jq -re '(.recipient_filters // [.agent_id, "ALL"]) | join("|")' "$NTFY_CONFIG") \
  || { echo "FATAL: cannot derive recipient filters from $NTFY_CONFIG" >&2; exit 1; }
SELF=$(printf '%s' "$AGENT_ID" | tr '[:upper:]' '[:lower:]')

# SENDER-anchored noise: mute only when the SENDER is automation, never a human
# whose SUBJECT happens to mention one of these.
NOISE=$(jq -r '.waker.noise_senders // "gate|uptime|backup|nightly|cron|mirror|ansible|nocodb|bot|kuma"' "$NTFY_CONFIG")
STARTUP_TAIL=$(jq -r '.waker.startup_tail // 200' "$NTFY_CONFIG")

fatal_missing() {
  echo "FATAL: $1 missing/empty in $NTFY_CONFIG — state paths are per-machine config, not code defaults. See README 'Config migration: state paths + pidfile'." >&2
  exit 1
}
INBOX="${1:-$(jq -r '.inbox_jsonl // ""' "$NTFY_CONFIG")}"
[ -n "$INBOX" ]   || fatal_missing ".inbox_jsonl"
WAKELOG=$(jq -r '.waker.wakelog // ""' "$NTFY_CONFIG")
[ -n "$WAKELOG" ] || fatal_missing ".waker.wakelog"
SEEN=$(jq -r '.waker.seen_ids // ""' "$NTFY_CONFIG")
[ -n "$SEEN" ]    || fatal_missing ".waker.seen_ids"
PIDFILE=$(jq -r '.waker.pidfile // ""' "$NTFY_CONFIG")
[ -n "$PIDFILE" ] || fatal_missing ".waker.pidfile"
NOTIFY=$(jq -r '.waker.notify_hook // ""' "$NTFY_CONFIG")
[ -n "$NOTIFY" ] || NOTIFY="~/.claude/bin/bus-wake-notify.sh"   # hook, not state; default allowed
CMD_MATCH=$(jq -r '.waker.cmdline_match // "bus-waker-daemon"' "$NTFY_CONFIG")
INBOX=$(ntfy_expand_home "$INBOX"); WAKELOG=$(ntfy_expand_home "$WAKELOG")
SEEN=$(ntfy_expand_home "$SEEN");   PIDFILE=$(ntfy_expand_home "$PIDFILE")
NOTIFY=$(ntfy_expand_home "$NOTIFY")
SEEN_CAP=500; SEEN_KEEP=300; WAKELOG_CAP=500; WAKELOG_KEEP=300

# This daemon's pidfile and the session waker's derived one are two different
# JOBS' claims — the documented healthy pair runs both at once. A config that
# points .waker.pidfile at the derived path makes the two fight over one lock,
# and each exit deletes the other's claim. Refuse loudly (issue #27).
if [ "$PIDFILE" = "$(ntfy_session_pidfile "$INBOX")" ]; then
  echo "FATAL: .waker.pidfile ($PIDFILE) collides with the session waker's derived pidfile — give the daemon its own distinct .waker.pidfile in the host config" >&2
  exit 1
fi

# Claim the pidfile ATOMICALLY (issue #29): noclobber `>` is O_CREAT|O_EXCL,
# so creation and pid-write are one step and two same-instant launches can
# never both proceed. The old check-then-write accepted that window on the
# systemd-serialization rationale; the session waker inherited it where
# nothing serializes, so both wakers now share ONE concurrency contract and
# the exception is deleted. PID-reuse-safe on the held path: a live PID only
# blocks us if its command line matches a known waker — .waker.cmdline_match,
# the SAME regex the statusline probe greps, so a waker running under a
# legacy/custom name still blocks a double-start.
claim_pidfile() { (set -C; echo "$$" > "$PIDFILE") 2>/dev/null; }
if ! claim_pidfile; then
  oldpid=$(cat "$PIDFILE" 2>/dev/null)
  # A freshly-claimed pidfile can read empty for an instant; give it a beat.
  [ -z "$oldpid" ] && { sleep 1; oldpid=$(cat "$PIDFILE" 2>/dev/null); }
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
     && ntfy_proc_cmdline "$oldpid" | grep -qE "$CMD_MATCH"; then
    echo "FATAL: another waker (pid $oldpid) owns $PIDFILE" >&2; exit 1
  fi
  # Stale claim: reclaim once; losing the retry means another launch is
  # reclaiming this instant — under systemd that restart will simply retry.
  rm -f "$PIDFILE"
  claim_pidfile || { echo "FATAL: cannot claim pidfile $PIDFILE (lost reclaim race or unwritable)" >&2; exit 1; }
fi
# Remove the pidfile ONLY while we still own it — if another launch reclaimed
# it (stale-reclaim path above), exiting must not delete the LIVE owner's claim.
release_pidfile() { [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"; }
# The follow-pipeline below never exits on its own, and bash DEFERS signal
# traps until the foreground command finishes — so the pipeline runs as a
# background job (wait IS interruptible) and cleanup kills its children.
# pkill can be absent on stripped hosts; fall back to killing the job pid.
cleanup() { release_pidfile; { pkill -P $$ || kill $(jobs -p); } 2>/dev/null; exit 0; }
trap cleanup INT TERM
trap release_pidfile EXIT

touch "$SEEN"

# The watcher may come up slightly after us; wait for the inbox rather than
# dying. NOTE: the pidfile is already claimed here — "armed" means the daemon
# process is up, which is true while it waits.
while [ ! -f "$INBOX" ]; do sleep 5; done

# Startup catch-up (tail -n N, not -n0) so messages that arrived while the
# daemon was down aren't skipped; dedup makes the replay safe. In-loop jq
# stderr is intentionally NOT swallowed: a routing.sh/jq regression must
# surface in the journal, not masquerade as silence.
tail -n "$STARTUP_TAIL" -F "$INBOX" | while IFS= read -r line; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)   # portable; BSD date has no -I
  M=$(printf '%s' "$line" | jq -c --arg f "$FILTERS" --arg self "$SELF" \
        --arg noise "$NOISE" --arg ts "$TS" "$BUS_ROUTING_DEFS"'
        select(.event=="message") | select(.title!=null)
        | select(addressed_to($f))
        | msg_sender as $s | select($s!=$self) | select(($s|test($noise))|not)
        | {ts: $ts, title: .title,
           id: (.id // ((.time // .received // 0 | tostring) + ":" + .title))}')
  [ -n "$M" ] || continue
  ID=$(printf '%s' "$M" | jq -r .id)
  bus_seen "$ID" "$SEEN" && continue          # already woke on this message — replay guard
  bus_mark_seen "$ID" "$SEEN" "$SEEN_CAP" "$SEEN_KEEP"
  printf '%s\n' "$M" >> "$WAKELOG"
  bus_cap_trim "$WAKELOG" "$WAKELOG_CAP" "$WAKELOG_KEEP"
  [ -x "$NOTIFY" ] && "$NOTIFY" "$(printf '%s' "$M" | jq -r .title)" 2>/dev/null || true
done &
wait $!
