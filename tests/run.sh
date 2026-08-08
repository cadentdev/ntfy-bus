#!/usr/bin/env bash
# tests/run.sh — the single "run the tests" entry point.
#
# Discovers and runs every tests/*.sh suite (tests/lib/ is helpers, not
# suites), aggregates results, exits non-zero if any suite fails. A suite
# exiting 2 is a SKIP (missing dependency) — reported, not a failure.
#
# Hermetic: suites build throwaway $NTFY_HOME envs and the scripts under test
# resolve their libs self-relatively, so a fresh clone runs this with only
# bash + jq. No live bus, no network, no credentials, no installed skill.
#
# This sits BESIDE bin/check.sh (portability lint), it does not replace it:
# check.sh answers "is the code portable/doctrine-clean", run.sh answers
# "does it behave".
#
# Deferred by decision, not oversight: capabilities.sh,
# statusline/bus-segment.sh, hooks/BridgeBodyGuard.hook.ts (bun),
# bus-waker-daemon.sh notify path, Workflows doc-drift.
set -u

TESTS_DIR=$(cd -P "$(dirname "$0")" && pwd -P)

suites=0; failed=0; skipped=0
for t in "$TESTS_DIR"/*.sh; do
  [ "$(basename "$t")" = "run.sh" ] && continue
  suites=$((suites+1))
  echo "=== $(basename "$t") ==="
  bash "$t"; rc=$?
  case "$rc" in
    0) ;;
    2) echo "--- SKIPPED ($(basename "$t"))"; skipped=$((skipped+1)) ;;
    *) echo "--- FAILED ($(basename "$t"), exit $rc)"; failed=$((failed+1)) ;;
  esac
  echo
done

echo "SUITES: $suites run, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
