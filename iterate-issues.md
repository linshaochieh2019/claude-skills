---
argument-hint: "[issue numbers to scope to, e.g. 507 506 505 — omit to drain all ready-for-agent]"
description: Drain all open `ready-for-agent` GitHub issues into a single batch branch end-to-end, then open one batch PR. Built for stacked queues where each issue depends on the previous. Wakes you with one PR to review. Use whenever you want to drain a stacked-issue queue, run an AFK batch, or "just work through the ready-for-agent issues."
---

# /iterate-issues

End-to-end autonomous loop for **stacked queues**: pick up every open issue labeled `ready-for-agent`, implement them sequentially as commits on a **single batch branch** off `origin/<baseBranch>`, then open one batch PR at the end. The batch PR closes all included issues. You wake from AFK to **one** PR with N commits.

Direct-invoke locally OR one-shot via `/schedule` for AFK. Same design either way.

## When to use this vs. `/conduct-issues`

This is the **engine**, optimized for **one batch of stacked work** — issues that import from or build on each other (e.g., module slices: bootstrap → schema → list pages → detail pages → quotes). For these queues, "one PR per issue, all branched off `origin/<baseBranch>`" doesn't work without a human merging between issues, which defeats the AFK promise. Invoke it directly when you want exactly one batch, right now, in-session.

For everything above a single batch — partitioning a mixed queue into independent groups, running ≤`maxConcurrentBatches` scoped runs concurrently, live-QAing UI batch PRs, chaining batches across merges overnight — use `/conduct-issues` (usually as `/loop /conduct-issues`). It launches scoped instances of this command and owns nothing engine-level. (`/fan-out-issues` was the old one-shot partition layer; deleted 2026-07-10, absorbed into `/conduct-issues`.)

## Project portability

This command lives at `~/.claude/commands/iterate-issues.md` and is available in every git repo on this machine. It auto-detects the GitHub repo, base branch, and worktree path from the current working directory, so no per-project install step is needed.

Per-project tuning (verification commands, framework-citation rules, etc.) is optional — drop a `.iterate-issues.json` at the repo root. See `~/.claude/commands/iterate-issues/config/.iterate-issues.example.json` for the schema.

## Bundled artifacts

- `~/.claude/commands/iterate-issues/templates/planner-prompt.txt` — task prompt for the planner subagent (Step 4.3).
- `~/.claude/commands/iterate-issues/templates/implementer-prompt.txt` — task prompt for the implementer subagent (Step 4.5).
- `~/.claude/commands/iterate-issues/scripts/advance-issue.sh` — deterministic issue-label transitions (Steps 4.1 / 4.6), so a boundary flip can't be half-applied under context pressure.

Step 6 (bot-review loop) delegates to `/await-review`, which is a sibling command that owns:

- `~/.claude/commands/_shared/bot-review-loop.sh` — deterministic state-machine for polling the bot-review check and deduping comments.
- `~/.claude/commands/_shared/handler-prompt.txt` — task prompt for the review handler subagent.

These two are shared with `/await-review` so the same loop is used whether you're draining issues (this command) or babysitting a single-feature PR (`/await-review`).

## Pipeline position

```
design doc → /grill-me (ad-hoc) → /to-prd → /to-issues → /triage → /iterate-issues → review one PR → merge
```

Matt's skills (`/grill-me`, `/to-prd`, `/to-issues`, `/triage`) are upstream and stay untouched.

## Critical invariants

- **Single batch branch.** Every issue's commits land on the same branch (`agent/batch-<YYYYMMDD>[-<lowest-scoped-issue>]`) off the project's base branch. No per-issue branches. No worktree-per-issue. One PR at the end. The `-<lowest>` suffix is present only when the run is scoped to specific issue numbers (see Step 0); it keeps concurrent and same-day batches from colliding.
- **Sequential, not parallel.** Each issue's implementer sees the previous issue's commits in its working tree, naturally resolving stacked-import dependencies.
- **Single isolated worktree.** The whole batch runs in `../<repo-name>-batch[-<lowest-scoped-issue>]/`. Your main checkout's dirty state on whatever branch is irrelevant. Because the path carries the same scope suffix as the branch, two scoped runs over disjoint issue sets get separate worktrees and never collide — see **Running concurrent batches** below.
- **State lives in GitHub.** Issue labels are the durable queue. Don't keep an in-memory queue; remote runs are stateless across sessions.
- **Skill reuse over reinvention.** Thin shim over `superpowers:writing-plans` + `superpowers:subagent-driven-development` + `superpowers:receiving-code-review`. Override the subagent's "push and open PR" default via the implementer task prompt; don't fork the skill. Don't override the `superpowers` skills' internal model selections — they know what they're doing.
- **You merge.** This command opens one PR and stops. You review it, you merge.

