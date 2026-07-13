---
name: loop-kit
description: >-
  Set up and run a context-bounded, multi-runner autonomous build loop driven by an issue
  tracker (GitHub or GitLab). Use when the user wants to stand up an unattended build loop
  on a repo, onboard a repo to loop-kit, generate a loop launcher + tracker config, or run
  or resume the loop. Sub-commands — `init` (onboard a repo, auto-runs first), `config`
  (edit/add a backend), `run` (launch the loop). The runbook is a shared SKELETON
  (loop-runbook.md, in the skill, symlinked + auto-updating); per-repo judgment lives in
  the repo's own CLAUDE.md. The loop spawns a fresh headless `claude -p` per iteration
  (flat context), each tracker issue is the lock so N runners never collide, and a
  backend-agnostic `track` dispatcher seams GitHub and GitLab (a local-files backend is
  planned). The loop never merges — it opens PRs/MRs and the human is always the merge
  gate. Never authors the backlog, never auto-commits.
---

# Loop Kit

Stand up (and run) a **context-bounded autonomous build loop** on a repo. The loop has two
tiers, and the whole point is that **context never fills up**:

- An external **driver** (`loop-drive.sh`) spawns a **fresh headless `claude -p` per iteration** —
  empty context each time. All durable state lives OUTSIDE the agent (tracker issues, labels,
  a run-log), so each fresh session re-derives it. The driver is stateless: it only decides
  *when to fire the next session* and *when to stop*, reading a `LOOP_STATUS` sentinel.
- Each iteration is a thin **orchestrator** that picks ONE tracker issue, claims it, and delegates
  the build to **fresh sub-agents** whose context is thrown away when they return.

**Each tracker issue is the lock**, so two (or N) people can run the same loop on separate machines
without colliding. A backend-agnostic dispatcher `track <verb>` hides whether the tracker is GitHub
(`gh`) or GitLab (`glab`) — the runbook calls verbs, never the underlying CLI directly. (A
`local`-files backend is designed in REFERENCE.md but ships no adapter yet.)

The loop **never merges**: it builds each issue on its own branch, opens a PR/MR whose description
carries `Closes #N`, and stops — the human is always the merge gate.

This skill does two things:
1. **`init`** — onboard a target repo: emit its tracker config + a launcher, and point it at the
   kit's shared runbook **skeleton**.
2. **bundles the runtime** — `loop-drive.sh`, `track`, `adapters/*.sh`, `loop-runbook.md` — that
   the onboarded repo references (symlinked, so updates propagate).

### The runbook = a shared SKELETON (code); repo judgment = the repo's CLAUDE.md
- **[loop-runbook.md](loop-runbook.md)** — the canonical **skeleton**: the backend/project-neutral
  state machine. It lives **in the skill** and is **symlinked** into each onboarded repo (exactly
  like `track`/`adapters/`/`loop-drive.sh`), so a skeleton fix propagates to every repo
  automatically — there is no per-repo copy to go stale. The driver defaults `RUNBOOK` to this
  file, so `./plans/run-loop.sh` (no runbook arg) uses it.
- **Per-repo judgment** (build constraints, review lenses, merge hotspots) lives in the target
  repo's own CLAUDE.md, which every fresh session reads anyway. There is no kit-owned judgment file.
- **PIN the skeleton for reproducibility** the same way you pin `adapters/` — the symlink/checkout
  is the knob. To freeze the skeleton at a known version, vendor the kit into `./plans/loop-kit/`
  (delivery mode "scaffold-a-copy") or install a pinned skill version; then a skeleton change won't
  move under a running loop until you re-vendor/re-pin.

> Read **[REFERENCE.md](REFERENCE.md)** for the verb contract, the lock contract (the 4 guarantees
> every backend must satisfy), the capability matrix, and the config/env resolution.

---

## Commands

The skill takes a sub-command as its argument (e.g. `loop-kit init`, `loop-kit config`). Route on it:

| command | what it does | mutates the tracker? |
|---|---|---|
| **`init`** (default) | Onboard the target repo: probe → confirm a plan → emit `plans/loop.config.sh`, `plans/run-loop.sh`. Points the repo at the kit's shared **skeleton** (`loop-runbook.md`) — no per-repo runbook copy. **Non-destructive** (keeps any file that already exists). | no |
| **`config`** | Re-open the config Q&A on an already-onboarded repo: edit values or add a second tracker backend. Touches only `plans/loop.config.sh`. | no |
| **`run`** | Launch/resume the loop via `./plans/run-loop.sh` (see the `run` section). Surfaces the tunables; does not edit files. | yes (builds, opens PRs) |

