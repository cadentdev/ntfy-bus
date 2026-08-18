#!/bin/bash
# bin/onboard.sh — one idempotent command for the mechanical half of onboarding
# a repo onto the bus (issue #21; the operator's standing preference is logic
# in scripts, not specs re-interpreted per session — which is how steps got
# dropped during the seven-step manual onboarding this replaces).
#
# Usage: onboard.sh <AgentName> [repo-path]     (repo-path defaults to cwd's repo)
#
# What it DOES (skipping anything already done — every step is idempotent):
#   1. refuse cleanly on host-locked hosts (write-time half of the hijack
#      guard, same as Setup step 6) and on hosts that never opted in
#   2. write the repo-local identity config, copying the fleet settings
#      (endpoint, topic, auth env names) from the host-global config
#   3. fence it instantly via the repo's local exclude file (issue #23 — no
#      PR to wait on)
#   4. wire BridgeBodyGuard ONCE, host-globally (issue #24)
#   5. install the durable poller where the host has a scheduler for it;
#      otherwise queue it as a human step
#   6. print the steps that still need a human, explicitly
#
# What it NEVER does: guess an identity, touch a locked host's config, commit
# anything, or arm a waker (arming must be a harness-tracked launch from a
# session — a script-armed waker cannot wake anyone; see hooks/arm-bus-waker.sh).
#
# NTFY_HOME overrides $HOME for testing (same contract as lib/resolve-config.sh).
set -u

say()  { printf '%s\n' "$*"; }
done_() { printf 'done  %s\n' "$*"; }
skip() { printf 'skip  %s (already done)\n' "$*"; }
fatal(){ printf 'FATAL %s\n' "$*" >&2; exit 1; }

AGENT="${1:?usage: onboard.sh <AgentName> [repo-path]}"
REPO_ARG="${2:-}"

# The name lands in a filename, a launchd plist label, and the installer's sed
# — validate the shape before any of them see it, and reserve the broadcast
# address (an agent named ALL would receive everything and answer as everyone).
case "$AGENT" in
  ''|*[!A-Za-z0-9_-]*) fatal "agent name must be letters/digits/_/- only (got: '$AGENT')" ;;
esac
case "$(printf '%s' "$AGENT" | tr '[:lower:]' '[:upper:]')" in
  ALL) fatal "'ALL' is the reserved broadcast address, not an agent identity" ;;
esac

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
SKILL="$REPO/skills/ntfy-bus"

# The host-lock refusal below is a SECURITY guard — it must fail CLOSED. A
# silently-failed source would leave ntfy_host_is_locked undefined and the
# `if` would fall through to the unlocked branch (command-not-found is falsy),
# so both the source and the function's presence are checked loudly.
# shellcheck source=skills/ntfy-bus/lib/resolve-config.sh
. "$SKILL/lib/resolve-config.sh" >/dev/null 2>&1 \
  || fatal "cannot source $SKILL/lib/resolve-config.sh — run onboard.sh from a full clone (bin/ and skills/ side by side)"
type ntfy_host_is_locked >/dev/null 2>&1 && type ntfy_lock_reason >/dev/null 2>&1 \
  || fatal "resolver lib loaded but incomplete ($SKILL/lib/resolve-config.sh) — the clone is stale or corrupted"
# shellcheck source=skills/ntfy-bus/lib/capabilities.sh
. "$SKILL/lib/capabilities.sh" >/dev/null 2>&1 \
  || fatal "cannot source $SKILL/lib/capabilities.sh"

HOMEDIR="${NTFY_HOME:-$HOME}"
HG_CONFIG="$HOMEDIR/.claude/ntfy-bus.config.json"

# Human-step queue: everything the script cannot or must not do itself.
HUMAN_STEPS=""
human() { HUMAN_STEPS="${HUMAN_STEPS}  - $*
"; }

# --- 1. host guards: locked hosts never grow a repo identity -----------------
# One flat guard per lock reason, each message matching its actual trigger.
# The reason comes from the lib (single source of truth for the marker's name
# and the opt-in rule) — never re-probed inline here.
case "$(ntfy_lock_reason)" in
  pai-marker)
    fatal "this host is host-locked (LifeOS marker present) — a repo-local identity must not even be born here. The read-time guard would ignore it; this is the write-time half." ;;
  no-config)
    fatal "no host-global config at $HG_CONFIG — run the Setup workflow first; it writes the fleet settings (endpoint, credentials) interactively, which this script deliberately never invents." ;;
  no-optin)
    fatal "this host has not opted into per-repo identity (per_repo_identity_allowed is not true in $HG_CONFIG). Run the Setup workflow first if per-repo identity is really what you want." ;;
  unlocked) : ;;
  *) fatal "unrecognized lock state — refusing (fail closed)" ;;
