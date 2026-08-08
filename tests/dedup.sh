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

finish
