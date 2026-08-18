#!/usr/bin/env bash
# tests/doctor.sh — regression tests for bin/doctor.sh.
#
# Issue #13: the shadow scan must descend a SYMLINKED scan root (stow-managed
# ~/.local/bin) — `find` without -L treats the start point as a symlink, never
# descends, and reports a false all-clear on exactly the tidier hosts.
#
# Issue #19: doctor must report the tracking state of a repo-local identity
# config in the repo it is run from: tracked = DRIFT (the repo ships a live
# fleet identity to every clone), untracked-but-not-ignored = warn, ignored =
# ok (naming where the rule came from).
#
# Doctor probes $HOME directly (it is a host probe, not a config consumer), so
# each case runs it under a scratch HOME. Other sections (skill link, host
# config) will report their own DRIFT under that fake HOME — assertions here
# grep for the specific lines under test, never the exit code.
set -u
. "$(dirname "$0")/lib/harness.sh"
DOCTOR="$TESTS_DIR/../bin/doctor.sh"
# Keep doctor's `git fetch` off the network inside tests.
export GIT_ALLOW_PROTOCOL=file

run_doctor() { ( cd "${1:-$ROOT}"; HOME="$ROOT" NTFY_HOME="$ROOT" bash "$DOCTOR" 2>&1 ); }

echo "D1: shadow scan descends a symlinked scan root (issue #13)"
new_env
mkdir -p "$ROOT/dotfiles/bin"
touch "$ROOT/dotfiles/bin/ntfy-shadow-tool.sh"
ln -s "$ROOT/dotfiles/bin" "$ROOT/.local-bin-real" # control: not scanned
mkdir -p "$ROOT/.claude"
ln -s "$ROOT/dotfiles/bin" "$ROOT/.local/bin" 2>/dev/null || { mkdir -p "$ROOT/.local"; ln -s "$ROOT/dotfiles/bin" "$ROOT/.local/bin"; }
out=$(run_doctor)
case "$out" in
  *"ntfy-shadow-tool.sh"*) pass "shadow behind symlinked root surfaced" ;;
  *) fail "shadow behind symlinked root surfaced (got: '$out')" ;;
esac
cleanup

echo "D2: tracked identity config reported as DRIFT (issue #19)"
new_env
mkdir -p "$ROOT/repo/.claude"
git -C "$ROOT/repo" init -q
echo '{ "agent_id": "LeakedAgent" }' > "$ROOT/repo/.claude/ntfy-bus.config.json"
git -C "$ROOT/repo" add .claude/ntfy-bus.config.json
git -C "$ROOT/repo" -c user.email=t@t -c user.name=t commit -qm x
out=$(run_doctor "$ROOT/repo")
case "$out" in
  *"TRACKED"*) pass "tracked identity config flagged" ;;
  *) fail "tracked identity config flagged (got: '$out')" ;;
esac
cleanup

echo "D3: untracked, unignored identity config gets a warning (issue #19)"
new_env
mkdir -p "$ROOT/repo/.claude"
git -C "$ROOT/repo" init -q
echo '{ "agent_id": "LooseAgent" }' > "$ROOT/repo/.claude/ntfy-bus.config.json"
out=$(run_doctor "$ROOT/repo")
case "$out" in
  *"NOT ignored"*) pass "unignored identity config warned" ;;
  *) fail "unignored identity config warned (got: '$out')" ;;
esac
cleanup

echo "D4: ignored identity config is ok, naming the rule source (issue #19)"
new_env
mkdir -p "$ROOT/repo/.claude"
git -C "$ROOT/repo" init -q
echo '{ "agent_id": "FencedAgent" }' > "$ROOT/repo/.claude/ntfy-bus.config.json"
echo '.claude/ntfy-bus.config.json' >> "$ROOT/repo/.git/info/exclude"
out=$(run_doctor "$ROOT/repo")
case "$out" in
  *"identity config untracked + ignored"*) pass "ignored identity config ok" ;;
  *) fail "ignored identity config ok (got: '$out')" ;;
esac
case "$out" in
  *"info/exclude"*) pass "ignore rule source named" ;;
  *) fail "ignore rule source named (got: '$out')" ;;
esac
cleanup

echo "D5: no identity config in the cwd repo -> no tracking-state output at all"
new_env
mkdir -p "$ROOT/repo"
git -C "$ROOT/repo" init -q
out=$(run_doctor "$ROOT/repo")
case "$out" in
  *"identity config"*) fail "silent when no repo-local config (got: '$out')" ;;
  *) pass "silent when no repo-local config" ;;
esac
cleanup

finish
