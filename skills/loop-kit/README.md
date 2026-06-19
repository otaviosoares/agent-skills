# loop-kit

Set up and run a **context-bounded, multi-runner autonomous build loop** driven by an issue tracker
(GitHub or GitLab).

The loop spawns a **fresh headless `claude -p` per iteration**, so context never fills up — all
durable state lives on the tracker (issues, labels, a run-log), and each fresh session re-derives it.
**Each tracker issue is the lock**, so N people can run the same loop on separate machines without
colliding. A backend-agnostic dispatcher `track <verb>` seams GitHub (`gh`) and GitLab (`glab`) — the
runbook calls verbs, never `gh`/`glab` directly. (A `local`-files backend is designed but not yet shipped.)

## What's in here

- `loop-drive.sh` — the stateless external driver (spawns a fresh session per iteration).
- `track` + `adapters/{github,gitlab}.sh` — the backend-agnostic tracker dispatcher.
- `materialize-core.mjs` + `materialize-{github,gitlab}.mjs` — the offline producer that stands up a
  scope's issues on the tracker from a backlog file.
- `tracker.config.example.sh` — the per-repo config template (copied in as `plans/loop.config.sh`).
- `run-loop.template.sh` — the human launcher (copied in as `plans/run-loop.sh`).
- `runbook.template.md` — the loop runbook template (the SYNC→…→FINISH state machine + verb calls,
  with the 4 per-project judgment blocks left as fail-loud `<<FILL>>` tokens).

## Use it

Invoke the skill on a target repo to **`init`** it: auto-detect the backend, emit `plans/loop.config.sh`,
`plans/run-loop.sh`, and a `plans/wave-loop.md` runbook — then resolve the `<<FILL>>` judgment tokens
by hand and commit. See [SKILL.md](SKILL.md). The contract (verbs, the lock guarantees, the capability
matrix, the producer) is in [REFERENCE.md](REFERENCE.md).

> **Safety:** the loop runs `bypassPermissions` and, in `merge` mode, pushes to `main` unattended. The
> skill never auto-fills the judgment blocks, never authors the dependency graph, and never
> auto-commits — a confidently-wrong auto-runbook is more dangerous than a blank one.

## Delivery modes

- **call-from-skill** (default) — the repo keeps no copy; its launcher locates the installed skill.
- **scaffold-a-copy** — the skill vendors the runtime into the repo's `plans/loop-kit/` (for a repo or
  CI that can't assume the skill is installed). Same layout either way.
