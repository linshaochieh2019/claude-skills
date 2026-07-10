---
argument-hint: "[optional issue numbers to restrict the conducted queue — omit to conduct the whole ready-for-agent queue]"
description: One stateless conductor tick, designed to be driven by `/loop /conduct-issues` — keeps scoped /iterate-issues batches flowing unattended. Partitions the live queue at launch time, bounds work-in-flight, live-QAs UI batch PRs in Chrome, pings you when a PR is merge-ready, cleans up after you merge, then launches the next batch. Never merges, never applies migrations. Use when you want the issue pipeline to keep itself moving overnight while you stay the merge gate.
---

# /conduct-issues — pipeline conductor (one tick per invocation)

The family is exactly two commands:

- `/iterate-issues` — the **engine**: drains one scoped batch end-to-end into one PR. All quality machinery (planner/implementer split, budgets, two-stage review, per-issue push, `/await-review`) lives there, unchanged. Invoke it directly only when you want exactly one batch, right now, in-session.
- `/conduct-issues` (this) — **everything above the engine**: each invocation is a single stateless *tick* that reads live GitHub state and does whatever keeps the pipeline moving — then ends. Driven by `/loop /conduct-issues` (dynamic pacing), the ticks chain batches across the whole night while the human merge gate stays human. A single un-looped invocation is also meaningful: one tick = "partition and launch what fits / QA what's ready" — this subsumes the retired `/fan-out-issues` (deleted 2026-07-10; its partition rules now live in Action E below).

**The one entry point to remember: `/loop /conduct-issues`.**

This command invents **no new implementation path**. It only decides *when* to launch *what*, adds the live-browser QA stage the AFK engine cannot do (its Step 5.2 can only warn), and tells you when a PR is actually merge-ready.

## Invariants

- **Never merge, never close issues.** The human merge gate is the pipeline's last quality guarantee; removing it is not an optimization.
- **Never launch a bare run.** Every batch this command starts is a *scoped* `/iterate-issues <numbers>` (scope suffix = collision safety).
- **State lives in GitHub, re-read every tick.** A loop session gets summarized; labels, PRs, checks, and marker comments are the only trustworthy memory. Never act on what a previous tick "remembered".
- **WIP cap.** In-flight = (batches still implementing) + (open unmerged `agent/batch-*` PRs) ≤ `maxConcurrentBatches` (config, default 2). The cap bounds review-bot quota (false-clean under concurrent load, observed 2026-06-25) *and* your merge burden — don't pile inventory in front of the constraint.
- **Partition at launch time, never earlier.** The next group is computed from the queue as it exists *at that tick* — issues opened mid-loop join the next partition automatically.
- **DB writes stay deferred.** Same as the engine: migrations are written as files only; anything needing a live-DB/PII write goes `needs-human`.
- **QA fix loop is bounded to ONE round.** One fix dispatch, one re-QA. Still broken → `needs-human` + notify. No tight loops.

## Step 0 — Read live state (every tick)

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
REPO_ROOT=$(git rev-parse --show-toplevel)
CONFIG="$REPO_ROOT/.iterate-issues.json"
MAX_WIP=$(jq -r '.maxConcurrentBatches // 2' "$CONFIG" 2>/dev/null || echo 2)

# Optional restriction, same digit-extraction semantics as /iterate-issues.
SCOPE=$(printf '%s\n' "$ARGUMENTS" | grep -oE '[0-9]+' | sort -n -u)

