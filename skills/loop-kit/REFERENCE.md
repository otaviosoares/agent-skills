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

`loop.config.sh` keys: `TRACKER_BACKEND` (github|gitlab — `local` is a planned backend, no adapter
shipped yet), `LAND_MODE` (merge|pr), `REPO`,
`RUNLOG`, `WAVE` (default scope label), `BRANCH_PREFIX`, `CLAIM_STRATEGY` (gitlab: assignee|note),
and the optional github `GH_PROJECT*`/`GH_FIELD_*` board block (producer only).

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
  **case-folded lexicographically-smallest** assignee login. Needs **N distinct logins** (shared
  account → degrade to a `claimed by <name>` marker). Best-effort CAS, backstopped by the
  contention-overlap skip at PICK and git's non-fast-forward push rejection at LAND.
- **GitLab** — same, but assignment must be the **additive `+` union** (a bare replace is
  last-writer-wins and unsafe); single-assignee tiers (Free / many self-hosted) → `CLAIM_STRATEGY=note`
  (note-marker CAS, current-round time-windowed to exclude stale ghost claims).
- **local** *(planned — `adapters/local.sh` not shipped yet)* — kernel `mkdir`/`O_EXCL` (same host,
  true mutex) or `git push` non-fast-forward rejection (distributed CAS). **REFUSED:** cross-machine
  local over a bare shared FS (NFS/SMB/Dropbox/iCloud/Syncthing) — atomicity isn't guaranteed; the
  adapter must detect-and-refuse, never degrade silently (the failure mode is a silent double-build).

## Capability matrix

Shipped backends: **github**, **gitlab**. `local` is designed (below) but has no adapter yet.

```
backend          atomic-lock            cross-machine multi-runner    open-PR   deps
github (gh)      yes (login-sort CAS)   yes (N distinct logins)       yes       issue-body dep list / title convention
gitlab (glab)    yes (additive-+ CAS)   yes (N distinct users)        yes (MR)  native blocked_by links (stronger)
local (planned)  mkdir/O_EXCL or        same-host-N, or cross-machine no        native deps:[id] frontmatter
                 git-push rejection     ONLY via a git remote (=server)
```

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

### Backend interface (to add a backend)
```
{ name,
  ensureMilestones?: async (ms:[{title,description}]) => void,   // optional, WET-only, once up front
  createIssue: async ({title, bodyFile, body, milestone, labels}) => ({ url, id }),  // required
  placeOnBoard?: async ({url, id, wave, milestone, pkgs, size}) => void }             // optional
```
