<!-- loop-kit v2: this reference is refreshed by the v2 doc tickets (runbook skeleton #9,
     config surface #8, README/migration #11); until then it documents only what survives
     the v2 deletions. -->
# Loop Kit — reference

The contract behind the skill: the tracker verbs, the lock guarantees, the capability matrix, and
the config resolution. Backend-neutral — no project specifics here.

## The two-tier loop (why context stays flat)

```
DRIVER (loop-drive.sh)  — stateless; spawns a fresh headless `claude -p` per iteration, reads a
                          LOOP_STATUS sentinel, decides fire-next / sleep / stop.
  └─ ORCHESTRATOR (one fresh session per iteration — thin, short-lived)
       re-derive state from the tracker → RECONCILE any dangling claim
       → REVIEW-RESPONSE: an in-review PR with human feedback? → RESPONDER sub-agent → reply + STOP
       → else PICK + CLAIM one issue → build in a fresh sub-agent
       → LAND (open a PR/MR) → mark-review → run-log → print sentinel + STOP
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

## The runbook: a shared SKELETON

- **`loop-runbook.md`** — the canonical **skeleton** (backend/project-neutral state machine). It lives
  **in the kit** and is **symlinked** into each onboarded repo, like `track`/`adapters/`/`loop-drive.sh` —
  so a skeleton change propagates everywhere with no per-repo copy to go stale. The driver defaults
  `RUNBOOK` to it, so `./plans/run-loop.sh` (no runbook arg) uses it.
- **Per-repo judgment** (build constraints, review lenses, merge hotspots) lives in the target repo's
  own CLAUDE.md, which every fresh session reads anyway. The kit ships no judgment file.

**Pinning for reproducibility** uses the same knob as `adapters/`: the symlink/checkout. Vendor the kit
into `<repo>/plans/loop-kit/` (delivery mode "scaffold-a-copy") or install a pinned skill version to
freeze the skeleton; otherwise a skeleton update moves under the next iteration (usually what you want).

## Config + env resolution

`track` resolves its project config to the **first that exists** of: **`$TRACKER_CONFIG`** →
**`$PWD/plans/loop.config.sh`** (call-from-skill, run from the repo root) → **`$HERE/../loop.config.sh`**
(vendored mode, where the kit lives at `<repo>/plans/loop-kit/`) → the kit's `tracker.config.example.sh`
(placeholder fallback, with a LOUD warning). **Interactive (no driver):** run `track` from the repo root
(the `$PWD/plans/loop.config.sh` branch resolves it) or export `TRACKER_CONFIG` — otherwise it falls
through to the placeholder `REPO=owner/repo`. Every config value is `${VAR:-default}` so an env override
always wins.

**The driver (`loop-drive.sh`) exports into every spawned session:**
- `LOOP_KIT_DIR` — the kit dir (where `track` + `adapters/` + `loop-runbook.md` live);
  the skeleton's verb calls are `"$LOOP_KIT_DIR"/track …`.
- `TRACKER_CONFIG` — `<repo>/plans/loop.config.sh` (so `track`'s first resolution branch always hits).
- `WAVE`, `BRANCH_PREFIX` (+ the rest of the config) — the driver **sources `loop.config.sh` into its
  real env** (`set -a; . "$TRACKER_CONFIG"; set +a`) so the skeleton's `"$WAVE"` and `"$BRANCH_PREFIX/…"`
  references resolve in the agent's bash calls. Because the config uses `${VAR:-default}`, a value pre-set
  on the launch still **wins** — sourcing respects it.
- `BASE_BRANCH` — the integration branch (rebase target, PR base, the `branch-merged` check). Both
  the driver and `track` source `resolve-base-branch.sh` **after** the config, so an explicit
  env/config value wins; otherwise it auto-detects the repo's default branch (`origin/HEAD`, probing
  `main`/`master`/`trunk`, ultimately `main`). The agent's own `git rebase` and the adapters all
  read the **same** exported value — so a `master`/`trunk` repo is no longer mis-targeted as `main`.

`TRACKER_CONFIG` honors a pre-set env value (the driver only defaults it).

`loop.config.sh` keys: `TRACKER_BACKEND` (github|gitlab — `local` is a planned backend, no adapter
shipped yet), `REVIEW_RESPONSE` (on|off — review-response, default on), `REPO`, `RUNLOG`, `WAVE`
(default scope label), `BRANCH_PREFIX`, `BASE_BRANCH` (empty = auto-detect the repo's default branch;
set to pin a non-default integration branch), and `CLAIM_STRATEGY` (assignee|note; github note
REQUIRES a per-agent `RUNNER_ID` — see the lock contract below).

## Verbs (the stable interface)

The runbook calls these via `"$LOOP_KIT_DIR"/track <verb>`; `TRACKER_BACKEND` selects the adapter.

| verb | purpose | criticality |
|---|---|---|
| `caps` | print backend capabilities (atomic-claim, can_open_pr, can_respond_to_reviews) | — |
| `sync-list <scope>` | open work-items in scope as JSON (id,title,labels,assignees,state) | state |
| `runlog-tail [N]` | last N run-log entries (the resume trail) | state |
| `view <id>` | one item's body + labels + state + assignees | state |
| `item-state <id>` | `open\|closed` (the dep gate) | state |
| `deps <id>` | ids blocking `<id>`, one per line (empty = unblocked): native links first (GitHub issue dependencies / GitLab `is_blocked_by`), else a `## Blocked by` body section. PICK treats `<id>` as unblocked iff every id is `closed` | state |
| `reconcile-mine <scope>` | my in-progress items (the dangling-claim signal) | state |
| `branch-merged <branch>` | `yes\|no` — is this branch already on the base branch (`$BASE_BRANCH`) | state |
| `claim <id>` | **atomic claim → `won\|lost`** — the only lock-critical verb | **lock** |
| `claim-owner <id>` | note strategy: live owner's claimant id (smallest claimant whose latest marker is a claim), else empty — RECONCILE's shared-login gate | lock |
| `whoami` | my claimant id in `claim-owner`'s shape (note: `login#RUNNER_ID`; assignee: `login`) | lock |
| `release <id>` | release my claim (lost race / abort) | lock |
| `close <id>` | terminal close + remove in-progress — RECONCILE's stranded-tail fallback (a merged branch whose degraded PR carried no `Closes #N`) | state |
| `mark-review <id> <url>` | remove in-progress, add in-review, keep assignee, note URL | state |
| `log <body>` | append one run-log entry (arg or stdin) | state |
| `open-pr <branch> <id>` | push branch + open PR/MR, print URL | — |
| `reviews-pending <scope>` | my in-review items whose PR has actionable feedback → `[{number,title,pr}]` | state |
| `review-read <id>` | actionable feedback for #N → `{pr,branch,base,url,items:[{kind,reply_to,path,line,conversation}]}` | state |
| `review-reply <id> <reply_to> <body>` | post an inline thread reply (`reply_to`=token) or a conversation reply (`reply_to`=`conversation`) | — |

## The lock contract (every backend satisfies the *guarantee*, not the mechanism)

Of N runners racing for an item: (1) **exactly one wins**; (2) the **loser detects** the loss and
yields; (3) the lock is **owner-releasable**; (4) ownership carries a **stable, globally-unique,
comparable claimant id that survives a crash** (so RECONCILE finds a dangling claim). `claim` returns
`won|lost` and hides how:

- **GitHub** — add assignee + in-progress label, re-read after a short **stabilization delay**
  (assignees are eventually-consistent — a naive immediate re-read can elect two winners), winner =
  **case-folded lexicographically-smallest** assignee login. Needs **N distinct logins** in the default
  `assignee` strategy. Best-effort CAS, backstopped by the contention-overlap skip at PICK and git's
  non-fast-forward push rejection.
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
    strategies under one login double-builds). The git non-fast-forward push remains the final
    backstop against a double *merge*.
