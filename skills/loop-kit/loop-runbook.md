<!--
  loop-runbook.md — the CANONICAL loop-kit runbook SKELETON. This file lives IN THE SKILL and is
  symlinked into every onboarded repo (like track / adapters / loop-drive.sh), so a skeleton change
  propagates to every repo automatically — no per-repo copy to go stale. `run-loop.sh` defaults
  RUNBOOK to this file.

  It is backend-neutral and project-neutral. The per-repo JUDGMENT (contention recipe, land/lockfile
  recipe, CI-truth carve-out, review lenses, build constraints) is NOT here — it lives in the REPO's
  `plans/loop.recipes.md`, which the driver exports as $LOOP_RECIPES. The PER-WAVE scope (the wave's
  target/keystones) lives in the REPO's `plans/loop.scope.md`, exported as $LOOP_SCOPE.
  Wherever a step needs that judgment, the skeleton carries a **RECIPE →** marker naming the labeled
  section to apply verbatim. The kit NEVER auto-fills those sections (fail loud — a wrong value
  corrupts shared code or bypasses a supply-chain gate while the loop runs UNATTENDED).

  Environment the driver exports into each session (loop-drive.sh):
    LOOP_KIT_DIR    — this kit dir (where track + adapters/ live). Verb calls use "$LOOP_KIT_DIR"/track.
    TRACKER_CONFIG  — the repo's plans/loop.config.sh (track sources it for REPO/RUNLOG/backend/…).
    LOOP_RECIPES    — the repo's plans/loop.recipes.md (the ~stable per-repo judgment this skeleton applies).
    LOOP_SCOPE      — the repo's plans/loop.scope.md (the per-wave TARGET/KEYSTONES this skeleton applies).
    WAVE            — the scope label (from loop.config.sh). The skeleton's verb calls pass "$WAVE".
    BRANCH_PREFIX   — the branch/worktree prefix (from loop.config.sh). Branches are "$BRANCH_PREFIX/N-<slug>".
  Running interactively without the driver? From the repo root, first:
    export LOOP_KIT_DIR="$(./plans/run-loop.sh --print-kit-dir)" TRACKER_CONFIG="$PWD/plans/loop.config.sh" \
           LOOP_RECIPES="$PWD/plans/loop.recipes.md" LOOP_SCOPE="$PWD/plans/loop.scope.md"; set -a; . "$TRACKER_CONFIG"; set +a
  (the last clause exports WAVE/BRANCH_PREFIX for the verb calls below).
-->
# Build Loop — context-bounded, multi-runner, tracker-driven

A **context-bounded build loop** that one or more people run **simultaneously** on separate machines.
Everyone runs the *same* driver; they never collide because **each tracker issue is the lock**, and
**context never fills up** because each iteration is a *fresh headless session* — a thin orchestrator
that delegates each issue to *fresh sub-agents*.

State and dependencies live **entirely on the tracker** (issues, labels, the run-log) — this runbook
reads nothing local for state.

> **Current scope: `$WAVE`** (the scope label in `plans/loop.config.sh`). Advancing a wave = bump
> `WAVE` in `loop.config.sh` and edit the `## TARGET`/`## KEYSTONES` sections of `plans/loop.scope.md`
> (see end). Run-log handle: `RUNLOG` in `plans/loop.config.sh`. Backend / land mode: also there.

## The per-repo recipes + per-wave scope — read `$LOOP_RECIPES` and `$LOOP_SCOPE` first
Everything that is *project judgment* lives in two repo files, as clearly-labeled `## SECTION`s:
- **`$LOOP_SCOPE`** (`plans/loop.scope.md`) — the **per-wave** scope, rewritten each wave: `## TARGET`,
  `## KEYSTONES`.
- **`$LOOP_RECIPES`** (`plans/loop.recipes.md`) — the **~stable per-repo** judgment: `## CONTENTION`,
  `## BUILD-CONSTRAINTS`, `## REVIEW-LENSES`, `## LAND`, `## CI-TRUTH`.

This skeleton references each by name at the step it governs with a **RECIPE → `## NAME`** marker that
also names the file. The contract, applied at every marker:

> **At a `RECIPE → ## NAME` marker, open the named file (`$LOOP_SCOPE` for `## TARGET`/`## KEYSTONES`;
> `$LOOP_RECIPES` for the other five), find the `## NAME` section, and apply it VERBATIM as the rule for
> that step — do not improvise, summarize, or substitute a sensible default.** If that file is missing,
> or the referenced section is absent or still carries a `<<FILL>>` token, the judgment is unresolved:
> **STOP and emit `LOOP_STATUS=BLOCKED`** (`track log "BLOCKED — <file> § NAME unresolved. Unblock-when:
> the ## NAME section is filled"`, where `<file>` is `$LOOP_SCOPE` or `$LOOP_RECIPES`). Never guess it —
> a wrong scope/contention/land/CI-truth/lens value corrupts shared code or bypasses a supply-chain gate
> while the loop runs unattended.

