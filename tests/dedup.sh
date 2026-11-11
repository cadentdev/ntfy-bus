#!/usr/bin/env bash
# tests/dedup.sh — regression tests for lib/dedup.sh.
#
# Pure and cheap: the id-keyed seen-ledger the waker's gap recovery rides on.
set -u
. "$(dirname "$0")/lib/harness.sh"
. "$SKILL_ROOT/lib/dedup.sh"

L=$(mktemp "${TMPDIR:-/tmp}/dedup-test.XXXXXX")
trap 'rm -f "$L" "$L.tmp"' EXIT

echo "D1: seen/mark basics"
assert_false "unseen id misses"                bus_seen "id-1" "$L"
bus_mark_seen "id-1" "$L"
assert_true  "marked id hits"                  bus_seen "id-1" "$L"
assert_false "other id still misses"           bus_seen "id-2" "$L"
assert_false "substring id does not hit"       bus_seen "id-" "$L"

echo "D2: re-mark stays seen (at-most-once holds)"
bus_mark_seen "id-1" "$L"
assert_true  "still seen after re-mark"        bus_seen "id-1" "$L"

echo "D3: missing ledger file"
assert_false "seen on nonexistent file is false" bus_seen "id-1" "$L.absent"

echo "D4: cap-trim boundary — n > cap trims to keep, n == cap does not"
: > "$L"; for i in $(seq 1 5); do printf 'id-%s\n' "$i" >> "$L"; done
bus_cap_trim "$L" 5 3
assert_eq "at cap: untouched" "5" "$(wc -l < "$L" | tr -d ' ')"
printf 'id-6\n' >> "$L"
bus_cap_trim "$L" 5 3
assert_eq "over cap: trimmed to keep" "3" "$(wc -l < "$L" | tr -d ' ')"
assert_true  "newest ids survive the trim"     bus_seen "id-6" "$L"
assert_false "oldest ids trimmed away"         bus_seen "id-1" "$L"

echo "D5: mark_seen enforces its cap"
: > "$L"; for i in $(seq 1 6); do bus_mark_seen "cap-$i" "$L" 5 3; done
assert_eq "ledger bounded after marks" "3" "$(wc -l < "$L" | tr -d ' ')"

echo "D6: an id that looks like a grep option is still an id (issue #52)"
# stdin is /dev/null on purpose: unfixed, `grep -qxF -e FILE` takes FILE as
# the pattern and reads stdin — in the waker that swallows the rest of the
# scan; here it would hang the suite.
seen() { bus_seen "$@" < /dev/null; }
: > "$L"
assert_false "unseen '-c4' misses"             seen "-c4" "$L"
bus_mark_seen "-c4" "$L"
bus_mark_seen "--help" "$L"
bus_mark_seen "-e" "$L"
assert_true  "'-c4' hits once marked"          seen "-c4" "$L"
assert_true  "'--help' hits once marked"       seen "--help" "$L"
assert_true  "'-e' hits once marked"           seen "-e" "$L"
assert_false "'-c' (a prefix) does not hit"    seen "-c" "$L"
assert_false "'-v' does not invert into a hit" seen "-v" "$L"
assert_eq "bus_seen prints nothing for an option-like id" "" "$(seen "--help" "$L" 2>&1)"
assert_eq "bus_seen leaves its caller's stdin alone" "rest" "$(printf 'rest\n' | { bus_seen "-e" "$L"; cat; })"

finish
