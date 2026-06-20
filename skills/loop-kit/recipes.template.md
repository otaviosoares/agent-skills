<!--
  recipes.template.md — `init` copies this in as the repo's plans/loop.recipes.md. It is the PER-REPO
  JUDGMENT the loop-kit skeleton (loop-runbook.md, which lives IN THE SKILL and is symlinked into the
  repo) applies BY NAME. Each `## SECTION` below answers a `RECIPE → ## NAME` marker in the skeleton; at
  that marker the skeleton opens this file, finds the named section, and applies it VERBATIM.

  THE KIT NEVER AUTO-FILLS THESE — fail loud. A wrong CONTENTION/LAND/CI-TRUTH/REVIEW-LENSES value
  corrupts shared code or bypasses a supply-chain gate while the loop runs UNATTENDED, so a confidently
  wrong recipe is more dangerous than a blank one. Resolve EVERY `<<FILL: … >>` token by hand before a
  real run; an unresolved section makes the skeleton STOP with `LOOP_STATUS=BLOCKED` (it never guesses).
  Search for `<<FILL` to find them.

  This file holds the ~STABLE PER-REPO recipes — ## CONTENTION, ## BUILD-CONSTRAINTS, ## REVIEW-LENSES,
  ## LAND, ## CI-TRUTH — set them once and revisit only when the repo's shape changes. The PER-WAVE
  scope (## TARGET, ## KEYSTONES, rewritten each wave) lives in the sibling plans/loop.scope.md
  (exported as $LOOP_SCOPE); advancing a wave edits THAT file, not this one.

  These are RULES, not VALUES: the scope LABEL, the run-log handle, and the branch/worktree prefix are
  values in plans/loop.config.sh (WAVE / RUNLOG / BRANCH_PREFIX), NOT here. This file answers "how",
  loop.config.sh answers "which".
-->
# <<FILL: repo name>> — loop recipes

## CONTENTION
<<FILL: which files are merge hotspots and the per-file resolution rule, plus the PICK skip key.
e.g. a shared schema file → each issue writes a NEW schema-<domain>.ts + barrel export (union-merge);
generated files (a route tree, a lockfile) → regenerate at merge; frozen package shapes → consume-only,
never edit. Name the axis the PICK step skips on: an issue whose <shared-pkg label / new-tables set>
overlaps an in-progress issue you don't own. If two in-progress issues touch the same shared file this
section names, serialize them. ~Stable per-repo. >>

## BUILD-CONSTRAINTS
<<FILL: the constraints the BUILDER sub-agent must honor, applied verbatim. e.g. where acceptance
criteria live (which plan file + section); design specs binding on UI slices (which DESIGN.md / brief,
and which surfaces need a brief before build); how new shared shapes are authored (new owned file, never
fork a frozen shape); test requirements (unit-test new pure logic); security invariants (auth/RBAC
step-up on money/impersonation); and the build-time install/lockfile command CI enforces (e.g.
`pnpm install --frozen-lockfile && typecheck && build && test`, with the supply-chain cooldown rule).
~Stable per-repo. >>

## REVIEW-LENSES
<<FILL: the domain threat model — the review lenses that matter here, applied verbatim by the REVIEWER
sub-agent. e.g. cross-tenant isolation · money/contract correctness · auth/RBAC + audit · regression/CI
· acceptance-criteria coverage · design fidelity for UI slices (hold the diff against the DESIGN.md
Do's/Don'ts + the brief; themeable tokens, no hardcoded brand, touch targets, focus, state never by
color alone). For a design finding, cite the violated rule; otherwise attach a failing-test repro.
~Stable per-repo. >>

## LAND
<<FILL: the lockfile/dependency reconcile at LAND + any supply-chain cooldown, applied verbatim.
e.g. rebase on the base branch; regenerate generated files (route trees); resolve barrels as unions;
for the lockfile DON'T re-resolve the world — take the base branch's lockfile and run a frozen install;
only on a real dep add/bump do a deliberate `--prefer-frozen-lockfile` install honoring the committed
cooldown and commit the lockfile, scoping any cooldown exclude per-package — NEVER disable the cooldown.
Name the EXACT install command CI enforces so a runner never merges a lockfile that fails it.
~Stable per-repo. >>

## CI-TRUTH
<<FILL: which checks GATE landability vs which are non-gating, applied verbatim. List the GATING checks
(re-test the specific one named on resume — e.g. the base branch's frozen-install step, typecheck,
build, test, or "commit <sha> is on the base branch") and the NON-GATING ones (a CD/deploy job that can
be structurally red for environmental reasons — a missing deploy token — that has nothing to do with
landability). Merge only on the gating checks; a structurally-red non-gating job must NOT wedge the
loop. ~Stable per-repo. >>
