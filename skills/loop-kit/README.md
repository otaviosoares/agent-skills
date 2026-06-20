# loop-kit

Set up and run a **context-bounded, multi-runner autonomous build loop** driven by an issue tracker
(GitHub, GitLab, or ClickUp).

The loop spawns a **fresh headless `claude -p` per iteration**, so context never fills up — all
durable state lives on the tracker (issues, labels, a run-log), and each fresh session re-derives it.
**Each tracker issue is the lock**, so N people can run the same loop on separate machines without
colliding. A backend-agnostic dispatcher `track <verb>` seams GitHub (`gh`), GitLab (`glab`), and
ClickUp (`curl` against the ClickUp REST API v2 — there is no official ClickUp CLI) — the runbook
calls verbs, never `gh`/`glab`/`curl` directly. (A `local`-files backend is designed but not yet shipped.)

## What's in here

- `loop-drive.sh` — the stateless external driver (spawns a fresh session per iteration).
- `track` + `adapters/{github,gitlab,clickup}.sh` — the backend-agnostic tracker dispatcher.
- `materialize-core.mjs` + `materialize-{github,gitlab,clickup}.mjs` — the offline producer that stands
  up a scope's issues on the tracker from a backlog file.
- `materialize-plan.mjs` + `plan.template/` — the `plan` engine: scaffold a wave's backlog as a source
  tree, `compile` it into the producer's data dir, and `check` it (the init→materialize bridge).
- `migrate.mjs` — the `migrate` engine: lift the per-repo judgment out of a stale `plans/wave-loop.md`
  (a pre-split runbook copy) into `plans/loop.recipes.md` + `plans/loop.scope.md` (fail-loud, non-destructive).
- `loop-runbook.md` — the canonical runbook **skeleton** (the SYNC→…→FINISH state machine + verb calls).
  It lives in the kit and is **symlinked** into each repo; the driver defaults `RUNBOOK` to it. The
  judgment it applies lives in the repo's `plans/loop.recipes.md` (~stable) + `plans/loop.scope.md` (per-wave).
- `recipes.template.md` — the per-repo recipes template (copied in as `plans/loop.recipes.md`): the 5
  ~stable judgment `## SECTION`s the skeleton applies by name, left as fail-loud `<<FILL>>` tokens.
- `scope.template.md` — the per-wave scope template (copied in as `plans/loop.scope.md`): the 2 scope
  `## SECTION`s (`## TARGET`, `## KEYSTONES`) the skeleton applies by name, left as fail-loud `<<FILL>>` tokens.
- `tracker.config.example.sh` — the per-repo config template (copied in as `plans/loop.config.sh`).
- `run-loop.template.sh` — the human launcher (copied in as `plans/run-loop.sh`).

## What each adapter needs

Every backend also needs **`git`** (the loop builds branches and lands them; `branch-merged` is git-based).
For ClickUp the code can live on any git host — ClickUp is only the tracker.

- **github** — the `gh` CLI, authed (`gh auth login`). No `jq` (gh has a built-in `--jq`). Config:
  `REPO=owner/name`. Multi-runner: each runner authed as a DISTINCT `gh` login (the assignee is the lock).
  Supports `LAND_MODE` `merge` AND `pr` (can open PRs). Producer `materialize-github.mjs` needs `gh` + Node.
- **gitlab** — the `glab` CLI, authed, PLUS `jq` (glab has no built-in jq filter, so read verbs pipe
  through `jq`). Self-hosted: set `GITLAB_HOST=<host>`. Config: `REPO=group/project`. Multi-runner: N
  distinct `glab` users; on GitLab Free / single-assignee instances set `CLAIM_STRATEGY=note` (the
  note-marker CAS). Supports `merge` AND `pr` (MRs). Producer `materialize-gitlab.mjs` needs `glab` + `jq` + Node.
- **clickup** — NO CLI exists, so `curl` + `jq` + a personal token `CLICKUP_TOKEN` (the raw `pk_…` value,
  sent in the Authorization header). The tracker unit is a ClickUp LIST: set `CLICKUP_LIST_ID` (in place
  of `REPO`). Scope/labels are space TAGS; open|closed is the task STATUS TYPE; `close` sets the status
  named by `CLICKUP_STATUS_DONE` (default `closed`). `RUNLOG` is a ClickUp TASK id whose comments are the
  run-log. PRECONDITION: create the `in-progress` and `in-review` tags in the space once. Multi-runner:
  each runner needs a DISTINCT `CLICKUP_TOKEN`. ClickUp hosts no code, so it supports **`LAND_MODE=merge`
  ONLY** (`can_open_pr=false`; `open-pr` fails loud). Producer `materialize-clickup.mjs` needs Node 18+
  (uses global `fetch`) + `CLICKUP_TOKEN` + `CLICKUP_LIST_ID`.

## Use it

Invoke the skill on a target repo with a sub-command:

- **`init`** (default, auto-runs if the repo isn't onboarded) — probe the repo, confirm a write-plan,
  and emit `plans/loop.config.sh`, `plans/run-loop.sh`, `plans/loop.recipes.md`, and `plans/loop.scope.md`
  (pointing the repo at the shared `loop-runbook.md` skeleton — no per-repo runbook copy). Non-destructive
  (keeps any file that already exists). Then resolve the `<<FILL>>` judgment tokens in `loop.recipes.md`
  and `loop.scope.md` by hand and commit.
- **`config`** — edit values or add a tracker backend on an already-onboarded repo (rewrites only the config).
- **`plan`** — author a wave's backlog as a source tree (`plans/.tracker/src/`), then compile + validate
  it into the producer's data dir. Bridges `init`→`materialize`; scaffolds and checks the dependency
  graph + bodies but never authors them.
- **`migrate`** — one-time, for a repo onboarded before the skeleton/recipes split: lift the judgment
  from a stale `plans/wave-loop.md` into `plans/loop.recipes.md` + `plans/loop.scope.md` (`migrate.mjs`;
  fail-loud, non-destructive).
- **`run`** — launch/resume the loop (`./plans/run-loop.sh`).
- **`materialize`** — human-gated producer run that stands up a wave's issues from a backlog file (gated
  behind a clean `plan check`).

If you invoke `config`/`plan`/`run`/`materialize` before the repo is onboarded, the skill runs `init` first.
See [SKILL.md](SKILL.md). The contract (verbs, the lock guarantees, the capability matrix, the
producer) is in [REFERENCE.md](REFERENCE.md).

> **Safety:** the loop runs `bypassPermissions` and, in `merge` mode, pushes to `main` unattended. The
> skill never auto-fills the judgment blocks, never authors the dependency graph, and never
> auto-commits — a confidently-wrong auto-runbook is more dangerous than a blank one.

## Delivery modes

- **call-from-skill** (default) — the repo keeps no copy; its launcher locates the installed skill.
- **scaffold-a-copy** — the skill vendors the runtime into the repo's `plans/loop-kit/` (for a repo or
  CI that can't assume the skill is installed). Same layout either way.
