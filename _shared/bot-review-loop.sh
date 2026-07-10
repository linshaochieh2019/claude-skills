#!/usr/bin/env bash
#
# Bot review polling loop. Used by /iterate-issues and /await-review.
#
# Usage:
#   bot-review-loop.sh <PR_NUM> <REPO> <WORKTREE_DIR> <BRANCH>
#
# Polls the "Code Review" check on the given PR up to N_ROUNDS times,
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
# Haiku handler subagent (../_shared/handler-prompt.txt), and re-invokes this
# script with the handler's result via the HANDLER_RESULT env var.
#
# This keeps subagent dispatch in the LLM orchestrator (which has the Task
# tool) and pure state-watching here in bash (cheap, deterministic).
#
# Optional env vars:
#   INPROGRESS_LABEL  — if set, this label is removed from the PR on every
#                       terminal exit. /iterate-issues passes "batch-pr-open";
#                       /await-review leaves it unset.
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
BRANCH="${4:?BRANCH required}"

N_ROUNDS="${N_ROUNDS:-3}"
ROUND="${ROUND:-1}"
LAST_HANDLED_COMMENT_ID="${LAST_HANDLED_COMMENT_ID:-0}"
HANDLER_RESULT="${HANDLER_RESULT:-}"
INPROGRESS_LABEL="${INPROGRESS_LABEL:-}"

remove_inprogress_label() {
  [ -n "$INPROGRESS_LABEL" ] || return 0
  gh pr edit "$PR_NUM" --remove-label "$INPROGRESS_LABEL" --repo "$REPO" 2>/dev/null || true
}

# If the orchestrator passes back a HANDLER_RESULT from a prior dispatch,
# branch on it before polling for the next round.
if [ -n "$HANDLER_RESULT" ]; then
  case "$HANDLER_RESULT" in
    DONE_FIXED*)
      ROUND=$((ROUND + 1))
      ;;
    DONE_NO_PUSH*)
      remove_inprogress_label
      exit 0
      ;;
    NEEDS_HUMAN*)
      remove_inprogress_label
      gh pr edit "$PR_NUM" --add-label needs-human --repo "$REPO"
      exit 20
      ;;
  esac
fi

if [ "$ROUND" -gt "$N_ROUNDS" ]; then
  # Hit the cap.
  remove_inprogress_label
  exit 0
fi

echo "=== Round $ROUND of $N_ROUNDS ==="
CURRENT_HEAD=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

# Wait for the "Code Review" check to resolve for the current HEAD.
# (Generic check name per the code-review workflow contract.)
# Run this script via the Bash tool with run_in_background=true so the harness
# fires a single completion notification when the until-loop exits — no LLM
# tokens burned during the wait.
#
# Empty `status` means the check isn't surfaced yet — keep waiting. This matters
# for `needs:`-gated two-job workflows (e.g. OpenAI Codex's Generate review →
# Code Review pattern), where the "Code Review" check doesn't appear in
# `gh pr checks` output until its upstream dependency completes.
i=0
until status=$(gh pr checks "$PR_NUM" --repo "$REPO" --json name,bucket \
      --jq '.[] | select(.name == "Code Review") | .bucket'); \
      { [ -n "$status" ] && [ "$status" != "pending" ]; } || [ "$i" -ge 60 ]; do
  sleep 30
  i=$((i+1))
done
final_status=$(gh pr checks "$PR_NUM" --repo "$REPO" --json name,bucket \
  --jq '.[] | select(.name == "Code Review") | .bucket')

# Timeout path
if [ "$final_status" = "pending" ]; then
  remove_inprogress_label
  gh pr edit "$PR_NUM" --add-label bot-review-timeout --repo "$REPO"
  echo "TIMEOUT round=$ROUND head=$CURRENT_HEAD"
  exit 30
fi

# Fetch the latest code-review comment whose id > LAST_HANDLED_COMMENT_ID.
# We filter by the marker `<!-- ai-code-review -->` (per the workflow contract)
# rather than by user.login, so this works regardless of which provider is
# active and which bot identity ends up posting (claude[bot],
# github-actions[bot], etc.). The marker is the contract — bots come and go.
# (gh's bundled --jq avoids a hard dep on standalone jq.)
LATEST_ID=$(gh api "repos/$REPO/issues/$PR_NUM/comments" \
  --jq '[.[] | select(.body | contains("<!-- ai-code-review -->"))] | last | .id // 0')

if [ "$LATEST_ID" -le "$LAST_HANDLED_COMMENT_ID" ]; then
  # Bot didn't post a new substantive review. Treat as terminal-clean.
  echo "NO_NEW_REVIEW round=$ROUND head=$CURRENT_HEAD"
  remove_inprogress_label
  exit 0
fi

# Signal to orchestrator: dispatch the handler with this comment.
echo "DISPATCH_HANDLER round=$ROUND of=$N_ROUNDS head=$CURRENT_HEAD comment_id=$LATEST_ID last_handled=$LAST_HANDLED_COMMENT_ID"
exit 10
