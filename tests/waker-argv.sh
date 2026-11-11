#!/usr/bin/env bash
# tests/waker-argv.sh — a running session waker says whose it is (issue #45).
#
# Every identity on a shared-$HOME host used to run the byte-identical command
# line, so `ps`/`pgrep` showed "a waker" without saying whose. Twice an agent
# saw another identity's waker, concluded its own was armed, and sat silently
# unarmed. The waker now re-execs itself with its config's identity as $1, and
# refuses to start under any other name, so the process list tells the truth.
set -u
. "$(dirname "$0")/lib/harness.sh"
WAKER="$SKILL_ROOT/daemons/ntfy-bus-waker.sh"
export NTFY_WAKER_INTERVAL=1
unset NTFY_WAKER_IDENTITY CLAUDE_PROJECT_DIR NTFY_DAEMON_CONTEXT

cmd_of() { ps -p "$1" -o command= 2>/dev/null; }
reap() { kill -TERM "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
# Never leave a scratch waker behind, even when a case fails half way: every
# pid this suite starts is recorded and signalled on exit — by pid, never by
# name (real wakers on a developer machine share the script name).
STARTED=""
trap 'for p in $STARTED; do kill -TERM "$p" 2>/dev/null; done' EXIT
# start OUT [ARGS...] — launch from the scratch root, leave the pid in $P.
start() {
  local out="$1"; shift
  ( cd "$ROOT" && exec bash "$WAKER" "$@" ) > "$out" 2>&1 & P=$!
  STARTED="$STARTED $P"
  sleep 2
}
# Run a launch that must EXIT on its own. A regression that lets it arm must
# fail the case, not hang the suite inside a command substitution. Sets rc
# (124 = it did not exit) and out.
expect_exit() { # [VAR=val...] -- [ARGS...]
  local envs="" p i=0
  while [ "$1" != "--" ]; do envs="$envs $1"; shift; done; shift
  ( cd "$ROOT" && exec env $envs bash "$WAKER" "$@" ) > "$ROOT/x.out" 2>&1 & p=$!
  STARTED="$STARTED $p"
  while [ $i -lt 5 ] && kill -0 "$p" 2>/dev/null; do sleep 1; i=$((i+1)); done
  if kill -0 "$p" 2>/dev/null; then reap "$p"; rc=124; else wait "$p" 2>/dev/null; rc=$?; fi
  out=$(cat "$ROOT/x.out" 2>/dev/null)
}
argv_ends() { # DESC PID WANT
  local c; c=$(cmd_of "$2")
  case "$c" in
    *"ntfy-bus-waker.sh $3") pass "$1" ;;
    *) fail "$1 (got: '$c')" ;;
  esac
}

echo "V1: launched with no argument, the process names its identity"
new_env; start "$ROOT/o"
argv_ends "argv ends with the resolved identity" "$P" TestAgent
assert_eq "same pid after the re-exec (harness tracking survives)" "$P" "$(cat "${INBOX%.jsonl}.waker.pid" 2>/dev/null)"
assert_contains "it armed as that identity" "$ROOT/o" '^armed: identity=TestAgent '
assert_eq "armed exactly once (no double start)" "1" "$(grep -c '^armed:' "$ROOT/o")"
reap "$P"
assert_false "pidfile released on exit" test -f "${INBOX%.jsonl}.waker.pid"
cleanup

echo "V2: a name that disagrees with the config is refused, not relabelled"
# The inbox and filters come from the config. Started as someone else, the
# waker would watch TestAgent's inbox while its command line vouched for the
# other name — the #45 false positive with a documented command behind it.
new_env
expect_exit -- WrongAgent
assert_eq "explicit wrong name: exits 1" "1" "$rc"
case "$out" in *"FATAL"*"WrongAgent"*"TestAgent"*) pass "explicit wrong name: FATAL names both" ;; *) fail "explicit wrong name: FATAL names both (got: '$out')" ;; esac
expect_exit NTFY_WAKER_IDENTITY=EnvAgent --
assert_eq "env wrong name: exits 1" "1" "$rc"
case "$out" in *"FATAL"*"EnvAgent"*) pass "env wrong name: FATAL" ;; *) fail "env wrong name: FATAL (got: '$out')" ;; esac
assert_false "a refused launch claims no pidfile" test -f "${INBOX%.jsonl}.waker.pid"
cleanup

echo "V2b: the same name in another letter case is accepted, shown as the config spells it"
new_env; start "$ROOT/o" testagent
argv_ends "argv carries the config's spelling" "$P" TestAgent
assert_contains "armed under the canonical name" "$ROOT/o" '^armed: identity=TestAgent '
reap "$P"; cleanup

echo "V2c: a config with no agent_id still takes the given name (pre-backfill)"
new_env
jq 'del(.agent_id)' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
start "$ROOT/o" LegacyName
argv_ends "given name used as-is" "$P" LegacyName
reap "$P"; cleanup

