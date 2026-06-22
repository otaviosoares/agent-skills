---
name: loop-kit
description: >-
  Set up and run a context-bounded, multi-runner autonomous build loop driven by an issue
  tracker (GitHub, GitLab, or ClickUp). Use when the user wants to stand up an unattended
  "wave" build loop on a repo, onboard a repo to loop-kit, generate a loop runbook + tracker
  config, run or resume the loop (as planned waves OR a standing day-to-day loop), migrate an
  old runbook into recipes + scope, or add a tracker backend. Sub-commands — `init` (onboard a
  repo, auto-runs first), `config` (edit/add a backend), `plan` (author a wave's backlog as a
  source tree, compile + validate it), `migrate` (lift a stale runbook copy into
  loop.recipes.md + loop.scope.md), `run` (launch the loop), `materialize` (stand up a wave's
  issues). The runbook is a shared SKELETON (loop-runbook.md, in the skill, symlinked +
  auto-updating) plus two per-repo files the skeleton applies by name — loop.recipes.md (5
  ~stable per-repo judgment sections) and loop.scope.md (2 per-wave scope sections). The loop
  spawns a fresh headless `claude -p` per iteration (flat context), each tracker issue is the
  lock so N runners never collide, and a backend-agnostic `track` dispatcher seams GitHub,
  GitLab, and ClickUp (a local-files backend is planned). FAILS LOUD on the per-project
  judgment sections (contention/merge recipe, land/lockfile recipe, CI-truth carve-out, review
  lenses) — never auto-fills or auto-commits them.
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
1. **`init`** — onboard a target repo: emit its tracker config + a launcher + a per-repo **recipes**
   file + a per-wave **scope** file, and point it at the kit's shared runbook **skeleton**.
2. **bundles the runtime** — `loop-drive.sh`, `track`, `adapters/*.sh`, `loop-runbook.md`,
   `materialize-*.mjs` — that the onboarded repo references (symlinked, so updates propagate).

### The runbook = a shared SKELETON (code) + per-repo RECIPES + per-wave SCOPE (config)
The loop runbook is split into a shared skeleton and two repo files:
- **[loop-runbook.md](loop-runbook.md)** — the canonical **skeleton**: the backend/project-neutral
  SYNC→RECONCILE→PICK→CLAIM→BUILD→REVIEW→LAND→CLOSE→LOG→FINISH state machine. It lives **in the skill**
  and is **symlinked** into each onboarded repo (exactly like `track`/`adapters/`/`loop-drive.sh`), so a
  skeleton fix propagates to every repo automatically — there is no per-repo copy to go stale. The driver
  defaults `RUNBOOK` to this file, so `./plans/run-loop.sh` (no runbook arg) uses it.
- **`plans/loop.recipes.md`** — the **~stable per-repo judgment**, as 5 labeled `## SECTION`s
  (CONTENTION, BUILD-CONSTRAINTS, REVIEW-LENSES, LAND, CI-TRUTH). The driver exports it as `$LOOP_RECIPES`;
  `init` emits it from **[recipes.template.md](recipes.template.md)**.
- **`plans/loop.scope.md`** — the **per-wave scope**, as 2 labeled `## SECTION`s (TARGET, KEYSTONES),
  rewritten each wave. The driver exports it as `$LOOP_SCOPE`; `init` emits it from
  **[scope.template.md](scope.template.md)**.
  The skeleton references every section by name with a `RECIPE → ## NAME` marker (naming the file) and
  applies it **verbatim**. The kit **NEVER auto-fills** any of them (fail loud).
- **PIN the skeleton for reproducibility** the same way you pin `adapters/` — the symlink/checkout is the
  knob. To freeze the skeleton at a known version, vendor the kit into `./plans/loop-kit/` (delivery mode
  "scaffold-a-copy") or install a pinned skill version; then a skeleton change won't move under a running
  wave until you re-vendor/re-pin.

> Read **[REFERENCE.md](REFERENCE.md)** for the verb contract, the lock contract (the 4 guarantees
> every backend must satisfy), the capability matrix, the config/env resolution, and the producer
> (`materialize-*`) contract.

