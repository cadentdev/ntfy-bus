#!/usr/bin/env bash
# tests/waker-argv.sh — a running session waker says whose it is (issue #45).
#
# Every identity on a shared-$HOME host used to run the byte-identical command
# line, so `ps`/`pgrep` showed "a waker" without saying whose. Twice an agent
# saw another identity's waker, concluded its own was armed, and sat silently
# unarmed. The waker now re-execs itself with the resolved identity as $1, so
# the process list answers the question people actually ask.
set -u
. "$(dirname "$0")/lib/harness.sh"
WAKER="$SKILL_ROOT/daemons/ntfy-bus-waker.sh"
export NTFY_WAKER_INTERVAL=1
unset NTFY_WAKER_IDENTITY CLAUDE_PROJECT_DIR NTFY_DAEMON_CONTEXT

cmd_of() { ps -p "$1" -o command= 2>/dev/null; }
reap() { kill -TERM "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
# start OUT [ARGS...] — launch from the scratch root (no identity in cwd beyond
# the config), leave the pid in $P.
start() {
  local out="$1"; shift
  ( cd "$ROOT" && exec bash "$WAKER" "$@" ) > "$out" 2>&1 & P=$!
  sleep 2
}

echo "V1: launched with no argument, the process names its identity"
new_env; start "$ROOT/o"
c=$(cmd_of "$P")
case "$c" in
  *"ntfy-bus-waker.sh TestAgent") pass "argv ends with the resolved identity" ;;
  *) fail "argv ends with the resolved identity (got: '$c')" ;;
esac
assert_eq "same pid after the re-exec (harness tracking survives)" "$P" "$(cat "${INBOX%.jsonl}.waker.pid" 2>/dev/null)"
assert_contains "it armed as that identity" "$ROOT/o" '^armed: identity=TestAgent '
assert_eq "armed exactly once (no double start)" "1" "$(grep -c '^armed:' "$ROOT/o")"
reap "$P"
assert_false "pidfile released on exit" test -f "${INBOX%.jsonl}.waker.pid"
cleanup

echo "V2: identity from \$NTFY_WAKER_IDENTITY also lands in argv"
new_env
( cd "$ROOT" && NTFY_WAKER_IDENTITY=EnvAgent exec bash "$WAKER" ) > "$ROOT/o" 2>&1 & P=$!
sleep 2
c=$(cmd_of "$P")
case "$c" in
  *"ntfy-bus-waker.sh EnvAgent") pass "argv carries the env identity" ;;
  *) fail "argv carries the env identity (got: '$c')" ;;
esac
assert_contains "it armed as that identity" "$ROOT/o" '^armed: identity=EnvAgent '
reap "$P"; cleanup

echo "V3: an explicit argument is left exactly as given"
new_env; start "$ROOT/o" TestAgent
c=$(cmd_of "$P")
case "$c" in
  *"ntfy-bus-waker.sh TestAgent") pass "argv unchanged" ;;
  *) fail "argv unchanged (got: '$c')" ;;
esac
assert_eq "armed once" "1" "$(grep -c '^armed:' "$ROOT/o")"
reap "$P"; cleanup

echo "V4: two identities on one host can be told apart from the process list"
new_env; ROOT_A="$ROOT"; start "$ROOT_A/o"; PA=$P
jq '.agent_id = "OtherAgent" | .recipient_filters = ["OtherAgent","ALL"]' \
  "$ROOT_A/.claude/ntfy-bus.config.json" > "$ROOT_A/other.json"
ROOT_B=$(mktemp -d "${TMPDIR:-/tmp}/ntfy-bus-test.XXXXXX"); mkdir -p "$ROOT_B/.claude"
jq --arg i "$ROOT_B/.claude/ntfy-inbox.otheragent.jsonl" '.inbox_jsonl = $i' \
  "$ROOT_A/other.json" > "$ROOT_B/.claude/ntfy-bus.config.json"
: > "$ROOT_B/.claude/ntfy-inbox.otheragent.jsonl"
( cd "$ROOT_B" && NTFY_HOME="$ROOT_B" exec bash "$WAKER" ) > "$ROOT_B/o" 2>&1 & PB=$!
sleep 2
mine=$(pgrep -f "ntfy-bus-waker.sh TestAgent$" | tr '\n' ' ')
theirs=$(pgrep -f "ntfy-bus-waker.sh OtherAgent$" | tr '\n' ' ')
case " $mine " in *" $PA "*) pass "pgrep for my identity finds my waker" ;; *) fail "pgrep for my identity finds my waker (got: '$mine')" ;; esac
case " $mine " in *" $PB "*) fail "pgrep for my identity must not find the other waker" ;; *) pass "pgrep for my identity does not find the other waker" ;; esac
case " $theirs " in *" $PB "*) pass "pgrep for the other identity finds theirs" ;; *) fail "pgrep for the other identity finds theirs (got: '$theirs')" ;; esac
reap "$PA"; reap "$PB"; rm -rf "$ROOT_B"; cleanup

echo "V5: the no-argument launch still wakes, and a second one does not stack"
new_env; emit id0 "Dana->ALL: backlog"
start "$ROOT/o"; P1=$P
( cd "$ROOT" && exec bash "$WAKER" ) > "$ROOT/o2" 2>&1 & P2=$!
sleep 2
assert_contains "second launch defers to the first" "$ROOT/o2" "already armed for TestAgent \(pid $P1\)"
assert_false "second launch exited" kill -0 "$P2"
emit live1 "Dana->TestAgent: live after re-exec"
sleep 3
assert_contains "first launch woke on live mail" "$ROOT/o" '^WAKE: 1 message \(0 backlog, 1 new\)'
assert_false "first launch exited on the wake" kill -0 "$P1"
wait "$P1" 2>/dev/null; assert_eq "wake exit code is 0" "0" "$?"
cleanup

echo "V6: a failure before the re-exec is still loud, and nothing loops"
new_env; rm -f "$ROOT/.claude/ntfy-bus.config.json"
out=$( ( cd "$ROOT" && bash "$WAKER" ) 2>&1 ); rc=$?
assert_eq "no config: exits 1" "1" "$rc"
case "$out" in *"FATAL"*) pass "no config: says FATAL" ;; *) fail "no config: says FATAL (got: '$out')" ;; esac
cleanup

finish
