#!/usr/bin/env node
// migrate.mjs — the `loop-kit migrate` engine: lift the per-repo JUDGMENT out of a STALE materialized
// runbook (the old plans/wave-loop.md, a per-repo COPY of runbook.template.md) into TWO files the
// SKELETON loop-runbook.md applies by name: plans/loop.scope.md (the 2 per-wave sections TARGET +
// KEYSTONES) and plans/loop.recipes.md (the 5 ~stable per-repo sections CONTENTION, BUILD-CONSTRAINTS,
// REVIEW-LENSES, LAND, CI-TRUTH).
//
// WHY: an earlier step split the runbook into a SKELETON (code, in the skill, symlinked) + RECIPES
// (config, in the repo); the per-wave scope was then split out into its own loop.scope.md. A repo
// onboarded BEFORE that split has its judgment baked into a wave-loop.md copy. This engine extracts that
// judgment into both files so the repo can drop the copy and point run-loop.sh at the skeleton.
//
// SAFETY RULE (mirrors materialize-plan.mjs / SKILL.md "fail loud, never guess"): a wrong
// CONTENTION/LAND/CI-TRUTH/REVIEW-LENSES recipe corrupts shared code or bypasses a supply-chain gate
// while the loop runs UNATTENDED. So this engine extracts ONLY what it can place CONFIDENTLY (a source
// section/brief maps 1:1 to a recipe slot), and for ANYTHING it can't confidently place it writes a
// `<<FILL: … >>` token AND records a loud FLAG — never a guessed value. It is NON-DESTRUCTIVE: it
// refuses to clobber an existing loop.recipes.md unless `--overwrite` is passed.
//
// It does NOT attempt to reproduce a human's EDITORIAL polish (rewrapping, merging a bullet across
// sections). It preserves the source judgment text verbatim and places it in the right slot; the human
// then reviews + polishes. The migrate is a starting point, not the final artifact.
//
//   node "$KIT"/migrate.mjs --runbook plans/wave-loop.md --out plans/loop.recipes.md \
//        --scope-out plans/loop.scope.md [--overwrite] [--repo-name <name>]
//
// CLI flags:
//   --runbook <f>     the stale materialized runbook to extract FROM (req).  alias: --from
//   --out <f>         the loop.recipes.md to write (default: <runbook dir>/loop.recipes.md)
//   --scope-out <f>   the loop.scope.md to write (default: <runbook dir>/loop.scope.md)
//   --overwrite       allow clobbering an existing --out / --scope-out file (default: refuse, exit non-zero)
//   --repo-name <n>   the repo name for the title line (default: derived from the runbook's H1, else "repo")
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, basename } from 'node:path';

function argOf(argv, ...names) {
  for (const name of names) { const i = argv.indexOf(name); if (i !== -1) return argv[i + 1]; }
  return undefined;
}
const argv = process.argv.slice(2);
const RUNBOOK = argOf(argv, '--runbook', '--from');
const OVERWRITE = argv.includes('--overwrite');
if (!RUNBOOK) {
  console.error('fail: migrate needs --runbook <stale wave-loop.md> [--out <loop.recipes.md>] [--scope-out <loop.scope.md>] [--overwrite]');
  process.exit(1);
}
if (!existsSync(RUNBOOK)) { console.error(`fail: runbook not found: ${RUNBOOK}`); process.exit(1); }
const OUT = argOf(argv, '--out') || `${dirname(RUNBOOK)}/loop.recipes.md`;
const SCOPE_OUT = argOf(argv, '--scope-out') || `${dirname(RUNBOOK)}/loop.scope.md`;

const src = readFileSync(RUNBOOK, 'utf8').replace(/\r\n?/g, '\n');
const lines = src.split('\n');

