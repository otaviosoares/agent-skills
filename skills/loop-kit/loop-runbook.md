<!--
  loop-runbook.md — the CANONICAL loop-kit runbook SKELETON: a backend/project-neutral state machine,
  symlinked into every onboarded repo. Per-repo judgment (build constraints, review lenses, merge
  policy) lives in the repo's own CLAUDE.md, which every fresh session reads anyway. How it's wired,
  the env the driver exports into each session, and how to run a step interactively: see SKILL.md,
  REFERENCE.md, and the loop-drive.sh header.
-->
# Build Loop — context-bounded, multi-runner, tracker-driven

A **context-bounded build loop** that one or more people run **simultaneously** on separate machines.
Everyone runs the *same* driver; they never collide because **each tracker issue is the lock**, and
**context never fills up** because each iteration is a *fresh headless session* — a thin orchestrator
that delegates each issue to *fresh sub-agents*.

State and dependencies live **entirely on the tracker** (issues, labels, the run-log) — this runbook
reads nothing local for state.

> **Current scope: `$WAVE`** (the scope label in `plans/loop.config.sh`). Run-log handle: `RUNLOG`
> in `plans/loop.config.sh`. Backend: also there.

## Per-repo judgment — the repo's own CLAUDE.md
Everything that is *project judgment* (build constraints, review lenses, merge hotspots, CI policy)
lives in the target repo's own CLAUDE.md, which every fresh session — orchestrator and sub-agent —
reads anyway. This skeleton carries only the backend/project-neutral state machine.

## Run it (every runner runs this — self-paced, context-bounded)
```
./plans/run-loop.sh                                       # defaults to this skeleton
REVIEW_RESPONSE=off ./plans/run-loop.sh                   # never auto-address review feedback (pure human gate)
TRACKER_BACKEND=gitlab ./plans/run-loop.sh               # different tracker backend
```
`run-loop.sh` locates the installed loop-kit skill, points RUNBOOK at this skeleton, and spawns a
**fresh headless `claude -p` per iteration** (empty context; all state is on the tracker, so each
session re-derives it). No per-loop script.

**Tracker interface (backend-agnostic).** This runbook NEVER calls `gh`/`glab` directly — it calls
verbs through `"${LOOP_KIT_DIR:?run via ./plans/run-loop.sh, or export LOOP_KIT_DIR}"/track <verb>`,
and `TRACKER_BACKEND` (in `plans/loop.config.sh`) picks the adapter. Verb list + lock contract:
the kit's REFERENCE.md. Verbs used below: `sync-list`, `runlog-tail`, `view`, `item-state`,
`reconcile-mine`, `branch-merged`, `claim`→`won|lost`, `claim-owner`, `whoami`, `release`, `close`,
`mark-review`, `log`, `open-pr`, `reviews-pending`, `review-read`, `review-reply`.

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

> ⚠️ The driver runs `bypassPermissions`. The loop pushes branches and opens PRs/MRs unattended, but
> **never merges** — the human is always the merge gate. See the safety notes atop the kit's
> `loop-drive.sh`.

---

## Architecture — why context stays flat
**Two tiers. Each iteration is a fresh ORCHESTRATOR session that holds almost nothing; each issue is
built by a FRESH sub-agent whose context is discarded when it returns — and the driver discards the
orchestrator session too, after one iteration.**

