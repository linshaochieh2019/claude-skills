---
argument-hint: "[optional issue numbers to restrict the conducted queue — omit to conduct the whole ready-for-agent queue]"
description: One stateless conductor tick, designed to be driven by `/loop /conduct-issues` — keeps scoped /iterate-issues batches flowing unattended. Partitions the live queue at launch time, bounds work-in-flight, live-QAs UI batch PRs in Chrome, pings you when a PR is merge-ready, cleans up after merges, then launches the next batch. Never merges itself and never applies migrations; when the repo opts in via mergePolicy.autoMerge it dispatches /land-pr (autonomous) for safe-tier PRs, while migrations/auth/payments PRs always wait for you. Use when you want the issue pipeline to keep itself moving overnight while you stay the gate for what matters.
---

# /conduct-issues — pipeline conductor (one tick per invocation)

The family is exactly two commands:

- `/iterate-issues` — the **engine**: drains one scoped batch end-to-end into one PR. All quality machinery (planner/implementer split, budgets, two-stage review, per-issue push, `/await-review`) lives there, unchanged. Invoke it directly only when you want exactly one batch, right now, in-session.
- `/conduct-issues` (this) — **everything above the engine**: each invocation is a single stateless *tick* that reads live GitHub state and does whatever keeps the pipeline moving — then ends. Driven by `/loop /conduct-issues` (dynamic pacing), the ticks chain batches across the whole night while the human merge gate stays human. A single un-looped invocation is also meaningful: one tick = "partition and launch what fits / QA what's ready" — this subsumes the retired `/fan-out-issues` (deleted 2026-07-10; its partition rules now live in Action E below).

**The one entry point to remember: `/loop /conduct-issues`.**

This command invents **no new implementation path**. It only decides *when* to launch *what*, adds the live-browser QA stage the AFK engine cannot do (its Step 5.2 can only warn), and tells you when a PR is actually merge-ready.

## Invariants

- **The conductor itself never merges, never closes issues.** Default: every merge belongs to the human. When the repo opts in (`mergePolicy.autoMerge: true` in `.iterate-issues.json`), the conductor may *dispatch* `/land-pr` in autonomous mode for **safe-tier** PRs only — classification, green gate, and post-merge verification all live in that skill, in one place. Risk-tier PRs (migrations, auth/RLS, payments/e-invoicing, anything under `needsHumanPaths`) are ALWAYS pinged to the human; that residual gate is the pipeline's last quality guarantee and is not negotiable.
- **A UI diff with no live QA never reaches the merge gate at all.** If the batch's diff touches UI files (globs in the config's `liveQa.uiDiffGate`) and live QA came back `DEFERRED` or `SKIPPED`, the PR is **hard-blocked**: no merge-ping, never autoMerge, BLOCKER comment instead (Action C2). A purely visual ticket's only acceptance procedure is *looking at it* — degrading that to a checklist line in a friendly deferral comment is how #895 shipped a layout nobody had ever seen (PR #904, 2026-07-11). Non-UI diffs are unaffected.
- **Never launch a bare run.** Every batch this command starts is a *scoped* `/iterate-issues <numbers>` (scope suffix = collision safety).
- **State lives in GitHub, re-read every tick.** A loop session gets summarized; labels, PRs, checks, and marker comments are the only trustworthy memory. Never act on what a previous tick "remembered".
- **Two WIP ledgers — active and parked. A PR waiting on a human is NOT work in flight.**
  - **Active** = (batches still implementing) + (open batch PRs still in the review/QA loop, i.e. head SHA can still move) ≤ `maxConcurrentBatches` (config, default 2). This is what actually burns agent compute and review-bot quota (false-clean under concurrent load, observed 2026-06-25) — keep it tight.
  - **Parked** = open batch PRs that have stopped and are waiting on *you*: a `<!-- conductor-merge-ping <headRefOid> -->` for the current head SHA, or a `needs-human` label. They consume **zero** agent capacity. Bounded separately by `maxParkedPRs` (config, default 5) — a cap on *your* merge burden and on merge-conflict surface, not on throughput.
  - **The moment a PR parks, it leaves the active ledger and the slot frees** — Action E may launch the next batch in the same tick. If its head SHA later moves (you commented, an agent pushed a fix), it re-enters the active ledger and the review/QA loop, exactly as the per-SHA markers already guarantee.
  - Why this is an invariant and not a tuning knob: **overnight, human availability is zero by definition**, so a parked PR is guaranteed to hold its slot until morning. Counting parked against active means two merge-pings deadlock the entire pipeline for the whole night — observed 2026-07-13: #969 parked 00:18, #970 parked 00:59, and the conductor then sat idle for 8.5 hours with 13 `ready-for-agent` issues untouched.
