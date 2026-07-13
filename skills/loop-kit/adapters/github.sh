#!/usr/bin/env bash
# adapters/github.sh — the GitHub (gh CLI) tracker adapter. REFERENCE backend.
#
# Defines cmd_<verb> functions invoked by ./track. Each is a faithful wrapper of the exact gh
# command the original runbook used to inline. Project values (REPO, RUNLOG,
# BRANCH_PREFIX) come from tracker.config.sh; ./track sources both before dispatch.
#
# The lock CONTRACT this adapter satisfies (see LOOP-KIT.md): of N racing runners, exactly one
# wins, the loser can detect it and yield, the lock is owner-releasable, and the claimant id is
# stable+unique+comparable+crash-surviving. TWO claim strategies (CLAIM_STRATEGY, default assignee):
#
#   • assignee (default) — claimant id = the gh LOGIN. add-assignee + re-read + lexicographic
#     login-sort tie-break. REQUIRES each runner authed as a DISTINCT gh login.
#   • note — claimant id = LOGIN#RUNNER_ID, so N agents can share ONE login (e.g. a teammate running
#     two agents under one account). TWO-LEVEL CAS: every runner assigns its login UP FRONT (so an
#     assignee-mode racer sees it in the SAME pool — the two strategies INTEROP on one issue), level-1
#     elects the smallest assignee LOGIN exactly like assignee mode, then level-2 breaks ties among
#     agents sharing the winning login via per-agent "claimed by login#runner" comment markers.
#
# INVARIANT (operator-enforced, NOT machine-checkable cross-process): a given login is wholly one
# strategy — never assignee on one runner and note on another. Mixing strategies under ONE login
# double-builds (the assignee runner declares won without reading notes). Distinct logins may mix
# freely. Under a SHARED login, RECONCILE is runner-aware (see cmd_claim_owner / cmd_whoami): it adopts
# a dangling claim only when the live owner is itself (or none), never a sibling — and a crashed agent
# recovers its OWN claim by reuping with the SAME RUNNER_ID (no timed sibling takeover; no heartbeat).
#
# Convention: read verbs print to stdout; mutating verbs are quiet unless they return a value
# (claim → won|lost, open-pr → url, branch-merged/item-state → token). Non-fatal cleanup uses || true.

_gh() { gh "$@" -R "$REPO"; }   # every gh call is repo-scoped

# Portable lowercase (bash 3.2 has no ${x,,}; macOS /usr/bin/env bash is 3.2). Honors the case-folded
# "lexicographic" claimant contract (gh's gojq sorts by codepoint) without a bash-4 dependency.
_lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# Per-agent discriminator for the note strategy (the part of the claimant id BELOW the login). It is
# the operator-set RUNNER_ID, lowercased. There is deliberately NO default: ownership is identity-based
# (a downed agent reups with the SAME id to recover its own claim), so the id must be BOTH stable across
# restarts AND distinct between concurrent agents — and no auto-default can be both (hostname is stable
# but collides for two agents on one host; host-pid is unique but changes on restart). So note mode
# REQUIRES an explicit RUNNER_ID per agent (e.g. agent-1, agent-2); _claim_note refuses without one.
_runner_disc() { _lc "${RUNNER_ID:-}"; }

# capabilities — the driver/runbook reads these to decide multi-runner / PR availability.
cmd_caps() {
  cat <<EOF
backend=github
cross_machine_atomic_claim=true
can_open_pr=true
can_respond_to_reviews=true
EOF
}

# SYNC — open work-items in scope. --limit 300 fixes gh's silent default of 30.
cmd_sync_list() {
  local scope="${1:?scope label required, e.g. wave:4}"
  _gh issue list --label "$scope" --state open --limit 300 \
    --json number,title,labels,assignees,state
}

# Run-log resume trail — last N entries.
cmd_runlog_tail() {
  local n="${1:-2}"
  _gh issue view "$RUNLOG" --json comments --jq ".comments[-${n}:][].body"
}

# One item, full. — used for the brief, dep parse, contention skip.
cmd_view() {
  _gh issue view "${1:?id required}" \
    --json number,title,body,labels,assignees,state,milestone
}

# Item terminal state as a lowercase token (open|closed) — the dep gate.
cmd_item_state() {
  _gh issue view "${1:?id required}" --json state --jq '.state' | tr '[:upper:]' '[:lower:]'
}

