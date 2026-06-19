---
name: loop-kit
description: Set up and run a context-bounded, multi-runner autonomous build loop driven by an issue tracker (GitHub, GitLab, or ClickUp). Use when the user wants to stand up an unattended "wave" build loop on a repo, onboard a repo to loop-kit, generate a loop runbook + tracker config, run or resume the loop, or add a tracker backend. The loop spawns a fresh headless `claude -p` per iteration (flat context), each tracker issue is the lock so N runners never collide, and a backend-agnostic `track` dispatcher seams GitHub, GitLab, and ClickUp (a local-files backend is planned). FAILS LOUD on the per-project judgment blocks (contention/merge recipe, land/lockfile recipe, CI-truth carve-out, review lenses) — never auto-fills or auto-commits them.
---

# Loop Kit

Stand up (and run) a **context-bounded autonomous build loop** on a repo. The loop has two
tiers, and the whole point is that **context never fills up**:

- An external **driver** (`loop-drive.sh`) spawns a **fresh headless `claude -p` per iteration** —
  empty context each time. All durable state lives OUTSIDE the agent (tracker issues, labels,
  a run-log), so each fresh session re-derives it. The driver is stateless: it only decides
  *when to fire the next session* and *when to stop*, reading a `LOOP_STATUS` sentinel.
- Each iteration is a thin **orchestrator** that picks ONE tracker issue, claims it, and delegates
  the build/review/fix to **fresh sub-agents** whose context is thrown away when they return.

**Each tracker issue is the lock**, so two (or N) people can run the same loop on separate machines
without colliding. A backend-agnostic dispatcher `track <verb>` hides whether the tracker is GitHub
(`gh`), GitLab (`glab`), or ClickUp (`curl` against the REST API) — the runbook calls verbs, never the
underlying CLI/API directly. (A `local`-files backend is designed in REFERENCE.md but ships no adapter yet.)

This skill does two things:
1. **`init`** — onboard a target repo: emit its tracker config + a loop runbook + a launcher.
2. **bundles the runtime** — `loop-drive.sh`, `track`, `adapters/*.sh`, `materialize-*.mjs` — that
   the onboarded repo calls.

> Read **[REFERENCE.md](REFERENCE.md)** for the verb contract, the lock contract (the 4 guarantees
> every backend must satisfy), the capability matrix, and the producer (`materialize-*`) contract.
> The runbook is generated from **[runbook.template.md](runbook.template.md)**.

---

## What this skill does NOT do (the irreducible per-project IP)

The loop runs `bypassPermissions` and, in `merge` mode, **pushes to `main` unattended**. A
confidently-wrong auto-generated runbook is therefore **more dangerous than a blank one**. So:

- **Never auto-fill the 4 judgment blocks.** The runbook template leaves them as visible
  `<<FILL: …>>` tokens that a human must confirm. They are NOT inferable from the repo:
  1. **Contention axes / merge recipe** — which files are merge hotspots and the per-file
     resolution rule (e.g. "new `schema-<domain>.ts` + barrel union-merge"; regenerate generated
     files like a route tree or a lockfile).
  2. **LAND recipe** — lockfile reconcile + any supply-chain cooldown (e.g. a pnpm
     `minimumReleaseAge` cooldown that CI enforces).
  3. **CI truth vs structurally-red CD** — which checks actually gate landability vs a deploy job
     that is red for environmental reasons (a missing deploy token) and must NOT wedge the loop.
  4. **Review lenses** — the domain threat model (cross-tenant isolation, money/contract
     correctness, auth/RBAC step-up, …).
- **Never author the dependency graph.** The tracker's issue bodies + dep edges + curated
  acceptance criteria are hand-authored domain judgment. `init` can stub the *contract*
  (the `issues-open.json` / `bodies/` shape the producer reads) but must NOT invent the graph.
- **Never auto-commit.** Emit files into the working tree and STOP. The human reviews and commits.

If you cannot fill a block safely, **leave the FILL token and say so** — fail loud, never guess.

---

## Two delivery modes

| mode | who holds the runtime | the repo references the kit as | use when |
|---|---|---|---|
| **call-from-skill** (default) | the installed skill (`~/.claude/skills/loop-kit`) | `"$LOOP_KIT_DIR"/track` (the driver injects `LOOP_KIT_DIR`) | every runner has this skill installed (the loop is driven by Claude Code, so they do) |
| **scaffold-a-copy** (vendored) | a real `plans/loop-kit/` copied into the repo | `./plans/loop-kit/track` | a collaborator's repo or CI that can't assume the skill is installed |

The runtime layout is identical in both modes (`track`, `loop-drive.sh`, `adapters/`,
`materialize-*` as siblings), so scaffold-a-copy is literally "copy this dir into `plans/loop-kit/`".

---

## `init` — onboard a target repo

Run from the target repo. Two tiers; do tier 1 fully, then tier 2.

### Tier 1 — the mechanical, safe scaffold (do this confidently)
1. **Probe the repo.** Read the git remote (`git remote get-url origin`) and detect the backend:
   - `github.com` → `TRACKER_BACKEND=github`.
   - a GitLab host (`gitlab.com` or self-hosted) → `TRACKER_BACKEND=gitlab` + `GITLAB_HOST=<host>`.
     If the instance is **single-assignee** (GitLab Free / many self-hosted tiers can't multi-assign),
     default `CLAIM_STRATEGY=note` (the note-marker CAS) — `assignee` strategy silently breaks
     multi-runner there. When unsure, prefer `note` and say why.
   - **ClickUp is NOT derivable from the git remote** (the code host and the tracker are decoupled — the
     repo can live on any `origin`). Select `TRACKER_BACKEND=clickup` only when the user says so, and
     fill the `CLICKUP_TOKEN`/`CLICKUP_LIST_ID`/`CLICKUP_STATUS_DONE` block instead of `REPO`. ClickUp
     hosts no code → it supports `LAND_MODE=merge` only; if the user wants `pr`, say it's unavailable
     there. Each runner needs a **distinct `CLICKUP_TOKEN`** for multi-runner.
   - no recognizable remote → ask (it may be a ClickUp-tracked repo on an unrecognized host).
2. **Emit `plans/loop.config.sh`** from [`tracker.config.example.sh`](tracker.config.example.sh).
   Prompt for / fill: `REPO` (owner/name or group/project), `RUNLOG` (the run-log issue handle —
   may not exist yet; note it), `BRANCH_PREFIX`, `LAND_MODE` (`merge` = autonomous push to main;
   `pr` = open a PR and hand off to a human — recommend `pr` unless the user wants full autonomy).
   For github with a Projects-v2 board, optionally fill the `GH_PROJECT*`/`GH_FIELD_*` block (leave
   unset and board placement is skipped). Keep every value as `${VAR:-default}` so env overrides win.
3. **Emit the launcher** `plans/run-loop.sh` (the one path a human types that can't use
   `$LOOP_KIT_DIR` — the driver is what sets it). It discovers the installed skill and exec's the
   driver, and supports `--print-kit-dir`. A reference copy ships as
   [`run-loop.template.sh`](run-loop.template.sh) — copy it in and `chmod +x`.
   - **call-from-skill:** that's all the runtime the repo needs.
   - **scaffold-a-copy:** ALSO copy the kit's runtime files into `plans/loop-kit/` and point the
     runbook at `./plans/loop-kit/track` (see "Two delivery modes").

### Tier 2 — the runbook (the dangerous part — fail loud)
4. **Emit the runbook** `plans/wave-loop.md` (or `<loop>.md`) from
   [`runbook.template.md`](runbook.template.md). Keep the SYNC→RECONCILE→PICK→CLAIM→BUILD→REVIEW→
   LAND→CLOSE→LOG→FINISH state machine and the `"$LOOP_KIT_DIR"/track` verb calls intact.
   Leave the **4 judgment blocks as `<<FILL: …>>` tokens.** Draft a *suggestion* in a comment if you
   have evidence, but the token stays until a human confirms it. Tell the user exactly which tokens
   remain and that the loop must not run until they're resolved.
5. **Do NOT author the dependency graph or the issue bodies.** Point the user at the producer
   (`materialize-*.mjs`) + the `issues-open.json`/`bodies/` contract in REFERENCE.md; that's their IP.

### Always
- **Never auto-commit.** Leave the scaffold in the working tree; tell the user to review + commit.
- After scaffolding, verify the wiring resolves (don't run a real iteration), **from the repo root**:
  `./plans/run-loop.sh --print-kit-dir` prints the kit dir, and
  `KIT="$(./plans/run-loop.sh --print-kit-dir)"; TRACKER_CONFIG="$PWD/plans/loop.config.sh" LOOP_KIT_DIR="$KIT" "$KIT"/track caps`
  prints the configured backend's capabilities — **confirm `backend=` matches what you set** (without
  the `TRACKER_CONFIG` export, `track` falls back to the placeholder `REPO=owner/repo` and may report
  the wrong backend, giving false confidence).

---

## Running the loop (once onboarded)

```bash
./plans/run-loop.sh plans/wave-loop.md                       # default LAND_MODE from loop.config.sh
LAND_MODE=pr ./plans/run-loop.sh plans/wave-loop.md          # open PRs instead of merging to main
TRACKER_BACKEND=gitlab ./plans/run-loop.sh plans/wave-loop.md
```

`run-loop.sh` locates the installed skill and exec's `loop-drive.sh`, which exports `LOOP_KIT_DIR`
(this dir) + `TRACKER_CONFIG` (the repo's `plans/loop.config.sh`) into each spawned session. Stop
with Ctrl-C anytime — state is external, so re-running resumes. The driver tunables (MODEL, EFFORT,
MAX_ITERS, WAIT_SECONDS, PERMISSION_MODE, …) are documented at the top of `loop-drive.sh`.

## Advancing/creating a wave's issues (the producer)

The runtime adapter handles the *running* loop; the **producer** (`materialize-{github,gitlab}.mjs`,
driven by `materialize-core.mjs`) stands up a scope's issues on the tracker from a backlog file.
It is offline + DRY-by-default. See REFERENCE.md → "Producer". `init` never runs it (it mutates the
tracker); it's a human-gated step.

## Rules

- **Fail loud, never guess** on the 4 judgment blocks and the dependency graph — they corrupt shared
  code or bypass a supply-chain gate if wrong, and the loop runs unattended.
- **Never auto-commit** anything this skill emits.
- **Never run the loop mid-extraction or with unresolved `<<FILL>>` tokens.**
- Multi-runner needs **N distinct tracker logins** (github / clickup — one token per user) or a
  single-assignee-safe `CLAIM_STRATEGY=note` (gitlab Free). One shared login → degrade to single-runner
  and say so.