- **Partition at launch time, never earlier.** The next group is computed from the queue as it exists *at that tick* — issues opened mid-loop join the next partition automatically.
- **DB writes stay deferred.** Same as the engine: migrations are written as files only; anything needing a live-DB/PII write goes `needs-human`.
- **QA fix loop is bounded to ONE round.** One fix dispatch, one re-QA. Still broken → `needs-human` + notify. No tight loops.
- **Dispatch hygiene: `git -C`, never `cd && git`.** Every subagent prompt this command sends (QA fix rounds, inspections, anything touching a worktree from outside it) must state: cross-directory git is `git -C <path> ...` only — `cd <dir> && git ...` trips the harness's cd-before-git hook heuristic and forces a permission prompt **even when each part is allowlisted**. A prompt-blocked subagent emits no idle signal and looks identical to a hang (observed 2026-07-10: one batch stalled 3.5h on a confirmation box).
- **Unattended runs need a prompt-free session.** If the night is meant to be zero-touch, the loop session itself should run with `--permission-mode acceptEdits` (or a vetted allowlist); otherwise any stray un-allowlisted call silently parks a child until a human answers.

## Step 0 — Read live state (every tick)

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
REPO_ROOT=$(git rev-parse --show-toplevel)
CONFIG="$REPO_ROOT/.iterate-issues.json"
MAX_WIP=$(jq -r '.maxConcurrentBatches // 2' "$CONFIG" 2>/dev/null || echo 2)
MAX_PARKED=$(jq -r '.maxParkedPRs // 5' "$CONFIG" 2>/dev/null || echo 5)

# Optional restriction, same digit-extraction semantics as /iterate-issues.
SCOPE=$(printf '%s\n' "$ARGUMENTS" | grep -oE '[0-9]+' | sort -n -u)

