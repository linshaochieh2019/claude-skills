---
description: GitLab port of /iterate-issues. Drain all open `ready-for-agent` GitLab issues into a single batch branch end-to-end, then open one batch merge request (MR). Built for stacked queues where issues build on each other. Wakes you with one MR to review. Uses `glab`. Use to drain a GitLab ready-for-agent queue or run an AFK batch against a GitLab project.
---

# /gitlab-iterate-issues

GitLab analog of `/iterate-issues` (which is GitHub-only). End-to-end autonomous loop for **stacked queues**: pick up every open issue labeled `ready-for-agent`, implement them sequentially as commits on a **single batch branch** off `origin/<baseBranch>`, then open one batch **MR** at the end. The MR closes all included issues on merge. You wake from AFK to **one** MR with N commits.

This is the manual port the team needed because `/iterate-issues` hard-codes `gh`/GitHub PRs and cannot drive GitLab. The planning/implementation core is identical; only the tracker/VCS surface (`gh`→`glab`, PR→MR) and the review step differ.

## Prerequisites

- **`glab` CLI installed and authenticated** for the target host. Verify: `glab auth status --hostname <host>` should show "Logged in". Host-specific details (which host, which account, how to re-auth) are machine-local — keep them in memory or a local untracked note, never in this file.
- The current working directory is a **git checkout of the GitLab project** (origin → the GitLab repo). `jq` available.
- Fallback if `glab` is unavailable: the GitLab GraphQL endpoint `/api/graphql` works through an authenticated browser tab (see the `gitlab-tracker` memory) — but this command assumes `glab`.

## When to use this vs. alternatives

Optimized for **stacked work** — issues that import from or build on each other, or that touch overlapping files (shared models/seeders/controllers). For these, "one MR per issue all branched off `main`" needs a human merging between issues, defeating the AFK promise, and risks conflicts. For a queue of genuinely **independent** issues where you want N parallel MRs, this is the wrong tool.

## Bundled artifacts (reused from `/iterate-issues` — single source of truth)

- `~/.claude/commands/iterate-issues/templates/planner-prompt.txt` — planner subagent task prompt (provider-agnostic; uses "PR" generically — for GitLab the same "do not push / do not open the merge artifact" directive applies to MRs).
- `~/.claude/commands/iterate-issues/templates/implementer-prompt.txt` — implementer subagent task prompt (batch mode: no branch, no push, no MR; first commit message starts with `"<issue title> (#<N>)"`).

Per-project tuning is optional via a `.iterate-issues.json` at the repo root (same schema as `/iterate-issues`): `baseBranch`, `setupCommand`, `verificationCommands`, `frameworkCitations`. For this Laravel repo a sensible config is `setupCommand: "composer install --no-interaction"` and `verificationCommands: ["php -l <changed files>", "php artisan test"]` (DB-dependent verification needs a configured test DB/.env — see Failure modes).

## Critical invariants

- **Single batch branch.** Every issue's commits land on the same branch (`agent/batch-<YYYYMMDD>`) off the project's base branch. No per-issue branches. One MR at the end.
- **Sequential, not parallel.** Each issue's implementer sees the previous issue's commits in its working tree, naturally resolving stacked dependencies and avoiding same-file conflicts.
- **Single isolated worktree.** The whole batch runs in `../<repo-name>-batch/`. Your main checkout (and any running local docker stack mounting it) is untouched.
- **State lives in GitLab.** Issue labels are the durable queue. No in-memory queue; runs are stateless across sessions.
- **Skill reuse over reinvention.** Thin shim over `superpowers:writing-plans` + `superpowers:subagent-driven-development`. Override the subagent's "push and open MR" default via the implementer task prompt; don't fork those skills or override their internal model choices.
- **You merge.** This command opens one MR and stops. You review it, you merge.

## Step 0 — Detect project context

```bash
export PATH="$HOME/scoop/shims:$PATH"   # ensure glab on PATH (Windows/scoop)
REPO=$(git remote get-url origin | sed -E 's#(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')   # e.g. aks-freeroll/backend/api
PROJ=$(printf '%s' "$REPO" | sed 's#/#%2F#g')                                                # URL-encoded path for `glab api`
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_NAME=$(basename "$REPO_ROOT")
BATCH_BRANCH="agent/batch-$(date +%Y%m%d)"
WORKTREE_DIR="$(dirname "$REPO_ROOT")/${REPO_NAME}-batch"

CONFIG="$REPO_ROOT/.iterate-issues.json"
BASE_BRANCH=$(jq -r '.baseBranch // "main"' "$CONFIG" 2>/dev/null || echo "main")
SETUP_CMD=$(jq -r '.setupCommand // "composer install --no-interaction"' "$CONFIG" 2>/dev/null || echo "composer install --no-interaction")
```

If `git remote get-url origin` fails, abort: "not in a git working tree with an origin remote." If `glab auth status` is not logged in, abort: "glab not authenticated — run the host setup helper."

## Label conventions