# DEPS — the ids of issues blocking N, one per line (empty = unblocked). PICK gates on state: N is
# unblocked iff every id printed here is `closed` (via item-state). Two sources, native first:
#   1. GitHub's NATIVE issue dependencies (the UI-visible `blocked_by` edges). The endpoint returns an
#      array of blocker ISSUE objects; every one counts (open or closed — deps only enumerates, PICK
#      gates). `gh api` takes no -R, so REPO is in the path (like cmd_claim's `gh api user`).
#   2. FALLBACK when there are no native edges: parse a `## Blocked by` section from the body (what
#      /to-tickets writes on tiers without native links). Native present → body is ignored.
_deps_native_filter() { printf '%s' '.[] | .number'; }   # blocked_by array → blocker numbers (testable, cf. _owner_filter)

cmd_deps() {
  local id="${1:?id required}" native body
  # `|| true` (+ 2>/dev/null): a repo/tier without the dependencies API, or a transient error, must fall
  # through to the body parse, never abort the dispatcher under set -e mid-iteration.
  native="$(gh api "repos/${REPO}/issues/${id}/dependencies/blocked_by" --jq "$(_deps_native_filter)" 2>/dev/null || true)"
  if [[ -n "${native//[[:space:]]/}" ]]; then printf '%s\n' "$native"; return 0; fi
  body="$(_gh issue view "$id" --json body --jq '.body' 2>/dev/null || true)"
  printf '%s' "$body" | _deps_body
}

