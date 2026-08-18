#!/usr/bin/env bash
# tests/onboard.sh — regression tests for bin/onboard.sh (issue #21).
#
# onboard.sh folds the mechanical half of Setup step 6 into one idempotent
# script: repo-local identity config (fleet settings copied from the
# host-global config), instant fence via .git/info/exclude, host-global
# BridgeBodyGuard wiring, and a printed list of the steps that still need a
# human. It must refuse cleanly on locked hosts (write-time hijack guard) and
# skip cleanly everything already done.
set -u
. "$(dirname "$0")/lib/harness.sh"
ONBOARD="$TESTS_DIR/../bin/onboard.sh"

# Unlocked host + a git repo to onboard. HOME is pointed at the scratch root
# too: onboard writes the host-global settings.json and probes the installed
# skill under the home it is onboarding for. The hook fixture (skill hook file
# + executable bun fallback) exists because onboard refuses to wire a hook
# whose interpreter or file it cannot verify.
onboard_env() {
  new_env
  jq '.per_repo_identity_allowed = true' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
    && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
  mkdir -p "$ROOT/repo"
  git -C "$ROOT/repo" init -q
  mkdir -p "$ROOT/.claude/skills/ntfy-bus/hooks" "$ROOT/.bun/bin"
  touch "$ROOT/.claude/skills/ntfy-bus/hooks/BridgeBodyGuard.hook.ts"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/.bun/bin/bun" && chmod +x "$ROOT/.bun/bin/bun"
}
run_onboard() { ( HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ONBOARD" "$@" 2>&1 ); }

echo "O1: locked host (PAI marker) refuses cleanly"
onboard_env
mkdir -p "$ROOT/.claude/PAI"
rc=0; out=$( ( cd "$ROOT/repo"; HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ONBOARD" NewAgent "$ROOT/repo" 2>&1 ) ) || rc=$?
assert_eq "locked refusal exits 1" "1" "$rc"
case "$out" in
  *"host-locked"*) pass "refusal names the lock" ;;
  *) fail "refusal names the lock (got: '$out')" ;;
esac
[ ! -f "$ROOT/repo/.claude/ntfy-bus.config.json" ] && pass "no identity born on a locked host" \
  || fail "no identity born on a locked host"
cleanup

echo "O2: unopted host refuses, pointing at Setup"
onboard_env
jq '.per_repo_identity_allowed = false' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
rc=0; out=$( ( HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ONBOARD" NewAgent "$ROOT/repo" 2>&1 ) ) || rc=$?
assert_eq "unopted refusal exits 1" "1" "$rc"
case "$out" in
  *"Setup"*) pass "points at the Setup workflow" ;;
  *) fail "points at the Setup workflow (got: '$out')" ;;
esac
cleanup

echo "O3: fresh onboard writes config + fence + hook wiring, lists human steps"
onboard_env
rc=0; out=$( ( HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ONBOARD" NewAgent "$ROOT/repo" 2>&1 ) ) || rc=$?
assert_eq "fresh onboard exits 0" "0" "$rc"
cfg="$ROOT/repo/.claude/ntfy-bus.config.json"
assert_eq "repo config carries the identity" "NewAgent" "$(jq -r '.agent_id' "$cfg" 2>/dev/null)"
assert_eq "fleet endpoint copied from host-global" "http://127.0.0.1:9/unused" "$(jq -r '.endpoint' "$cfg" 2>/dev/null)"
assert_eq "inbox is per-identity" "~/.claude/ntfy-inbox.newagent.jsonl" "$(jq -r '.inbox_jsonl' "$cfg" 2>/dev/null)"
assert_true "fence in .git/info/exclude" grep -qxF '.claude/ntfy-bus.config.json' "$ROOT/repo/.git/info/exclude"
assert_true "config is git-ignored" git -C "$ROOT/repo" check-ignore -q .claude/ntfy-bus.config.json
assert_contains "hook wired host-globally" "$ROOT/.claude/settings.json" "BridgeBodyGuard"
case "$out" in
  *"still need a human"*) pass "human-steps section printed" ;;
  *) fail "human-steps section printed (got: '$out')" ;;
esac
case "$out" in
  *".gitignore"*) pass "tracked-fence follow-up listed" ;;
  *) fail "tracked-fence follow-up listed (got: '$out')" ;;
esac
cleanup

