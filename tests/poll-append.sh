#!/usr/bin/env bash
# tests/poll-append.sh — the poller's append survives a bad response line and a
# torn inbox (issue #52, review of PR #58).
#
# No network and no fake binary (the poller pins its own PATH, so a curl shim
# is never found): the scratch config's endpoint is a file:// URL, and the real
# curl reads the canned response from disk. curl drops the ?query on a file://
# URL; a curl that does not is detected up front and the suite SKIPs (exit 2).
set -u
. "$(dirname "$0")/lib/harness.sh"
POLLER="$SKILL_ROOT/daemons/ntfy-poll-to-jsonl.sh"
unset CLAUDE_PROJECT_DIR NTFY_DAEMON_CONTEXT

probe=$(mktemp -d "${TMPDIR:-/tmp}/ntfy-bus-probe.XXXXXX")
echo ok > "$probe/json"
got=$(curl -s --max-time 5 -u u:p "file://$probe/json?poll=1&since=1" 2>/dev/null)
rm -rf "$probe"
[ "$got" = ok ] || { echo "poll-append: this curl cannot read file:// URLs with a query — SKIP"; exit 2; }

# $1 = the response the "server" returns. An argument, not stdin: a function
# on the right of a pipe runs in a subshell, and new_env's $ROOT would be lost.
poll_env() {
  new_env
  mkdir -p "$ROOT/srv/test-bus"
  printf '%s\n' "$1" > "$ROOT/srv/test-bus/json"
  jq --arg e "file://$ROOT/srv" '.endpoint = $e' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
    && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
}
poll() {
  ( cd "$ROOT" && HOME="$ROOT" NTFY_HOME="$ROOT" \
      NTFY_USERNAME=u NTFY_PASSWORD=p bash "$POLLER" >/dev/null 2>&1 )
}
ids() { jq -R -r 'fromjson? | .id' "$INBOX" | tr '\n' ' '; }
msg() { printf '{"id":"%s","time":%s,"event":"message","topic":"test-bus","title":"Dana->TestAgent: %s","message":"b"}\n' "$1" "$2" "$1"; }
NOW=$(date +%s)

echo "A1: a clean response is appended, and a second poll adds nothing"
poll_env "$(msg a1 "$NOW"; msg a2 "$((NOW+1))")"
poll; assert_eq "both captured" "a1 a2 " "$(ids)"
poll; assert_eq "re-poll is idempotent" "a1 a2 " "$(ids)"
assert_eq "state advanced to the newest message" "$((NOW+1))" "$(cat "${INBOX%.jsonl}.poll-state")"
cleanup

echo "A2: one unparseable response line does not drop the messages behind it"
poll_env "$(msg b1 "$NOW"; printf '%s\n' '{"id":"bad","time":1,"event":"message","tit'; msg b2 "$((NOW+1))"; msg b3 "$((NOW+2))")"
poll
assert_eq "messages on both sides captured" "b1 b2 b3 " "$(ids)"
assert_eq "state advanced past the bad line" "$((NOW+2))" "$(cat "${INBOX%.jsonl}.poll-state")"
cleanup

echo "A3: an inbox left without a final newline is closed before appending"
poll_env "$(msg c2 "$NOW")"
printf '{"id":"c1","time":17' > "$INBOX"            # a torn write: no newline
poll
assert_eq "the new message is on its own, parseable line" "c2 " "$(ids)"
assert_eq "torn fragment kept as its own line" "2" "$(wc -l < "$INBOX" | tr -d ' ')"
assert_contains "the repair is logged" "${INBOX%.jsonl}.poll.log" 'did not end in a newline'
cleanup

echo "A4: a healthy inbox gets no extra blank line"
poll_env "$(msg d2 "$((NOW+1))")"
msg d1 "$NOW" > "$INBOX"
poll
assert_eq "exactly two lines" "2" "$(wc -l < "$INBOX" | tr -d ' ')"
assert_false "no blank line" grep -q '^$' "$INBOX"
cleanup

finish