Sections this skeleton applies: `## TARGET`, `## KEYSTONES` (in `$LOOP_SCOPE`); `## CONTENTION`,
`## BUILD-CONSTRAINTS`, `## REVIEW-LENSES`, `## LAND`, `## CI-TRUTH` (in `$LOOP_RECIPES`).

## Run it (every runner runs this — self-paced, context-bounded)
```
./plans/run-loop.sh                                       # defaults to this skeleton + LAND_MODE from loop.config.sh
LAND_MODE=pr ./plans/run-loop.sh                          # open PRs instead of merging to the base branch
TRACKER_BACKEND=gitlab ./plans/run-loop.sh               # different tracker backend
```
`run-loop.sh` locates the installed loop-kit skill, points RUNBOOK at this skeleton, and spawns a
**fresh headless `claude -p` per iteration** (empty context; all state is on the tracker, so each
session re-derives it). No per-loop script — advancing the scope = `WAVE` + the `## TARGET` scope section.

**Tracker interface (backend-agnostic).** This runbook NEVER calls `gh`/`glab` directly — it calls
verbs through `"${LOOP_KIT_DIR:?run via ./plans/run-loop.sh, or export LOOP_KIT_DIR}"/track <verb>`,
and `TRACKER_BACKEND` (in `plans/loop.config.sh`) picks the adapter. Verb list + lock contract:
the kit's REFERENCE.md. Verbs used below: `sync-list`, `runlog-tail`, `view`, `item-state`,
`reconcile-mine`, `branch-merged`, `claim`→`won|lost`, `claim-owner`, `whoami`, `release`, `close`,
`mark-review`, `log`, `open-pr`, `board-done`.

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
> to the base branch (`$BASE_BRANCH`) unattended** — only run it if you accept an autonomous push to the shared remote. To keep a
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
- **Target:** **RECIPE → `## TARGET`** — apply the `## TARGET` section of `$LOOP_SCOPE` verbatim: the
  in-scope issue set (the `$WAVE` scope label + how the frontier was chosen — which deps must be closed).
- **Keystones (prefer first):** **RECIPE → `## KEYSTONES`** — apply the `## KEYSTONES` section of
  `$LOOP_SCOPE` verbatim (the spine roots to build first, if any).
- **Out of scope:** issues outside the `$WAVE` scope label. Never auto-advance the scope (see end).

## The shared lock — how runners don't collide
- **Per-issue lock** = `assignee` + in-progress label. Claim before building; release on close.
- **Contention axes / merge recipe** — **RECIPE → `## CONTENTION`** — apply the `## CONTENTION` section
  of `$LOOP_RECIPES` verbatim: which files are merge hotspots and the per-file resolution rule. If two
  in-progress issues touch the same shared file the section names, serialize them.
- **Dependencies are on the issue itself** — the `Dependencies` section of the body
  (`"$LOOP_KIT_DIR"/track view N`): foundation, intra-plan (phase numbers), cross-plan.

---

