# loop-kit

Set up and run a **context-bounded, multi-runner autonomous build loop** driven by an issue tracker
(GitHub or GitLab).

The loop spawns a **fresh headless `claude -p` per iteration**, so context never fills up — all
durable state lives on the tracker (issues, labels, a run-log), and each fresh session re-derives it.
**Each tracker issue is the lock**, so N people can run the same loop on separate machines without
colliding. A backend-agnostic dispatcher `track <verb>` seams GitHub (`gh`) and GitLab (`glab`) —
the runbook calls verbs, never `gh`/`glab` directly. (A `local`-files backend is designed but not
yet shipped.) The loop **never merges**: it opens a PR/MR whose description carries `Closes #N` and
stops — the human is always the merge gate.

## Where it fits in the skill flow

loop-kit is the **AFK build stage**, not the planner. Planning lives upstream:

```
/grilling  →  /to-tickets  →  loop-kit (this skill)  →  you merge
 spec        ready-for-agent    claim → build → open PR      the merge gate
             issues + blocking   in a fresh session, repeat
             edges
```

- **`/grilling`** stress-tests an idea into a spec.
- **`/to-tickets`** publishes that spec as tracer-bullet issues with native blocking edges and a
  `ready-for-agent` label.
- **loop-kit** repeatedly claims one `ready-for-agent` issue whose blockers are all closed, builds it
  with **`/implement`** in a per-issue worktree, opens a PR/MR that `Closes #N`, and stops when nothing
  is pickable — always in a fresh session so context never fills.
- **You** review and merge. Merging auto-closes the issue and re-arms its dependents.

The kit owns *only* that AFK stage. It never authors the backlog and never merges — see
"[What each adapter needs](#what-each-adapter-needs)" and the safety note below.

## What's in here

- `loop-drive.sh` — the stateless external driver (spawns a fresh session per iteration).
- `track` + `adapters/{github,gitlab}.sh` — the backend-agnostic tracker dispatcher.
- `loop-runbook.md` — the canonical runbook **skeleton** (the state machine + verb calls).
  It lives in the kit and is **symlinked** into each repo; the driver defaults `RUNBOOK` to it.
  Per-repo judgment lives in the repo's own CLAUDE.md.
- `tracker.config.example.sh` — the per-repo config template (copied in as `plans/loop.config.sh`).
- `run-loop.template.sh` — the human launcher (copied in as `plans/run-loop.sh`).

## What each adapter needs

Every backend also needs **`git`** (the loop builds branches; `branch-merged` is git-based).

- **github** — the `gh` CLI, authed (`gh auth login`). No `jq` (gh has a built-in `--jq`). Config:
  `REPO=owner/name`. Multi-runner: each runner authed as a DISTINCT `gh` login (the assignee is the lock).
- **gitlab** — the `glab` CLI, authed, PLUS `jq` (glab has no built-in jq filter, so read verbs pipe
  through `jq`). Self-hosted: set `GITLAB_HOST=<host>`. Config: `REPO=group/project`. Multi-runner: N
  distinct `glab` users; on GitLab Free / single-assignee instances set `CLAIM_STRATEGY=note` (the
  note-marker CAS).

## Use it

Invoke the skill on a target repo with a sub-command:

- **`init`** (default, auto-runs if the repo isn't onboarded) — probe the repo, confirm a write-plan,
  and emit `plans/loop.config.sh` and `plans/run-loop.sh` (pointing the repo at the shared
  `loop-runbook.md` skeleton — no per-repo runbook copy). Non-destructive (keeps any file that
  already exists).
- **`config`** — edit values or add a tracker backend on an already-onboarded repo (rewrites only the config).
- **`run`** — launch/resume the loop (`./plans/run-loop.sh`).

If you invoke `config`/`run` before the repo is onboarded, the skill runs `init` first.
See [SKILL.md](SKILL.md). The contract (verbs, the lock guarantees, the capability matrix) is in
[REFERENCE.md](REFERENCE.md).

> **Safety:** the loop runs `bypassPermissions` and pushes branches + opens PRs unattended, but it
> never merges (the human is the merge gate), never authors the backlog, and never auto-commits.

## Delivery modes

- **call-from-skill** (default) — the repo keeps no copy; its launcher locates the installed skill.
- **scaffold-a-copy** — the skill vendors the runtime into the repo's `plans/loop-kit/` (for a repo or
  CI that can't assume the skill is installed). Same layout either way.

## Queue hygiene: mind the merge-debt

The human is the merge gate, so nothing in the code bounds the pile of un-merged agent PRs. One rule:

> **Don't refill the queue while more than N issues sit in-review.**

Review-response (`REVIEW_RESPONSE=on`, the default) drains your PR feedback back into the branch,
but the don't-refill rule stands — see [SKILL.md](SKILL.md) ("Standing-loop hazards").

## Migrating from v1

v2 has **no migration code** — `init` is non-destructive and keeps any file that already exists, so an
onboarded v1 repo (e.g. `ezk`) must be updated by hand. On each repo already running v1:

1. **Rewrite `plans/loop.config.sh`.** Drop `WAVE`, `RUNLOG` (the fixed run-log id), and `LAND_MODE`;
   add `READY_LABEL` (default `ready-for-agent`) and `RUNLOG_LABEL` (default `loop:runlog`). Every
   value is `${VAR:-default}`, so you only set what differs from the defaults.
2. **Delete the per-repo judgment files** — `plans/loop.recipes.md`, `plans/loop.scope.md`, and any
   `plans/wave-loop.md`. Anything in them worth keeping (build constraints, review lenses, merge
   hotspots) moves into the **repo's own CLAUDE.md**, which every fresh `/implement` session reads
   anyway.
3. **Point the run-log at a label.** Label the existing run-log issue `loop:runlog` (or whatever you
   set `RUNLOG_LABEL` to) — or just let the loop create a fresh one on its first iteration.
4. **Ensure the queue is agent-ready.** Open tickets carry the `ready-for-agent` label and their
   blocking links (`## Blocked by` in the body, or native issue links). `/to-tickets` output already
   does both.

> **Accepted caveat:** because `init` never overwrites, re-running it on a v1 repo will **not** fix a
> stale `plans/loop.config.sh` — step 1 is a manual edit.

Nothing else carries over: waves, keystones, `plan`/`materialize`/`migrate`, the ClickUp backend, and
the `LAND_MODE=merge` machinery are all gone. If your v1 setup relied on them, that workflow now lives
in `/grilling` + `/to-tickets` upstream (planning) and the human merge gate (landing).
