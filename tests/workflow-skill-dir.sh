#!/usr/bin/env bash
# tests/workflow-skill-dir.sh — the Send/CheckInbox/Watch snippets find the
# skill's lib on every install shape (issue #55).
#
# The Workflows used to source the lib from one fixed path, which does not
# exist on a plugin-only install. Each case extracts the snippet from the doc
# itself and runs it in a FRESH shell, the way an agent does:
#   - stable path present            -> works, NTFY_SKILL_DIR not needed
#   - plugin-only + NTFY_SKILL_DIR   -> works
#   - neither                        -> stops, loudly, having resolved nothing
#   - both                           -> the stable path wins
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
SEND=$(block_after "$WF/Send.md" '^## Step 1:')
CHECK=$(block_after "$WF/CheckInbox.md" '^## Step 1:')
CHECK3A=$(block_after "$WF/CheckInbox.md" '^## Step 3a:')
# Watch's block ends in a live curl; everything before it is the setup.
WATCH=$(block_after "$WF/Watch.md" '^## Foreground' | sed '/^curl /,$d')
[ -n "$SEND" ] && [ -n "$CHECK" ] && [ -n "$CHECK3A" ] && [ -n "$WATCH" ] \
  || { echo "workflow-skill-dir: could not extract a snippet from $WF" >&2; exit 1; }

stable_env() { new_env; mkdir -p "$ROOT/.claude/skills"; ln -s "$SKILL_ROOT" "$ROOT/.claude/skills/ntfy-bus"; }
# A lib that answers as someone else: proves which directory was sourced.
decoy_dir() {
  mkdir -p "$ROOT/decoy/lib"
  printf '%s\n' 'NTFY_CONFIG=/nonexistent; ntfy_require_config() { return 0; }; ntfy_expand_home() { printf %s "$1"; }' \
    > "$ROOT/decoy/lib/resolve-config.sh"
  printf '%s\n' 'BUS_ROUTING_DEFS="def addressed_to(f): false; "' > "$ROOT/decoy/lib/routing.sh"
}
# Run SNIPPET in a fresh process of SHELL; fd 3 carries the probe value.
run_in() { # shell snippet [VAR=val...]
  local sh="$1" code="$2"; shift 2
  ( cd "$ROOT" && env -u NTFY_SKILL_DIR -u CLAUDE_PROJECT_DIR HOME="$ROOT" NTFY_HOME="$ROOT" "$@" "$sh" -c "$code" 3>&1 >/dev/null 2>&1 )
}
run_err() { # same, but return everything the snippet printed
  local sh="$1" code="$2"; shift 2
  ( cd "$ROOT" && env -u NTFY_SKILL_DIR -u CLAUDE_PROJECT_DIR HOME="$ROOT" NTFY_HOME="$ROOT" "$@" "$sh" -c "$code" 2>&1 )
}

SHELLS="bash"
command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"

for sh in $SHELLS; do
  for name in SEND CHECK WATCH; do
    eval "code=\$$name"
    # Watch also sources the matcher: the probe proves it loaded.
    case "$name" in WATCH) probe='; printf %s "$FILTERS${BUS_ROUTING_DEFS:+ +matcher}" >&3'; want="TestAgent|ALL +matcher" ;;
                    *)     probe='; printf %s "$AGENT_ID" >&3'; want="TestAgent" ;; esac

    echo "W1 ($sh, $name): stable install path"
    stable_env
    assert_eq "resolves with no NTFY_SKILL_DIR" "$want" "$(run_in "$sh" "$code$probe")"
    decoy_dir
    assert_eq "stable path wins over NTFY_SKILL_DIR" "$want" \
      "$(run_in "$sh" "$code$probe" NTFY_SKILL_DIR="$ROOT/decoy")"
    cleanup

    echo "W2 ($sh, $name): plugin-only install"
    new_env
    assert_eq "resolves through NTFY_SKILL_DIR" "$want" \
      "$(run_in "$sh" "$code$probe" NTFY_SKILL_DIR="$SKILL_ROOT")"
    assert_eq "neither place: nothing resolved" "" "$(run_in "$sh" "$code$probe")"
    out=$(run_err "$sh" "$code; echo CONTINUED")
    case "$out" in *NTFY_SKILL_DIR*) pass "neither place: says what to set" ;; *) fail "neither place: says what to set (got: '$out')" ;; esac
    case "$out" in *CONTINUED*) fail "neither place: snippet stops" ;; *) pass "neither place: snippet stops" ;; esac
    cleanup

    echo "W2b ($sh, $name): a relative or broken path is never followed"
    new_env; decoy_dir
    mkdir -p "$ROOT/rel"; cp -R "$ROOT/decoy/lib" "$ROOT/rel/lib"
    assert_eq "relative NTFY_SKILL_DIR holding a lib: nothing resolved" "" \
      "$(run_in "$sh" "$code$probe" NTFY_SKILL_DIR="rel")"
    cleanup
    for state in dangling file nolib; do
      new_env; decoy_dir; mkdir -p "$ROOT/.claude/skills"
      S="$ROOT/.claude/skills/ntfy-bus"
      case "$state" in dangling) ln -s "$ROOT/gone" "$S" ;; file) : > "$S" ;; nolib) mkdir "$S" ;; esac
      out=$(run_err "$sh" "$code; echo CONTINUED" NTFY_SKILL_DIR="$ROOT/decoy")
      case "$out" in *CONTINUED*) fail "stable path is $state: stops, decoy not used" ;; *) pass "stable path is $state: stops, decoy not used" ;; esac
      cleanup
    done
  done

  echo "W3 ($sh): CheckInbox Step 3a finds the matcher in a fresh shell"
  for shape in stable plugin; do
    # stable: a decoy matcher (matches nothing) sits in NTFY_SKILL_DIR and must lose.
    if [ "$shape" = stable ]; then stable_env; decoy_dir; set -- NTFY_SKILL_DIR="$ROOT/decoy"; else new_env; set -- NTFY_SKILL_DIR="$SKILL_ROOT"; fi
    emit m1 "Someone→TestAgent: hello"
    emit m2 "Someone→Other: not ours"
    out=$(run_err "$sh" "$CHECK3A" RECIPIENT_FILTERS='["TestAgent","ALL"]' INBOX_JSONL="$INBOX" "$@")
    case "$out" in *'"id":"m1"'*) pass "$shape: addressed message shown" ;; *) fail "$shape: addressed message shown (got: '$out')" ;; esac
    case "$out" in *'"id":"m2"'*) fail "$shape: other mail hidden" ;; *) pass "$shape: other mail hidden" ;; esac
    cleanup
  done
  new_env
  out=$(run_err "$sh" "$CHECK3A; echo CONTINUED" RECIPIENT_FILTERS='["TestAgent","ALL"]' INBOX_JSONL="$INBOX")
  case "$out" in *CONTINUED*) fail "neither place: 3a stops" ;; *) pass "neither place: 3a stops" ;; esac
  cleanup
done

finish