---

## Commands

The skill takes a sub-command as its argument (e.g. `loop-kit init`, `loop-kit config`). Route on it:

| command | what it does | mutates the tracker? |
|---|---|---|
| **`init`** (default) | Onboard the target repo: probe → confirm a plan → emit `plans/loop.config.sh`, `plans/run-loop.sh`, `plans/loop.recipes.md`, `plans/loop.scope.md`. Points the repo at the kit's shared **skeleton** (`loop-runbook.md`) — no per-repo runbook copy. **Non-destructive** (keeps any file that already exists). | no |
| **`config`** | Re-open the config Q&A on an already-onboarded repo: edit values or add a second tracker backend. Touches only `plans/loop.config.sh`; never regenerates the recipes. | no |
| **`plan`** | Author a wave's backlog as a **source tree** (`plans/.tracker/src/`), then `compile` it into the producer's data dir and `check` it. Bridges `init`→`materialize`. Writes only local files; **facilitates** the human's dep graph + bodies, never invents them (see the `plan` section). | no |
| **`migrate`** | One-time: lift the per-repo judgment out of a STALE materialized runbook (`plans/wave-loop.md`, a copy from before the skeleton/recipes split) into `plans/loop.recipes.md` (5 ~stable sections) + `plans/loop.scope.md` (2 per-wave sections). Non-destructive (refuses to clobber either); **fails loud** on any block it can't place. Engine `migrate.mjs` (see the `migrate` section). | no |
| **`run`** | Launch/resume the loop via `./plans/run-loop.sh` (see the `run` section). Surfaces the tunables; does not edit files. | yes (builds/lands) |
| **`materialize`** | Human-gated: run the producer (`materialize-*.mjs`) to stand up a wave's issues from a backlog file (see the `materialize` section). Gated behind a clean `plan check`. | yes |

