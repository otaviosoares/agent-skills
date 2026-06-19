#!/usr/bin/env node
// materialize-gitlab.mjs — the GitLab (glab CLI) backend of the generic producer
// (materialize-core.mjs), plus the CLI entry. The matched SIBLING of materialize-github.mjs
// and the setup-side counterpart of the runtime adapter adapters/gitlab.sh. Generalizes
// create-wave{3,4}.mjs against `glab`: it carries NO project knowledge — the per-scope judgment
// (scope label + labelFixes) lives in a backlog JSON the caller points at. It is NOT a clone.
//
//   # source plans/loop.config.sh (exports REPO; set GITLAB_HOST for self-hosted) first.
//   # KIT="$(plans/run-loop.sh --print-kit-dir)"  (or use the vendored plans/loop-kit/ path)
//   DRY=1 node "$KIT"/materialize-gitlab.mjs --batch-data plans/.tracker/waves/wave4.json --root plans/.tracker
//   DRY=0 node "$KIT"/materialize-gitlab.mjs --batch-data plans/.tracker/waves/wave4.json --root plans/.tracker
//
// CLI: identical surface to materialize-github.mjs:
//   --batch-data <path>   JSON { scope, labelFixes }. Optional if --scope given.
//   --scope <label>       supplies/overrides the scope label.
//   --root <dir>          REQUIRED (or env MATERIALIZE_ROOT).
//
// GitLab specifics (all confirmed in Task C, parity with adapters/gitlab.sh):
//   - REPO + GITLAB_HOST from env (normally plans/loop.config.sh). issue calls take -R REPO;
//     `glab api` has no -R, so inject `--hostname $GITLAB_HOST` when set (exactly like gitlab.sh's
//     _glab_api) and resolve the URL-encoded namespaced project path for api endpoints.
//   - createIssue: glab has NO --body-file → pass the body string via --description (a long arg
//     through execFileSync is fine; never shell:true). Labels AUTO-CREATE on first use.
//     Parse the IID from the create-output URL — glab returns a /-/work_items/N URL now (not
//     /-/issues/N), so match either.
//   - ensureMilestones: GitLab milestones do NOT auto-create → idempotently list+POST the missing
//     ones up front (LOOP-KIT.md step-5's ensure-milestones gap).
//   - placeOnBoard: OMITTED — GitLab boards are label-driven (the label IS the column), so the gh
//     PVT_/PVTF_ field block collapses to nothing. A documented absence is the correct backend shape.
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
  console.error('usage: [DRY=0] REPO=group/project node materialize-gitlab.mjs --batch-data <path> [--scope <label>] --root <dir>');
  console.error('  fail: no scope — supply --scope or a --batch-data file containing { "scope": "…" }');
  process.exit(1);
}
if (!root) {
  console.error('usage: [DRY=0] REPO=group/project node materialize-gitlab.mjs --batch-data <path> [--scope <label>] --root <dir>');
  console.error('  fail: no --root and no MATERIALIZE_ROOT');
  process.exit(1);
}

// DRY convention identical to the clones / materialize-github: dry unless DRY==='0'.
const DRY = process.env.DRY !== '0';

// REPO from the env (EZK sources plans/loop.config.sh, which exports REPO). NO default — fail loud.
const REPO = process.env.REPO;
if (!REPO) {
  console.error('fail: REPO unset — `source plans/loop.config.sh` (it exports REPO) or set REPO=group/project');
  process.exit(1);
}
// Self-hosted host (e.g. gitlab.machobear.ca). gitlab.com has no token in this env — the runbook
// exports GITLAB_HOST. Does NOT affect DRY output; only injected into live `glab api` calls.
const GITLAB_HOST = process.env.GITLAB_HOST || '';

// `glab issue …` is repo-scoped via -R (glab resolves the host from GITLAB_HOST/remote), exactly
// like adapters/gitlab.sh's _glab().
const glabIssue = (args) => execFileSync('glab', ['issue', ...args, '-R', REPO], { encoding: 'utf8' }).trim();

// `glab api` has NO -R: the host comes from --hostname (or GITLAB_HOST env / cwd remote). Inject
// --hostname only when GITLAB_HOST is set, so a cwd-resolved host still works when it isn't — the
// exact contract of adapters/gitlab.sh's _glab_api.
const glabApi = (args) => {
  const full = GITLAB_HOST ? ['api', '--hostname', GITLAB_HOST, ...args] : ['api', ...args];
  return execFileSync('glab', full, { encoding: 'utf8' }).trim();
};

// URL-encode REPO (group/project) → the numeric-id-free projects/<group%2Fproject> path form
// accepted as :id by the api, exactly like adapters/gitlab.sh's _enc + _project_id (jq @uri).
const encRepo = () => encodeURIComponent(REPO);

// Resolve REPO → numeric project id (needed for the milestones endpoint; `glab api` takes no -R so
// the project must be in the path). Mirrors gitlab.sh's _project_id.
const projectId = () => JSON.parse(glabApi([`projects/${encRepo()}`])).id;

const backend = {
  name: 'gitlab',

  // GitLab milestones do NOT auto-create (unlike labels). Idempotently ensure each referenced
  // milestone: list the existing ones (paginated), then POST only the missing titles. Called ONCE
  // up front by the core in WET mode with [{title, description}].
  ensureMilestones: async (ms) => {
    const pid = projectId();
    // List existing milestones (paginate). `glab api --paginate` emits ONE JSON array PER PAGE,
    // CONCATENATED (`[...][...]`) — NOT a single merged array — so a bare JSON.parse throws past
    // page 1 (>100 milestones). Split the concatenated per-page arrays and flatten, mirroring
    // adapters/gitlab.sh's `glab api --paginate … | jq -s 'add // []'` idiom.
    const raw = glabApi(['--paginate', `projects/${pid}/milestones?per_page=100`]).trim();
    const existing = raw
      ? raw.split(/(?<=\])\s*(?=\[)/).flatMap((chunk) => JSON.parse(chunk))
      : [];
    const have = new Set(existing.map((m) => m.title));
    for (const m of ms) {
      if (have.has(m.title)) {
        console.log('milestone exists:', m.title);
        continue;
      }
      glabApi([
        '--method',
        'POST',
        `projects/${pid}/milestones`,
        '-f',
        `title=${m.title}`,
        '-f',
        `description=${m.description || ''}`,
      ]);
      console.log('milestone created:', m.title);
    }
  },

  // Create one issue. glab has no --body-file: read by the core, handed here as `body`, passed via
  // --description. --yes makes it non-interactive. Labels auto-create on first use (no pre-create).
  createIssue: async ({ title, body, milestone, labels }) => {
    const createArgs = [
      'create',
      '--title',
      title,
      '--description',
      body,
      '--milestone',
      milestone,
      ...labels.flatMap((l) => ['--label', l]),
      '--yes',
    ];
    const url = glabIssue(createArgs);
    // glab now returns a .../-/work_items/N URL (NOT .../-/issues/N) — match EITHER and capture the IID.
    const m = url.match(/-\/(?:work_items|issues)\/(\d+)/);
    const id = m ? m[1] : url;
    return { url, id };
  },

  // placeOnBoard: intentionally OMITTED. GitLab boards are label-driven (the wave:/size:/shared-pkg:
  // labels ARE the columns), so the gh `project item-add`/`item-edit` + PVT_/PVTF_ field block has
  // no GitLab equivalent. A documented absence is the correct backend shape (the core treats the hook
  // as optional and simply skips it).
};

await materialize({ scope, labelFixes, dry: DRY, backend, root });