- **GitLab** — same, but assignment must be the **additive `+` union** (a bare replace is
  last-writer-wins and unsafe); single-assignee tiers (Free / many self-hosted) → `CLAIM_STRATEGY=note`
  (note-marker CAS — owner = smallest claimant whose latest note is a claim, `released by …` tombstone
  retracts it; identity-based, no time window, same as github note mode but username-granular).
- **local** *(planned — `adapters/local.sh` not shipped yet)* — kernel `mkdir`/`O_EXCL` (same host,
  true mutex) or `git push` non-fast-forward rejection (distributed CAS). **REFUSED:** cross-machine
  local over a bare shared FS (NFS/SMB/Dropbox/iCloud/Syncthing) — atomicity isn't guaranteed; the
  adapter must detect-and-refuse, never degrade silently (the failure mode is a silent double-build).

## Capability matrix

Shipped backends: **github**, **gitlab**. `local` is designed (above) but has no adapter yet.

```
backend          atomic-lock            cross-machine multi-runner    open-PR   deps
github (gh)      yes (login-sort CAS)   N logins, or note: N/login     yes       native issue dependencies, else ## Blocked by body
gitlab (glab)    yes (additive-+ CAS)   yes (N distinct users)        yes (MR)  native blocked_by links (stronger)
local (planned)  mkdir/O_EXCL or        same-host-N, or cross-machine no        native deps:[id] frontmatter
                 git-push rejection     ONLY via a git remote (=server)
```

