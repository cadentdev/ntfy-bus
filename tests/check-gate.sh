#!/usr/bin/env bash
# tests/check-gate.sh — proves bin/check.sh section 11 can go red (issue #46).
#
# A gate nothing has ever seen fail is a comment. Each case runs check.sh in a
# COPY of the repo with one planted line and asserts on section 11's own
# message — never the exit code, since a copy can trip other sections.
set -u
. "$(dirname "$0")/lib/harness.sh"
SRC=$(cd -P "$TESTS_DIR/.." && pwd -P)

copy_repo() {
  new_env
  mkdir -p "$ROOT/r"
  ( cd "$SRC" && tar cf - --exclude .git . ) | ( cd "$ROOT/r" && tar xf - )
  git -C "$ROOT/r" init -q
}
gate() { bash "$ROOT/r/bin/check.sh" 2>&1; }
flags() { case "$(gate)" in *"LifeOS marker path spelled out in $1"*) return 0 ;; *) return 1 ;; esac; }

echo "G1: the tree as shipped does not trip section 11"
copy_repo
assert_false "clean copy: no shell finding" flags "shell code"
assert_false "clean copy: no doc finding"   flags "a doc code block"
cleanup

echo "G2: a marker path in shared shell code is caught, whatever the test operator"
for line in '[ -d "$HOME/.claude/PAI" ] && x=1' '[ -L "$HOME/.claude/LIFEOS" ] && x=1' \
            'ls "$HOME/.claude/lifeos/VERSION" >/dev/null' 'M="$HOME/.claude/PAI"'; do
  copy_repo
  printf '%s\n' "$line" >> "$ROOT/r/skills/ntfy-bus/daemons/ntfy-bus-waker.sh"
  assert_true "caught in daemons/: $line" flags "shell code"
  cleanup
done
copy_repo
printf '%s\n' '[ -d "$HOME/.claude/PAI" ] && x=1' >> "$ROOT/r/skills/ntfy-bus/hooks/arm-bus-waker.sh"
assert_true "caught in hooks/" flags "shell code"
cleanup

echo "G3: comments and doc prose may name the marker; a doc code block may not"
copy_repo
printf '%s\n' '# the latest LifeOS creates ~/.claude/LIFEOS/ -- detected by the lib' >> "$ROOT/r/bin/doctor.sh"
printf '\n%s\n' 'The latest LifeOS release creates `~/.claude/LIFEOS/`; a pre-existing `~/.claude/PAI/` also counts.' >> "$ROOT/r/README.md"
assert_false "comment not flagged" flags "shell code"
assert_false "prose not flagged"   flags "a doc code block"
printf '\n```bash\n%s\n```\n' 'if [ -d "$HOME/.claude/PAI" ]; then HOST_CLASS=pai; fi' >> "$ROOT/r/skills/ntfy-bus/Workflows/Setup.md"
assert_true  "doc code block flagged" flags "a doc code block"
cleanup

echo "G4: a Workflow snippet sourcing the lib from the fixed install path is caught (section 12)"
flags12() { case "$(gate)" in *"sources the lib from the fixed install path"*) return 0 ;; *) return 1 ;; esac; }
copy_repo
assert_false "clean copy: no finding" flags12
printf '\n%s\n' 'Prose may say `. "$HOME/.claude/skills/ntfy-bus/lib/routing.sh"` when explaining the old form.' >> "$ROOT/r/skills/ntfy-bus/Workflows/Send.md"
assert_false "prose not flagged" flags12
cleanup
for line in '. "$HOME/.claude/skills/ntfy-bus/lib/resolve-config.sh"' \
            '  source ~/.claude/skills/ntfy-bus/lib/routing.sh' \
            '. "${HOME}/.claude/skills/ntfy-bus/lib/routing.sh"'; do
  copy_repo
  printf '\n```bash\n%s\n```\n' "$line" >> "$ROOT/r/skills/ntfy-bus/Workflows/Watch.md"
  assert_true "caught: $line" flags12
  cleanup
done

finish
