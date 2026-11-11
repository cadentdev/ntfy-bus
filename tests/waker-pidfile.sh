#!/usr/bin/env bash
# tests/waker-pidfile.sh — regression tests for the waker pidfile contract.
#
# Issue #29: the pidfile claim must be ATOMIC. Check-then-write let two
# same-instant arms both proceed — the loser's pid was overwritten, leaving a
# live waker invisible to every pidfile reader. Concurrent arms are the session
# waker's ROUTINE traffic (SessionStart re-arms, multi-session hosts), so the
# window was hit in practice, not in theory.
#
# Issue #27: the durable daemon claims .waker.pidfile from config while the
# session waker derives <inbox>.waker.pid — two pidfiles for two different
# JOBS, by design. The status tool must see BOTH (a daemon-managed waker used
# to report NOT ARMED), and the daemon must refuse a config that points its
# pidfile at the session waker's derived path (one file, two jobs = each exit
# deletes the other's claim).
set -u
. "$(dirname "$0")/lib/harness.sh"
WAKER="$SKILL_ROOT/daemons/ntfy-bus-waker.sh"
DAEMON="$SKILL_ROOT/daemons/bus-waker-daemon.sh"
STATUS="$SKILL_ROOT/bin/ntfy-waker-status.sh"

# The daemon fail-louds on missing state paths; give the scratch config the
# full set, with the daemon pidfile distinct from the derived session one.
daemon_env() {
  new_env
  jq --arg r "$ROOT" '.waker = {
      "pidfile":  ($r + "/.claude/ntfy-bus.daemon.pid"),
      "wakelog":  ($r + "/.claude/ntfy-bus.wake.log"),
      "seen_ids": ($r + "/.claude/ntfy-bus.seen-ids")
    }' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
    && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
}

PIDFILE_OF() { printf '%s' "${INBOX%.jsonl}.waker.pid"; }

echo "W1: same-instant double arm — exactly one session waker survives (issue #29)"
new_env
NTFY_HOME="$ROOT" NTFY_WAKER_INTERVAL=60 bash "$WAKER" TestAgent > "$ROOT/a.out" 2>&1 & A=$!
NTFY_HOME="$ROOT" NTFY_WAKER_INTERVAL=60 bash "$WAKER" TestAgent > "$ROOT/b.out" 2>&1 & B=$!
sleep 3
alive=0
kill -0 "$A" 2>/dev/null && alive=$((alive+1))
kill -0 "$B" 2>/dev/null && alive=$((alive+1))
assert_eq "exactly one waker survives" "1" "$alive"
pf_pid=$(cat "$(PIDFILE_OF)" 2>/dev/null)
if kill -0 "$pf_pid" 2>/dev/null; then pass "pidfile names a live waker"
else fail "pidfile names a live waker (pidfile: '$pf_pid')"; fi
case "$pf_pid" in
  "$A"|"$B") pass "pidfile pid is one of the two arms" ;;
  *) fail "pidfile pid is one of the two arms (got '$pf_pid', arms $A/$B)" ;;
esac
kill -TERM "$A" "$B" 2>/dev/null; wait "$A" "$B" 2>/dev/null
cleanup

echo "W2: stale pidfile (dead pid) is reclaimed"
new_env
sh -c 'exit 0' & deadpid=$!
wait "$deadpid" 2>/dev/null
echo "$deadpid" > "$(PIDFILE_OF)"
NTFY_HOME="$ROOT" NTFY_WAKER_INTERVAL=60 bash "$WAKER" TestAgent > "$ROOT/a.out" 2>&1 & A=$!
sleep 2
assert_eq "waker reclaimed the stale pidfile" "$A" "$(cat "$(PIDFILE_OF)" 2>/dev/null)"
if kill -0 "$A" 2>/dev/null; then pass "waker is running"; else fail "waker is running"; fi
kill -TERM "$A" 2>/dev/null; wait "$A" 2>/dev/null
cleanup

echo "W3: second arm against a live waker exits without stacking"
new_env
NTFY_HOME="$ROOT" NTFY_WAKER_INTERVAL=60 bash "$WAKER" TestAgent > "$ROOT/a.out" 2>&1 & A=$!
sleep 2
out=$(NTFY_HOME="$ROOT" NTFY_WAKER_INTERVAL=60 bash "$WAKER" TestAgent 2>&1); rc=$?
assert_eq "second arm exits 0" "0" "$rc"
case "$out" in
  *"already armed"*) pass "second arm reports already armed" ;;
  *) fail "second arm reports already armed (got: '$out')" ;;
esac
assert_eq "pidfile still the first waker's" "$A" "$(cat "$(PIDFILE_OF)" 2>/dev/null)"
kill -TERM "$A" 2>/dev/null; wait "$A" 2>/dev/null
cleanup

