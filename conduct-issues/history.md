# /conduct-issues — incident case file

Append-only. Each case is the "legislative history" behind a rule in `conduct-issues.md`; the contract cites these as `[H#]`. **Never delete a case whose rule still stands** — the case is what stops a future edit from "simplifying" the rule away. New cases come from evolve runs or manual post-mortems; add them at the bottom with the next H number.

---

## H1 — Review-bot false-clean under concurrent load (2026-06-25)

Multiple batches in review at once exhausted the review bot's quota; it exited clean **without actually reviewing**. A green check that never ran is worse than a red one.
**Rules:** keep `maxConcurrentBatches` tight (it bounds bot quota, not just compute); Action C/D verify the `Code Review` check **conclusion**, never infer success from an absence of comments.

## H2 — Permission-hang looks identical to work (2026-07-10)

A subagent prompt used `cd <dir> && git ...`, tripping the harness's cd-before-git hook heuristic → confirmation box **even though each part was allowlisted**. The child emitted no idle signal; one batch sat 3.5 h on a prompt nobody saw.
**Rules:** dispatch hygiene — cross-directory git is `git -C <path> ...` only, stated in every subagent prompt; Action A's watchdog (alive but no commits/idle-signal ~30 min → nudge once → TaskStop + relaunch); unattended loop sessions run `--permission-mode acceptEdits` or a vetted allowlist.

## H3 — Biggest batch launched last bounds the night (2026-07-10)

A 5-issue group launched in wave 2 ran alone for the final two hours while everything else was done.
**Rule:** Action E orders groups LPT — larger groups before smaller (after P0/P1 priority), ties by lowest issue number.

## H4 — QA typed into an autosave field and wrote prod data (2026-07-11, #868)

Live QA "just tested" a header field; the field PATCHes on `change`, so it silently updated a real record.
**Rule:** QA is STRICTLY read-only — navigate, scroll, screenshot; never type or toggle unless the config's `liveQa` block explicitly sanctions it.

## H5 — The unseen layout that shipped (2026-07-11, PR #904 / #895 → gate #934)

A purely visual ticket's PR went out with QA `DEFERRED`; the deferral read as a friendly reminder next to the risk checklist, got skimmed past, and a layout **nobody had ever seen** landed on prod.
**Rule:** Action C2 — a UI diff whose live QA is `DEFERRED`/`SKIPPED` is hard-blocked: BLOCKER comment + `needs-human`, no merge-ping, never autoMerge, for as long as that head SHA stands. A visual ticket's only acceptance procedure is *looking at it*.

## H6 — Two parked PRs deadlocked the whole night (2026-07-13)

#969 parked 00:18, #970 parked 00:59 — with parked PRs counted as WIP, the conductor sat idle **8.5 hours** with 13 `ready-for-agent` issues untouched. Overnight, human availability is zero by definition, so a parked PR holds its slot till morning.
**Rules:** two separate ledgers — ACTIVE (burns compute/quota, cap `maxConcurrentBatches`) vs PARKED (waits on the human, cap `maxParkedPRs`); the moment a PR parks its active slot frees, same tick.

## H7 — Green PR held hostage by an impossible AC (2026-07-13, #969 / #946)

#969 was green, SAFE-tier, QA CLEAN — and still parked until morning because #946's AC1 asked for four columns in a viewport that cannot fit four. Asking at 00:18 costs a whole night.
**Rules:** D2's conditions are jointly sufficient — no discretionary hold. A knowingly unmet/unreachable AC on a green safe-tier PR → land anyway + file a `needs-triage` follow-up naming the gap + name it in the notification. A gap bad enough to stop shipment is `QA: DEFECTS`, not a hold.

## H8 — The overnight loop that froze the whole machine (2026-07-12→13, #930)

`maxConcurrentBatches: 6` (3× default) × Windows Defender real-time scanning × worktrees never reclaimed = tens of thousands of small-file writes queued synchronously; the **entire OS** (Explorer, Chrome) stalled, not just Claude. Each batch = a full worktree with its own ~0.73 GB `npm install` + an Opus orchestrator chain; RAM fell to 4.3 GB free. Also found: QA port hardcoded to 3789 — two concurrent QAs would bind-fail or **silently QA the wrong batch's app and report a false clean**; orphan batch dirs (no `.git`, absent from `git worktree list`) that nothing ever cleaned.
**Rules:** default cap 2 stands unless a machine is proven to take more; QA port is always derived per-batch (`liveQa.start`); Step 0 sweeps orphan batch/plans dirs; the global governor exists because `maxConcurrentBatches` is per-repo while loops are per-session — nothing else guards the cross-repo sum.

## H9 — /fan-out-issues retired (2026-07-10)

Its partition rules were folded into Action E; a single un-looped `/conduct-issues` tick subsumes it ("partition and launch what fits / QA what's ready").
**Rule:** the family is exactly two commands; the conductor invents no new implementation path.
