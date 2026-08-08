# shellcheck shell=bash
# tests/lib/harness.sh — shared scaffold for the ntfy-bus test suites.
#
# Source this at the top of a tests/*.sh file. It provides:
#
#   $SKILL_ROOT                 the skill tree under test — THIS repo's
#                               skills/ntfy-bus, derived from the harness's own
#                               location. No installed host required: scripts
#                               resolve their libs self-relatively, so a fresh
#                               clone runs the whole suite hermetically.
#   new_env / cleanup           throwaway $NTFY_HOME with its own config +
#                               inbox JSONL ($ROOT, $INBOX set). No live bus,
#                               no network, no credentials.
#   emit ID TITLE               append a message the way the poller would.
#   pass/fail MSG               counters + output, aggregated by finish.
#   assert_eq DESC WANT GOT
#   assert_contains DESC FILE PATTERN   (grep -E)
#   assert_true DESC CMD... / assert_false DESC CMD...
#   finish                      print TOTAL, exit 0 iff no failures.
#
# Every suite is also directly runnable: bash tests/<suite>.sh. tests/run.sh
# discovers and aggregates them. Exit 2 from a suite means SKIP (dependency
# missing), which run.sh reports without failing the run.

_harness_self=${BASH_SOURCE[0]}
while [ -L "$_harness_self" ]; do _harness_self=$(readlink "$_harness_self"); done
TESTS_DIR=$(cd -P "$(dirname "$_harness_self")/.." && pwd -P)
SKILL_ROOT=$(cd -P "$TESTS_DIR/../skills/ntfy-bus" && pwd -P)
[ -f "$SKILL_ROOT/SKILL.md" ] || { echo "harness: cannot locate skill root (got $SKILL_ROOT)" >&2; exit 1; }

PASS=0; FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# Scratch host: config carries the same keys the real Setup writes, pointed at
# throwaway paths. TestAgent is deliberately not a real fleet identity.
new_env() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ntfy-bus-test.XXXXXX")
  export NTFY_HOME="$ROOT"
  mkdir -p "$ROOT/.claude"
  INBOX="$ROOT/.claude/ntfy-inbox.testagent.jsonl"
  cat > "$ROOT/.claude/ntfy-bus.config.json" <<JSON
{ "agent_id": "TestAgent", "endpoint": "http://127.0.0.1:9/unused", "topic": "test-bus",
  "auth_env": { "username": "NTFY_USERNAME", "password": "NTFY_PASSWORD" },
  "inbox_jsonl": "$INBOX", "recipient_filters": ["TestAgent", "ALL"],
  "waker": { "seen_ids": "$ROOT/.claude/ntfy-bus.seen-ids" } }
JSON
  : > "$INBOX"
}
cleanup() { rm -rf "${ROOT:-}"; unset NTFY_HOME; }

# Append a message the way the poller would have: addressed via the Title.
emit() {
  printf '{"event":"message","id":"%s","time":%s,"title":"%s","message":"b"}\n' \
    "$1" "$(date +%s)" "$2" >> "$INBOX"
}

assert_eq() { # DESC WANT GOT
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi
}
assert_contains() { # DESC FILE PATTERN
  if grep -Eq "$3" "$2" 2>/dev/null; then pass "$1"
  else fail "$1 (no match for '$3' in $2)"; fi
}
assert_true() { # DESC CMD...
  local d="$1"; shift
  if "$@"; then pass "$d"; else fail "$d (expected success, got exit $?)"; fi
}
assert_false() { # DESC CMD...
  local d="$1"; shift
  if "$@"; then fail "$d (expected failure, command succeeded)"; else pass "$d"; fi
}

finish() {
  echo
  echo "TOTAL: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
