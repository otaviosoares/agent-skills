# Loop-kit v2 — the AFK issue loop

**Status:** agreed spec (grilling session, 2026-07-13). Supersedes the wave-oriented loop-kit design.

## Motivation

The planning flow has moved out of loop-kit: `/grilling` produces a spec, `/to-tickets`
publishes it as tracer-bullet issues with native blocking edges and a `ready-for-agent`
label, and `/implement #N` builds a ticket (TDD at seams, typecheck/test cadence,
`/code-review` at the end, commit to the current branch). That makes loop-kit's
`plan`/`materialize`/`migrate` machinery and its builder/reviewer/fixer sub-agent briefs
redundant.

The one missing piece is **AFK work**: claim a ready issue, build it with `/implement`
in a worktree, open an MR, and repeat — always in a fresh session so context never
fills up. Loop-kit v2 is that piece and nothing else.

## One-sentence shape

A driver that repeatedly spawns a fresh headless session which claims one
`ready-for-agent` issue, builds it with `/implement` in a per-issue worktree, opens an
MR that `Closes #N`, and stops when nothing is pickable — the human is always the merge
gate.

## Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Skill shape | Rewrite loop-kit **in place** — keep the name, driver, `track` adapters, claim/reconcile machinery |
| 2 | Land mode | **MR/PR-only**; `LAND_MODE=merge` deleted |
| 3 | Per-repo judgment files | `loop.recipes.md` + `loop.scope.md` **deleted**; repo judgment lives in the repo's own CLAUDE.md |
| 4 | How `/implement` runs | In a **fresh sub-agent** spawned by the orchestrator, not inline |
| 5 | Dependency gating | New **`track deps N`** verb: native blocking links, body-text fallback |
| 6 | Starved/empty queue | **Stop with a handoff summary** — no standing WAIT loop |
| 7 | Review-response | **Kept**, recipe references removed |
| 8 | ClickUp backend | **Deleted** (no code host → no MR; structurally dead in MR-only mode) |
| 9 | Run-log | Kept as an issue **discovered by label** (no fixed id in config), auto-created |
| 10 | Migration for old repos | **None in code** — README documents the manual steps |
| 11 | Close semantics | MR description carries **`Closes #N`** — merging auto-closes the issue and unblocks dependents |
| 12 | Tracker interface | **`track` stays** — deterministic verbs for the unattended path; interactive skills keep calling `gh`/`glab` directly |

## Architecture (unchanged in spirit)

Two tiers, context always flat:

- **Driver** (`loop-drive.sh`) — spawns a fresh headless `claude -p` per iteration, reads
  the `LOOP_STATUS` sentinel, decides when to fire the next session and when to stop.
  Sentinel protocol, INTERRUPTED handling, backoff, and tunables (MODEL, EFFORT,
  MAX_ITERS, PERMISSION_MODE, …) carry over unchanged.
- **Orchestrator** (one fresh session per iteration) — thin; claims one issue, delegates
  the build to a fresh sub-agent, does the MR + bookkeeping tail itself. The sub-agent's
  implementation context is discarded when it returns, so the push/MR/log/sentinel tail
  always has room. All durable state lives on the tracker; each session re-derives it.

Each tracker issue is still the lock; multi-runner semantics (distinct logins in
`assignee` strategy, `note` comment-marker CAS with per-agent `RUNNER_ID` for shared
logins) carry over unchanged.

## The iteration (new runbook skeleton)

1. **SYNC** — `git fetch origin`; fast-forward the base branch. Derive live state:
   `track sync-list "$READY_LABEL"`. Read the run-log tail (last 1–2 entries).
2. **RECONCILE** — finish dangling claims (mechanics unchanged: `reconcile-mine`,
   `claim-owner`/`whoami` gate under shared logins, `branch-merged` check). A prior
   `BLOCKED` entry's `Unblock-when:` condition is re-tested first. The merge-mode
   branches of the old RECONCILE (resume-at-LAND, CI-truth re-tests) are gone; what
   remains is: branch already merged → finish the stranded tail (log, done); branch
   exists unmerged → resume (push + open MR, or re-run the implement sub-agent if the
   worktree is incomplete).
