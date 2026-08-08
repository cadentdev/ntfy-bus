# Canonical bus routing matcher — SINGLE SOURCE OF TRUTH.
#
# Source this file, then put $BUS_ROUTING_DEFS at the FRONT of a jq program and use:
#   addressed_to($filters)  -> true if the title routes to any recipient in the
#                              pipe-joined $filters string (e.g. "Bob|ALL").
#   msg_sender              -> normalized lowercased sender token (text before first →).
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
# Consumers: ntfy-bus skill CheckInbox/Watch, both wakers, and any fleet-side
# monitors. Change the matcher HERE and every consumer inherits it.
BUS_ROUTING_DEFS='
def normalize_pointer: gsub("➡️";"→") | gsub("➡";"→") | gsub("👉";"→") | gsub("->";"→") | gsub(" to ";"→";"i");
def routing_header: ((.title // "") | split(":")[0] | normalize_pointer);
def addressed_to($filters): (routing_header | test("→.*\\b(" + $filters + ")\\b"));
def msg_sender: (routing_header | split("→")[0] | gsub("^\\s+|\\s+$";"") | ascii_downcase);
'
