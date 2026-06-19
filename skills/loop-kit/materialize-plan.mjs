#!/usr/bin/env node
// materialize-plan.mjs — the `loop-kit plan` engine: the missing init->materialize bridge.
//
// The producer (materialize-{github,gitlab,clickup}.mjs) stands up a scope's issues on the tracker
// from a DATA DIR (issues-open.json + bodies/*.md + milestones.json + created-issues.tsv). But nothing
// owned the step BEFORE that: turning a project into that data dir, by hand, in raw JSON with detached
// markdown bodies and a fistful of implicit invariants (slug==bodyFile, every milestone resolves, the
// scope label is present, deps form a DAG). That hand-authoring is the toil; the invariants are the
// footguns — most cruelly, the producer's DRY mode never reads bodies/*.md at all, so a typo'd bodyFile
// sails through DRY clean and only detonates mid-DRY=0 on a LIVE tracker.
//
// This engine fixes both, in three offline, zero-dependency modes:
//
//   scaffold  — lay down a friendly SOURCE TREE (one markdown-with-frontmatter file per issue, deps a
//               typed list, body co-located) for a human to author. Non-destructive. The slug is the
//               FILENAME, so the slug<->bodyFile footgun is impossible by construction.
//   compile   — deterministically lower the source tree into the EXACT existing producer contract
//               (issues-open.json + bodies/<slug>.md + milestones.json), byte-compatible downstream:
//               materialize-core/github/gitlab/clickup and the runtime loop change ZERO lines. The
//               body's `## Dependencies` section is RENDERED from the typed deps (the prose the runtime
//               PICK step already keys on) — rendered, never authored.
//   check     — a complete, read-only validator over a producer --root dir (compiled OR hand-authored):
//               accumulate EVERY violation (never fail-on-first), exit non-zero with a grouped report.
//               Wired as a BLOCKING precondition on `materialize` before DRY=0.
//
// SAFETY RULE (mirrors SKILL.md "What this skill does NOT do"): this engine FACILITATES human judgment,
// it never FABRICATES it. scaffold writes `<<FILL: … >>` tokens for Goal / Acceptance criteria (the same
// fail-loud stance the runbook uses for its 4 judgment blocks) and NEVER infers a dependency edge from
// title similarity, file overlap, or ordering — the human names every edge or there is no edge. compile
// REFUSES to lower a body that still carries a `<<FILL>>` token or is empty. check reports a dependency
// CYCLE but never picks which edge to cut. No mode mutates the tracker; `materialize` (DRY=0) stays the
// only human-gated mutation.
//
//   # source plans/loop.config.sh first (TRACKER_BACKEND; clickup still DECLARES milestones — the core
//   # resolves every milestone title for all backends, the clickup backend just no-ops ensureMilestones).
//   node "$KIT"/materialize-plan.mjs scaffold --root plans/.tracker [--scope wave:1] [--slug auth-login ...]
//   node "$KIT"/materialize-plan.mjs compile  --src  plans/.tracker/src --out plans/.tracker
//   node "$KIT"/materialize-plan.mjs check    --root plans/.tracker [--scope wave:1] [--batch-data <f>.json]
//
// CLI: first positional arg is the mode. Flags mirror the materialize-*.mjs surface:
//   --root <dir>        producer data dir (check / scaffold out). Default src lives at <root>/src.
//   --src  <dir>        source tree (compile in).  Default <root>/src.
//   --out  <dir>        producer dir to write (compile out). Default <root>.
//   --scope <label>     scope label to sanity-check membership against (optional).
//   --batch-data <f>    a waves/<scope>.json { scope, labelFixes } whose labelFixes.only slugs are checked.
//   --slug/-title/-milestone/-labels/-deps   scaffold: seed one issue stub (labels/deps are comma lists).
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';

// ── tiny arg parser (mirrors materialize-github.mjs argOf) ──────────────────────────────────────
function argOf(argv, name) {
  const i = argv.indexOf(name);
  return i === -1 ? undefined : argv[i + 1];
}
const argv = process.argv.slice(2);
const MODE = argv[0];
const BACKEND = process.env.TRACKER_BACKEND || 'github';