3. **REVIEW-RESPONSE** (before new work) — if `reviews-pending` returns an in-review
   issue of yours with actionable human feedback, spawn the responder sub-agent: it reads
   the feedback (`review-read`), fixes the branch, pushes, and replies inline to every
   item (`review-reply`). Never merges, never resolves threads. That is the iteration's
   work → log, emit `CONTINUE`, stop. The responder brief drops all `$LOOP_RECIPES`
   references — it trusts the repo's CLAUDE.md and minimal-change rules.
4. **PICK** — one OPEN issue that is: labeled `$READY_LABEL` · unassigned · not
   in-progress · not in-review · every blocker returned by `track deps N` is **closed**.
   Nothing pickable → see "Stop conditions".
5. **CLAIM** — `track claim N` (atomic CAS, unchanged) → `won` or `lost`; on `lost`,
   back to PICK.
6. **WORKTREE** — create `$BRANCH_PREFIX/N-<slug>` as a worktree off the up-to-date base
   branch.
7. **IMPLEMENT** — spawn **one fresh sub-agent** with a minimal brief:

   > In worktree `<path>` (branch `<branch>`), run the `/implement` skill for issue #N
   > of `<repo>`. Get the goal and acceptance criteria with `track view N`. Commit to
   > the current branch. Return ONLY `{issue, branch, headSha, ci:"green"|"red",
   > summary, blockers:[]}`.

   `/implement` itself is unchanged: it TDDs, typechecks, runs the suite, runs
   `/code-review`, and commits to the current branch. It does not push.
8. **MR** — orchestrator pushes the branch and opens the MR/PR via
   `track open-pr <branch> N`; the description carries **`Closes #N`** so the human's
   merge auto-closes the issue and re-arms dependents. `open-pr` failing → `release N`,
   log `BLOCKED` with an `Unblock-when:`, emit `BLOCKED`.
9. **MARK** — `track mark-review N "$url"`. The issue stays OPEN + in-review, so PICK
   skips it and dependents stay gated until the human merges (auto-close does the rest).
10. **LOG** — one run-log line: `iter K — MR'd #N (<url>) · awaiting merge · remaining: …`.
11. **FINISH** — remove the worktree, print the `LOOP_STATUS` sentinel, stop. Never loop
    back to SYNC in-session.

### Stop conditions

- **Work done this iteration** → `CONTINUE`.
- **Nothing pickable** (queue empty, or every remaining ticket is blocked on un-merged
  MRs / claimed by another runner) → post a **handoff summary** to the run-log — e.g.
  `done for now: 3 MRs open (#12 #14 #15), 2 tickets blocked on them (#16 #17)` — and
  emit `COMPLETE`. Rationale: in MR-only mode nothing unblocks without the human, so
  polling buys nothing while AFK. `WAIT` disappears from the runbook's vocabulary (the
  driver may keep understanding it for compatibility, but the skeleton never emits it).
- **Human decision needed** → log `BLOCKED … Unblock-when: <re-checkable condition>`,
  leave the claim intact, emit `BLOCKED`.

## Config surface

`plans/loop.config.sh` is the **only** per-repo file (plus the `plans/run-loop.sh`
launcher). All values `${VAR:-default}` so env overrides win.

| var | default | notes |
|---|---|---|
| `TRACKER_BACKEND` | detected from `git remote` | `github` or `gitlab` only |
| `REPO` | detected | `owner/name` or `group/project` |
| `GITLAB_HOST` | — | self-hosted GitLab |
| `READY_LABEL` | `ready-for-agent` | the pick queue; matches what `/to-tickets` applies |
| `RUNLOG_LABEL` | `loop:runlog` | run-log discovery label |
| `BRANCH_PREFIX` | existing default | branch/worktree naming; RECONCILE greps on it |
| `CLAIM_STRATEGY` | `assignee` (`note` where single-assignee) | unchanged semantics |

**Removed:** `WAVE`, `RUNLOG` (fixed id), `LAND_MODE`, the `GH_PROJECT*`/board block if
it only served wave flows, and every ClickUp var.

## `track` changes

`track` stays as the loop's tracker seam (decision 12): deterministic, tested verbs for
the unattended/repeated path. The claim CAS and the `reviews-pending` query are exactly
the order-sensitive dances that must not be re-improvised by a fresh session each
iteration (cf. the `_mr_for --state` bug — fixed once in the adapter, stayed fixed).

