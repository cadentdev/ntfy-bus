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
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'DRIFT %s\n' "$*"; warn=1; }
# A finding worth acting on that must not fail the run (exit stays healthy).
note() { printf 'warn  %s\n' "$*"; }

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
# ~/.local/bin is scanned WITH -L: both symlinked ENTRIES (a stow-managed shadow
# script) and a symlinked START POINT (a stow-managed ~/.local/bin itself) must
# be followed — without -L, find treats a symlinked root as a symlink, never
# descends, and reports a false all-clear on exactly the tidier dotfiles hosts
# (issue #13). -maxdepth 1 bounds the traversal, so the usual -L cycle concern
# does not apply; a broken symlink is still -type l under -L, so broken-link
# shadows still surface.
# /ntfy alone is the standalone ntfy client binary, not a bus component.
ALLOW='ntfy-bus.config.json|ntfy-inbox.jsonl|.bus-wake.log|.bus-wake.seen-ids|bus-wake-notify.sh|bus-waker.service|ntfy-bus.waker.pid|ntfy-bus.wake.log|ntfy-bus.seen-ids|/ntfy'
shadows=$(find -L "$HOME/.claude/bin" "$HOME/.claude/hooks" "$HOME/.local/bin" -maxdepth 1 \
  \( -type f -o -type l \) \
  \( -name '*bus-wak*' -o -name '*bus-monitor*' -o -name '*ntfy*' \) 2>/dev/null \
  | grep -vE "($ALLOW)$")
if [ -n "$shadows" ]; then
  printf 'DRIFT host-local bus code shadowing canonical (fold in or allowlist):\n%s\n' "$shadows"; warn=1
else
  ok "no host-local shadows of canonical components"
fi

# 5. tracking state of the identity config in the repo doctor is run FROM.
# A tracked .claude/ntfy-bus.config.json ships a live fleet identity to
# everyone who clones — the first clone to run a workflow sends and arms wakers
# AS that agent. check.sh section 7 guards only the canonical repo; identity
# configs live in OTHER repos by design, and this host probe is what reaches
# them (issue #19). git-guarded: outside a work tree there is no tracking state
# to check, and a config there is legitimately just a file (see #9 — the
# not-a-git-repo case is load-bearing on this fleet). Ignore state comes from
# `git check-ignore -v`, not a .gitignore grep: the rule may live in a GLOBAL
# ignore file, which protects this machine and NOT a fresh clone — so the
# report names where the rule came from.
cwd_repo=$(git rev-parse --show-toplevel 2>/dev/null) || cwd_repo=""
if [ -n "$cwd_repo" ] && [ -f "$cwd_repo/.claude/ntfy-bus.config.json" ]; then
  rel=".claude/ntfy-bus.config.json"
  if git -C "$cwd_repo" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    bad "identity config is TRACKED in $cwd_repo — every clone becomes this agent. Untrack it (git -C \"$cwd_repo\" rm --cached $rel), add an ignore rule, and treat the identity as disclosed to anyone with clone access (rotating the agent name is the conservative move)."
  elif rule=$(git -C "$cwd_repo" check-ignore -v "$rel" 2>/dev/null); then
    ok "identity config untracked + ignored (rule: ${rule%%	*})"
  else
    note "identity config in $cwd_repo is untracked but NOT ignored — one 'git add .' away from tracked. Add $rel to $cwd_repo/.git/info/exclude (instant, this clone) and consider a tracked .gitignore entry (protects every clone)."
  fi
fi

exit "$warn"
