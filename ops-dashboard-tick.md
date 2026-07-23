---
description: One stateless conductor tick for the daily-quest 營運 dashboard build (GitLab). Drives the BE and FE paths in parallel, merges green MRs into dev (= staging), then QAs on deployed dev via API probes + Chrome. Designed to be driven by `/loop /ops-dashboard-tick`.
---

# ops-dashboard conductor — one tick per invocation

You are the conductor for the daily-quest **營運 dashboard** build. Each invocation is ONE
stateless tick: read live GitLab state, do whatever moves the pipeline, append a journal line,
end. Never carry state in your head across ticks — GitLab is the only ground truth.

Working directory: `C:\Users\linsh\projects\fleet-fe\daily-quest` (NOT a git repo; the two
checkouts are the nested `backend/api` and `frontend/web`). Use `git -C <repo>`, never `cd && git`.

## Scope (closed set — never pick up anything else)

- **Path BE** — GitLab project `dailyquest/backend/api` (proj 64), repo `backend/api`, base `dev`:
  `#23` (B1 auth) → `#24` (B2 mysql_ops+health) → `#25` (B3 overview), `#26` (B4 quests+players), `#27` (B5 d2)
- **Path FE** — GitLab project `dailyquest/frontend/web` (proj 66), repo `frontend/web`, base `dev`:
  `#135` (F1 route+auth) → `#136` (F2 版面, mock 資料) → `#137` (F3 接真 API + 冒煙)

**proj 64 `#19` is NOT in scope.** It is a different layer (public `/api/stats/summary` cross-fleet
contract). Never batch it with `/api/ops/*`.

**proj 66 `#141` / `#142` are NOT in scope** even though they carry `ready-for-agent`. Every launch
must be a *scoped* `/gitlab-iterate-issues <numbers>` run — never a bare one, or it sweeps them in.

Spec is `docs/ops-dashboard-spec.md`; the frozen visual baseline is
`docs/ops-dashboard/v4-daily-dark.html` (the copy under `scratch/` is a draft — ignore it).

## Authority

- MAY merge MRs **into `dev`** (that is the staging deploy — `dev` auto-builds+deploys).
- MUST NOT touch `main`, MUST NOT tag, MUST NOT run any prod deploy job.
- MUST NOT apply DDL to any DB **by hand**. Never run `artisan migrate` against an RDS yourself.
- **BUT KNOW THIS (verified 2026-07-19, pipeline 4237 job 8256): merging a migration into `dev`
  AUTO-APPLIES it to the dev RDS.** `deploy_dev` sets the image on a deployment that carries an
  `artisan-migrate` container, so the schema changes as a side effect of the merge — there is no
  separate human DDL step on dev, and "migrations are files only" is FALSE here. Treat merging a
  migration as a schema change to a shared database: read the migration before merging, and say so
  in the notification. Assume the prod pipeline does the same and never merge a migration to `main`.
- MUST NOT create the ops account (see Action D) — that is a human artisan step.

## The two paths run in parallel, with three hard joins

```
BE:  #23 ──▶ #24 ──▶ {#25, #26, #27} ──┐
                                        ├──▶ [J3] ──▶ #137
FE:  #135 ─▶ #136 ─────────────────────┘
```

- **[J1]** `#135` may start at t=0 in parallel with `#23` — both implement the auth contract already
  written in spec §3. Do NOT wait for `#23` to merge.
- **[J2]** `#136` uses mock data by design. It never blocks on BE.
- **[J3]** `#137` splits into two gates, because the ops account blocks only the last mile:
  - **Implementation** is eligible once `#25/#26/#27` and `#136` are merged and deployed. It does
    NOT need an ops account — build against the spec plus the merged BE source, exactly as `#135`
    and `#136` were built before any backend existed. Launch it; do not idle on a credential.
  - **Live smoke acceptance** needs an ops account on dev (probe: login returns a token, not
    401/500). If absent when the MR lands: merge on unit-test + build evidence only if the diff is
    otherwise verified, state plainly in the QA comment that the authenticated path is UNVERIFIED,
    and Action D the human. Never claim a smoke pass you could not run.

## Step 0 — read live state (every tick, this is ground truth)

