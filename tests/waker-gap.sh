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

# --- drain, don't single-step (issues #44, #49) ---
# One arm used to retire exactly ONE addressed-unseen message. Against stale
# backlog that cost one agent turn per message (#44); against a live sender,
# arrivals outpaced arms and the remainder stayed queued and silent (#49).
# These pin the fix: one arm retires EVERYTHING addressed and unseen, wakes
# once, and says how many.
LEDGER_REL=".claude/ntfy-inbox.testagent.wake-seen"
summary() { grep -m1 '^WAKE:' "$1"; }
in_ledger() { grep -qxF "$1" "$ROOT/$LEDGER_REL"; }

echo "T10: re-arm drains the WHOLE backlog in one wake (#44/#49)"
new_env; emit id0 "Dana->ALL: backlog"
arm "$ROOT/o1" 2                                   # first arm: creates ledger
emit g1 "Dana->TestAgent: gap one"
emit g2 "Dana->SomeoneElse: not mine"
emit g3 "Dana->ALL: gap two"
emit g4 "Dana->TestAgent: gap three"
arm "$ROOT/o2" 3
assert_eq "one summary line counts all three" \
  "WAKE: 3 messages (3 backlog, 0 new)" "$(summary "$ROOT/o2")"
assert_eq "exactly one WAKE line per arm" "1" "$(grep -c '^WAKE:' "$ROOT/o2")"
assert_contains "title 1 listed" "$ROOT/o2" 'Dana->TestAgent: gap one'
assert_contains "title 2 listed" "$ROOT/o2" 'Dana->ALL: gap two'
assert_contains "title 3 listed" "$ROOT/o2" 'Dana->TestAgent: gap three'
assert_false "non-addressed message not listed" grep -q 'not mine' "$ROOT/o2"
assert_true "g1 in ledger" in_ledger g1
assert_true "g3 in ledger" in_ledger g3
assert_true "g4 in ledger" in_ledger g4
arm "$ROOT/o3" 2
expect "next arm is silent — nothing left queued" nowake "$ROOT/o3"
assert_contains "next arm stays armed (reached the live loop)" "$ROOT/o3" 'arm=rearm'
cleanup

echo "T11: a single message still reports a count (singular)"
new_env; emit id0 "Dana->ALL: backlog"
arm "$ROOT/o1" 2
emit g1 "Dana->TestAgent: the only one"
arm "$ROOT/o2" 3
assert_eq "singular summary" "WAKE: 1 message (1 backlog, 0 new)" "$(summary "$ROOT/o2")"
assert_contains "its title is listed" "$ROOT/o2" 'Dana->TestAgent: the only one'
cleanup

echo "T12: in-arm burst — everything that landed in one interval wakes ONCE, as new"
new_env
"$WAKER" TestAgent > "$ROOT/o" 2>&1 & P=$!
sleep 2
# One write, so both lines land inside the same poll interval deterministically.
INBOX_REAL="$INBOX"; INBOX="$ROOT/burst"; : > "$INBOX"
emit b1 "Dana->TestAgent: burst one"; emit b2 "Dana->ALL: burst two"
INBOX="$INBOX_REAL"; cat "$ROOT/burst" >> "$INBOX"
sleep 3; kill -TERM "$P" 2>/dev/null; wait "$P" 2>/dev/null
assert_eq "burst summary" "WAKE: 2 messages (0 backlog, 2 new)" "$(summary "$ROOT/o")"
assert_contains "burst title 1" "$ROOT/o" 'Dana->TestAgent: burst one'
assert_contains "burst title 2" "$ROOT/o" 'Dana->ALL: burst two'
assert_true "b1 in ledger" in_ledger b1
assert_true "b2 in ledger" in_ledger b2
cleanup

echo "T13: a long backlog lists only the newest titles, but retires all of it"
new_env; export NTFY_WAKER_LIST_MAX=2
emit id0 "Dana->ALL: backlog"
arm "$ROOT/o1" 2
for i in 1 2 3 4 5; do emit "m$i" "Dana->TestAgent: msg $i"; done
arm "$ROOT/o2" 3
assert_eq "summary counts all five" "WAKE: 5 messages (5 backlog, 0 new)" "$(summary "$ROOT/o2")"
assert_contains "newest listed" "$ROOT/o2" 'Dana->TestAgent: msg 5'
assert_contains "second newest listed" "$ROOT/o2" 'Dana->TestAgent: msg 4'
assert_false "older ones not listed" grep -q 'msg [123]$' "$ROOT/o2"
assert_contains "says how many were left off" "$ROOT/o2" '3 older'
for i in 1 2 3 4 5; do assert_true "m$i in ledger" in_ledger "m$i"; done
arm "$ROOT/o3" 2
expect "unlisted messages do not re-wake" nowake "$ROOT/o3"
unset NTFY_WAKER_LIST_MAX; cleanup

echo "T14: a message captured twice (same id) counts once"
new_env; emit id0 "Dana->ALL: backlog"
arm "$ROOT/o1" 2
emit dup "Dana->TestAgent: delivered twice"
emit dup "Dana->TestAgent: delivered twice"
arm "$ROOT/o2" 3
assert_eq "duplicate id counted once" "WAKE: 1 message (1 backlog, 0 new)" "$(summary "$ROOT/o2")"
cleanup

echo "T15: backlog lines carry the message date, so stale mail is recognisable"
new_env; emit id0 "Dana->ALL: backlog"
arm "$ROOT/o1" 2
printf '{"event":"message","id":"old1","time":1756155600,"title":"Dana->TestAgent: from last year","message":"b"}\n' >> "$INBOX"
arm "$ROOT/o2" 3
assert_contains "date shown beside the title" "$ROOT/o2" '\[2025-08-25\] Dana->TestAgent: from last year'
cleanup

finish
