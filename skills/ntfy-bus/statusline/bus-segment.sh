#!/bin/bash
# statusline/bus-segment.sh — canonical "BUS: ⏻ armed" statusline segment.
#
# SEMANTIC CONTENT IS CANONICAL, PRESENTATION IS HOST-LOCAL: this script decides
# WHAT the bus state is and prints a plain-text segment; the host's statusline
# decides WHERE it appears, with what colors and separators — or not at all.
# Whether/how the segment renders on a given machine is controlled entirely by
# the host-global config (the one source-of-truth file):
#
#   .statusline.enabled        false -> no output, exit 2 (default true)
#   .statusline.label          default "BUS"
#   .statusline.icon_armed     default "⏻"
#   .statusline.icon_down      default "⏚"
#   .statusline.show_when_down false -> silent when down (still exit 1)
#   .waker.mode                auto | systemd | pidfile | none  (default auto)
#   .waker.systemd_unit        default "bus-waker.service"
#   .waker.pidfile             NO default — per-host fact, config-only;
#                              unset => the pidfile probe is UNAVAILABLE
#   .waker.cmdline_match       default "bus-waker-daemon" (the shipped artifact's
#                              own name); hosts running their OWN wakers add
#                              those names in per-host config
#
# mode=auto: armed if ANY waker (durable systemd daemon OR in-session pidfile
# waker) is up. Pin mode=pidfile to keep "armed == in-session waker" semantics.
#
# Output: "BUS: ⏻ armed" on stdout. Exit: 0 armed, 1 down, 2 no segment
# (no config / disabled / mode=none). --state prints just "armed"/"down".
# STATUSLINE CONTEXT: runs on every render — must be fast and NEVER emit
# errors. All stderr is discarded up front.
exec 2>/dev/null

# Portable resolver — readlink -f is absent on macOS <12.3, and the install
# path is a DOUBLE symlink hop. Duplicated in daemon/bin (pre-lib bootstrap).
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
. "$LIB_DIR/resolve-config.sh" || exit 2
. "$LIB_DIR/capabilities.sh"   || exit 2

[ -f "$NTFY_CONFIG" ] || exit 2

CFG=$(jq -r '[
  (.statusline.enabled != false | tostring),
  (.statusline.label // "BUS"),
  (.statusline.icon_armed // "⏻"),
  (.statusline.icon_down // "⏚"),
  (.statusline.show_when_down != false | tostring),
  (.waker.mode // "auto"),
  (.waker.systemd_unit // "bus-waker.service"),
  (.waker.pidfile // ""),
  (.waker.cmdline_match // "bus-waker-daemon")
] | join("\u0001")' "$NTFY_CONFIG") || exit 2
IFS=$'\x01' read -r ENABLED LABEL ICON_ARMED ICON_DOWN SHOW_DOWN MODE UNIT PIDFILE CMD_MATCH <<< "$CFG"
# Same expansion the daemon applies when it WRITES the pidfile — one shared
# function (lib/resolve-config.sh), so the two can't drift.
PIDFILE=$(ntfy_expand_home "$PIDFILE")

[ "$ENABLED" = "false" ] && exit 2
[ "$MODE" = "none" ] && exit 2
# NO DEFAULT PIDFILE. This used to default to ~/.claude/.bus-monitor.pid, which
# is one specific host's private convention (proxima5's rearm-bus-monitor.sh) —
# shared code carrying a single machine's filename, which the portability floor
# forbids and the hardcoded-home ban does not catch ($HOME-relative slips it).
# Nothing in THIS repo writes that file, so the default made pidfile_armed()
# stat a path that never exists on a clean install: a permanently-false branch
# that reported DOWN on a healthy host. A pidfile path is a per-host fact and
# belongs in the per-host config (.waker.pidfile), not in shared code.
# RESOLVED: the shipped daemon now WRITES .waker.pidfile (fail-loud if
# unset), so on macOS — no systemd — a clean install CAN report "armed": set
# .waker.pidfile in the host config and this probe becomes the real answer.

systemd_armed() {
  [ "$NTFY_HAS_SYSTEMD" = "1" ] || return 1
  [ "$(systemctl --user is-active "$UNIT")" = "active" ]
}

# PID-reuse-safe, read-only: never claims the pidfile, only checks that the
# recorded PID is alive AND its command line matches a known waker.
pidfile_armed() {
  local pid cmd
  # No pidfile configured => this probe is UNAVAILABLE, not "down". Callers that
  # OR the probes together must not read an unavailable probe as a negative.
  [ -n "$PIDFILE" ] || return 2
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" || return 1
  cmd=$(ntfy_proc_cmdline "$pid")
  [ -n "$cmd" ] || return 1
  printf '%s' "$cmd" | grep -qE "$CMD_MATCH"
}

STATE=down
case "$MODE" in
  systemd) systemd_armed && STATE=armed ;;
  pidfile) pidfile_armed && STATE=armed ;;
  *)       { systemd_armed || pidfile_armed; } && STATE=armed ;;
esac

if [ "${1:-}" = "--state" ]; then
  printf '%s\n' "$STATE"
  [ "$STATE" = "armed" ]; exit
fi

if [ "$STATE" = "armed" ]; then
  printf '%s: %s armed' "$LABEL" "$ICON_ARMED"
  exit 0
fi
[ "$SHOW_DOWN" = "false" ] && exit 1
printf '%s: %s DOWN' "$LABEL" "$ICON_DOWN"
exit 1