esac

# --- resolve the target repo (always normalized to the git TOPLEVEL: the
# resolver only ever reads <toplevel>/.claude/, so a subdirectory target would
# produce a config no session can resolve and a fence that matches nothing) ---
TARGET=$(git -C "${REPO_ARG:-.}" rev-parse --show-toplevel 2>/dev/null) \
  || fatal "${REPO_ARG:-$PWD} is not inside a git work tree"
say "onboarding identity '$AGENT' into $TARGET"

AGENT_LC=$(printf '%s' "$AGENT" | tr '[:upper:]' '[:lower:]')
CFG="$TARGET/.claude/ntfy-bus.config.json"
REL_CFG=".claude/ntfy-bus.config.json"

# --- 2. tracked-config guard, BEFORE anything is written: a tracked path can
# be tracked with the working copy deleted, and writing first would put the
# fresh identity INTO the tracked file ahead of the refusal ------------------
if git -C "$TARGET" ls-files --error-unmatch "$REL_CFG" >/dev/null 2>&1; then
  fatal "the identity config is TRACKED in $TARGET — every clone becomes this agent. Untrack it first: git -C \"$TARGET\" rm --cached $REL_CFG — and treat the identity as disclosed."
fi

# --- 3. repo-local identity config ------------------------------------------
require_cfg_keys() { # $1 = config path; the same keys the fresh-write path guarantees
  jq -e '.agent_id and .endpoint and .topic and .auth_env and .inbox_jsonl' "$1" >/dev/null 2>&1
}
if [ -f "$CFG" ]; then
  existing=$(jq -r '.agent_id // ""' "$CFG" 2>/dev/null)
  if [ "$existing" != "$AGENT" ]; then
    fatal "$CFG already carries identity '$existing' — refusing to overwrite one identity with another. Remove it first if that is really what you want."
  fi
  # A matching name is not an onboarded config: an incomplete file (no fleet
  # settings, no inbox) would be certified 'done' here and fail loud later in
  # the poller instead. Same bar as the fresh-write path.
  require_cfg_keys "$CFG" \
    || fatal "$CFG carries '$AGENT' but is missing required keys (endpoint/topic/auth_env/inbox_jsonl) — repair or remove it, then re-run"
  skip "repo-local identity config ($existing)"
else
  # Fleet settings come from the host-global config — the one interactive
  # source of truth Setup wrote. This script copies, never invents.
  fleet=$(jq -c '{endpoint, topic, auth_env}' "$HG_CONFIG" 2>/dev/null) \
    || fatal "cannot read fleet settings (endpoint/topic/auth_env) from $HG_CONFIG"
  jq -e '.endpoint and .topic and .auth_env' >/dev/null 2>&1 <<<"$fleet" \
    || fatal "$HG_CONFIG is missing endpoint/topic/auth_env — run the Setup workflow"
  mkdir -p "$TARGET/.claude"
  # The per-identity inbox path is a config VALUE this writer authors once —
  # the same value Setup step 6a writes — not a runtime default; consumers
  # still fail loud if it is ever absent.
  jq -n --argjson fleet "$fleet" --arg agent "$AGENT" --arg inbox "~/.claude/ntfy-inbox.${AGENT_LC}.jsonl" '  # gate-literal
    $fleet + { agent_id: $agent, recipient_filters: [$agent, "ALL"], inbox_jsonl: $inbox }' > "$CFG" \
    || fatal "could not write $CFG"
  chmod 600 "$CFG"
  done_ "repo-local identity config written ($AGENT)"
fi

