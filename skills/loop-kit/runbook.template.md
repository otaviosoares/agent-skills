<!--
  runbook.template.md — the loop-kit runbook template. `init` copies this in as plans/<loop>.md and
  fills the mechanical bits. The 4 `<<FILL: … >>` tokens are the irreducible PER-PROJECT judgment;
  they are NOT inferable from the repo and a wrong value corrupts shared code or bypasses a
  supply-chain gate while the loop runs UNATTENDED. A human MUST resolve every token before a real
  run — fail loud, never guess. Search for `<<FILL` to find them.

  Verb calls use "${LOOP_KIT_DIR:?…}"/track. In CALL-FROM-SKILL mode the driver exports LOOP_KIT_DIR,
  so the `:?` fails loud if the runbook is ever run without it. In SCAFFOLD-A-COPY (vendored) mode,
  `init` may instead emit `./plans/loop-kit/track` directly. Running interactively without the driver?
  First, from the repo root: `export LOOP_KIT_DIR="$(./plans/run-loop.sh --print-kit-dir)" TRACKER_CONFIG="$PWD/plans/loop.config.sh"`
  (the driver normally exports both; `track` also resolves `$PWD/plans/loop.config.sh` when run from the repo root).
-->
# Build Loop — context-bounded, multi-runner, tracker-driven

A **context-bounded build loop** that one or more people run **simultaneously** on separate machines.
Everyone runs the *same* driver; they never collide because **each tracker issue is the lock**, and
**context never fills up** because each iteration is a *fresh headless session* — a thin orchestrator
that delegates each issue to *fresh sub-agents*.

State and dependencies live **entirely on the tracker** (issues, labels, the run-log) — this runbook
reads nothing local for state.

> **Current scope: `<<FILL: scope label, e.g. wave:1 >>`.** Update the *Scope* block when advancing.
> Run-log handle: `RUNLOG` in `plans/loop.config.sh`. Backend / land mode: also `plans/loop.config.sh`.

## Run it (every runner runs this — self-paced, context-bounded)
```
./plans/run-loop.sh plans/<this-runbook>.md
# open PRs instead of merging to main:   LAND_MODE=pr ./plans/run-loop.sh plans/<this-runbook>.md
# different tracker backend:              TRACKER_BACKEND=gitlab ./plans/run-loop.sh plans/<this-runbook>.md
```
`run-loop.sh` locates the installed loop-kit skill and spawns a **fresh headless `claude -p` per
iteration** (empty context; all state is on the tracker, so each session re-derives it). No per-loop
script — advancing the scope = edit the *Scope* block below.

**Tracker interface (backend-agnostic).** This runbook NEVER calls `gh`/`glab` directly — it calls
verbs through `"${LOOP_KIT_DIR:?run via ./plans/run-loop.sh, or export LOOP_KIT_DIR}"/track <verb>`,
and `TRACKER_BACKEND` (in `plans/loop.config.sh`) picks the adapter. Verb list + lock contract:
the kit's REFERENCE.md. Verbs used below: `sync-list`, `runlog-tail`, `view`, `item-state`,
`reconcile-mine`, `branch-merged`, `claim`→`won|lost`, `release`, `close`, `mark-review`, `log`, `open-pr`, `board-done`.

**Precondition (multi-runner):** each runner's tracker CLI is authed as a **distinct user** — the
*assignee* is the lock that tells runners apart. One shared account → run **single-runner**. (Backend
note: on **GitLab** Free / single-assignee instances set `CLAIM_STRATEGY=note` for the note-marker CAS;
on **GitHub** there is no shared-account fallback — use N distinct logins or run single-runner.)

Each session runs **exactly one** orchestrator iteration, then prints a status sentinel:

| sentinel | meaning | driver does |
|---|---|---|
| `LOOP_STATUS=CONTINUE` | did a unit of work; pickable work likely remains | run the next fresh iteration |
| `LOOP_STATUS=WAIT` | open issues remain but none pickable now (other runner / open dep) | sleep, re-SYNC |
| `LOOP_STATUS=COMPLETE` | zero open in-scope issues | post the ✅ summary to the run-log, stop |
| `LOOP_STATUS=BLOCKED` | a human decision/input is needed | stop with a non-zero code |

> ⚠️ The driver runs `bypassPermissions`. In the default **`LAND_MODE=merge`** the LAND step **merges
> to `main` unattended** — only run it if you accept an autonomous push to the shared remote. To keep a
> human gate, set **`LAND_MODE=pr`**: the loop opens a PR/MR and stops short of merging. See the safety
> notes atop the kit's `loop-drive.sh`.

