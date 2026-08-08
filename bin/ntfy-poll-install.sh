#!/bin/bash
# bin/ntfy-poll-install.sh — render + install + load a per-identity ntfy-poll
# LaunchAgent on macOS from launchd/ntfy-poll.plist.example.
#
# Each identity needs its own durable capture poller because a host can share
# one $HOME across agents (two repos, each with its own identity) — see
# daemons/ntfy-poll-to-jsonl.sh for why per-agent state files are required.
# This renders the shipped template for one identity and (re)loads the unit.
#
# WHY A RENDERER AND NOT A COMMITTED PLIST: launchd hands ProgramArguments to
# execve VERBATIM — it expands neither ~ nor $HOME — so the absolute paths have
# to be baked in for the host doing the install. Doing that here, in the shell,
# is what keeps an absolute path out of the repo. A committed plist carrying
# one host's /Users/<name> is how a stale fork gets wired to the next install.
#
# ProgramArguments points at the STABLE skill path, per the template's own path
# doctrine — never at a plugin cache, whose path changes on every update.
#
# Usage: ntfy-poll-install.sh <identity> <repo-path> [label-prefix]
#   identity      agent id, e.g. cindy (lowercased automatically)
#   repo-path     absolute path to the repo whose ntfy-bus config to poll as
#   label-prefix  reverse-DNS prefix for the LaunchAgent label (default: local)
#
# FORCE=1 overrides the double-schedule refusal. Read that guard first.
set -eu

AGENT_RAW="${1:?usage: ntfy-poll-install.sh <identity> <repo-path> [label-prefix]}"
REPO_ARG="${2:?usage: ntfy-poll-install.sh <identity> <repo-path> [label-prefix]}"
LABEL="${3:-local}"

# macOS only. On Linux the equivalent is systemd/ntfy-poll.{service,timer};
# silently producing a plist nothing will ever read would be worse than this.
[ "$(uname -s)" = "Darwin" ] || {
  echo "FATAL: launchd is macOS-only — on Linux install systemd/ntfy-poll.{service,timer}" >&2
  exit 1
}

# Reject anything that is not a plain reverse-DNS-ish token: the value lands in
# both a sed replacement and a filename.
case "$LABEL" in
  ''|*[!a-zA-Z0-9.-]*)
    echo "FATAL: label prefix must be alphanumerics, dots and hyphens only (got: '$LABEL')" >&2
    exit 1 ;;
esac

AGENT_LC=$(printf '%s' "$AGENT_RAW" | tr '[:upper:]' '[:lower:]')

# Portable symlink resolver — keep in sync with bin/check.sh (pre-lib bootstrap).
bus_resolve() {
  local t="$1" d
  while [ -L "$t" ]; do
    d=$(cd -P "$(dirname "$t")" && pwd -P); t=$(readlink "$t")
    case "$t" in /*) ;; *) t="$d/$t" ;; esac
  done
  printf '%s/%s' "$(cd -P "$(dirname "$t")" && pwd -P)" "$(basename "$t")"
}
REPO=$(cd -P "$(dirname "$(bus_resolve "${BASH_SOURCE[0]}")")/.." && pwd -P)

TEMPLATE="$REPO/skills/ntfy-bus/launchd/ntfy-poll.plist.example"
[ -f "$TEMPLATE" ] || { echo "FATAL: template not found: $TEMPLATE" >&2; exit 1; }
[ -d "$REPO_ARG" ] || { echo "FATAL: repo not found: $REPO_ARG" >&2; exit 1; }

# The template wires ProgramArguments to the stable skill path. Verify the file
# is really there and executable BEFORE writing a unit that points at it: a
# plist naming a missing program loads clean and then dies at spawn, which
# reads as "the poller just isn't running" with nothing obvious to blame.
POLLER="$HOME/.claude/skills/ntfy-bus/daemons/ntfy-poll-to-jsonl.sh"
[ -x "$POLLER" ] || {
  echo "FATAL: canonical poller not found/executable: $POLLER" >&2
  echo "       (install the skill to ~/.claude/skills/ntfy-bus first)" >&2
  exit 1
}

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
OUT="$LAUNCH_AGENTS/${LABEL}.ntfy-poll.${AGENT_LC}.plist"

# DOUBLE-SCHEDULE GUARD. The label prefix is free-form, so the same identity can
# be installed twice under two prefixes — launchd runs both, and two pollers
# appending to one inbox is exactly the interleaved/corrupt-lines failure that
# per-agent state files exist to prevent. Refuse, and name the other unit.
existing=$(ls "$LAUNCH_AGENTS"/*.ntfy-poll."${AGENT_LC}".plist 2>/dev/null | grep -v "^${OUT}$" || true)
if [ -n "$existing" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "FATAL: '${AGENT_LC}' is already scheduled under a different label prefix:" >&2
  printf '  %s\n' $existing >&2
  echo "       Two pollers on one identity corrupt its inbox. Remove the other unit," >&2
  echo "       or re-run with the same prefix, or FORCE=1 if you truly want both." >&2
  exit 1
fi

mkdir -p "$LAUNCH_AGENTS" "$HOME/.local/state"

sed -e "s#__AGENT__#${AGENT_LC}#g" \
    -e "s#__HOME__#${HOME}#g" \
    -e "s#__REPO__#${REPO_ARG}#g" \
    -e "s#__LABEL__#${LABEL}#g" \
    "$TEMPLATE" > "$OUT"

# Fail loud on an incomplete render rather than loading a broken unit: a
# leftover placeholder means a new one was added to the template without being
# threaded through here. Checked against the plist BODY only — the template's
# comment block documents the placeholders in prose ("substitute the four
# __PLACEHOLDERS__"), which is not itself a placeholder. Matching any
# __TOKEN__, rather than the four names known today, is deliberate: a name-list
# would go stale the moment someone adds a fifth, which is the case this exists
# to catch.
if printf '%s\n' "$(sed '/<!--/,/-->/d' "$OUT")" | grep -q '__[A-Z]*__'; then
  echo "FATAL: unsubstituted placeholder(s) left in $OUT:" >&2
  sed '/<!--/,/-->/d' "$OUT" | grep -n '__[A-Z]*__' >&2
  rm -f "$OUT"
  exit 1
fi
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$OUT" >/dev/null || { echo "FATAL: rendered plist is malformed: $OUT" >&2; rm -f "$OUT"; exit 1; }
fi

echo "wrote $OUT"
launchctl unload "$OUT" 2>/dev/null || true
launchctl load "$OUT"
echo "loaded ${LABEL}.ntfy-poll.${AGENT_LC} (repo=$REPO_ARG, poller=$POLLER)"