```
ORCHESTRATOR (one fresh driver-spawned session per iteration — thin, short-lived, STATELESS)
  re-derive state from the tracker (+ read run-log resume trail) → RECONCILE any dangling claim
    → REVIEW-RESPONSE: an in-review PR with human feedback? → RESPONDER sub-agent → reply + STOP
    → else PICK + CLAIM one issue → BUILDER sub-agent (fresh ctx) → REVIEWER sub-agent (fresh, independent)
    → if P0/P1: FIXER sub-agent → re-review → LAND (open PR) → mark-review → run-log → print sentinel + STOP
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
- **Target:** OPEN issues carrying the `$WAVE` scope label whose dependencies are all closed.
- **Out of scope:** issues outside the `$WAVE` scope label. Never auto-advance the scope.

## The shared lock — how runners don't collide
- **Per-issue lock** = `assignee` + in-progress label. Claim before building; release on close.
- **Merge hotspots** — the repo's CLAUDE.md names any files that are contention axes and the per-file
  resolution rule. If two in-progress issues touch the same shared file it names, serialize them.
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
   base branch"), **NOT** a non-gating check:
   - **Still blocked** → re-emit `LOOP_STATUS=BLOCKED`, append a one-line `still blocked on #N` note, STOP.
   - **Cleared** → #N is still your claim; fall through to (b) and resume it (the run-log says how far
     it got — branch built ⇒ resume at LAND, not a fresh BUILD).
   **(b) Finish a dangling claim.** A prior iteration can be interrupted between opening the PR and
   MARK/LOG — or a human can merge the branch while the issue sits stranded (a degraded PR create
   carries no `Closes #N`, so the merge didn't auto-close it) — leaving an issue that is **yours +
   in-progress but actually done**. List your
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
   - **Already merged** → just finish the stranded tail: `"$LOOP_KIT_DIR"/track close N` + **LOG**
     (8, mark `reconciled after interrupt`). That **is** this iteration's work → stop, emit
     `CONTINUE`; **don't also PICK**.
   - **Not merged** → resume at **BUILD/REVIEW/LAND** (do **not** re-CLAIM — you already own it).
1c. **REVIEW-RESPONSE (drain human feedback BEFORE opening new work).**
   **Run this only when** the backend's `"$LOOP_KIT_DIR"/track caps` reports
   `can_respond_to_reviews=true` **and** `REVIEW_RESPONSE` is not `off` (default on; set
   `REVIEW_RESPONSE=off` to keep the pure human-only gate). Otherwise **skip straight to PICK**.
   Draining feedback on an already-open PR takes **priority over PICK** — it moves work toward merge and
   bounds the in-review pile — so it runs first. List your in-review items in scope whose PR has
   **actionable** feedback: `"$LOOP_KIT_DIR"/track reviews-pending "$WAVE"` → `[{number,title,pr}]`
   (a PR is actionable iff it has an unresolved review thread whose **last comment is a human's**, or a
   PR comment/review newer than your last push — **self-limiting**: once you reply, that thread/PR drops
   out, so there is no re-processing loop). **Empty list → fall through to PICK.** Otherwise take the
   **first** issue `#N` — it is already yours (assignee unchanged, still `in-review`): **do NOT re-claim
   and do NOT change its labels** (it stays OPEN + `in-review` throughout, so PICK still skips it and
   dependents still WAIT).
   - Spawn a fresh **review-responder sub-agent** for `#N` (brief below). It reads the feedback, fixes
     the branch, pushes, and replies inline to every item.
   - **LOG** (8): `"$LOOP_KIT_DIR"/track log "iter K — responded #N (<sha>) · <m> item(s) answered ·
     awaiting re-review · remaining: …"`.
   - This **is** this iteration's work → emit `CONTINUE` and **STOP**; **do not also PICK**.
   If the responder is interrupted mid-flight, no state is corrupted: items it already answered have your
   reply as their last comment, so they drop out of `reviews-pending` and the next run addresses only
   what's left. (Multi-runner note: `reviews-pending` keys on the **assignee**, so each runner drains its
   own PRs. Under a SHARED login — `CLAIM_STRATEGY=note` — two agents could both pick one PR; the work is
   idempotent + self-limiting, but run the responder single-runner if that double-effort matters.)
2. **PICK** — choose one OPEN in-scope issue that is **all of**: unassigned · not in-progress · not
   in-review · not gated · every dep in its **`Dependencies` section closed** (`track view N` for the
   body; test each with `"$LOOP_KIT_DIR"/track item-state <depId>` = `closed`). **Skip** any whose
   merge hotspot (per the repo's CLAUDE.md) overlaps an issue currently in-progress you don't own.
   Among equals **don't deterministically pick what another runner would** — the tie-break
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
   resolve conflicts per the repo's CLAUDE.md merge rules (conflicts won't resolve cleanly? release +
   log — don't guess). Once **CI is green**:
   `url=$("$LOOP_KIT_DIR"/track open-pr "$BRANCH_PREFIX/N-<slug>" N)` opens a
   PR/MR and prints its URL; **do not merge**. If it exits non-zero / prints no URL → `release N`,
   `log "BLOCKED #N — open-pr failed. Unblock-when: a PR for the branch exists"`, emit `BLOCKED`.
7. **HANDOFF** — `"$LOOP_KIT_DIR"/track mark-review N "$url"`. **Leave the issue OPEN** — it is
   NOT landed, so the dep-gate keeps dependents gated until a human merges + closes. PICK skips it.
8. **LOG** — append one run-log entry: `"$LOOP_KIT_DIR"/track log "iter K — PR'd #N (<url>) · review
   CLEAN | Pn-fixed · awaiting human merge · remaining: …"`. **A
   `BLOCKED` entry MUST end with `Unblock-when: <concrete, re-checkable condition>`** naming the
   **specific** failing check — that line is exactly what the next session re-tests in RECONCILE (1b-a).
9. **FINISH** — clean up the per-iteration worktree, then **print the `LOOP_STATUS` sentinel and STOP**.
   Stopping after one iteration is what keeps context flat; the driver fires the next fresh session —
   do **not** loop back to SYNC or schedule a wakeup.

### Builder sub-agent brief (minimal — orchestrator passes only this)
> Build issue **#N** of `<REPO>` to *merge-ready, not merged*. Read this runbook (`$RUNBOOK`) and the
> repo's CLAUDE.md for the rules. Steps: (1) `"$LOOP_KIT_DIR"/track view N` → goal/deps.
> (2) Read acceptance criteria from the plan file the issue references, else from the issue body's own
> Acceptance Criteria checklist (the issue body IS the DoR for a directly-filed/ad-hoc issue); post them
> as a checklist comment on #N (DoR).
> **Apply the repo CLAUDE.md's build constraints** (frozen packages to
> consume-only, design specs binding on UI slices, test requirements, security invariants). (3) Create
> a worktree/branch `$BRANCH_PREFIX/N-<slug>` off the base branch.
> (4) Implement the slice per the repo's merge-hotspot rules (new shared-file shapes go in this
> issue's own file; don't edit frozen shapes). (5) Build + typecheck + test until green; push the branch.
> **Return ONLY** `{issue, branch, headSha, ci:"green"|"red", summary, blockers:[]}`. Do **not** merge.