# 1. The queue (intersect with $SCOPE when non-empty).
gh issue list --repo "$REPO" --state open --label ready-for-agent --json number,title,body
# 2. Issues mid-implementation (theirs or ours — both count as WIP).
gh issue list --repo "$REPO" --state open --label in-progress --json number,title
# 3. Batch PRs, open and recently merged.
gh pr list --repo "$REPO" --state open   --search 'head:agent/batch' --json number,headRefName,headRefOid,url
gh pr list --repo "$REPO" --state merged --search 'head:agent/batch' --limit 10 --json number,headRefName
# 4. Worktrees left behind by batches.
git worktree list
# 5. Triage backlog (surfaced in notifications, never triaged here).
gh issue list --repo "$REPO" --state open --label needs-triage --json number --jq 'length'
```

Also note which background child tasks from earlier ticks are still alive (the harness notifies on completion — but a notification's exit code lies; the PR/label state above is the ground truth for whether a batch actually succeeded).

## Step 1 — Act (process every action that applies, in this order)

Actions are independent; one tick may clean up a merged PR *and* launch a new batch *and* QA another PR.

### A — Resume an orphaned batch

`in-progress` issues exist, no live child task is working them, and their scope-suffixed worktree exists → the child crashed. Re-launch a background scoped `/iterate-issues` with **the same issue numbers** (batch identity is a pure function of the args; its own Step 1 reconciliation handles the rest), model `opus` pinned as in Action E. Worktree missing too → leave it; the engine's reconciliation will `needs-human` it on the next scoped run.

### B — Clean up after your merge

For each *merged* batch PR whose worktree still exists locally: `git worktree remove <dir>`, `git worktree prune`, delete the sibling `*-plans/` dir. This frees the WIP slot. (Engine Step 8, automated.)

### C — Live QA a reviewed batch PR

Trigger: an open batch PR where **all three** hold —

1. The `Code Review` check **actually SUCCEEDED** (`gh pr checks` — a quota-exhausted bot exits clean without reviewing; verify the check conclusion, not the absence of comments).
2. The diff touches UI (`git diff --name-only origin/<base>...HEAD` has `.css/.scss/.tsx/.jsx` — three-dot, so main's drift doesn't pollute the answer).
3. No comment `<!-- conductor-live-qa <headRefOid> -->` exists yet for the current head SHA.

Procedure:

1. Derive the changed screens/routes from the diff.
2. Start the app **from the batch worktree** per the config's `liveQa` block (see below); if absent, consult the repo's CLAUDE.md / runbooks for the sanctioned local-QA path.
3. Drive Chrome (load `claude-in-chrome` tools via one ToolSearch batch) through each changed screen at every breakpoint the config names. Be picky — pixel-perfection standards apply; flag anything that looks off even if unrelated.
4. Post one PR comment starting with `<!-- conductor-live-qa <headRefOid> -->`, verdict `QA: CLEAN` or `QA: DEFECTS`, with concrete findings (screen, breakpoint, what's wrong).
5. Kill the dev server.
6. On `DEFECTS`: **one** fix round — dispatch a subagent (sonnet) in the batch worktree, scope hard-limited to the QA findings' blast radius, never migrations/schema, commit + push (new head SHA → C re-triggers exactly once). Second `DEFECTS` on the same PR → label it `needs-human`, notify, stop touching it.

A PR whose diff has no UI files skips straight to D.

### D — Ping you when a PR is merge-ready

An open batch PR with `Code Review` succeeded, QA clean or not applicable, and no `<!-- conductor-merge-ping <headRefOid> -->` comment yet → leave that marker comment, then send a PushNotification (load via ToolSearch): PR number, issues included, QA verdict, and the current `needs-triage` count (so you can top up the queue while merging). **Then wait — merging is yours.**

### E — Launch the next batch

If in-flight WIP < `MAX_WIP` and the (scoped) queue has issues not `in-progress`/`needs-human`:

0. **Cross-batch dependency deferral.** Scan eligible issues for `Depends on #N` / `Blocked by #N` edges. If a dependency is an open issue that is *not* itself eligible this tick — typically labeled `done`, sitting in an unmerged batch PR — **hold the dependent issue for a later tick**: exclude it from this partition instead of letting the engine `needs-human` it. Once you merge that PR the dependency closes, the next batch bases on the updated main, and the held issue becomes eligible naturally. (This is how a chain longer than one session ceiling flows across PRs: PR₂ builds on PR₁ *through main*, gated by your merge.)

1. **Partition** the eligible queue. Analysis is delegated: dispatch a subagent that runs the `parallel-safety-check` skill over the issues (number, title, body each), prompted that it is **non-interactive** (conclude, never ask a human), must predict the files/modules each issue touches (read-only repo exploration as needed), and must return safe-to-parallelize groups + the serial queue + per-edge reasons.
2. **Converge conservatively** (this command's own logic — bias, not approval, is the no-HITL safety mechanism):
   - When in doubt, same group. A wrong merge costs only wall-clock; a wrong split costs conflicting PRs and a human untangling them.
   - Dependency edges (`Depends on #N` / `Blocked by #N`) → same group, always.
   - Predicted shared files → same group; watch known hotspots (design-system CSS, shared primitives, glossary/CONTEXT docs).
   - A serial chain goes into ONE group whole — never split a chain.
   - Balance groups by issue count, not by maximizing group count. Everything collapsing into one group is a fine answer.
3. Order groups: any group containing a P0 first, then P1, then lowest issue number.
4. Launch as many groups as free WIP slots allow (usually one): background general-purpose subagent with **model `opus` pinned explicitly** — the child is an `/iterate-issues` orchestrator and that command's Models table specifies Opus; never let it silently inherit the loop session's model. Task = *run `/iterate-issues <group numbers>` in this repo, following `~/.claude/commands/iterate-issues.md` end-to-end* (its planner/implementer/handler tiers are pinned inside that command and unaffected). Do **not** wait for it — end the tick.
5. Log the partition + reasons as text (the audit trail for the no-HITL decision).

Never launch two groups sharing an issue number; never launch anything already `in-progress`.

### F — Nothing left

Queue empty, no batch running, no unmerged batch PR → post a final one-line summary (include `needs-triage` count) and **end the loop** (in `/loop` dynamic mode: `ScheduleWakeup {stop: true}`).

## Pacing (for `/loop` dynamic mode)

| State when the tick ends | Next wakeup |
|---|---|
| A child batch is running | 1800s — its completion notification is the real wake signal; this is only the hang-fallback |
| Only waiting on your merge | 1800s |
| Adopted PR still mid-bot-review | 270s |
| Nothing left (action F) | stop |

## Config — `liveQa` block in `.iterate-issues.json`

Optional, freeform strings the QA step follows verbatim:

```json
"liveQa": {
  "start":       "how to boot the app from a batch worktree (env files to copy, port to use)",
  "url":         "where the running app answers",
  "login":       "the sanctioned QA auth path",
  "breakpoints": "which widths to test and how to achieve them",
  "standards":   "which doc is law for judging what you see"
}
```

## What this command does NOT do

- Does not merge, close issues, or apply migrations/DB writes — ever.
- Does not re-implement anything `/iterate-issues` owns; it launches and observes scoped instances of it.
- Does not triage. `needs-triage` issues are counted and surfaced, never picked up.
- Does not exceed the WIP cap, and never launches a bare (unscoped) run.
- Does not loop on a defective PR: one fix round, then `needs-human`.
- Does not tolerate a concurrent **bare** `/iterate-issues` (it would double-pick issues). Concurrent *manual scoped* runs are fine — their labels/PRs are counted as WIP automatically.