# Shared `## Blocked by` body parser (identical in both adapters — same reason _lc is): read a body on
# stdin, print each `#K` referenced under a `## Blocked by` heading, deduped, first-seen order. The
# section ends at the next `#`-heading. Case-insensitive on the heading, tolerant of a trailing `:`;
refs elsewhere are ignored.
_deps_body() {
  awk '
    /^#+[[:space:]]/ {
      inblk = (tolower($0) ~ /^#+[[:space:]]+blocked[[:space:]]+by[[:space:]]*:?[[:space:]]*$/)
      next
    }
    inblk {
      s = $0
      while (match(s, /#[0-9]+/)) {
        n = substr(s, RSTART + 1, RLENGTH - 1)
        if (!(n in seen)) { seen[n] = 1; print n }
        s = substr(s, RSTART + RLENGTH)
      }
    }
  '
}

# RECONCILE — my in-progress items in scope (the dangling-claim signal).
cmd_reconcile_mine() {
  local scope="${1:?scope label required}"
  _gh issue list --label "$scope" --label in-progress --state open \
    --assignee "@me" --limit 100 --json number,title,labels,assignees
}

# Is a branch already merged into the base branch? backend-neutral (no gh-shaped "Merge #N"). BASE_BRANCH
# is resolved by `track` (origin/HEAD, not hardcoded main); :-main is a defensive fallback if sourced raw.
cmd_branch_merged() {
  local branch="${1:?branch required}" base="${BASE_BRANCH:-main}"
  git fetch origin "$base" -q 2>/dev/null || true   # avoid a stale origin/$base → false-negative → needless rebuild
  # merge-commit / rebase landings: the branch tip is an ANCESTOR of the base branch.
  if git branch -r --merged "origin/$base" 2>/dev/null | grep -q "/${branch}\$"; then
    echo yes; return 0
  fi
  # squash landings (branch tip is NOT an ancestor): ask the host whether its PR merged.
  if [[ "$(_gh pr view "$branch" --json state --jq '.state' 2>/dev/null || true)" == "MERGED" ]]; then
    echo yes; return 0
  fi
  echo no
}

# CLAIM (atomic) → prints won|lost. Dispatches on CLAIM_STRATEGY (assignee|note).
cmd_claim() {
  local id="${1:?id required}" me
  me="$(gh api user --jq .login 2>/dev/null || true)"   # claimant identity; empty → treated as lost (safe)
  [[ -n "$me" ]] || { echo "✋ cannot resolve gh login (the claim identity) — is gh authed?" >&2; echo lost; return 0; }
  me="$(_lc "$me")"   # case-fold: GitHub logins are case-insensitive; honor the "lexicographic" contract (gojq sorts by codepoint)
  if [[ "${CLAIM_STRATEGY:-assignee}" == "note" ]]; then
    _claim_note "$id" "$me"
  else
    _claim_assignee "$id" "$me"
  fi
}

# Default CAS: add assignee + in-progress, re-read, winner = smallest-sorting assignee login. Loser releases.
_claim_assignee() {
  local id="$1" me="$2" winner
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

# Shared-login CAS: lets N agents share ONE login. TWO-LEVEL — level-1 (cross-login) is IDENTICAL to
# _claim_assignee's smallest-assignee-login arbitration (so an assignee-mode racer on the same issue
# elects the same winner — the strategies interop); level-2 breaks ties among agents under the winning
# login via per-agent "claimed by login#runner" comment markers. Comments are append-only — both agents
# can post at the same instant, both survive, and the deterministic smallest-id read picks one winner.
# OWNERSHIP IS IDENTITY-BASED, NOT TIMED: there is no liveness window — owner = smallest claimant whose
# LATEST marker is a claim (a `released by …` tombstone retracts it). A live build of any length never
# looks crashed; recovery is the agent reuping with its SAME RUNNER_ID. See cmd_claim_owner.
_claim_note() {
  local id="$1" me="$2" disc runner winner_login winner_id f
  # Note mode REQUIRES an explicit, stable, per-agent RUNNER_ID (see _runner_disc). Refuse rather than
  # mint an unstable default that would break self-recovery or collide between two agents on one host.
  if [[ -z "${RUNNER_ID:-}" ]]; then
    echo "✋ CLAIM_STRATEGY=note requires an explicit RUNNER_ID per agent (e.g. RUNNER_ID=agent-1), stable" >&2
    echo "   across restarts and distinct between concurrent agents. Refusing to claim without one." >&2
    echo lost; return 0
  fi
  disc="$(_runner_disc)"; runner="${me}#${disc}"
  # 1. Assign my LOGIN + in-progress UP FRONT, so an assignee-mode racer sees me in the same level-1 pool.
  if ! _gh issue edit "$id" --add-assignee "@me" --add-label in-progress >/dev/null 2>&1; then
    _gh issue edit "$id" --remove-assignee "@me" >/dev/null 2>&1 || true; echo lost; return 0
  fi
  # 2. Post my per-AGENT marker (the level-2 tiebreaker among agents sharing my login).
  if ! _gh issue comment "$id" --body "claimed by ${runner}" >/dev/null 2>&1; then
    _gh issue edit "$id" --remove-assignee "@me" >/dev/null 2>&1 || true; echo lost; return 0
  fi
  sleep 3
  # 3. LEVEL 1 (cross-login): winner login = smallest assignee — same computation as _claim_assignee.
  winner_login="$(_gh issue view "$id" --json assignees --jq '[.assignees[].login | ascii_downcase] | sort | .[0] // ""' 2>/dev/null || true)"
  if [[ -z "$winner_login" || "$winner_login" != "$me" ]]; then
    # Lost at level 1 (another login won, or a transient read). Remove ONLY my assignee — never the
    # in-progress label, which the winning login holds. Two siblings both losing to another login each
    # strip the shared login idempotently; the winner keeps its own assignee.
    _gh issue edit "$id" --remove-assignee "@me" >/dev/null 2>&1 || true; echo lost; return 0
  fi
  # 4. LEVEL 2 (within my login): smallest LIVE claimant for my login wins (owner = latest marker is a
  #    claim, not a release). No window: an issue can't be re-claimed while a claim stands (PICK skips
  #    in-progress), so every prior claim on a now-claimable issue was released — its tombstone retracts
  #    it. `$me` (a lowercased [a-z0-9-] login) is inlined — gh's --jq takes no --arg, keeping assignee
  #    mode jq-free. Comments are chronological, so last-write-wins per runner = its latest event.
  winner_id="$(_gh issue view "$id" --json comments --jq "$(_owner_filter "$me#")" 2>/dev/null || true)"
  if [[ -n "$winner_id" && "$winner_id" == "$runner" ]]; then
    echo won
  else
    # A sibling under my login won (or a transient read). Leave the shared assignee + in-progress to the
    # sibling — releasing them would strip the winner's claim. RECONCILE adopts a still-assigned item
    # next round only if I am the live owner, so a transient miss self-heals without a double build.
    echo lost
  fi
}

# Shared jq (gh's gojq) filter → smallest LIVE claimant id, or "". A runner is live iff its LATEST
# marker is a claim (not a `released by …` tombstone). $1 optionally scopes to a login prefix ("me#").
_owner_filter() {
  local pfx="${1:-}"
  printf '%s' '
    reduce (.comments[]
            | select(.body | test("^(claimed|released) by '"$pfx"'"))
            | { who: (.body | capture("^(?:claimed|released) by (?<w>[^ ]+)") | .w | ascii_downcase),
                act: (.body | capture("^(?<a>claimed|released)") | .a) }) as $e ({}; .[$e.who] = $e.act)
    | [ to_entries[] | select(.value == "claimed") | .key ] | sort | .[0] // ""'
}

# Live owner of an issue's claim (note strategy) — RECONCILE reads it to tell a sibling's ACTIVE claim
# from a dangling one under a SHARED login. Owner = smallest claimant whose LATEST marker is a claim;
# a `released by …` tombstone retracts a claim. Empty → no live note claim (an assignee-mode claim that
# left no marker, or all released = the item is free) → the caller may adopt it as its own.
# NO time window and NO heartbeat: a claim stays owned until its owner tombstones it, so a build of any
# length is safe; recovery of a crashed owner is that owner reuping with its SAME RUNNER_ID.
cmd_claim_owner() {
  local id="${1:?id required}"
  _gh issue view "$id" --json comments --jq "$(_owner_filter)" 2>/dev/null || true
}

# My own claimant id, in the SAME shape cmd_claim_owner returns — RECONCILE compares the two to decide
# "is this dangling claim mine?". note → login#runner ; assignee → bare login (no marker is ever posted,
# so cmd_claim_owner returns empty for an assignee claim and the caller adopts it as its own).
cmd_whoami() {
  local me; me="$(_lc "$(gh api user --jq .login 2>/dev/null || true)")"
  [[ -n "$me" ]] || { echo ""; return 0; }
  if [[ "${CLAIM_STRATEGY:-assignee}" == "note" ]]; then echo "${me}#$(_runner_disc)"; else echo "$me"; fi
}

# Release my claim (lost race / abort).
cmd_release() {
  local id="${1:?id required}"
  _gh issue edit "$id" --remove-assignee "@me" --remove-label in-progress >/dev/null 2>&1 || true
  # note strategy: drop a `released by login#runner` tombstone so a later re-claim of this issue is not
  # mis-attributed to this now-released claimant (cmd_claim_owner ignores a runner whose latest marker
  # is a release). Without it, an aborted winner's lingering claim marker would re-own the issue.
  if [[ "${CLAIM_STRATEGY:-assignee}" == "note" && -n "${RUNNER_ID:-}" ]]; then
    local me; me="$(_lc "$(gh api user --jq .login 2>/dev/null || true)")"
    [[ -n "$me" ]] && _gh issue comment "$id" --body "released by ${me}#$(_runner_disc)" >/dev/null 2>&1 || true
  fi
}

# CLOSE — terminal. RECONCILE's stranded-tail fallback: a merged branch whose PR was created degraded
# (the --fill fallback carries no `Closes #N` keyword) leaves the issue open — this finishes it.
cmd_close() {
  local id="${1:?id required}"
  # Close FIRST (the terminal op). If close fails and aborts, the issue stays OPEN, still assigned + in-progress,
  # so RECONCILE (reconcile-mine + branch-merged) re-finds and re-closes it next iteration. Removing the label
  # first would hide a stranded-but-merged issue from reconcile-mine (which filters on the in-progress label).
  _gh issue close "$id" --reason completed
  _gh issue edit "$id" --remove-label in-progress >/dev/null 2>&1 || true
}

# Review handoff — keep the issue OPEN + assigned so PICK skips it and dependents stay gated until a human merge.
cmd_mark_review() {
  local id="${1:?id required}" url="${2:-}"
  _gh issue edit "$id" --remove-label in-progress --add-label in-review >/dev/null
  [[ -n "$url" ]] && _gh issue comment "$id" --body "PR opened: ${url} — awaiting human merge." >/dev/null || true
}

# LOG — append one run-log entry (arg or stdin).
cmd_log() {
  local body="${1:-}"
  # Read stdin only if there's no arg AND stdin is piped (not a tty → won't block waiting for EOF).
  if [[ -z "$body" && ! -t 0 ]]; then body="$(cat)"; fi
  # Refuse to post an empty entry (covers: tty with no arg, and headless /dev/null/empty-pipe). No blank comment, no hang.
  if [[ -z "$body" ]]; then echo "✋ log: empty entry (pass a body arg or pipe content)" >&2; return 64; fi
  _gh issue comment "$RUNLOG" --body "$body" >/dev/null
}

# Open a PR for the built branch, print its URL.
cmd_open_pr() {
  local branch="${1:?branch required}" id="${2:?id required}" base="${BASE_BRANCH:-main}" url
  # Idempotent: a prior interrupted run may already have opened the PR — return its URL, don't double-create.
  url="$(_gh pr view "$branch" --json url --jq .url 2>/dev/null || true)"
  if [[ -n "$url" ]]; then echo "$url"; return 0; fi
  # FAIL LOUD on a push failure: otherwise the caller would mark the issue in-review with NO PR, parking it and
  # its dependents forever. Return non-zero + no URL so the runbook treats it as a build failure (release + BLOCKED).
  if ! git push -u origin "$branch" >/dev/null 2>&1; then
    echo "✋ open-pr: failed to push '$branch' to origin" >&2; return 1
  fi
  # `Closes #${id}` lets GitHub auto-close the issue when this PR merges to the DEFAULT branch, so a
  # human merge IS the close (the PR-mode dep-gate keys on closed; nothing in the loop closes an
  # in-review issue). Fires only when base==default branch; the --fill fallback carries no keyword,
  # so a degraded create lands without auto-close and needs a manual `track close`.
  _gh pr create --head "$branch" --base "$base" \
    --title "#${id} — ${branch}" \
    --body "Automated build for #${id}. Closes #${id}. CI green; awaiting human review/merge." >/dev/null 2>&1 \
    || _gh pr create --head "$branch" --base "$base" --fill >/dev/null 2>&1 || true
  url="$(_gh pr view "$branch" --json url --jq .url 2>/dev/null || true)"
  if [[ -z "$url" ]]; then echo "✋ open-pr: PR did not open for '$branch'" >&2; return 1; fi
  echo "$url"
}

# ── REVIEW-RESPONSE (PR mode) — drain human review feedback on an already-open PR ────────────────
# The loop opens a PR (open-pr) and parks the issue in-review; without these verbs nothing ever reads
# the human's comments. These let the orchestrator pick an in-review PR that has UNADDRESSED feedback,
# hand it to a responder sub-agent, and reply inline. Actionability is SELF-LIMITING: a thread needs
# work iff its LAST comment is a human's — once the bot replies, its own comment is last, so the thread
# drops out (no global high-water marker, no infinite loop). Conversation-level feedback (a PR comment
# or a review body, which is not an inline thread) uses a timestamp high-water: a human event newer than
# the bot's latest commit/comment on the PR. "me" = my gh login = the bot; a reviewer under the SAME
# login reads as self (multi-runner already requires distinct logins — see the lock contract).

# Resolve the OPEN PR number for issue #N by its branch convention ($BRANCH_PREFIX/N-<slug>) — a
# slug-agnostic prefix match, so the lister needs no slug (parity with branch-merged keying on the
# branch name). $BRANCH_PREFIX is treated as a regex prefix (fine for the usual [a-z0-9/-] prefixes).
# Empty → no open PR for this issue.
_pr_for() {
  local id="${1:?id required}"
  # Literal prefix match via jq `startswith` with --arg (NOT test()/regex) so a BRANCH_PREFIX with a
  # regex metachar or quote can neither break the filter nor mis-match. 2>/dev/null + trailing || true:
  # a transient list failure must yield "" (no PR), never abort the dispatcher under set -e mid-iteration
  # (reviews-pending's common no-feedback path assigns this in a command sub).
  _gh pr list --state open --limit 200 --json number,headRefName 2>/dev/null \
    | jq -r --arg bp "$BRANCH_PREFIX" --arg id "$id" \
        '[.[] | select(.headRefName | startswith($bp+"/"+$id+"-")) | .number] | first // empty' 2>/dev/null || true
}

# One GraphQL round-trip → a PR's review threads + conversation, normalized. Shape (logins lowercased):
#   { commits:[iso…], reviews:[{author,body,state,at}], comments:[{author,body,at}],
#     threads:[{isResolved, reply_to, path, line, last_author, comments:[{author,body,at}]}] }
# reply_to = the thread's FIRST review-comment databaseId — the id the REST "replies" endpoint keys on.
# Shared by _pr_actionable (boolean) and cmd_review_read (detail) so the two can't drift.
# Paging: the OUTER reviews/comments/reviewThreads use last:100 so the NEWEST feedback is always in scope
# (first:100 would return the oldest and silently miss recent comments on a busy PR); the INNER thread
# comments use first:100 so nodes[0] is the true ROOT comment (its databaseId = reply_to).
_pr_graphql() {
  local pr="${1:?pr required}" owner name
  owner="${REPO%%/*}"; name="${REPO##*/}"
  # -f forces String vars (owner/name); -F types pr as Int (gh auto-types numeric -F values).
  gh api graphql -f owner="$owner" -f name="$name" -F pr="$pr" -f query='
    query($owner:String!,$name:String!,$pr:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$pr){
          commits(last:100){nodes{commit{committedDate}}}
          reviews(last:100){nodes{author{login} body state submittedAt}}
          comments(last:100){nodes{author{login} body createdAt}}
          reviewThreads(last:100){nodes{
            isResolved
            comments(first:100){nodes{databaseId author{login} body createdAt path line}}}}}}}' \
    --jq '
      .data.repository.pullRequest as $pr
      | { commits: [ $pr.commits.nodes[].commit.committedDate ],
          reviews: [ $pr.reviews.nodes[] | {author:((.author.login//"")|ascii_downcase), body, state, at:.submittedAt} ],
          comments:[ $pr.comments.nodes[] | {author:((.author.login//"")|ascii_downcase), body, at:.createdAt} ],
          threads: [ $pr.reviewThreads.nodes[]
                     | { isResolved,
                         reply_to: (.comments.nodes[0].databaseId // null),
                         path: (.comments.nodes[0].path // null),
                         line: (.comments.nodes[0].line // null),
                         last_author: ((.comments.nodes[-1].author.login // "")|ascii_downcase),
                         comments: [ .comments.nodes[] | {author:((.author.login//"")|ascii_downcase), body, at:.createdAt} ] } ] }'
}

# Does this PR have actionable feedback for me? → yes|no. (unresolved thread whose last comment isn't
# mine) OR (a human comment/review newer than my latest commit/comment). max-of-empty is null in jq, and
# null sorts lowest, so "no bot activity yet" makes any human event actionable — the desired default.
_pr_actionable() {
  local pr="$1" me="$2" g
  g="$(_pr_graphql "$pr" 2>/dev/null || true)"
  [[ -n "$g" ]] || { echo no; return 0; }
  if printf '%s' "$g" | jq -e --arg me "$me" '
      ( ([ .commits[] ] + [ .comments[]|select(.author==$me)|.at ] + [ .reviews[]|select(.author==$me)|.at ])
        | map(select(.!=null)) | (if length>0 then max else null end) ) as $bot
      | ( [ .threads[] | select(.isResolved|not) | select(.last_author!=$me) | select(.reply_to!=null) ] | length > 0 )
        or ( [ (.comments[]|select(.author!=$me)|.at),
               (.reviews[]|select(.author!=$me)|select(((.body|length)>0) or .state=="CHANGES_REQUESTED")|.at) ]
             | map(select(.!=null)) | (if length>0 then max else null end) as $h
             | ($h!=null) and (($bot==null) or ($h>$bot)) )
    ' >/dev/null 2>&1; then echo yes; else echo no; fi
}

# REVIEWS-PENDING — my in-review issues in scope whose PR has actionable feedback → [{number,title,pr}].
# Empty [] → nothing to drain → the orchestrator falls through to PICK.
cmd_reviews_pending() {
  local scope="${1:?scope label required}" me out='[]' issues num title pr
  me="$(_lc "$(gh api user --jq .login 2>/dev/null || true)")"
  # Without my own login I can't tell my replies from a human's (self-limiting breaks) — report nothing
  # pending rather than spuriously flag; the next iteration retries once gh auth is back.
  [[ -n "$me" ]] || { echo '[]'; return 0; }
  issues="$(_gh issue list --label "$scope" --label in-review --assignee "@me" --state open --limit 200 --json number,title 2>/dev/null || echo '[]')"
  while IFS=$'\t' read -r num title; do
    [[ -n "$num" ]] || continue
    pr="$(_pr_for "$num")"; [[ -n "$pr" ]] || continue
    [[ "$(_pr_actionable "$pr" "$me")" == "yes" ]] || continue
    out="$(jq -nc --argjson a "$out" --argjson n "$num" --arg t "$title" --argjson p "$pr" '$a + [{number:$n,title:$t,pr:$p}]')"
  done < <(printf '%s' "$issues" | jq -r '.[] | "\(.number)\t\(.title)"')
  printf '%s\n' "$out"
}

# REVIEW-READ — the feedback the responder sub-agent acts on for issue #N. Only ACTIONABLE items:
# unresolved threads whose last comment isn't mine, plus one aggregate conversation item (human PR
# comments / review bodies newer than my high-water) carrying reply_to:"conversation".
cmd_review_read() {
  local id="${1:?id required}" me pr g meta
  me="$(_lc "$(gh api user --jq .login 2>/dev/null || true)")"
  [[ -n "$me" ]] || { echo "✋ review-read: cannot resolve gh login (is gh authed?)" >&2; return 1; }
  pr="$(_pr_for "$id")"
  [[ -n "$pr" ]] || { echo "✋ review-read: no open PR for #$id (branch ${BRANCH_PREFIX}/${id}-…)" >&2; return 1; }
  g="$(_pr_graphql "$pr" 2>/dev/null || true)"
  [[ -n "$g" ]] || { echo "✋ review-read: could not fetch review data for PR #$pr (transient gh error?)" >&2; return 1; }
  meta="$(_gh pr view "$pr" --json headRefName,baseRefName,url 2>/dev/null || echo '{}')"
  printf '%s' "$g" | jq --argjson pr "$pr" --arg me "$me" --argjson meta "$meta" '
    ( ([ .commits[] ] + [ .comments[]|select(.author==$me)|.at ] + [ .reviews[]|select(.author==$me)|.at ])
      | map(select(.!=null)) | (if length>0 then max else null end) ) as $bot
    | { pr:$pr, branch:($meta.headRefName//null), base:($meta.baseRefName//null), url:($meta.url//null),
        items: (
          [ .threads[] | select(.isResolved|not) | select(.last_author!=$me) | select(.reply_to!=null)
            | {kind:"thread", reply_to:.reply_to, path, line, conversation:[.comments[]|{author,body}]} ]
          + ( [ (.comments[]|select(.author!=$me)|select(($bot==null) or (.at>$bot))|{author,body}),
                (.reviews[]|select(.author!=$me)|select(((.body|length)>0) or .state=="CHANGES_REQUESTED")|select(($bot==null) or (.at>$bot))|{author,body:.body}) ]
              | if length>0 then [ {kind:"comment", reply_to:"conversation", conversation:.} ] else [] end )
        ) }'
}

# REVIEW-REPLY — post the responder's answer. reply_to="conversation" → a PR comment; else a databaseId
# from review-read → an inline reply under that thread (REST replies endpoint). Quiet on success.
cmd_review_reply() {
  local id="${1:?id required}" ref="${2:?reply_to token required (a thread id from review-read, or 'conversation')}" body="${3:?body required}" pr owner name
  pr="$(_pr_for "$id")"
  [[ -n "$pr" ]] || { echo "✋ review-reply: no open PR for #$id" >&2; return 1; }
  if [[ "$ref" == "conversation" ]]; then
    _gh pr comment "$pr" --body "$body" >/dev/null
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    owner="${REPO%%/*}"; name="${REPO##*/}"
    gh api "repos/${owner}/${name}/pulls/${pr}/comments/${ref}/replies" -f body="$body" >/dev/null
  else
    # A thread token from review-read is always a numeric databaseId or the literal "conversation";
    # anything else (e.g. a null that slipped through) would POST to /comments/null/replies and fail.
    echo "✋ review-reply: invalid reply_to '$ref' (expected a numeric thread token or 'conversation')" >&2
    return 1
  fi
}