### Reviewer sub-agent brief
> Adversarially review branch `<branch>` for issue **#N** — you did **not** write this code. Apply
> the review lenses the repo's CLAUDE.md names (the
> domain threat model). Each finding: severity `P0|P1|P2`, `file:line`, and a failing-test repro (or,
> for a design finding, the violated rule). **Return ONLY**
> `{verdict:"CLEAN"|"CHANGES", findings:[{sev,file,line,desc,repro}]}`.

### Fixer sub-agent brief (only if P0/P1)
> On `<REPO>` branch `<branch>` (issue #N), fix these findings: `<findings>`. Add a **red-without-fix
> regression test** per finding; keep changes minimal; re-run CI green.
> **Return ONLY** `{fixedSha, testsAdded:[], note}`.

### Review-responder sub-agent brief (only when `reviews-pending` flags #N)
> A human left review feedback on the PR for issue **#N** of `<REPO>`. Address it to *merge-ready, still
> NOT merged*. Read this runbook (`$RUNBOOK`) + the repo's CLAUDE.md for the rules. Steps:
> (1) `"$LOOP_KIT_DIR"/track review-read N` → `{pr, branch, base, url, items[]}`. Each **item** is either
> a `kind:"thread"` (an inline review thread: `path`, `line`, the `conversation`, and a `reply_to` token)
> or a `kind:"comment"` (PR-conversation feedback, `reply_to:"conversation"`). (2) Check out `branch` and
> rebase on `origin/<base>` if it is behind; resolve conflicts per the repo's CLAUDE.md merge rules.
> (3) For **each item**: make the **minimal** change it asks for — add a **red-without-fix regression
> test** when it is a bug fix — **or**, if it is a question or you disagree, prepare a short rationale
> instead. Apply the repo CLAUDE.md's build constraints and merge-hotspot rules, exactly as a
> builder would (don't touch frozen/shared shapes out-of-band). (4) Build + typecheck + test until CI is
> green; **push the branch**. (5) Reply to **every** item you read —
> `"$LOOP_KIT_DIR"/track review-reply N <reply_to> "<what you changed + the new sha, or your rationale>"`
> — using each item's own `reply_to`. Replying is what clears an item from `reviews-pending`, so a missed
> reply will be re-surfaced next iteration. **Do NOT** resolve threads, re-request review, or merge — the
> human stays the gate. **Return ONLY**
> `{issue, branch, pushedSha, answered:[<reply_to>…], ci:"green"|"red", note}`.

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
> branches from it. The invariant holds while a PR is open (the issue stays in-review, not closed).

## Safety rails
- Never modify frozen/shared shapes out-of-band. Never force-push the base branch.
- Open the PR only after CI is green on a tree **rebased on the current base branch**.
- **One in-progress issue per runner at a time** (claim → land → release before the next).
- The orchestrator stays thin: delegate every build/review/fix to a fresh sub-agent.
- If a claim race or merge conflict won't resolve cleanly, **release the claim and log it** — don't guess.

---

## Filling the queue (human-gated, not part of the loop)
Authoring the backlog is a separate, human-gated step the loop never performs. File issues directly
(tracker UI or an authoring skill such as `/to-tickets`); each issue needs a falsifiable Acceptance
Criteria checklist, the scope label, and its blocking edges. The loop only consumes the queue.