---

## Architecture — why context stays flat
**Two tiers. Each iteration is a fresh ORCHESTRATOR session that holds almost nothing; each issue is
built by a FRESH sub-agent whose context is discarded when it returns — and the driver discards the
orchestrator session too, after one iteration.**

```
ORCHESTRATOR (one fresh driver-spawned session per iteration — thin, short-lived, STATELESS)
  re-derive state from the tracker (+ read run-log resume trail) → RECONCILE any dangling claim
    → PICK + CLAIM one issue → BUILDER sub-agent (fresh ctx) → REVIEWER sub-agent (fresh, independent)
    → if P0/P1: FIXER sub-agent → re-review → LAND → CLOSE/mark-review → run-log → print sentinel + STOP
```

Two rules make this work:
1. **The orchestrator carries no state in its head — it re-derives everything from the tracker every
   iteration.** Issue open/closed + in-progress label + assignee = machine truth; the **run-log** =
   the human resume trail, read at SYNC (last 1–2 entries) and written at LOG. This is what makes the
   loop fully **resumable** after a crash/restart/summarization.
2. **The brief passed to a sub-agent is minimal** — `{issue id, repo, this runbook path}`. The
   sub-agent fetches its own acceptance criteria; the orchestrator never reads source/diffs/test output.

> Orchestrator hygiene: don't read whole plan files or large diffs yourself — `"$LOOP_KIT_DIR"/track
> view N` for the small stuff, and let the sub-agents do the heavy reading.

---

## Scope — the queue
- **Target:** `<<FILL: the in-scope issue set — the scope label + how the frontier was chosen (which
  deps must be closed). e.g. "all OPEN wave:1 issues whose cross-plan deps are closed". >>`
- **Keystones (prefer first):** `<<FILL: the spine roots to build first, if any >>`.
- **Out of scope:** issues outside the scope label. Never auto-advance the scope (see end).

## The shared lock — how runners don't collide
- **Per-issue lock** = `assignee` + in-progress label. Claim before building; release on close.
- **Contention axes / merge recipe** — `<<FILL: which files are merge hotspots and the per-file
  resolution rule. e.g. a shared schema file → each issue writes a NEW schema-<domain>.ts + barrel
  union-merge; generated files (route tree, lockfile) → regenerate at merge; frozen package shapes →
  consume-only. If two in-progress issues touch the same shared file, serialize them. >>`
- **Dependencies are on the issue itself** — the `Dependencies` section of the body
  (`"$LOOP_KIT_DIR"/track view N`): foundation, intra-plan (phase numbers), cross-plan.

---

## The orchestrator iteration (what each driver-spawned session does)
1. **SYNC** — `git fetch origin`; fast-forward the base branch. Derive live state:
   `"$LOOP_KIT_DIR"/track sync-list <<FILL: scope label >>`.
   Then read the **run-log resume trail** — the last 1–2 entries only (orchestrator hygiene):
   `"$LOOP_KIT_DIR"/track runlog-tail 2`. The last entry records how the previous iteration ended
   (`merged …` / `WAIT` / `BLOCKED`). A trailing **`BLOCKED`** is handled first in RECONCILE (1b-a).
1b. **RECONCILE (self-heal dangling state — BEFORE PICK).**
   **(a) Recover a prior `BLOCKED` first.** If SYNC's run-log tail shows the previous iteration ended
   `LOOP_STATUS=BLOCKED` on issue #N, do **not** silently re-attempt it. That entry ends with an
   explicit **`Unblock-when: <condition>`** — re-test *that exact condition* against current state,
   checking the **specific** thing it names (e.g. a specific CI step, or "commit `<sha>` is on the
   base branch"), **NOT** `<<FILL: which checks are NON-gating — a structurally-red CD/deploy job
   (e.g. a missing deploy token) that must NOT wedge the loop. See the CI-truth carve-out below. >>`:
   - **Still blocked** → re-emit `LOOP_STATUS=BLOCKED`, append a one-line `still blocked on #N` note, STOP.
   - **Cleared** → #N is still your claim; fall through to (b) and resume it (the run-log says how far
     it got — branch built ⇒ resume at LAND, not a fresh BUILD).
   **(b) Finish a dangling claim.** A prior iteration can be interrupted *after* LAND merged but
   *before* CLOSE/LOG, stranding an issue that is **yours + in-progress but actually done**. List your
   dangling claims — `"$LOOP_KIT_DIR"/track reconcile-mine <<FILL: scope label >>`; for each, check
   whether its branch `<<FILL: BRANCH_PREFIX >>/N-<slug>` is already landed —
   `"$LOOP_KIT_DIR"/track branch-merged <<FILL: BRANCH_PREFIX >>/N-<slug>`:
   - **Already merged** → just finish the stranded tail: **CLOSE** (7) + **LOG** (8, mark `reconciled
     after interrupt`). That **is** this iteration's work → stop, emit `CONTINUE`; **don't also PICK**.
   - **Not merged** → resume at **BUILD/REVIEW/LAND** (do **not** re-CLAIM — you already own it).