# Run a daemon expected to EXIT on its own within ~5s; a regression that keeps
# it alive must fail the case, not hang the suite (the daemon otherwise runs
# forever inside a command substitution). Sets run_rc + run_out.
run_daemon_expect_exit() {
  NTFY_HOME="$ROOT" bash "$DAEMON" > "$ROOT/dx.out" 2>&1 & local p=$!
  local i=0
  while [ $i -lt 5 ] && kill -0 "$p" 2>/dev/null; do sleep 1; i=$((i+1)); done
  if kill -0 "$p" 2>/dev/null; then
    kill -TERM "$p" 2>/dev/null; wait "$p" 2>/dev/null
    run_rc=124   # sentinel: did not exit on its own
  else
    wait "$p" 2>/dev/null; run_rc=$?
  fi
  run_out=$(cat "$ROOT/dx.out" 2>/dev/null)
}

echo "W4: daemon refuses a pidfile colliding with the session waker's (issue #27)"
daemon_env
jq --arg p "$(PIDFILE_OF)" '.waker.pidfile = $p' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
run_daemon_expect_exit
assert_eq "collision is FATAL" "1" "$run_rc"
case "$run_out" in
  *"collides"*) pass "collision named in the error" ;;
  *) fail "collision named in the error (got: '$run_out')" ;;
esac
cleanup

echo "W5: status tool sees a daemon-managed waker (issue #27)"
daemon_env
NTFY_HOME="$ROOT" bash "$DAEMON" > "$ROOT/d.out" 2>&1 & D=$!
sleep 2
out=$(NTFY_HOME="$ROOT" bash "$STATUS" 2>&1)
case "$out" in
  *"durable daemon: RUNNING (pid $D"*) pass "step 1 reports the daemon" ;;
  *) fail "step 1 reports the daemon (got: '$out')" ;;
esac
case "$out" in
  *"daemon"*"$D"*"armed"*) pass "table shows the daemon row" ;;
  *) fail "table shows the daemon row (got: '$out')" ;;
esac
kill -TERM "$D" 2>/dev/null; wait "$D" 2>/dev/null
cleanup

echo "W6: second daemon against a live daemon is FATAL (double-start guard kept)"
daemon_env
NTFY_HOME="$ROOT" bash "$DAEMON" > "$ROOT/d.out" 2>&1 & D=$!
sleep 2
run_daemon_expect_exit
assert_eq "second daemon exits 1" "1" "$run_rc"
case "$run_out" in
  *"owns"*) pass "second daemon names the owner" ;;
  *) fail "second daemon names the owner (got: '$run_out')" ;;
esac
kill -TERM "$D" 2>/dev/null; wait "$D" 2>/dev/null
cleanup

echo "W9: the daemon's ledger key — empty and non-string ids are each notified once (issue #52)"
# `.id // fallback` kept an empty-string id (truthy), so every such message
# keyed as "" — first notified, the rest suppressed. A non-string id printed
# over several lines, which grep -F then matched as alternatives.
daemon_env
WL="$ROOT/.claude/ntfy-bus.wake.log"
NTFY_HOME="$ROOT" bash "$DAEMON" > "$ROOT/d.out" 2>&1 & DP=$!
sleep 2
printf '{"event":"message","id":"","time":1,"title":"Dana->TestAgent: empty one","message":"b"}\n' >> "$INBOX"
printf '{"event":"message","id":"","time":2,"title":"Dana->TestAgent: empty two","message":"b"}\n' >> "$INBOX"
printf '{"event":"message","id":{"k":1},"time":3,"title":"Dana->TestAgent: object one","message":"b"}\n' >> "$INBOX"
printf '{"event":"message","id":{"k":2},"time":4,"title":"Dana->TestAgent: object two","message":"b"}\n' >> "$INBOX"
printf '{"event":"message","id":"plain","time":5,"title":"Dana->TestAgent: plain","message":"b"}\n' >> "$INBOX"
printf '{"event":"message","id":"plain","time":5,"title":"Dana->TestAgent: plain","message":"b"}\n' >> "$INBOX"
i=0; while [ $i -lt 10 ] && [ "$(wc -l < "$WL" 2>/dev/null | tr -d ' ')" != 5 ]; do sleep 1; i=$((i+1)); done
sleep 1
kill -TERM "$DP" 2>/dev/null; wait "$DP" 2>/dev/null
assert_eq "five distinct messages logged, the replay once" "5" "$(wc -l < "$WL" 2>/dev/null | tr -d ' ')"
assert_contains "second empty-id message was not suppressed" "$WL" 'empty two'
assert_contains "second object-id message was not suppressed" "$WL" 'object two'
assert_eq "plain id is unchanged as a key" "1" "$(grep -cxF -- 'plain' "$ROOT/.claude/ntfy-bus.seen-ids")"
cleanup

finish
