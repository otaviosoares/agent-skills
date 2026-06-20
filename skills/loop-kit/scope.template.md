<!--
  scope.template.md — `init` copies this in as the repo's plans/loop.scope.md. It holds the PER-WAVE
  scope (## TARGET, ## KEYSTONES) the loop-kit skeleton (loop-runbook.md, which lives IN THE SKILL and
  is symlinked into the repo) applies BY NAME. Each `## SECTION` below answers a `RECIPE → ## NAME`
  marker in the skeleton; at that marker the skeleton opens this file, finds the named section, and
  applies it VERBATIM. The driver exports this file as $LOOP_SCOPE.

  THESE ARE REWRITTEN EVERY WAVE — they are THIS wave's scope. Advancing a wave = bump WAVE in
  plans/loop.config.sh + edit ## TARGET / ## KEYSTONES here. (The ~stable per-repo recipes — CONTENTION,
  BUILD-CONSTRAINTS, REVIEW-LENSES, LAND, CI-TRUTH — live in the sibling plans/loop.recipes.md.)

  THE KIT NEVER AUTO-FILLS THESE — fail loud. Resolve every `<<FILL: … >>` token by hand before a real
  run; an unresolved section makes the skeleton STOP with `LOOP_STATUS=BLOCKED` (it never guesses).
  Search for `<<FILL` to find them.

  The scope LABEL itself is a VALUE in plans/loop.config.sh (WAVE), NOT here — this file answers "what is
  in scope and how the frontier was chosen", loop.config.sh answers "which label".
-->
# <<FILL: repo name>> — loop scope (per-wave)

## TARGET
<<FILL: the in-scope issue set for THIS wave — the WAVE scope label + how the frontier was chosen
(which deps must be closed). e.g. "all OPEN wave:1 issues whose cross-plan deps are closed in earlier
waves; N READY roots + M chained follow-ons the PICK gate serializes behind an in-wave sibling".
Note any wave-specific gotchas a builder must not get wrong (a concept that does NOT exist yet in the
foundation, a serial backbone that is intentionally deep, etc.). Rewritten every wave. >>

## KEYSTONES
<<FILL: the spine roots to build first this wave, if any (PICK prefers these among equals). e.g.
"#169 menu P1 · #170 cart P1 · #171 checkout P1". Leave "_none_" if this wave has no keystones.
Rewritten every wave. >>
