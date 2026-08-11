#!/bin/bash
# skills/ntfy-bus/bin/ntfy-waker-status.sh — which identities have a waker armed
# on this host,
# right now, in one command. Read-only; exit 0 = ran, not "all armed".
#
# WHY THIS EXISTS: daemons/ntfy-bus-waker.sh is the same script for every
# identity, so `ps aux | grep ntfy-bus-waker` shows a live process without
# telling you WHOSE it is. On a shared-$HOME multi-identity host that ambiguity
# produced a real false positive (2026-07-02): one identity reported
# its waker armed because *a* waker was running — it was another identity's,
# and the first had none at all. Namespacing already keeps the two wakers' DATA
# apart; what was missing was a command that SURFACES that namespacing instead
# of a manual ps + lsof + cat-the-pidfile cross-reference every time.
#
# PATHS ARE CONFIG-ANCHORED, NEVER CONVENTIONAL. The waker derives its pidfile
# from the configured inbox (ntfy-bus-waker.sh: PIDFILE="${INBOX%.jsonl}.waker
# .pid"); this script derives it the same way from the same config, so the two
# cannot drift into watching different files. This is load-bearing, not style:
# a host-local ancestor of this script guessed ~/.claude/ntfy-waker.<id>.pid
# and could therefore NEVER see a canonical waker — it reported NOT ARMED for
# an armed waker, i.e. the exact false reading it was written to eliminate,
# with the polarity flipped. Guessing a state path is how that happens.
#
# The host-wide table discovers identities by scanning the directory holding
# the configured inbox. Enumeration is unavoidably a heuristic — a host cannot
# list identities it was never told about — but every PATH it reports is either
# read from config or derived exactly as the waker derives it.
#
# DISCOVERY IS ARTIFACT-GATED: a *.jsonl counts as a
# bus inbox only when a poller/waker sibling exists for its stem (.poll-state,
# .wake-seen, .waker.pid). Presence of those files is *evidence* the bus wrote
# here; a bare .jsonl in a shared ~/.claude (history.jsonl, retired naming
# generations) is not. Deliberate consequence: an identity whose inbox exists
# but has never been polled or woken does not appear at all — this table
# reports live wake state, not directory contents.
#
# ROWS ARE KEYED BY IDENTITY, NOT BY FILE STEM: a pidfile stem and an
# inbox stem may differ for one identity (config-set pidfile vs inbox-derived),
# and stem-keyed rows split that identity into two half-rows that each
# fabricate an absence ("no inbox" / "not armed"). The join key is the trimmed
# identity token — a promotion of the display-label trim to grouping, and the
# one place this script depends on the naming scheme. Accepted trade-off:
# grouping affects presentation only; every path and pid shown still comes
# from an observed file. One identity CAN legitimately hold several pidfiles
# (two waker implementations racing); that renders as one row per pidfile,
# because two armed wakers is a true state the reader needs to see.
#
# LIVENESS AND IDENTIFICATION ARE SEPARATE QUESTIONS: kill -0 answers
# "alive"; the command-name match answers "which script". A live pid whose
# command is not a known waker renders as "alive (unknown cmd)" — never as
# "stale pidfile", which invites killing a working process, and never as
# armed, which would vouch for a process this script cannot identify.
#
# PORTABLE: bash 3.2 (macOS /bin/bash) + jq. No associative arrays. cwd lookup
# prefers /proc (Linux) and falls back to lsof; prints "?" rather than failing
# if neither is available. mtime tries BSD stat(1) then GNU stat(1).
#
# Usage: ntfy-waker-status.sh
set -u

