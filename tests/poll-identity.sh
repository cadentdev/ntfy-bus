#!/usr/bin/env bash
# tests/poll-identity.sh — regression tests for daemons/ntfy-poll-to-jsonl.sh
# identity resolution and the EXPECT_AGENT guard.
#
# Issue #12: on a host-locked host the resolver returns the host-global config
# before ever reading a repo path, so NTFY_POLL_REPO has zero influence on
# identity there — a stale path must not abort capture. On an UNLOCKED host the
# repo genuinely selects identity, so there a missing repo stays FATAL.
#
# Issue #5: EXPECT_AGENT must accept the identity as .agent_id spells it —
# the comparison folds case on BOTH sides, not just the resolved one.
#
# No live bus: the poller is expected to stop at the credential gate ("missing
# ntfy credentials" in its run log), which proves it got PAST identity + repo
# resolution. The scratch config names auth vars that exist nowhere, so the
# gate fires deterministically even if the operator's ~/.env carries real creds.
set -u
. "$(dirname "$0")/lib/harness.sh"
POLLER="$SKILL_ROOT/daemons/ntfy-poll-to-jsonl.sh"

# Point auth at var names no real env file carries (see header).
unique_auth() {
  jq '.auth_env = {"username":"TESTBUS_POLL_USER","password":"TESTBUS_POLL_PASS"}' \
    "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

run_poller() { # [extra env assignments via caller's `env`] — captures stderr, discards stdout
  ( cd "$ROOT"; NTFY_HOME="$ROOT" "$@" bash "$POLLER" 2>&1 >/dev/null )
}

echo "P1: locked host — stale NTFY_POLL_REPO must not kill capture (issue #12)"
new_env
unique_auth "$ROOT/.claude/ntfy-bus.config.json"
err=$( ( cd "$ROOT"; NTFY_HOME="$ROOT" NTFY_POLL_REPO="$ROOT/renamed-away" bash "$POLLER" 2>&1 >/dev/null ) ) || true
case "$err" in
  *"repo not found"*) fail "stale repo path ignored on locked host (got: '$err')" ;;
  *) pass "stale repo path ignored on locked host" ;;
esac
LOG="${INBOX%.jsonl}.poll.log"
assert_contains "poller reached the credential gate" "$LOG" "missing ntfy credentials"
cleanup

echo "P2: EXPECT_AGENT accepts the identity as .agent_id spells it (issue #5)"
new_env
unique_auth "$ROOT/.claude/ntfy-bus.config.json"
err=$( ( cd "$ROOT"; NTFY_HOME="$ROOT" EXPECT_AGENT="TestAgent" bash "$POLLER" 2>&1 >/dev/null ) ) || true
case "$err" in
  *"identity guard"*) fail "EXPECT_AGENT=TestAgent accepted (got: '$err')" ;;
  *) pass "EXPECT_AGENT=TestAgent accepted" ;;
esac
cleanup

echo "P3: EXPECT_AGENT still accepts the lower-cased spelling"
new_env
unique_auth "$ROOT/.claude/ntfy-bus.config.json"
err=$( ( cd "$ROOT"; NTFY_HOME="$ROOT" EXPECT_AGENT="testagent" bash "$POLLER" 2>&1 >/dev/null ) ) || true
case "$err" in
  *"identity guard"*) fail "EXPECT_AGENT=testagent accepted (got: '$err')" ;;
  *) pass "EXPECT_AGENT=testagent accepted" ;;
esac
cleanup

echo "P4: EXPECT_AGENT still refuses a genuinely wrong identity (control)"
new_env
unique_auth "$ROOT/.claude/ntfy-bus.config.json"
rc=0
err=$( ( cd "$ROOT"; NTFY_HOME="$ROOT" EXPECT_AGENT="bogus" bash "$POLLER" 2>&1 >/dev/null ) ) || rc=$?
case "$err" in
  *"identity guard"*) pass "wrong identity refused" ;;
  *) fail "wrong identity refused (got: '$err')" ;;
esac
assert_eq "refusal exits non-zero" "1" "$rc"
cleanup

echo "P5: unlocked host — NTFY_POLL_REPO selects the repo-local identity"
new_env
jq '.per_repo_identity_allowed = true' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
mkdir -p "$ROOT/fakerepo/.claude"
cat > "$ROOT/fakerepo/.claude/ntfy-bus.config.json" <<JSON
{ "agent_id": "RepoAgent", "endpoint": "http://127.0.0.1:9/unused", "topic": "test-bus",
  "auth_env": { "username": "TESTBUS_POLL_USER", "password": "TESTBUS_POLL_PASS" },
  "inbox_jsonl": "$ROOT/fakerepo/.claude/ntfy-inbox.repoagent.jsonl" }
JSON
err=$( ( cd "$ROOT"; NTFY_HOME="$ROOT" NTFY_POLL_REPO="$ROOT/fakerepo" EXPECT_AGENT="RepoAgent" bash "$POLLER" 2>&1 >/dev/null ) ) || true
case "$err" in
  *"identity guard"*) fail "repo identity resolved + guard passed (got: '$err')" ;;
  *) pass "repo identity resolved + guard passed" ;;
esac
assert_contains "polled as the repo identity (its own log)" \
  "$ROOT/fakerepo/.claude/ntfy-inbox.repoagent.poll.log" "missing ntfy credentials"
cleanup

echo "P6: unlocked host — a stale NTFY_POLL_REPO stays FATAL (repo selects identity there)"
new_env
jq '.per_repo_identity_allowed = true' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
rc=0
err=$( ( cd "$ROOT"; NTFY_HOME="$ROOT" NTFY_POLL_REPO="$ROOT/renamed-away" bash "$POLLER" 2>&1 >/dev/null ) ) || rc=$?
case "$err" in
  *"repo not found"*) pass "unlocked stale repo refused" ;;
  *) fail "unlocked stale repo refused (got: '$err')" ;;
esac
assert_eq "unlocked stale repo exits non-zero" "1" "$rc"
cleanup

finish
