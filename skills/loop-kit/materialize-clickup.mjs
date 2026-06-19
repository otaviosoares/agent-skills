#!/usr/bin/env node
// materialize-clickup.mjs — the ClickUp (REST API v2) backend of the generic producer
// (materialize-core.mjs), plus the CLI entry. The matched SIBLING of materialize-{github,gitlab}.mjs
// and the setup-side counterpart of the runtime adapter adapters/clickup.sh. It carries NO project
// knowledge — the per-scope judgment (scope tag + labelFixes) lives in a backlog JSON the caller
// points at.
//
//   # source plans/loop.config.sh first (exports CLICKUP_TOKEN + CLICKUP_LIST_ID).
//   # KIT="$(plans/run-loop.sh --print-kit-dir)"  (or use the vendored plans/loop-kit/ path)
//   DRY=1 node "$KIT"/materialize-clickup.mjs --batch-data plans/.tracker/waves/wave4.json --root plans/.tracker
//   DRY=0 node "$KIT"/materialize-clickup.mjs --batch-data plans/.tracker/waves/wave4.json --root plans/.tracker
//
// CLI: identical surface to materialize-github.mjs:
//   --batch-data <path>   JSON { scope, labelFixes }. Optional if --scope given.
//   --scope <label>       supplies/overrides the scope tag.
//   --root <dir>          REQUIRED (or env MATERIALIZE_ROOT).
//
// ClickUp specifics (parity with adapters/clickup.sh):
//   - There is NO official CLI: every call is `curl`-equivalent fetch() against
//     https://api.clickup.com/api/v2 authed with the raw `pk_…` personal token in the Authorization
//     header (CLICKUP_TOKEN). The tracker unit is a LIST (CLICKUP_LIST_ID), not an owner/repo.
//   - createIssue: POST /list/{id}/task with {name, markdown_content, tags}. ClickUp TAGS are the
//     label analog; tags passed on create are attached (and created in the space if absent).
//   - ensureMilestones: NO-OP. ClickUp has no native milestone concept; the milestone is plan-side
//     metadata only and is not represented on the task. (Documented absence, like github's no-op but
//     for a different reason.)
//   - placeOnBoard: OMITTED — ClickUp board views are status/tag-driven (the tag IS the column), so the
//     gh PVT_/PVTF_ field block has no equivalent. A documented absence is the correct backend shape.
//
// PRECONDITION (runtime, not producer): the `in-progress` / `in-review` tags must exist in the space —
// the runtime adapter's _add_tag attaches existing space tags. Create them once in the ClickUp UI (or
// run one materialized task carrying them). The scope/size tags are created here on first task-create.
import { readFileSync } from 'node:fs';
import { materialize } from './materialize-core.mjs';

function argOf(argv, name) {
  const i = argv.indexOf(name);
  return i === -1 ? undefined : argv[i + 1];
}

const argv = process.argv.slice(2);
const batchPath = argOf(argv, '--batch-data');
const scopeArg = argOf(argv, '--scope');
const root = argOf(argv, '--root') || process.env.MATERIALIZE_ROOT;

let batchData = {};
if (batchPath) {
  batchData = JSON.parse(readFileSync(batchPath, 'utf8'));
}

const scope = scopeArg || batchData.scope;
const labelFixes = batchData.labelFixes || [];

if (!scope) {
  console.error('usage: [DRY=0] CLICKUP_TOKEN=pk_… CLICKUP_LIST_ID=… node materialize-clickup.mjs --batch-data <path> [--scope <label>] --root <dir>');
  console.error('  fail: no scope — supply --scope or a --batch-data file containing { "scope": "…" }');
  process.exit(1);
}
if (!root) {
  console.error('usage: [DRY=0] CLICKUP_TOKEN=pk_… CLICKUP_LIST_ID=… node materialize-clickup.mjs --batch-data <path> [--scope <label>] --root <dir>');
  console.error('  fail: no --root and no MATERIALIZE_ROOT');
  process.exit(1);
}

// DRY convention identical to the other backends: dry unless DRY==='0'.
const DRY = process.env.DRY !== '0';

// Auth + target list from the env (a project's loop.config.sh exports these). NO defaults — fail loud.
const TOKEN = process.env.CLICKUP_TOKEN;
const LIST_ID = process.env.CLICKUP_LIST_ID;
const API = process.env.CLICKUP_API || 'https://api.clickup.com/api/v2';
// Auth/list are only needed in WET mode (DRY never mutates) — defer the hard failure so a DRY rehearsal
// runs with neither set, exactly like materialize-github DRY runs without touching gh.
function requireEnv() {
  if (!TOKEN) {
    console.error('fail: CLICKUP_TOKEN unset — `source plans/loop.config.sh` (it exports CLICKUP_TOKEN) or set CLICKUP_TOKEN=pk_…');
    process.exit(1);
  }
  if (!LIST_ID) {
    console.error('fail: CLICKUP_LIST_ID unset — `source plans/loop.config.sh` (it exports CLICKUP_LIST_ID) or set CLICKUP_LIST_ID=…');
    process.exit(1);
  }
}

// One JSON call to the ClickUp api. Throws loud (status + body) on a non-2xx so a failed create aborts
// the run instead of silently recording a bad TSV line.
async function cu(method, path, body) {
  const res = await fetch(`${API}/${path}`, {
    method,
    headers: { Authorization: TOKEN, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`ClickUp ${method} ${path} → ${res.status}: ${text}`);
  }
  return text ? JSON.parse(text) : {};
}

const backend = {
  name: 'clickup',

  // ClickUp has no native milestones — documented NO-OP (the milestone stays plan-side metadata).
  ensureMilestones: async (_ms) => {
    /* no-op: ClickUp has no milestone concept */
  },

  // Create one task in the configured list. markdown_content carries the issue body; tags carry the
  // labels (created in the space on first use). Returns {url, id} — id is the ClickUp task id (the
  // opaque string the runtime adapter and branch names use as N).
  createIssue: async ({ title, body, labels }) => {
    requireEnv();
    const task = await cu('POST', `list/${LIST_ID}/task`, {
      name: title,
      markdown_content: body,
      tags: labels,
    });
    return { url: task.url, id: task.id };
  },

  // placeOnBoard: intentionally OMITTED. ClickUp board views are status/tag-driven (the wave:/size:
  // tags ARE the columns), so the gh `project item-add`/`item-edit` block has no equivalent. The core
  // treats the hook as optional and simply skips it.
};

await materialize({ scope, labelFixes, dry: DRY, backend, root });