# Portable symlink resolver — keep in sync with bin/check.sh (pre-lib bootstrap).
bus_resolve() {
  local t="$1" d
  while [ -L "$t" ]; do
    d=$(cd -P "$(dirname "$t")" && pwd -P); t=$(readlink "$t")
    case "$t" in /*) ;; *) t="$d/$t" ;; esac
  done
  printf '%s/%s' "$(cd -P "$(dirname "$t")" && pwd -P)" "$(basename "$t")"
}
# Anchor to the SKILL dir (this script's parent), never to a repo root: the
# skill is the unit that ships, and under a plugin install there is no repo
# above it. Resolving via ../.. was why this tool was reachable only from a
# clone (issue #17).
SKILL_DIR=$(cd -P "$(dirname "$(bus_resolve "${BASH_SOURCE[0]}")")/.." && pwd -P)

# shellcheck source=skills/ntfy-bus/lib/resolve-config.sh
. "$SKILL_DIR/lib/resolve-config.sh"

[ -f "${NTFY_CONFIG:-}" ] || {
  echo "FATAL: config missing/unresolved at ${NTFY_CONFIG:-unresolved} — run the Setup workflow" >&2
  exit 1
}

ME=$(jq -r '.agent_id // empty' "$NTFY_CONFIG" 2>/dev/null)

# State paths have NO code defaults (see CLAUDE.md): read from config, fail loud
# when absent. A guessed inbox path here would resolve the whole table against
# one host's filesystem layout and silently report on the wrong files.
INBOX=$(jq -r '.inbox_jsonl // ""' "$NTFY_CONFIG" 2>/dev/null)
if [ -z "$INBOX" ]; then
  echo "FATAL: .inbox_jsonl missing/empty in $NTFY_CONFIG — state paths are per-machine config, not code defaults" >&2
  exit 1
fi
INBOX=$(ntfy_expand_home "$INBOX")
STATE_DIR=$(dirname "$INBOX")
# Byte-identical to the waker's own derivation. If that line changes, this one
# changes with it — that coupling is the point.
MY_PIDFILE="${INBOX%.jsonl}.waker.pid"

# GNU FIRST, and the caller validates. BSD-first was wrong in a way the `||`
# cannot catch: GNU `stat -f` is not a format flag, it means FILE SYSTEM status,
# so it SUCCEEDS on Linux and prints a multi-line block. The fallback therefore
# never fired and the block reached arithmetic context, where the bare word
# `File` aborted the subshell under `set -u` (issue #4). BSD has no `-c` and
# fails cleanly with exit 1, so this order is safe both ways — verified on both.
mtime_epoch() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

human_age() {
  local secs=$1
  if   [ "$secs" -lt 60 ];    then printf '%ds' "$secs"
  elif [ "$secs" -lt 3600 ];  then printf '%dm' $((secs / 60))
  elif [ "$secs" -lt 86400 ]; then printf '%dh' $((secs / 3600))
  else                             printf '%dd' $((secs / 86400)); fi
}

pid_cwd() {
  local pid=$1
  if [ -r "/proc/$pid/cwd" ]; then
    readlink "/proc/$pid/cwd" 2>/dev/null && return
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | tail -n1 && return
  fi
  echo "?"
}

# Every waker implementation in the fleet, in ONE place. The old
# single-name grep reported the repo's own bus-waker-daemon.sh as "stale
# pidfile" — a live, working process, flagged for cleanup. Add a fourth
# implementation HERE, not in a new grep.
KNOWN_WAKER_NAMES='ntfy-bus-waker|bus-waker-daemon'

is_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

is_known_waker() {
  ps -p "$1" -o command= 2>/dev/null | grep -Eq "$KNOWN_WAKER_NAMES"
}

# WHICH JOB a row represents, read from the running process's COMMAND — not
# from the pidfile's name. The distinction matters: identity is invisible in
# argv (every identity runs the same script), but the JOB is not, because the
# two jobs are different scripts. So this is evidence, not a naming heuristic
# like identity_key, and it stays correct when a host config sets a pidfile
# path that does not follow the usual stem convention.
#
# Without this column the documented healthy pair — one durable daemon plus one
# in-session waker — renders as two identical armed rows for one identity, i.e.
# indistinguishable from the drift it is most likely to be consulted about. The
# obvious remedy for that misreading is to kill one, and the one that looks
# redundant is the daemon that provides durable capture (issue #14).
waker_job() {
  case "$(ps -p "$1" -o command= 2>/dev/null)" in
    *bus-waker-daemon*) printf 'daemon' ;;
    *ntfy-bus-waker*)   printf 'waker'  ;;
    *)                  printf '?'      ;;
  esac
}

# --- Step 1: "is MY waker armed" — a direct answer, not a table to scan ---
if [ -n "$ME" ]; then
  my_pid=$(cat "$MY_PIDFILE" 2>/dev/null)
  if is_alive "$my_pid" && is_known_waker "$my_pid"; then
    echo "This repo's identity ($ME): ARMED (pid $my_pid)"
  elif is_alive "$my_pid"; then
    # Alive but not a script we recognise. Saying NOT ARMED here would hint
    # the reader into arming a SECOND waker next to a live one.
    echo "This repo's identity ($ME): UNCLEAR — pidfile pid $my_pid is alive but runs an unrecognised command:"
    echo "  $(ps -p "$my_pid" -o command= 2>/dev/null)"
    echo "  inspect it before arming anything."
  else
    echo "This repo's identity ($ME): NOT ARMED"
    echo "  arm it: bash \"$SKILL_DIR/daemons/ntfy-bus-waker.sh\"   (run in background, from this repo's cwd)"
  fi
  echo
fi

# --- Step 2: host-wide table ---

# Identity token from a stem basename. The same trimming the display label
# always used, now also the row-grouping key (see header: the one deliberate
# naming-scheme dependency, presentation-only).
identity_key() {
  local k
  k=$(basename "$1")
  case "$k" in
    ntfy-inbox.*) k="${k#ntfy-inbox.}" ;;
    ntfy-inbox-*) k="${k#ntfy-inbox-}" ;;
    ntfy-bus.*)   k="${k#ntfy-bus.}"   ;;
  esac
  printf '%s' "$k"
}

# A .jsonl is a bus inbox only with poller/waker evidence beside it.
has_bus_artifact() {
  [ -e "$1.poll-state" ] || [ -e "$1.wake-seen" ] || [ -e "$1.waker.pid" ]
}

# Evidence lines: key<TAB>kind<TAB>stem. Every stem here is an observed file.
evidence=$(
  for f in "$STATE_DIR"/*.waker.pid; do
    [ -e "$f" ] && printf '%s\t%s\t%s\n' "$(identity_key "${f%.waker.pid}")" pid "${f%.waker.pid}"
  done
  for f in "$STATE_DIR"/*.jsonl; do
    [ -e "$f" ] || continue
    has_bus_artifact "${f%.jsonl}" || continue
    printf '%s\t%s\t%s\n' "$(identity_key "${f%.jsonl}")" inbox "${f%.jsonl}"
  done | sort -u
)

if [ -z "$evidence" ]; then
  echo "No waker pidfiles or artifact-backed inboxes found under $STATE_DIR."
  exit 0
fi

printf '%-22s %-7s %-8s %-20s %-40s %s\n' "IDENTITY" "JOB" "PID" "STATUS" "CWD" "INBOX AGE"
now=$(date +%s)
printf '%s\n' "$evidence" | cut -f1 | sort -u | while IFS= read -r key; do
  [ -n "$key" ] || continue

  # One inbox per identity (first found if several); age shared by its rows.
  inbox_stem=$(printf '%s\n' "$evidence" \
    | awk -F'\t' -v k="$key" '$1==k && $2=="inbox" {print $3; exit}')
  age="no inbox"
  if [ -n "$inbox_stem" ] && [ -f "${inbox_stem}.jsonl" ]; then
    mt=$(mtime_epoch "${inbox_stem}.jsonl")
    # Numeric, not merely non-empty: the failure mode this guards was never
    # "no output", it was confident output of the wrong KIND. Ordering alone
    # fixes today's Linux; this is what stops the shape recurring.
    case "$mt" in ''|*[!0-9]*) ;; *) age="$(human_age $((now - mt))) ago" ;; esac
  fi

  label="$key"
  [ -n "$inbox_stem" ] && [ "$inbox_stem" = "${INBOX%.jsonl}" ] && label="$key *"

  # One row PER PIDFILE: two live wakers on one identity is a true state
  # the reader must see, not a duplicate to collapse.
  pid_stems=$(printf '%s\n' "$evidence" \
    | awk -F'\t' -v k="$key" '$1==k && $2=="pid" {print $3}')

  if [ -z "$pid_stems" ]; then
    printf '%-22s %-7s %-8s %-20s %-40s %s\n' "$label" "-" "-" "not armed" "-" "$age"
    continue
  fi

  printf '%s\n' "$pid_stems" | while IFS= read -r stem; do
    pid=$(cat "${stem}.waker.pid" 2>/dev/null)
    cwd="-"
    # A stale pidfile has no process, so no command, so no job: "-" rather than
    # a guess from the stem, which would be exactly the conventional-path
    # inference this script refuses everywhere else.
    job="-"
    if is_alive "$pid"; then
      job=$(waker_job "$pid")
      if is_known_waker "$pid"; then
        status="armed"
      else
        status="alive (unknown cmd)"
      fi
      cwd=$(pid_cwd "$pid")
    else
      status="stale pidfile"
    fi
    printf '%-22s %-7s %-8s %-20s %-40s %s\n' "$label" "$job" "${pid:--}" "$status" "$cwd" "$age"
  done
done

echo
echo "* = this repo's configured identity.  Paths anchored to $STATE_DIR (from .inbox_jsonl)."
echo "Only artifact-backed inboxes are listed (.poll-state/.wake-seen/.waker.pid sibling required)."