```bash
glab api "groups/dailyquest/issues?state=opened&per_page=100"
glab mr list -R dailyquest/backend/api  --target-branch dev
glab mr list -R dailyquest/frontend/web --target-branch dev
git -C backend/api  worktree list
git -C frontend/web worktree list
```

Read `scratch/ops-dashboard/loop-state.md` (soft hints only — GitLab outranks it, always; delete a
hint the moment GitLab contradicts it). Bootstrap `loop-state.md` + `loop-log.md` if missing.

Compute a digest over the raw JSON. Unchanged digest + no task notification + no new child
completions → append `actions=idle`, end the tick. Do not re-reason about an unchanged world.

## Step 1 — act (all that apply, in order)

### A — Launch

Per path independently, **max 1 in-flight batch per path** (2 total). Launch the next eligible
group as a background subagent, model `opus` pinned explicitly, task = run
`/gitlab-iterate-issues <numbers>` in that repo following the skill end-to-end.

Same-repo issues in one wave go in **ONE** batch — `#25 #26 #27` together; they share the
`mysql_ops` connection, the routes file, and the ops controller namespace, so splitting them
guarantees conflicts. Never launch two groups sharing an issue number; never launch anything
already `in-progress`.

### B — Deploy to staging

**THERE IS NO PRE-MERGE CI IN THESE REPOS.** Pipelines are configured server-side and run only on
`dev`, `main`, and tags — never on MR/branch refs, so an open MR always reports `pipeline: null`.
Merging into `dev` *is* the first time anything runs. Never read `pipeline: null` as "not ready",
and never treat a batch agent's claim that verification passed as evidence — an agent that goes
idle without returning a summary has given you nothing.

So **you** are the pre-merge gate. Before merging any batch MR, in that batch's worktree:

1. Run the repo's `verificationCommands` yourself and read the actual output.
   FE: `export CHROME_BIN=...; npm run test:ci` then `npm run build` (must exit 0).
   BE: the docker `artisan test` line (`MSYS_NO_PATHCONV=1` mandatory).
2. Read the diff for the failure modes that tests don't catch. For auth/session code specifically:
   does the token interceptor scope its `Authorization` header to the ops namespace only (a
   substring match on an unparsed URL leaks the bearer token), is the login endpoint's own 401
   excluded from the clear+redirect path, is the token in sessionStorage per spec, and does the
   MR touch any `needsHumanPaths` file?
3. Only then merge into `dev`, and wait for the dev pipeline's `deploy_dev` job to succeed.

A red verification or a defect found in step 2 → do NOT merge; one scoped fix round, then re-verify.