// ── the producer's EXACT rules, reused verbatim so plan and producer can never disagree ─────────
// (kept in lockstep with materialize-core.mjs: slug derivation + scope membership.)
const slugOfBodyFile = (bodyFile) => bodyFile.replace('bodies/', '').replace('.md', '');

// ── a deliberately tiny, fail-loud frontmatter + flat-YAML reader (scalars + string lists only) ──
// Refuses anything richer than `key: scalar` / `key: [a, b]` / a `key:` block list of `- item`s, and
// a milestones block sequence of `- title:`/`  description:` maps. Anything else => a loud violation,
// never a silent mis-parse. This is the only genuinely-new risk surface, so it stays small + strict.
function splitFrontmatter(text, file, v) {
  const lines = text.replace(/\r\n?/g, '\n').split('\n'); // normalize CRLF/CR first
  if (lines[0].trim() !== '---') {
    v.push({ cat: 'source', file, msg: 'no YAML frontmatter (file must start with a `---` fence)', hint: 'add a frontmatter block with title/labels/milestone/deps' });
    return { meta: {}, body: text };
  }
  let end = -1;
  for (let i = 1; i < lines.length; i++) { if (lines[i].trim() === '---') { end = i; break; } } // closing fence = a `---` LINE
  if (end === -1) {
    v.push({ cat: 'source', file, msg: 'unterminated frontmatter (missing closing `---`)', hint: 'close the frontmatter with a line containing only `---`' });
    return { meta: {}, body: '' };
  }
  return { meta: parseFlatYaml(lines.slice(1, end).join('\n'), file, v), body: lines.slice(end + 1).join('\n') };
}
function stripQuotes(s) {
  const t = s.trim();
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) return t.slice(1, -1);
  return t;
}
// Split a flow list's inner text on TOP-LEVEL commas only (a comma inside "…"/'…' stays put), so
// `["needs: triage, design", wave:1]` yields two items, not three.
function splitTopComma(s) {
  const out = [];
  let cur = '';
  let q = null;
  for (const ch of s) {
    if (q) { cur += ch; if (ch === q) q = null; }
    else if (ch === '"' || ch === "'") { q = ch; cur += ch; }
    else if (ch === ',') { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out.map((x) => stripQuotes(x)).filter((x) => x !== '');
}
function parseFlatYaml(text, file, v) {
  const meta = {};
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const m = line.match(/^(\w[\w-]*):\s*(.*)$/);
    if (!m) {
      // a bare `  - item` is consumed by a preceding block-list key; anything else is unexpected.
      if (/^\s*-\s+/.test(line)) continue;
      v.push({ cat: 'source', file, msg: `unparseable frontmatter line: ${JSON.stringify(line)}`, hint: 'use `key: value` or `key: [a, b]` (scalars + flat string lists only)' });
      continue;
    }
    const key = m[1];
    const rest = m[2].trim();
    if (rest === '') {
      // either an empty scalar or the head of a block list (`key:` then `  - item` lines).
      const items = [];
      let j = i + 1;
      while (j < lines.length && /^\s*-\s+/.test(lines[j])) {
        items.push(stripQuotes(lines[j].replace(/^\s*-\s+/, '')));
        j++;
      }
      meta[key] = items.length ? items : '';
      i = j - 1;
    } else if (rest.startsWith('[') && rest.endsWith(']')) {
      meta[key] = splitTopComma(rest.slice(1, -1));
    } else {
      meta[key] = stripQuotes(rest);
    }
  }
  return meta;
}
function parseMilestonesYaml(text, file, v) {
  const out = [];
  let cur = null;
  for (const raw of text.replace(/\r\n?/g, '\n').split('\n')) {
    if (!raw.trim() || raw.trim().startsWith('#')) continue;
    const head = raw.match(/^-\s+title:\s*(.+)$/);
    if (head) {
      cur = { title: stripQuotes(head[1]), description: '' };
      out.push(cur);
      continue;
    }
    const desc = raw.match(/^\s+description:\s*(.+)$/);
    if (desc && cur) {
      cur.description = stripQuotes(desc[1]);
      continue;
    }
    v.push({ cat: 'milestones', file, msg: `unparseable milestones line: ${JSON.stringify(raw)}`, hint: 'each entry is `- title: X` then `  description: Y` (title/description only)' });
  }
  return out;
}

// ── the rendered `## Dependencies` block — the SINGLE contract shared with the runtime PICK step ──
// The runbook's PICK step parses an issue body's `## Dependencies` section (track view N) and gates on
// each dep being closed. compile RENDERS this section from the typed deps; check PARSES it back. Pin the
// exact shape here so the writer and the runtime reader can never diverge.
const DEPS_HEADING = '## Dependencies';
function renderDepsSection(deps, bySlug) {
  if (!deps.length) return `${DEPS_HEADING}\n- _none_\n`;
  const lines = deps.map((d) => `- ${bySlug.get(d)?.title ?? d} (\`${d}\`)`);
  return `${DEPS_HEADING}\n${lines.join('\n')}\n`;
}
function parseDepsSection(body) {
  // Returns the list of referenced tokens, inverse of renderDepsSection. Recovery order:
  //   1. the TRAILING `(`slug`)` group renderDepsSection writes — preferred, so a backtick span inside
  //      the dep's TITLE (e.g. "Use the `useState` hook") can't be mistaken for the slug.
  //   2. any other `…` span (lenient for hand-authored bodies that wrote just a backtick slug).
  //   3. the raw item text (a bare title, or a `#N` cross-wave id ref).
  const lines = body.replace(/\r\n?/g, '\n').split('\n');
  const start = lines.findIndex((l) => l.trim().toLowerCase() === DEPS_HEADING.toLowerCase());
  if (start === -1) return [];
  const refs = [];
  for (let i = start + 1; i < lines.length; i++) {
    const l = lines[i];
    if (/^#{1,6}\s/.test(l)) break; // next heading ends the section
    const item = l.match(/^\s*-\s+(.*)$/);
    if (!item) continue;
    const text = item[1].trim();
    if (!text || /^_?none_?$/i.test(text)) continue;
    const trailing = text.match(/\(`([^`]+)`\)\s*$/);
    const anyTick = text.match(/`([^`]+)`/);
    refs.push(trailing ? trailing[1] : anyTick ? anyTick[1] : text);
  }
  return refs;
}

// ── normalized dataset model (both loaders produce this; ONE validator consumes it) ──────────────
//   issues: [{ slug, title, labels:[], milestone, bodyText, bodyMissing, deps:[ref], origin }]
//   milestoneTitles: Set<string>;  hasCreatedTsv: bool;  loadErrors: [violation]
function loadProducerDataset(root) {
  const v = [];
  let issuesRaw;
  try {
    issuesRaw = JSON.parse(readFileSync(`${root}/issues-open.json`, 'utf8'));
  } catch (e) {
    v.push({ cat: 'contract', file: `${root}/issues-open.json`, msg: `missing/malformed: ${e.message}`, hint: 'compile from a source tree, or fix the JSON' });
    return { issues: [], milestoneTitles: new Set(), milestones: [], hasCreatedTsv: false, loadErrors: v };
  }
  if (!Array.isArray(issuesRaw)) {
    v.push({ cat: 'contract', file: `${root}/issues-open.json`, msg: `must be a JSON array, got ${typeof issuesRaw}`, hint: 'the producer reads issues-open.json as an array of issue objects' });
    return { issues: [], milestoneTitles: new Set(), milestones: [], hasCreatedTsv: false, loadErrors: v };
  }
  let milestoneTitles = new Set();
  let milestones = [];
  try {
    milestones = JSON.parse(readFileSync(`${root}/milestones.json`, 'utf8'));
    milestoneTitles = new Set(milestones.map((m) => m.title));
  } catch (e) {
    v.push({ cat: 'milestones', file: `${root}/milestones.json`, msg: `missing/malformed: ${e.message}`, hint: 'every issue.milestone must resolve here (all backends; clickup no-ops it but core still requires it)' });
  }
  const hasCreatedTsv = existsSync(`${root}/created-issues.tsv`);
  if (!hasCreatedTsv) {
    v.push({ cat: 'contract', file: `${root}/created-issues.tsv`, msg: 'missing dedupe ledger', hint: 'create an empty file (the producer appends url<TAB>title and reads it on every run)' });
  }
  const issues = issuesRaw.map((it) => {
    const slug = it.bodyFile ? slugOfBodyFile(it.bodyFile) : '(no bodyFile)';
    let bodyText = '';
    let bodyMissing = false;
    try {
      bodyText = readFileSync(`${root}/${it.bodyFile}`, 'utf8');
    } catch {
      bodyMissing = true; // THE DRY FOOTGUN: producer DRY never reads bodies, so it never catches this.
    }
    return { slug, title: it.title, labels: it.labels || [], milestone: it.milestone, bodyText, bodyMissing, deps: parseDepsSection(bodyText), origin: it.bodyFile };
  });
  return { issues, milestoneTitles, milestones, hasCreatedTsv, loadErrors: v };
}
function loadSourceDataset(src) {
  const v = [];
  const issueDir = `${src}/issue`;
  if (!existsSync(issueDir)) {
    v.push({ cat: 'source', file: issueDir, msg: 'no issue/ directory in the source tree', hint: 'run `scaffold` first, or create src/issue/<slug>.md files' });
    return { issues: [], milestoneTitles: new Set(), milestones: [], hasCreatedTsv: true, loadErrors: v };
  }
  const files = readdirSync(issueDir).filter((f) => f.endsWith('.md')).sort();
  const issues = files.map((f) => {
    const slug = f.replace(/\.md$/, '');
    const { meta, body } = splitFrontmatter(readFileSync(`${issueDir}/${f}`, 'utf8'), `${issueDir}/${f}`, v);
    const labels = Array.isArray(meta.labels) ? meta.labels : meta.labels ? [meta.labels] : [];
    const deps = Array.isArray(meta.deps) ? meta.deps : meta.deps ? [meta.deps] : [];
    return { slug, title: meta.title || '', labels, milestone: meta.milestone || '', bodyText: body, bodyMissing: false, deps, origin: `${issueDir}/${f}`, body, file: `${issueDir}/${f}` };
  });
  let milestones = [];
  const myml = `${src}/milestones.yml`;
  if (existsSync(myml)) milestones = parseMilestonesYaml(readFileSync(myml, 'utf8'), myml, v);
  else v.push({ cat: 'milestones', file: myml, msg: 'missing src/milestones.yml', hint: 'declare each milestone as `- title: X` / `  description: Y`' });
  return { issues, milestoneTitles: new Set(milestones.map((m) => m.title)), milestones, hasCreatedTsv: true, loadErrors: v };
}

// An unresolved judgment token in ANY field (not just the body) must never reach the tracker — a
// `<<FILL>>` milestone/title/label would otherwise be created verbatim. Broad + case-insensitive +
// matches a bare `<<FILL>>` with no colon.
const FILL_RE = /<<\s*fill\b/i;
const hasFill = (x) => typeof x === 'string' && FILL_RE.test(x);

// ── the ONE validator: accumulate EVERY violation, never fail-on-first ───────────────────────────
function validate(ds, { scope, labelFixes, sourceMode } = {}) {
  const v = [...ds.loadErrors];
  const bySlug = new Map();
  const byTitle = new Map();
  const lowerSlugs = new Map();
  for (const it of ds.issues) {
    // (b) slug uniqueness incl. macOS case-fold.
    const lc = it.slug.toLowerCase();
    if (lowerSlugs.has(lc)) v.push({ cat: 'slug', file: it.origin, msg: `duplicate slug (case-fold) "${it.slug}" vs "${lowerSlugs.get(lc)}"`, hint: 'rename one issue file/bodyFile — slugs must be unique case-insensitively' });
    lowerSlugs.set(lc, it.slug);
    bySlug.set(it.slug, it);
    if (typeof it.title === 'string' && it.title) byTitle.set(it.title, it);
  }
  for (const it of ds.issues) {
    // title must be a non-empty SCALAR — a bracketed value like `title: [x]` parses to a list and would
    // otherwise be emitted as a JSON array into issues-open.json.
    if (typeof it.title !== 'string' || !it.title.trim()) v.push({ cat: 'issue', file: it.origin, msg: 'missing or non-scalar title', hint: 'set a string `title:` (quote it if it contains `[ ]`, `:` or `#`)' });
    if (it.milestone !== undefined && it.milestone !== '' && typeof it.milestone !== 'string') v.push({ cat: 'milestone', file: it.origin, msg: 'milestone must be a scalar', hint: 'quote a milestone value containing `[ ]`' });
    // (a) body present + non-empty — THE DRY FOOTGUN for producer dirs.
    if (it.bodyMissing) v.push({ cat: 'body', file: it.origin, msg: `bodyFile does not exist: ${it.origin}`, hint: 'the producer DRY run never reads bodies, so this only fails at DRY=0 on the live tracker — fix the path now' });
    else if (!it.bodyText.trim()) v.push({ cat: 'body', file: it.origin, msg: 'empty body', hint: 'every issue needs a Goal + Acceptance criteria' });
    // never ship an unresolved judgment token — scan EVERY field, not just the body.
    if (hasFill(it.bodyText) || hasFill(it.title) || hasFill(it.milestone) || it.labels.some(hasFill) || it.deps.some(hasFill))
      v.push({ cat: 'fill', file: it.origin, msg: 'unresolved <<FILL>> token (body, title, milestone, labels, or deps)', hint: 'a human must resolve every <<FILL>> before push — it would be created verbatim on the tracker' });
    // (f) >=1 label, scope present.
    if (!it.labels.length) v.push({ cat: 'label', file: it.origin, msg: 'no labels', hint: 'every issue needs >=1 label incl. its scope label (e.g. wave:1)' });
    if (scope && !it.labels.includes(scope)) v.push({ cat: 'scope', file: it.origin, msg: `does not carry scope label "${scope}"`, hint: `add "${scope}" to labels, or it will never be selected by the producer/runtime` });
    // (c) milestone resolves — uniform across backends (materialize-core resolves it for all).
    if (BACKEND !== 'clickup' || it.milestone) {
      if (!it.milestone) v.push({ cat: 'milestone', file: it.origin, msg: 'no milestone', hint: 'set `milestone:` (the producer resolves every milestone title)' });
      else if (!ds.milestoneTitles.has(it.milestone)) v.push({ cat: 'milestone', file: it.origin, msg: `milestone "${it.milestone}" not declared`, hint: 'add it to src/milestones.yml (compile) or milestones.json' });
    }
    // source bodies must NOT hand-author the Dependencies section — compile owns it.
    if (sourceMode && new RegExp(`^${DEPS_HEADING}`, 'mi').test(it.bodyText)) v.push({ cat: 'deps', file: it.origin, msg: 'source body contains a `## Dependencies` section', hint: 'remove it — deps come from the frontmatter `deps:` list; compile renders the section' });
  }
  // (d) deps resolve; (e) DAG.
  const edges = new Map(); // slug -> [depSlug]
  for (const it of ds.issues) {
    const resolved = [];
    for (const ref of it.deps) {
      if (/^#\d+$/.test(ref)) continue; // cross-wave id ref to an already-created issue — external, OK.
      const hit = bySlug.get(ref) || byTitle.get(ref);
      if (!hit) v.push({ cat: 'deps', file: it.origin, msg: `dependency "${ref}" resolves to no issue in this set`, hint: 'fix the slug/title, or use `#N` for a dep already created in an earlier wave' });
      else resolved.push(hit.slug);
    }
    edges.set(it.slug, resolved);
  }
  const cycle = findCycle(edges);
  if (cycle) v.push({ cat: 'cycle', file: '(dependency graph)', msg: `dependency cycle: ${cycle.join(' -> ')}`, hint: 'break the cycle by removing one edge — the validator will not choose which (human judgment)' });
  // milestone declarations must not carry an unresolved token either (the scaffold seeds a FILL stub).
  for (const m of ds.milestones || []) {
    if (hasFill(m.title) || hasFill(m.description)) v.push({ cat: 'fill', file: 'milestones', msg: `unresolved <<FILL>> token in milestone "${m.title}"`, hint: 'name the milestone before push — it would be created verbatim on the tracker' });
  }
  // (g) labelFixes.only slugs resolve.
  for (const fix of labelFixes || []) {
    for (const s of fix.only || []) {
      if (!bySlug.has(s)) v.push({ cat: 'labelfix', file: '(batch-data)', msg: `labelFixes "${fix.label}" only:[…] references unknown slug "${s}"`, hint: 'this is a silent no-op in the producer — fix the slug or drop it' });
    }
  }
  return { v, count: ds.issues.length, scopes: new Set(ds.issues.flatMap((i) => i.labels.filter((l) => l.includes(':')))).size };
}
function findCycle(edges) {
  const WHITE = 0, GRAY = 1, BLACK = 2;
  const color = new Map();
  const stack = [];
  let found = null;
  function dfs(n) {
    if (found) return;
    color.set(n, GRAY);
    stack.push(n);
    for (const d of edges.get(n) || []) {
      if (!edges.has(d)) continue;
      const c = color.get(d) || WHITE;
      if (c === GRAY) { found = [...stack.slice(stack.indexOf(d)), d]; return; }
      if (c === WHITE) { dfs(d); if (found) return; }
    }
    stack.pop();
    color.set(n, BLACK);
  }
  for (const n of edges.keys()) { if ((color.get(n) || WHITE) === WHITE) dfs(n); if (found) break; }
  return found;
}

// ── report ───────────────────────────────────────────────────────────────────────────────────────
function report(result, label) {
  const { v } = result;
  if (!v.length) {
    console.log(`check OK (${label}): ${result.count} issues, ${result.scopes} distinct labels, 0 violations`);
    return 0;
  }
  const groups = {};
  for (const x of v) (groups[x.cat] ||= []).push(x);
  console.error(`check FAILED (${label}): ${v.length} violation(s)\n`);
  for (const [cat, items] of Object.entries(groups)) {
    console.error(`▶ ${cat} (${items.length})`);
    for (const it of items) {
      console.error(`   ${it.file}\n     ${it.msg}\n     fix: ${it.hint}`);
    }
    console.error('');
  }
  return 1;
}

// ── modes ────────────────────────────────────────────────────────────────────────────────────────
function doCheck() {
  const root = argOf(argv, '--root') || process.env.MATERIALIZE_ROOT;
  if (!root) { console.error('fail: check needs --root <producer data dir>'); process.exit(1); }
  const scope = argOf(argv, '--scope');
  let labelFixes = [];
  const batch = argOf(argv, '--batch-data');
  if (batch) { try { labelFixes = JSON.parse(readFileSync(batch, 'utf8')).labelFixes || []; } catch (e) { console.error(`fail: --batch-data unreadable: ${e.message}`); process.exit(1); } }
  const ds = loadProducerDataset(root);
  process.exit(report(validate(ds, { scope, labelFixes }), root));
}

function doCompile() {
  const root = argOf(argv, '--root') || process.env.MATERIALIZE_ROOT;
  const src = argOf(argv, '--src') || (root ? `${root}/src` : undefined);
  const out = argOf(argv, '--out') || root;
  if (!src || !out) { console.error('fail: compile needs --src <source tree> and --out <producer dir> (or --root for both)'); process.exit(1); }
  if (resolve(src) === resolve(out)) { console.error('fail: --src and --out must differ (compile would overwrite the source)'); process.exit(1); }
  const ds = loadSourceDataset(src);
  // Validate the SOURCE before writing — never leave a dirty producer dir.
  const result = validate(ds, { scope: argOf(argv, '--scope'), sourceMode: true });
  if (result.v.length) { report(result, src); console.error('compile aborted: fix the source violations above first.'); process.exit(1); }

  const bySlug = new Map(ds.issues.map((it) => [it.slug, it]));
  mkdirSync(`${out}/bodies`, { recursive: true });
  const issuesOpen = [];
  for (const it of ds.issues) {
    const bodyFile = `bodies/${it.slug}.md`;
    const rendered = `${it.bodyText.trimEnd()}\n\n${renderDepsSection(it.deps, bySlug)}`;
    writeFileSync(`${out}/${bodyFile}`, rendered);
    issuesOpen.push({ title: it.title, labels: it.labels, milestone: it.milestone, bodyFile });
  }
  writeFileSync(`${out}/issues-open.json`, JSON.stringify(issuesOpen, null, 2) + '\n');
  writeFileSync(`${out}/milestones.json`, JSON.stringify(ds.milestones, null, 2) + '\n');
  // created-issues.tsv is the live dedupe ledger: create-if-absent ONLY, never clobber.
  if (!existsSync(`${out}/created-issues.tsv`)) writeFileSync(`${out}/created-issues.tsv`, '');
  // A prior compile may have left a body whose source file was since renamed/removed. The producer
  // ignores unreferenced bodies (no corruption), but warn so the dir doesn't silently accrete stale
  // files — don't auto-delete (they could be a hand-authored body the user still wants).
  const referenced = new Set(issuesOpen.map((i) => i.bodyFile.replace('bodies/', '')));
  for (const f of readdirSync(`${out}/bodies`)) {
    if (f.endsWith('.md') && !referenced.has(f)) console.error(`warning: orphaned body ${out}/bodies/${f} — no issue references it (source renamed/removed?). Remove it by hand if stale.`);
  }
  console.log(`compiled ${issuesOpen.length} issues -> ${out}/issues-open.json + ${out}/bodies/ + ${out}/milestones.json`);

  // Re-check the GENERATED producer dir so compile can never leave a dirty result.
  const post = validate(loadProducerDataset(out), { scope: argOf(argv, '--scope') });
  process.exit(report(post, out));
}

function doScaffold() {
  const root = argOf(argv, '--root') || process.env.MATERIALIZE_ROOT;
  if (!root) { console.error('fail: scaffold needs --root <data dir> (the source tree is written to <root>/src)'); process.exit(1); }
  const src = `${root}/src`;
  mkdirSync(`${src}/issue`, { recursive: true });
  let wrote = [];
  const myml = `${src}/milestones.yml`;
  if (!existsSync(myml)) {
    writeFileSync(myml, '# Declare every milestone an issue references. title/description only.\n- title: <<FILL: milestone name>>\n  description: <<FILL: one line>>\n');
    wrote.push(myml);
  }
  const slug = argOf(argv, '--slug');
  if (slug) {
    const f = `${src}/issue/${slug}.md`;
    if (existsSync(f)) { console.error(`kept existing ${f}`); }
    else {
      const scope = argOf(argv, '--scope') || process.env.WAVE || 'wave:1';
      const title = argOf(argv, '--title') || `<<FILL: title for ${slug}>>`;
      const milestone = argOf(argv, '--milestone') || '<<FILL: milestone>>';
      const labels = (argOf(argv, '--labels') || `${scope}, size:M`).split(',').map((s) => s.trim()).filter(Boolean);
      const deps = (argOf(argv, '--deps') || '').split(',').map((s) => s.trim()).filter(Boolean);
      const fm = [
        '---',
        `title: ${title}`,
        `labels: [${labels.join(', ')}]`,
        `milestone: ${milestone}`,
        `deps: [${deps.join(', ')}]`,
        '---',
        '## Goal',
        '<<FILL: goal — one or two sentences>>',
        '',
        '## Acceptance criteria',
        '- [ ] <<FILL: a concrete, checkable criterion>>',
        '',
      ].join('\n');
      writeFileSync(f, fm);
      wrote.push(f);
    }
  }
  if (wrote.length) console.log('scaffolded:\n' + wrote.map((w) => '  ' + w).join('\n'));
  else console.log(`source tree present at ${src} (nothing to scaffold; pass --slug to add an issue stub)`);
  console.log('\nNext: fill the <<FILL>> tokens + name deps, then `compile`, then `check`.');
}

switch (MODE) {
  case 'scaffold': doScaffold(); break;
  case 'compile': doCompile(); break;
  case 'check': doCheck(); break;
  default:
    console.error('usage: materialize-plan.mjs <scaffold|compile|check> [flags]');
    console.error('  scaffold --root <dir> [--scope wave:1] [--slug <s> --title <t> --milestone <m> --labels a,b --deps x,y]');
    console.error('  compile  --src <dir> --out <dir>   (or --root for <root>/src -> <root>)');
    console.error('  check    --root <dir> [--scope <label>] [--batch-data <waves/scope.json>]');
    process.exit(1);
}
