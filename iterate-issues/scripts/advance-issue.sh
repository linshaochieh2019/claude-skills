#!/usr/bin/env bash
#
# advance-issue.sh — deterministic issue-label transition for /iterate-issues.
#
# Bundles the two label flips at an issue boundary into ONE command so they
# can't be half-applied under long-session context pressure (retro #676 item
# 4). Replaces ad-hoc `gh issue edit` pairs.
#
# Usage:
#   advance-issue.sh <REPO> done   <N>            # <N>: in-progress -> done
#   advance-issue.sh <REPO> start  <N>            # <N>: ready-for-agent -> in-progress
#   advance-issue.sh <REPO> human  <N> "<reason>" # <N>: in-progress -> needs-human (+comment)
#   advance-issue.sh <REPO> advance <DONE_N> <NEXT_N>  # DONE_N->done AND NEXT_N->in-progress
#
# `advance` is the common per-loop transition: close out the finished issue and
# pick up the next one in a single call. Either number may be empty ("" -> skip
# that half), so the first issue (no predecessor) and the last (no successor)
# both work: advance "" 12  /  advance 16 "".
#
# Idempotent: re-adding a label already present, or removing one already gone,
# is a no-op on GitHub, so a crashed-then-resumed run can safely re-issue it.

set -euo pipefail

REPO="${1:?REPO required}"
ACTION="${2:?action required (done|start|human|advance)}"

flip() {  # flip <N> <add-label> <remove-label>
  [ -n "$1" ] || return 0
  gh issue edit "$1" --repo "$REPO" --add-label "$2" --remove-label "$3"
}

case "$ACTION" in
  done)  flip "${3:?N required}" done        in-progress ;;
  start) flip "${3:?N required}" in-progress ready-for-agent ;;
  human)
    N="${3:?N required}"
    flip "$N" needs-human in-progress
    [ -n "${4:-}" ] && gh issue comment "$N" --repo "$REPO" --body "$4" || true
    ;;
  advance)
    flip "${3:-}" done        in-progress       # close out the finished issue
    flip "${4:-}" in-progress ready-for-agent    # pick up the next one
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac
