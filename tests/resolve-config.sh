#!/usr/bin/env bash
# tests/resolve-config.sh — regression tests for lib/resolve-config.sh.
#
# The host-lock guard is a SECURITY PROPERTY (repo CLAUDE.md carve-out):
# default polarity is LOCKED, and both fail-safe branches (missing config,
# malformed config) must stay locked. Each case re-sources the resolver in a
# subshell with a scratch NTFY_HOME, exactly how consumers load it.
set -u
. "$(dirname "$0")/lib/harness.sh"
RESOLVER="$SKILL_ROOT/lib/resolve-config.sh"

# Run CODE in a subshell with the resolver freshly sourced against $ROOT.
# CLAUDE_PROJECT_DIR is cleared unless the case sets it — the surrounding
# real repo must never leak into a case.
in_env() { ( export NTFY_HOME="$ROOT"; unset CLAUDE_PROJECT_DIR; cd /; . "$RESOLVER" >/dev/null 2>&1; eval "$1" ); }

echo "L1: fresh host with a plain config is LOCKED (default-safe polarity)"
new_env
assert_true  "locked by default"          in_env 'ntfy_host_is_locked'
assert_eq    "NTFY_HOST_LOCKED=1" "1"     "$(in_env 'printf %s "$NTFY_HOST_LOCKED"')"
assert_eq    "source is host-global" "host-global" "$(in_env 'printf %s "$NTFY_IDENTITY_SOURCE"')"
cleanup

echo "L2: no config at all is LOCKED"
new_env; rm -f "$ROOT/.claude/ntfy-bus.config.json"
assert_true  "locked with no config"      in_env 'ntfy_host_is_locked'
cleanup

echo "L3: malformed config is LOCKED (fail-safe) and says so"
new_env; echo '{ not json' > "$ROOT/.claude/ntfy-bus.config.json"
assert_true  "locked on malformed config" in_env 'ntfy_host_is_locked'
warn=$( ( export NTFY_HOME="$ROOT"; . "$RESOLVER" >/dev/null; ntfy_host_is_locked 2>&1 >/dev/null ) )
case "$warn" in
  *"treating host as locked"*) pass "operator warning emitted" ;;
  *) fail "operator warning emitted (got: '$warn')" ;;
esac
cleanup

echo "L4: PAI marker forces LOCKED even with explicit opt-in"
new_env
jq '.per_repo_identity_allowed = true' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
mkdir -p "$ROOT/.claude/PAI"
assert_true  "PAI marker wins over opt-in" in_env 'ntfy_host_is_locked'
cleanup

echo "L5: explicit opt-in on a vanilla host UNLOCKS"
new_env
jq '.per_repo_identity_allowed = true' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
assert_false "opt-in unlocks"             in_env 'ntfy_host_is_locked'
cleanup