**Auto-init guard.** Before honoring `config`, `plan`, `run`, or `materialize`, check the target repo for
`plans/loop.config.sh`. If it's **missing**, the repo isn't onboarded yet — say so and run **`init`
first**, then continue to the requested command. A bare invocation with no argument also means `init`.
(`init` itself is safe to re-run: it's non-destructive and just reports what already exists.)

---

## What this skill does NOT do (the irreducible per-project IP)

The loop runs `bypassPermissions` and, in `merge` mode, **pushes to `main` unattended**. A
confidently-wrong recipe is therefore **more dangerous than a blank one**. So:

- **Never auto-fill the judgment recipes.** `plans/loop.recipes.md` holds 5 ~stable per-repo judgment
  sections and the sibling `plans/loop.scope.md` holds the 2 per-wave scope sections (`## TARGET`,
  `## KEYSTONES`). `recipes.template.md` / `scope.template.md` leave all of them as visible `<<FILL: …>>`
  tokens a human must confirm; the skeleton STOPs with `LOOP_STATUS=BLOCKED` if a referenced section is
  missing or still carries a `<<FILL>>`. The four dangerous recipe ones are NOT inferable from the repo:
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

If you cannot fill a section safely, **leave the FILL token and say so** — fail loud, never guess.

---

## Two delivery modes

| mode | who holds the runtime | the repo references the kit as | use when |
|---|---|---|---|
| **call-from-skill** (default) | the installed skill (`~/.claude/skills/loop-kit`) | `"$LOOP_KIT_DIR"/track` (the driver injects `LOOP_KIT_DIR`) | every runner has this skill installed (the loop is driven by Claude Code, so they do) |
| **scaffold-a-copy** (vendored) | a real `plans/loop-kit/` copied into the repo | `./plans/loop-kit/track` | a collaborator's repo or CI that can't assume the skill is installed |

The runtime layout is identical in both modes (`track`, `loop-drive.sh`, `adapters/`, `loop-runbook.md`,
`materialize-*` as siblings), so scaffold-a-copy is literally "copy this dir into `plans/loop-kit/`".
**Vendoring also PINS the skeleton** (and adapters) at that copy's version — the reproducibility knob.

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
Show the user a compact summary: detected backend + host, the `LAND_MODE` you'll default to, the
delivery mode, which of `loop.config.sh` / `run-loop.sh` / `loop.recipes.md` / `loop.scope.md` are new
vs. already present (plus that the repo points at the shared `loop-runbook.md` skeleton, no per-repo
runbook copy), and the `<<FILL>>` tokens that will remain. Then ask — via the AskUserQuestion picker, with our real
options — ONLY the questions whose answers you couldn't safely infer. Typical ambiguous ones:
`LAND_MODE` (`pr` vs `merge`), delivery mode (call-from-skill vs scaffold-a-copy), and — when the
remote is unrecognized or the user named ClickUp — the backend itself. If everything was unambiguous,
skip straight to emit after the confirmation summary.

### Step 2 — emit (Tier 1: mechanical, safe — do confidently)
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
   [`run-loop.template.sh`](run-loop.template.sh) — copy it in and `chmod +x`. **No runbook arg**:
   `./plans/run-loop.sh` (no args) lets the driver default `RUNBOOK` to the shared skeleton — the repo
   never holds its own runbook copy.
   - **call-from-skill:** that's all the runtime the repo needs (the skeleton resolves via the skill).
   - **scaffold-a-copy:** ALSO copy the kit's runtime files (incl. `loop-runbook.md`) into
     `plans/loop-kit/` and point the recipes/track at `./plans/loop-kit/…` (see "Two delivery modes").

> Each emit step writes only if the target is **absent**. If `plans/loop.config.sh` /
> `plans/run-loop.sh` / `plans/loop.recipes.md` / `plans/loop.scope.md` already exist, keep them and
> report `kept existing …` — `init` is re-run-safe.

### Step 3 — emit (Tier 2: the recipes + scope — the dangerous part, fail loud)
4. **Emit `plans/loop.recipes.md`** from [`recipes.template.md`](recipes.template.md) — the 5 ~stable
   per-repo `## SECTION`s — **and `plans/loop.scope.md`** from [`scope.template.md`](scope.template.md) —
   the 2 per-wave scope sections (`## TARGET`, `## KEYSTONES`) — the shared skeleton applies by name.
   **Do NOT emit a per-repo runbook copy** and do NOT keep `plans/wave-loop.md` around: the SYNC→…→FINISH
   state machine + `"$LOOP_KIT_DIR"/track` verb calls now live in the skill's `loop-runbook.md` skeleton
   (symlinked, auto-updating), which the driver uses by default. Leave **every recipe + scope section as
   a `<<FILL: …>>` token.** Draft a *suggestion* in a comment if you have evidence, but the token stays
   until a human confirms it. Tell the user exactly which sections remain unfilled and that the loop must
   not run until they're resolved (the skeleton STOPs `BLOCKED` on any unresolved section).
5. **Do NOT author the dependency graph or the issue bodies.** Point the user at the producer
   (`materialize-*.mjs`) + the `issues-open.json`/`bodies/` contract in REFERENCE.md; that's their IP.

### Always
- **Never auto-commit.** Leave the scaffold in the working tree; tell the user to review + commit.
- After scaffolding, verify the wiring resolves (don't run a real iteration), **from the repo root**:
  `./plans/run-loop.sh --print-kit-dir` prints the kit dir, and
  `KIT="$(./plans/run-loop.sh --print-kit-dir)"; TRACKER_CONFIG="$PWD/plans/loop.config.sh" LOOP_KIT_DIR="$KIT" "$KIT"/track caps`
  prints the configured backend's capabilities — **confirm `backend=` matches what you set** (without
  the `TRACKER_CONFIG` export, `track` falls back to the placeholder `REPO=owner/repo` and may report
  the wrong backend, giving false confidence). Also confirm the skeleton resolves: `ls "$KIT"/loop-runbook.md`
  (the driver's default `RUNBOOK`) and that `plans/loop.recipes.md` (the driver's `$LOOP_RECIPES`) and
  `plans/loop.scope.md` (the driver's `$LOOP_SCOPE`) exist.

---

## `config` — edit values or add a backend (already-onboarded repo)

Use when the repo already has `plans/loop.config.sh` and the user wants to change something (flip
`LAND_MODE`, switch `CLAIM_STRATEGY`, point at a different `RUNLOG`) or **add a second tracker
backend**. Read the existing config, show the current values, and ask only what's changing (the
AskUserQuestion picker, our real options). Rewrite **only** `plans/loop.config.sh`; never regenerate
`plans/loop.recipes.md` or `plans/loop.scope.md` (they hold hand-resolved `<<FILL>>` judgment —
regenerating would clobber that). After writing, re-run the wiring check from "Always" to confirm `backend=` is right.
**Never auto-commit.**

## `migrate` — lift a stale runbook copy into recipes (one-time)

For a repo onboarded **before** the skeleton/recipes split: it has a per-repo `plans/wave-loop.md`
(a copy of the old `runbook.template.md`) with the judgment baked in. `migrate` extracts that judgment
into `plans/loop.recipes.md` (the 5 ~stable sections) + `plans/loop.scope.md` (the 2 per-wave scope
sections) so the repo can drop the copy and use the shared skeleton. Engine:
[`migrate.mjs`](migrate.mjs) (offline, like `materialize-plan.mjs`):

```bash
KIT="$(./plans/run-loop.sh --print-kit-dir)"
# refuses to clobber either output:
node "$KIT"/migrate.mjs --runbook plans/wave-loop.md --out plans/loop.recipes.md --scope-out plans/loop.scope.md
node "$KIT"/migrate.mjs --runbook plans/wave-loop.md --out plans/loop.recipes.md --scope-out plans/loop.scope.md --overwrite
```

It maps each runbook region to a slot — Scope→TARGET/KEYSTONES (written to `loop.scope.md`),
shared-lock→CONTENTION, the builder/reviewer briefs→BUILD-CONSTRAINTS/REVIEW-LENSES, LAND step→LAND, the
CI-truth carve-out→CI-TRUTH (the last five written to `loop.recipes.md`) — extracting the source text
**verbatim**, not reproducing a human's rewrapping/editorial polish. It is **non-destructive** (refuses to
overwrite either output without `--overwrite`) and **fails loud**: any block it can't place confidently is
left as a `<<FILL>>` token in whichever output it belongs to and reported as a FLAG on stderr (exit
non-zero if any FILL remains in either file). `migrate` is a *starting point* — the human must REVIEW +
trim every section (e.g. strip the mechanical scaffolding the briefs carry, which the skeleton already
provides) before a real run. After migrating: drop the runbook arg (`./plans/run-loop.sh`), then delete
`plans/wave-loop.md`.

