<!--
  loop-runbook.md — the CANONICAL loop-kit runbook SKELETON: a backend/project-neutral state machine,
  symlinked into every onboarded repo. Per-repo judgment (build constraints, review lenses, merge
  policy) lives in the repo's own CLAUDE.md, which every fresh session reads anyway. How it's wired,
  the env the driver exports into each session, and how to run a step interactively: see SKILL.md,
  REFERENCE.md, and the loop-drive.sh header.
-->
# Build Loop — context-bounded, multi-runner, MR-only, tracker-driven

A **context-bounded AFK build loop** that one or more people run **simultaneously** on separate
machines. Everyone runs the *same* driver; they never collide because **each tracker issue is the
lock**, and **context never fills up** because each iteration is a *fresh headless session* — a thin
orchestrator that claims one ready issue, delegates the build to a *fresh `/implement` sub-agent*,
opens an MR that `Closes #N`, and stops. **The human is always the merge gate** — the loop never merges.

State and dependencies live **entirely on the tracker** (issues, labels, the run-log) — this runbook
reads nothing local for state.

> **The queue:** OPEN issues labeled **`$READY_LABEL`** (in `plans/loop.config.sh`, matches what
> `/to-tickets` applies) whose every `deps` blocker is closed. **Run-log:** the newest OPEN issue
> labeled **`$RUNLOG_LABEL`**, auto-created if none exists — no fixed id in config. **Backend:**
> `TRACKER_BACKEND` (`github` or `gitlab`) in the same config file.

## Per-repo judgment — the repo's own CLAUDE.md
Everything that is *project judgment* (build constraints, review lenses, merge hotspots, CI policy)
lives in the target repo's own CLAUDE.md, which every fresh session — orchestrator and sub-agent —
reads anyway. `/implement` reads it too. This skeleton carries only the backend/project-neutral state
machine; it has **no** per-repo recipe or scope files.

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
the kit's REFERENCE.md. Verbs used below: `sync-list`, `runlog-tail`, `view`, `item-state`, `deps`,
`reconcile-mine`, `branch-merged`, `claim`→`won|lost`, `claim-owner`, `whoami`, `release`, `close`,
`mark-review`, `log`, `open-pr`, `reviews-pending`, `review-read`, `review-reply`, `caps`.

**Precondition (multi-runner):** each runner's tracker CLI is authed as a **distinct user** — the
*assignee* is the lock that tells runners apart. One shared account → run **single-runner**. (Backend
note: on **GitLab** Free / single-assignee instances set `CLAIM_STRATEGY=note` for the note-marker CAS;
on **GitHub** there is no shared-account fallback — use N distinct logins or run single-runner.)

Each session runs **exactly one** orchestrator iteration, then prints a status sentinel:

| sentinel | meaning | driver does |
|---|---|---|
| `LOOP_STATUS=CONTINUE` | did a unit of work; pickable work likely remains | run the next fresh iteration |
| `LOOP_STATUS=COMPLETE` | nothing pickable — queue empty or every remaining issue is gated on an unmerged MR / another runner | post the handoff summary, stop |
| `LOOP_STATUS=BLOCKED` | a human decision/input is needed | stop with a non-zero code |

> **`WAIT` is retired from this skeleton's vocabulary.** In MR-only mode nothing unblocks without the
> human merging, so a starved queue is `COMPLETE` (with a handoff summary), never a polling `WAIT`.
> The driver may still *understand* `WAIT` for compatibility, but the runbook never emits it.

> ⚠️ The driver runs `bypassPermissions`. The loop pushes branches and opens PRs/MRs unattended, but
> **never merges** — the human is always the merge gate. See the safety notes atop the kit's
> `loop-drive.sh`.

---

## Architecture — why context stays flat
**Two tiers. Each iteration is a fresh ORCHESTRATOR session that holds almost nothing; the issue is
built by a FRESH `/implement` sub-agent whose context is discarded when it returns — and the driver
discards the orchestrator session too, after one iteration.**

