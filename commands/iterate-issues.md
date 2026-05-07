---
description: Drain all open `ready-for-agent` GitHub issues into a single batch branch end-to-end, then open one batch PR. Built for stacked queues where each issue depends on the previous. Wakes you with one PR to review. Use whenever you want to drain a stacked-issue queue, run an AFK batch, or "just work through the ready-for-agent issues."
---

# /iterate-issues

End-to-end autonomous loop for **stacked queues**: pick up every open issue labeled `ready-for-agent`, implement them sequentially as commits on a **single batch branch** off `origin/<baseBranch>`, then open one batch PR at the end. The batch PR closes all included issues. You wake from AFK to **one** PR with N commits.

Direct-invoke locally OR one-shot via `/schedule` for AFK. Same design either way.

## When to use this vs. fan-out alternatives

Optimized for **stacked work** — issues that import from or build on each other (e.g., module slices: bootstrap → schema → list pages → detail pages → quotes). For these queues, "one PR per issue, all branched off `origin/<baseBranch>`" doesn't work without a human merging between issues, which defeats the AFK promise.

If you have a queue of **independent** issues (disjoint files, no shared imports) and want N PRs in parallel, this command is the wrong tool — write a separate fan-out command.

## Project portability

This command lives at `~/.claude/commands/iterate-issues.md` and is available in every git repo on this machine. It auto-detects the GitHub repo, base branch, and worktree path from the current working directory, so no per-project install step is needed.

Per-project tuning (verification commands, framework-citation rules, etc.) is optional — drop a `.iterate-issues.json` at the repo root. See `~/.claude/commands/iterate-issues/config/.iterate-issues.example.json` for the schema.

## Bundled artifacts

- `~/.claude/commands/iterate-issues/scripts/bot-review-loop.sh` — deterministic state-machine for polling the bot review check and deduping comments. Invoked by Step 5; signals via exit codes.
- `~/.claude/commands/iterate-issues/templates/planner-prompt.txt` — task prompt for the planner subagent (Step 3.3).
- `~/.claude/commands/iterate-issues/templates/implementer-prompt.txt` — task prompt for the implementer subagent (Step 3.5).
- `~/.claude/commands/iterate-issues/templates/handler-prompt.txt` — task prompt for the review handler subagent (Step 5).

## Pipeline position

```
design doc → /grill-me (ad-hoc) → /to-prd → /to-issues → /triage → /iterate-issues → review one PR → merge
```

Matt's skills (`/grill-me`, `/to-prd`, `/to-issues`, `/triage`) are upstream and stay untouched.

## Critical invariants

- **Single batch branch.** Every issue's commits land on the same branch (`agent/batch-<YYYYMMDD>`) off the project's base branch. No per-issue branches. No worktree-per-issue. One PR at the end.
- **Sequential, not parallel.** Each issue's implementer sees the previous issue's commits in its working tree, naturally resolving stacked-import dependencies.
- **Single isolated worktree.** The whole batch runs in `../<repo-name>-batch/`. Your main checkout's dirty state on whatever branch is irrelevant.
- **State lives in GitHub.** Issue labels are the durable queue. Don't keep an in-memory queue; remote runs are stateless across sessions.
- **Skill reuse over reinvention.** Thin shim over `superpowers:writing-plans` + `superpowers:subagent-driven-development` + `superpowers:receiving-code-review`. Override the subagent's "push and open PR" default via the implementer task prompt; don't fork the skill. Don't override the `superpowers` skills' internal model selections — they know what they're doing.
- **You merge.** This command opens one PR and stops. You review it, you merge.

## Step 0 — Detect repo context

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
BATCH_BRANCH="agent/batch-$(date +%Y%m%d)"
WORKTREE_DIR="$(dirname "$REPO_ROOT")/${REPO_NAME}-batch"

# Read project config if present (optional). All keys default if absent.
CONFIG="$REPO_ROOT/.iterate-issues.json"
BASE_BRANCH=$(jq -r '.baseBranch // "main"' "$CONFIG" 2>/dev/null || echo "main")
SETUP_CMD=$(jq -r '.setupCommand // "npm ci"' "$CONFIG" 2>/dev/null || echo "npm ci")
```

If `gh repo view` or `git rev-parse` fails, abort with "not a github repo / not in a git working tree."

## Label conventions

| Owner | Labels |
|---|---|
| `/triage` (Matt's, untouched) | `bug`, `enhancement`, `needs-triage`, `needs-info`, **`ready-for-agent`** (input), `ready-for-human`, `wontfix` |
| This command (per issue) | `in-progress`, `done`, `needs-human` |
| This command (batch-level) | `batch-pr-open`, `bot-review-timeout` (on the batch PR, not on issues) |

State machine per issue: `ready-for-agent` → `in-progress` → `done` (committed to batch branch) **or** `needs-human` (escalation).

The batch PR carries `batch-pr-open` while awaiting bot review, and closes the included issues automatically via `Closes #N` lines in the body when merged.