**Verify the deploy actually landed — do not trust the job alone.** FE: fetch the deployed
`/main-<hash>.js` and grep for the new `/ops` route chunk. BE: hit the new endpoint and confirm it
is no longer 404. (A cached `ops_content_snapshots` response can serve the OLD shape for up to 10
minutes after a BE deploy — watch `meta.fetchedAt`, don't conclude the deploy failed and roll back.)

### C — QA on staging

After every successful `deploy_dev`, QA what that batch changed. Both halves are mandatory when
applicable. **A UI diff whose QA never opened a browser is a BLOCKER, not a pass** — post the
blocker comment, label `needs-human`, and never merge-ping or auto-land it.

**C1 — API QA (any BE batch).** Resolve the dev API host from
`frontend/web/src/app/service/api.service.ts` (runtime host switch — read it, do not guess the
hostname). Then:

- unauthenticated `GET /api/ops/overview` → **must be 401**
- login with the ops account → token
- authenticated `GET /api/ops/health`, `/overview`, `/quests`, `/players`, `/d2` → **200**
- `/d2` with no settled data → the spec's empty response, not a 500
- rate limit: 6 rapid bad logins → the 6th is throttled (`throttle:5,1`)
- cross-check 2–3 numbers from `/overview` against a **read-only** query on the dev DB
  (`dailyquest_dev_db`; host/creds in `backend/api/.env`). SELECT only, no writes, no DDL.

**C2 — Chrome QA (any FE batch).** Load the `claude-in-chrome` tools in ONE ToolSearch call. Drive
`https://dev-dailyquest.wptglobalkr.com/ops`:

- logged out → login page, no dashboard flash
- logged in → date navigator defaults to the latest available day (D-1 pipeline); 單日卡片 follow
  the focus day; trend charts show 14 days back with the focus day highlighted; DAY badge follows
  the focus day
- D2 section with no data → the empty state, never a broken chart
- side-by-side against `docs/ops-dashboard/v4-daily-dark.html` at the same focus day
- **breakpoints: 1112×534 (default V3 webview) and maximized.** Vertical is the scarce axis — a
  layout that only fits maximized is a defect.
- **Measure with JS (`innerWidth`), never trust a screenshot** — this Chrome silently flips tab
  zoom when screenshotting (drops innerWidth 1440→756, sticks per-origin), which fakes a
  responsive bug. Assert innerWidth in the same call as the measurement.
- QA is READ-ONLY apart from the login itself. Never mutate data.

Post the verdict as an MR comment: `QA: CLEAN` or `QA: DEFECTS` with screen + breakpoint + what is
wrong. Be picky — pixel-perfection standards apply; flag anything that looks off even if unrelated
to the diff. On DEFECTS: **exactly one** fix round (sonnet subagent, scoped hard to the findings'
blast radius, never migrations) → re-deploy → re-QA. Second DEFECTS → label `needs-human`, notify,
stop touching that MR.

### D — Human gate (notify via PushNotification and hold)

- `#25/#26/#27` merged+deployed but **no ops account exists** → give the human the exact artisan
  command from spec §3 and say `#137` is held until it is run. There is no registration endpoint;
  you cannot create it yourself.
- a migration file was written → the human applies it. Never apply DDL.
- a second QA round failed.
- the dev DB has no data to render (the dashboard reads DA-written tables; dev may be sparse) →
  report as an **environment gap, NOT an FE defect**.

### E — Done

Both paths' issues merged into `dev`, `#137` QA CLEAN, no open batch MR → post the run report
(per-MR: issues covered, diff size, QA verdict; anomalies; what the human still owes) and
`ScheduleWakeup {stop: true}`.

## Step 2 — close the tick (mandatory, no exceptions)

Append one line to `scratch/ops-dashboard/loop-log.md`:

```
<ISO time +08:00> | tick | actions=<A,B,C|idle> | launched=<issues|-> | deployed=<mr|-> | qa=<mr:verdict|-> | held=<issues|-> | anomalies=<...|->
```

Update `loop-state.md` (≤20 lines): last digest, last tick, hints worth saving for the next tick.
A tick that skips Step 2 is a bug — the journal is what the morning review stands on.

## Pacing (dynamic `/loop`)

| Tick ended with | Next wakeup |
|---|---|
| a batch subagent running | 1800s (its completion notification is the real signal; this is the hang fallback) |
| waiting on a dev pipeline | 300s |
| held on the human gate | 1800s |
| idle | 1800s |
| done (E) | stop |

## Known traps (do not re-learn these)

- **`dev` moves under you** — another agent may merge mid-batch. Rebase on `origin/dev` and re-run
  `npm ci` if the lockfile moved.
- FE verify: `export CHROME_BIN="/c/Program Files/Google/Chrome/Application/chrome.exe"` or headless
  karma dies. `ng build` enforces CSS budgets karma does not. `npm run i18n:guard` is RED and is
  NOT a gate — ignore it.
- BE verify: `MSYS_NO_PATHCONV=1` is mandatory or docker rejects `-w /app`.
- FrankenPHP worker serves **stale PHP** until `docker compose restart app` — if a local BE change
  seems not to apply, that's why.
- **The Agent harness may silently run a subagent in its OWN worktree** (`.claude/worktrees/agent-<id>`).
  Tell: the agent reports a commit hash but the batch branch HEAD didn't advance. Always confirm
  each subagent's commit is on the batch branch HEAD before calling an issue done; cherry-pick if not.
- If `git push` hangs, push via HTTPS token (`grep token: ~/AppData/Local/glab-cli/config.yml`);
  `tr -d '\r'` any content pushed through the GitLab API or autocrlf flips the whole file.
- Both RDS instances run `time_zone=UTC` while local is UTC+8 — always label which clock a
  timestamp is in.
- `information_schema` table stats are cached 24h here — only `COUNT(*)` is admissible for row counts.