**Auto-init guard.** Before honoring `config` or `run`, check the target repo for
`plans/loop.config.sh`. If it's **missing**, the repo isn't onboarded yet — say so and run **`init`
first**, then continue to the requested command. A bare invocation with no argument also means `init`.
(`init` itself is safe to re-run: it's non-destructive and just reports what already exists.)

---

## What this skill does NOT do

The loop runs `bypassPermissions` and pushes branches + opens PRs unattended. So:

- **Never author the backlog.** Issue bodies, acceptance criteria, and dependency edges are
  hand-authored domain judgment (file them via the tracker UI or an authoring skill such as
  `/to-tickets`); the loop only consumes the queue.
- **Never merge.** The loop opens the PR/MR and stops; the human is the merge gate.
- **Never auto-commit.** Emit files into the working tree and STOP. The human reviews and commits.

---

## Two delivery modes

| mode | who holds the runtime | the repo references the kit as | use when |
|---|---|---|---|
| **call-from-skill** (default) | the installed skill (`~/.claude/skills/loop-kit`) | `"$LOOP_KIT_DIR"/track` (the driver injects `LOOP_KIT_DIR`) | every runner has this skill installed (the loop is driven by Claude Code, so they do) |
| **scaffold-a-copy** (vendored) | a real `plans/loop-kit/` copied into the repo | `./plans/loop-kit/track` | a collaborator's repo or CI that can't assume the skill is installed |

The runtime layout is identical in both modes (`track`, `loop-drive.sh`, `adapters/`,
`loop-runbook.md` as siblings), so scaffold-a-copy is literally "copy this dir into
`plans/loop-kit/`". **Vendoring also PINS the skeleton** (and adapters) at that copy's version —
the reproducibility knob.

---

## `init` — onboard a target repo

Run from the target repo. The flow is **probe → confirm → emit**: auto-detect everything you can,
present ONE summary of exactly what will be written (and with which values), and ask the user only
where a value is genuinely ambiguous or unsafe to assume. **Never overwrite an existing file** — for
each target, if it already exists, keep it and report `kept existing <path>` instead of writing.

### Step 0 — probe + plan (silent)
Gather the detectable facts, then assemble a write-plan. Detect the backend, the multi-runner claim
strategy, and sensible defaults; mark anything you had to guess as *needs-confirm*.

### Step 1 — confirm (one summary, ask only on ambiguity)
Show the user a compact summary: detected backend + host, the delivery mode, which of
`loop.config.sh` / `run-loop.sh` are new vs. already present (plus that the repo points at the
shared `loop-runbook.md` skeleton, no per-repo runbook copy). Then ask — via the AskUserQuestion
picker, with our real options — ONLY the questions whose answers you couldn't safely infer. Typical
ambiguous ones: delivery mode (call-from-skill vs scaffold-a-copy), and — when the remote is
unrecognized — the backend itself. If everything was unambiguous, skip straight to emit after the
confirmation summary.

### Step 2 — emit
1. **Probe the repo.** Read the git remote (`git remote get-url origin`) and detect the backend:
   - `github.com` → `TRACKER_BACKEND=github`.
   - a GitLab host (`gitlab.com` or self-hosted) → `TRACKER_BACKEND=gitlab` + `GITLAB_HOST=<host>`.
     If the instance is **single-assignee** (GitLab Free / many self-hosted tiers can't multi-assign),
     default `CLAIM_STRATEGY=note` (the note-marker CAS) — `assignee` strategy silently breaks
     multi-runner there. When unsure, prefer `note` and say why.
   - no recognizable remote → ask.
2. **Emit `plans/loop.config.sh`** from [`tracker.config.example.sh`](tracker.config.example.sh).
   Prompt for / fill: `REPO` (owner/name or group/project), `BRANCH_PREFIX`. The run-log needs no id —
   it is the newest open issue labeled `RUNLOG_LABEL` (default `loop:runlog`), auto-created on first
   `log`; override the label only to reuse an existing convention. Leave `BASE_BRANCH` **empty** unless the repo
   integrates into a non-default branch — it auto-detects the repo's default branch (`origin/HEAD`,
   falling back to `main`), so a `master`/`trunk` repo needs no config; set it only to pin a
   specific integration branch (e.g. `develop`). Keep every value as `${VAR:-default}` so env
   overrides win.
3. **Emit the launcher** `plans/run-loop.sh` (the one path a human types that can't use
   `$LOOP_KIT_DIR` — the driver is what sets it). It discovers the installed skill and exec's the
   driver, and supports `--print-kit-dir`. A reference copy ships as
   [`run-loop.template.sh`](run-loop.template.sh) — copy it in and `chmod +x`. **No runbook arg**:
   `./plans/run-loop.sh` (no args) lets the driver default `RUNBOOK` to the shared skeleton — the repo
   never holds its own runbook copy.
   - **call-from-skill:** that's all the runtime the repo needs (the skeleton resolves via the skill).
   - **scaffold-a-copy:** ALSO copy the kit's runtime files (incl. `loop-runbook.md`) into
     `plans/loop-kit/` and point the launcher at `./plans/loop-kit/…` (see "Two delivery modes").

> Each emit step writes only if the target is **absent**. If `plans/loop.config.sh` /
> `plans/run-loop.sh` already exist, keep them and report `kept existing …` — `init` is re-run-safe.

### Always
- **Never auto-commit.** Leave the scaffold in the working tree; tell the user to review + commit.
- After scaffolding, verify the wiring resolves (don't run a real iteration), **from the repo root**:
  `./plans/run-loop.sh --print-kit-dir` prints the kit dir, and
  `KIT="$(./plans/run-loop.sh --print-kit-dir)"; TRACKER_CONFIG="$PWD/plans/loop.config.sh" LOOP_KIT_DIR="$KIT" "$KIT"/track caps`
  prints the configured backend's capabilities — **confirm `backend=` matches what you set** (without
  the `TRACKER_CONFIG` export, `track` falls back to the placeholder `REPO=owner/repo` and may report
  the wrong backend, giving false confidence). Also confirm the skeleton resolves:
  `ls "$KIT"/loop-runbook.md` (the driver's default `RUNBOOK`).

---

## `config` — edit values or add a backend (already-onboarded repo)

Use when the repo already has `plans/loop.config.sh` and the user wants to change something (switch
`CLAIM_STRATEGY`, point at a different `RUNLOG_LABEL`) or **add a second tracker backend**. Read the
existing config, show the current values, and ask only what's changing (the AskUserQuestion picker,
our real options). Rewrite **only** `plans/loop.config.sh`. After writing, re-run the wiring check
from "Always" to confirm `backend=` is right. **Never auto-commit.**

## `run` — launch/resume the loop (once onboarded)

```bash
./plans/run-loop.sh                                          # default skeleton
TRACKER_BACKEND=gitlab ./plans/run-loop.sh
./plans/run-loop.sh plans/custom-loop.md                    # an explicit, non-default runbook (rare)
```

`run-loop.sh` locates the installed skill and exec's `loop-drive.sh`, which (with no runbook arg)
defaults `RUNBOOK` to the skill's `loop-runbook.md` skeleton and exports `LOOP_KIT_DIR` (the kit
dir), `TRACKER_CONFIG` (the repo's `plans/loop.config.sh`), and — by sourcing the config —
`READY_LABEL` / `RUNLOG_LABEL` / `BRANCH_PREFIX` (and the rest of the config) into each spawned
session. Stop with Ctrl-C anytime — state is external,
so re-running resumes. The driver tunables (MODEL, EFFORT, MAX_ITERS, WAIT_SECONDS,
PERMISSION_MODE, …) are documented at the top of `loop-drive.sh`.

**Queue hygiene.** Each issue the loop picks MUST carry a **falsifiable Acceptance Criteria
checklist** (`` `parseConfig('')` returns `{}`, not throws `` — not "handles empty config
gracefully"). File issues directly — tracker UI, `track`, or an authoring skill — the loop never
authors them.

**Standing-loop hazards.**
- **Merge-debt has no backpressure.** Issues stay OPEN until you merge, and a standing label never
  reaches `COMPLETE` — so nothing bounds the pile of un-merged agent PRs. Rule: **don't refill the
  queue while > N issues sit in-review.** (Review-response — `REVIEW_RESPONSE=on`, default — closes
  the *feedback* half of this: the loop reads your PR comments, fixes the branch, and replies
  inline. It still never merges — you remain the merge gate — so the don't-refill rule stands.)
- **Cost shape.** The driver defaults to `MODEL=opus EFFORT=high`. For a stream of small edits set
  a cheaper profile — `MODEL=sonnet EFFORT=medium ./plans/run-loop.sh` — and reserve opus/high for
  a deliberate batch.
- **WIP=1.** One in-progress issue per runner: a single self-paced runner that wedges on a
  `BLOCKED` item stalls the whole queue until you clear it (or run a second runner).

**Single change on demand.** To run just one item through the assembly line, file the issue (with
its Acceptance Criteria checklist) and `MAX_ITERS=1 ./plans/run-loop.sh` — one full build → review →
fix → PR pass, then the driver stops.

## Rules

- **Never author the backlog** (issue bodies, criteria, dependency edges) — that's the user's
  domain judgment; the loop only consumes the queue.
- **Never auto-commit** anything this skill emits.
- Multi-runner needs **N distinct tracker logins** (one token per user) in the default `assignee`
  strategy. To run **N agents under ONE login**, set `CLAIM_STRATEGY=note` (github): a per-agent
  `login#RUNNER_ID` comment-marker CAS that interops with assignee runners on the same issue. Note mode
  REQUIRES a stable, distinct **`RUNNER_ID` per agent** (passed on each agent's command line, not in
  `loop.config.sh`) — ownership is identity-based, so a downed agent reups with the same id to recover
  its claim. Invariant: **a login is wholly one strategy** (mixing under one login double-builds).