## Running concurrent batches

Two `/iterate-issues` runs can drain the same repo at once **as long as their issue sets are disjoint and each run is scoped** (issue numbers passed as arguments). The scope suffix (`-<lowest-issue>`, Step 0) gives each run its own worktree dir and batch branch, so they never fight over `../<repo>-batch` or `agent/batch-<date>`. This replaces the manual worktree/branch override earlier batches did by hand.

Rules for safe concurrency:

- **Always scope both runs.** A bare run (no args) drains *every* `ready-for-agent` issue and uses the unsuffixed default — running it alongside anything else will double-pick issues and collide on the worktree. Never pair a bare run with another run.
- **Keep the scopes disjoint.** Two scopes that share an issue would both try to implement it. The lowest-issue suffix is collision-free only because each issue belongs to exactly one batch.
- **Resume = re-invoke with the same args.** Batch identity is a pure function of the scoped issue numbers, so resuming a crashed scoped run means passing the same numbers again (Step 1).

## Step 0 — Detect repo context

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")

# Optional scoping. $ARGUMENTS holds the issue numbers the run is restricted to,
# exactly as typed — tokens may carry a leading '#' (e.g. "#507 #506") or be bare.
# Empty → bare run: drain every open ready-for-agent issue (legacy).
# grep -oE pulls the digit runs out of each token, so a leading '#' (which would
# otherwise start a shell comment and silently empty the scope) is harmless.
SCOPE=$(printf '%s\n' "$ARGUMENTS" | grep -oE '[0-9]+' | sort -n -u)   # sorted, deduped; may be empty
LOWEST=$(printf '%s\n' "$SCOPE" | head -1)                            # lowest scoped issue, or empty
SUFFIX="${LOWEST:+-$LOWEST}"   # "-507" when scoped; "" for a bare run

# The suffix is what makes concurrent / same-day batches safe: each scoped run gets
# its own worktree dir and branch. It is a pure function of the args, so resuming a
# scoped run = re-invoking with the same issue numbers (see Step 1).
BATCH_BRANCH="agent/batch-$(date +%Y%m%d)${SUFFIX}"
WORKTREE_DIR="$(dirname "$REPO_ROOT")/${REPO_NAME}-batch${SUFFIX}"
# Plans live in a sibling dir, NOT inside the worktree — so an implementer's
# commit can never sweep a plan file in. One file per issue (Step 4.3/4.5).
PLANS_DIR="$(dirname "$REPO_ROOT")/${REPO_NAME}-batch${SUFFIX}-plans"

# Read project config if present (optional). All keys default if absent.
CONFIG="$REPO_ROOT/.iterate-issues.json"
BASE_BRANCH=$(jq -r '.baseBranch // "main"' "$CONFIG" 2>/dev/null || echo "main")
SETUP_CMD=$(jq -r '.setupCommand // "npm ci"' "$CONFIG" 2>/dev/null || echo "npm ci")
CEILING_HOURS=$(jq -r '.sessionCeilingHours // 8' "$CONFIG" 2>/dev/null || echo 8)

