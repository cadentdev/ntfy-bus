# shellcheck shell=bash
# lib/resolve-config.sh — shared identity-config resolver for all ntfy-bus workflows.
#
# Source this file, then use "$NTFY_CONFIG" as the config path. It also exports
# NTFY_HOST_LOCKED (1/0) and NTFY_IDENTITY_SOURCE (host-global|repo-local).
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
#                       -> prefer the repo-local .claude/ntfy-bus.config.json,
#                          fall back to the host-global config.
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
  local repo_root="${CLAUDE_PROJECT_DIR:-}"
  [ -z "$repo_root" ] && repo_root=$(git rev-parse --show-toplevel 2>/dev/null)

  local repo_cfg=""
  [ -n "$repo_root" ] && repo_cfg="${repo_root}/.claude/ntfy-bus.config.json"

  if [ -n "$repo_cfg" ] && [ -f "$repo_cfg" ]; then
    NTFY_IDENTITY_SOURCE="repo-local"
    NTFY_CONFIG="$repo_cfg"
  else
    NTFY_IDENTITY_SOURCE="host-global"
    NTFY_CONFIG="$host_global"
  fi
  export NTFY_HOST_LOCKED NTFY_IDENTITY_SOURCE NTFY_CONFIG
  return 0
}

# Auto-resolve when sourced so callers can use "$NTFY_CONFIG" immediately.
ntfy_resolve_config