## The orchestrator iteration (what each driver-spawned session does)
1. **SYNC** — `git fetch origin`; fast-forward the base branch (**`$BASE_BRANCH`** — exported into your
   env; it is the repo's default branch, which may be `master`/`trunk`, **not** assumed `main`). Derive
   live state: `"$LOOP_KIT_DIR"/track sync-list "$WAVE"`.
   Then read the **run-log resume trail** — the last 1–2 entries only (orchestrator hygiene):
   `"$LOOP_KIT_DIR"/track runlog-tail 2`. The last entry records how the previous iteration ended
   (`merged …` / `WAIT` / `BLOCKED`). A trailing **`BLOCKED`** is handled first in RECONCILE (1b-a).
1b. **RECONCILE (self-heal dangling state — BEFORE PICK).**
   **(a) Recover a prior `BLOCKED` first.** If SYNC's run-log tail shows the previous iteration ended
   `LOOP_STATUS=BLOCKED` on issue #N, do **not** silently re-attempt it. That entry ends with an
   explicit **`Unblock-when: <condition>`** — re-test *that exact condition* against current state,
   checking the **specific** thing it names (e.g. a specific CI step, or "commit `<sha>` is on the
   base branch"), **NOT** a non-gating check — see **RECIPE → `## CI-TRUTH`** (a structurally-red
   CD/deploy job that must NOT wedge the loop):
   - **Still blocked** → re-emit `LOOP_STATUS=BLOCKED`, append a one-line `still blocked on #N` note, STOP.
   - **Cleared** → #N is still your claim; fall through to (b) and resume it (the run-log says how far
     it got — branch built ⇒ resume at LAND, not a fresh BUILD).
   **(b) Finish a dangling claim.** A prior iteration can be interrupted *after* LAND merged but
   *before* CLOSE/LOG, stranding an issue that is **yours + in-progress but actually done**. List your
   dangling claims — `"$LOOP_KIT_DIR"/track reconcile-mine "$WAVE"`; for each:
   - **Shared-login gate (only when `CLAIM_STRATEGY=note`).** `reconcile-mine` keys on the *login*, so
     under a login shared by several agents it also returns a **sibling's claim** — adopting it would
     double-build. Before touching the item, run `"$LOOP_KIT_DIR"/track claim-owner N` and compare to
     `"$LOOP_KIT_DIR"/track whoami`: **proceed only if** the owner **equals your `whoami`** (your own
     dangling claim — reup with the same `RUNNER_ID` to land here) **or is empty** (no live claim: an
     assignee-mode claim that left no marker, or all released = yours to finish). If it is a **different
     non-empty** runner, that sibling owns it (building, or crashed and will reup its own id) → **SKIP
     this item**, do not build. (In `assignee` mode this gate is a no-op: skip to the branch check.)
   Then check whether its branch `$BRANCH_PREFIX/N-<slug>` is already landed —
   `"$LOOP_KIT_DIR"/track branch-merged "$BRANCH_PREFIX/N-<slug>"`:
   - **Already merged** → just finish the stranded tail: **CLOSE** (7) + **LOG** (8, mark `reconciled
     after interrupt`). That **is** this iteration's work → stop, emit `CONTINUE`; **don't also PICK**.
   - **Not merged** → resume at **BUILD/REVIEW/LAND** (do **not** re-CLAIM — you already own it).
2. **PICK** — choose one OPEN in-scope issue that is **all of**: unassigned · not in-progress · not
   in-review · not gated · every dep in its **`Dependencies` section closed** (`track view N` for the
   body; test each with `"$LOOP_KIT_DIR"/track item-state <depId>` = `closed`). **Skip** any whose
   contention axis (`## CONTENTION`) overlaps an issue currently in-progress you don't own. Prefer
   keystones; among equals **don't deterministically pick what another runner would** — the tie-break
   in step 3 resolves rare races.
3. **CLAIM (atomic)** — `"$LOOP_KIT_DIR"/track claim N` performs the add-assignee + in-progress,
   re-read, and arbitration, printing **`won`** or **`lost`**. On `lost` the verb has already released
   your claim → back to PICK. (Manual release on abort: `"$LOOP_KIT_DIR"/track release N`.)
4. **BUILD** — spawn a **fresh builder sub-agent**, brief below. It returns `{issue, branch, headSha,
   ci, …, summary, blockers}`. **Do not** read its work yourself.
5. **REVIEW** — spawn a **fresh, independent reviewer sub-agent** (it did NOT write the code), brief
   below → `{verdict, findings[]}`. If `findings` has **P0/P1** → spawn a **fresh fixer sub-agent**
   (each finding needs a red-without-fix regression test) → re-run REVIEW until `CLEAN`.