# --- 4. instant fence (local exclude — issue #23) ----------------------------
# --git-path, not --absolute-git-dir: in a LINKED WORKTREE the git dir is
# .git/worktrees/<name>/, whose info/exclude git never reads — the fence must
# land in the COMMON dir's exclude, and --git-path resolves that correctly.
EXCL=$(git -C "$TARGET" rev-parse --git-path info/exclude)
case "$EXCL" in /*) ;; *) EXCL="$TARGET/$EXCL" ;; esac
if grep -qxF "$REL_CFG" "$EXCL" 2>/dev/null; then
  skip "identity fence in the repo's local exclude"
else
  mkdir -p "$(dirname "$EXCL")"
  echo "$REL_CFG" >> "$EXCL"
  git -C "$TARGET" check-ignore -q "$REL_CFG" \
    || fatal "wrote the fence to $EXCL but git still does not ignore $REL_CFG — investigate before the identity leaks into a commit"
  done_ "identity fenced via the repo's local exclude (instant, this clone)"
fi
if ! grep -qxF "$REL_CFG" "$TARGET/.gitignore" 2>/dev/null; then
  human "add '$REL_CFG' to the tracked .gitignore (PR on protected repos) — protects every OTHER clone's contributor; this clone is already fenced"
fi

# --- 5. BridgeBodyGuard, host-global, once (issue #24) -----------------------
SETTINGS="$HOMEDIR/.claude/settings.json"
HOOK_TS="$HOMEDIR/.claude/skills/ntfy-bus/hooks/BridgeBodyGuard.hook.ts"
if grep -q 'BridgeBodyGuard' "$SETTINGS" 2>/dev/null; then
  skip "BridgeBodyGuard wired host-globally"
else
  BUN="$(command -v bun || echo "$HOMEDIR/.bun/bin/bun")"
  # Verify BOTH ends before wiring: a host-global PreToolUse hook pointing at
  # a missing interpreter or missing file fails on every Bash call in every
  # session, while the byte-cap guard is silently absent — and the grep skip
  # above would keep the broken entry forever.
  if [ ! -f "$HOOK_TS" ] || [ ! -x "$BUN" ]; then
    human "wire BridgeBodyGuard host-globally once bun and the installed skill exist (missing: $( [ -f "$HOOK_TS" ] || printf '%s ' "$HOOK_TS"; [ -x "$BUN" ] || printf '%s' 'bun' )) — settings.json PreToolUse/Bash: <bun> $HOOK_TS"
  else
    HOOK_CMD="${BUN} ${HOOK_TS}"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    tmp=$(mktemp "${SETTINGS}.XXXXXX")
    if jq --arg cmd "$HOOK_CMD" '
        .hooks //= {} | .hooks.PreToolUse //= [] |
        if any(.hooks.PreToolUse[]?; any(.hooks[]?; .command == $cmd))
        then . else .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":$cmd}]}] end
      ' "$SETTINGS" > "$tmp" 2>/dev/null && mv "$tmp" "$SETTINGS"; then
      done_ "BridgeBodyGuard wired host-globally in $SETTINGS"
    else
      rm -f "$tmp"
      human "wire BridgeBodyGuard in $SETTINGS (PreToolUse/Bash): $HOOK_CMD"
    fi
  fi
fi

# --- 6. durable poller (per identity) ----------------------------------------
# Branch on CAPABILITIES (lib/capabilities.sh), never host class — the doctrine
# exception is the identity lock only. launchd is probed the same way
# capabilities probes systemd: by the tool that would run the unit.
POLL_INSTALL="$HOMEDIR/.claude/skills/ntfy-bus/bin/ntfy-poll-install.sh"
if [ "${NTFY_HAS_SYSTEMD:-0}" = "1" ]; then
  human "install the durable poller: systemd/ntfy-poll.{service,timer} with NTFY_POLL_REPO=$TARGET and EXPECT_AGENT=$AGENT (see the templates' headers)"
elif command -v launchctl >/dev/null 2>&1; then
  if ls "$HOMEDIR/Library/LaunchAgents"/*.ntfy-poll."$AGENT_LC".plist >/dev/null 2>&1; then
    skip "durable poller scheduled for $AGENT_LC"
  elif [ -x "$POLL_INSTALL" ]; then
    if "$POLL_INSTALL" "$AGENT_LC" "$TARGET"; then
      done_ "durable poller installed (launchd)"
    else
      human "poller install failed — rerun: $POLL_INSTALL $AGENT_LC $TARGET"
    fi
  else
    human "install the skill at ~/.claude/skills/ntfy-bus, then run: skills/ntfy-bus/bin/ntfy-poll-install.sh $AGENT_LC $TARGET"
  fi
else
  human "no systemd or launchd detected — schedule daemons/ntfy-poll-to-jsonl.sh yourself (cron: see the poller's header; NTFY_POLL_REPO=$TARGET EXPECT_AGENT=$AGENT)"
fi

# --- 7. what only a session or a human can finish ----------------------------
human "arm the session waker from a Claude session in $TARGET (harness-tracked: run daemons/ntfy-bus-waker.sh with run_in_background) — a script-armed waker cannot wake anyone"
human "smoke-test per Setup step 7 (capture) and 7b (wake path — external sender), then finish with a green bin/doctor.sh run from this repo"

say ""
say "Steps that still need a human:"
printf '%s' "$HUMAN_STEPS"
exit 0
