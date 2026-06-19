#!/usr/bin/env bash
# adapters/github.sh — the GitHub (gh CLI) tracker adapter. REFERENCE backend.
#
# Defines cmd_<verb> functions invoked by ./track. Each is a faithful wrapper of the exact gh
# command wave-loop.md used to inline (file:line cited per verb). Project values (REPO, RUNLOG,
# LAND_MODE, BRANCH_PREFIX) come from tracker.config.sh; ./track sources both before dispatch.
#
# The lock CONTRACT this adapter satisfies (see LOOP-KIT.md): of N racing runners, exactly one
# wins, the loser can detect it and yield, the lock is owner-releasable, and the claimant id (the
# gh login) is stable+unique+comparable+crash-surviving. Mechanism: add-assignee + re-read +
# lexicographic login-sort tie-break. REQUIRES each runner authed as a DISTINCT gh login.
#
# Convention: read verbs print to stdout; mutating verbs are quiet unless they return a value
# (claim → won|lost, open-pr → url, branch-merged/item-state → token). Non-fatal cleanup uses || true.

_gh() { gh "$@" -R "$REPO"; }   # every gh call is repo-scoped

# capabilities — the driver/runbook reads these to decide multi-runner / PR availability.
cmd_caps() {
  cat <<EOF
backend=github
cross_machine_atomic_claim=true
can_open_pr=true
land_modes=merge,pr
EOF
}

# SYNC — open work-items in scope. (wave-loop.md:82) --limit 300 fixes gh's silent default of 30.
cmd_sync_list() {
  local scope="${1:?scope label required, e.g. wave:4}"
  _gh issue list --label "$scope" --state open --limit 300 \
    --json number,title,labels,assignees,state
}

# Run-log resume trail — last N entries. (wave-loop.md:84)
cmd_runlog_tail() {
  local n="${1:-2}"
  _gh issue view "$RUNLOG" --json comments --jq ".comments[-${n}:][].body"
}

# One item, full. (wave-loop.md:95,107) — used for the brief, dep parse, contention skip.
cmd_view() {
  _gh issue view "${1:?id required}" \
    --json number,title,body,labels,assignees,state,milestone
}

# Item terminal state as a lowercase token (open|closed) — the dep gate. (wave-loop.md:95,133)
cmd_item_state() {
  _gh issue view "${1:?id required}" --json state --jq '.state' | tr '[:upper:]' '[:lower:]'
}

# RECONCILE — my in-progress items in scope (the dangling-claim signal). (wave-loop.md:91)
cmd_reconcile_mine() {
  local scope="${1:?scope label required}"
  _gh issue list --label "$scope" --label in-progress --state open \
    --assignee "@me" --limit 100 --json number,title,labels,assignees
}

# Is a branch already merged into main? backend-neutral (no gh-shaped "Merge #N"). (wave-loop.md:91)
cmd_branch_merged() {
  local branch="${1:?branch required}"
  git fetch origin main -q 2>/dev/null || true   # avoid a stale origin/main → false-negative → needless rebuild
  # merge-commit / rebase landings (what the loop does in merge mode): the branch tip is an ANCESTOR of main.
  if git branch -r --merged origin/main 2>/dev/null | grep -q "/${branch}\$"; then
    echo yes; return 0
  fi
  # squash landings (PR mode; branch tip is NOT an ancestor): ask the host whether its PR merged.
  if [[ "$(_gh pr view "$branch" --json state --jq '.state' 2>/dev/null || true)" == "MERGED" ]]; then
    echo yes; return 0
  fi
  echo no
}

