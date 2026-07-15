---
argument-hint: "[issue numbers to restrict the queue | 'evolve' to run a self-improvement pass]"
description: One stateless conductor tick, designed to be driven by `/loop /conduct-issues` — keeps scoped /iterate-issues batches flowing unattended. Partitions the live queue at launch time, bounds work-in-flight per repo AND across repos (global governor), live-QAs UI batch PRs in Chrome, pings you when a PR is merge-ready, cleans up after merges (including orphan sweeps), journals every tick to the repo's loops/ folder, then launches the next batch. Never merges itself and never applies migrations; when the repo opts in via mergePolicy.autoMerge it dispatches /land-pr (autonomous) for safe-tier PRs, while migrations/auth/payments PRs always wait for you. `/conduct-issues evolve` reads the tick journal and proposes contract improvements. Use when you want the issue pipeline to keep itself moving overnight while you stay the gate for what matters.
---

# /conduct-issues — pipeline conductor (one tick per invocation)

The family is exactly two commands [H9]:

- `/iterate-issues` — the **engine**: drains one scoped batch end-to-end into one PR. All quality machinery (planner/implementer split, budgets, two-stage review, per-issue push, `/await-review`) lives there, unchanged. Invoke it directly only when you want exactly one batch, right now, in-session.
- `/conduct-issues` (this) — **everything above the engine**: each invocation is a single stateless *tick* that reads live GitHub state and does whatever keeps the pipeline moving — then ends. Driven by `/loop /conduct-issues` (dynamic pacing), the ticks chain batches across the whole night while the human merge gate stays human.

**The one entry point to remember: `/loop /conduct-issues`.**

This command invents no new implementation path. It decides *when* to launch *what*, adds the live-browser QA stage the AFK engine cannot do, and tells you when a PR is actually merge-ready.

`[H#]` markers cite the incident case file `conduct-issues/history.md` (relative to this file) — the evidence behind each rule. Read a case before weakening its rule.

## Memory model — three layers, strictly ranked

1. **GitHub (hard state, ground truth).** Labels, PRs, checks, marker comments — re-read every tick. Never act on what a previous tick "remembered"; a loop session gets summarized and its recollections rot.
2. **`<repo>/loops/conduct-issues/state.md` (soft memory, hints only).** Small (≤20 lines), mutable: tonight's context — "review bot quota exhausted until ~02:00", "worktree dev servers need 90 s to boot", last tick's digest. Hints may save a tick from re-discovering tonight's noise, but they are **never a basis for action** — when a hint contradicts GitHub, GitHub wins and the hint gets deleted.
3. **`<repo>/loops/conduct-issues/log.md` (append-only journal).** One line per tick, never edited, never read for action decisions. It exists for the human's morning review and for evolve runs. Silent ticks are forbidden — every tick appends, even (especially) idle ones.

## Invariants

- **The conductor itself never merges, never closes issues.** Default: every merge belongs to the human. When the repo opts in (`mergePolicy.autoMerge: true` in `.iterate-issues.json`), the conductor may *dispatch* `/land-pr` in autonomous mode for **safe-tier** PRs only. Risk-tier PRs (migrations, auth/RLS, payments/e-invoicing, anything under `needsHumanPaths`) are ALWAYS pinged to the human; that residual gate is not negotiable.
- **A UI diff with no live QA never reaches the merge gate** [H5] — hard-blocked by Action C2, not deferred politely.
- **Never launch a bare run.** Every batch is a *scoped* `/iterate-issues <numbers>` (scope suffix = collision safety).
- **Two WIP ledgers — active and parked; a PR waiting on a human is NOT work in flight** [H6].
  - **ACTIVE** = (batches still implementing) + (open batch PRs whose head SHA can still move) ≤ `maxConcurrentBatches` (default 2 — bounds agent compute and review-bot quota [H1][H8]).
  - **PARKED** = open batch PRs stopped and waiting on *you* (current-SHA merge-ping or `needs-human`) ≤ `maxParkedPRs` (default 5 — bounds your merge burden, not throughput).
  - The moment a PR parks, its active slot frees **in the same tick**.