```
ORCHESTRATOR (one fresh driver-spawned session per iteration — thin, short-lived, STATELESS)
  re-derive state from the tracker (+ read run-log resume trail) → RECONCILE any dangling claim
    → REVIEW-RESPONSE: an in-review MR with human feedback? → RESPONDER sub-agent → reply + STOP
    → else PICK + CLAIM one issue → worktree → IMPLEMENT sub-agent (fresh ctx, runs /implement)
    → ORCHESTRATOR pushes + opens MR (Closes #N) → mark-review → run-log → print sentinel + STOP
```

Two rules make this work:
1. **The orchestrator carries no state in its head — it re-derives everything from the tracker every
   iteration.** Issue open/closed + in-progress label + assignee = machine truth; the **run-log** =
   the human resume trail, read at SYNC (last 1–2 entries) and written at LOG. This is what makes the
   loop fully **resumable** after a crash/restart/summarization.
2. **The brief passed to the sub-agent is minimal** — worktree path, branch, issue id, repo. The
   sub-agent fetches its own acceptance criteria (`track view N`); the orchestrator never reads
   source/diffs/test output. The **push and MR are the orchestrator's job, not the sub-agent's** — so
   the implementation context is gone before the bookkeeping tail runs and there is always room for it.

> Orchestrator hygiene: don't read whole plan files or large diffs yourself — `"$LOOP_KIT_DIR"/track
> view N` for the small stuff, and let the sub-agent do the heavy reading.

---

## Scope — the queue
- **Target:** OPEN issues labeled **`$READY_LABEL`** whose every `deps` blocker is closed.
- **Out of scope:** issues without `$READY_LABEL`. The loop only consumes the queue; authoring the
  backlog (`/to-tickets` or the tracker UI) is a separate, human-gated step.

## The shared lock — how runners don't collide
- **Per-issue lock** = `assignee` + in-progress label. Claim before building; release on abort.
- **Merge hotspots** — the repo's CLAUDE.md names any files that are contention axes and the per-file
  resolution rule. If two in-progress issues touch the same shared file it names, serialize them.
- **Dependencies are on the issue itself** — `"$LOOP_KIT_DIR"/track deps N` resolves native blocking
  links first, else a `## Blocked by` section in the body (what `/to-tickets` writes on tiers without
  native links). N is pickable iff **every** returned id is `closed`.

---

