# Loop Kit — reference

The contract behind the skill: the tracker verbs, the lock guarantees, the capability matrix, the
config resolution, and the producer. Backend-neutral — no project specifics here.

## The two-tier loop (why context stays flat)

```
DRIVER (loop-drive.sh)  — stateless; spawns a fresh headless `claude -p` per iteration, reads a
                          LOOP_STATUS sentinel, decides fire-next / sleep / stop.
  └─ ORCHESTRATOR (one fresh session per iteration — thin, short-lived)
       re-derive state from the tracker → RECONCILE any dangling claim → PICK + CLAIM one issue
       → BUILDER sub-agent (fresh ctx) → REVIEWER sub-agent (fresh, independent) → [FIXER if P0/P1]
       → LAND (merge to main, or open a PR) → CLOSE/mark-review → run-log → print sentinel + STOP
```

Two invariants make it resumable after any crash/restart/summarization:
1. The orchestrator carries **no state in its head** — it re-derives everything from the tracker
   every iteration (issue open/closed + in-progress label + assignee = machine truth; the **run-log**
   issue = the human resume trail, read at SYNC, written at LOG).
2. The brief to a sub-agent is **minimal** (`{issue id, repo, runbook path}`); the sub-agent fetches
   its own acceptance criteria. The orchestrator never reads source/diffs/test output itself.

### The `LOOP_STATUS` sentinel (the driver's only input from the agent)
- `CONTINUE` — did a unit of work; pickable work likely remains → fire the next fresh session.
- `WAIT` — work remains but nothing pickable now (a dep is in-flight on another runner) → sleep, re-run.
- `COMPLETE` — nothing left → exit 0.
- `BLOCKED` — a human decision/input is needed → exit 2.
- *(implicit)* INTERRUPTED — non-zero exit + no sentinel → state UNKNOWN; the driver backs off and
  retries (bounded by `MAX_FAILS`); the runbook's RECONCILE step self-heals the dangling claim.

## Config resolution

`track` resolves its project config to the **first that exists** of: **`$TRACKER_CONFIG`** →
**`$PWD/plans/loop.config.sh`** (call-from-skill, run from the repo root) → **`$HERE/../loop.config.sh`**
(vendored mode, where the kit lives at `<repo>/plans/loop-kit/`) → the kit's `tracker.config.example.sh`
(placeholder fallback, with a LOUD warning). The driver `export`s `TRACKER_CONFIG` =
`<repo>/plans/loop.config.sh` and `LOOP_KIT_DIR` = the kit dir into every spawned session, so the
runbook's `"$LOOP_KIT_DIR"/track` calls always hit the first branch. **Interactive (no driver):** run
`track` from the repo root (the `$PWD/plans/loop.config.sh` branch resolves it) or export
`TRACKER_CONFIG` — otherwise it falls through to the placeholder `REPO=owner/repo`. Every config value
is `${VAR:-default}` so an env override always wins.

`loop.config.sh` keys: `TRACKER_BACKEND` (github|gitlab|clickup — `local` is a planned backend, no
adapter shipped yet), `LAND_MODE` (merge|pr), `REPO`,
`RUNLOG`, `WAVE` (default scope label), `BRANCH_PREFIX`, `CLAIM_STRATEGY` (github+gitlab: assignee|note;
github note REQUIRES a per-agent `RUNNER_ID` — see the lock contract below),
the optional github `GH_PROJECT*`/`GH_FIELD_*` board block (producer only), and the clickup
`CLICKUP_TOKEN`/`CLICKUP_LIST_ID`/`CLICKUP_STATUS_DONE`/`CLICKUP_API` block (clickup uses `CLICKUP_LIST_ID`
as the tracker unit in place of `REPO`, scope/labels are space tags, and `RUNLOG` is a task id).

## Verbs (the stable interface)

The runbook calls these via `"$LOOP_KIT_DIR"/track <verb>`; `TRACKER_BACKEND` selects the adapter.