# CLAIM (atomic) → prints won|lost. (wave-loop.md:96)
#   add assignee + in-progress, re-read, winner = smallest-sorting assignee login. Loser releases.
cmd_claim() {
  local id="${1:?id required}" me winner
  me="$(gh api user --jq .login 2>/dev/null || true)"   # claimant identity; empty → treated as lost (safe)
  [[ -n "$me" ]] || { echo "✋ cannot resolve gh login (the claim identity) — is gh authed?" >&2; echo lost; return 0; }
  me="$(printf '%s' "$me" | tr '[:upper:]' '[:lower:]')"   # case-fold (portable; bash 3.2 lacks ${x,,}): GitHub logins are case-insensitive; honor the "lexicographic" contract (jq sort is by codepoint)
  # Add our claim. If the edit FAILS, release whatever stuck and report lost — never abort mid-claim (that would
  # leave an orphan in-progress label with no clear winner and print no won|lost for the runbook to act on).
  if ! _gh issue edit "$id" --add-assignee "@me" --add-label in-progress >/dev/null 2>&1; then
    cmd_release "$id"; echo lost; return 0
  fi
  # Stabilize against GitHub's eventual consistency: a concurrent runner's just-added assignee can lag the read,
  # so a naive immediate re-read could see only itself and both racers would "win". Sleep so both re-read a list
  # containing BOTH, then arbitrate deterministically: winner = case-folded lexicographically-smallest login.
  # This is a BEST-EFFORT CAS, not a true mutex; the soft contention-overlap skip at PICK and git's
  # non-fast-forward push rejection at LAND are the backstops if the shrunken window is ever hit.
  sleep 3
  # `|| true`: if the arbitration re-read fails transiently, fall to lost+release (recover next iteration) rather
  # than aborting mid-claim with our assignee still stuck.
  winner="$(_gh issue view "$id" --json assignees --jq '[.assignees[].login | ascii_downcase] | sort | .[0] // ""' 2>/dev/null || true)"
  if [[ -n "$winner" && "$winner" == "$me" ]]; then
    echo won
  else
    cmd_release "$id"; echo lost
  fi
}

# Release my claim (lost race / abort). (wave-loop.md:96,141)
cmd_release() {
  _gh issue edit "${1:?id required}" --remove-assignee "@me" --remove-label in-progress >/dev/null 2>&1 || true
}

# CLOSE — terminal, merge-mode. (wave-loop.md:101)
cmd_close() {
  local id="${1:?id required}"
  # Close FIRST (the terminal op). If close fails and aborts, the issue stays OPEN, still assigned + in-progress,
  # so RECONCILE (reconcile-mine + branch-merged) re-finds and re-closes it next iteration. Removing the label
  # first would hide a stranded-but-merged issue from reconcile-mine (which filters on the in-progress label).
  _gh issue close "$id" --reason completed
  _gh issue edit "$id" --remove-label in-progress >/dev/null 2>&1 || true
}

# PR-mode handoff — keep the issue OPEN + assigned so PICK skips it and dependents WAIT for a human merge.
cmd_mark_review() {
  local id="${1:?id required}" url="${2:-}"
  _gh issue edit "$id" --remove-label in-progress --add-label in-review >/dev/null
  [[ -n "$url" ]] && _gh issue comment "$id" --body "PR opened: ${url} — awaiting human merge." >/dev/null || true
}

# LOG — append one run-log entry (arg or stdin). (wave-loop.md:102)
cmd_log() {
  local body="${1:-}"
  # Read stdin only if there's no arg AND stdin is piped (not a tty → won't block waiting for EOF).
  if [[ -z "$body" && ! -t 0 ]]; then body="$(cat)"; fi
  # Refuse to post an empty entry (covers: tty with no arg, and headless /dev/null/empty-pipe). No blank comment, no hang.
  if [[ -z "$body" ]]; then echo "✋ log: empty entry (pass a body arg or pipe content)" >&2; return 64; fi
  _gh issue comment "$RUNLOG" --body "$body" >/dev/null
}

# Open a PR for the built branch (PR/MR mode), print its URL. (new — LAND_MODE=pr)
cmd_open_pr() {
  local branch="${1:?branch required}" id="${2:?id required}" url
  # Idempotent: a prior interrupted run may already have opened the PR — return its URL, don't double-create.
  url="$(_gh pr view "$branch" --json url --jq .url 2>/dev/null || true)"
  if [[ -n "$url" ]]; then echo "$url"; return 0; fi
  # FAIL LOUD on a push failure: otherwise the caller would mark the issue in-review with NO PR, parking it and
  # its dependents forever. Return non-zero + no URL so the runbook treats it as a build failure (release + BLOCKED).
  if ! git push -u origin "$branch" >/dev/null 2>&1; then
    echo "✋ open-pr: failed to push '$branch' to origin" >&2; return 1
  fi
  _gh pr create --head "$branch" --base main \
    --title "#${id} — ${branch}" \
    --body "Automated build for #${id}. CI green; awaiting human review/merge." >/dev/null 2>&1 \
    || _gh pr create --head "$branch" --base main --fill >/dev/null 2>&1 || true
  url="$(_gh pr view "$branch" --json url --jq .url 2>/dev/null || true)"
  if [[ -z "$url" ]]; then echo "✋ open-pr: PR did not open for '$branch'" >&2; return 1; fi
  echo "$url"
}

# Board projection — convenience only; the loop reads NOTHING from the board (wave-loop.md:7).
# No-op here: moving the card needs the project's opaque PVT_/PVTF_ IDs (do at runtime if wanted).
cmd_board_done() { :; }