# Wall-clock anchor for the session ceiling (see Budgets + Step 4.0).
BATCH_START=$(date +%s)
```

If `gh repo view` or `git rev-parse` fails, abort with "not a github repo / not in a git working tree."

**Scoping semantics.** When `$SCOPE` is non-empty, this run only ever touches those issue numbers — Step 2 intersects the `ready-for-agent` queue with `$SCOPE`, and Step 1 only adopts in-progress issues that are in `$SCOPE`. This is both the parallel-safety mechanism and the way to run a deliberate subset (e.g. infra issues while another agent drains a feature PRD). Passing no arguments preserves the original "drain everything" behavior on the unsuffixed default worktree.

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
| Session ceiling (**single-PR scope ceiling**) | `sessionCeilingHours` (default 8h), **checked at each issue boundary — Step 4.0** | Not an emergency stop — a normal close-out: proceed to Step 5 (open the batch PR with completed issues), run the bot-review loop, leave the rest of the queue labeled `ready-for-agent` for the next run. |

The ceiling exists to bound **review burden per PR** and **orchestrator context length**, not data safety (the branch is pushed after every issue — Step 4.6). Since it's only checked between issues, real overshoot is bounded by ceiling + one issue's max time (~1h).

## Step 1 — Reconciliation pass (resume safety)

Before pulling the queue, detect a crashed prior batch.

```bash
gh issue list --repo "$REPO" --state open --label in-progress --json number,title
```

**Resume identity is this run's `$WORKTREE_DIR` / `$BATCH_BRANCH` (already carrying the scope suffix from Step 0), not "any batch worktree."** A concurrent batch over a different scope lives at a different suffixed path with its own in-progress issues — never adopt it. Concretely: when `$SCOPE` is non-empty, **ignore any in-progress issue whose number is not in `$SCOPE`** (it belongs to another run), and only treat the worktree at `$WORKTREE_DIR` as ours. This is why resuming a scoped run means re-invoking with the same issue numbers — that reconstructs the same suffix and points Step 1 at the right worktree.

Cases (read "worktree" / "in-progress issue" as "at `$WORKTREE_DIR`" / "within `$SCOPE`"):

- **Worktree exists, branch exists, in-progress issue exists.** Resume: cd into worktree, reset uncommitted changes (`git reset --hard HEAD && git clean -fd`), re-run the in-progress issue from scratch starting at the planner stage (its label stays `in-progress`). Restarting from planning is safe whether the prior crash was mid-planning or mid-implementation.
- **Worktree exists but no in-progress issue.** Prior batch finished implementation but never opened the batch PR. Skip to Step 5 (open batch PR).
- **In-progress issue (in `$SCOPE`) exists but no worktree at `$WORKTREE_DIR`.** Worktree was deleted; state was lost. Label the issue `needs-human` with comment "worktree missing on resume; manual investigation needed." Continue queue.
- **Neither exists.** Fresh run. Proceed to Step 2.

## Step 2 — Pull and order the queue

```bash
gh issue list --repo "$REPO" --state open --label ready-for-agent \
  --json number,title,body,labels --jq 'sort_by(.number)'

gh issue list --repo "$REPO" --state open --label needs-triage \
  --json number --jq 'length'   # for final summary notice
```

**Apply the scope.** If `$SCOPE` is non-empty, drop every pulled issue whose number is not in `$SCOPE`. For any number in `$SCOPE` that is *not* in the pulled set (closed, missing, or not labeled `ready-for-agent`), log a one-line warning and skip it — do not fail the run. The resulting scoped queue is what the rest of the steps operate on.

If the (scoped) `ready-for-agent` queue is empty, exit cleanly: "no ready-for-agent issues. (N still in needs-triage.)"

For each issue, scan the body for **either** `Depends on #N` **or** `Blocked by[:]?\s*#N` lines (both are dependency edges; `/triage` issue templates use the second form). Topo-sort if any are present, otherwise ascending by issue number. Treat closed issues as satisfied dependencies; treat any open dependency that isn't itself in the current `ready-for-agent` queue as a hard blocker — label the dependent issue `needs-human` and skip it.