// ── slice the runbook into `## ` / `### ` sections (heading -> body lines) ────────────────────────
// A flat map keyed by the trimmed heading text; bodies are the lines up to the next heading of the
// same-or-shallower level. Good enough for the freeform prose of a materialized runbook.
function sliceSections(allLines) {
  const out = [];
  let cur = null;
  for (const l of allLines) {
    const h = l.match(/^(#{1,6})\s+(.*)$/);
    if (h) { cur = { level: h[1].length, heading: h[2].trim(), raw: l, body: [] }; out.push(cur); }
    else if (cur) cur.body.push(l);
  }
  return out;
}
const sections = sliceSections(lines);
// find a section whose heading matches a regex (case-insensitive); returns {heading, body[]} or null.
function findSection(re) {
  const s = sections.find((x) => re.test(x.heading));
  return s ? { heading: s.heading, body: s.body } : null;
}
const bodyText = (s) => (s ? s.body.join('\n').trim() : '');

// extract the H1 repo name (e.g. "# Wave Build Loop — …" → no repo; "# ezk — loop recipes" → ezk).
const h1 = sections.find((x) => x.level === 1);
const repoName =
  argOf(argv, '--repo-name') ||
  (h1 && /—/.test(h1.heading) ? h1.heading.split('—')[0].trim() : null) ||
  basename(dirname(RUNBOOK).replace(/\/plans$/, '')) ||
  'repo';

// ── pull a `- **Label:** …` bullet (possibly continued on following indented lines) out of a body ──
// Returns { text, found }. text drops the `- **Label:** ` prefix; continuation lines are joined.
function pullBullet(body, labelRe) {
  const idx = body.findIndex((l) => new RegExp(`^- \\*\\*${labelRe}`, 'i').test(l));
  if (idx === -1) return { text: '', found: false };
  let text = body[idx].replace(/^- \*\*[^*]*\*\*\s*/, '').trim();
  for (let j = idx + 1; j < body.length; j++) {
    if (/^\s*-\s/.test(body[j]) || /^#{1,6}\s/.test(body[j])) break; // next bullet / heading ends it
    if (body[j].trim() === '') break;
    text += ' ' + body[j].trim();
  }
  return { text: text.trim(), found: true };
}

const flags = []; // loud, human-facing: anything not confidently placed.
const FILL = (what) => `<<FILL: ${what} — migrate could not place this confidently from ${basename(RUNBOOK)}; resolve by hand>>`;

// ── 1. TARGET + KEYSTONES — from the "Scope" section ──────────────────────────────────────────────
const scope = findSection(/^scope\b/i);
let target, keystones;
if (!scope) {
  flags.push('No "## Scope" section found — TARGET and KEYSTONES left as FILL tokens.');
  target = FILL('the in-scope issue set for this wave');
  keystones = FILL('the spine roots to build first this wave');
} else {
  // TARGET = every Scope bullet EXCEPT the Keystones bullet (that becomes its own section) and EXCEPT
  // the design-briefs bullet (a build-time constraint — flagged + routed to BUILD-CONSTRAINTS context).
  const targetBullets = [];
  let lead = '';
  const b = scope.body;
  for (let i = 0; i < b.length; i++) {
    const l = b[i];
    if (!/^- \*\*/.test(l)) continue;
    if (/^- \*\*keystone/i.test(l)) continue;          // → KEYSTONES
    if (/^- \*\*design briefs/i.test(l)) continue;     // → BUILD-CONSTRAINTS (flagged below)
    // collect this bullet + its continuation lines verbatim.
    const block = [l];
    for (let j = i + 1; j < b.length; j++) {
      if (/^\s*-\s/.test(b[j]) || /^#{1,6}\s/.test(b[j]) || b[j].trim() === '') break;
      block.push(b[j]);
    }
    if (/^- \*\*target/i.test(l)) {
      // the Target bullet becomes the lead paragraph (drop the `- **Target:** ` label).
      lead = block.join('\n').replace(/^- \*\*[^*]*\*\*\s*/, '').trim();
    } else {
      targetBullets.push(block.join('\n'));
    }
  }
  target = [lead, '', ...targetBullets].join('\n').trim();
  if (!target) { flags.push('Scope section had no recognizable bullets — TARGET left as FILL.'); target = FILL('the in-scope issue set for this wave'); }

  const k = pullBullet(scope.body, 'keystone');
  if (k.found) keystones = k.text;
  else { keystones = '_none_'; flags.push('No Keystones bullet in Scope — KEYSTONES set to "_none_"; confirm this wave truly has none.'); }

  // the design-briefs bullet is a BUILD constraint, not scope — flag the move so the human verifies it.
  const db = pullBullet(scope.body, 'design briefs');
  if (db.found) flags.push('Scope had a "Design briefs required before build" bullet — it is a BUILD constraint, so migrate appended it to ## BUILD-CONSTRAINTS. Verify placement.');
}

// ── 2. CONTENTION — from the "shared lock" section (drop the generic per-issue-lock + dependencies bullets) ──
const lock = findSection(/shared lock/i);
let contention;
if (!lock) {
  flags.push('No "shared lock" section — CONTENTION left as FILL.');
  contention = FILL('merge hotspots + per-file resolution rule + the PICK skip key');
} else {
  // Keep the project-specific contention bullets; drop the two backend-generic bullets the SKELETON
  // already carries (the per-issue lock definition, and the "Dependencies are on the issue itself" note).
  const keep = [];
  const b = lock.body;
  for (let i = 0; i < b.length; i++) {
    const l = b[i];
    if (!/^- /.test(l)) continue;
    if (/^- \*\*per-issue lock\*\*/i.test(l)) continue;
    if (/^- \*\*dependencies are on the issue/i.test(l)) continue;
    const block = [l];
    for (let j = i + 1; j < b.length; j++) {
      if (/^\s*-\s/.test(b[j]) || /^#{1,6}\s/.test(b[j]) || b[j].trim() === '') break;
      block.push(b[j]);
    }
    keep.push(block.join('\n'));
  }
  contention = keep.join('\n').trim();
  if (!contention) { flags.push('shared-lock section had only generic bullets — CONTENTION left as FILL.'); contention = FILL('merge hotspots + per-file resolution rule + the PICK skip key'); }
}

// ── 3. BUILD-CONSTRAINTS — from the Builder sub-agent brief ───────────────────────────────────────
// The brief is a blockquote with mechanical scaffolding (track view, worktree, "Return ONLY …"). The
// per-repo JUDGMENT is the embedded constraints. Extracting just the judgment from freeform prose is
// NOT confidently mechanical, so we surface the WHOLE brief body as a starting point + flag it for a
// human trim. (Plus the design-briefs bullet pulled from Scope, if any.)
const builder = findSection(/builder sub-agent brief/i);
let buildConstraints;
if (!builder) {
  flags.push('No Builder sub-agent brief — BUILD-CONSTRAINTS left as FILL.');
  buildConstraints = FILL('build constraints: plan/acceptance source, design specs, new-shape authoring, tests, security, install/lockfile command CI enforces');
} else {
  const quote = builder.body.filter((l) => /^>/.test(l)).map((l) => l.replace(/^>\s?/, '')).join('\n').trim();
  buildConstraints = quote || FILL('the builder constraints');
  flags.push('BUILD-CONSTRAINTS was lifted from the Builder sub-agent brief VERBATIM (incl. mechanical scaffolding like `track view`/worktree/`Return ONLY`). Trim it to just the per-repo constraints — the SKELETON already carries the scaffolding.');
  const db = scope ? pullBullet(scope.body, 'design briefs') : { found: false };
  if (db.found) buildConstraints += `\n- **Design briefs:** ${db.text}`;
}

// ── 4. REVIEW-LENSES — from the Reviewer sub-agent brief ──────────────────────────────────────────
const reviewer = findSection(/reviewer sub-agent brief/i);
let reviewLenses;
if (!reviewer) {
  flags.push('No Reviewer sub-agent brief — REVIEW-LENSES left as FILL.');
  reviewLenses = FILL('the domain threat model — the review lenses that matter here');
} else {
  const quote = reviewer.body.filter((l) => /^>/.test(l)).map((l) => l.replace(/^>\s?/, '')).join('\n').trim();
  // pull the "Lenses: …" run if present; else surface the whole brief and flag.
  const m = quote.match(/Lenses?:\s*([\s\S]*?)(?:\n\s*Each finding|\n\s*\*\*Return ONLY|$)/i);
  if (m) reviewLenses = m[1].trim().replace(/\s+/g, ' ');
  else { reviewLenses = quote || FILL('the review lenses'); flags.push('Could not isolate a "Lenses:" run in the Reviewer brief — REVIEW-LENSES holds the whole brief; trim by hand.'); }
}

// ── 5. LAND — from the LAND step (step 6 of the orchestrator iteration) ───────────────────────────
// The orchestrator iteration is one section; the LAND step is a numbered item inside it. Extract the
// "6. **LAND**" item's text up to (but not including) the LAND_MODE branch bullets (those are skeleton).
const iter = findSection(/orchestrator iteration/i);
let land;
if (!iter) {
  flags.push('No orchestrator-iteration section — LAND left as FILL.');
  land = FILL('the lockfile/dependency reconcile at LAND + supply-chain cooldown + the exact install command CI enforces');
} else {
  const b = iter.body;
  const start = b.findIndex((l) => /^\d+\.\s+\*\*LAND\*\*/.test(l));
  if (start === -1) {
    flags.push('Could not find a "6. **LAND**" step in the iteration — LAND left as FILL.');
    land = FILL('the lockfile/dependency reconcile at LAND + supply-chain cooldown + the exact install command CI enforces');
  } else {
    const acc = [b[start]];
    for (let j = start + 1; j < b.length; j++) {
      if (/^\d+\.\s+\*\*/.test(b[j])) break;     // next numbered step ends LAND
      if (/^\s*-\s+\*\*`?merge/i.test(b[j])) break; // the LAND_MODE merge/pr branch is skeleton, not recipe
      acc.push(b[j]);
    }
    // drop the leading "6. **LAND** — in the worktree:" scaffolding lead-in, keep the recipe judgment.
    land = acc.join('\n').replace(/^\d+\.\s+\*\*LAND\*\*\s*—?\s*/, '').trim();
    flags.push('LAND was extracted from iteration step 6 up to the LAND_MODE branch. It may include the generic "rebase on the base branch / Once CI is green …" lead-in — trim to the repo-specific lockfile/cooldown recipe.');
  }
}

// ── 6. CI-TRUTH — gating vs non-gating. The most safety-critical, and the HARDEST to place: in a
// materialized runbook it is woven into RECONCILE (1b-a) and/or the Safety rails, not a clean block. We
// look for an explicit carve-out; if we can't isolate one confidently, we FAIL LOUD with a FILL token. ──
const safety = findSection(/safety rails/i);
let ciTruth;
const ciCandidates = [];
if (iter) ciCandidates.push(bodyText(iter));
if (safety) ciCandidates.push(bodyText(safety));
const ciHay = ciCandidates.join('\n');
const ciLine = ciHay.split('\n').find((l) => /CI truth|non-gating|structurally-red|deploy.*token|gating/i.test(l));
if (ciLine && /non-gating|structurally-red|gating/i.test(ciLine)) {
  // we found a sentence that talks about gating vs non-gating; surface it but flag for verification —
  // this is the one section where a confident-but-wrong value is most dangerous.
  ciTruth = ciLine.replace(/^\s*-\s*\*\*[^*]*\*\*\s*/, '').replace(/^\s*-\s*/, '').trim();
  flags.push('CI-TRUTH: migrate found a gating/non-gating sentence but this is the MOST safety-critical recipe — re-derive the exact GATING checks vs the structurally-red CD/deploy job by hand and confirm, do NOT trust the auto-extract.');
} else {
  flags.push('CI-TRUTH: could not isolate a gating-vs-non-gating carve-out — left as FILL (this is the most dangerous slot to guess).');
  ciTruth = FILL('which checks GATE landability vs which are non-gating (a structurally-red CD/deploy job that must NOT wedge the loop)');
}

// ── assemble loop.scope.md (the 2 per-wave sections) ────────────────────────────────────────────────
const scopeHeader = `<!--
  loop.scope.md — the PER-WAVE scope the loop-kit skeleton (loop-runbook.md, in the skill) applies by
  name (exported as \$LOOP_SCOPE). \`## TARGET\` / \`## KEYSTONES\` answer a RECIPE → marker in the
  skeleton. REWRITTEN EVERY WAVE: advancing a wave = bump WAVE in plans/loop.config.sh + edit these two
  sections. The kit NEVER auto-fills these — fail loud; resolve every \`<<FILL>>\` before a real run.

  The ~stable per-repo recipes (## CONTENTION, ## BUILD-CONSTRAINTS, ## REVIEW-LENSES, ## LAND,
  ## CI-TRUTH) live in the sibling plans/loop.recipes.md. The scope LABEL itself is a VALUE in
  plans/loop.config.sh (WAVE), not here.

  [MIGRATED from ${basename(RUNBOOK)} by loop-kit migrate. REVIEW EVERY SECTION before a real run — see
   the migration FLAGS printed to stderr; some content was lifted verbatim and needs trimming.]
-->`;
const scopeOut = `${scopeHeader}
# ${repoName} — loop scope (per-wave)

## TARGET
${target}

## KEYSTONES
${keystones}
`;

// ── assemble loop.recipes.md (the 5 ~stable per-repo sections) ──────────────────────────────────────
const header = `<!--
  loop.recipes.md — the ~STABLE PER-REPO judgment the loop-kit skeleton (loop-runbook.md, in the skill)
  applies by name. Each \`## SECTION\` answers a RECIPE → marker in the skeleton. Small, hand-authored,
  fail-loud: the kit NEVER auto-fills these — a wrong value corrupts shared code or bypasses a
  supply-chain gate while the loop runs UNATTENDED. Resolve every \`<<FILL>>\` before a real run.

  The PER-WAVE scope (## TARGET, ## KEYSTONES — rewritten each wave) lives in the sibling
  plans/loop.scope.md. Scope label + run-log handle + branch prefix are VALUES → plans/loop.config.sh.

  [MIGRATED from ${basename(RUNBOOK)} by loop-kit migrate. REVIEW EVERY SECTION before a real run — see
   the migration FLAGS printed to stderr; some content was lifted verbatim and needs trimming.]
-->`;
const out = `${header}
# ${repoName} — loop recipes

## CONTENTION
${contention}

## BUILD-CONSTRAINTS
${buildConstraints}

## REVIEW-LENSES
${reviewLenses}

## LAND
${land}

## CI-TRUTH
${ciTruth}
`;

// ── non-destructive write (BOTH outputs refuse to clobber without --overwrite) ───────────────────────
for (const f of [OUT, SCOPE_OUT]) {
  if (existsSync(f) && !OVERWRITE) {
    console.error(`✋ refusing to clobber existing ${f} (pass --overwrite to replace it).`);
    process.exit(1);
  }
}
writeFileSync(SCOPE_OUT, scopeOut);
writeFileSync(OUT, out);
console.log(`migrated ${RUNBOOK} -> ${SCOPE_OUT} + ${OUT} (${repoName})`);
console.log('\nRun-loop change needed: point this repo at the SKELETON. `./plans/run-loop.sh` now');
console.log('defaults RUNBOOK to the kit\'s loop-runbook.md, so just drop the runbook arg:');
console.log('  ./plans/run-loop.sh            # was: ./plans/run-loop.sh plans/wave-loop.md');
console.log('Then DELETE the stale plans/wave-loop.md (the skeleton + loop.scope.md + loop.recipes.md replace it).');

if (flags.length) {
  console.error(`\n⚠ ${flags.length} migration FLAG(S) — each needs a human pass before a real run:`);
  for (const f of flags) console.error(`   • ${f}`);
  // exit non-zero when any section in EITHER output was left as a FILL token (a hard, unresolved gap);
  // a "verify this" flag on extracted content is a warning, not a failure.
  const hasFill = /<<FILL/.test(out) || /<<FILL/.test(scopeOut);
  if (hasFill) {
    console.error('\n✋ At least one section is an unresolved <<FILL>> token — the loop must NOT run until every one is filled.');
    process.exit(2);
  }
  process.exit(0);
}
console.log('\nNo flags — but still REVIEW the result; migrate extracts, it does not author judgment.');
