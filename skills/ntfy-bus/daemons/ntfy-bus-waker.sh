#!/usr/bin/env bash
# daemons/ntfy-bus-waker.sh — in-session, harness-tracked poll-and-exit waker.
#
# The counterpart to daemons/bus-waker-daemon.sh. That daemon is durable but can
# only NOTIFY (a systemd process cannot re-invoke an idle in-session Claude
# agent). THIS waker is the piece that actually wakes the model: it is launched
# by the agent itself as a harness-tracked background task, tails the agent's
# durable inbox JSONL, and exits(0) as soon as there is NEW mail addressed to that
# agent (or ALL) — reporting ALL of it in that one wake. Exiting is the mechanism that re-invokes the agent in-session
# — a streaming long-poll can SEE traffic but never completes, so it never wakes
# the model. Pair it with hooks/arm-bus-waker.sh (a SessionStart detector that
# prompts the agent to (re)arm this via the wake-capable, harness-tracked path).
#
# Identity resolves from $1, else $NTFY_WAKER_IDENTITY, else the canonical
# .agent_id in this cwd's bus config. It never guesses a hardcoded name — an
# unresolvable identity is a loud FATAL (fail loudly, don't guess).
# The inbox path comes from the config's .inbox_jsonl (fail-loud, same key the
# durable daemon follows — the two consumers can never watch different files);
# the session pidfile derives from that configured path.
#
# Routing match is delegated to the shared lib/routing.sh (addressed_to/msg_sender)
# — the single source of truth, so a matcher fix is one edit every consumer
# inherits (fleet review 2026-06-27). No inline matcher here.
#
# Gap recovery: a bare EOF baseline is correct on a first arm and
# WRONG on a re-arm — every message that lands between one waker being reaped and
# the next arming would be baselined past, i.e. dropped from the wake path, not
# delayed. So arms are now backed by an id-keyed seen ledger (lib/dedup.sh, the
# fleet's one dedup mechanism). First arm suppresses the existing backlog; every
# later arm scans the recent inbox window and wakes ONCE on EVERY ADDRESSED,
# UNSEEN message in it — recovering the kill-to-rearm gap. The forward line-scan is kept only
# as the in-arm fast path (don't re-parse a growing inbox every interval); ids,
# not line numbers, are the durable across-arm marker, so this also survives the
# truncation the rotation branch used to handle by discarding everything present.
# The ledger is wake-private (${inbox}.wake-seen), NOT the durable daemon's
# .waker.seen_ids: notify-the-phone and wake-the-model must both fire on the same
# message, so they cannot share one at-most-once ledger (fleet decision, 2026-07-22).
#
# Drain, don't single-step (issues #44, #49): a wake retires every addressed,
# unseen message it can see and says how many — "WAKE: 4 messages (4 backlog,
# 0 new)" plus the titles. One arm used to retire exactly ONE message, which
# (a) cost a full agent turn per already-handled backlog message and read as a
# startup crash loop, and (b) against a live sender let arrivals outpace arms,
# so whatever was still queued when the agent stopped re-arming stayed SILENT.
# "backlog" = found by the arm-time gap scan (landed while nothing was armed —
# may be old, may already be handled; each line carries its date). "new" =
# landed while this arm was live.
#
# Usage:  ntfy-bus-waker.sh [Identity]
# Launch backgrounded from the agent's repo cwd so identity stays consistent.
# Launched without an argument it re-execs itself once with the resolved
# identity as $1 (same pid), so the process list shows whose waker it is:
#   pgrep -f 'ntfy-bus-waker.sh Alice$'
set -u