## `run` — launch/resume the loop (once onboarded)

```bash
./plans/run-loop.sh                                          # default skeleton + LAND_MODE from loop.config.sh
LAND_MODE=pr ./plans/run-loop.sh                             # open PRs instead of merging to main
TRACKER_BACKEND=gitlab ./plans/run-loop.sh
./plans/run-loop.sh plans/custom-loop.md                    # an explicit, non-default runbook (rare)
```

Before launching, confirm there are **no unresolved `<<FILL>>` tokens** in `plans/loop.recipes.md` or
`plans/loop.scope.md` (grep both) — the loop must not run with any remaining (the skeleton STOPs `BLOCKED`
on one anyway). `run-loop.sh` locates the installed skill and exec's `loop-drive.sh`, which (with no
runbook arg) defaults `RUNBOOK` to the skill's `loop-runbook.md` skeleton and exports `LOOP_KIT_DIR` (the
kit dir), `TRACKER_CONFIG` (the repo's `plans/loop.config.sh`), `LOOP_RECIPES` (the repo's
`plans/loop.recipes.md`), `LOOP_SCOPE` (the repo's `plans/loop.scope.md`), and — by sourcing the config —
`WAVE` / `BRANCH_PREFIX` into each spawned session. Stop with Ctrl-C
anytime — state is external, so re-running resumes. The driver tunables (MODEL, EFFORT, MAX_ITERS,
WAIT_SECONDS, PERMISSION_MODE, …) are documented at the top of `loop-drive.sh`.

## Day-to-day mode — the standing-label preset (post-waves)

Once the planned waves are done, the same loop runs ad-hoc day-to-day work with **no new code** — the
build → independent-review → regression-tested-fix → land assembly line and the 5 recipes are
**wave-agnostic**. Convert an onboarded repo to a standing day-to-day loop:

1. **Standing scope, not an advancing wave.** Point `WAVE` (in `plans/loop.config.sh`, via `config`) at a
   permanent label, e.g. `loop:active`, and create it once on the tracker. The PICK query is just
   `track sync-list "$WAVE"` — nothing requires the label to be a wave.
2. **Rewrite `plans/loop.scope.md` once, then leave it.** `## TARGET` = "all OPEN `<label>` issues whose
   `Dependencies` are closed (most are independent leaves)"; `## KEYSTONES` = `_none_` (ad-hoc work has
   no spine). `plans/loop.recipes.md` carries over **untouched** — that's the whole reuse win.
