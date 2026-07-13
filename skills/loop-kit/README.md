<!-- loop-kit v2: this README is rewritten by the "README + migration docs" ticket (#11);
     until then it documents only what survives the v2 deletions. -->
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