# Identity resolution (fleet review, 2026-06-28): explicit arg/env wins
# (the arm hook passes it per-cwd, by design); otherwise resolve the CANONICAL
# .agent_id from this cwd's bus config — never a hardcoded default, which would
# silently mislabel every non-default agent. .recipient_filters[0] is only a
# pre-backfill fallback; it's a filter list, not an identity.
# Config is required regardless of how identity arrives: the inbox path and
# wake filters are per-host config, not code defaults (a recurring defect class here).
#
# Libs resolve relative to this file's REAL location — the same
# symlink-safe bootstrap bus-waker-daemon.sh uses, byte-identical by gate
# (check.sh section 5). Installed hosts reach the same files as before through
# the ~/.claude/skills/ntfy-bus symlink; a fresh clone (tests, CI) needs no
# install at all.
bus_resolve() {
  local t="$1" d
  while [ -L "$t" ]; do
    d=$(cd -P "$(dirname "$t")" && pwd -P); t=$(readlink "$t")
    case "$t" in /*) ;; *) t="$d/$t" ;; esac
  done
  printf '%s/%s' "$(cd -P "$(dirname "$t")" && pwd -P)" "$(basename "$t")"
}
LIB_DIR="$(dirname "$(bus_resolve "${BASH_SOURCE[0]}")")/../lib"
RESOLVER="$LIB_DIR/resolve-config.sh"
if [ ! -f "$RESOLVER" ]; then
  echo "FATAL: resolve-config lib missing ($RESOLVER)" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$RESOLVER" >/dev/null 2>&1
if [ -z "${NTFY_CONFIG:-}" ] || [ ! -f "$NTFY_CONFIG" ]; then
  echo "FATAL: no resolvable ntfy-bus config — run the Setup workflow" >&2
  exit 1
fi
ME="${1:-${NTFY_WAKER_IDENTITY:-}}"
[ -n "$ME" ] || ME=$(jq -r '.agent_id // .recipient_filters[0] // empty' "$NTFY_CONFIG" 2>/dev/null)
if [ -z "$ME" ]; then
  echo "FATAL: no identity (no arg, no \$NTFY_WAKER_IDENTITY, no resolvable .agent_id)" >&2
  exit 1
fi
# Put the identity in argv (issue #45). Every identity on a shared-$HOME host
# otherwise runs the byte-identical command line, and `ps`/`pgrep` shows "a
# waker" without saying whose — twice an agent took another identity's waker
# for its own and sat silently unarmed. `exec` replaces this process in place:
# SAME pid, so the harness keeps tracking it and its exit is still the wake.
# This must stay ABOVE the pidfile claim and the EXIT trap (nothing stateful
# has happened yet). It cannot loop: the second pass has $1 = $ME, the
# highest-precedence source, so it resolves the same identity and skips this.
# "$0", not the resolved path: keep the path the caller launched (the install
# symlink), which is what people grep for.
if [ "${1:-}" != "$ME" ]; then
  exec "${BASH:-bash}" "$0" "$ME"
fi
id_lc="$(echo "$ME" | tr '[:upper:]' '[:lower:]')"
# Inbox comes from config — the SAME key the durable daemon follows, so the two
# consumers can never watch different files. Per-identity isolation on a
# shared-$HOME host = each identity's config sets its own namespaced path
# (e.g. ~/.claude/ntfy-inbox.<agent>.jsonl); the path never lives in code.
INBOX=$(jq -r '.inbox_jsonl // ""' "$NTFY_CONFIG")
if [ -z "$INBOX" ]; then
  echo "FATAL: .inbox_jsonl missing/empty in $NTFY_CONFIG — state paths are per-host config, not code defaults" >&2
  exit 1
fi
INBOX=$(ntfy_expand_home "$INBOX")
# The session pidfile derives from the configured inbox path: config-anchored
# and per-identity unique without a new migration key. Shared helper — the
# status tool and arm hook derive it the same way, so readers and writer can
# never watch different files (issue #27).
PIDFILE=$(ntfy_session_pidfile "$INBOX")
INTERVAL="${NTFY_WAKER_INTERVAL:-30}"
SELF="$(basename "${BASH_SOURCE[0]}")"
# Wake-set + noise mute come from the same config keys the durable daemon reads
# — one list per host, never two silently-diverging copies (behavior knobs, so
# defaults are allowed; the defaults match the daemon's).
FILTERS=$(jq -re '(.recipient_filters // [.agent_id, "ALL"]) | join("|")' "$NTFY_CONFIG" 2>/dev/null) || FILTERS="${ME}|ALL"
NOISE=$(jq -r '.waker.noise_senders // "gate|uptime|backup|nightly|cron|mirror|ansible|nocodb|bot|kuma"' "$NTFY_CONFIG")

# Shared routing matcher — required, never hand-rolled.
ROUTING="$LIB_DIR/routing.sh"
if [ ! -f "$ROUTING" ]; then
  echo "FATAL: routing lib missing ($ROUTING) — refusing to run with a stale inline matcher" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$ROUTING"

# Shared dedup — the fleet's one dedup mechanism, keyed on ntfy .id
# (lib/dedup.sh header: "dedup is implemented ONCE, here"). Required: the gap
# recovery below cannot function without a persistent seen-ledger.
DEDUP="$LIB_DIR/dedup.sh"
if [ ! -f "$DEDUP" ]; then
  echo "FATAL: dedup lib missing ($DEDUP) — refusing to run without gap recovery" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$DEDUP"
# Wake-private seen ledger, config-anchored off the inbox path exactly like
# PIDFILE — no new config key, no per-host migration. Deliberately separate from
# the durable daemon's .waker.seen_ids (see header).
SEEN="${INBOX%.jsonl}.wake-seen"
# The gap scan reads only the last GAP_WINDOW lines of the (unbounded, append-
# only) inbox, NOT its whole history. This is load-bearing, not an optimization:
# the ledger is cap-trimmed, so an id scrolled out of its memory would read as
# unseen and re-wake on ancient mail. Keeping the scan window strictly smaller
# than the ledger's retained size (KEEP below) guarantees any message we could
# still scan is a message the ledger can still remember. A reaper gap is minutes
# to hours — a handful of messages — so a 1000-line window is ample; a longer
# outage falls back to the read-the-inbox-by-hand doctrine.
GAP_WINDOW="${NTFY_WAKER_GAP_LINES:-1000}"
# Env-overridable so a test can force a real cap-trim with small values; the
# defaults keep KEEP >> GAP_WINDOW (the invariant above). If you override these,
# keep SEEN_KEEP > NTFY_WAKER_GAP_LINES or the trim can drop an id still inside
# the scan window and re-wake ancient mail.
# CEILING IS CAP, NOT KEEP: bus_cap_trim only fires when the ledger EXCEEDS CAP,
# cutting it back to KEEP, so the file oscillates up to CAP and never sits at
# KEEP. The margin that matters is still KEEP > GAP_WINDOW — a trimmed id is at
# least KEEP marks old, hence already outside the scan window (fleet review).
SEEN_CAP="${NTFY_WAKER_SEEN_CAP:-4000}"
SEEN_KEEP="${NTFY_WAKER_SEEN_KEEP:-3000}"
mark_seen() { bus_mark_seen "$1" "$SEEN" "$SEEN_CAP" "$SEEN_KEEP"; }

# Emit "id<US>date<US>title" (US = \x1f, the ASCII unit separator) for every message on stdin that is addressed to us, not
# self-sent, and not automation noise. One matcher, used by both the arm-time gap
# scan and the in-arm loop, so the two can never drift.
#
# Line-at-a-time on purpose (issue #52): -R hands jq each inbox line as a
# string and inbox_objects (lib/routing.sh) turns it into its message
# object(s), skipping a line that does not parse. Fed the raw stream, jq STOPS
# at the first corrupt line — and with stderr discarded every message after it
# was silently invisible until the line left the scan window.
# msg_key (same lib) is the ledger key, shared with the durable daemon.
match_scan() {
  jq -R -r --arg me "$id_lc" --arg f "$FILTERS" --arg noise "$NOISE" "$BUS_ROUTING_DEFS"'
      inbox_objects
      | select(.event == "message")
      | select(addressed_to($f))
      | select(msg_sender != $me)
      | select((msg_sender | test($noise)) | not)
      | "\(msg_key)\u001f\(.time | if type == "number" then (try (todate | .[0:10]) catch "undated") else "undated" end)\u001f\(.title // "" | tostring | gsub("[\t\n\r\u001f]"; " "))"' 2>/dev/null
}
# Why US and not TAB: tab is IFS-whitespace, so `read` collapses an empty field
# and shifts the rest left (a date read as an id). US is not whitespace, so
# fields stay put. Why try/catch on the date: an unconvertible .time (1e18)
# makes todate raise, and with stderr discarded that message would vanish from
# the scan — never woken on, never marked. A bad date must not cost the message.
# Why the gsub: a newline in a title would split one message into two lines.

# A wake lists at most this many titles (the newest); the count always covers
# everything retired. Bounds the output of a long-unarmed identity's first
# re-arm, which can be hundreds of messages. Behavior knob, so a default is fine.
LIST_MAX="${NTFY_WAKER_LIST_MAX:-20}"
# Anything but a positive integer falls back to the default: 0 or junk would
# retire the whole backlog while showing no titles at all.
case "$LIST_MAX" in ''|*[!0-9]*) LIST_MAX=20 ;; esac
[ "$LIST_MAX" -gt 0 ] || LIST_MAX=20
SEP="$(printf '\037')"
NL='
'
# drain_and_wake KIND [PREFIX_LINE]   (KIND = backlog|new; stdin = match_scan)
# Retire EVERY addressed, unseen message on stdin in one wake. Returns 1 and
# prints nothing when there is none; otherwise prints the summary + titles,
# marks them all seen, and returns 0 (the caller exits — that exit is the wake).
# Print BEFORE marking: a kill between the two re-reports on the next arm
# (at-least-once) instead of losing mail that was marked but never shown.
drain_and_wake() {
  local kind="$1" prefix="${2:-}" id day title n=0 ids="" list="" oldest="" backlog=0 new=0 noun=messages
  while IFS="$SEP" read -r id day title; do
    [ -z "$id" ] && continue
    bus_seen "$id" "$SEEN" && continue
    # Same id captured twice inside this scan: count it once.
    case "$NL$ids" in *"$NL$id$NL"*) continue ;; esac
    [ "$n" -eq 0 ] && oldest="$day"
    n=$((n+1)); ids="$ids$id$NL"; list="$list  [$day] $title$NL"
  done
  [ "$n" -gt 0 ] || return 1
  if [ "$kind" = backlog ]; then backlog=$n; else new=$n; fi
  [ "$n" -eq 1 ] && noun=message
  [ -n "$prefix" ] && echo "$prefix"
  echo "WAKE: $n $noun ($backlog backlog, $new new)"
  if [ "$n" -gt "$LIST_MAX" ]; then
    # Self-sufficient on purpose: these are retired from the wake path right
    # here, so the pointer must actually reach them. CheckInbox's default
    # window is smaller than this scan's, so name the file and the window.
    echo "  ... $((n-LIST_MAX)) older not listed (oldest: $oldest) — all are within the last $GAP_WINDOW lines of $INBOX"
  fi
  printf '%s' "$list" | tail -n "$LIST_MAX"
  if [ "$kind" = backlog ]; then
    echo "  (backlog = found waiting at arm time, not live arrivals; check the dates — some may already be handled)"
  fi
  while IFS= read -r id; do
    [ -n "$id" ] && mark_seen "$id"
  done <<EOF_IDS
$ids
EOF_IDS
  return 0
}

# --- atomic pidfile claim: don't stack duplicate wakers (issue #29) ---
# noclobber `>` is O_CREAT|O_EXCL: creation and pid-write are ONE atomic step,
# so two same-instant arms can never both proceed — exactly one create wins.
# The old check-then-write let both racers pass the liveness check and both
# run, with the loser's pid overwritten: a live waker invisible to every
# pidfile reader (status, hook), delivering duplicate wakes. Concurrent arms
# are this script's ROUTINE traffic (SessionStart re-arms, multi-session
# hosts), not a rare manual double-launch, so the window was real.
# An mkdir side-lock was considered and rejected: it adds a second state file
# that outlives a SIGKILL and a lockdir-but-no-pidfile limbo state. Here the
# pidfile IS the lock, and the existing liveness+cmdline check gates
# RECLAMATION of a stale claim — not acquisition.
claim_pidfile() { (set -C; echo $$ > "$PIDFILE") 2>/dev/null; }
if ! claim_pidfile; then
  old=$(cat "$PIDFILE" 2>/dev/null)
  # A freshly-claimed pidfile can read empty for an instant between the
  # winner's O_EXCL create and its write landing; give it a beat.
  [ -z "$old" ] && { sleep 1; old=$(cat "$PIDFILE" 2>/dev/null); }
  # PID-reuse-safe: a bare `kill -0` can be fooled by an unrelated process that
  # inherited a recycled pid, which would block every future arm. Also confirm
  # the live pid is actually one of our wakers via its command line (fleet
  # review; `ps -p` is portable across macOS + Linux, unlike /proc).
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null \
     && ps -p "$old" -o command= 2>/dev/null | grep -q "$SELF"; then
    echo "waker already armed for $ME (pid $old) — exiting without stacking"
    exit 0
  fi
  # Stale claim (dead pid, or a recycled pid running something else): reclaim.
  # ONE retry — losing it means another arm is reclaiming this instant, and
  # the goal is one live waker, not THIS one.
  rm -f "$PIDFILE"
  if ! claim_pidfile; then
    echo "waker arm for $ME lost the reclaim race — another arm is live; exiting without stacking"
    exit 0
  fi
fi
# set cleanup trap only AFTER claiming the pidfile: a no-op launch exits at the
# guard above BEFORE claiming, so an earlier trap would rm the RUNNING waker's
# pidfile. Ordering is load-bearing.
trap '[ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"' EXIT

[ -f "$INBOX" ] || : > "$INBOX"

# --- arm-time gap recovery ---
# The ledger's ABSENCE is what distinguishes a genuine first arm from a re-arm.
if [ ! -f "$SEEN" ]; then
  # First arm: suppress the existing backlog so we don't wake on history. Mark
  # every currently-addressed message in the scan window seen, and materialize
  # the ledger even when nothing matched, so the NEXT arm is treated as a re-arm.
  while IFS="$SEP" read -r id _; do
    [ -n "$id" ] && mark_seen "$id"
  done < <(tail -n "$GAP_WINDOW" "$INBOX" | match_scan)
  touch "$SEEN"
  armkind="first"
else
  # Re-arm: scan the recent inbox window and wake ONCE on every addressed,
  # unseen message in it. This recovers everything that landed in the
  # reaper-kill gap (which the old EOF baseline stepped past) — and retires all
  # of it in this one arm, so a busy session can never accumulate an invisible
  # queue behind a one-message-per-arm limit (#44, #49).
  if drain_and_wake backlog \
       "armed: identity=$ME inbox=$INBOX filters=$FILTERS re-arm gap-recovered pid=$$" \
       < <(tail -n "$GAP_WINDOW" "$INBOX" | match_scan); then
    exit 0
  fi
  armkind="rearm"
fi

baseline=$(wc -l < "$INBOX" | tr -d ' ')
echo "armed: identity=$ME inbox=$INBOX filters=$FILTERS baseline=$baseline arm=$armkind interval=${INTERVAL}s pid=$$"

while :; do
  sleep "$INTERVAL"
  [ -f "$INBOX" ] || continue
  cur=$(wc -l < "$INBOX" | tr -d ' ')
  if [ "$cur" -lt "$baseline" ]; then
    # Inbox SHRANK — truncation or log rotation reset the file. Re-anchor the
    # baseline to the new EOF; otherwise cur never re-exceeds the stale (larger)
    # baseline and every post-rotation message is silently missed (fleet review,
    # 2026-06-27). The seen-ledger, not the line count, is now what prevents a
    # re-wake on retained content, so re-anchoring is safe.
    echo "rotation detected (inbox shrank $baseline->$cur) — re-anchoring baseline"
    baseline="$cur"
  elif [ "$cur" -gt "$baseline" ]; then
    # Every NEW line addressed to me, not self-sent, not automation noise, and
    # not already seen — all of them in one wake, not just the first. They are
    # marked seen before the exit so the re-arm that follows a genuine wake does
    # not re-fire on the same messages via its gap scan.
    if drain_and_wake new < <(tail -n +"$((baseline+1))" "$INBOX" | match_scan); then
      exit 0
    fi
    baseline="$cur"
  fi
done