**Review-response (`can_respond_to_reviews`)**: **github + gitlab = yes**
(`reviews-pending`/`review-read`/`review-reply` over PR review threads / MR discussions).

## Landing

After rebase + CI-green, `track open-pr <branch> <id>` opens a PR/MR (description carries
`Closes #<id>`) and prints the URL, then `track mark-review <id> <url>` — **the loop never merges or
closes**. The issue stays open + assigned + in-review, so dependents stay gated until a human merges;
the merge auto-closes the issue via the `Closes` keyword and re-arms dependents.

### Review-response (`REVIEW_RESPONSE`, default `on`)

By itself, the loop parks an issue in-review and never looks at it again — your review comments sit
untouched until you merge. With `REVIEW_RESPONSE=on` (the default, gated on
`caps.can_respond_to_reviews=true`), the orchestrator adds a **REVIEW-RESPONSE phase** that runs
**before PICK** (draining feedback on an open PR beats opening a new one — it reduces in-review debt):

1. `track reviews-pending <scope>` → my in-review items whose PR has **actionable** feedback.
2. A fresh **review-responder sub-agent** reads `track review-read <id>`, fixes the branch, pushes, and
   `track review-reply <id> <reply_to> <body>` answers **every** item inline. It does **not** resolve
   threads, re-request review, or merge — the human stays the gate. The issue stays OPEN + in-review the
   whole time (no label churn), so PICK still skips it and dependents stay gated.

**Actionability is self-limiting — no high-water marker, no re-processing loop:** a review *thread* is
actionable iff its **last comment is a human's** (once the bot replies, the bot's comment is last → the
thread drops out); *conversation* feedback (a PR comment, or a review body that isn't an inline thread)
is actionable iff it is **newer than the bot's last commit/comment** on the PR (the bot's push + reply
advance that high-water). An interrupted responder is safe: already-answered items drop out, so a re-run
addresses only the remainder. `reviews-pending` keys on the **assignee**, so each runner drains its own
PRs; under a shared login (`CLAIM_STRATEGY=note`) two agents could both pick one PR — harmless
(idempotent + self-limiting), but run the responder single-runner if the double-effort matters.

**The loop must run under its own tracker identity.** Self-limiting keys on the gh/glab username, so if
the loop authenticates as the *same* account that leaves the review feedback, every comment reads as the
bot's own and `reviews-pending` is permanently empty (also: the issue's assignee must be the loop's
identity, or it never enters `reviews-pending` at all). Run the loop as a distinct identity and review
as yourself — GitHub: a bot or second login; GitLab: a project/group access token (or a second user's
PAT) exported as `GITLAB_TOKEN` from `plans/loop.config.sh` (glab honors it over `~/.config/glab-cli`,
so it binds to the loop, not your interactive shell). Keep the token out of git via an untracked
`plans/loop.secrets.sh` sourced with an `if [[ -f … ]]` guard (a missing file stays a clean no-op).

Set `REVIEW_RESPONSE=off` to keep the pure human-only gate.