**Undecided-rule guard.** `/triage` should never let an issue reach `ready-for-agent` with a product decision still open, but it is Matt's upstream skill and can't enforce that from here — so re-check at pickup. If an issue body still carries an unresolved-decision marker (e.g. "decide … during triage", "OPEN DECISION", "TBD", "to be defined/decided", or an unchecked decision checkbox in a "decisions to resolve" list), do **not** plan it: label it `needs-human` with comment "unresolved decision reached ready-for-agent — re-triage before agent pickup" and skip. Letting the orchestrator or planner make the product call is luck, not process (retro #676 item 7).

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

### 4.0 Session-ceiling check (before picking up the issue)

```bash
ELAPSED_H=$(( ($(date +%s) - BATCH_START) / 3600 ))
```

If `ELAPSED_H >= CEILING_HOURS`, stop picking up new issues and go straight to Step 5. This is the **only** enforcement point of the session ceiling — an LLM orchestrator has no alarm clock, so the check must run deterministically at every issue boundary. Remaining issues keep their `ready-for-agent` label and queue for the next run.

### 4.1 Mark in-progress

```bash
~/.claude/commands/iterate-issues/scripts/advance-issue.sh "$REPO" start <N>
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
| Plan returned with `CITATIONS` block (or explicit "no framework-specific naming choices made") | Write the plan verbatim to `$PLANS_DIR/issue-<N>.md` (`mkdir -p "$PLANS_DIR"` first), then proceed to 4.5 passing that path — do **not** inline the plan text into the implementer prompt. |
| `BLOCKED` | `gh issue edit <N> --remove-label in-progress --add-label needs-human`. Comment with planner's reason. **Skip implementer, continue queue.** No rollback needed (planner is read-only). |
| 15-min budget exceeded | Same as `BLOCKED`. Comment notes budget exceedance. |
| Plan returned without a `CITATIONS` block, but the spec implies framework-specific naming (e.g., touches `middleware.ts`, `route.ts`, `layout.tsx`, migration files, etc.) | Treat as `BLOCKED`. Comment "missing CITATIONS block — re-plan after planner adds doc citations." |

### 4.5 Dispatch implementer subagent

Read `~/.claude/commands/iterate-issues/templates/implementer-prompt.txt` and substitute:

| Placeholder | Value |
|---|---|
| `<N>` | issue number |
| `<issue title>` | issue title (used in commit-message format) |
| `<PLAN_PATH>` | `$PLANS_DIR/issue-<N>.md` — the file written in 4.4, read by the implementer (keeps the plan out of the prompt) |
| `<issue body>` | the original issue body |

Invoke `superpowers:subagent-driven-development` with model `sonnet`, working directory `$WORKTREE_DIR`, and the rendered prompt as the task input.

The plan travels as a **file path**, not inlined text — the implementer reads `<PLAN_PATH>` itself. Same fidelity, no large duplication in the dispatch prompt (retro #676 item 8). The plans dir is a worktree sibling, so plan files are never committed.

Two-stage review (spec compliance + code quality) is built into `subagent-driven-development` — don't skip it.

### 4.6 On implementer return

| Outcome | Action |
|---|---|
| Success | Run the **issue-boundary checklist**: (1) `~/.claude/commands/iterate-issues/scripts/advance-issue.sh "$REPO" done <N>` (or `advance <N> <next>` to also pick up the next issue in one call); (2) `git -C "$WORKTREE_DIR" push -u origin "$BATCH_BRANCH"` — branch only, NO PR; (3) update TodoWrite. Then move to next issue. |
| `BLOCKED` / `NEEDS_CONTEXT` | `git -C "$WORKTREE_DIR" reset --hard "$START_COMMIT" && git clean -fd`. `gh issue edit <N> --remove-label in-progress --add-label needs-human`. Comment with the blocker (include the plan so the human can see what the implementer was given). **Continue queue.** |
| 45-min budget exceeded | Same as `BLOCKED`. Comment notes the budget exceedance. |
| Implementer pushed or opened a PR despite the directive | Close the rogue PR, delete the rogue branch from remote, do NOT count this issue as `done`. Label `needs-human` with comment "implementer ignored batch-mode directive." Continue queue. |

**Do not abort the whole batch for one bad issue.** Forward progress is the point.

**Per-issue push semantics.** The orchestrator pushing `$BATCH_BRANCH` after each `done` issue is NOT the rogue-push failure mode — rogue means the *implementer* opened a PR or pushed a *non-batch* branch. The per-issue push exists so a crash at any point loses at most one issue's work (~30 min), instead of the whole night. Known cost, accepted by design: each push triggers a Vercel preview build (GitHub Actions workflows are `pull_request`-triggered and don't fire on branch pushes). Do NOT open a PR mid-run; the PR happens exactly once, at Step 5.

## Step 5 — Open the batch PR

After the queue is drained (or the session ceiling hit at Step 4.0):

### 5.0 Commit↔label reconciliation (deterministic, before the PR)

Label flips are orchestrator bookkeeping and can be missed under long-session context pressure. Before building the PR body, cross-check the branch against the labels:

```bash
cd "$WORKTREE_DIR"
# Issue numbers that actually have commits on the batch branch:
COMMITTED=$(git log --format='%s' "origin/$BASE_BRANCH"..HEAD | grep -oE '#[0-9]+' | tr -d '#' | sort -n -u)
# Issue numbers currently labeled done:
LABELED=$(gh issue list --repo "$REPO" --state open --label done --json number --jq '.[].number' | sort -n)
```

For every number in `COMMITTED` but not in `LABELED` that is part of this run's queue: it was implemented but the label flip was missed — fix it now (`--remove-label in-progress --add-label done`). For every number in `LABELED` but not in `COMMITTED`: stale label from elsewhere; exclude it from this PR's `Closes` list (the PR body must only close issues whose commits are on this branch).

### 5.1 Push and open the PR

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

### 5.2 UI-heavy batch → flag for live QA

Static review, jsdom, and the planner are all blind to pad/touch CSS-cascade bugs (a standing project lesson: they only surface in a live ~810px browser). An AFK run can't drive a browser, so it must not imply UI correctness it never checked. Detect whether the batch touched UI surfaces:

```bash
cd "$WORKTREE_DIR"
UI_HITS=$(git diff --name-only "origin/$BASE_BRANCH"..HEAD \
  | grep -cE '\.(css|scss)$|\.(tsx|jsx)$' || true)
```

If `UI_HITS` > 0, add a prominent line to the Step 7 summary: **"⚠️ UI-touching batch (<UI_HITS> files) — run a live browser pass (e.g. `/verify` or Chrome at 810px on the changed screens) BEFORE merging; the bot loop did not exercise the rendered UI."** This is advisory (no label, no block) — the point is to never present a UI batch as merge-ready without saying the visual layer is unverified.

## Step 6 — Bot review loop (delegated to `/await-review`)

Delegate to `/await-review $PR_NUM`. It owns the polling/dedup state machine, the Haiku handler dispatch loop, and the 3-round cap. Pass `INPROGRESS_LABEL=batch-pr-open` via env so it clears that label from the batch PR on terminal exit:

```bash
INPROGRESS_LABEL=batch-pr-open /await-review "$PR_NUM"
```

`/await-review` handles termination labelling itself: `needs-human` on `NEEDS_HUMAN`, `bot-review-timeout` on 30-min poll timeout, no label on clean exit. See `~/.claude/commands/await-review.md` for the full termination matrix and the code-review workflow contract (both apply unchanged here).

When `/await-review` returns, proceed to Step 7 and report its final status in the batch summary.

## Step 7 — Final summary

Post as text:

```
## Iterate-issues batch summary

Batch branch: <$BATCH_BRANCH, e.g. agent/batch-20260628-507>
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
| Session ceiling (`sessionCeilingHours`) hit at Step 4.0 | Normal close-out, not a failure: proceed to Step 5, open batch PR with whatever's done, post partial summary. Remaining `ready-for-agent` issues stay queued for next run. Branch is already on remote (per-issue push). |
| Worktree exists but on wrong branch | Step 1 detects via `git -C "$WORKTREE_DIR" branch --show-current`. If branch != `$BATCH_BRANCH`, label all in-progress issues `needs-human` and stop. Manual cleanup. |
| `gh repo view` fails (not a GitHub repo) | Abort with "this command requires a GitHub remote." |

## What this command does NOT do

- Does not merge the batch PR. You merge.
- Does not close issues (they close via `Closes #N` when the PR merges).
- Does not push migrations without manual review (orchestrator refuses + labels `needs-human` if an issue requires one).
- Does not bypass `pre-commit` hooks. Failed hook → implementer fixes the underlying issue.
- Does not re-run `/triage` on `needs-triage` issues. It surfaces the count; you triage.
- Does not handle fan-out queues (independent issues for parallel PRs) or cross-batch orchestration. For that, use `/conduct-issues`, which partitions the queue and runs scoped instances of this command.
