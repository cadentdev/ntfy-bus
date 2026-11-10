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
# Print the Nth ($2) fenced code block after the line matching $1.
block_n_after() {
  awk -v pat="$1" -v want="$2" '
    !found && $0 ~ pat { found=1; next }
    found && !inb && /^```/ { inb=1; n++; next }
    found && inb && /^```/ { if (n == want) exit; inb=0; next }
    found && inb && n == want { print }' "$DOC"
}
STEP0=$(block_after '^## Step 0:')
# Step 5's block goes on to write the config; the guard is everything before.
STEP5=$(block_after '^## Step 5:' | sed '/^cat > /,$d')
STEP6=$(block_after '^## Step 6:')
# 6b's second block wires the hook into settings.json (issue #55).
STEP6B=$(block_n_after '^\*\*6b\. ' 2)
[ -n "$STEP0" ] && [ -n "$STEP5" ] && [ -n "$STEP6" ] \
  || { echo "setup-doc: could not extract the Step 0/5/6 snippets from $DOC" >&2; exit 1; }
STEP8=$(block_after '^## Step 8:')
case "$STEP8" in *doctor.sh*) ;; *) echo "setup-doc: could not extract the Step 8 snippet from $DOC" >&2; exit 1 ;; esac
case "$STEP6B" in *HOOK_CMD*settings.json*) ;; *) echo "setup-doc: could not extract the Step 6b wiring snippet from $DOC" >&2; exit 1 ;; esac

