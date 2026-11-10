#!/usr/bin/env bash
# tests/setup-doc.sh — the host-class snippets in Workflows/Setup.md, run for
# real (issue #46).
#
# Setup is a document an agent executes, and its host-class guard is the
# write-time half of the identity lock. Until now nothing ran those snippets:
# a guard that silently wrote the wrong per_repo_identity_allowed, or that
# defaulted an undetectable host to "vanilla", would have shipped green. Each
# case extracts the snippet from the doc itself and runs it in a FRESH shell —
# which is how an agent runs them, and why no step may lean on a variable an
# earlier step set.
set -u
. "$(dirname "$0")/lib/harness.sh"
DOC="$SKILL_ROOT/Workflows/Setup.md"

# Print the first fenced code block that follows the heading matching $1.
block_after() {
  awk -v pat="$1" '
    !found && $0 ~ pat { found=1; next }
    found && !inb && /^```/ { inb=1; next }
    found && inb && /^```/ { exit }
    found && inb { print }' "$DOC"
}
STEP0=$(block_after '^## Step 0:')
# Step 5's block goes on to write the config; the guard is everything before.
STEP5=$(block_after '^## Step 5:' | sed '/^cat > /,$d')
STEP6=$(block_after '^## Step 6:')
[ -n "$STEP0" ] && [ -n "$STEP5" ] && [ -n "$STEP6" ] \
  || { echo "setup-doc: could not extract the Step 0/5/6 snippets from $DOC" >&2; exit 1; }

# Scratch home with the skill installed the way hosts have it: a symlink.
doc_env() { new_env; mkdir -p "$ROOT/.claude/skills"; ln -s "$SKILL_ROOT" "$ROOT/.claude/skills/ntfy-bus"; }
# Run SNIPPET in a fresh process of SHELL ($1), extra env as leading VAR=val.
run_in() { # shell snippet [VAR=val...]
  local sh="$1" code="$2"; shift 2
  ( cd "$ROOT" && env -u HOST_CLASS -u PER_REPO -u CLAUDE_PROJECT_DIR HOME="$ROOT" NTFY_HOME="$ROOT" "$@" "$sh" -c "$code" 2>&1 )
}

SHELLS="bash"
command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"

for sh in $SHELLS; do
  echo "S1 ($sh): Step 0 names the class and the marker"
  doc_env
  assert_eq "vanilla host" "host class: vanilla" "$(run_in "$sh" "$STEP0")"
  mkdir -p "$ROOT/.claude/LIFEOS"
  assert_eq "current LifeOS marker" "host class: lifeos (marker: ~/.claude/LIFEOS/)" "$(run_in "$sh" "$STEP0")"
  cleanup

  echo "S2 ($sh): Step 0 with no skill lib says STOP — out loud, even under set -e"
  new_env
  for pre in "" "set -e; "; do
    out=$(run_in "$sh" "${pre}${STEP0}")
    case "$out" in
      *"CANNOT detect host class"*) pass "STOP printed (prefix: '${pre}')" ;;
      *) fail "STOP printed (prefix: '${pre}', got: '$out')" ;;
    esac
    case "$out" in
      *"host class: vanilla"*) fail "never vanilla by default (prefix: '${pre}')" ;;
      *) pass "never vanilla by default (prefix: '${pre}')" ;;
    esac
  done
  cleanup

  echo "S3 ($sh): Step 5 decides per-repo by itself, in a fresh shell"
  doc_env
  # The regression the #46 review caught: Step 0's variable is gone by now.
  assert_eq "vanilla + asked for per-repo -> true" "true" \
    "$(run_in "$sh" "$STEP5"'; printf %s "$PER_REPO" >&3' PER_REPO=true 3>&1 >/dev/null)"
  assert_eq "vanilla, nothing asked -> false" "false" \
    "$(run_in "$sh" "$STEP5"'; printf %s "$PER_REPO" >&3' 3>&1 >/dev/null)"
  mkdir -p "$ROOT/.claude/LIFEOS"
  assert_eq "LifeOS + asked for per-repo -> false" "false" \
    "$(run_in "$sh" "$STEP5"'; printf %s "$PER_REPO" >&3' PER_REPO=true 3>&1 >/dev/null)"
  # A hand-set or stale HOST_CLASS must not be what decides.
  assert_eq "LifeOS + HOST_CLASS=vanilla typed by hand -> still false" "false" \
    "$(run_in "$sh" "$STEP5"'; printf %s "$PER_REPO" >&3' PER_REPO=true HOST_CLASS=vanilla 3>&1 >/dev/null)"
  cleanup
  new_env
  assert_eq "no skill lib + asked for per-repo -> false" "false" \
    "$(run_in "$sh" "$STEP5"'; printf %s "$PER_REPO" >&3' PER_REPO=true 3>&1 >/dev/null)"
  cleanup

  echo "S4 ($sh): Step 6 guard passes only a positively vanilla host"
  doc_env
  assert_eq "vanilla" "ok: vanilla host" "$(run_in "$sh" "$STEP6")"
  mkdir -p "$ROOT/.claude/PAI"
  case "$(run_in "$sh" "$STEP6")" in STOP*) pass "LifeOS host stopped" ;; *) fail "LifeOS host stopped" ;; esac
  cleanup
  new_env
  case "$(run_in "$sh" "$STEP6")" in STOP*) pass "no lib stopped" ;; *) fail "no lib stopped" ;; esac
  cleanup
done

finish
