---
description: Babysit the bot code-review loop on a PR — poll the `Code Review` check, dispatch a Haiku handler subagent per new bot comment, up to 3 rounds. Use after `/subagent-driven-development` (or any flow that produces a branch) to take the PR all the way to "ready for merge" hands-off.
---

# /await-review

Polls the `Code Review` GitHub check on a PR and runs the bot-review fix loop (≤ 3 rounds, sha-deduplicated, Haiku handler per round). Pairs with any flow that produces a feature branch: brainstorming → /writing-plans → /subagent-driven-development → **/await-review**.

This is the same loop `/iterate-issues` runs in its Step 6, extracted so both flows share it.

## When to use this

- After `/subagent-driven-development` (or any local feature flow) finishes committing on a branch and you want AFK babysitting through review.
- After manually opening a PR, when you just want the auto-fix loop without having pushed any commits yourself.

**Not for batch flows** — `/iterate-issues` already calls this internally on its batch PR.

## Arguments

- `/await-review` (no args) — auto-detect PR for the current branch. If no PR exists yet: push the branch, run `gh pr create --fill` (uses last commit message as title/body), then start the loop.
- `/await-review <PR_NUM>` — use the given PR. Branch + worktree are read from current `pwd`.

## Critical invariants

- **Caller owns the branch and worktree.** This command does NOT create a worktree, switch branches, or commit anything itself.
- **State lives in GitHub.** Re-running on the same PR resumes from current state (latest bot comment id is re-discovered).
- **You merge.** This command runs the bot-fix loop and stops. Review the PR and `gh pr merge` yourself.

## Step 0 — Detect context

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
WORKTREE_DIR=$(git rev-parse --show-toplevel)
BRANCH=$(git -C "$WORKTREE_DIR" branch --show-current)
BASE_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
```

Abort cases:

| Symptom | Action |
|---|---|
| `gh repo view` fails | "this command requires a GitHub remote." |
| `git rev-parse` fails | "must be run inside a git working tree." |
| `BRANCH == BASE_BRANCH` | "refusing to open a PR against itself. Switch to a feature branch first." |
| `BRANCH` is empty (detached HEAD) | "detached HEAD — switch to a branch first." |

## Step 1 — Resolve PR_NUM

```bash
# If user passed a PR number as argument, use it.
PR_NUM="$1"

# Otherwise, look for an existing open PR for this branch.
if [ -z "$PR_NUM" ]; then
  PR_NUM=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open \
    --json number --jq '.[0].number // empty')
fi
```

If still empty, open one:

```bash
if [ -z "$PR_NUM" ]; then
  # Push the branch (sets upstream if missing).
  git -C "$WORKTREE_DIR" push -u origin "$BRANCH"

  # Open PR with title/body filled from the last commit.
  PR_URL=$(gh pr create --repo "$REPO" --base "$BASE_BRANCH" --head "$BRANCH" --fill)
  PR_NUM=$(echo "$PR_URL" | grep -oP '\d+$')