3. **File issues directly** — tracker UI / `track` / the `/qa` skill — **skip `plan`/`materialize`** (the
   DAG authoring is a batch convenience; PICK reads live). Each issue body MUST carry a **falsifiable
   Acceptance Criteria checklist** (`` `parseConfig('')` returns `{}`, not throws `` — not "handles empty
   config gracefully"): that checklist is the independent reviewer's test oracle, and the builder now
   reads criteria from the issue body when no plan file is referenced (see the builder brief).
4. **`LAND_MODE=pr`, always, for ad-hoc work against shipped code.** Each item lands as a PR and the loop
   STOPs short of merge — you are the gate. Reserve `merge` (autonomous push to main) for a deliberately
   authored, criteria-bearing batch (i.e. a real wave), never for an ad-hoc one-off.

**Single change on demand.** To run just one item through the assembly line, file the issue (with its
Acceptance Criteria checklist) and `MAX_ITERS=1 ./plans/run-loop.sh` — one full build → review → fix →
PR pass, then the driver stops. (*Whether* a given ad-hoc change is worth the loop versus a by-hand edit
is a per-project workflow call — keep that policy in your own repo's docs, not in the kit.)

**Standing-loop hazards (the wave model masked these).**
- **Merge-debt has no backpressure.** In `pr` mode issues stay OPEN until you merge, and a standing label
  never reaches `COMPLETE` — so nothing bounds the pile of un-merged agent PRs. Rule: **don't refill the
  queue while > N issues sit in-review.**
- **Cost shape.** The driver defaults to `MODEL=opus EFFORT=high` (tuned for unattended wave work). For a
  stream of small edits set a cheaper profile — `MODEL=sonnet EFFORT=medium ./plans/run-loop.sh` — and
  reserve opus/high for a deliberate batch.
- **WIP=1.** One in-progress issue per runner: a single self-paced runner that wedges on a `BLOCKED` item
  stalls the whole queue until you clear it (or run a second runner).

## `plan` — author a wave's backlog (the init→materialize bridge)

`init` emits the config + recipes and stops; `materialize` assumes the producer's data dir already
exists and is correct. **`plan` owns the middle** — turning a project into the producer's input —
without ever inventing the parts that are the user's domain IP. Engine: `materialize-plan.mjs`
(offline, zero-dependency), three modes:

1. **scaffold** — `node "$KIT"/materialize-plan.mjs scaffold --root plans/.tracker --scope <label> [--slug <s> …]`
   lays down a **source tree** at `plans/.tracker/src/`: one `issue/<slug>.md` per issue (YAML
   frontmatter `{title, labels, milestone, deps:[slugs]}` + a markdown body) and `milestones.yml`.
   **Interview the human** (AskUserQuestion, same picker `init` uses) for the structural picks you can
   mechanically own — scope label, milestone set, and per issue `{title, milestone, which existing
   slugs it depends on}` — and seed the stubs. The body's Goal + Acceptance criteria stay as
   `<<FILL: … >>` tokens (the exact fail-loud stance the runbook uses). **Never infer a dependency
   edge** from title similarity, file overlap, or ordering — the human names every edge or there is
   none. **Never write the Goal/criteria.** Re-run-safe: never overwrites an existing source file.
2. **compile** — `node "$KIT"/materialize-plan.mjs compile --src plans/.tracker/src --out plans/.tracker`
   deterministically lowers the source tree into the **exact existing producer contract**
   (`issues-open.json` + `bodies/<slug>.md` + `milestones.json`), byte-compatible downstream — the
   producer and the runtime loop change zero lines. `slug = filename`, so the slug↔bodyFile footgun is
   impossible by construction; the body's `## Dependencies` section (which the runtime PICK step reads)
   is **rendered** from the typed `deps`, never authored. Refuses to compile if any `<<FILL>>` survives,
   a body is empty, or `--src == --out`. `created-issues.tsv` is create-if-absent only (it's live state).
3. **check** — `node "$KIT"/materialize-plan.mjs check --root plans/.tracker [--scope <label>] [--batch-data <f>]`
   a read-only validator over the producer dir (compiled **or** hand-authored) that accumulates **every**
   violation and exits non-zero: bodyFile existence (**the DRY footgun** — producer DRY never reads
   bodies), milestone resolution across all scopes, slug uniqueness (case-fold), scope-label presence,
   `deps` resolution (dangling refs), and **dependency-cycle / DAG** check. It reports a cycle but
   **never picks which edge to cut** — that's human judgment.

**Mechanical vs judgment.** `plan` owns the mechanical correctness (slug↔bodyFile, milestone
resolution, label hygiene, acyclicity); the human owns the judgment (whether the deps are the *right*
deps, what the acceptance criteria are). The `<<FILL>>` tokens and the "never infer an edge" rule are
where that line is drawn — same posture as the recipes' 4 judgment sections. **Hand-authoring escape
hatch:** a user who prefers writing the producer contract directly skips `compile` and just runs
`check --root` on their raw dir; the source format is strictly opt-in.

## `materialize` — advance/create a wave's issues (the producer)

The runtime adapter handles the *running* loop; the **producer** (`materialize-{github,gitlab,clickup}.mjs`,
driven by `materialize-core.mjs`) stands up a scope's issues on the tracker from a backlog file.
It is offline + DRY-by-default. See REFERENCE.md → "Producer". This **mutates the tracker**, so it is
human-gated: confirm the backlog file + scope with the user and run it DRY first, then for-real only on
explicit go-ahead. `init` never runs it. Do NOT author the dependency graph or issue bodies yourself —
that's the user's domain IP (REFERENCE.md → the `issues-open.json`/`bodies/` contract).

**Blocking precondition.** Before offering `DRY=0`, run `materialize-plan.mjs check --root <data-dir>`
and require a **clean exit** — same spirit as the no-unresolved-`<<FILL>>` grep gate before `run`. A
red `check` means the data dir would create broken issues (a missing body, an undeclared milestone, a
dangling dep, a dependency cycle that wedges the runtime in permanent WAIT) on a **live** tracker.

## Rules

- **Fail loud, never guess** on the 4 judgment recipe sections and the dependency graph — they corrupt
  shared code or bypass a supply-chain gate if wrong, and the loop runs unattended.
- **Never auto-commit** anything this skill emits.
- **Never run the loop mid-extraction or with unresolved `<<FILL>>` tokens** in `plans/loop.recipes.md`
  or `plans/loop.scope.md`.
- Multi-runner needs **N distinct tracker logins** (one token per user) in the default `assignee`
  strategy. To run **N agents under ONE login**, set `CLAIM_STRATEGY=note` (github): a per-agent
  `login#RUNNER_ID` comment-marker CAS that interops with assignee runners on the same issue. Note mode
  REQUIRES a stable, distinct **`RUNNER_ID` per agent** (passed on each agent's command line, not in
  `loop.config.sh`) — ownership is identity-based, so a downed agent reups with the same id to recover
  its claim. Invariant: **a login is wholly one strategy** (mixing under one login double-builds).
  clickup has no note strategy → distinct `CLICKUP_TOKEN`s, or single-runner; say so when degrading.
