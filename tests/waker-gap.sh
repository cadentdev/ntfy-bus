#!/usr/bin/env bash
# tests/waker-gap.sh — functional tests for the in-session waker's gap recovery
# and the wake behaviours it must not regress.
#
# WHY THIS EXISTS: daemons/ntfy-bus-waker.sh used to baseline to the inbox's EOF
# on every arm and keep no state between arms, so every message that landed in
# the gap between a reaper-killed waker and its re-arm was dropped from the wake
# path. The fix backs arms with an id-keyed seen-ledger. These tests reproduce
# the original drop and pin every behaviour the fix must preserve.
#
# HOW IT WORKS: each case builds a throwaway $NTFY_HOME with its own config and a
# fake inbox JSONL, arms the real waker against it, and asserts on whether a
# `WAKE:` line was emitted. No live bus, no network — the inbox is written by
# hand the way the poller would have appended it.
#
# Hermetic: the waker under test is THIS repo's copy ($SKILL_ROOT via the
# harness), and it resolves its libs self-relatively — no installed skill, no
# configured bus, no credentials. NTFY_HOME redirects the config and inbox, so
# the scratch env never touches your real inbox.
#
# USAGE:  bash tests/waker-gap.sh          # exit 0 = all pass
set -u
. "$(dirname "$0")/lib/harness.sh"

WAKER="$SKILL_ROOT/daemons/ntfy-bus-waker.sh"
export NTFY_WAKER_INTERVAL=1

# Arm the waker, capture output to $1, let it run $2 seconds, then reap it (the
# reaper's SIGTERM, which — as on macOS — leaves no termination trace).
arm() {
  "$WAKER" TestAgent > "$1" 2>&1 & local p=$!
  sleep "$2"; kill -TERM "$p" 2>/dev/null; wait "$p" 2>/dev/null
}
woke() { grep -q '^WAKE:' "$1"; }
expect() { # $1=desc $2=wake|nowake $3=outfile
  if [ "$2" = wake ]; then
    if woke "$3"; then pass "$1"
    else fail "$1 (expected a wake, got none)"; fi
  else
    if woke "$3"; then fail "$1 (expected no wake, but woke: $(grep '^WAKE:' "$3"))"
    else pass "$1"; fi
  fi
}

echo "T1: first arm does not wake on pre-existing backlog"
new_env; emit id1 "Dana->ALL: old backlog message"
arm "$ROOT/o" 2; expect "first arm suppresses backlog" nowake "$ROOT/o"; cleanup

echo "T2: message in the kill->re-arm gap IS recovered"
new_env; emit id1 "Dana->ALL: backlog"
arm "$ROOT/o1" 2
emit id2 "Dana->TestAgent: gap decision"
arm "$ROOT/o2" 3; expect "re-arm recovers gap message" wake "$ROOT/o2"; cleanup

echo "T3: no double wake — re-arm after a genuine wake does not re-fire it"
new_env; emit id1 "Dana->ALL: backlog"
arm "$ROOT/o1" 2
emit id2 "Dana->TestAgent: the one real message"
arm "$ROOT/o2" 3          # wakes on id2
arm "$ROOT/o3" 2          # id2 already seen -> silent
expect "second re-arm does not re-wake" nowake "$ROOT/o3"; cleanup

echo "T4: in-arm wake — a message arriving while armed still wakes"
new_env
"$WAKER" TestAgent > "$ROOT/o" 2>&1 & P=$!
sleep 2; emit id9 "Dana->TestAgent: live message while armed"; sleep 2
kill -TERM "$P" 2>/dev/null; wait "$P" 2>/dev/null
expect "in-arm live message wakes" wake "$ROOT/o"; cleanup

echo "T5: self-sent message does not wake (gap scan)"
new_env; emit id0 "Dana->ALL: backlog"
arm "$ROOT/o1" 2
emit id1 "TestAgent->ALL: my own message"
arm "$ROOT/o2" 3; expect "self-sent suppressed" nowake "$ROOT/o2"; cleanup

echo "T6: message addressed to someone else does not wake"
new_env; emit id0 "Dana->ALL: backlog"
arm "$ROOT/o1" 2
emit id1 "Dana->SomeoneElse: not for me"
arm "$ROOT/o2" 3; expect "non-addressed suppressed" nowake "$ROOT/o2"; cleanup

echo "T7: automation-noise sender does not wake"
new_env; emit id0 "Dana->ALL: backlog"
arm "$ROOT/o1" 2
emit id1 "cron->TestAgent: nightly job report"
arm "$ROOT/o2" 3; expect "noise sender suppressed" nowake "$ROOT/o2"; cleanup

echo "T8: gap WINDOW bound — addressed mail older than the scan window does not wake"
# NOTE: this pins the GAP_WINDOW bound, NOT the cap-trim path (the ledger holds
# only 40 ids here, far under the cap, so no trim runs). The trim path is T9.
new_env; export NTFY_WAKER_GAP_LINES=50
for i in $(seq 1 40); do emit "old-$i" "Dana->TestAgent: old $i"; done
arm "$ROOT/o1" 2                                   # all 40 marked seen (window=50)
for i in $(seq 1 200); do emit "flood-$i" "Dana->SomeoneElse: noise $i"; done
arm "$ROOT/o2" 3                                   # old ids now outside last-50 window
expect "no wake on ancient mail beyond gap window" nowake "$ROOT/o2"
unset NTFY_WAKER_GAP_LINES; cleanup

echo "T9: cap-trim path actually runs and keeps the ledger bounded (invariant held)"
# Force a real trim with tiny cap/keep, keeping SEEN_KEEP(4) > GAP_WINDOW(3) so
# the invariant holds. Drive >CAP marks via successive in-arm wakes (one id each).
# Total marks = 1 seed + 8 wakes = 9; without a trim the ledger would hold all 9.
# bus_cap_trim trims to KEEP whenever the file EXCEEDS CAP, so the steady-state
# ceiling is CAP (6), not KEEP — the file grows back toward CAP between trims.
# So the proof the trim path ran is: ledger <= CAP (6) < 9 total marks. Then
# assert no false wake results.
new_env
export NTFY_WAKER_SEEN_CAP=6 NTFY_WAKER_SEEN_KEEP=4 NTFY_WAKER_GAP_LINES=3
LEDGER="$ROOT/.claude/ntfy-inbox.testagent.wake-seen"
emit seed "Dana->ALL: backlog"
arm "$ROOT/w0" 2                                   # first arm: creates ledger
for i in $(seq 1 8); do                            # 8 genuine wakes -> 8 marks, crosses cap 6
  emit "wake-$i" "Dana->TestAgent: real $i"
  arm "$ROOT/w$i" 2
done
lines=$(wc -l < "$LEDGER" | tr -d ' ')
if [ "$lines" -le 6 ] && [ "$lines" -lt 9 ]; then
  pass "trim ran and bounded the ledger at <=CAP ($lines lines, 9 marks issued)"
else
  fail "ledger not bounded by CAP (found $lines lines; expected <=6 and <9)"
fi
arm "$ROOT/wf" 2                                    # nothing new -> must not false-wake
expect "no false wake after a real trim" nowake "$ROOT/wf"
unset NTFY_WAKER_SEEN_CAP NTFY_WAKER_SEEN_KEEP NTFY_WAKER_GAP_LINES; cleanup

finish
