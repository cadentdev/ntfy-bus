#!/usr/bin/env bash
# tests/arm-hook.sh — regression tests for hooks/arm-bus-waker.sh.
#
# The hook is detect-and-prompt, READ-ONLY: silent when armed, a stdout
# directive when down, a loud line when the durable inbox is missing — and it
# must never write the pidfile (writing it is the squat that disables the
# agent's own wake-capable re-arm).
set -u
. "$(dirname "$0")/lib/harness.sh"
HOOK="$SKILL_ROOT/hooks/arm-bus-waker.sh"

run_hook() { ( export NTFY_HOME="$ROOT"; unset CLAUDE_PROJECT_DIR; cd /; bash "$HOOK" ); }

echo "A1: no config -> silent, exit 0"
new_env; rm -f "$ROOT/.claude/ntfy-bus.config.json"
out=$(run_hook); rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "no output" "" "$out"
cleanup

echo "A2: config without .inbox_jsonl -> loud OFF notice"
new_env
jq 'del(.inbox_jsonl)' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
out=$(run_hook)
case "$out" in
  *"no .inbox_jsonl"*) pass "missing key surfaced" ;;
  *) fail "missing key surfaced (got: '$out')" ;;
esac
cleanup

echo "A3: inbox path set but file missing -> capture-down notice, not a prompt"
new_env; rm -f "$INBOX"
out=$(run_hook)
case "$out" in
  *"No durable inbox"*) pass "dead capture surfaced" ;;
  *) fail "dead capture surfaced (got: '$out')" ;;
esac
cleanup

echo "A4: inbox present, waker down -> arm directive with identity + waker path"
new_env
out=$(run_hook)
case "$out" in
  *"NOT armed"*) pass "down state prompted" ;;
  *) fail "down state prompted (got: '$out')" ;;
esac
case "$out" in
  *"TestAgent"*) pass "identity named in prompt" ;;
  *) fail "identity named in prompt" ;;
esac
case "$out" in
  *"daemons/ntfy-bus-waker.sh"*) pass "waker path named in prompt" ;;
  *) fail "waker path named in prompt" ;;
esac
[ ! -f "${INBOX%.jsonl}.waker.pid" ] && pass "hook never wrote the pidfile" \
  || fail "hook never wrote the pidfile"
cleanup

echo "A5: waker armed -> hook stays silent"
new_env
# Direct launch (no subshell wrapper) so $WP is the waker itself — the armed
# check ps-matches the pid recorded in the pidfile.
NTFY_HOME="$ROOT" NTFY_WAKER_INTERVAL=1 "$SKILL_ROOT/daemons/ntfy-bus-waker.sh" TestAgent >/dev/null 2>&1 & WP=$!
sleep 2   # let the waker write its pidfile and settle into its poll loop
out=$(run_hook); rc=$?
assert_eq "silent when armed" "" "$out"
assert_eq "exit 0 when armed" "0" "$rc"
kill -TERM "$WP" 2>/dev/null; wait "$WP" 2>/dev/null
cleanup

finish