| verb | purpose | criticality |
|---|---|---|
| `caps` | print backend capabilities (atomic-claim, can_open_pr, land_modes) | — |
| `sync-list <scope>` | open work-items in scope as JSON (id,title,labels,assignees,state) | state |
| `runlog-tail [N]` | last N run-log entries (the resume trail) | state |
| `view <id>` | one item's body + labels + state + assignees | state |
| `item-state <id>` | `open\|closed` (the dep gate) | state |
| `reconcile-mine <scope>` | my in-progress items (the dangling-claim signal) | state |
| `branch-merged <branch>` | `yes\|no` — is this branch already on `main` | state |
| `claim <id>` | **atomic claim → `won\|lost`** — the only lock-critical verb | **lock** |
| `claim-owner <id>` | note strategy: live owner's claimant id (smallest claimant whose latest marker is a claim), else empty — RECONCILE's shared-login gate | lock |
| `whoami` | my claimant id in `claim-owner`'s shape (note: `login#RUNNER_ID`; assignee: `login`) | lock |
| `release <id>` | release my claim (lost race / abort) | lock |
| `close <id>` | terminal close + remove in-progress (merge mode) | state |
| `mark-review <id> <url>` | remove in-progress, add in-review, keep assignee, note URL (PR mode) | state |
| `log <body>` | append one run-log entry (arg or stdin) | state |
| `open-pr <branch> <id>` | push branch + open PR/MR, print URL (PR mode) | — |
| `board-done <id>` | optional board projection; no-op-able | convenience |

## The lock contract (every backend satisfies the *guarantee*, not the mechanism)

Of N runners racing for an item: (1) **exactly one wins**; (2) the **loser detects** the loss and
yields; (3) the lock is **owner-releasable**; (4) ownership carries a **stable, globally-unique,
comparable claimant id that survives a crash** (so RECONCILE finds a dangling claim). `claim` returns
`won|lost` and hides how:

- **GitHub** — add assignee + in-progress label, re-read after a short **stabilization delay**
  (assignees are eventually-consistent — a naive immediate re-read can elect two winners), winner =
  **case-folded lexicographically-smallest** assignee login. Needs **N distinct logins** in the default
  `assignee` strategy. Best-effort CAS, backstopped by the contention-overlap skip at PICK and git's
  non-fast-forward push rejection at LAND.
  - **`CLAIM_STRATEGY=note`** lets **N agents share ONE login** (claimant id = `login#RUNNER_ID` in a
    `claimed by …` comment marker). **Two-level CAS:** every runner assigns its login up front, so
    level-1 is the *same* smallest-assignee-login arbitration as `assignee` mode (the two strategies
    **interop** on one issue — an assignee runner needs no awareness of note runners); level-2 breaks
    ties among agents under the winning login by smallest marker id. Comments are append-only, so
    simultaneous claims don't clobber — the deterministic read picks the winner. **Ownership is
    identity-based, not timed:** the live owner is the smallest claimant whose *latest* marker is a claim
    (a `released by …` tombstone retracts it) — so there is **no liveness window and no heartbeat**, a
    build of any length is safe, and a crashed agent recovers its OWN claim by **reuping with the same
    `RUNNER_ID`** (`RUNNER_ID` is therefore REQUIRED — it must be stable across restarts and distinct
    between concurrent agents; note mode refuses to claim without one). **Shared-login RECONCILE** is
    runner-aware via `claim-owner`/`whoami`: adopt a dangling claim only if the live owner is itself (or
    none), never a sibling. **Invariant:** a login is wholly one strategy (operator-enforced; mixing
    strategies under one login double-builds). The git non-fast-forward push at LAND remains the final
    backstop against a double *merge*.
- **GitLab** — same, but assignment must be the **additive `+` union** (a bare replace is
  last-writer-wins and unsafe); single-assignee tiers (Free / many self-hosted) → `CLAIM_STRATEGY=note`
  (note-marker CAS — owner = smallest claimant whose latest note is a claim, `released by …` tombstone
  retracts it; identity-based, no time window, same as github note mode but username-granular).
- **ClickUp** — same additive-union shape (`{"assignees":{"add":[id]}}`; ClickUp is natively
  multi-assignee, so there is no single-assignee fallback to worry about), re-read after a stabilization
  delay, winner = **numerically-smallest assignee id** (the claimant id is the stable numeric ClickUp
  user id). Needs **N distinct CLICKUP_TOKENs** (one per user). Backstopped, like the others, by the
  PICK contention-overlap skip and git's non-fast-forward push rejection at LAND.