2. **PICK** — choose one OPEN in-scope issue that is **all of**: unassigned · not in-progress · not
   in-review · not gated · every dep in its **`Dependencies` section closed** (`track view N` for the
   body; test each with `"$LOOP_KIT_DIR"/track item-state <depId>` = `closed`). **Skip** any whose
   contention axis (above) overlaps an issue currently in-progress you don't own. Prefer keystones;
   among equals **don't deterministically pick what another runner would** — the tie-break in step 3
   resolves rare races.
3. **CLAIM (atomic)** — `"$LOOP_KIT_DIR"/track claim N` performs the add-assignee + in-progress,
   re-read, and arbitration, printing **`won`** or **`lost`**. On `lost` the verb has already released
   your claim → back to PICK. (Manual release on abort: `"$LOOP_KIT_DIR"/track release N`.)
4. **BUILD** — spawn a **fresh builder sub-agent**, brief below. It returns `{issue, branch, headSha,
   ci, …, summary, blockers}`. **Do not** read its work yourself.
5. **REVIEW** — spawn a **fresh, independent reviewer sub-agent** (it did NOT write the code), brief
   below → `{verdict, findings[]}`. If `findings` has **P0/P1** → spawn a **fresh fixer sub-agent**
   (each finding needs a red-without-fix regression test) → re-run REVIEW until `CLEAN`.
