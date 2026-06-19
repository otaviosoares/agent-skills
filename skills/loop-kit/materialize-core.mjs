// materialize-core.mjs — the scope-/backend-agnostic producer machine.
//
// Generalizes the (~95% identical) create-wave3.mjs / create-wave4.mjs clones into ONE machine.
// The per-wave (now per-SCOPE) judgment lives entirely in DATA — a backlog file like
// <root>/waves/wave<N>.json shaped { scope, labelFixes } — and the create→label→(board)→dedupe
// pipeline is driven through a pluggable `backend`. This file is OFFLINE + backend-agnostic and
// carries no EZK paths/repo: the only membership axis is a `scope` label.
//
// ONE accepted residual (see step 7): core parses a fixed set of board-field label prefixes
// (`wave:` / `size:` / `shared-pkg:`) to derive the optional values fed to the WET-only
// `placeOnBoard` hook. A project using other conventions gets empty values and simply skips that
// hook (DRY output + the gitlab backend are unaffected). Lifting these prefixes into a data-driven
// `boardFields` option is deferred until a second project with different conventions onboards.
//
// SCOPE replaces the old hardcoded "wave" axis. `scope` is just the label issues are filtered on
// (EZK passes "wave:N"; any project can pass any label). There is no "wave file" lookup any more —
// the caller hands `scope` + `labelFixes` directly (typically read from a backlog JSON by the CLI).
//
// labelFixes is the GENERALIZED form of the clones' "two fixes". Each entry is
//   { label: <string>, only: [<slug>...] }
// meaning "this label must appear ONLY on the listed slugs": for every selected issue REMOVE
// `label`, then RE-ADD it iff the issue's slug is in `only`. Fixes apply in array order. This
// reproduces the clones EXACTLY — they stripped `keystone` + `blocked-on-oq` from all issues, then
// re-added `keystone` to the keystone set and `blocked-on-oq` to the oqGated set — now expressed as
// two labelFixes entries (keystone→only:[keystones], blocked-on-oq→only:[oqGated]; an empty `only`
// means strip-from-all + re-add-to-none, e.g. wave 3's blocked-on-oq).
//
// BACKEND INTERFACE
//   {
//     name: String,
//     // OPTIONAL. Called ONCE up front in WET mode with the distinct milestones the plan
//     // references (each {title, description} looked up in <root>/milestones.json).
//     //   github: documented no-op (milestones assumed to pre-exist, as `gh --milestone` assumes).
//     //   gitlab: POST to create milestones if absent.
//     ensureMilestones?: async (ms: [{title, description}]) => void,
//     // REQUIRED. Create one issue; returns its identity.
//     //   github: { url: <stdout>, id: <url> }  (no separate numeric id used here)
//     createIssue: async ({title, bodyFile, body, milestone, labels}) => ({ url, id }),
//     // OPTIONAL. Place the created issue on a board / set fields.
//     //   github: project item-add + item-edit.  gitlab: omit.
//     placeOnBoard?: async ({url, id, wave, milestone, pkgs, size}) => void,
//   }

import { readFileSync, appendFileSync } from 'node:fs';

