# shellcheck shell=bash
# lib/resolve-config.sh — shared identity-config resolver for all ntfy-bus workflows.
#
# Source this file, then use "$NTFY_CONFIG" as the config path. It also exports
# NTFY_HOST_LOCKED (1/0) and NTFY_IDENTITY_SOURCE (host-global|repo-local|none).
# Callers MUST treat an empty "$NTFY_CONFIG" (source "none") as unconfigured and
# refuse to act on the bus — never substitute an identity of their own.
#
# Send, CheckInbox, Watch, and Setup ALL go through this one resolver — identity
# resolution is never duplicated per-workflow.
#
# Identity resolution + host-lock guard
# (ratified on the bus 2026-06-13):
#
#   HOST-LOCKED (LifeOS):  ~/.claude/PAI/ exists, OR the host-global config does
#                       NOT set  per_repo_identity_allowed: true.
#                       -> ALWAYS the host-global config. Any repo-local
#                          identity config is IGNORED. This read-time guard
#                          stops the silent send-as-<other-agent> identity
#                          hijack that would otherwise happen the first time a
#                          LifeOS host clones + runs an identity-bearing repo.
#
#   VANILLA opt-in:     no ~/.claude/PAI/  AND the host-global config sets
#                       per_repo_identity_allowed: true.
#                       -> the repo-local .claude/ntfy-bus.config.json IS the
#                          identity. A repo without one resolves to NOTHING
#                          (source "none", empty NTFY_CONFIG) — there is no
#                          host-global fallback inside a repo, because falling
#                          back means acting as an agent this repo never named.
#                          Outside any repo the host-global config is used ONLY
#                          in explicit daemon context (NTFY_DAEMON_CONTEXT=1,
#                          set by the shipped unit templates); without the
#                          marker this release warns-and-allows, and a future
#                          release refuses (issue #9 migration).
#
# Default-safe polarity: the secure state (locked) is the default; per-repo
# identity is an explicit opt-in. A fresh, never-reconfigured host is locked.
#
# NTFY_HOME overrides $HOME for testing.

_ntfy_home="${NTFY_HOME:-$HOME}"

# Expand a leading "~" / "~/" in a config-supplied path (JSON can't; systemd
# Environment= quoting mangles it). "~user/..." is NOT supported — configs for
# other users' homes must be absolute. ONE home for this logic: the daemon,
# statusline, capabilities probe, and workflow snippets all call this — never
# inline your own expansion (a comment is not a gate; a shared function is).
ntfy_expand_home() {
  case "$1" in
    "~")   printf '%s' "$_ntfy_home" ;;
    "~/"*) printf '%s/%s' "$_ntfy_home" "${1#\~/}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# Return 0 (true) if this host is locked to its host-global identity.
ntfy_host_is_locked() {
  # LifeOS marker present => locked, regardless of config contents. (The
  # marker directory is still literally named PAI — LifeOS's former brand.)
  [ -d "${_ntfy_home}/.claude/PAI" ] && return 0
  # Otherwise locked unless the host-global config explicitly opts in.
  local hg="${_ntfy_home}/.claude/ntfy-bus.config.json"
  local optin="false"
  if [ -f "$hg" ]; then
    # A malformed/unreadable config must stay safe (locked), but say so —
    # otherwise the operator gets a silently-locked host with no clue why.
    if ! optin=$(jq -r '.per_repo_identity_allowed // false' "$hg" 2>/dev/null); then
      echo "ntfy resolve-config: host-global config unreadable, treating host as locked" >&2
      optin="false"
    fi
  fi
  [ "$optin" = "true" ] && return 1   # opted in => NOT locked
  return 0                            # default => locked
}

# WHY a host is locked, for callers that must explain a refusal (onboard.sh).
# One place answers, so no caller re-probes the marker directory inline and
# drifts when its (legacy) name changes. Prints one of:
#   pai-marker | no-config | no-optin | unlocked
ntfy_lock_reason() {
  if [ -d "${_ntfy_home}/.claude/PAI" ]; then printf 'pai-marker'
  elif [ ! -f "${_ntfy_home}/.claude/ntfy-bus.config.json" ]; then printf 'no-config'
  elif ntfy_host_is_locked; then printf 'no-optin'
  else printf 'unlocked'
  fi
  return 0
}

