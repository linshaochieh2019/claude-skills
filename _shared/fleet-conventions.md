# Fleet conventions — onboarding a repo into the pipeline

How every project on this fleet runs development, verification, ticketing, and merging. Copy this checklist when standing up a new repo; cite it instead of re-deriving per-project. Repo-specific *values* live in each repo (`.iterate-issues.json`, CLAUDE.md); the *shapes* live here. This repo is public — no secrets, no host-specific details.

## 1. Task tracking — GitHub issues, nothing else

Issues are the only tracker (no Notion/Linear/Jira). Labels are the state machine:

| Label | Owner | Meaning |
|---|---|---|
| `needs-triage` | anyone files | entry point — `/triage` routes it |
| `ready-for-agent` | `/triage` | agent may pick up; **no open product decisions inside** |
| `ready-for-human`, `needs-info` | `/triage` | not agent work |
| `in-progress`, `done`, `needs-human` | `/iterate-issues` | per-issue batch state |
| `batch-pr-open`, `bot-review-timeout` | `/iterate-issues` | batch-PR level |

Conventions: dependency edges as `Depends on #N` / `Blocked by #N` lines; decision tickets are normal issues with a "待拍板" checklist; agents file issues freely with `needs-triage`, humans promote.

## 2. Code review CI — fleet-wide shared config, not per-repo tuning

`.github/workflows/openai-code-review.yml`, identical shape in every repo:

- `openai/codex-action@v1`, model **`gpt-5.6-terra`** (fleet standard since 2026-08-01), secret `OPENAI_API_KEY_CODE_REVIEW` (same name everywhere, separately valued per repo).
- Check name **`Code Review`**, summary comment marker **`<!-- ai-code-review -->`** — this is the `/iterate-issues` contract (see iterate-issues.md "Code-review workflow contract"); never rename per provider.
- Tier policy: terra by default (precision > recall — a false positive becomes real agent work downstream). Hand-escalate to `gpt-5.6-sol` only on auth/schema/money PRs. Never `gpt-5.6-luna`.
- Carry revking's RED guard: if the review step produces no review, force the check RED with "Automated code review did not run" — a review that never ran must never look green.

## 3. `.iterate-issues.json` — the per-repo contract surface

Copy from `iterate-issues/config/.iterate-issues.example.json`. Every new repo should fill in, at minimum:

- `baseBranch`, `setupCommand`, `verificationCommands` (lint + typecheck + test + build where they exist).
- **`mergePolicy`** — `autoMerge` (human's call, per repo) + `needsHumanPaths` (migrations, auth, payments/push-quota surfaces, webhook entry points). Matcher is prefix-only: enumerate nested `actions.ts`-style files, don't glob. Safe-tier auto-land runs through `/land-pr`; risk-tier ALWAYS pings the human — non-negotiable.
- **`standingDecisions`** — answers a human already gave, so no question gates twice. Agents cite entries and act, agents may propose entries, only humans commit them. Pair with the repo's `docs/decisions.md` (append a row the same day a decision is made; the ledger entry cites it).
- **`liveQa`** — `startCommand`, `port`, `loginScript`, `breakpoints`. Without this block, every UI batch exits "rendered layer unverified" and parks on a human.

## 4. QA auto-login — the `qa-login` script pattern

The rule that makes agent QA possible: **the QA agent authenticates by running a repo-committed script, never by handling or typing a secret.**

Script contract (`scripts/qa-login.mjs` or equivalent):
- Reads its own secrets from `.env.local` (dev-login secret, QA operator subject via env, port via flag).
- Authenticates programmatically (e.g. POST the repo's dev-login endpoint) and emits a browser-injectable session (Playwright `storageState` JSON or a printed cookie).
- Fails loudly and distinctly on auth errors (403 "subject didn't resolve — check operators table") so QA never misreads an auth failure as a UI bug.
- Dev-login endpoints keep their guards (dead in production, timing-safe secret compare, identity must resolve) — the script replaces "human pastes into a form", it widens no attack surface.

## 5. Migrations — CI applies, humans decide, agents verify

- **Apply path is CI-only** (e.g. Supabase GitHub integration, push-to-main auto-applies `supabase/migrations/`). No manual SQL Editor / psql DDL, ever. A repo whose migration ledger is untrusted must reconcile it (read-only `information_schema` audit → repair ledger once → enable CI apply) before agents can treat "merged" as "live".
- `supabase/migrations/` stays in `needsHumanPaths` — the human merges migration PRs; only the *application* is automatic.
- Batch runs author migration files only, never apply (iterate-issues contract).
- **Post-merge verification needs a Management API token** (`SUPABASE_ACCESS_TOKEN` in `.env.local` only — not a runtime env): PostgREST can prove a column resolves but is blind to RLS policies, grants, indexes, triggers. Query `pg_policies` / `information_schema` read-only, report pass/fail + error codes only, never row data. Without the token, migrations exit UNVERIFIED → needs-human by design.
- Guard the repo side with a committed test: already-applied migration files must never be edited (new numbered file instead).
- Integration/e2e tests hit a **separate test project**, never prod, with prod credentials deleted from `process.env` so prod is not a fallback.

## 6. Journals and the learning loop

Every repo carries `loops/`:

- `loops/iterate-issues/log.md` — append-only, one entry per batch run (schema in iterate-issues.md Step 6.5): escalations tagged with `standing-candidate`, handler-introduced-defect counts, gates-at-exit, contract friction. A run that ends without journaling is a bug.
- `loops/conduct-issues/log.md` — one line per conductor tick, plus gitignored soft state.
- **Evolve cadence:** `/iterate-issues evolve` (≥3 run entries) and `/conduct-issues evolve` (≥10 tick lines) read journals across repos and propose contract diffs — presented to the human, never self-applied. One repo's scar tissue becomes every repo's rule; the contract lives in this repo and changes go through the human.

## 7. Human-gate policy — what may be automated away, what stays

A gate is removable only when one of these holds:
1. **The check can be mechanized** — script, CI rule, deployed-env probe (then automate the check, not the judgment).
2. **The decision was already made** — a human answered once; record it in `standingDecisions` and stop asking.
3. **The action is cheaply reversible AND verified** — safe-tier auto-merge exists because revert is one commit and QA + review ran.

Gates that stay human, always: first-time product decisions (undecided-rule guard), risk-tier merges (migrations/auth/money), anything irreversible whose success can't be machine-verified, and spending money. When an agent hits a gate that feels removable, it doesn't remove it — it journals it as friction/standing-candidate and lets evolve propose the change.

## 8. Agent-facing context hygiene — the `/doctor` rules

Distilled from the 2026-08-02 `/doctor` pass across revking/fujia/hermesops/mini-os (revking #1096–#1100, fujia #191, hermesops #159–#161, mini-os #122–#123). These are the standards a repo's always-loaded docs are audited against:

- **Always-loaded context is a budget.** Root CLAUDE.md is a thin router (~3k chars): non-derivable facts plus one-line pointers, nothing else. No file over the **40k-char large-file threshold** in the required reading chain, and never `@import` one. Reference docs (glossary, design system, playbooks) are **grep-on-demand, not full-read** — their value is in 查, not 讀. (revking's forced pre-read chain had hit ~26k tokens, 19k of it glossary.)
- **One fact, one home.** Every fact has exactly one owner file; everywhere else holds a one-line pointer. Reading order is defined once. Status snapshots ("P1 已上 prod…") never live in CLAUDE.md — they drift against the authoritative file (ROADMAP etc.) and the session reads the stale copy *first*.
- **Derivable content gets cut.** Directory trees, module one-liners, schema tables (canonical: `supabase/migrations/`), env-var lists, workflow filenames, git remotes — a session rebuilds these by reading the repo, and the copies go stale independently. Keep only the non-derivable half-sentence (which workflow is active vs standby, `[DORMANT]` markers, out-of-scope declarations, traps).
- **Stale beats missing for damage.** The bar for CLAUDE.md is 「讀了不會做出錯誤判斷」— docs describing already-fixed bugs as alive, or referencing dead symlinks, actively mislead. A doc claim of unknown freshness gets **verified before kept** (fujia's "已修復" Vercel note: verify, then keep or delete — never trust its self-report).
- **Prune against an explicit KEEP inventory.** Every slimming ticket enumerates the guard rules that must survive verbatim (鐵律 blocks, RLS conventions, "never test against prod", anti-drift vocabulary rules) as acceptance criteria. Slimming without a KEEP list is how load-bearing rules die silently.
- **Decision archaeology → `docs/decisions.md`.** The *why* of a past decision moves to the ledger (cites the issue); CLAUDE.md keeps only the operational rule. Pairs with `standingDecisions` (§3).
- **Long runbooks → on-demand skills.** A 55k-char playbook becomes a `.claude/skills/` entry with trigger frontmatter: daily cost drops to one description line, and the doc self-triggers instead of relying on the operator remembering it exists. Retired doc paths keep a redirect note so links don't break.
- **Mechanical config hygiene.** No dead symlinks under `.claude/skills/` (and don't "fix" them by re-pointing if that floods every session with tool descriptions). Settings that agents depend on (e.g. `additionalDirectories`) are listed in full in the checked-in `settings.json`, so the result doesn't depend on settings-merge semantics.
- **Doctor ticket craft.** Findings land as normal `ready-for-agent` issues: quantified (chars/tokens saved), KEEP list in acceptance criteria, and same-file edits chained with `Blocked by #N（同檔編輯）` so batch runs don't conflict.
