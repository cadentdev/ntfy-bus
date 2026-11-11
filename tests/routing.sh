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

# --- inbox_objects / msg_key (issue #52) ---
objs() { printf '%s\n' "$@" | jq -R -c "$BUS_ROUTING_DEFS"' inbox_objects | .id'; }
key_of() { printf '%s\n' "$1" | jq -r "$BUS_ROUTING_DEFS"' msg_key'; }

echo "R20: inbox_objects — a bad line costs only itself"
assert_eq "clean lines pass through" '"a""b"' "$(objs '{"id":"a"}' '{"id":"b"}' | tr -d '\n')"
assert_eq "a truncated line is skipped, later lines kept" '"a""c"' \
  "$(objs '{"id":"a"}' '{"id":"b","tit' '{"id":"c"}' | tr -d '\n')"
assert_eq "non-objects and blanks are dropped" '"z"' \
  "$(objs '42' '"s"' '[1]' 'null' 'true' '' '   ' 'not json' '{"id":"z"}' | tr -d '\n')"
assert_eq "trailing CR is tolerated" '"cr"' "$(objs "$(printf '{"id":"cr"}\r')" | tr -d '\n')"

echo "R21: inbox_objects — objects glued on one line are all recovered"
assert_eq "two glued" '"a""b"' "$(objs '{"id":"a"}{"id":"b"}' | tr -d '\n')"
assert_eq "three glued" '"a""b""c"' "$(objs '{"id":"a"}{"id":"b"}{"id":"c"}' | tr -d '\n')"
assert_eq "a valid object containing }{ in a string is ONE object" '"x"' \
  "$(objs '{"id":"x","title":"a}{b"}' | tr -d '\n')"
assert_eq "glued onto a torn fragment: nothing invented" '"after"' \
  "$(objs '{"id":"t1","time":17{"id":"t2"}' '{"id":"after"}' | tr -d '\n')"

echo "R22: msg_key — one line, one field, never the literal null for a missing id"
assert_eq "string id is itself"        "abc"      "$(key_of '{"id":"abc","time":5,"title":"T"}')"
assert_eq "missing id -> time:title"   "5:T"      "$(key_of '{"time":5,"title":"T"}')"
assert_eq "null id -> time:title"      "5:T"      "$(key_of '{"id":null,"time":5,"title":"T"}')"
assert_eq "empty id -> time:title"     "5:T"      "$(key_of '{"id":"","time":5,"title":"T"}')"
assert_eq "no time -> received"        "9:T"      "$(key_of '{"received":9,"title":"T"}')"
assert_eq "object id stays one line"   '{"k":1}'  "$(key_of '{"id":{"k":1},"title":"T"}')"
assert_eq "numeric id is its text"     "0"        "$(key_of '{"id":0,"title":"T"}')"
assert_eq "false id is its text"       "false"    "$(key_of '{"id":false,"title":"T"}')"
assert_eq "newline/tab in an id fold to a space" "a b c" "$(key_of '{"id":"a\nb\tc"}')"
assert_eq "key is always exactly one line" "1" \
  "$(key_of '{"id":{"k":[1,2]},"title":"x\ny"}' | wc -l | tr -d ' ')"

finish