# Resolve the config path for the current host + repo into NTFY_CONFIG.
ntfy_resolve_config() {
  local host_global="${_ntfy_home}/.claude/ntfy-bus.config.json"

  if ntfy_host_is_locked; then
    NTFY_HOST_LOCKED=1
    NTFY_IDENTITY_SOURCE="host-global"
    NTFY_CONFIG="$host_global"
    export NTFY_HOST_LOCKED NTFY_IDENTITY_SOURCE NTFY_CONFIG
    return 0
  fi

  NTFY_HOST_LOCKED=0

  # Vanilla + opt-in: prefer repo-local identity. Find the repo root via the
  # Claude Code project dir, else the surrounding git work tree.
  # set-e-safe: callers like the poller source this with `set -e` active, and a
  # bare failing `x=$(git ...)` at the tail of an && list would abort them.
  local repo_root="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$repo_root" ]; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
  fi

  local repo_cfg=""
  [ -n "$repo_root" ] && repo_cfg="${repo_root}/.claude/ntfy-bus.config.json"

  if [ -n "$repo_cfg" ] && [ -f "$repo_cfg" ]; then
    NTFY_IDENTITY_SOURCE="repo-local"
    NTFY_CONFIG="$repo_cfg"
  elif [ -n "$repo_root" ]; then
    # In a repo, on a host that opted into per-repo identity, but this repo
    # carries no identity: that is UNCONFIGURED, not "use the host's agent".
    # There is deliberately NO host-global fallback here — falling back silently
    # arms and sends as whichever agent the host happens to own, which is an
    # identity hijack by omission (the Cindy incident, 2026-08-08: a session in
    # a config-less repo armed a waker as a live agent and began consuming that
    # agent's wake ledger). Unresolved is loud and harmless; wrong is silent
    # and not.
    NTFY_IDENTITY_SOURCE="none"
    NTFY_CONFIG=""
    echo "ntfy resolve-config: opt-in host, but ${repo_root} has no .claude/ntfy-bus.config.json — identity UNRESOLVED (no host-global fallback by design). Run the Setup workflow to give this repo an identity." >&2
  else
    # No repo context at all. This branch is what keeps durable notification
    # alive on opt-in hosts (bus-waker.service sets no WorkingDirectory) — but
    # "no repo context" is NOT the same thing as "daemon context": an ordinary
    # interactive session crosses this boundary with a single `cd /tmp`, and
    # would then silently resolve as the host's agent — the exact substitution
    # PR #7 was written to eliminate (issue #9). Daemon context is therefore
    # EXPLICIT: the shipped unit templates set NTFY_DAEMON_CONTEXT=1, and only
    # that marker makes the host-global answer silent here.
    #
    # MIGRATION (issue #9, phase 1 of 2): hosts carry their own installed unit
    # copies, so a marker-less daemon must not break silently — this release
    # WARNS and still resolves host-global. A future release flips this branch
    # to refuse (source "none") without the marker, exactly as the in-repo
    # unconfigured case already does.
    NTFY_IDENTITY_SOURCE="host-global"
    NTFY_CONFIG="$host_global"
    if [ "${NTFY_DAEMON_CONTEXT:-}" != "1" ]; then
      echo "ntfy resolve-config: WARNING — resolved the HOST-GLOBAL identity outside any git work tree without NTFY_DAEMON_CONTEXT=1. If this is a daemon, update its installed unit file (the shipped templates now set the marker); if this is an interactive session, cd into the repo whose identity you mean — a future release will refuse to resolve here." >&2
    fi
  fi
  export NTFY_HOST_LOCKED NTFY_IDENTITY_SOURCE NTFY_CONFIG
  return 0
}

# Waker pidfile resolution — the ONE definition of both conventions (issue
# #27). TWO pidfiles exist BY DESIGN, because they are two different JOBS, not
# two spellings of one fact: the SESSION waker (harness-tracked, wake-capable,
# daemons/ntfy-bus-waker.sh) derives its pidfile from the configured inbox;
# the DURABLE daemon (notify-only, daemons/bus-waker-daemon.sh) claims
# .waker.pidfile from config. They may run simultaneously — that is the
# documented healthy pair — so they must never share a file. Every reader asks
# about the job it means, through these helpers, or both when the question is
# "is anything watching this identity".
ntfy_session_pidfile() { # $1 = EXPANDED inbox path -> the session waker's pidfile
  printf '%s' "${1%.jsonl}.waker.pid"
}
ntfy_daemon_pidfile() { # $1 = config path -> the daemon's pidfile; empty = not configured
  local p
  p=$(jq -r '.waker.pidfile // ""' "$1" 2>/dev/null) || p=""
  [ -n "$p" ] && ntfy_expand_home "$p"
  return 0
}

# Caller-side gate for the contract above (issue #8): anything about to ACT on
# the bus calls this immediately after sourcing and STOPS on failure — never
# substitutes an identity of its own. The resolver declining to guess is only
# half the fix; a caller that proceeds with four empty variables ends up in
# exactly the position that produced the original incident, where the most
# plausible "repair" is supplying an identity from somewhere else. A comment is
# not a gate; this is (pairing enforced by bin/check.sh section 8).
ntfy_require_config() {
  if [ -z "${NTFY_CONFIG:-}" ] || [ ! -f "${NTFY_CONFIG:-}" ]; then
    echo "ntfy-bus: identity UNRESOLVED (source: ${NTFY_IDENTITY_SOURCE:-none}) — refusing to act on the bus. Do NOT substitute or guess an identity; run the Setup workflow to configure one for this context." >&2
    return 1
  fi
  return 0
}

# Auto-resolve when sourced so callers can use "$NTFY_CONFIG" immediately.
ntfy_resolve_config
