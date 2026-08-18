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
# skill under the home it is onboarding for.
onboard_env() {
  new_env
  jq '.per_repo_identity_allowed = true' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
    && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
  mkdir -p "$ROOT/repo"
  git -C "$ROOT/repo" init -q
}
run_onboard() { ( cd "${2:-$ROOT}"; HOME="$ROOT" NTFY_HOME="$ROOT" bash "$ONBOARD" "$@" 2>&1 ); }

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

finish
