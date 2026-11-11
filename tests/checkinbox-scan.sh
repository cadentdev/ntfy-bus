#!/usr/bin/env bash
# tests/checkinbox-scan.sh — CheckInbox's JSONL read survives a corrupt line
# (issue #52).
#
# Step 3a fed the inbox tail to one jq. jq stops at the first line it cannot
# parse, so one corrupt line hid every later message from the agent reading
# its inbox by hand — the fallback the waker doctrine points to. The snippet
# is extracted from the doc itself and run in a fresh shell, as an agent would.
set -u
. "$(dirname "$0")/lib/harness.sh"
WF="$SKILL_ROOT/Workflows"

# Print the first fenced code block after the heading matching $2 in doc $1.
block_after() {
  awk -v pat="$2" '
    !found && $0 ~ pat { found=1; next }
    found && !inb && /^```/ { inb=1; next }
    found && inb && /^```/ { exit }
    found && inb { print }' "$1"
}
STEP1=$(block_after "$WF/CheckInbox.md" '^## Step 1:')
STEP3A=$(block_after "$WF/CheckInbox.md" '^## Step 3a:')
[ -n "$STEP1" ] && [ -n "$STEP3A" ] \
  || { echo "checkinbox-scan: could not extract a snippet from $WF/CheckInbox.md" >&2; exit 1; }

run_in() { # shell -> the snippet's stdout (the matched messages)
  ( cd "$ROOT" && env -u NTFY_SKILL_DIR -u CLAUDE_PROJECT_DIR HOME="$ROOT" NTFY_HOME="$ROOT" \
      "$1" -c "$STEP1
$STEP3A" 2>/dev/null )
}

SHELLS="bash"
command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"

for sh in $SHELLS; do
  echo "C1 ($sh): a clean inbox lists the addressed messages"
  new_env; mkdir -p "$ROOT/.claude/skills"; ln -s "$SKILL_ROOT" "$ROOT/.claude/skills/ntfy-bus"
  emit a1 "Dana->TestAgent: one"
  emit a2 "Dana->SomeoneElse: not mine"
  emit a3 "Dana->ALL: two"
  out=$(run_in "$sh")
  assert_eq "two addressed messages" "2" "$(printf '%s\n' "$out" | grep -c '"id"')"
  cleanup

  echo "C2 ($sh): a corrupt line does not hide the messages after it"
  new_env; mkdir -p "$ROOT/.claude/skills"; ln -s "$SKILL_ROOT" "$ROOT/.claude/skills/ntfy-bus"
  emit b1 "Dana->TestAgent: before"
  printf '%s\n' '{"event":"message","id":"bad1","tit' '42' 'not json' '' >> "$INBOX"
  emit b2 "Dana->TestAgent: after"
  emit b3 "Dana->ALL: also after"
  out=$(run_in "$sh")
  assert_eq "all three real messages" "3" "$(printf '%s\n' "$out" | grep -c '"id"')"
  assert_true "the message after the bad line is there" \
    sh -c 'printf "%s\n" "$1" | grep -q "\"id\":\"b2\""' _ "$out"
  assert_true "output is still one compact JSON object per line" \
    sh -c 'printf "%s\n" "$1" | jq -e -s "length == 3 and all(.[]; type == \"object\")" >/dev/null' _ "$out"
  cleanup

  echo "C3 ($sh): two messages glued on one line are both listed"
  new_env; mkdir -p "$ROOT/.claude/skills"; ln -s "$SKILL_ROOT" "$ROOT/.claude/skills/ntfy-bus"
  printf '{"event":"message","id":"g1","time":1,"title":"Dana->TestAgent: no newline","message":"b"}' >> "$INBOX"
  printf '{"event":"message","id":"g2","time":2,"title":"Dana->ALL: glued on","message":"b"}\n' >> "$INBOX"
  out=$(run_in "$sh")
  assert_eq "both glued messages" "2" "$(printf '%s\n' "$out" | grep -c '"id"')"
  cleanup
done



finish
