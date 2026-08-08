# shellcheck shell=bash
# lib/capabilities.sh — runtime host-capability detection for ntfy-bus components.
#
# Source AFTER resolve-config.sh (uses $NTFY_CONFIG for the inbox check), then read:
#   NTFY_HAS_SYSTEMD      1 if a live systemd instance can run --user units
#   NTFY_HAS_DURABLE_INBOX 1 if the config names an inbox JSONL that exists
#   NTFY_PROC_PROBE       linux | darwin | none — how to inspect a PID's command line
#
# DOCTRINE: components branch on CAPABILITIES, never on host class ("LifeOS vs
# vanilla"). The one deliberate exception is the host-locked identity guard in
# resolve-config.sh — that is a security property, not a capability, and it is
# never detected away.

ntfy_detect_capabilities() {
  NTFY_HAS_SYSTEMD=0
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    NTFY_HAS_SYSTEMD=1
  fi

  NTFY_PROC_PROBE=none
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    NTFY_PROC_PROBE=darwin
  elif [ -r /proc/self/cmdline ]; then
    NTFY_PROC_PROBE=linux
  fi

  NTFY_HAS_DURABLE_INBOX=0
  if [ -n "${NTFY_CONFIG:-}" ] && [ -f "$NTFY_CONFIG" ]; then
    local _inbox
    _inbox=$(jq -r '.inbox_jsonl // ""' "$NTFY_CONFIG" 2>/dev/null)
    # Config paths may carry "~/" (bash won't expand it inside a variable).
    [ -n "$_inbox" ] && _inbox=$(ntfy_expand_home "$_inbox")
    [ -n "$_inbox" ] && [ -f "$_inbox" ] && NTFY_HAS_DURABLE_INBOX=1
  fi

  export NTFY_HAS_SYSTEMD NTFY_HAS_DURABLE_INBOX NTFY_PROC_PROBE
}

# Return PID $1's command line via the detected probe (empty if unreadable/none).
# Callers grep the result — the daemon's double-start guard and the statusline's
# pidfile probe MUST share this, or the OS matrix forks across files ungated.
ntfy_proc_cmdline() {
  case "$NTFY_PROC_PROBE" in
    linux)  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null ;;
    darwin) ps -p "$1" -o command= 2>/dev/null ;;
  esac
}

ntfy_detect_capabilities
