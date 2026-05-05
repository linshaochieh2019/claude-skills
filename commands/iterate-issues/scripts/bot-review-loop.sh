#!/usr/bin/env bash
#
# Bot review polling loop for /iterate-issues batch PRs.
#
# Usage:
#   bot-review-loop.sh <PR_NUM> <REPO> <WORKTREE_DIR> <BATCH_BRANCH>
#
# Polls the "Claude Code Review" check on the given PR up to N_ROUNDS times,
# dispatching a review handler between rounds (the orchestrator passes the
# handler's prompt and result back through env vars / stdout).
#
# This script handles the deterministic state-machine pieces:
#   - waiting for the check to leave `pending`
#   - sha-based deduplication of bot comments
#   - timeout / round-cap label management
#
# It does NOT dispatch the LLM handler itself. Instead, when a new bot review
# is detected, the script prints "DISPATCH_HANDLER round=<R> head=<sha> comment_id=<id>"
# and exits with code 10. The orchestrator reads that line, dispatches the
# Haiku handler subagent (templates/handler-prompt.md), and re-invokes this
# script with the handler's result via the HANDLER_RESULT env var.
#
# This keeps subagent dispatch in the LLM orchestrator (which has the Task
# tool) and pure state-watching here in bash (cheap, deterministic).
#
# Exit codes:
#   0   loop terminated cleanly (PR ready for human review)
#   10  needs handler dispatch — orchestrator should re-invoke
#   20  needs-human (handler returned NEEDS_HUMAN)
#   30  bot-review-timeout

set -euo pipefail

PR_NUM="${1:?PR_NUM required}"
REPO="${2:?REPO required}"
WORKTREE_DIR="${3:?WORKTREE_DIR required}"
BATCH_BRANCH="${4:?BATCH_BRANCH required}"

N_ROUNDS="${N_ROUNDS:-2}"
ROUND="${ROUND:-1}"
LAST_HANDLED_COMMENT_ID="${LAST_HANDLED_COMMENT_ID:-0}"
HANDLER_RESULT="${HANDLER_RESULT:-}"

# If the orchestrator passes back a HANDLER_RESULT from a prior dispatch,
# branch on it before polling for the next round.
if [ -n "$HANDLER_RESULT" ]; then
  case "$HANDLER_RESULT" in
    DONE_FIXED*)
      ROUND=$((ROUND + 1))
      ;;
    DONE_NO_PUSH*)
      gh pr edit "$PR_NUM" --remove-label batch-pr-open --repo "$REPO"
      exit 0
      ;;
    NEEDS_HUMAN*)
      gh pr edit "$PR_NUM" --remove-label batch-pr-open --add-label needs-human --repo "$REPO"
      exit 20
      ;;
  esac
fi

if [ "$ROUND" -gt "$N_ROUNDS" ]; then
  # Hit the cap. Clear batch-pr-open if still set.
  final_labels=$(gh pr view "$PR_NUM" --repo "$REPO" --json labels --jq '.labels | map(.name)')
  if echo "$final_labels" | grep -q '"batch-pr-open"'; then
    gh pr edit "$PR_NUM" --remove-label batch-pr-open --repo "$REPO"
  fi
  exit 0
fi

echo "=== Round $ROUND of $N_ROUNDS ==="
CURRENT_HEAD=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

# Wait for the Claude Code Review check to resolve for the current HEAD.
# Run this script via the Bash tool with run_in_background=true so the harness
# fires a single completion notification when the until-loop exits — no LLM
# tokens burned during the wait.
i=0
until status=$(gh pr checks "$PR_NUM" --repo "$REPO" --json name,bucket \
      --jq '.[] | select(.name == "Claude Code Review") | .bucket'); \
      [ "$status" != "pending" ] || [ "$i" -ge 60 ]; do
  sleep 30
  i=$((i+1))
done
final_status=$(gh pr checks "$PR_NUM" --repo "$REPO" --json name,bucket \
  --jq '.[] | select(.name == "Claude Code Review") | .bucket')

# Timeout path
if [ "$final_status" = "pending" ]; then
  gh pr edit "$PR_NUM" --add-label bot-review-timeout --remove-label batch-pr-open --repo "$REPO"
  echo "TIMEOUT round=$ROUND head=$CURRENT_HEAD"
  exit 30
fi

# Fetch the latest claude[bot] comment whose id > LAST_HANDLED_COMMENT_ID
# AND whose body isn't the "PR Review in Progress" placeholder.
LATEST_COMMENT=$(gh api "repos/$REPO/issues/$PR_NUM/comments" \
  --jq '[.[] | select(.user.login == "claude[bot]") | select(.body | test("PR Review in Progress") | not)] | last')
LATEST_ID=$(echo "$LATEST_COMMENT" | jq '.id // 0')

if [ "$LATEST_ID" -le "$LAST_HANDLED_COMMENT_ID" ]; then
  # Bot didn't post a new substantive review. Treat as terminal-clean.
  echo "NO_NEW_REVIEW round=$ROUND head=$CURRENT_HEAD"
  gh pr edit "$PR_NUM" --remove-label batch-pr-open --repo "$REPO"
  exit 0
fi

# Signal to orchestrator: dispatch the handler with this comment.
echo "DISPATCH_HANDLER round=$ROUND of=$N_ROUNDS head=$CURRENT_HEAD comment_id=$LATEST_ID last_handled=$LAST_HANDLED_COMMENT_ID"
exit 10
