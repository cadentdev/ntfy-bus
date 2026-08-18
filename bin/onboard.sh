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
#   3. fence it instantly via .git/info/exclude (issue #23 — no PR to wait on)
#   4. wire BridgeBodyGuard ONCE, host-globally (issue #24)
#   5. install the durable poller where it can (macOS launchd via the skill's
#      installer); otherwise queue it as a human step
#   6. print the steps that still need a human, explicitly
#
# What it NEVER does: guess an identity, touch a locked host's config, commit
# anything, or arm a waker (arming must be a harness-tracked launch from a
# session — a script-armed waker cannot wake anyone; see hooks/arm-bus-waker.sh).
#
# NTFY_HOME overrides $HOME for testing (same contract as lib/resolve-config.sh).
set -u

AGENT="${1:?usage: onboard.sh <AgentName> [repo-path]}"
REPO_ARG="${2:-}"

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

# shellcheck source=skills/ntfy-bus/lib/resolve-config.sh
. "$SKILL/lib/resolve-config.sh" >/dev/null 2>&1

HOMEDIR="${NTFY_HOME:-$HOME}"
HG_CONFIG="$HOMEDIR/.claude/ntfy-bus.config.json"

say()  { printf '%s\n' "$*"; }
done_() { printf 'done  %s\n' "$*"; }
skip() { printf 'skip  %s (already done)\n' "$*"; }
fatal(){ printf 'FATAL %s\n' "$*" >&2; exit 1; }

# Human-step queue: everything the script cannot or must not do itself.
HUMAN_STEPS=""
human() { HUMAN_STEPS="${HUMAN_STEPS}  - $*
"; }

# --- 1. host guards: locked hosts never grow a repo identity -----------------
if ntfy_host_is_locked; then
  if [ -d "$HOMEDIR/.claude/PAI" ]; then
    fatal "this host is host-locked (LifeOS marker present) — a repo-local identity must not even be born here. The read-time guard would ignore it; this is the write-time half."
  fi
  fatal "this host has not opted into per-repo identity (per_repo_identity_allowed is not true in $HG_CONFIG). Run the Setup workflow first — it writes the host-global config interactively (endpoint, credentials), which this script deliberately never invents."
fi
[ -f "$HG_CONFIG" ] || fatal "no host-global config at $HG_CONFIG — run the Setup workflow first."

# --- resolve the target repo -------------------------------------------------
if [ -n "$REPO_ARG" ]; then
  TARGET=$(cd -P "$REPO_ARG" 2>/dev/null && pwd -P) || fatal "repo not found: $REPO_ARG"
else
  TARGET=$(git rev-parse --show-toplevel 2>/dev/null) || fatal "not inside a git repo and no repo-path given"
fi
git -C "$TARGET" rev-parse --show-toplevel >/dev/null 2>&1 || fatal "$TARGET is not a git work tree"
say "onboarding identity '$AGENT' into $TARGET"

AGENT_LC=$(printf '%s' "$AGENT" | tr '[:upper:]' '[:lower:]')
CFG="$TARGET/.claude/ntfy-bus.config.json"

# --- 2. repo-local identity config ------------------------------------------
if [ -f "$CFG" ]; then
  existing=$(jq -r '.agent_id // ""' "$CFG" 2>/dev/null)
  if [ "$existing" != "$AGENT" ]; then
    fatal "$CFG already carries identity '$existing' — refusing to overwrite one identity with another. Remove it first if that is really what you want."
  fi
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

# --- 3. instant fence (.git/info/exclude — issue #23) ------------------------
if git -C "$TARGET" ls-files --error-unmatch .claude/ntfy-bus.config.json >/dev/null 2>&1; then
  fatal "the identity config is TRACKED in $TARGET — every clone becomes this agent. Untrack it first: git -C \"$TARGET\" rm --cached .claude/ntfy-bus.config.json — and treat the identity as disclosed."
fi
EXCL="$(git -C "$TARGET" rev-parse --absolute-git-dir)/info/exclude"
if grep -qxF '.claude/ntfy-bus.config.json' "$EXCL" 2>/dev/null; then
  skip "identity fence in .git/info/exclude"
else
  mkdir -p "$(dirname "$EXCL")"
  echo '.claude/ntfy-bus.config.json' >> "$EXCL"
  done_ "identity fenced via .git/info/exclude (instant, this clone)"
fi
if ! grep -qxF '.claude/ntfy-bus.config.json' "$TARGET/.gitignore" 2>/dev/null; then
  human "add '.claude/ntfy-bus.config.json' to the tracked .gitignore (PR on protected repos) — protects every OTHER clone's contributor; this clone is already fenced"
fi

# --- 4. BridgeBodyGuard, host-global, once (issue #24) -----------------------
SETTINGS="$HOMEDIR/.claude/settings.json"
if grep -q 'BridgeBodyGuard' "$SETTINGS" 2>/dev/null; then
  skip "BridgeBodyGuard wired host-globally"
else
  BUN="$(command -v bun || echo "$HOMEDIR/.bun/bin/bun")"
  HOOK_CMD="${BUN} ${HOMEDIR}/.claude/skills/ntfy-bus/hooks/BridgeBodyGuard.hook.ts"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  tmp=$(mktemp)
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

# --- 5. durable poller (per identity) ----------------------------------------
POLL_INSTALL="$HOMEDIR/.claude/skills/ntfy-bus/bin/ntfy-poll-install.sh"
case "$(uname -s)" in
  Darwin)
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
    ;;
  *)
    human "install the durable poller: systemd/ntfy-poll.{service,timer} with NTFY_POLL_REPO=$TARGET and EXPECT_AGENT=$AGENT (see the templates' headers)"
    ;;
esac

# --- 6. what only a session or a human can finish ----------------------------
human "arm the session waker from a Claude session in $TARGET (harness-tracked: run daemons/ntfy-bus-waker.sh with run_in_background) — a script-armed waker cannot wake anyone"
human "smoke-test per Setup step 7 (capture) and 7b (wake path — external sender), then finish with a green bin/doctor.sh run from this repo"

say ""
say "Steps that still need a human:"
printf '%s' "$HUMAN_STEPS"
exit 0