- **The global governor bounds the cross-repo sum** [H8]. `maxConcurrentBatches` is per-repo; `/loop` is per-session; nothing else guards the machine when two repos loop at once. See "Global governor" below.
- **Partition at launch time, never earlier.** The next group is computed from the queue as it exists at that tick.
- **DB writes stay deferred.** Migrations are written as files only; anything needing a live-DB/PII write goes `needs-human`.
- **QA fix loop is bounded to ONE round.** One fix dispatch, one re-QA. Still broken → `needs-human` + notify.
- **Dispatch hygiene: `git -C`, never `cd && git`** [H2] — stated in every subagent prompt this command sends.
- **Unattended runs need a prompt-free session** [H2]: `--permission-mode acceptEdits` or a vetted allowlist.
- **Every tick appends one journal line before it ends.** No silent ticks.

## Step 0 — Bootstrap, read, short-circuit

### 0.1 Bootstrap the loop folder (first tick in any repo)

If `<repo>/loops/conduct-issues/` is missing, create it, add `loops/conduct-issues/` to `.gitignore` (machine state, not code), and write:

`state.md`:
```markdown
# conduct-issues state — SOFT MEMORY ONLY (hints, never facts; GitHub outranks this file)
lastDigest: (none)
lastTick: (none)
## Tonight's hints
(none)
```

`log.md`:
```markdown
# conduct-issues tick journal — append-only, one line per tick
# schema: <ISO time> | tick | actions=<A,B,C,...|idle> | launched=<groups+issues|-> | qa=<pr:verdict|-> | parked=<prs|-> | landed=<prs|-> | anomalies=<...|->
```

### 0.2 Read soft memory

Read `state.md`. Treat every hint as a *suggestion to check*, never a fact to act on.