echo "O4: re-run is idempotent — skips, never duplicates"
onboard_env
( HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ONBOARD" NewAgent "$ROOT/repo" ) >/dev/null 2>&1
rc=0; out=$( ( HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ONBOARD" NewAgent "$ROOT/repo" 2>&1 ) ) || rc=$?
assert_eq "re-run exits 0" "0" "$rc"
assert_eq "fence not duplicated" "1" "$(grep -cxF '.claude/ntfy-bus.config.json' "$ROOT/repo/.git/info/exclude")"
assert_eq "hook not duplicated" "1" "$(grep -o 'BridgeBodyGuard' "$ROOT/.claude/settings.json" | wc -l | tr -d ' ')"
case "$out" in
  *"skip"*|*"already"*) pass "re-run reports skips" ;;
  *) fail "re-run reports skips (got: '$out')" ;;
esac
cleanup

echo "O5: existing repo config under a DIFFERENT identity refuses"
onboard_env
mkdir -p "$ROOT/repo/.claude"
echo '{ "agent_id": "SomeoneElse" }' > "$ROOT/repo/.claude/ntfy-bus.config.json"
rc=0; out=$( ( HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ONBOARD" NewAgent "$ROOT/repo" 2>&1 ) ) || rc=$?
assert_eq "identity mismatch exits 1" "1" "$rc"
case "$out" in
  *"SomeoneElse"*) pass "mismatch names the existing identity" ;;
  *) fail "mismatch names the existing identity (got: '$out')" ;;
esac
cleanup

echo "O6: a TRACKED identity config refuses with untrack guidance"
onboard_env
mkdir -p "$ROOT/repo/.claude"
echo '{ "agent_id": "NewAgent" }' > "$ROOT/repo/.claude/ntfy-bus.config.json"
git -C "$ROOT/repo" add .claude/ntfy-bus.config.json
git -C "$ROOT/repo" -c user.email=t@t -c user.name=t commit -qm x
rc=0; out=$( ( HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ONBOARD" NewAgent "$ROOT/repo" 2>&1 ) ) || rc=$?
assert_eq "tracked config exits 1" "1" "$rc"
case "$out" in
  *"rm --cached"*) pass "untrack guidance printed" ;;
  *) fail "untrack guidance printed (got: '$out')" ;;
esac
cleanup

echo "O7: tracked-but-DELETED config refuses BEFORE writing into the tracked path"
onboard_env
mkdir -p "$ROOT/repo/.claude"
echo '{ "agent_id": "NewAgent" }' > "$ROOT/repo/.claude/ntfy-bus.config.json"
git -C "$ROOT/repo" add .claude/ntfy-bus.config.json
git -C "$ROOT/repo" -c user.email=t@t -c user.name=t commit -qm x
rm "$ROOT/repo/.claude/ntfy-bus.config.json"
rc=0; out=$(run_onboard NewAgent "$ROOT/repo") || rc=$?
assert_eq "tracked-deleted exits 1" "1" "$rc"
[ ! -f "$ROOT/repo/.claude/ntfy-bus.config.json" ] \
  && pass "nothing written into the tracked path" \
  || fail "nothing written into the tracked path"
cleanup

echo "O8: linked worktree — the fence lands where git actually reads it"
onboard_env
git -C "$ROOT/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$ROOT/repo" worktree add -q "$ROOT/wt" 2>/dev/null
rc=0; out=$(run_onboard NewAgent "$ROOT/wt") || rc=$?
assert_eq "worktree onboard exits 0" "0" "$rc"
assert_true "config ignored inside the worktree" git -C "$ROOT/wt" check-ignore -q .claude/ntfy-bus.config.json
cleanup

echo "O9: a subdirectory target is normalized to the git toplevel"
onboard_env
mkdir -p "$ROOT/repo/src"
rc=0; out=$(run_onboard NewAgent "$ROOT/repo/src") || rc=$?
assert_eq "subdir onboard exits 0" "0" "$rc"
[ -f "$ROOT/repo/.claude/ntfy-bus.config.json" ] && pass "config written at the toplevel" \
  || fail "config written at the toplevel"
[ ! -e "$ROOT/repo/src/.claude" ] && pass "nothing written under the subdirectory" \
  || fail "nothing written under the subdirectory"
cleanup

echo "O10: missing host-global config gets ITS OWN message (not the opt-in one)"
onboard_env
rm -f "$ROOT/.claude/ntfy-bus.config.json"
rc=0; out=$(run_onboard NewAgent "$ROOT/repo") || rc=$?
assert_eq "no-config exits 1" "1" "$rc"
case "$out" in
  *"no host-global config"*) pass "message names the missing config" ;;
  *) fail "message names the missing config (got: '$out')" ;;
esac
cleanup

echo "O11: hostile or reserved agent names refuse before touching anything"
onboard_env
rc=0; out=$(run_onboard 'A/B' "$ROOT/repo") || rc=$?
assert_eq "slash name exits 1" "1" "$rc"
rc=0; out=$(run_onboard ALL "$ROOT/repo") || rc=$?
assert_eq "ALL exits 1" "1" "$rc"
case "$out" in
  *"broadcast"*) pass "ALL refusal names the reservation" ;;
  *) fail "ALL refusal names the reservation (got: '$out')" ;;
esac
cleanup

echo "O12: an incomplete same-name config is refused, not skipped as done"
onboard_env
mkdir -p "$ROOT/repo/.claude"
echo '{ "agent_id": "NewAgent" }' > "$ROOT/repo/.claude/ntfy-bus.config.json"
rc=0; out=$(run_onboard NewAgent "$ROOT/repo") || rc=$?
assert_eq "incomplete config exits 1" "1" "$rc"
case "$out" in
  *"missing required keys"*) pass "incompleteness named" ;;
  *) fail "incompleteness named (got: '$out')" ;;
esac
cleanup

echo "O13: hook is NOT wired when its file or interpreter is unverifiable"
onboard_env
rm -f "$ROOT/.claude/skills/ntfy-bus/hooks/BridgeBodyGuard.hook.ts"
rc=0; out=$(run_onboard NewAgent "$ROOT/repo") || rc=$?
assert_eq "onboard still exits 0" "0" "$rc"
if grep -q 'BridgeBodyGuard' "$ROOT/.claude/settings.json" 2>/dev/null; then
  fail "no broken hook entry written"
else
  pass "no broken hook entry written"
fi
case "$out" in
  *"wire BridgeBodyGuard"*) pass "hook queued as a human step" ;;
  *) fail "hook queued as a human step (got: '$out')" ;;
esac
cleanup

finish