## The orchestrator iteration (what each driver-spawned session does)
1. **SYNC** — `git fetch origin`; fast-forward the base branch (**`$BASE_BRANCH`** — exported into your
   env; it is the repo's default branch, which may be `master`/`trunk`, **not** assumed `main`). Derive
   live state: `"$LOOP_KIT_DIR"/track sync-list "$READY_LABEL"`.
   Then read the **run-log resume trail** — the last 1–2 entries only (orchestrator hygiene):
   `"$LOOP_KIT_DIR"/track runlog-tail 2`. The last entry records how the previous iteration ended
   (`MR'd …` / `BLOCKED`). A trailing **`BLOCKED`** is handled first in RECONCILE (2a).
2. **RECONCILE (self-heal dangling state — BEFORE PICK).**
   **(a) Recover a prior `BLOCKED` first.** If SYNC's run-log tail shows the previous iteration ended
   `LOOP_STATUS=BLOCKED` on issue #N, do **not** silently re-attempt it. That entry ends with an
   explicit **`Unblock-when: <condition>`** — re-test *that exact condition* against current state,
   checking the **specific** thing it names (e.g. "an MR for the branch exists"), **NOT** a non-gating
   check:
   - **Still blocked** → re-emit `LOOP_STATUS=BLOCKED`, append a one-line `still blocked on #N` note, STOP.
   - **Cleared** → #N is still your claim; fall through to (b) and resume it (the run-log says how far
     it got — branch built ⇒ resume at MR, not a fresh IMPLEMENT).
   **(b) Finish a dangling claim.** A prior iteration can be interrupted between opening the MR and
   MARK/LOG — or a human can merge the branch while the issue sits stranded (a degraded MR create via
   the `--fill` fallback carries no `Closes #N`, so the merge didn't auto-close it) — leaving an issue
   that is **yours + in-progress but actually done**. List your dangling claims —
   `"$LOOP_KIT_DIR"/track reconcile-mine "$READY_LABEL"`; for each:
   - **Shared-login gate (only when `CLAIM_STRATEGY=note`).** `reconcile-mine` keys on the *login*, so
     under a login shared by several agents it also returns a **sibling's claim** — adopting it would
     double-build. Before touching the item, run `"$LOOP_KIT_DIR"/track claim-owner N` and compare to
     `"$LOOP_KIT_DIR"/track whoami`: **proceed only if** the owner **equals your `whoami`** (your own
     dangling claim — reup with the same `RUNNER_ID` to land here) **or is empty** (no live claim: an
     assignee-mode claim that left no marker, or all released = yours to finish). If it is a **different
     non-empty** runner, that sibling owns it → **SKIP this item**, do not build. (In `assignee` mode
     this gate is a no-op: skip to the branch check.)
   Then check whether its branch `$BRANCH_PREFIX/N-<slug>` is already landed —
   `"$LOOP_KIT_DIR"/track branch-merged "$BRANCH_PREFIX/N-<slug>"`:
   - **Already merged** → just finish the stranded tail: if the issue is still open (degraded MR with no
     `Closes #N`) `"$LOOP_KIT_DIR"/track close N`, then **LOG** (10, mark `reconciled after interrupt`).
     That **is** this iteration's work → remove the worktree, emit `CONTINUE`; **don't also PICK**.
   - **Not merged, branch exists** → resume the tail: **do NOT re-CLAIM** (you already own it) — push +
     `open-pr` (step 8), or, if the worktree is incomplete, re-run the IMPLEMENT sub-agent (step 7) first.
3. **REVIEW-RESPONSE (drain human feedback BEFORE opening new work).**
   **Run this only when** the backend's `"$LOOP_KIT_DIR"/track caps` reports
   `can_respond_to_reviews=true` **and** `REVIEW_RESPONSE` is not `off` (default on; set
   `REVIEW_RESPONSE=off` to keep the pure human-only gate). Otherwise **skip straight to PICK**.
   Draining feedback on an already-open MR takes **priority over PICK** — it moves work toward merge and
   bounds the in-review pile — so it runs first. List your in-review items whose MR has **actionable**
   feedback: `"$LOOP_KIT_DIR"/track reviews-pending "$READY_LABEL"` → `[{number,title,pr}]` (an MR is
   actionable iff it has an unresolved review thread whose **last comment is a human's**, or an MR
   comment/review newer than your last push — **self-limiting**: once you reply, that thread/MR drops
   out, so there is no re-processing loop). **Empty list → fall through to PICK.** Otherwise take the
   **first** issue `#N` — it is already yours (assignee unchanged, still `in-review`): **do NOT re-claim
   and do NOT change its labels** (it stays OPEN + `in-review` throughout, so PICK still skips it and
   dependents stay gated).
   - Spawn a fresh **review-responder sub-agent** for `#N` (brief below). It reads the feedback, fixes
     the branch, pushes, and replies inline to every item.
   - **LOG** (10): `"$LOOP_KIT_DIR"/track log "iter K — responded #N (<sha>) · <m> item(s) answered ·
     awaiting re-review · remaining: …"`.
   - This **is** this iteration's work → emit `CONTINUE` and **STOP**; **do not also PICK**.
   If the responder is interrupted mid-flight, no state is corrupted: items it already answered have your
   reply as their last comment, so they drop out of `reviews-pending` and the next run addresses only
   what's left. (Multi-runner note: `reviews-pending` keys on the **assignee**, so each runner drains its
   own MRs. Under a SHARED login — `CLAIM_STRATEGY=note` — two agents could both pick one MR; the work is
   idempotent + self-limiting, but run the responder single-runner if that double-effort matters.)