## Models

| Step | Model | Why |
|---|---|---|
| Orchestrator (this command) | Opus | Coordinates everything; needs strong judgment for failure routing. |
| Planner subagent (`superpowers:writing-plans`) | Opus | Architecture, file paths, framework citations — judgment-heavy. |
| Implementer subagent (`superpowers:subagent-driven-development`) | Sonnet | Mechanical execution against a fixed plan. |
| Review-handler subagent (`superpowers:receiving-code-review`) | Haiku 4.5 | Tight scope: read review, apply or push back, push commit. |
| Sub-subagents inside `superpowers` skills | skill default | Don't override. |
| Merge phase | n/a | Human review. |

The planner and implementer are **different subagents** with different scopes. Issue bodies from `/to-issues` are specs (what + why), not implementation plans (how + where + in what order). The planner converts spec → plan and owns framework citations; the implementer executes the plan mechanically.

## Code-review workflow contract

`/iterate-issues` is provider-agnostic. It does not care whether code review is run by Claude, Codex, or anything else — only that the active workflow honors this contract:

| Surface | Required value | Why |
|---|---|---|
| GitHub check name (the job's `name:` field) | **`Code Review`** | The orchestrator polls `gh pr checks --jq '.[] \| select(.name == "Code Review")'`. Generic name → no rename when swapping providers. |
| Summary PR comment body | Begins with **`<!-- ai-code-review -->`** | The orchestrator filters comments by this marker, not by `user.login`. Survives identity changes (`claude[bot]` ↔ `github-actions[bot]`). |
| Posting cadence | One substantive comment per push | The orchestrator dedupes via comment id (`LATEST_ID > LAST_HANDLED_COMMENT_ID`); a new push that produces a new comment with the marker is treated as a new round. |
| Placeholder comments | If the workflow posts a "review in progress" placeholder, it must NOT include the marker | Otherwise the orchestrator will treat the placeholder as the substantive review. |

Per-project, the active code-review workflow lives in `.github/workflows/` and must meet the contract above. To swap providers (e.g., Claude ↔ Codex), replace or toggle the workflow file's trigger and adjust GitHub repo secrets accordingly. No changes to this command should be needed.

## Budgets

| Phase | Wall-clock | On exceed |
|---|---|---|
| Per-issue planner | 15 min | Label `needs-human` with planner output (or "no output"). **Skip implementer**, continue queue. |
| Per-issue implementer | 45 min | Roll back the issue's partial work, label `needs-human`, **continue to next issue**. |
| Bot review (after batch PR opens) | 30 min poll | Label batch PR `bot-review-timeout`. Don't dispatch handler. |
| Whole-session ceiling | 8 hours | Push current batch branch to remote (so work isn't lost), open batch PR with whatever issues completed, post partial summary. |

## Step 1 — Reconciliation pass (resume safety)

Before pulling the queue, detect a crashed prior batch.

```bash
gh issue list --repo "$REPO" --state open --label in-progress --json number,title
```

Cases:

- **Worktree exists, branch exists, in-progress issue exists.** Resume: cd into worktree, reset uncommitted changes (`git reset --hard HEAD && git clean -fd`), re-run the in-progress issue from scratch starting at the planner stage (its label stays `in-progress`). Restarting from planning is safe whether the prior crash was mid-planning or mid-implementation.
- **Worktree exists but no in-progress issue.** Prior batch finished implementation but never opened the batch PR. Skip to Step 5 (open batch PR).
- **In-progress issue exists but no worktree.** Worktree was deleted; state was lost. Label the issue `needs-human` with comment "worktree missing on resume; manual investigation needed." Continue queue.
- **Neither exists.** Fresh run. Proceed to Step 2.

## Step 2 — Pull and order the queue

```bash
gh issue list --repo "$REPO" --state open --label ready-for-agent \
  --json number,title,body,labels --jq 'sort_by(.number)'

gh issue list --repo "$REPO" --state open --label needs-triage \
  --json number --jq 'length'   # for final summary notice
```

If the `ready-for-agent` queue is empty, exit cleanly: "no ready-for-agent issues. (N still in needs-triage.)"

For each issue, scan the body for **either** `Depends on #N` **or** `Blocked by[:]?\s*#N` lines (both are dependency edges; `/triage` issue templates use the second form). Topo-sort if any are present, otherwise ascending by issue number. Treat closed issues as satisfied dependencies; treat any open dependency that isn't itself in the current `ready-for-agent` queue as a hard blocker — label the dependent issue `needs-human` and skip it.

Build a TodoWrite list with one entry per issue.

## Step 3 — Set up the batch worktree (once per run)

```bash
git fetch origin "$BASE_BRANCH"
git worktree add -b "$BATCH_BRANCH" "$WORKTREE_DIR" "origin/$BASE_BRANCH"
cd "$WORKTREE_DIR"
$SETUP_CMD   # one install for the whole batch
```

If the setup command fails, stop the batch entirely; label all queued issues `needs-human` with comment "batch setup failed: <error>".

## Step 4 — Per-issue loop (sequential, in-place)

For each issue in topo-sorted order:

### 4.1 Mark in-progress

```bash
gh issue edit <N> --add-label in-progress --remove-label ready-for-agent --repo "$REPO"
```

### 4.2 Capture starting commit (for rollback on failure)

```bash
START_COMMIT=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
```

### 4.3 Dispatch planner subagent

Read `~/.claude/commands/iterate-issues/templates/planner-prompt.txt` and substitute:

| Placeholder | Value |
|---|---|
| `<N>` | issue number |
| `<WORKTREE_DIR>` | `$WORKTREE_DIR` |
| `<issue body>` | the full issue body from `gh issue view` |

Invoke `superpowers:writing-plans` with model `opus`, working directory `$WORKTREE_DIR` (read-only), and the rendered prompt as the task input. The template instructs the planner to honor `<repo-root>/.iterate-issues.json` if present.

### 4.4 On planner return

| Outcome | Action |
|---|---|
| Plan returned with `CITATIONS` block (or explicit "no framework-specific naming choices made") | Proceed to 4.5 with the plan as input. |
| `BLOCKED` | `gh issue edit <N> --remove-label in-progress --add-label needs-human`. Comment with planner's reason. **Skip implementer, continue queue.** No rollback needed (planner is read-only). |
| 15-min budget exceeded | Same as `BLOCKED`. Comment notes budget exceedance. |
| Plan returned without a `CITATIONS` block, but the spec implies framework-specific naming (e.g., touches `middleware.ts`, `route.ts`, `layout.tsx`, migration files, etc.) | Treat as `BLOCKED`. Comment "missing CITATIONS block — re-plan after planner adds doc citations." |

### 4.5 Dispatch implementer subagent

Read `~/.claude/commands/iterate-issues/templates/implementer-prompt.txt` and substitute:

| Placeholder | Value |
|---|---|
| `<N>` | issue number |
| `<issue title>` | issue title (used in commit-message format) |
| `<planner output>` | the plan returned by the 4.3 planner subagent |
| `<issue body>` | the original issue body |

Invoke `superpowers:subagent-driven-development` with model `sonnet`, working directory `$WORKTREE_DIR`, and the rendered prompt as the task input.

Two-stage review (spec compliance + code quality) is built into `subagent-driven-development` — don't skip it.

### 4.6 On implementer return

| Outcome | Action |
|---|---|
| Success | `gh issue edit <N> --remove-label in-progress --add-label done`. Update TodoWrite. Move to next issue. |
| `BLOCKED` / `NEEDS_CONTEXT` | `git -C "$WORKTREE_DIR" reset --hard "$START_COMMIT" && git clean -fd`. `gh issue edit <N> --remove-label in-progress --add-label needs-human`. Comment with the blocker (include the plan so the human can see what the implementer was given). **Continue queue.** |
| 45-min budget exceeded | Same as `BLOCKED`. Comment notes the budget exceedance. |
| Implementer pushed or opened a PR despite the directive | Close the rogue PR, delete the rogue branch from remote, do NOT count this issue as `done`. Label `needs-human` with comment "implementer ignored batch-mode directive." Continue queue. |

**Do not abort the whole batch for one bad issue.** Forward progress is the point.

## Step 5 — Open the batch PR

After the queue is drained (or the 8-hour session ceiling hit):

```bash
cd "$WORKTREE_DIR"
git push -u origin "$BATCH_BRANCH"

DONE_ISSUES=$(gh issue list --repo "$REPO" --state open --label done \
  --json number,title --jq 'map("- Closes #\(.number) — \(.title)") | join("\n")')

DONE_COUNT=$(gh issue list --repo "$REPO" --state open --label done \
  --json number --jq 'length')

PR_URL=$(gh pr create --repo "$REPO" \
  --base "$BASE_BRANCH" --head "$BATCH_BRANCH" \
  --title "Batch: $(date +%Y-%m-%d) ($DONE_COUNT issues)" \
  --body "$(cat <<EOF
Batch run via /iterate-issues.

Issues included (one or more commits each on this branch):

$DONE_ISSUES

Review by walking commits in order — each commit's title starts with the
originating issue number. Merging this PR will close all listed issues.
EOF
)")

PR_NUM=$(echo "$PR_URL" | grep -oP '\d+$')
gh pr edit "$PR_NUM" --add-label batch-pr-open --repo "$REPO"
```

If no issues completed (everything went `needs-human`), skip the PR and post the summary directly.

## Step 6 — Bot review loop (up to 2 rounds)

The bot auto-triggers a fresh review on every push to the PR branch. The loop runs up to **N=2 rounds** with sha-based deduplication, catching the realistic case ("bot found something → handler fixed it → bot now happy") without inviting handler-vs-bot infinite loops.

**Per-round budget:** 30 min wait for the `Code Review` check to leave `pending`. **Total cap:** 2 rounds.

### 6.1 Architecture: deterministic state-machine in bash, LLM dispatch in orchestrator

The polling/dedup state-machine lives in `~/.claude/commands/iterate-issues/scripts/bot-review-loop.sh`. The orchestrator calls it via the Bash tool (with `run_in_background=true` during the poll wait, so the harness fires a single completion notification when the until-loop exits — no tokens burned while idle).

The script communicates via exit codes:

| Exit | Meaning | Orchestrator action |
|---|---|---|
| `0` | Loop terminated cleanly (PR ready for human review). | Move to Step 7. |
| `10` | A new bot review needs handling. Stdout includes `DISPATCH_HANDLER round=<R> of=<N> head=<sha> comment_id=<id> last_handled=<id>`. | Dispatch the Haiku handler subagent (see 6.2). Re-invoke the script with `ROUND`, `LAST_HANDLED_COMMENT_ID`, `HANDLER_RESULT` env vars set. |
| `20` | Handler returned `NEEDS_HUMAN`. PR is labeled `needs-human`. | Move to Step 7. |
| `30` | 30-min poll timeout; PR is labeled `bot-review-timeout`. | Move to Step 7. |

This split keeps deterministic state-watching in bash and model-judgment dispatch in the orchestrator (the only thing that can use the Task tool).

### 6.2 Handler dispatch (when script exits 10)

Read `~/.claude/commands/iterate-issues/templates/handler-prompt.txt` and substitute:

| Placeholder | Value |
|---|---|
| `<R>`, `<N>` | round number / total cap (from script stdout) |
| `<PR>` | PR number |
| `<SHA>` | HEAD sha (from script stdout) |
| `<LATEST_ID>` | bot comment id (from script stdout) |
| `<REPO>` | `$REPO` |
| `<BATCH_BRANCH>` | `$BATCH_BRANCH` |
| `<WORKTREE_DIR>` | `$WORKTREE_DIR` |

Invoke `superpowers:receiving-code-review` with model `haiku-4.5` and the rendered prompt. Capture the handler's return string (one of `DONE_FIXED ...`, `DONE_NO_PUSH ...`, `NEEDS_HUMAN ...`) and pass it as `HANDLER_RESULT` when re-invoking `bot-review-loop.sh`.

### 6.3 Loop control

```bash
N_ROUNDS=2 ROUND=1 LAST_HANDLED_COMMENT_ID=0 HANDLER_RESULT=""
while true; do
  out=$(N_ROUNDS=$N_ROUNDS ROUND=$ROUND \
        LAST_HANDLED_COMMENT_ID=$LAST_HANDLED_COMMENT_ID \
        HANDLER_RESULT="$HANDLER_RESULT" \
        ~/.claude/commands/iterate-issues/scripts/bot-review-loop.sh \
        "$PR_NUM" "$REPO" "$WORKTREE_DIR" "$BATCH_BRANCH")
  rc=$?
  case $rc in
    0|20|30) break ;;                                  # terminal
    10)
      # Parse `DISPATCH_HANDLER round=R of=N head=SHA comment_id=ID last_handled=ID`
      # from stdout, dispatch handler subagent (6.2), capture result, then loop.
      eval "$(parse_dispatch_line "$out")"             # sets ROUND, head, comment_id
      LAST_HANDLED_COMMENT_ID=$comment_id
      HANDLER_RESULT=$(dispatch_handler "$ROUND" "$N_ROUNDS" "$head" "$comment_id")
      ;;
    *)  echo "bot-review-loop.sh failed rc=$rc"; break ;;
  esac
done
```

### 6.4 Termination matrix

This is the canonical exit-state mapping for the bot-review loop. Any unexpected failures (rogue PRs, setup failures, branch drift) are in "Failure modes" below.

| Exit reason | Final label | Final summary line |
|---|---|---|
| All rounds passed; bot found nothing actionable in latest round | `batch-pr-open` removed (no labels) | "ready for merge after R rounds" |
| Round R returned `DONE_NO_PUSH` | `batch-pr-open` removed | "ready for merge; pushed back on all findings in round R" |
| Round R returned `NEEDS_HUMAN` | `needs-human` set, `batch-pr-open` removed | "needs-human after round R: <reason>" |
| Round R hit 30-min poll timeout | `bot-review-timeout` set, `batch-pr-open` removed | "bot-review-timeout in round R" |
| Round 2 returned `DONE_FIXED` and we hit N_ROUNDS cap | `batch-pr-open` removed | "ready for merge after 2 fix rounds (cap reached)" |

## Step 7 — Final summary

Post as text:

```
## Iterate-issues batch summary

Batch branch: agent/batch-<YYYYMMDD>
Batch PR: #<PR_NUM>  (status: <ready-for-merge | needs-human | bot-review-timeout>)

| Issue | Status | Commits on batch |
|---|---|---|
| #12 | done | 2 |
| #14 | done | 1 |
| #15 | needs-human | 0 (rolled back: <reason>) |
| #16 | done | 1 |
...

NOTE: <K> issues remain in needs-triage. Run /triage before next /iterate-issues invocation.

Next step: review batch PR #<PR_NUM> commit-by-commit, then `gh pr merge <PR_NUM> --squash`.
```

Then exit. Do NOT merge the PR. Do NOT close issues — they close automatically when the human merges the PR.

## Step 8 — Post-merge cleanup (manual, after you merge)

```bash
git worktree remove "$WORKTREE_DIR"
git worktree prune
```

This step isn't part of the AFK run. Do it post-merge when you have time.

## Failure modes (unexpected)

For routine exit states see Step 6.4. This table covers genuine failures.

| Symptom | Action |
|---|---|
| Planner subagent returns `BLOCKED` (e.g., no doc citation found) | No rollback (planner is read-only). Label issue `needs-human` with planner's reason. Skip implementer, continue queue. |
| Planner exceeds 15-min budget | Same as planner `BLOCKED`. Comment notes budget exceedance. |
| Planner produced a plan but implementer disagrees with it (returns `BLOCKED`) | Roll back. Label issue `needs-human`. Comment includes the plan so the human can see the disagreement. Do NOT silently re-plan in the same run — that's a tight loop risk. |
| Implementer subagent returns `BLOCKED` | Roll back partial work to `$START_COMMIT`. Label issue `needs-human`. Continue queue. |
| Implementer exceeds 45-min budget | Same as `BLOCKED`. Comment notes budget exceedance. |
| Implementer ignores batch-mode directive (pushes / opens PR) | Close rogue PR, delete rogue branch, label issue `needs-human`. Continue queue. |
| Two issues form a `Depends on #N` cycle | Stop; report cycle to user. |
| Setup command fails at batch setup | Stop the batch entirely; label all queued issues `needs-human` with comment "batch setup failed: <error>". |
| Verification command fails after an issue's commits | Implementer should have caught this; if it slipped through, Step 4.6 catches a non-success return. Roll back, label issue `needs-human`, continue. |
| Whole-session 8-hour ceiling hit | Push batch branch to remote, open batch PR with whatever's done, post partial summary. Remaining `ready-for-agent` issues stay queued for next run. |
| Worktree exists but on wrong branch | Step 1 detects via `git -C "$WORKTREE_DIR" branch --show-current`. If branch != `$BATCH_BRANCH`, label all in-progress issues `needs-human` and stop. Manual cleanup. |
| `gh repo view` fails (not a GitHub repo) | Abort with "this command requires a GitHub remote." |

## What this command does NOT do

- Does not merge the batch PR. You merge.
- Does not close issues (they close via `Closes #N` when the PR merges).
- Does not push migrations without manual review (orchestrator refuses + labels `needs-human` if an issue requires one).
- Does not bypass `pre-commit` hooks. Failed hook → implementer fixes the underlying issue.
- Does not re-run `/triage` on `needs-triage` issues. It surfaces the count; you triage.
- Does not handle fan-out queues (independent issues for parallel PRs). For that, use a different tool.