export async function materialize({ scope, labelFixes = [], dry = true, backend, root }) {
  // 0. FAIL LOUD on the two required, EZK-free inputs. No defaults: the engine must carry no
  //    project knowledge — the caller (the per-backend CLI) supplies both.
  if (!scope || typeof scope !== 'string') {
    throw new Error('materialize: `scope` is required (the label to filter issues-open.json on, e.g. "wave:4")');
  }
  if (!root || typeof root !== 'string') {
    throw new Error('materialize: `root` is required (the data dir holding issues-open.json / created-issues.tsv / milestones.json)');
  }

  // 1. Load inputs from <root>.
  const issues = JSON.parse(readFileSync(`${root}/issues-open.json`, 'utf8'));
  const createdTsv = readFileSync(`${root}/created-issues.tsv`, 'utf8');

  // 2. Line-exact dedupe index against created-issues.tsv: the TSV holds "url<TAB>title" lines —
  //    match the TITLE COLUMN exactly (field [1] after splitting on \t), NOT substring includes().
  const createdTitles = new Set(
    createdTsv
      .split('\n')
      .filter((line) => line.length > 0)
      .map((line) => line.split('\t')[1])
      .filter((t) => t !== undefined),
  );

  // 3. Filter membership by the `scope` label.
  const scoped = issues.filter((i) => i.labels.includes(scope));

  console.log(`${dry ? '[DRY RUN] ' : ''}Scope ${scope} — issues to create: ${scoped.length}\n`);

  // Compute the plan (per-issue derived data) — shared by DRY and WET.
  const plan = [];
  let created = 0;
  let skipped = 0;

  for (const it of scoped) {
    // 4. Dedupe (line-exact title match).
    if (createdTitles.has(it.title)) {
      console.log('SKIP (already created):', it.title);
      skipped++;
      continue;
    }
    // 5. slug = bodyFile without "bodies/" prefix and ".md" suffix.
    const slug = it.bodyFile.replace('bodies/', '').replace('.md', '');
    // 6. APPLY labelFixes IN ORDER. Each {label, only}: remove `label` from labels, then re-add it
    //    iff slug ∈ only. (Generalizes the clones' two fixes; empty `only` = strip-from-all.)
    let labels = [...it.labels];
    for (const fix of labelFixes) {
      labels = labels.filter((l) => l !== fix.label);
      if (fix.only && fix.only.includes(slug)) labels.push(fix.label);
    }
    // 7. Derive wave / size / pkgs by PARSING a fixed set of board-field label prefixes
    //    (wave:/size:/shared-pkg:). This is the ONE accepted residual (see header): a project
    //    lacking these labels gets empty values and skips the optional github placeOnBoard hook.
    const waveNum = (labels.find((l) => l.startsWith('wave:')) || '').split(':')[1] || '';
    const size = (labels.find((l) => l.startsWith('size:')) || '').split(':')[1] || '';
    const pkgs = labels
      .filter((l) => l.startsWith('shared-pkg:'))
      .map((l) => l.split(':')[1])
      .join(', ');

    plan.push({
      title: it.title,
      slug,
      milestone: it.milestone,
      bodyFile: it.bodyFile,
      labels,
      wave: waveNum,
      size,
      pkgs,
    });
  }

  // 8. Load + resolve milestones BEFORE the DRY branch, so a missing/malformed milestones.json or
  //    an unresolvable milestone reference fails during the DRY rehearsal (not only at WET time).
  //    FAIL LOUD on both; the mutating ensureMilestones / create loop stay WET-gated below.
  let milestones;
  try {
    milestones = JSON.parse(readFileSync(`${root}/milestones.json`, 'utf8'));
  } catch (e) {
    throw new Error(`missing/malformed milestone data file: ${root}/milestones.json (${e.message})`);
  }
  const milestonesByTitle = new Map(milestones.map((m) => [m.title, m]));
  const distinctMilestoneTitles = [...new Set(plan.map((p) => p.milestone))];
  const milestonesForPlan = distinctMilestoneTitles.map((title) => {
    const m = milestonesByTitle.get(title);
    if (!m) throw new Error(`milestone not in milestones.json: ${title}`);
    return { title, description: m.description };
  });

  // 9. DRY (default): print one "WOULD CREATE" block per issue. No mutations.
  if (dry) {
    for (const p of plan) {
      console.log(`WOULD CREATE  ${p.title}`);
      console.log(`   milestone=${p.milestone}  wave=${p.wave} size=${p.size}`);
      console.log(`   labels: ${p.labels.join(', ')}\n`);
      created++;
    }
    console.log(`\n[DRY RUN] would create: ${created}   skipped: ${skipped}`);
    return { created, skipped, plan };
  }

  // 10. WET: ensure milestones ONCE up front, then create + record + board per issue.
  //     (milestones resolved above so DRY exercises the same load/lookup; only the mutation is gated.)
  await backend.ensureMilestones?.(milestonesForPlan);

  for (const p of plan) {
    const bodyFile = `${root}/${p.bodyFile}`;
    const body = readFileSync(bodyFile, 'utf8');
    const { url, id } = await backend.createIssue({
      title: p.title,
      bodyFile,
      body,
      milestone: p.milestone,
      labels: p.labels,
    });
    appendFileSync(`${root}/created-issues.tsv`, `${url}\t${p.title}\n`);
    await backend.placeOnBoard?.({
      url,
      id,
      wave: p.wave,
      milestone: p.milestone,
      pkgs: p.pkgs,
      size: p.size,
    });
    console.log('CREATED', url, '·', p.title);
    created++;
  }
  console.log(`\ncreated: ${created}   skipped: ${skipped}`);
  return { created, skipped, plan };
}
