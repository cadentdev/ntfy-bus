# Canonical bus routing matcher — SINGLE SOURCE OF TRUTH.
#
# Source this file, then put $BUS_ROUTING_DEFS at the FRONT of a jq program and use:
#   addressed_to($filters)  -> true if the title routes to any recipient in the
#                              pipe-joined $filters string (e.g. "Bob|ALL").
#   msg_sender              -> normalized lowercased sender token (text before first →).
#   inbox_objects           -> the message object(s) on ONE inbox line. Run jq
#                              with -R (each line arrives as a string) and start
#                              the program with it. See "Reading an inbox".
#   msg_key                 -> the dedup key for a message: its .id, or
#                              "time:title" when the id is missing or empty.
#
# Properties (the reasons this is shared, not duplicated):
#   - Pointer-agnostic: senders type the pointer as → ➡️ ➡ 👉 ASCII "->" or the
#     word " to " (space-delimited, case-insensitive); all are folded to →
#     (fold ➡️/VS16 BEFORE bare ➡ or a stray variation selector lands between →
#     and the recipient and breaks the match). The spaces around " to " are
#     load-bearing: they keep names like Toby or auto from splitting mid-word.
#     ACCEPTED FALSE POSITIVE (deliberate — do not "fix"): plain-English
#     headers like "reply to Bob: draft" now route (sender "reply" → Bob).
#     The bus is private and the Title convention is the contract.
#   - Header-scoped: only the routing header (before the first colon) is tested, so a
#     "->" appearing in the SUBJECT cannot false-match.
#   - Token recipient: the recipient is matched as a \b-bounded token (not "→FILTER:"),
#     so group/multi-recipient titles like "Dana→Alice & Bob:" / "Dana→Bob, Alice:" match,
#     and substrings (BOBBY ≠ BOB) do not.
#
# Reading an inbox (issue #52): never hand an inbox FILE to a bare jq. jq stops
# at the first line it cannot parse, and every message after it is silently
# gone. Use `jq -R ... 'inbox_objects | ...'`: one line at a time, a line that
# is not JSON is skipped and costs only itself. Two objects glued on one line
# ("{...}{...}", what an append after a write with no trailing newline leaves)
# are both recovered. Anything that is not an object is dropped.
#
# msg_key is the ONE ledger key (lib/dedup.sh) for both wakers. A missing or
# empty .id falls back to "time:title": two id-less messages with the same
# second AND title are one message to the ledger. ntfy always sets .id, so
# the fallback is a floor, not a guarantee. Tab/newline/US are folded to a
# space so a key is always one line and one field.
#
# Consumers: ntfy-bus skill CheckInbox/Watch, both wakers, and any fleet-side
# monitors. Change the matcher HERE and every consumer inherits it.
BUS_ROUTING_DEFS='
def normalize_pointer: gsub("➡️";"→") | gsub("➡";"→") | gsub("👉";"→") | gsub("->";"→") | gsub(" to ";"→";"i");
def routing_header: ((.title // "") | split(":")[0] | normalize_pointer);
def addressed_to($filters): (routing_header | test("→.*\\b(" + $filters + ")\\b"));
def msg_sender: (routing_header | split("→")[0] | gsub("^\\s+|\\s+$";"") | ascii_downcase);
def inbox_objects:
  . as $l
  | [$l | fromjson?] as $whole
  | (if ($whole | length) > 0 then $whole[]
     else ($l | split("}{")) as $p
       | ($p | length) as $n
       | if $n < 2 then empty
         else range(0; $n) as $i
           | ((if $i > 0 then "{" else "" end) + $p[$i] + (if $i < $n - 1 then "}" else "" end))
           | fromjson?
         end
     end)
  | select(type == "object");
def msg_key:
  ((.id | if . == null or . == "" then null else tostring end)
   // ((.time // .received // 0 | tostring) + ":" + (.title // "" | tostring)))
  | gsub("[\t\n\r\u001f]"; " ");
'