fi
```

If `gh pr create` fails because the branch has no commits ahead of base, abort: "branch has nothing to PR — commit work first."

## Step 2 — Run the bot-review loop

The loop terminates via exit codes from `~/.claude/commands/_shared/bot-review-loop.sh`:

| Exit | Meaning | Orchestrator action |
|---|---|---|
| `0` | Loop terminated cleanly. PR ready for human review. | Move to Step 3. |
| `10` | New bot review needs handling. Stdout: `DISPATCH_HANDLER round=<R> of=<N> head=<sha> comment_id=<id> last_handled=<id>`. | Dispatch the Haiku handler subagent (see 2.1), capture result, re-invoke. |
| `20` | Handler returned `NEEDS_HUMAN`. PR has been labeled `needs-human`. | Move to Step 3. |
| `30` | 30-min poll timeout. PR has been labeled `bot-review-timeout`. | Move to Step 3. |

Run the script via the Bash tool with `run_in_background=true` during the poll wait so the harness fires a single completion notification — no LLM tokens burned while idle.

### 2.1 Handler dispatch (when script exits 10)

Read `~/.claude/commands/_shared/handler-prompt.txt` and substitute:

| Placeholder | Value |
|---|---|
| `<R>`, `<N>` | round / cap (from script stdout) |
| `<PR>` | `$PR_NUM` |
| `<SHA>` | HEAD sha (from script stdout) |
| `<LATEST_ID>` | bot comment id (from script stdout) |
| `<REPO>` | `$REPO` |
| `<BRANCH>` | `$BRANCH` |
| `<WORKTREE_DIR>` | `$WORKTREE_DIR` |

Invoke `superpowers:receiving-code-review` with model `haiku-4.5` and the rendered prompt. Capture the handler's return string (one of `DONE_FIXED ...`, `DONE_NO_PUSH ...`, `NEEDS_HUMAN ...`) and pass it as `HANDLER_RESULT` when re-invoking the script.

**2.1b — Inspect the handler commit before accepting it (on `DONE_FIXED`).** The handler is a Haiku subagent on a tight leash; twice in the #676 run it pushed a plausible-but-wrong fix that had to be reverted (a schema migration that didn't actually serialize under READ COMMITTED; an out-of-scope caption retokenization). Before feeding `DONE_FIXED` back to the loop, look at what it actually committed:

```bash
git -C "$WORKTREE_DIR" show --stat "$head"..HEAD   # $head = pre-handler sha from the dispatch line
```

Reject and undo the handler's push if the diff:
- **adds or edits a migration / schema file** — the handler's HARD LIMIT forbids this; it should have pushed back. `git revert` (or reset + force-push) the handler commit, and file a follow-up issue for the underlying finding instead.
- **strays outside the finding's blast radius** — mass token/style sweeps, renamed symbols the review never mentioned, edits to files unrelated to the comment.

On rejection: undo the commit on the branch, post a PR comment explaining the revert + the correct route (follow-up issue for schema; re-scoped fix for a stray sweep), and pass `DONE_NO_PUSH` (not `DONE_FIXED`) back to the loop so the round isn't counted as a real fix. Folding this correction into the same push before the next poll means one bot review per round instead of burning a round on the orchestrator's own revert (retro #676 item 5).

### 2.2 Loop control

```bash
N_ROUNDS=3 ROUND=1 LAST_HANDLED_COMMENT_ID=0 HANDLER_RESULT=""
while true; do
  out=$(N_ROUNDS=$N_ROUNDS ROUND=$ROUND \
        LAST_HANDLED_COMMENT_ID=$LAST_HANDLED_COMMENT_ID \
        HANDLER_RESULT="$HANDLER_RESULT" \
        ~/.claude/commands/_shared/bot-review-loop.sh \
        "$PR_NUM" "$REPO" "$WORKTREE_DIR" "$BRANCH")
  rc=$?
  case $rc in
    0|20|30) break ;;                                  # terminal
    10)
      # Parse `DISPATCH_HANDLER round=R of=N head=SHA comment_id=ID last_handled=ID`
      # from stdout, dispatch handler subagent (2.1), capture result, then loop.
      eval "$(parse_dispatch_line "$out")"             # sets ROUND, head, comment_id
      LAST_HANDLED_COMMENT_ID=$comment_id
      HANDLER_RESULT=$(dispatch_handler "$ROUND" "$N_ROUNDS" "$head" "$comment_id")
      ;;
    *)  echo "bot-review-loop.sh failed rc=$rc"; break ;;
  esac
done
```

`/await-review` leaves `INPROGRESS_LABEL` unset, so the script does not manage a "loop in progress" label on this PR. (Contrast with `/iterate-issues`, which passes `INPROGRESS_LABEL=batch-pr-open` to clear that batch marker on terminal exit.)

### 2.3 Termination matrix

| Exit reason | Final label | Final summary line |
|---|---|---|
| All rounds passed; bot found nothing actionable in latest round | (none) | "ready for merge after R rounds" |
| Round R returned `DONE_NO_PUSH` | (none) | "ready for merge; pushed back on all findings in round R" |
| Round R returned `NEEDS_HUMAN` | `needs-human` | "needs-human after round R: <reason>" |
| Round R hit 30-min poll timeout | `bot-review-timeout` | "bot-review-timeout in round R" |
| Round 3 returned `DONE_FIXED` and we hit N_ROUNDS cap | (none) | "ready for merge after 3 fix rounds (cap reached)" |

## Step 3 — Final summary

Post as text:

```
## Await-review summary

PR: #<PR_NUM>  (status: <ready-for-merge | needs-human | bot-review-timeout>)
Branch: <BRANCH>
Rounds: <R> of 3
<final summary line from 2.3>

Next step: review PR #<PR_NUM>, then `gh pr merge <PR_NUM> --squash`.
```

Then exit. Do NOT merge the PR.

## Code-review workflow contract

Same as `/iterate-issues`. The active workflow under `.github/workflows/` must:

| Surface | Required value |
|---|---|
| GitHub check name | **`Code Review`** |
| Summary PR comment body | Begins with **`<!-- ai-code-review -->`** |
| Posting cadence | One substantive comment per push |
| Placeholder comments | Must NOT include the marker |

## What this command does NOT do

- Does not merge the PR. You merge.
- Does not create a worktree, switch branches, or commit code. The caller owns the branch.
- Does not handle batch PRs (multiple issues, `Closes #N` body). For that, use `/iterate-issues`, which calls this loop internally.
