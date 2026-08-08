#!/usr/bin/env bash
# tests/routing.sh — regression tests for lib/routing.sh.
#
# The matcher is the nervous system: every consumer (CheckInbox, Watch, both
# wakers) sources these jq defs. Each case runs a title through addressed_to /
# msg_sender exactly the way consumers do.
set -u
. "$(dirname "$0")/lib/harness.sh"
. "$SKILL_ROOT/lib/routing.sh"

# routes TITLE FILTERS -> exit 0 if addressed_to matches
routes() {
  printf '{"title":"%s"}\n' "$1" \
    | jq -e "$BUS_ROUTING_DEFS"' addressed_to("'"$2"'")' >/dev/null
}
sender_of() {
  printf '{"title":"%s"}\n' "$1" | jq -r "$BUS_ROUTING_DEFS"' msg_sender'
}

echo "R1: canonical pointer routes"
assert_true  "A→B: hits filter B"                routes "Alice→Bob: hello" "Bob|ALL"
assert_false "A→B: misses filter C"              routes "Alice→Bob: hello" "Carol|ALL"

echo "R2: every tolerated pointer variant routes"
assert_true  "emoji arrow ➡️"                    routes "Alice➡️Bob: hi" "Bob|ALL"
assert_true  "bare arrow ➡"                      routes "Alice➡Bob: hi" "Bob|ALL"
assert_true  "pointing finger 👉"                routes "Alice👉Bob: hi" "Bob|ALL"
assert_true  "ASCII ->"                          routes "Alice->Bob: hi" "Bob|ALL"

echo "R3: broadcast + group titles"
assert_true  "ALL broadcast"                     routes "Alice→ALL: scope change" "Bob|ALL"
assert_true  "group 'X & Y' matches Y"           routes "Alice→Bob & Carol: sync" "Carol|ALL"
assert_true  "group 'X, Y' matches Y"            routes "Alice→Bob, Carol: sync" "Carol|ALL"
assert_true  "group 'X & Y' matches X"           routes "Alice→Bob & Carol: sync" "Bob|ALL"

echo "R4: token boundary — substrings must not route"
assert_false "BOBBY does not hit filter BOB"     routes "Alice→BOBBY: hi" "BOB|ALL"
assert_false "recipient BOB not hit by BO"       routes "Alice→BOB: hi" "BO"

echo "R5: header scoping — pointer in the SUBJECT must not route"
assert_false "-> in subject only"                routes "status: a->Bob deploy" "Bob"
assert_false "no pointer at all"                 routes "Bob: just a mention" "Bob"

echo "R6: msg_sender extraction"
assert_eq "sender lowercased"        "alice" "$(sender_of 'Alice→Bob: hi')"
assert_eq "sender trimmed"           "alice" "$(sender_of ' Alice ➡️Bob: hi')"
assert_eq "ASCII pointer sender"     "alice" "$(sender_of 'Alice->Bob: hi')"

echo "R7: ' to ' pointer variant routes"
assert_true  "'Alice to Bob:' routes"            routes "Alice to Bob: hi" "Bob|ALL"
assert_true  "'Alice to ALL:' broadcasts"        routes "Alice to ALL: scope change" "Bob|ALL"
assert_true  "'Alice To Bob:' routes (case)"     routes "Alice To Bob: hi" "Bob|ALL"
assert_true  "'Alice TO Bob:' routes (case)"     routes "Alice TO Bob: hi" "Bob|ALL"
assert_true  "group 'Dana to Bob & Carol:' hits Carol" routes "Dana to Bob & Carol: sync" "Carol|ALL"
assert_true  "group 'Dana to Bob & Carol:' hits Bob" routes "Dana to Bob & Carol: sync" "Bob|ALL"
assert_eq    "' to ' sender extracted"           "alice" "$(sender_of 'Alice to Bob: hi')"

echo "R8: ' to ' space delimiters are load-bearing"
assert_false "'Aliceto Bob:' does not route"     routes "Aliceto Bob: hi" "Bob|ALL"
assert_false "'Alice toBob:' does not route"     routes "Alice toBob: hi" "Bob|ALL"
assert_true  "sender Toby unaffected by ' to '"  routes "Toby→Alice: hi" "Alice|ALL"
assert_eq    "msg_sender of Toby stays toby"     "toby" "$(sender_of 'Toby→Alice: hi')"

echo "R9: ' to ' header scoping — subject-only ' to ' must not route"
assert_false "' to ' in subject only"            routes "Dana: how to deploy" "deploy"

echo "R10: accepted false positive pinned — plain-English header DOES route"
assert_true  "'reply to Bob: draft' routes"      routes "reply to Bob: draft attached" "Bob|ALL"
assert_eq    "its sender is 'reply'"             "reply" "$(sender_of 'reply to Bob: draft attached')"

echo "R11: chained ' to ' folds — first pointer wins for sender, any recipient matches"
assert_true  "'Alice to Bob to Carol:' hits Carol" routes "Alice to Bob to Carol: hi" "Carol|ALL"
assert_eq    "chained sender is alice"           "alice" "$(sender_of 'Alice to Bob to Carol: hi')"

finish
