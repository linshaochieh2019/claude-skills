# claude-skills

Personal collection of Claude Code slash commands, version-controlled in place: **this repo's root IS `~/.claude/commands/`**. Edit a live command, commit, push — no copy/sync step.

## Install (fresh machine)

```bash
git clone https://github.com/linshaochieh2019/claude-skills.git ~/.claude/commands
```

If `~/.claude/commands/` already has files, clone elsewhere and merge manually.

## The issue-pipeline family

```
open issues → /triage → ┌─────────────────────────────────────┐
                        │  /loop /conduct-issues  (the entry)  │
                        │   ├─ partitions live queue per tick  │
                        │   ├─ spawns scoped /iterate-issues   │──→ one PR per batch
                        │   ├─ live Chrome QA on UI batch PRs  │
                        │   └─ pings you when merge-ready      │
                        └─────────────────────────────────────┘
                                     you merge (always)
```

- **`/conduct-issues`** — the conductor: one stateless tick per invocation, designed to be driven by `/loop /conduct-issues`. Partitions the queue at launch time, bounds work-in-flight per repo (≤2) and across repos (global governor in `~/.claude/loops/governor.json`), live-QAs UI batch PRs in Chrome, notifies for merge, cleans up after merge (incl. orphan worktree/plans sweeps), journals every tick to `<repo>/loops/conduct-issues/` (gitignored soft state + append-only log), launches the next batch. `/conduct-issues evolve` reads the journal and proposes contract improvements (human-approved). Incident case file: `conduct-issues/history.md` — rules cite it as `[H#]`. Never merges, never applies migrations. Subsumes the retired `/fan-out-issues` (2026-07-10).
- **`/iterate-issues`** — the engine: drains one scoped batch of stacked issues into a single branch and exactly one PR (planner → implementer → two-stage review per issue, per-issue push, bot-review loop). Invoke directly only for "exactly one batch, right now."
- **`/await-review`** — babysits the bot code-review loop on any PR (poll `Code Review` check, dispatch Haiku handler per comment, ≤3 rounds). Used by `/iterate-issues` Step 6; also standalone.
- **`/gitlab-iterate-issues`** — GitLab port of the engine (`glab`, MRs instead of PRs). Host-specific auth details stay machine-local, never in this file set.

## Bundled artifacts

```
conduct-issues/
  history.md                            # incident case file — the [H#] evidence behind conductor rules
iterate-issues/
  config/.iterate-issues.example.json   # per-repo overrides — copy to <repo>/.iterate-issues.json
  scripts/advance-issue.sh              # deterministic issue-label transitions
  templates/planner-prompt.txt          # planner subagent task prompt
  templates/implementer-prompt.txt      # implementer subagent task prompt
_shared/
  fleet-conventions.md                  # how every repo runs dev/verification/ticketing/merging — new-repo onboarding checklist
  bot-review-loop.sh                    # poll/dedup state machine (used by /await-review)
  handler-prompt.txt                    # review-handler subagent task prompt
```

**Fleet conventions live in [`_shared/fleet-conventions.md`](./_shared/fleet-conventions.md)** — labels/ticketing, the shared code-review CI config, the `.iterate-issues.json` contract surface (`mergePolicy`, `standingDecisions`, `liveQa`), the qa-login script pattern, migration pipeline rules, journal layout, and the human-gate policy. Onboard a new repo by walking that checklist; don't re-derive per project.

Per-repo config (`.iterate-issues.json` at a repo's root) is where project-specific facts live — base branch, session ceiling, WIP cap, and the `liveQa` block (how to boot the app, auth, breakpoints, which doc is design law). Keep secrets and machine/host-specific details out of this repo; it is public.
