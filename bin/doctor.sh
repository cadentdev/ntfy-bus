#!/bin/bash
# bin/doctor.sh — host drift probe. Run on any fleet host: is this machine's
# bus install healthy and canonical? Read-only; exit 0 = healthy.
set -u
# Portable symlink resolver — keep in sync with bin/check.sh (pre-lib bootstrap).
bus_resolve() {
  local t="$1" d
  while [ -L "$t" ]; do
    d=$(cd -P "$(dirname "$t")" && pwd -P); t=$(readlink "$t")
    case "$t" in /*) ;; *) t="$d/$t" ;; esac
  done
  printf '%s/%s' "$(cd -P "$(dirname "$t")" && pwd -P)" "$(basename "$t")"
}
REPO=$(cd -P "$(dirname "$(bus_resolve "${BASH_SOURCE[0]}")")/.." && pwd -P)
SKILL_LINK="$HOME/.claude/skills/ntfy-bus"
warn=0
ok()  { printf 'ok    %s\n' "$*"; }
bad() { printf 'DRIFT %s\n' "$*"; warn=1; }

# 1. skill path resolves into this repo
if [ -e "$SKILL_LINK/SKILL.md" ]; then
  real=$(bus_resolve "$SKILL_LINK/SKILL.md")
  case "$real" in
    "$REPO"/*) ok "skill path resolves into canonical repo" ;;
    *)         bad "skill path resolves OUTSIDE repo: $real" ;;
  esac
else
  bad "no skill at $SKILL_LINK (symlink missing or dangling)"
fi

# 2. repo clean and current
dirty=$(git -C "$REPO" status --porcelain 2>/dev/null)
[ -z "$dirty" ] && ok "repo clean" || bad "repo has uncommitted changes"
git -C "$REPO" fetch --quiet 2>/dev/null
if git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  # BSD `wc -l` PADS its output ("       0"), so a string compare against "0" is
  # false even at zero and macOS hosts report drift while printing a count of
  # zero. Use a numeric compare, which tolerates the padding. (seen on a Darwin
  # host — invisible on GNU coreutils, which does not pad.)
  behind=$(git -C "$REPO" log 'HEAD..@{u}' --oneline 2>/dev/null | wc -l)
  [ "$behind" -eq 0 ] 2>/dev/null && ok "repo current with origin" || bad "repo behind origin by $behind commit(s)"
else
  bad "no upstream configured (detached or upstream-less clone) — cannot verify currency"
fi

# 3. config parses and identity resolves
. "$REPO/skills/ntfy-bus/lib/resolve-config.sh" 2>/dev/null
if [ -f "${NTFY_CONFIG:-}" ] && jq -e '.agent_id' "$NTFY_CONFIG" >/dev/null 2>&1; then
  ok "config parses, identity: $(jq -r .agent_id "$NTFY_CONFIG") (source: ${NTFY_IDENTITY_SOURCE:-?})"
else
  bad "config missing/unparseable at ${NTFY_CONFIG:-unresolved} — run the Setup workflow"
fi

# 4. shadow scan: known bus-component basenames living outside repo-owned homes.
# Allowlist of legitimately host-local files; everything else matching is drift.
# ~/.local/bin is scanned and symlinks match: the shadows found in
# the wild lived in ~/.local/bin, and one was a stow-managed symlink — a scan
# limited to ~/.claude/{bin,hooks} regular files reported clean on both hosts.
# /ntfy alone is the standalone ntfy client binary, not a bus component.
ALLOW='ntfy-bus.config.json|ntfy-inbox.jsonl|.bus-wake.log|.bus-wake.seen-ids|bus-wake-notify.sh|bus-waker.service|ntfy-bus.waker.pid|ntfy-bus.wake.log|ntfy-bus.seen-ids|/ntfy'
shadows=$(find "$HOME/.claude/bin" "$HOME/.claude/hooks" "$HOME/.local/bin" -maxdepth 1 \
  \( -type f -o -type l \) \
  \( -name '*bus-wak*' -o -name '*bus-monitor*' -o -name '*ntfy*' \) 2>/dev/null \
  | grep -vE "($ALLOW)$")
if [ -n "$shadows" ]; then
  printf 'DRIFT host-local bus code shadowing canonical (fold in or allowlist):\n%s\n' "$shadows"; warn=1
else
  ok "no host-local shadows of canonical components"
fi

exit "$warn"