- **local** *(planned — `adapters/local.sh` not shipped yet)* — kernel `mkdir`/`O_EXCL` (same host,
  true mutex) or `git push` non-fast-forward rejection (distributed CAS). **REFUSED:** cross-machine
  local over a bare shared FS (NFS/SMB/Dropbox/iCloud/Syncthing) — atomicity isn't guaranteed; the
  adapter must detect-and-refuse, never degrade silently (the failure mode is a silent double-build).

## Capability matrix

Shipped backends: **github**, **gitlab**, **clickup**. `local` is designed (below) but has no adapter yet.

```
backend          atomic-lock            cross-machine multi-runner    open-PR   deps
github (gh)      yes (login-sort CAS)   N logins, or note: N/login     yes       issue-body dep list / title convention
gitlab (glab)    yes (additive-+ CAS)   yes (N distinct users)        yes (MR)  native blocked_by links (stronger)
clickup (curl)   yes (id-sort CAS)      yes (N distinct tokens)       NO        task-body dep list (ClickUp hosts no code)
local (planned)  mkdir/O_EXCL or        same-host-N, or cross-machine no        native deps:[id] frontmatter
                 git-push rejection     ONLY via a git remote (=server)
```

ClickUp is a tracker, not a code host: `branch-merged` is git-only and `open-pr` fails loud, so the
clickup backend supports **`LAND_MODE=merge` only** (the git push to the base branch still happens
against whatever code host — GitHub/GitLab/etc — the repo's `origin` points at).

## LAND_MODE

- **`merge` (default):** after rebase/regenerate/CI-green, the agent **merges to `main`** then
  `track close <id>`. Fully autonomous; dependents unblock immediately (the dep-gate keys on *closed*
  ⇒ code is on `main`).
- **`pr`:** after CI-green, `track open-pr <branch> <id>` opens a PR/MR and prints the URL, then
  `track mark-review <id> <url>` — **do NOT close**. The issue stays open + assigned + in-review, so
  dependents WAIT until a human merges and closes. Trades full autonomy for a human merge gate.

## Producer (`materialize-*`) — standing up a scope's issues

`materialize-core.mjs` is the offline, backend-agnostic machine; `materialize-{github,gitlab}.mjs`
are the CLIs/backends (selected by the same `TRACKER_BACKEND` axis as the runtime adapters). DRY by
default (mutates only with `DRY=0`).

```bash
# source the repo's plans/loop.config.sh first (exports REPO [+ GITLAB_HOST] [+ GH board config]).
KIT="$(./plans/run-loop.sh --print-kit-dir)"
DRY=1 node "$KIT"/materialize-github.mjs --batch-data <scope>.json --root <data-dir>   # rehearse
DRY=0 node "$KIT"/materialize-github.mjs --batch-data <scope>.json --root <data-dir>   # execute
```

- **Contract:** `materialize({ scope, labelFixes = [], dry = true, backend, root })`. `scope` is the
  label issues are filtered on (e.g. `wave:4`); `root` is the data dir holding `issues-open.json`,
  `created-issues.tsv`, `milestones.json`, `bodies/`. Both required — fail loud, no defaults.
- **`labelFixes`** — each `{ label, only: [<slug>…] }` means "this label appears ONLY on these
  slugs": for every selected issue, remove `label`, then re-add it iff the issue's slug ∈ `only`
  (empty `only` = strip-from-all). Applied in order. This is the generic form of the per-scope
  judgment a project hand-curates; lives in a backlog JSON (`{ scope, labelFixes }`), never in code.
- **Dedupe** is line-exact against the title column of `created-issues.tsv`.
- **Backends:** github creates via `gh issue create --body-file` (milestones assumed to pre-exist)
  and optionally places each issue on a Projects-v2 board (the `GH_PROJECT*`/`GH_FIELD_*` env block;
  unset → no-op). gitlab creates via `glab issue create --description` (labels auto-create;
  milestones do NOT → it list+POSTs the missing ones), no board (GitLab boards are label-driven).
  clickup creates via `POST /list/{id}/task` (tags = the label analog, attached on create; no board —
  ClickUp board views are status/tag-driven), milestones are a documented no-op (ClickUp has none).

### Backend interface (to add a backend)
```
{ name,
  ensureMilestones?: async (ms:[{title,description}]) => void,   // optional, WET-only, once up front
  createIssue: async ({title, bodyFile, body, milestone, labels}) => ({ url, id }),  // required
  placeOnBoard?: async ({url, id, wave, milestone, pkgs, size}) => void }             // optional
```

## Source format + `plan` checks (`materialize-plan.mjs`)

The producer reads the data dir; **`plan`** is the offline, zero-dependency engine that *authors* that
data dir from a friendlier **source tree** and *validates* it before any push. It carries no project IP
and reuses the producer's exact `slug`/membership rules so the two can't drift.

**Source tree** (`<root>/src/`, conventionally `plans/.tracker/src/`):
```
src/
  issue/<slug>.md     # YAML frontmatter + body. slug = FILENAME (so slug↔bodyFile can't mismatch).
  milestones.yml      # block seq of `- title:` / `  description:` (scalars only)
```
Each `issue/<slug>.md` frontmatter: `title` (req), `labels` (req, ≥1, must include the scope label),
`milestone` (req — resolved for *all* backends; clickup just no-ops creating it), `deps` (a list of
**slugs** in this same tree). The body is markdown (Goal + Acceptance criteria) and must **not** contain
a `## Dependencies` section — `compile` renders that. The frontmatter reader is deliberately tiny
(scalars + flat/`[a, b]`/block string lists only) and **fails loud** on anything richer.

**compile** lowers `src/` → the producer contract byte-compatibly: `issues-open.json` (`bodyFile =
bodies/<slug>.md`), `bodies/<slug>.md` (= the body + a rendered **`## Dependencies`** section), and
`milestones.json`. `created-issues.tsv` is create-if-absent only. It validates the source first and
refuses to write a dirty result, then re-checks the generated dir.

**The dependency heading is `## Dependencies`** — the one contract shared between what `compile` writes
and what the runtime PICK step parses (`runbook.template.md` step 2: gate each dep in the body's
`Dependencies` section on `item-state <id> = closed`). `compile` renders each dep as
`` - <dep title> (`<dep-slug>`) ``. `check` parses it back, resolving each ref to a slug or title; a
`#N` ref is treated as an **external** cross-wave dep (an issue already created in an earlier wave) and
is not flagged as dangling.

**check** is read-only, runs over a compiled OR hand-authored `--root`, and **accumulates every**
violation (never fail-on-first), exit 0/1:

| check | catches |
|---|---|
| bodyFile exists + non-empty | **the DRY footgun** — producer DRY never reads `bodies/`, so a typo'd `bodyFile` only fails at `DRY=0` on the live tracker |
| milestone resolves (all issues) | an undeclared milestone the producer's core would throw on |
| slug uniqueness (incl. case-fold) | two issues whose `bodyFile` reduces to the same slug (silent in core; membership/labelFixes key on slug) |
| ≥1 label; scope selects >0 (if `--scope`) | an issue in no scope, or a no-op materialize run |
| `deps` resolve | a `Dependencies` ref matching no issue → a runtime dep-gate that never clears |
| dependency DAG | a cycle that wedges the runtime in permanent `WAIT` (reported, never auto-broken) |
| `created-issues.tsv` present | the dedupe ledger the producer reads on every run |
| `labelFixes.only` slugs resolve (if `--batch-data`) | a silent no-op in the producer |

**Mechanical vs judgment** (the safety line): `check` asserts *resolvability* and *acyclicity*
(mechanical) — it never decides whether the deps are the *right* deps, never authors a body or a
criterion, and never chooses which edge breaks a cycle. **Pre-creation ID boundary:** `deps` resolve by
slug/title (the only stable pre-push handle); the runtime gate ultimately keys on issue open/closed
state. Intra-wave deps reference issues created in the same batch (the orchestrator maps the rendered
title/slug to the live issue); cross-wave deps to already-created issues use `#N` directly. Editing
issue titles on the tracker after push can drift this mapping — a documented boundary, not a guarantee.
