#!/usr/bin/env node
// materialize-github.mjs — the GitHub backend of the generic producer (materialize-core.mjs),
// plus the CLI entry. The matched pair to materialize-gitlab.mjs and a mirror of
// adapters/{github,gitlab}.sh. Generalizes create-wave{3,4}.mjs: it carries NO project knowledge —
// the per-scope judgment (scope label + labelFixes) lives in a backlog JSON the caller points at.
//
//   # source plans/loop.config.sh first (exports REPO + the GH_PROJECT*/GH_FIELD_* board config), or
//   # set REPO=… (board config optional — placeOnBoard no-ops when unset). KIT="$(plans/run-loop.sh --print-kit-dir)".
//   DRY=1 node "$KIT"/materialize-github.mjs --batch-data plans/.tracker/waves/wave4.json --root plans/.tracker
//   DRY=0 node "$KIT"/materialize-github.mjs --batch-data plans/.tracker/waves/wave4.json --root plans/.tracker
//
// CLI:
//   --batch-data <path>   JSON { scope, labelFixes } (the per-scope backlog file). Optional if --scope given.
//   --scope <label>       supplies/overrides the scope label (wins over batchData.scope).
//   --root <dir>          REQUIRED (or env MATERIALIZE_ROOT). The data dir for issues-open.json etc.
// Effective scope = --scope || batchData.scope (FAIL LOUD if neither). labelFixes = batchData.labelFixes || [].
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
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
  console.error('usage: [DRY=0] REPO=owner/name node materialize-github.mjs --batch-data <path> [--scope <label>] --root <dir>');
  console.error('  fail: no scope — supply --scope or a --batch-data file containing { "scope": "…" }');
  process.exit(1);
}
if (!root) {
  console.error('usage: [DRY=0] REPO=owner/name node materialize-github.mjs --batch-data <path> [--scope <label>] --root <dir>');
  console.error('  fail: no --root and no MATERIALIZE_ROOT');
  process.exit(1);
}

// DRY convention identical to the clones: dry unless DRY==='0'.
const DRY = process.env.DRY !== '0';

// REPO from the env (EZK sources plans/loop.config.sh, which exports REPO). NO default — fail loud.
const REPO = process.env.REPO;
if (!REPO) {
  console.error('fail: REPO unset — `source plans/loop.config.sh` (it exports REPO) or set REPO=owner/name');
  process.exit(1);
}

// Board config from the env (a project's loop.config.sh exports these — they are PER-PROJECT, not
// kit IP, so they live OUTSIDE this shared file). The board hook is WET-only and never touches DRY
// output. If the core ids (project / owner / project-id) are unset, placeOnBoard is a NO-OP — a repo
// with no GitHub Projects-v2 board simply skips it. Each field-edit is independently guarded on its
// field-id, so a board with only some fields configured still works.
// (Runtime field-id discovery — the board.sh fid() pattern — is the future de-hardcoding; see LOOP-KIT.md.)
const PROJ = process.env.GH_PROJECT || '';
const OWNER = process.env.GH_PROJECT_OWNER || '';
const PROJ_ID = process.env.GH_PROJECT_ID || '';
const F = {
  Wave: process.env.GH_FIELD_WAVE || '',
  Plan: process.env.GH_FIELD_PLAN || '',
  Pkgs: process.env.GH_FIELD_PKGS || '',
  Size: process.env.GH_FIELD_SIZE || '',
};
const boardConfigured = Boolean(PROJ && OWNER && PROJ_ID);

const gh = (args) => execFileSync('gh', args, { encoding: 'utf8' }).trim();

const backend = {
  name: 'github',

  // GitHub milestones are assumed to pre-exist (the clones assume this via `gh --milestone`).
  // Documented NO-OP — behavior unchanged. (`gh api` could create them to close LOOP-KIT.md's
  // ensure-milestones gap, but we deliberately do NOT change behavior here.)
  ensureMilestones: async (_ms) => {
    /* no-op: GitHub milestones pre-exist */
  },

  createIssue: async ({ title, bodyFile, milestone, labels }) => {
    const createArgs = [
      'issue',
      'create',
      '--repo',
      REPO,
      '--title',
      title,
      '--body-file',
      bodyFile,
      '--milestone',
      milestone,
      ...labels.flatMap((l) => ['--label', l]),
    ];
    const url = gh(createArgs);
    return { url, id: url };
  },

  // OMITTED entirely (undefined) when no board is configured, so the core's optional-hook call
  // `await backend.placeOnBoard?.(…)` simply skips it.
  placeOnBoard: boardConfigured
    ? async ({ url, wave, milestone, pkgs, size }) => {
        const itemId = JSON.parse(
          gh(['project', 'item-add', PROJ, '--owner', OWNER, '--url', url, '--format', 'json']),
        ).id;
        const edit = (fieldId, kind, val) => {
          if (fieldId && val)
            gh(['project', 'item-edit', '--id', itemId, '--project-id', PROJ_ID, '--field-id', fieldId, kind, val]);
        };
        edit(F.Wave, '--number', wave);
        edit(F.Plan, '--text', milestone);
        edit(F.Pkgs, '--text', pkgs);
        edit(F.Size, '--text', size);
      }
    : undefined,
};

await materialize({ scope, labelFixes, dry: DRY, backend, root });