4. **PICK** — choose one OPEN issue that is **all of**: labeled `$READY_LABEL` · unassigned · not
   in-progress · not in-review · **unblocked** — every id from `"$LOOP_KIT_DIR"/track deps N` is `closed`
   (test each with `"$LOOP_KIT_DIR"/track item-state <depId>` = `closed`; empty `deps` output = no
   blockers). `deps` resolves native links first, else a `## Blocked by` body section. **Skip** any whose
   merge hotspot (per the repo's CLAUDE.md) overlaps an issue currently in-progress you don't own.
   Among equals **don't deterministically pick what another runner would** — the tie-break in CLAIM
   resolves rare races. **Nothing pickable → see "Stop conditions".**
5. **CLAIM (atomic)** — `"$LOOP_KIT_DIR"/track claim N` performs the add-assignee + in-progress,
   re-read, and arbitration, printing **`won`** or **`lost`**. On `lost` the verb has already released
   your claim → back to PICK. (Manual release on abort: `"$LOOP_KIT_DIR"/track release N`.)
6. **WORKTREE** — create the branch `$BRANCH_PREFIX/N-<slug>` as a **worktree off the up-to-date base
   branch** (`$BASE_BRANCH`). One worktree per issue; it is removed at FINISH.
7. **IMPLEMENT** — spawn **one fresh sub-agent** with the minimal brief below. It runs the `/implement`
   skill for #N inside the worktree, commits to the branch, and returns
   `{issue, branch, headSha, ci, summary, blockers}`. **Do not** read its work yourself. `/implement`
   itself is unchanged: it TDDs at seams, typechecks, runs the suite, runs `/code-review`, and commits
   to the current branch. **It does not push and it does not open the MR** — that is the orchestrator's
   job (step 8), so the sub-agent's context is discarded before the tail runs.
   - If the sub-agent returns `ci:"red"` or a non-empty `blockers`, do **not** open an MR: `release N`,
     **LOG** a `BLOCKED` line ending in `Unblock-when: <re-checkable condition>`, emit `BLOCKED`, STOP.
8. **MR** — the **orchestrator** (not the sub-agent) pushes the branch and opens the MR/PR:
   `url=$("$LOOP_KIT_DIR"/track open-pr "$BRANCH_PREFIX/N-<slug>" N)`. `open-pr` pushes and creates the
   MR whose description carries **`Closes #N`** so the human's merge auto-closes the issue and re-arms
   dependents; it prints the URL. **Do not merge.** If it exits non-zero / prints no URL → `release N`,
   `log "BLOCKED #N — open-pr failed. Unblock-when: an MR for the branch exists"`, emit `BLOCKED`, STOP.
9. **MARK** — `"$LOOP_KIT_DIR"/track mark-review N "$url"`. **Leave the issue OPEN** — it is NOT landed,
   so the dep-gate keeps dependents gated until a human merges (auto-close does the rest). PICK skips it.
10. **LOG** — append one run-log entry: `"$LOOP_KIT_DIR"/track log "iter K — MR'd #N (<url>) · awaiting
    merge · remaining: …"`. **A `BLOCKED` entry MUST end with `Unblock-when: <concrete, re-checkable
    condition>`** naming the **specific** failing check — that line is exactly what the next session
    re-tests in RECONCILE (2a).
11. **FINISH** — remove the per-issue worktree, then **print the `LOOP_STATUS` sentinel and STOP**.
    Stopping after one iteration is what keeps context flat; the driver fires the next fresh session —
    do **not** loop back to SYNC or schedule a wakeup.

### IMPLEMENT sub-agent brief (minimal — orchestrator passes only this)
> In worktree `<path>` (branch `<branch>`), run the `/implement` skill for issue **#N** of `<REPO>`.
> Get the goal and acceptance criteria with `"$LOOP_KIT_DIR"/track view N`, and read the repo's own
> CLAUDE.md for build constraints, review lenses, and merge-hotspot rules. TDD at seams, typecheck and
> run tests to green, run `/code-review`, and **commit to the current branch**. Do **NOT** push and do
> **NOT** open an MR — the orchestrator does that. **Return ONLY**
> `{issue, branch, headSha, ci:"green"|"red", summary, blockers:[]}`.

### Review-responder sub-agent brief (only when `reviews-pending` flags #N)
> A human left review feedback on the MR for issue **#N** of `<REPO>`. Address it to *merge-ready, still
> NOT merged*. Read the repo's CLAUDE.md for the build constraints, review lenses, and merge-hotspot
> rules — trust it and minimal-change discipline; there are no loop recipe/scope files. Steps:
> (1) `"$LOOP_KIT_DIR"/track review-read N` → `{pr, branch, base, url, items[]}`. Each **item** is either
> a `kind:"thread"` (an inline review thread: `path`, `line`, the `conversation`, and a `reply_to` token)
> or a `kind:"comment"` (MR-conversation feedback, `reply_to:"conversation"`). (2) Check out `branch` and
> rebase on `origin/<base>` if it is behind; resolve conflicts per the repo's CLAUDE.md merge rules.
> (3) For **each item**: make the **minimal** change it asks for — add a **red-without-fix regression
> test** when it is a bug fix — **or**, if it is a question or you disagree, prepare a short rationale
> instead. (4) Build + typecheck + test until CI is green; **push the branch**. (5) Reply to **every**
> item you read — `"$LOOP_KIT_DIR"/track review-reply N <reply_to> "<what you changed + the new sha, or
> your rationale>"` — using each item's own `reply_to`. Replying is what clears an item from
> `reviews-pending`, so a missed reply will be re-surfaced next iteration. **Do NOT** resolve threads,
> re-request review, or merge — the human stays the gate. **Return ONLY**
> `{issue, branch, pushedSha, answered:[<reply_to>…], ci:"green"|"red", note}`.

---

## Run-log = the newest OPEN issue labeled `$RUNLOG_LABEL`
Append every iteration entry via `"$LOOP_KIT_DIR"/track log "…"`, and **read its last 1–2 entries at
SYNC** via `"$LOOP_KIT_DIR"/track runlog-tail 2` to recover the resume trail — most importantly a
trailing `BLOCKED` entry's `Unblock-when:` condition, which RECONCILE (2a) re-tests before touching the
issue. The verbs resolve the log **by label** (auto-creating it on first use — no fixed id in config).
Per-item state lives on the individual issues; the run-log is the chronological log only.

## Stop conditions — don't confuse "starved" with "done"; in MR-only mode both are `COMPLETE`
- **Work done this iteration → `CONTINUE`.** A build MR'd, a reconcile finished, or review feedback
  answered. The driver fires the next fresh iteration.
- **Nothing pickable → post a handoff summary, emit `COMPLETE`.** Either the `$READY_LABEL` queue is
  empty, or every remaining issue is blocked — gated on an un-merged MR, or claimed by another runner.
  Post a **handoff summary** to the run-log naming the open MRs and what they block —
  `"$LOOP_KIT_DIR"/track log "done for now: 3 MRs open (#12 #14 #15), 2 tickets blocked on them (#16
  #17)"` — then emit `COMPLETE`. Rationale: in MR-only mode nothing unblocks without the human merging,
  so polling buys nothing while AFK. **This is why `WAIT` is gone** — a starved queue is not a
  sleep-and-retry, it is a handoff back to the human.
- **Human decision needed → `BLOCKED` (re-checkable).** Record it via `"$LOOP_KIT_DIR"/track log "…
  Unblock-when: <concrete condition>"`, **leave the claim intact** (resumable — the next session's
  RECONCILE 2a re-tests the condition), emit `BLOCKED`.

> The dep gate keys on **closed**, and an issue is closed **only after its MR merges to the base branch**
> (`Closes #N`). So "dep closed" guarantees the dep's code is actually on the base before the dependent
> branches from it. The invariant holds while an MR is open (the issue stays in-review, not closed).

## Safety rails
- Never modify frozen/shared shapes out-of-band. Never force-push the base branch. **Never merge** —
  the human is the merge gate.
- The orchestrator opens the MR; `/implement` runs `/code-review` inside the build. Human MR review is
  the final gate on top of that.
- **One in-progress issue per runner at a time** (claim → MR → mark-review before the next).
- The orchestrator stays thin: delegate the whole build to the fresh `/implement` sub-agent, and open
  the MR + write the bookkeeping tail yourself.
- If a claim race or merge conflict won't resolve cleanly, **release the claim and log it** — don't guess.

---

## Filling the queue (human-gated, not part of the loop)
Authoring the backlog is a separate, human-gated step the loop never performs. File issues directly
(tracker UI or an authoring skill such as `/to-tickets`); each issue needs a falsifiable Acceptance
Criteria checklist, the `$READY_LABEL` label, and its blocking edges (native links or a `## Blocked by`
body section). The loop only consumes the queue.