6. **LAND** — in the worktree: rebase on the latest base branch; resolve conflicts per the contention
   recipe above. **LAND recipe:** `<<FILL: the lockfile/dependency reconcile + any supply-chain
   cooldown. e.g. take the base branch's lockfile and run a frozen install; only on a real dep
   add/bump do a deliberate install honoring the committed cooldown — NEVER disable the cooldown.
   Name the exact install command CI enforces, so a runner never merges a lockfile that fails it. >>`
   Once **CI is green**, the terminal action depends on **`LAND_MODE`**:
   - **`merge` (default)** — **merge to the base branch**. (Conflicts won't resolve cleanly? release +
     log — don't guess.) → CLOSE (7m).
   - **`pr`** — `url=$("$LOOP_KIT_DIR"/track open-pr <<FILL: BRANCH_PREFIX >>/N-<slug> N)` opens a
     PR/MR and prints its URL; **do not merge**. If it exits non-zero / prints no URL → `release N`,
     `log "BLOCKED #N — open-pr failed. Unblock-when: a PR for the branch exists"`, emit `BLOCKED`.
     On success → 7p.
7. **CLOSE / HANDOFF** —
   - **(7m) merge mode** — `"$LOOP_KIT_DIR"/track close N`; `"$LOOP_KIT_DIR"/track board-done N`.
   - **(7p) PR mode** — `"$LOOP_KIT_DIR"/track mark-review N "$url"`. **Leave the issue OPEN** — it is
     NOT landed, so the dep-gate keeps dependents in WAIT until a human merges + closes. PICK skips it.
8. **LOG** — append one run-log entry: `"$LOOP_KIT_DIR"/track log "iter K — merged #N (<sha>) · review
   CLEAN | Pn-fixed · remaining: …"` (PR mode: `PR'd #N (<url>) · awaiting human merge · …`). **A
   `BLOCKED` entry MUST end with `Unblock-when: <concrete, re-checkable condition>`** naming the
   **specific** failing check — that line is exactly what the next session re-tests in RECONCILE (1b-a).
9. **FINISH** — clean up the per-iteration worktree, then **print the `LOOP_STATUS` sentinel and STOP**.
   Stopping after one iteration is what keeps context flat; the driver fires the next fresh session —
   do **not** loop back to SYNC or schedule a wakeup.

### Builder sub-agent brief (minimal — orchestrator passes only this)
> Build issue **#N** of `<REPO>` to *merge-ready, not merged*. Read `plans/<this-runbook>.md` for the
> rules. Steps: (1) `"$LOOP_KIT_DIR"/track view N` → goal/deps. (2) Read acceptance criteria from the
> plan file; post them as a checklist comment on #N (DoR). `<<FILL: any build constraints — frozen
> packages to consume-only, design specs binding on UI slices, test requirements, security invariants
> (e.g. auth step-up on sensitive ops). >>` (3) Create a worktree/branch off the base branch.
> (4) Implement the slice per the contention recipe (new shared-file shapes go in this issue's own
> file; don't edit frozen shapes). (5) Build + typecheck + test until green; push the branch.
> **Return ONLY** `{issue, branch, headSha, ci:"green"|"red", summary, blockers:[]}`. Do **not** merge.

### Reviewer sub-agent brief
> Adversarially review branch `<branch>` for issue **#N** — you did **not** write this code. Lenses:
> `<<FILL: the domain threat model — the review lenses that matter here. e.g. cross-tenant isolation ·
> money/contract correctness · auth/RBAC + audit · regression/CI · acceptance-criteria coverage ·
> design fidelity for UI slices. >>` Each finding: severity `P0|P1|P2`, `file:line`, and a failing-test
> repro (or, for a design finding, the violated rule). **Return ONLY**
> `{verdict:"CLEAN"|"CHANGES", findings:[{sev,file,line,desc,repro}]}`.

### Fixer sub-agent brief (only if P0/P1)
> On `<REPO>` branch `<branch>` (issue #N), fix these findings: `<findings>`. Add a **red-without-fix
> regression test** per finding; keep changes minimal; re-run CI green.
> **Return ONLY** `{fixedSha, testsAdded:[], note}`.

---

## Run-log = the tracker's run-log handle (`RUNLOG` in plans/loop.config.sh)
Append every iteration entry via `"$LOOP_KIT_DIR"/track log "…"`, and **read its last 1–2 entries at
SYNC** via `"$LOOP_KIT_DIR"/track runlog-tail 2` to recover the resume trail — most importantly a
trailing `BLOCKED` entry's `Unblock-when:` condition, which RECONCILE (1b-a) re-tests before touching
the issue. Per-item state lives on the individual issues; the run-log is the chronological log only.

## Stop vs wait — don't confuse "starved" with "done"
- **Work available → BUILD**, then emit `CONTINUE`.
- **Starved → WAIT (do NOT stop).** In-scope issues remain but none pickable *right now* (assigned to
  another runner, or gated on an open dep). Emit `WAIT`; the driver sleeps and re-SYNCs.
- **Complete → STOP.** `"$LOOP_KIT_DIR"/track sync-list <<FILL: scope label >>` returns **zero** open
  → post a final ✅ summary via `track log` and emit `COMPLETE`.
- **Blocked → STOP (re-checkable).** A human decision/input is needed. Record it via `track log "…
  Unblock-when: …"` with a crisp condition, leave the claim intact (resumable), emit `BLOCKED`.

> The dep gate keys on **closed**, and an issue is closed **only after its code merges to the base
> branch**. So "dep closed" guarantees the dep's code is actually on the base before the dependent
> branches from it. In `LAND_MODE=pr` the invariant still holds (the issue stays in-review, not closed).

## Safety rails
- Never modify frozen/shared shapes out-of-band. Never force-push the base branch.
- **CI truth vs structurally-red CD:** `<<FILL: which checks GATE landability vs which are non-gating
  (a CD/deploy job red for environmental reasons — e.g. a missing deploy token). Merge only on the
  gating checks; a structurally-red non-gating job must NOT wedge the loop. >>`
- Merge only after CI is green on a tree **rebased on the current base branch**.
- **One in-progress issue per runner at a time** (claim → land → release before the next).
- The orchestrator stays thin: delegate every build/review/fix to a fresh sub-agent.
- If a claim race or merge conflict won't resolve cleanly, **release the claim and log it** — don't guess.

---

## Advancing the scope (human-gated, not part of the loop)
Generating the next scope's issues is a separate, human-gated step (the producer, `materialize-*.mjs`):
1. Compute the frontier (which unopened items now have every dep closed) and stamp them with the next
   scope label via your generator. **The dependency graph + issue bodies are hand-authored domain IP —
   the loop-kit skill does not author them.**
2. Author the scope's backlog data file `{ "scope": "<next scope>", "labelFixes": [ … ] }`, then create
   the delta: `KIT="$(./plans/run-loop.sh --print-kit-dir)"; source plans/loop.config.sh && DRY=1 node
   "$KIT"/materialize-github.mjs --batch-data <scope>.json --root <data-dir>` to rehearse, then `DRY=0`.
   (GitLab: `materialize-gitlab.mjs`, `TRACKER_BACKEND=gitlab`, set `GITLAB_HOST`.)
3. Create the scope's run-log issue, update this runbook's *Scope* block, and re-launch the loop.