6. **LAND** — in the worktree: rebase on the latest base branch (`git rebase "origin/$BASE_BRANCH"`);
   resolve conflicts per the contention recipe (`## CONTENTION`) above. **RECIPE → `## LAND`** — apply the `## LAND` section of
   `$LOOP_RECIPES` verbatim: the lockfile/dependency reconcile + any supply-chain cooldown, including
   the exact install command CI enforces (so a runner never merges a lockfile that fails it). Do not
   improvise a lockfile resolution. Once **CI is green**, the terminal action depends on **`LAND_MODE`**:
   - **`merge` (default)** — **merge to the base branch**. (Conflicts won't resolve cleanly? release +
     log — don't guess.) → CLOSE (7m).
   - **`pr`** — `url=$("$LOOP_KIT_DIR"/track open-pr "$BRANCH_PREFIX/N-<slug>" N)` opens a
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
> Build issue **#N** of `<REPO>` to *merge-ready, not merged*. Read this runbook (`$RUNBOOK`) and the
> repo recipes (`$LOOP_RECIPES`) for the rules. Steps: (1) `"$LOOP_KIT_DIR"/track view N` → goal/deps.
> (2) Read acceptance criteria from the plan file the issue references, else from the issue body's own
> Acceptance Criteria checklist (the issue body IS the DoR for a directly-filed/ad-hoc issue); post them
> as a checklist comment on #N (DoR).
> **Apply the `## BUILD-CONSTRAINTS` section of `$LOOP_RECIPES` verbatim** (frozen packages to
> consume-only, design specs binding on UI slices, test requirements, security invariants). (3) Create
> a worktree/branch `$BRANCH_PREFIX/N-<slug>` off the base branch.
> (4) Implement the slice per the contention recipe (`## CONTENTION`: new shared-file shapes go in this
> issue's own file; don't edit frozen shapes). (5) Build + typecheck + test until green; push the branch.
> **Return ONLY** `{issue, branch, headSha, ci:"green"|"red", summary, blockers:[]}`. Do **not** merge.

### Reviewer sub-agent brief
> Adversarially review branch `<branch>` for issue **#N** — you did **not** write this code. **Apply
> the `## REVIEW-LENSES` section of `$LOOP_RECIPES` verbatim** as the lenses that matter here (the
> domain threat model). Each finding: severity `P0|P1|P2`, `file:line`, and a failing-test repro (or,
> for a design finding, the violated rule). **Return ONLY**
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
- **Complete → STOP.** `"$LOOP_KIT_DIR"/track sync-list "$WAVE"` returns **zero** open
  → post a final ✅ summary via `track log` and emit `COMPLETE`.
- **Blocked → STOP (re-checkable).** A human decision/input is needed. Record it via `track log "…
  Unblock-when: …"` with a crisp condition, leave the claim intact (resumable), emit `BLOCKED`.

> The dep gate keys on **closed**, and an issue is closed **only after its code merges to the base
> branch**. So "dep closed" guarantees the dep's code is actually on the base before the dependent
> branches from it. In `LAND_MODE=pr` the invariant still holds (the issue stays in-review, not closed).

## Safety rails
- Never modify frozen/shared shapes out-of-band. Never force-push the base branch.
- **CI truth vs structurally-red CD:** **RECIPE → `## CI-TRUTH`** — apply the `## CI-TRUTH` section of
  `$LOOP_RECIPES` verbatim: which checks GATE landability vs which are non-gating (a CD/deploy job red
  for environmental reasons). Merge only on the gating checks; a structurally-red non-gating job must
  NOT wedge the loop.
- Merge only after CI is green on a tree **rebased on the current base branch**.
- **One in-progress issue per runner at a time** (claim → land → release before the next).
- The orchestrator stays thin: delegate every build/review/fix to a fresh sub-agent.
- If a claim race or merge conflict won't resolve cleanly, **release the claim and log it** — don't guess.

---

## Advancing the scope (human-gated, not part of the loop)
Generating the next scope's issues is a separate, human-gated step. Author it with `loop-kit plan`,
then push it with the producer (`materialize-*.mjs`):
1. **Author the backlog** as a source tree — `loop-kit plan` (engine `materialize-plan.mjs`): scaffold
   `plans/.tracker/src/issue/<slug>.md` for the next scope's items, fill each Goal + Acceptance criteria,
   and name every dependency edge in the frontmatter `deps:` list. **The dependency graph + issue bodies
   are hand-authored domain IP — the loop-kit skill does not author them**, it only scaffolds + validates.
2. **Compile + check:** `KIT="$(./plans/run-loop.sh --print-kit-dir)";
   node "$KIT"/materialize-plan.mjs compile --src plans/.tracker/src --out plans/.tracker &&
   node "$KIT"/materialize-plan.mjs check --root plans/.tracker --scope "<next scope>"`. A clean `check`
   is the precondition for the next step (it catches a missing body, an undeclared milestone, a dangling
   dep, or a dependency cycle *before* the live tracker is touched).
3. **Push the delta:** author `{ "scope": "<next scope>", "labelFixes": [ … ] }`, then
   `source plans/loop.config.sh && DRY=1 node "$KIT"/materialize-github.mjs --batch-data <scope>.json
   --root plans/.tracker` to rehearse, then `DRY=0`. (GitLab: `materialize-gitlab.mjs`,
   `TRACKER_BACKEND=gitlab`, set `GITLAB_HOST`. ClickUp: `materialize-clickup.mjs`.)
4. Create the scope's run-log issue, then **advance the scope: bump `WAVE` in `plans/loop.config.sh`
   and edit the `## TARGET` / `## KEYSTONES` sections of `plans/loop.scope.md`** to the new frontier.
   Re-launch the loop.