| Owner | Labels |
|---|---|
| `/to-issues` / triage (input) | **`ready-for-agent`** |
| This command (per issue) | `in-progress`, `done`, `needs-human` |
| This command (batch-level) | `batch-mr-open` (on the MR) |

State machine per issue: `ready-for-agent` → `in-progress` → `done` (committed to batch branch) **or** `needs-human` (escalation). Create any missing label on first use (`glab api --method POST "projects/$PROJ/labels" -f name=in-progress -f color=#FC8A3A`, etc.).

## Models

| Step | Model | Why |
|---|---|---|
| Orchestrator (this command) | Opus | Coordinates everything; failure routing needs judgment. |
| Planner subagent (`superpowers:writing-plans`) | Opus | Architecture/naming/citations — judgment-heavy. |
| Implementer subagent (`superpowers:subagent-driven-development`) | Sonnet | Mechanical execution against a fixed plan. |
| Sub-subagents inside `superpowers` skills | skill default | Don't override. |
| Merge | n/a | Human review. |

## Budgets

| Phase | Wall-clock | On exceed |
|---|---|---|
| Per-issue planner | 15 min | Label `needs-human` with planner output. Skip implementer, continue queue. |
| Per-issue implementer | 45 min | Roll back the issue's partial work, label `needs-human`, continue to next issue. |
| Whole-session ceiling | 8 hours | Push batch branch to remote, open MR with whatever completed, post partial summary. |

## Step 1 — Reconciliation pass (resume safety)

```bash
glab api "projects/$PROJ/issues?state=opened&labels=in-progress&per_page=100" | jq -r '.[].iid'
```

- **Worktree exists, batch branch exists, an `in-progress` issue exists.** Resume: `cd` into the worktree, `git reset --hard HEAD && git clean -fd`, re-run that issue from the planner stage (label stays `in-progress`).
- **Worktree exists, no `in-progress` issue.** Prior batch finished implementing but never opened the MR. Skip to Step 5.
- **`in-progress` issue exists, no worktree.** State lost. Label it `needs-human` ("worktree missing on resume"). Continue.
- **Neither.** Fresh run → Step 2.

## Step 2 — Pull and order the queue

```bash
glab api "projects/$PROJ/issues?state=opened&labels=ready-for-agent&per_page=100" \
  | jq 'sort_by(.iid) | map({iid, title, labels, body: .description})'
```

If empty, exit cleanly: "no ready-for-agent issues."

For each issue, find its `## Blocked by` section (or a `Depends on` line) and collect **every** `#N` reference within it. Important: `/to-issues` writes the dependency on a **bullet line under the heading** (e.g. `## Blocked by` → blank line → `- #2 (...)`), not immediately after the words "Blocked by" — so a strict adjacent regex like `Blocked by\s*#N` misses it. Collect all `#N` tokens in that section instead. The literal text `None - can start immediately` means no dependencies. Topo-sort if any edges exist, else ascending by iid. A closed dependency is satisfied. An **open** dependency that is NOT itself in the current `ready-for-agent` queue is a hard blocker — label the dependent `needs-human` and skip it. A dependency cycle → stop and report.

Build a TodoWrite list, one entry per issue.

## Step 3 — Set up the batch worktree (once per run)

```bash
git fetch origin "$BASE_BRANCH"
git worktree add -b "$BATCH_BRANCH" "$WORKTREE_DIR" "origin/$BASE_BRANCH"
cd "$WORKTREE_DIR"
eval "$SETUP_CMD"   # one install for the whole batch
```

If setup fails, stop the batch; label all queued issues `needs-human` with "batch setup failed: <error>".

## Step 4 — Per-issue loop (sequential, in-place)

For each issue in topo order:

### 4.1 Mark in-progress
```bash
glab api --method PUT "projects/$PROJ/issues/<iid>" -f "add_labels=in-progress" -f "remove_labels=ready-for-agent" >/dev/null
```

### 4.2 Capture rollback point
```bash
START_COMMIT=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
```

### 4.3 Dispatch planner subagent
Render `~/.claude/commands/iterate-issues/templates/planner-prompt.txt`, substituting `<N>`→iid, `<WORKTREE_DIR>`, `<issue body>`→description. Invoke `superpowers:writing-plans` (model `opus`, cwd `$WORKTREE_DIR`, read-only) with the rendered prompt.

### 4.4 On planner return
- Plan with `CITATIONS` block (or explicit "no framework-specific naming choices") → proceed to 4.5.
- `BLOCKED` or 15-min budget exceeded → label `needs-human` (`add_labels=needs-human`, `remove_labels=in-progress`), comment the reason (`glab issue note <iid> -R "$REPO" -m "..."`). Skip implementer; continue. No rollback (planner is read-only).
- Plan missing CITATIONS but the spec implies framework-specific naming (migrations, route/middleware files, etc.) → treat as `BLOCKED`.