- **New verbs:**
  - `deps N` — print the ids of issues blocking N. GitLab: native issue links
    (`blocked_by`); GitHub: native relationships where available; both fall back to
    parsing a `## Blocked by` section from the body (what `/to-tickets` writes on tiers
    without native links). PICK treats N as unblocked iff every returned id is `closed`.
  - Run-log resolution by label — `log`/`runlog-tail` resolve the newest OPEN issue
    labeled `$RUNLOG_LABEL`, creating it (deterministic title) if none exists. The
    create path should be search-then-create to keep the duplicate window small.
- **Deleted:** `adapters/clickup.sh` and any merge-mode-only verbs (audit the verb list;
  e.g. anything that existed solely to merge to the base branch or close issues from the
  loop — `close` may survive only if RECONCILE still needs it for stranded tails).
- **Kept:** `sync-list`, `view`, `item-state`, `claim`, `claim-owner`, `whoami`,
  `release`, `mark-review`, `open-pr`, `branch-merged`, `reconcile-mine`,
  `reviews-pending`, `review-read`, `review-reply`, `log`, `runlog-tail`, `caps`.

## Deletions (the point of the rewrite)

- `LAND_MODE=merge` and everything that existed to make unattended merging safe:
  the CI-TRUTH carve-out, the LAND lockfile/supply-chain recipe, the `<<FILL>>`
  fail-loud token machinery and its pre-run grep gates.
- `plans/loop.recipes.md` + `plans/loop.scope.md`, `recipes.template.md`,
  `scope.template.md`. Repo judgment = the repo's own CLAUDE.md, which every fresh
  `/implement` session reads anyway.
- Sub-commands `plan`, `materialize`, `migrate` and their engines/templates:
  `materialize-plan.mjs`, `materialize-core.mjs`, `materialize-github.mjs`,
  `materialize-gitlab.mjs`, `materialize-clickup.mjs`, `migrate.mjs`, `plan.template`.
  `/to-tickets` owns backlog authoring end-to-end.
- The builder / reviewer / fixer sub-agent briefs (replaced by the single `/implement`
  brief; review is inside `/implement` via `/code-review`, plus the human MR review).
- The ClickUp backend, `WAVE`, keystones, wave-advancement docs.
- `tests/` entries covering any of the above (prune to match).

## Kept

- `loop-drive.sh` — sentinel protocol, INTERRUPTED/backoff handling, all tunables.
- `track` + `adapters/github.sh` + `adapters/gitlab.sh`, claim strategies, multi-runner
  semantics, WIP=1 per runner.
- Worktree-per-issue lifecycle (create at claim, remove at FINISH).
- Review-response (placement, verbs, self-limiting drain semantics), default ON.
- `init` / `config` / `run` sub-commands, the auto-init guard, both delivery modes
  (call-from-skill and scaffold-a-copy), never-auto-commit, non-destructive `init`.

## `init` in v2

Radically simpler: probe the remote → confirm backend/host, `READY_LABEL`,
`BRANCH_PREFIX` → emit `plans/loop.config.sh` + `plans/run-loop.sh`. No recipes, no
scope, no FILL tokens, no runbook copy. Wiring check unchanged
(`--print-kit-dir`, `track caps` with the config exported).

## Migration (documentation only — decision 10)

No code support. The README gets a short "migrating from v1" section:

1. Rewrite `plans/loop.config.sh`: drop `WAVE`/`RUNLOG`/`LAND_MODE`, add
   `READY_LABEL`/`RUNLOG_LABEL`.
2. Delete `plans/loop.recipes.md`, `plans/loop.scope.md`, and any `plans/wave-loop.md`.
   Anything in them worth keeping (build constraints, review lenses) moves into the
   repo's CLAUDE.md.
3. Label the run-log issue `loop:runlog` (or let the loop create a fresh one).
4. Ensure open tickets carry `ready-for-agent` and blocking links (`/to-tickets` output
   already does).

Known consequence, accepted: `init` keeps existing files, so a stale v1 config on an
onboarded repo (ezk) must be edited by hand.

## Out of scope / unchanged by design

- `/implement`, `/to-tickets`, `/grilling`, `/setup-matt-pocock-skills` — no changes.
- Driver model/effort defaults — still env tunables.
- Merge-debt policy ("don't refill while > N in review") — stays a documented rule, not
  code; review-response plus the stop-summary keep it visible.
- SKILL.md gets a full description rewrite (valid folded YAML `>-`, no bare `: `,
  ≤1024 chars — the `npx skills` constraint).
