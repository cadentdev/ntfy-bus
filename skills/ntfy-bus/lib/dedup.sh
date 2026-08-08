# shellcheck shell=bash
# lib/dedup.sh — per-message dedup keyed on the ntfy message .id.
#
# THE ruling (fleet review, 2026-07-07): dedup is implemented ONCE, here,
# keyed on ntfy `.id`, and consumed by every waker/inbox consumer — the shell
# waker daemon and (when its wiring lands) Pulse's bus-inbox.ts. Rationale:
# `tail -F` across the watcher's inbox rotation REPLAYS the kept window from
# byte 0, so consumers MUST treat message ids as at-most-once.
#
#   bus_cap_trim FILE CAP KEEP   bound an append-only file: >CAP lines -> keep KEEP
#   bus_seen ID FILE             0 (true) if ID already recorded in FILE
#   bus_mark_seen ID FILE CAP KEEP   record ID, then cap-trim FILE

bus_cap_trim() {
  local f="$1" cap="$2" keep="$3" n
  [ -f "$f" ] || return 0
  n=$(wc -l < "$f" 2>/dev/null || echo 0)
  if [ "$n" -gt "$cap" ]; then
    tail -n "$keep" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
}

bus_seen() {
  local id="$1" f="$2"
  [ -f "$f" ] || return 1
  grep -qxF "$id" "$f"
}

bus_mark_seen() {
  local id="$1" f="$2" cap="${3:-500}" keep="${4:-300}"
  printf '%s\n' "$id" >> "$f"
  bus_cap_trim "$f" "$cap" "$keep"
}