# 1. The queue (intersect with $SCOPE when non-empty).
gh issue list --repo "$REPO" --state open --label ready-for-agent --json number,title,body
# 2. Issues mid-implementation (theirs or ours — both count as WIP).
gh issue list --repo "$REPO" --state open --label in-progress --json number,title
# 3. Batch PRs, open and recently merged.
#    Pull labels + comments too: they are what classify an open PR as ACTIVE vs PARKED.
gh pr list --repo "$REPO" --state open   --search 'head:agent/batch' --json number,headRefName,headRefOid,url,labels,comments
gh pr list --repo "$REPO" --state merged --search 'head:agent/batch' --limit 10 --json number,headRefName
# 4. Worktrees left behind by batches.
git worktree list
# 5. Triage backlog (surfaced in notifications, never triaged here).
gh issue list --repo "$REPO" --state open --label needs-triage --json number --jq 'length'
```

Also note which background child tasks from earlier ticks are still alive (the harness notifies on completion — but a notification's exit code lies; the PR/label state above is the ground truth for whether a batch actually succeeded).

**Then classify every open batch PR into exactly one ledger** (this is the input to Action E's slot arithmetic):

- **PARKED** — carries a `needs-human` label, **or** a `<!-- conductor-merge-ping <headRefOid> -->` comment whose SHA equals the PR's *current* `headRefOid`. It is waiting on the human and nothing else. Does **not** consume an active slot.
- **ACTIVE** — everything else: still implementing, mid-bot-review, awaiting QA, in a QA fix round, or its head SHA has moved past its merge-ping (→ it re-enters the loop). Consumes an active slot.

A merge-ping whose SHA is *stale* (head moved after the ping) does **not** park the PR — that PR is ACTIVE again.

```
ACTIVE_WIP = (live implementing batches) + (open batch PRs classified ACTIVE)
PARKED     = (open batch PRs classified PARKED)
```

## Step 1 — Act (process every action that applies, in this order)

Actions are independent; one tick may clean up a merged PR *and* launch a new batch *and* QA another PR.

### A — Resume an orphaned batch

`in-progress` issues exist, no live child task is working them, and their scope-suffixed worktree exists → the child crashed. Re-launch a background scoped `/iterate-issues` with **the same issue numbers** (batch identity is a pure function of the args; its own Step 1 reconciliation handles the rest), model `opus` pinned as in Action E. Worktree missing too → leave it; the engine's reconciliation will `needs-human` it on the next scoped run.

**Permission-hang watchdog.** A child that is *alive* but has produced no new commits on its branch and no idle signal for ~30+ min is presumed stuck on a permission prompt (see Dispatch hygiene invariant), not thinking. Nudge it once via SendMessage; no reaction → TaskStop it and re-launch per this action. Never let a silent child sit for hours on the assumption it's working.

### B — Clean up after your merge

For each *merged* batch PR whose worktree still exists locally: `git worktree remove <dir>`, `git worktree prune`, delete the sibling `*-plans/` dir. This clears it from both ledgers. (Engine Step 8, automated.) Note the *active* slot was already freed when the PR parked or landed — this action reclaims disk and the parked-ledger entry, it is not what unblocks Action E.

**Stale-label reconciliation.** An *open* batch PR still carrying `batch-pr-open` whose `Code Review` check has already concluded, with no live child owning it → the `/await-review` that should have cleared the label died mid-flight (e.g. its batch was killed/restarted). Remove the label here; downstream actions key off check conclusions, never off this label, so this is cosmetic-but-mandatory hygiene.

### C — Live QA a reviewed batch PR

Trigger: an open batch PR where **all three** hold —

1. The `Code Review` check **actually SUCCEEDED** (`gh pr checks` — a quota-exhausted bot exits clean without reviewing; verify the check conclusion, not the absence of comments).
2. The diff touches UI (`git diff --name-only origin/<base>...HEAD` has `.css/.scss/.tsx/.jsx` — three-dot, so main's drift doesn't pollute the answer).
3. No comment `<!-- conductor-live-qa <headRefOid> -->` exists yet for the current head SHA.

Procedure:

1. Derive the changed screens/routes from the diff.
2. Start the app **from the batch worktree** per the config's `liveQa` block (see below); if absent, consult the repo's CLAUDE.md / runbooks for the sanctioned local-QA path.
3. Drive Chrome (load `claude-in-chrome` tools via one ToolSearch batch) through each changed screen at every breakpoint the config names. Be picky — pixel-perfection standards apply; flag anything that looks off even if unrelated.
   **QA is read-only**: navigate, scroll, screenshot. Never type into inputs or toggle controls unless the config's `liveQa` block explicitly sanctions it — autosave UIs persist on `change`, so "just testing a field" writes real data (incident 2026-07-11: a header field PATCHed a live record during QA).
4. Post one PR comment starting with `<!-- conductor-live-qa <headRefOid> -->`, verdict `QA: CLEAN` or `QA: DEFECTS`, with concrete findings (screen, breakpoint, what's wrong).
5. Kill the dev server.
6. On `DEFECTS`: **one** fix round — dispatch a subagent (sonnet) in the batch worktree, scope hard-limited to the QA findings' blast radius, never migrations/schema, commit + push (new head SHA → C re-triggers exactly once). Second `DEFECTS` on the same PR → label it `needs-human`, notify, stop touching it.

A PR whose diff has no UI files skips straight to D.

### C2 — Hard-block a UI diff with no live QA

The gate rule lives in the config: `liveQa.uiDiffGate` in `.iterate-issues.json`. Read it and follow it verbatim; the text below is only how it plugs into the tick.

Trigger: an open batch PR where **all three** hold —

1. The diff touches UI files per `liveQa.uiDiffGate` (`git diff --name-only origin/<base>...HEAD` — three-dot — matching the globs that block names; in this repo `app/**/*.tsx` and `app/os/styles/**`). Let `N` = the number of matched files.
2. The `<!-- conductor-live-qa <headRefOid> -->` comment for the **current** head SHA carries a verdict of `DEFERRED` or `SKIPPED` — including every case where QA never opened a browser at all (env fail-closed, stale dataset, module not enabled).
3. No `<!-- conductor-ui-qa-blocker <headRefOid> -->` comment exists yet for the current head SHA.

Then:

1. Post one PR comment beginning `<!-- conductor-ui-qa-blocker <headRefOid> -->`, whose body is the BLOCKER template in `liveQa.uiDiffGate`, rendered with: `<N>` = the matched-file count, the verdict (`DEFERRED`/`SKIPPED`), the reason copied from the QA comment, and **every matched UI file listed, one per line**.
2. Label the PR `needs-human`.
3. **Skip D and D2 for this PR entirely.** No merge-ping. No `/land-pr` dispatch. Not this tick, not any later tick, for as long as this head SHA stands.

The `needs-human` label parks the PR (Step 0's classification), so its **active slot frees immediately** and Action E may still launch the next batch in this very tick — blocking a bad merge must never mean stalling the pipeline.

This is an **escalation of the existing deferral notice, not a new QA state**: the QA verdict is still `DEFERRED`. What changed is that on a UI diff it now *blocks the merge* instead of reading as a friendly reminder that gets skimmed past next to the risk-tier checklist.

If a later push moves the head SHA, the per-SHA markers make C re-QA from scratch and this gate re-evaluate. A re-QA that comes back `CLEAN` clears the block: remove the `needs-human` label and let the PR proceed to D/D2 normally.

### D — Ping you when a PR is merge-ready

An open batch PR with `Code Review` succeeded, QA clean or not applicable, and no `<!-- conductor-merge-ping <headRefOid> -->` comment yet → leave that marker comment, then send a PushNotification (load via ToolSearch): PR number, issues included, QA verdict, and the current `needs-triage` count (so you can top up the queue while merging). **Then wait — merging is yours.**

Leaving that marker moves the PR to the **PARKED** ledger *immediately* — its active slot is free from this tick onward, so Action E may launch the next batch in the very same tick. Waiting on the human must never mean waiting on the pipeline.

**The trigger list for D is closed.** A PR parks here for exactly three reasons, and there is no fourth:

1. **Risk tier** — touches `needsHumanPaths` / `supabase/migrations/`.
2. **`Code Review` did not succeed.**
3. **QA is not CLEAN** — `DEFECTS` (after its one fix round), or `DEFERRED`/`SKIPPED` **on a diff with no UI files**. A `DEFERRED`/`SKIPPED` QA on a diff that *does* touch UI files never reaches D at all: it is hard-blocked by **C2**, which posts a BLOCKER comment and `needs-human` instead of a merge-ping. Parking a UI-diff PR with a merge-ready ping is exactly the #904 failure.

Anything else that is green and safe-tier goes to D2 and lands. In particular, **the conductor has no discretionary hold.** If you find yourself reasoning "the code is fine and the risk is safe, but I'd like a human to weigh in on X" — X is a follow-up issue, not a parked PR. See D2.

### D2 — Auto-land a safe-tier PR (config-gated)

Only when `mergePolicy.autoMerge` is `true` in the repo config.

**These conditions are jointly sufficient. Meet them and you land — there is no further judgement to exercise:**

- `Code Review` **succeeded**, and
- QA is **CLEAN** or not applicable, and
- the PR classifies **safe tier** under `/land-pr`'s risk gate (no file under `needsHumanPaths`, no migrations), and
- no `<!-- conductor-autoland <headRefOid> -->` comment exists for the current head SHA, and
- **C2 did not fire** — a diff touching UI files whose QA is `DEFERRED`/`SKIPPED` is **never** auto-landed, regardless of tier or check colour.

Then:

1. Leave the `<!-- conductor-autoland <headRefOid> -->` marker comment (dispatch-dedup, same pattern as C/D).
2. Dispatch a background subagent running `/land-pr <n>` in **autonomous mode** (its prompt must say no human is available). The skill re-runs its own classification and green gate — the conductor's pre-check is a dispatch filter, not the safety mechanism.
3. Do not wait; end the tick. The merged PR shows up in the next tick's Step 0 read → Action B cleans its worktree → the slot frees → Action E launches the next group. Merges flow the pipeline automatically.

#### An unmet acceptance criterion is NOT a reason to hold a green PR

`autoMerge: true` is the human's standing instruction: *safe tier, green, QA'd → land it, don't wake me.* It is not conditional on the batch having satisfied every AC.

So when a green safe-tier batch shipped a **knowingly unmet or unreachable AC** — the spec asked for something arithmetically impossible, or the implementer made a defensible trade between two ACs — **land it anyway** and:

- **File a follow-up issue** (`needs-triage`) capturing the gap: which AC, why it was not met, what shipped instead, and the decision the human actually needs to make. Reference the original issue and the landed PR.
- **Name that follow-up in the autoland notification**, so the question reaches the human without the pipeline holding still to ask it.

The shipped *behaviour* was reviewed, QA'd in a real browser, and is risk-free by classification. **A spec that contradicts reality is a bug in the spec, not in the PR** — and it costs a whole night to ask about it at 00:18 (observed 2026-07-13: #969 was green, SAFE, QA CLEAN, and still parked until morning over #946's AC1 asking for four columns in a viewport that cannot fit four columns).

If a gap is genuinely bad enough that the code should not ship, that is not a hold — that is **`QA: DEFECTS`**, and it goes through C's fix round. "Green, but I'm holding it" is the worst of both: it blocks throughput without blocking any defect.

Risk-tier PRs, config absent, or `autoMerge: false` → Action D ping, exactly as before. A PR whose head SHA moved after its QA marker re-enters C first (per-SHA markers already guarantee this).

### E — Launch the next batch

If `ACTIVE_WIP < MAX_WIP` **and** `PARKED < MAX_PARKED` and the (scoped) queue has issues not `in-progress`/`needs-human`:

Note the two gates are separate and mean different things. `ACTIVE_WIP` is throughput — parked PRs are excluded from it, so a night full of merge-pings still launches batches. `PARKED >= MAX_PARKED` is the **only** state where waiting-on-you legitimately stops the pipeline: your review backlog is genuinely full, and piling on more inventory in front of the constraint helps nobody. On hitting it, launch nothing, send one PushNotification naming the parked PRs, and end the tick — do not treat it as action F (there is still work queued; you are the bottleneck, not the queue).

0. **Cross-batch dependency deferral.** Scan eligible issues for `Depends on #N` / `Blocked by #N` edges. If a dependency is an open issue that is *not* itself eligible this tick — typically labeled `done`, sitting in an unmerged batch PR — **hold the dependent issue for a later tick**: exclude it from this partition instead of letting the engine `needs-human` it. Once you merge that PR the dependency closes, the next batch bases on the updated main, and the held issue becomes eligible naturally. (This is how a chain longer than one session ceiling flows across PRs: PR₂ builds on PR₁ *through main*, gated by your merge.)

1. **Partition** the eligible queue. Analysis is delegated: dispatch a subagent that runs the `parallel-safety-check` skill over the issues (number, title, body each), prompted that it is **non-interactive** (conclude, never ask a human), must predict the files/modules each issue touches (read-only repo exploration as needed), and must return safe-to-parallelize groups + the serial queue + per-edge reasons.
2. **Converge conservatively** (this command's own logic — bias, not approval, is the no-HITL safety mechanism):
   - When in doubt, same group. A wrong merge costs only wall-clock; a wrong split costs conflicting PRs and a human untangling them.
   - Dependency edges (`Depends on #N` / `Blocked by #N`) → same group, always.
   - Predicted shared files → same group; watch known hotspots (design-system CSS, shared primitives, glossary/CONTEXT docs).
   - A serial chain goes into ONE group whole — never split a chain.
   - Balance groups by issue count, not by maximizing group count. Everything collapsing into one group is a fine answer.
3. Order groups: any group containing a P0 first, then P1, then **larger groups before smaller** (LPT — the biggest batch bounds the night's wall-clock, so it must claim a slot in the first wave; observed 2026-07-10: a 5-issue group launched in wave 2 ran alone for the final two hours), ties by lowest issue number.
4. Launch as many groups as free WIP slots allow (usually one): background general-purpose subagent with **model `opus` pinned explicitly** — the child is an `/iterate-issues` orchestrator and that command's Models table specifies Opus; never let it silently inherit the loop session's model. Task = *run `/iterate-issues <group numbers>` in this repo, following `~/.claude/commands/iterate-issues.md` end-to-end* (its planner/implementer/handler tiers are pinned inside that command and unaffected). Do **not** wait for it — end the tick.
5. Log the partition + reasons as text (the audit trail for the no-HITL decision).

Never launch two groups sharing an issue number; never launch anything already `in-progress`.

### F — Nothing left

Queue empty, no batch running, no unmerged batch PR → post the **run report**, then **end the loop** (in `/loop` dynamic mode: `ScheduleWakeup {stop: true}`).

Also post the run report (without stopping) when the terminal state is *"all PRs open, only waiting on merges"* and every open batch PR already has its merge-ping — that is the state a human wakes up to, and the report is what makes the morning hand-off self-serve.

The run report (one message, also sent as a PushNotification):

- Per batch PR: number, issues covered, diff size, duration (first commit on the branch → PR opened — derive from `git log`), QA verdict.
- Suggested merge order (smallest/safest first; call out any PR containing `supabase/migrations/` changes — those need human eyes on the migration diff before merge, since merge auto-applies to prod).
- `needs-human` issues parked during the run, with one-line reasons.
- Current `needs-triage` count.
- Anomalies: children killed/restarted, permission hangs, QA fix rounds spent.

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
  "standards":   "which doc is law for judging what you see",
  "uiDiffGate":  "which globs count as UI files, and the hard block Action C2 applies when a UI diff's QA is DEFERRED/SKIPPED (incl. the BLOCKER comment template)"
}
```

## Config — `mergePolicy` block in `.iterate-issues.json`

Optional. Absent → the conductor never dispatches a merge (pure Action D pings).

```json
"mergePolicy": {
  "autoMerge":       false,
  "needsHumanPaths": ["path prefixes that make a PR risk-tier (migrations, auth, payments, ...)"],
  "postMergeVerify": "freeform instructions /land-pr step 4.5 follows verbatim after landing a PR that touched sensitive paths (read-only evidence queries)"
}
```

## Config — WIP ledgers in `.iterate-issues.json`

```json
"maxConcurrentBatches": 2,   // ACTIVE ledger: batches implementing + PRs whose head SHA can still move
"maxParkedPRs":         5    // PARKED ledger: PRs stopped and waiting on the human (merge-ping / needs-human)
```

Keep `maxConcurrentBatches` tight (it bounds agent compute and review-bot quota). `maxParkedPRs` can be generous — it only bounds your morning merge burden and the merge-conflict surface between unmerged branches. Setting them as one number is the deadlock described in the Invariants.

The block is consumed by `/land-pr`'s risk gate; the conductor only reads `autoMerge` and the classification to decide between D (ping) and D2 (dispatch).

## What this command does NOT do

- Does not merge anything itself, close issues, or apply migrations/DB writes — ever. Safe-tier merges happen only through `/land-pr`'s full gate (D2), only when the repo config opts in; risk-tier PRs always end at the human.
- Does not re-implement anything `/iterate-issues` owns; it launches and observes scoped instances of it.
- Does not triage. `needs-triage` issues are counted and surfaced, never picked up.
- Does not exceed either WIP ledger's cap, and never launches a bare (unscoped) run.
- Does not let a PR that is merely *waiting on you* consume an active slot — parked ≠ active.
- Does not hold a green, safe-tier, QA-CLEAN PR on discretion. An unmet AC becomes a follow-up issue; the PR lands. The only holds are risk tier, red review, and non-CLEAN QA.
- Does not ping merge-ready — or autoland — a PR whose diff touches UI files when live QA came back `DEFERRED`/`SKIPPED`. That PR gets a BLOCKER comment and `needs-human` (C2). Config: `liveQa.uiDiffGate`.
- Does not loop on a defective PR: one fix round, then `needs-human`.
- Does not tolerate a concurrent **bare** `/iterate-issues` (it would double-pick issues). Concurrent *manual scoped* runs are fine — their labels/PRs are counted as WIP automatically.
