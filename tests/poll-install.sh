#!/usr/bin/env bash
# tests/poll-install.sh — regression tests for skills/ntfy-bus/bin/ntfy-poll-install.sh.
#
# Issue #22 (same class as #17): the installer lived in root bin/, which a
# skill install never ships — the documented ~/bin shim's target dangled and a
# skill-only host had NO working path to the poller installer. It now lives in
# skills/ntfy-bus/bin/ and anchors its template to the SKILL dir, so clone,
# symlink, and plugin installs all reach it at one path.
#
# The install itself (launchctl load) is deliberately not exercised — these
# cases stop at the guards. What matters here is that template resolution
# works from the new location, including through the installed-skill symlink
# the dotfiles shim uses.
set -u
. "$(dirname "$0")/lib/harness.sh"
INSTALLER="$SKILL_ROOT/bin/ntfy-poll-install.sh"

[ -f "$INSTALLER" ] || { echo "installer missing at $INSTALLER"; exit 1; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "I1: non-macOS host refuses with the systemd pointer"
  rc=0; out=$(bash "$INSTALLER" foo /tmp 2>&1) || rc=$?
  assert_eq "exits 1" "1" "$rc"
  case "$out" in
    *"macOS-only"*) pass "points at systemd instead" ;;
    *) fail "points at systemd instead (got: '$out')" ;;
  esac
  finish
  exit $?
fi

echo "I1: template resolves from the skill location (direct path)"
new_env
rc=0; out=$(bash "$INSTALLER" testagent "$ROOT/nonexistent-repo" 2>&1) || rc=$?
assert_eq "exits 1 on bogus repo" "1" "$rc"
case "$out" in
  *"template not found"*) fail "template found (got: '$out')" ;;
  *"repo not found"*) pass "template found; failed later at the repo guard" ;;
  *) fail "unexpected failure (got: '$out')" ;;
esac
cleanup

echo "I2: template resolves through an installed-skill symlink (the shim path)"
new_env
mkdir -p "$ROOT/.claude/skills"
ln -s "$SKILL_ROOT" "$ROOT/.claude/skills/ntfy-bus"
rc=0; out=$(bash "$ROOT/.claude/skills/ntfy-bus/bin/ntfy-poll-install.sh" testagent "$ROOT/nonexistent-repo" 2>&1) || rc=$?
assert_eq "exits 1 on bogus repo" "1" "$rc"
case "$out" in
  *"template not found"*) fail "template found via symlink (got: '$out')" ;;
  *"repo not found"*) pass "template found via symlink; failed later at the repo guard" ;;
  *) fail "unexpected failure via symlink (got: '$out')" ;;
esac
cleanup

finish