# Scratch home with the skill installed the way hosts have it: a symlink.
doc_env() { new_env; mkdir -p "$ROOT/.claude/skills"; ln -s "$SKILL_ROOT" "$ROOT/.claude/skills/ntfy-bus"; }
# Run SNIPPET in a fresh process of SHELL ($1), extra env as leading VAR=val.
run_in() { # shell snippet [VAR=val...]
  local sh="$1" code="$2"; shift 2
  ( cd "$ROOT" && env -u HOST_CLASS -u PER_REPO -u CLAUDE_PROJECT_DIR -u NTFY_SKILL_DIR HOME="$ROOT" NTFY_HOME="$ROOT" "$@" "$sh" -c "$code" 2>&1 )
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

  # --- issue #55: the plugin-only install (no stable path) -------------------
  echo "S5 ($sh): plugin-only — NTFY_SKILL_DIR reaches the lib in every step"
  new_env
  P="NTFY_SKILL_DIR=$SKILL_ROOT"
  assert_eq "Step 0 vanilla" "host class: vanilla" "$(run_in "$sh" "$STEP0" "$P")"
  assert_eq "Step 5 vanilla + asked -> true" "true" \
    "$(run_in "$sh" "$STEP5"'; printf %s "$PER_REPO" >&3' PER_REPO=true "$P" 3>&1 >/dev/null)"
  assert_eq "Step 6 vanilla" "ok: vanilla host" "$(run_in "$sh" "$STEP6" "$P")"
  mkdir -p "$ROOT/.claude/LIFEOS"
  assert_eq "Step 0 LifeOS" "host class: lifeos (marker: ~/.claude/LIFEOS/)" "$(run_in "$sh" "$STEP0" "$P")"
  assert_eq "Step 5 LifeOS + asked -> false" "false" \
    "$(run_in "$sh" "$STEP5"'; printf %s "$PER_REPO" >&3' PER_REPO=true "$P" 3>&1 >/dev/null)"
  case "$(run_in "$sh" "$STEP6" "$P")" in STOP*) pass "Step 6 LifeOS stopped" ;; *) fail "Step 6 LifeOS stopped" ;; esac
  cleanup

  # A lib that calls every host vanilla: if it is ever sourced, the guards open.
  decoy() { mkdir -p "$1/lib"; printf '%s\n' 'ntfy_host_class() { printf vanilla; }; ntfy_lifeos_marker() { return 1; }' > "$1/lib/resolve-config.sh"; }
  # All three guards must refuse; $1 = label, rest = env for run_in.
  refuses() {
    local what="$1" out; shift
    out=$(run_in "$sh" "$STEP0" "$@")
    case "$out" in *"CANNOT detect host class"*) pass "Step 0 STOP ($what)" ;; *) fail "Step 0 STOP ($what, got: '$out')" ;; esac
    assert_eq "Step 5 false ($what)" "false" \
      "$(run_in "$sh" "$STEP5"'; printf %s "$PER_REPO" >&3' PER_REPO=true "$@" 3>&1 >/dev/null)"
    case "$(run_in "$sh" "$STEP6" "$@")" in STOP*) pass "Step 6 STOP ($what)" ;; *) fail "Step 6 STOP ($what)" ;; esac
  }

  echo "S6 ($sh): a wrong NTFY_SKILL_DIR never yields vanilla"
  new_env
  refuses "nonexistent dir" NTFY_SKILL_DIR="$ROOT/nowhere"
  refuses "empty" NTFY_SKILL_DIR=""
  # Relative: resolves against the cwd, i.e. whatever repo the shell is in.
  # A real decoy lib sits there, so only the absolute-path rule stops it.
  decoy "$ROOT/relative/dir"
  refuses "relative dir holding a lib" NTFY_SKILL_DIR="relative/dir"
  cleanup

  echo "S7 ($sh): anything at the stable path wins — NTFY_SKILL_DIR cannot swap the lib"
  doc_env
  mkdir -p "$ROOT/.claude/LIFEOS"; decoy "$ROOT/decoy"
  D="NTFY_SKILL_DIR=$ROOT/decoy"
  assert_eq "healthy install: Step 0 still lifeos" "host class: lifeos (marker: ~/.claude/LIFEOS/)" "$(run_in "$sh" "$STEP0" "$D")"
  assert_eq "healthy install: Step 5 still false" "false" \
    "$(run_in "$sh" "$STEP5"'; printf %s "$PER_REPO" >&3' PER_REPO=true "$D" 3>&1 >/dev/null)"
  case "$(run_in "$sh" "$STEP6" "$D")" in STOP*) pass "healthy install: Step 6 still stopped" ;; *) fail "healthy install: Step 6 still stopped" ;; esac
  cleanup
  # A BROKEN install must stop, not fall through to the environment (the
  # #55 review: each of these states unlocked a LifeOS host before the fix).
  for state in dangling file nolib libfile; do
    new_env; mkdir -p "$ROOT/.claude/LIFEOS" "$ROOT/.claude/skills"; decoy "$ROOT/decoy"
    S="$ROOT/.claude/skills/ntfy-bus"
    case "$state" in
      dangling) ln -s "$ROOT/gone" "$S" ;;
      file)     : > "$S" ;;
      nolib)    mkdir "$S" ;;
      libfile)  mkdir "$S"; : > "$S/lib" ;;
    esac
    refuses "stable path is $state + decoy NTFY_SKILL_DIR" "NTFY_SKILL_DIR=$ROOT/decoy"
    cleanup
  done

  echo "S8 ($sh): Step 6b never wires a hook path that is not the stable one"
  new_env
  mkdir -p "$ROOT/.bun/bin"
  out=$(run_in "$sh" "$STEP6B" "NTFY_SKILL_DIR=$SKILL_ROOT")
  case "$out" in *"NOT wiring"*) pass "plugin-only: says NOT wiring" ;; *) fail "plugin-only: says NOT wiring (got: '$out')" ;; esac
  assert_false "plugin-only: settings.json untouched" test -e "$ROOT/.claude/settings.json"
  cleanup
  doc_env
  run_in "$sh" "$STEP6B" >/dev/null
  assert_eq "stable install: hook wired at the stable path" "1" \
    "$(jq '[.hooks.PreToolUse[].hooks[].command | select(endswith("/.claude/skills/ntfy-bus/hooks/BridgeBodyGuard.hook.ts"))] | length' "$ROOT/.claude/settings.json" 2>/dev/null)"
  cleanup

  echo "S9 ($sh): Step 8 runs the clone's doctor, and no other"
  new_env
  mkdir -p "$ROOT/work/sub" "$ROOT/work/bin" "$ROOT/work/skills/ntfy-bus"
  echo 'echo WRONG-DOCTOR' > "$ROOT/work/bin/doctor.sh"
  # Plugin-only: nothing at the stable path. cwd's parent has a bin/doctor.sh.
  out=$( cd "$ROOT/work/sub" && env HOME="$ROOT" "$sh" -c "$STEP8" 2>&1 )
  case "$out" in *WRONG-DOCTOR*) fail "plugin-only: ran a doctor found near the cwd" ;; *skipped*) pass "plugin-only: skipped" ;; *) fail "plugin-only: skipped (got: '$out')" ;; esac
  # Clone behind a RELATIVE symlink, the way real hosts link it.
  mkdir -p "$ROOT/clone/bin" "$ROOT/clone/skills/ntfy-bus/lib" "$ROOT/.claude/skills"
  echo 'echo CLONE-DOCTOR' > "$ROOT/clone/bin/doctor.sh"
  ln -s ../../clone/skills/ntfy-bus "$ROOT/.claude/skills/ntfy-bus"
  out=$( cd "$ROOT/work/sub" && env HOME="$ROOT" "$sh" -c "$STEP8" 2>&1 )
  assert_eq "relative symlink: the clone's doctor ran" "CLONE-DOCTOR" "$out"
  cleanup
done

finish
