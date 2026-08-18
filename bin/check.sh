#!/bin/bash
# bin/check.sh — portability gate. Run before pushing main. Exit 0 = green.
set -u
# Portable symlink resolver — readlink -f is absent on macOS <12.3.
# Duplicated in doctor.sh/daemon/segment (pre-lib bootstrap); keep in sync.
bus_resolve() {
  local t="$1" d
  while [ -L "$t" ]; do
    d=$(cd -P "$(dirname "$t")" && pwd -P); t=$(readlink "$t")
    case "$t" in /*) ;; *) t="$d/$t" ;; esac
  done
  printf '%s/%s' "$(cd -P "$(dirname "$t")" && pwd -P)" "$(basename "$t")"
}
REPO=$(cd -P "$(dirname "$(bus_resolve "${BASH_SOURCE[0]}")")/.." && pwd -P)
SKILL="$REPO/skills/ntfy-bus"
# Fail LOUD if resolution went sideways — a false-green portability gate is
# worse than none (an unresolved REPO would make every check below a no-op).
[ -f "$SKILL/SKILL.md" ] || { echo "FAIL: cannot resolve repo root (got: $REPO)"; exit 1; }
fail=0
say() { printf '%s\n' "$*"; }
bad() { say "FAIL: $*"; fail=1; }

# 1. bash parses every shell file
while IFS= read -r f; do
  bash -n "$f" || bad "bash -n $f"
done < <(find "$REPO/bin" "$SKILL/bin" "$SKILL/lib" "$SKILL/daemons" "$SKILL/statusline" -name '*.sh' -type f 2>/dev/null)

# 2. example configs are valid JSON
for j in "$REPO/config.example.json" "$REPO/config.repo-local.example.json" \
         "$REPO/.claude-plugin/plugin.json" "$REPO/.claude-plugin/marketplace.json"; do
  [ -f "$j" ] && { jq empty "$j" 2>/dev/null || bad "invalid JSON: $j"; }
done

# 3. grep bans in shared shell code (portability + identity hygiene).
# No pipes into while (subshell would swallow fail=1) — capture then test.
# $REPO/bin is IN scope: the gate must scan its own directory. It didn't until
# 2026-07-13, which is exactly how a `readlink -f` survived in doctor.sh — the
# portability gate was blind to the tools that enforce portability.
#
# Scanning bin/ means this file is now in its own scan set, so check.sh's ban
# PATTERNS and error STRINGS are themselves literal matches. They are exempted
# by the `gate-literal` sentinel below: a line that DEFINES a ban is not a
# violation of it. The sentinel exempts the marked LINE only — never a file, and
# never a directory. Excluding check.sh wholesale would just rebuild the exact
# blind spot this change closes.
SHARED=$(find "$REPO/bin" "$SKILL/bin" "$SKILL/lib" "$SKILL/daemons" "$SKILL/statusline" -name '*.sh' -type f 2>/dev/null)
# ban <grep-flags> <regex> <message> — reports file:line, minus sentinel lines.
ban() {
  local flags="$1" re="$2" msg="$3" h
  # shellcheck disable=SC2086
  h=$(grep $flags -n -- "$re" $SHARED 2>/dev/null | grep -v 'gate-literal')
  [ -n "$h" ] && bad "$msg: $(printf '%s' "$h" | tr '\n' ' ')"
}
ban "-E" '\$\{!' 'bash indirection ${!}'                                        # gate-literal
ban "-E" '/home/[a-z]|/Users/[a-z]' 'hardcoded home path'
# Fleet agent names must not appear as code values in shared shell (comments OK).
ban "-iE" '^[^#]*(FILTERS|SELF|AGENT)[A-Z_]*=.*"(Alice|Bob|Carol|Dave)' 'hardcoded agent identity'
# GNU-only constructs that break BSD/macOS — the exact class this gate exists
# for. Code lines only (comments may name the banned forms to explain them).
ban "-E" '^[^#]*(readlink +-[a-z]*f|date -I)' 'GNU-only readlink -f / date -I (use bus_resolve / date -u +%Y-%m-%dT%H:%M:%SZ)'  # gate-literal

# 4. systemd template must not point into a plugin cache
grep -q 'plugins/cache' "$SKILL/systemd/bus-waker.service" 2>/dev/null && \
  bad "systemd template points into plugin cache"

# 5. the duplicated bus_resolve() bootstrap copies must stay byte-identical.
# There are FOUR (bin/check.sh, bin/doctor.sh, daemons/bus-waker-daemon.sh,
# statusline/bus-segment.sh) and "keep in sync" was a comment, not a check —
# which is how one of them stayed on logical pwd after the other three were
# fixed. A comment is not a gate. This is.
copies=$(grep -rl 'bus_resolve()' --include='*.sh' "$REPO" 2>/dev/null | sort)
n=$(printf '%s\n' "$copies" | grep -c . )
uniq=$(for f in $copies; do sed -n '/^bus_resolve()/,/^}/p' "$f" | shasum | cut -d" " -f1; done | sort -u | wc -l | tr -d ' ')
[ "$uniq" = "1" ] || bad "bus_resolve() copies have DIVERGED across $n files ($uniq distinct versions) — they must be byte-identical"

# 6. no literal STATE-FILE paths in shared runtime code. Every state path
# (pidfile, inbox, wake-log, seen-ids, lock) is a per-machine fact and must
# come from config; if config doesn't supply it, code FAILS LOUD — it never
# guesses. This generalizes the daemon's fail-loud identity rule from WHO an
# agent is to WHERE its state lives. bin/ is IN scope: status/
# install tools in bin/ read and derive state paths too, and the old
# by-scope exemption made exactly that class undetectable. A detector line
# that must name a state path (like doctor.sh's ALLOW list, which uses bare
# basenames anyway) is exempted per-line via the gate-literal sentinel.
# Comments are exempt (^[^#]*): explaining a path is fine, shipping one is not.
RUNTIME=$(find "$REPO/bin" "$SKILL/bin" "$SKILL/lib" "$SKILL/daemons" "$SKILL/statusline" -name '*.sh' -type f 2>/dev/null)
# /dev/null guarantees >=1 file arg: with an empty $RUNTIME, grep would
# otherwise BLOCK reading stdin — a hung gate, worse than a red one.
h=$(grep -En '^[^#]*(\$HOME|~)/[^"]*\.(pid|jsonl|log|lock|seen-ids)' $RUNTIME /dev/null 2>/dev/null | grep -v 'gate-literal')  # gate-literal
[ -n "$h" ] && bad "literal state-file path in shared runtime code (move to config + fail loud): $(printf '%s' "$h" | tr '\n' ' ')"

# 6b. the same rule, one level of indirection deep: the single-line
# pattern above is evaded by exactly the refactor someone would naturally
# write — DIR="$HOME/x" on one line, FILE="$DIR/y.jsonl" on another. Per file:
# collect variable names assigned a home-anchored path, then flag any
# state-extension path built from one of them. One level only, by design —
# deeper laundering is possible, but each level costs the author more
# contortion and this catches the natural form.
for f in $RUNTIME; do
  hv=$(sed -nE 's,^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=["'\'']?(\$HOME|~)/.*,\1,p' "$f" | sort -u | tr '\n' '|' | sed 's/|$//')  # gate-literal
  [ -n "$hv" ] || continue
  h=$(grep -En '^[^#]*\$\{?('"$hv"')\}?/[^"]*\.(pid|jsonl|log|lock|seen-ids)' "$f" /dev/null 2>/dev/null | grep -v 'gate-literal')
  [ -n "$h" ] && bad "state-file path built from home-anchored variable \$${hv} (move to config + fail loud): $(printf '%s' "$h" | tr '\n' ' ')"
done

# 7. no contributor's bus identity may be tracked in this repo. A committed
# .claude/ntfy-bus.config.json ships a live fleet agent name to everyone who
# clones, and the first clone to run a workflow sends and arms wakers AS that
# agent. Identity is per-contributor, not per-project — it belongs in an
# untracked file (.gitignore) on each machine. git ls-files is the authority
# here, not .gitignore: an already-tracked file stays tracked no matter what
# the ignore rules say afterwards.
t=$(git -C "$REPO" ls-files -- '.claude/ntfy-bus.config.json' '*/.claude/ntfy-bus.config.json' 2>/dev/null)
[ -n "$t" ] && bad "bus identity config is TRACKED (identity is per-contributor — untrack it: git rm --cached <file>): $(printf '%s' "$t" | tr '\n' ' ')"

# 8. every Workflow that sources the resolver must also call the caller-side
# gate (issue #8). The resolver's header states the contract — treat an empty
# NTFY_CONFIG as unconfigured and refuse — but a stated contract is a comment,
# and a comment is not a gate. Gating on the PAIRING (source implies
# require) also catches a hand-rolled or subtly broken inline guard.
for f in "$SKILL"/Workflows/*.md; do
  grep -Eq '^[[:space:]]*(\.|source)[[:space:]].*resolve-config\.sh' "$f" || continue
  grep -q 'ntfy_require_config' "$f" || bad "workflow sources resolver without ntfy_require_config: $f"
done

[ "$fail" = "0" ] && say "check.sh: all green"
exit "$fail"
