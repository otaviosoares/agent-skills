<!--
  scope.template.md — `init` copies this in as the repo's plans/loop.scope.md: the PER-WAVE scope
  (## TARGET, ## KEYSTONES) the loop-kit skeleton applies BY NAME. REWRITTEN EVERY WAVE — advancing a
  wave = bump WAVE in plans/loop.config.sh + rewrite these two sections. Fill every `<<FILL: …>>` by hand
  before a real run; the kit never auto-fills, and an unresolved section makes the loop STOP with
  LOOP_STATUS=BLOCKED. The ~stable per-repo recipes live in the sibling plans/loop.recipes.md.
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
