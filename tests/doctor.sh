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

echo "D6: doctor names the host class and the marker that produced it (issue #46)"
new_env
out=$(run_doctor)
case "$out" in
  *"host class: vanilla"*"lock state: no-optin"*) pass "vanilla host reported, with its lock state" ;;
  *) fail "vanilla host reported, with its lock state (got: '$out')" ;;
esac
mkdir -p "$ROOT/.claude/LIFEOS"
out=$(run_doctor)
case "$out" in
  *"host class: lifeos (marker: ~/.claude/LIFEOS/)"*) pass "current-LifeOS marker reported" ;;
  *) fail "current-LifeOS marker reported (got: '$out')" ;;
esac
case "$out" in
  *"per_repo_identity_allowed"*) fail "no opt-in warning without the flag (got: '$out')" ;;
  *) pass "no opt-in warning without the flag" ;;
esac
rmdir "$ROOT/.claude/LIFEOS"; mkdir -p "$ROOT/.claude/PAI"
out=$(run_doctor)
case "$out" in
  *"host class: lifeos (marker: ~/.claude/PAI/)"*) pass "legacy marker reported" ;;
  *) fail "legacy marker reported (got: '$out')" ;;
esac
cleanup

echo "D7: LifeOS host carrying the per-repo opt-in flag is DRIFT (issue #46)"
new_env
mkdir -p "$ROOT/.claude/LIFEOS"
jq '.per_repo_identity_allowed = true' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
out=$(run_doctor)
case "$out" in
  *"DRIFT host-global config sets per_repo_identity_allowed: true on a LifeOS host"*"EXPECT_AGENT"*) pass "inert opt-in flag is DRIFT and names the poller consequence" ;;
  *) fail "inert opt-in flag is DRIFT and names the poller consequence (got: '$out')" ;;
esac
cleanup

# A doctor whose lib predates the host-class functions must say it cannot
# tell — printing "vanilla" by default would be the silent wrong answer this
# line exists to end. Run a COPY of bin/ + skills/ with the functions removed.
echo "D8: stale lib -> doctor says it cannot determine host class (issue #46)"
new_env
mkdir -p "$ROOT/clone" "$ROOT/.claude/LIFEOS"
cp -R "$TESTS_DIR/../bin" "$TESTS_DIR/../skills" "$ROOT/clone/"
sed -e 's/^ntfy_lifeos_marker()/ntfy_gone_marker()/' -e 's/^ntfy_host_class()/ntfy_gone_class()/' \
  "$SKILL_ROOT/lib/resolve-config.sh" > "$ROOT/clone/skills/ntfy-bus/lib/resolve-config.sh"
out=$( ( cd "$ROOT"; HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ROOT/clone/bin/doctor.sh" 2>&1 ) )
case "$out" in
  *"DRIFT cannot determine host class"*) pass "stale lib reported, not guessed" ;;
  *) fail "stale lib reported, not guessed (got: '$out')" ;;
esac
case "$out" in
  *"host class: vanilla"*) fail "never prints vanilla by default (got: '$out')" ;;
  *) pass "never prints vanilla by default" ;;
esac
cleanup

finish