echo "L6: unlocked host prefers a repo-local identity; locked host IGNORES it"
new_env
mkdir -p "$ROOT/fakerepo/.claude"
echo '{ "agent_id": "RepoAgent" }' > "$ROOT/fakerepo/.claude/ntfy-bus.config.json"
with_repo() { ( export NTFY_HOME="$ROOT" CLAUDE_PROJECT_DIR="$ROOT/fakerepo"; cd /; . "$RESOLVER" >/dev/null 2>&1; eval "$1" ); }
# still locked (no opt-in): repo-local must be ignored
assert_eq "locked: repo-local ignored" "host-global" "$(with_repo 'printf %s "$NTFY_IDENTITY_SOURCE"')"
jq '.per_repo_identity_allowed = true' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
assert_eq "unlocked: repo-local preferred" "repo-local" "$(with_repo 'printf %s "$NTFY_IDENTITY_SOURCE"')"
assert_eq "unlocked: repo-local path" "$ROOT/fakerepo/.claude/ntfy-bus.config.json" "$(with_repo 'printf %s "$NTFY_CONFIG"')"
# opt-in, IN a repo, but no repo-local config -> UNRESOLVED, never host-global.
# Falling back here is the identity-hijack-by-omission this repo hit once.
rm "$ROOT/fakerepo/.claude/ntfy-bus.config.json"
assert_eq "unlocked, no repo config: unresolved" "none" "$(with_repo 'printf %s "$NTFY_IDENTITY_SOURCE"')"
assert_eq "unlocked, no repo config: empty config path" "" "$(with_repo 'printf %s "$NTFY_CONFIG"')"
# ...but OUTSIDE any repo, in EXPLICIT daemon context (NTFY_DAEMON_CONTEXT=1,
# set by the shipped unit templates) host-global is still the answer, silently
# — else durable notification dies on every opt-in host. WITHOUT the marker
# this release warns-and-allows (issue #9 migration, phase 1); the flip to
# refuse re-points these assertions.
no_repo() { ( export NTFY_HOME="$ROOT"; unset CLAUDE_PROJECT_DIR NTFY_DAEMON_CONTEXT; cd "$ROOT/norepo"; . "$RESOLVER" >/dev/null 2>&1; eval "$1" ); }
as_daemon() { ( export NTFY_HOME="$ROOT" NTFY_DAEMON_CONTEXT=1; unset CLAUDE_PROJECT_DIR; cd "$ROOT/norepo"; . "$RESOLVER" >/dev/null 2>&1; eval "$1" ); }
mkdir -p "$ROOT/norepo"
assert_eq "unlocked, marked daemon, no repo: host-global" "host-global" "$(as_daemon 'printf %s "$NTFY_IDENTITY_SOURCE"')"
marked_err=$( ( export NTFY_HOME="$ROOT" NTFY_DAEMON_CONTEXT=1; unset CLAUDE_PROJECT_DIR; cd "$ROOT/norepo"; . "$RESOLVER" 2>&1 >/dev/null ) )
case "$marked_err" in
  *WARNING*) fail "marked daemon resolves silently (got: '$marked_err')" ;;
  *) pass "marked daemon resolves silently" ;;
esac
assert_eq "unlocked, UNMARKED, no repo: still host-global (phase 1)" "host-global" "$(no_repo 'printf %s "$NTFY_IDENTITY_SOURCE"')"
unmarked_err=$( ( export NTFY_HOME="$ROOT"; unset CLAUDE_PROJECT_DIR NTFY_DAEMON_CONTEXT; cd "$ROOT/norepo"; . "$RESOLVER" 2>&1 >/dev/null ) )
case "$unmarked_err" in
  *"NTFY_DAEMON_CONTEXT"*) pass "unmarked resolution warns, naming the marker" ;;
  *) fail "unmarked resolution warns, naming the marker (got: '$unmarked_err')" ;;
esac
cleanup

echo "L7: ntfy_expand_home"
new_env
assert_eq "bare ~"        "$ROOT"       "$(in_env 'ntfy_expand_home "~"')"
assert_eq "~/x"           "$ROOT/x/y"   "$(in_env 'ntfy_expand_home "~/x/y"')"
assert_eq "absolute untouched" "/a/b"   "$(in_env 'ntfy_expand_home "/a/b"')"
assert_eq "~user unsupported, untouched" "~other/x" "$(in_env 'ntfy_expand_home "~other/x"')"
cleanup

echo "L8: ntfy_require_config refuses an unresolved identity, loudly (issue #8)"
new_env
jq '.per_repo_identity_allowed = true' "$ROOT/.claude/ntfy-bus.config.json" > "$ROOT/c" \
  && mv "$ROOT/c" "$ROOT/.claude/ntfy-bus.config.json"
mkdir -p "$ROOT/fakerepo"
req() { ( export NTFY_HOME="$ROOT" CLAUDE_PROJECT_DIR="$ROOT/fakerepo"; cd /; . "$RESOLVER" >/dev/null 2>&1; ntfy_require_config ); }
# opt-in host, in a repo with no identity config: source none -> gate refuses
assert_false "gate refuses source=none"  req
gate_err=$( req 2>&1 >/dev/null ) || true
case "$gate_err" in
  *"refusing to act on the bus"*) pass "gate says why, on stderr" ;;
  *) fail "gate says why, on stderr (got: '$gate_err')" ;;
esac
# resolved identity (host-global, outside any repo) -> gate passes
assert_true  "gate passes when resolved" in_env 'ntfy_require_config'
cleanup

finish