echo "V3: an explicit, matching argument is left exactly as given"
new_env; start "$ROOT/o" TestAgent
argv_ends "argv unchanged" "$P" TestAgent
assert_eq "armed once" "1" "$(grep -c '^armed:' "$ROOT/o")"
reap "$P"; cleanup

echo "V4: two identities on one host can be told apart from the process list"
new_env; ROOT_A="$ROOT"; start "$ROOT_A/o"; PA=$P
ROOT_B=$(mktemp -d "${TMPDIR:-/tmp}/ntfy-bus-test.XXXXXX"); mkdir -p "$ROOT_B/.claude"
jq --arg i "$ROOT_B/.claude/ntfy-inbox.otheragent.jsonl" \
  '.agent_id = "OtherAgent" | .recipient_filters = ["OtherAgent","ALL"] | .inbox_jsonl = $i' \
  "$ROOT_A/.claude/ntfy-bus.config.json" > "$ROOT_B/.claude/ntfy-bus.config.json"
: > "$ROOT_B/.claude/ntfy-inbox.otheragent.jsonl"
( cd "$ROOT_B" && NTFY_HOME="$ROOT_B" exec bash "$WAKER" ) > "$ROOT_B/o" 2>&1 & PB=$!
STARTED="$STARTED $PB"
sleep 2
# The exact form the arm prompt and README give.
whose() { ps -ax -o pid=,command= | grep "ntfy-bus-waker.sh $1\$" | awk '{print $1}' | tr '\n' ' '; }
mine=$(whose TestAgent); theirs=$(whose OtherAgent)
case " $mine " in *" $PA "*) pass "the documented ps line finds my waker" ;; *) fail "the documented ps line finds my waker (got: '$mine')" ;; esac
case " $mine " in *" $PB "*) fail "my identity must not match the other waker" ;; *) pass "my identity does not match the other waker" ;; esac
case " $theirs " in *" $PB "*) pass "the other identity finds theirs" ;; *) fail "the other identity finds theirs (got: '$theirs')" ;; esac
case " $theirs " in *" $PA "*) fail "the other identity must not match mine" ;; *) pass "the other identity does not match mine" ;; esac
reap "$PA"; reap "$PB"; rm -rf "$ROOT_B"; cleanup

echo "V5: the no-argument launch still wakes, and a second one does not stack"
new_env; emit id0 "Dana->ALL: backlog"
start "$ROOT/o"; P1=$P
( cd "$ROOT" && exec bash "$WAKER" ) > "$ROOT/o2" 2>&1 & P2=$!
STARTED="$STARTED $P2"
sleep 2
assert_contains "second launch defers to the first" "$ROOT/o2" "already armed for TestAgent \(pid $P1\)"
assert_false "second launch exited" kill -0 "$P2"
emit live1 "Dana->TestAgent: live after re-exec"
sleep 3
assert_contains "first launch woke on live mail" "$ROOT/o" '^WAKE: 1 message \(0 backlog, 1 new\)'
assert_false "first launch exited on the wake" kill -0 "$P1"
wait "$P1" 2>/dev/null; assert_eq "wake exit code is 0" "0" "$?"
cleanup

echo "V6: a failure before the re-exec is still loud"
new_env; rm -f "$ROOT/.claude/ntfy-bus.config.json"
expect_exit --
assert_eq "no config: exits 1" "1" "$rc"
case "$out" in *"FATAL"*) pass "no config: says FATAL" ;; *) fail "no config: says FATAL (got: '$out')" ;; esac
cleanup

echo "V7: nothing loops — odd launches arm exactly once and stay up"
for arg in EMPTY NONE; do
  new_env
  if [ "$arg" = EMPTY ]; then start "$ROOT/o" ""; else start "$ROOT/o"; fi
  assert_true "launch ($arg): alive" kill -0 "$P"
  assert_eq "launch ($arg): armed exactly once" "1" "$(grep -c '^armed:' "$ROOT/o")"
  argv_ends "launch ($arg): argv settled on the identity" "$P" TestAgent
  reap "$P"; cleanup
done

echo "V8: sourced instead of run, it does not exec the caller's shell"
# Sourced, $0 is the calling shell. exec'ing that ran the wrong program; with a
# login shell's "-bash" it exited 0 in silence, which a harness reads as a wake.
new_env
# `shift` first: a sourced script sees the caller's positional parameters, and
# the waker would read its own path as the identity argument.
( cd "$ROOT" && exec bash -c 'w=$1; shift; . "$w"' wrapper-name "$WAKER" ) > "$ROOT/o" 2>&1 & P=$!
STARTED="$STARTED $P"
sleep 2
assert_true "still running (it armed instead of exec'ing wrapper-name)" kill -0 "$P"
assert_contains "armed as the config identity" "$ROOT/o" '^armed: identity=TestAgent '
reap "$P"; cleanup

finish