### 4.5 Dispatch implementer subagent
Render `~/.claude/commands/iterate-issues/templates/implementer-prompt.txt`, substituting `<N>`→iid, `<issue title>`, `<planner output>`, `<issue body>`. Invoke `superpowers:subagent-driven-development` (model `sonnet`, cwd `$WORKTREE_DIR`) with the rendered prompt. Two-stage review (spec compliance + code quality) is built into that skill — don't skip it.

### 4.6 On implementer return
- **Success** → `glab api --method PUT "projects/$PROJ/issues/<iid>" -f "add_labels=done" -f "remove_labels=in-progress"`. Update TodoWrite. Next issue.
- **BLOCKED / NEEDS_CONTEXT / 45-min budget** → `git -C "$WORKTREE_DIR" reset --hard "$START_COMMIT" && git clean -fd`; label `needs-human`; comment the blocker (include the plan). Continue.
- **Implementer pushed / opened an MR despite the directive** → close the rogue MR, delete the rogue branch from remote, do NOT mark `done`, label `needs-human`. Continue.

**Do not abort the whole batch for one bad issue.** Forward progress is the point.

## Step 5 — Open the batch MR

After the queue is drained (or the 8-hour ceiling hit):

```bash
cd "$WORKTREE_DIR"
git push -u origin "$BATCH_BRANCH"

DONE=$(glab api "projects/$PROJ/issues?state=opened&labels=done&per_page=100")
DONE_COUNT=$(printf '%s' "$DONE" | jq 'length')
# GitLab auto-closes issues referenced as "Closes #<iid>" when the MR merges into the default branch.
CLOSES=$(printf '%s' "$DONE" | jq -r 'map("- Closes #\(.iid) — \(.title)") | join("\n")')

glab mr create -R "$REPO" \
  --source-branch "$BATCH_BRANCH" --target-branch "$BASE_BRANCH" --yes \
  --title "Batch: $(date +%Y-%m-%d) ($DONE_COUNT issues)" \
  --description "Batch run via /gitlab-iterate-issues.

Issues included (one or more commits each on this branch; commit titles start with the issue iid):

$CLOSES

Review by walking commits in order. Merging this MR closes all listed issues."
```

Capture the MR iid from the output and label it: `glab api --method PUT "projects/$PROJ/merge_requests/<mr_iid>" -f "add_labels=batch-mr-open" >/dev/null`. If no issues completed, skip the MR and post the summary directly.

## Step 6 — Review (human)

There is no GitLab-CI bot-review loop wired up here (unlike `/iterate-issues`, which polls a GitHub "Code Review" check). So this command **stops after opening the MR**. If/when a GitLab CI code-review job exists, add a poll loop here analogous to `/await-review` (poll the pipeline via `glab ci status` / `glab api .../pipelines`, dispatch a handler subagent per new review note, cap at 3 rounds). Until then: open MR → stop → human reviews and merges.

## Step 7 — Final summary

```
## gitlab-iterate-issues batch summary

Batch branch: agent/batch-<YYYYMMDD>
Batch MR: !<mr_iid>

| Issue | Status | Commits on batch |
|---|---|---|
| #2 | done | 1 |
| #4 | needs-human | 0 (rolled back: <reason>) |
...

Next: review MR !<mr_iid> commit-by-commit, then `glab mr merge <mr_iid> -R <REPO> --yes`.
```

Then exit. Do NOT merge the MR. Do NOT close issues (they close via `Closes #N` when you merge).

## Step 8 — Post-merge cleanup (manual, after you merge)

```bash
git worktree remove "$WORKTREE_DIR"
git worktree prune
```

## Failure modes

| Symptom | Action |
|---|---|
| `glab` not authenticated | Abort; tell user to run the host setup helper / re-auth. |
| `git remote get-url origin` fails | Abort: "not a git checkout with an origin remote." |
| Planner `BLOCKED` / 15-min budget | No rollback; label `needs-human` with reason; skip implementer; continue. |
| Implementer `BLOCKED` / 45-min budget | Roll back to `$START_COMMIT`; label `needs-human`; continue. |
| Implementer ignores batch mode (pushes/opens MR) | Close rogue MR, delete rogue branch, label `needs-human`; continue. |
| Dependency cycle in `Blocked by` edges | Stop; report cycle. |
| Setup command fails | Stop batch; label all queued `needs-human`. |
| DB-dependent verification (migrations) can't run in worktree | The worktree has no DB/.env by default. Either configure a test DB via `.iterate-issues.json` `setupCommand` (copy `.env`, point at a disposable schema, `php artisan migrate`) or have the planner mark such issues for human verification. Never point verification at STG/PROD. |
| Whole-session 8-hour ceiling | Push batch branch, open MR with whatever's done, partial summary; remaining `ready-for-agent` issues stay queued. |

## What this command does NOT do

- Does not merge the MR. You merge.
- Does not close issues (they close via `Closes #N` on merge into the default branch).
- Does not run a GitLab-CI bot-review loop (not wired up — see Step 6).
- Does not push schema migrations against STG/PROD; DB-dependent verification must use a disposable local/test DB.
- Does not handle fan-out queues (independent issues → parallel MRs). Different tool.