### 0.3 Read live state (every tick — this is the ground truth)

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
# 3. Batch PRs, open and recently merged. statusCheckRollup feeds both the digest and C/D's check-conclusion reads.
gh pr list --repo "$REPO" --state open   --search 'head:agent/batch' --json number,headRefName,headRefOid,url,labels,comments,statusCheckRollup
gh pr list --repo "$REPO" --state merged --search 'head:agent/batch' --limit 10 --json number,headRefName
# 4. Worktrees left behind by batches.
git worktree list
# 5. Triage backlog (surfaced in notifications, never triaged here).
gh issue list --repo "$REPO" --state open --label needs-triage --json number --jq 'length'
```

Also note which background child tasks from earlier ticks are still alive (a completion notification's exit code lies; the PR/label state above is the ground truth for whether a batch succeeded).

### 0.4 Orphan sweep [H8]

- `git worktree prune`.
- Any sibling `<repo-name>-batch-*` directory that is **not** in `git worktree list` output is a corpse from a killed batch — delete it.
- Any `<repo-name>-batch-*-plans` directory whose batch PR is merged/closed, or whose worktree no longer exists — delete it.
- Log what was swept in the tick's journal line. Never touch a directory that a live worktree or running child still owns.

### 0.5 Digest short-circuit (the cheap-tick optimization)

Compute `DIGEST = sha1` over the concatenated raw JSON of reads 1–5 above. If `DIGEST == state.lastDigest` **and** no task-notification arrived since the last tick **and** the live-children set is unchanged: nothing in the world has moved — append an `actions=idle` journal line, update `lastDigest`/`lastTick` in `state.md`, and **end the tick immediately** (pacing per the table below). Do not re-reason about actions on an unchanged world.

### 0.6 Classify every open batch PR into exactly one ledger

- **PARKED** — carries `needs-human`, **or** a `<!-- conductor-merge-ping <headRefOid> -->` comment whose SHA equals the PR's *current* `headRefOid`. Consumes no active slot.
- **ACTIVE** — everything else: implementing, mid-bot-review, awaiting QA, in a fix round, or head SHA moved past its merge-ping (it re-enters the loop).

A merge-ping with a *stale* SHA does not park the PR.

```
ACTIVE_WIP = (live implementing batches) + (open batch PRs classified ACTIVE)
PARKED     = (open batch PRs classified PARKED)
```

## Step 1 — Act (process every action that applies, in this order)

Actions are independent; one tick may clean up a merged PR *and* launch a new batch *and* QA another PR.

### A — Resume an orphaned batch

`in-progress` issues exist, no live child works them, and their scope-suffixed worktree exists → the child crashed. Re-launch a background scoped `/iterate-issues` with **the same issue numbers**, model `opus` pinned as in Action E. Worktree missing too → leave it; the engine's reconciliation will `needs-human` it.

**Permission-hang watchdog** [H2]: a child that is *alive* but shows no new commits and no idle signal for ~30+ min is presumed stuck on a prompt, not thinking. Nudge once via SendMessage; no reaction → TaskStop + relaunch. Never let a silent child sit for hours.

### B — Clean up after your merge

For each *merged* batch PR whose worktree still exists: `git worktree remove <dir>`, `git worktree prune`, delete the sibling `*-plans/` dir. (The active slot already freed when the PR parked or landed — this reclaims disk and the parked-ledger entry.)

**Stale-label reconciliation:** an *open* batch PR still carrying `batch-pr-open` whose `Code Review` check concluded, with no live child owning it → the `/await-review` died mid-flight; remove the label (cosmetic-but-mandatory; downstream actions key off check conclusions, never this label).

### C — Live QA a reviewed batch PR

Trigger: an open batch PR where **all three** hold —

1. The `Code Review` check **actually SUCCEEDED** (verify the check conclusion — a quota-exhausted bot exits clean without reviewing [H1]).
2. The diff touches UI (`git diff --name-only origin/<base>...HEAD` — three-dot — has `.css/.scss/.tsx/.jsx`).
3. No `<!-- conductor-live-qa <headRefOid> -->` comment exists for the current head SHA.

Procedure:

1. Derive the changed screens/routes from the diff.
2. Start the app **from the batch worktree** per the config's `liveQa` block; if absent, consult the repo's CLAUDE.md / runbooks for the sanctioned local-QA path.
3. Drive Chrome (load `claude-in-chrome` tools via one ToolSearch batch) through each changed screen at every breakpoint the config names. Be picky — pixel-perfection standards apply; flag anything off even if unrelated. **QA is read-only** [H4]: navigate, scroll, screenshot; never type or toggle unless `liveQa` explicitly sanctions it.
4. Post one PR comment starting `<!-- conductor-live-qa <headRefOid> -->`, verdict `QA: CLEAN` or `QA: DEFECTS`, with concrete findings (screen, breakpoint, what's wrong).
5. Kill the dev server.
6. On `DEFECTS`: **one** fix round — dispatch a subagent (sonnet) in the batch worktree, scope hard-limited to the findings' blast radius, never migrations/schema, commit + push (new head SHA → C re-triggers exactly once). Second `DEFECTS` on the same PR → `needs-human`, notify, stop touching it.

A PR whose diff has no UI files skips straight to D.

### C2 — Hard-block a UI diff with no live QA [H5]

The gate rule lives in the config: `liveQa.uiDiffGate`. Read it and follow it verbatim.

Trigger: an open batch PR where **all three** hold —

1. The diff touches UI files per `liveQa.uiDiffGate` (three-dot diff against the globs; `N` = matched-file count).
2. The `<!-- conductor-live-qa <headRefOid> -->` comment for the **current** head SHA carries `DEFERRED` or `SKIPPED` — including every case where QA never opened a browser (env fail-closed, stale dataset, module not enabled).
3. No `<!-- conductor-ui-qa-blocker <headRefOid> -->` comment exists for the current head SHA.

Then: (1) post the BLOCKER comment (template in `liveQa.uiDiffGate`, rendered with `N`, the verdict, the reason from the QA comment, and every matched file one per line), beginning `<!-- conductor-ui-qa-blocker <headRefOid> -->`; (2) label `needs-human`; (3) **skip D and D2 for this PR entirely** — no merge-ping, no `/land-pr`, for as long as this head SHA stands.

The `needs-human` label parks the PR, so its active slot frees immediately — blocking a bad merge must never stall the pipeline. A later push moves the head SHA → C re-QAs from scratch and this gate re-evaluates; a `CLEAN` re-QA clears the block (remove `needs-human`, proceed to D/D2).

### D — Ping you when a PR is merge-ready

An open batch PR with `Code Review` succeeded, QA clean or not applicable, and no `<!-- conductor-merge-ping <headRefOid> -->` comment yet → leave that marker, then send a PushNotification: PR number, issues included, QA verdict, current `needs-triage` count. **Then wait — merging is yours.** The marker parks the PR immediately; Action E may launch the next batch in the same tick [H6].

**The trigger list for D is closed.** A PR parks for exactly three reasons:

1. **Risk tier** — touches `needsHumanPaths` / `supabase/migrations/`.
2. **`Code Review` did not succeed.**
3. **QA is not CLEAN** — `DEFECTS` (after its one fix round), or `DEFERRED`/`SKIPPED` on a diff with **no** UI files (a UI diff never reaches D in that state — C2 owns it).

Anything else green and safe-tier goes to D2. **The conductor has no discretionary hold** [H7] — "I'd like a human to weigh in on X" means X is a follow-up issue, not a parked PR.

### D2 — Auto-land a safe-tier PR (config-gated)

Only when `mergePolicy.autoMerge` is `true`. **These conditions are jointly sufficient — meet them and you land, no further judgement** [H7]:

- `Code Review` **succeeded**, and
- QA is **CLEAN** or not applicable, and
- the PR classifies **safe tier** under `/land-pr`'s risk gate (no `needsHumanPaths` file, no migrations), and
- no `<!-- conductor-autoland <headRefOid> -->` comment exists for the current head SHA, and
- **C2 did not fire** — a UI diff with `DEFERRED`/`SKIPPED` QA is never auto-landed.

Then: (1) leave the `<!-- conductor-autoland <headRefOid> -->` marker; (2) dispatch a background subagent running `/land-pr <n>` in **autonomous mode** (its prompt must say no human is available — the skill re-runs its own classification and green gate; the conductor's pre-check is a dispatch filter, not the safety mechanism); (3) do not wait — end the tick. The merge shows up in the next tick's Step 0 → B cleans → slot frees → E launches.

**An unmet acceptance criterion is NOT a reason to hold a green PR** [H7]. `autoMerge: true` is the human's standing instruction: safe tier, green, QA'd → land it, don't wake me. A knowingly unmet/unreachable AC → land anyway, file a `needs-triage` follow-up (which AC, why unmet, what shipped, the decision needed; reference issue + PR), and name that follow-up in the autoland notification. A gap bad enough that the code should not ship is `QA: DEFECTS` and goes through C's fix round — "green, but I'm holding it" blocks throughput without blocking any defect.

Risk-tier, config absent, or `autoMerge: false` → Action D ping. A head SHA that moved after its QA marker re-enters C first.

### E — Launch the next batch

Gates, all required:

- `ACTIVE_WIP < MAX_WIP` (throughput — parked PRs excluded, so a night of merge-pings still launches [H6]);
- `PARKED < MAX_PARKED` — on hitting this cap, launch nothing, send one PushNotification naming the parked PRs, end the tick (you are the bottleneck, not the queue; this is not action F);
- **the global governor has a free slot** (below) [H8];
- the (scoped) queue has issues not `in-progress`/`needs-human`.

Then:

0. **Cross-batch dependency deferral.** Scan for `Depends on #N` / `Blocked by #N` edges. If a dependency is open but not eligible this tick (typically `done`, sitting in an unmerged batch PR), **hold the dependent issue** — exclude it from this partition instead of letting the engine `needs-human` it. Your merge closes the dependency; the next batch bases on updated main; the held issue becomes eligible naturally.
1. **Partition** the eligible queue: dispatch a subagent running the `parallel-safety-check` skill over the issues (number, title, body), prompted that it is **non-interactive** (conclude, never ask), must predict the files/modules each issue touches (read-only exploration as needed), and must return safe-to-parallelize groups + serial queue + per-edge reasons.
2. **Converge conservatively** (bias, not approval, is the no-HITL safety mechanism): when in doubt, same group (a wrong merge costs wall-clock; a wrong split costs a human untangling conflicting PRs); dependency edges → same group, always; predicted shared files → same group (watch design-system CSS, shared primitives, glossary/CONTEXT docs); a serial chain goes into ONE group whole; balance by issue count, not group count — everything collapsing into one group is a fine answer.
3. Order groups: any group with a P0 first, then P1, then **larger before smaller** (LPT [H3]), ties by lowest issue number.
4. Launch as many groups as free slots allow (usually one): background general-purpose subagent, **model `opus` pinned explicitly** (never inherit the loop session's model), task = *run `/iterate-issues <group numbers>` in this repo, following `~/.claude/commands/iterate-issues.md` end-to-end*. Register the launch in the governor file. Do not wait — end the tick.
5. Record the partition + reasons in the journal line (the audit trail for the no-HITL decision).

Never launch two groups sharing an issue number; never launch anything already `in-progress`.

### F — Nothing left

Queue empty, no batch running, no unmerged batch PR → post the **run report**, zero this repo's governor entry, then **end the loop** (`ScheduleWakeup {stop: true}`).

Also post the run report (without stopping) when the terminal state is *"all PRs open, only waiting on merges"* and every open batch PR has its merge-ping — that is what a human wakes up to.

The run report (one message, also a PushNotification):

- Per batch PR: number, issues covered, diff size, duration (first branch commit → PR opened, from `git log`), QA verdict.
- Suggested merge order (smallest/safest first; call out any PR with `supabase/migrations/` changes — merge auto-applies to prod).
- `needs-human` issues parked during the run, one-line reasons.
- Current `needs-triage` count.
- Anomalies: children killed/restarted, permission hangs, QA fix rounds spent, orphans swept.

## Step 2 — Close the tick (mandatory, no exceptions)

1. **Append one journal line to `log.md`** per the schema — which actions fired, what launched (groups + issue numbers + one-line partition reason), QA verdicts, parks, lands, anomalies. Idle ticks log `actions=idle`.
2. **Update `state.md`**: `lastDigest`, `lastTick`, and tonight's hints — add a hint only if it will plausibly save the *next* tick real work; delete hints that GitHub has contradicted or that expired. Keep the whole file ≤20 lines.
3. **Update the governor file** (own repo's entry: current ACTIVE_WIP + timestamp).

A tick that skips Step 2 is a bug — the journal is what evolve runs and morning reviews stand on.

## Global governor — `~/.claude/loops/governor.json` [H8]

`maxConcurrentBatches` is per-repo; `/loop` sessions are per-session; the machine is shared. The governor is the only thing guarding the sum.

```json
{
  "_config": { "globalMaxActive": 3 },
  "linshaochieh2019/revking": { "activeWip": 2, "updatedAt": "2026-07-15T02:10:00+08:00" }
}
```

Rules:

- Every tick's Step 2 writes its own repo's entry (`activeWip` = ACTIVE_WIP, fresh timestamp). Action F zeroes it.
- Before Action E launches, sum `activeWip` across **other** repos, ignoring entries older than 2 h (stale = dead session). If `sum + own ACTIVE_WIP + 1 > globalMaxActive` → skip the launch this tick, note `governor-full` in the journal line. Everything else in the tick proceeds normally.
- Missing file → create it with `_config.globalMaxActive: 3`. The governor is a **soft, advisory cap on launches only** — it never blocks QA, cleanup, or pings, and a stale entry can only delay a launch by one tick, never corrupt state.

## Evolve mode — `/conduct-issues evolve`

Run when invoked explicitly, or propose it in the run report when `log.md` has gained ≥10 tick lines since the last `evolve` line. An evolve run:

1. Reads `log.md` (whole file), `state.md`, this contract, and `conduct-issues/history.md`; skims the loop session transcript if available.
2. Looks for: rules that fired never/always (tunable caps, pacing values), recurring anomalies (a new H-case candidate), repetitive SOP steps that should become a script, hints that keep being re-learned (→ contract or config material), cost sinks (ticks that burned tokens without moving state).
3. Produces: (a) a **proposed diff** to `conduct-issues.md` / new case for `conduct-issues.history.md` — **presented to the human, never self-applied**; the contract lives in the claude-skills repo and changes go through you; (b) direct cleanup of `state.md` (that part is machine state — apply freely); (c) appends an `evolve` line to `log.md` summarizing what was proposed.

The evolve run is how one repo's scar tissue becomes every repo's rule: data accumulates per-repo in `log.md`; lessons converge into this one global contract.

## Pacing (for `/loop` dynamic mode)

| State when the tick ends | Next wakeup |
|---|---|
| A child batch is running | 1800s — its completion notification is the real wake signal; this is the hang-fallback |
| Only waiting on your merge | 1800s |
| Adopted PR still mid-bot-review | 270s |
| Digest short-circuit fired (idle) | same as the underlying state above |
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

The block is consumed by `/land-pr`'s risk gate; the conductor only reads `autoMerge` and the classification to decide between D (ping) and D2 (dispatch).

## Config — WIP ledgers in `.iterate-issues.json`

```json
"maxConcurrentBatches": 2,   // ACTIVE ledger: batches implementing + PRs whose head SHA can still move
"maxParkedPRs":         5    // PARKED ledger: PRs stopped and waiting on the human
```

Keep `maxConcurrentBatches` tight — it bounds agent compute, review-bot quota [H1], and the machine itself [H8]. `maxParkedPRs` can be generous. Setting them as one number is the H6 deadlock.

## What this command does NOT do

- Does not merge anything itself, close issues, or apply migrations/DB writes — ever. Safe-tier merges happen only through `/land-pr`'s full gate (D2), only when the repo config opts in; risk-tier PRs always end at the human.
- Does not re-implement anything `/iterate-issues` owns; it launches and observes scoped instances of it.
- Does not triage. `needs-triage` issues are counted and surfaced, never picked up.
- Does not exceed either WIP ledger's cap, the global governor's cap, and never launches a bare (unscoped) run.
- Does not let a PR merely *waiting on you* consume an active slot — parked ≠ active [H6].
- Does not hold a green, safe-tier, QA-CLEAN PR on discretion [H7]. The only holds are risk tier, red review, and non-CLEAN QA.
- Does not ping merge-ready — or autoland — a UI-diff PR whose live QA came back `DEFERRED`/`SKIPPED`; that PR gets a BLOCKER + `needs-human` (C2) [H5].
- Does not loop on a defective PR: one fix round, then `needs-human`.
- Does not act on `state.md` hints as if they were facts — GitHub outranks soft memory, always.
- Does not end a tick without appending its journal line.
- Does not tolerate a concurrent **bare** `/iterate-issues` (double-picks issues). Concurrent *manual scoped* runs are fine — their labels/PRs count as WIP automatically.
