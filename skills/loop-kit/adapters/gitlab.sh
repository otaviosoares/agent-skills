#!/usr/bin/env bash
# adapters/gitlab.sh — the GitLab (glab CLI) tracker adapter.
#
# Mirrors adapters/github.sh VERB-FOR-VERB (identical cmd_* names) so the dispatcher and runbook
# never change — TRACKER_BACKEND=gitlab is the only switch. Project values (REPO, RUNLOG, LAND_MODE,
# BRANCH_PREFIX) come from plans/loop.config.sh; ./track sources both before dispatch. For a
# self-hosted instance, export GITLAB_HOST=<host> in the config so glab targets the right server.
#
# The lock CONTRACT this adapter satisfies (see LOOP-KIT.md) is IDENTICAL to github.sh — only the
# MECHANISM differs: of N racing runners exactly one wins, the loser detects it and yields, the lock
# is owner-releasable, and the claimant id (the glab username) is stable+unique+comparable+crash-
# surviving. Mechanism: ADDITIVE assignee union (`--assignee +me`, NOT a bare replace which is
# last-writer-wins and unsafe) + stabilization re-read + lexicographic username-sort tie-break.
# On Free tier (single-assignee → union impossible), CLAIM_STRATEGY=note falls back to a note-marker
# CAS: owner = smallest claimant whose LATEST note is a claim, with a `released by …` tombstone
# retracting it (identity-based, no time window — see _gl_owner). REQUIRES each runner a DISTINCT glab user.
#
# DEPENDENCY: jq (glab has no built-in --jq like gh; read verbs pipe `--output json` through jq).
# Convention: read verbs print to stdout; mutating verbs are quiet unless they return a value
# (claim → won|lost, open-pr → url, branch-merged/item-state → token). Non-fatal cleanup uses || true.

_glab() { glab "$@" -R "$REPO"; }   # every issue/mr call is repo-scoped (glab resolves host via GITLAB_HOST/remote)

# glab api has no -R; host comes from --hostname or GITLAB_HOST (or the cwd repo's remote). Inject
# --hostname only when GITLAB_HOST is set, so a cwd-resolved host still works when it isn't.
_glab_api() {
  if [[ -n "${GITLAB_HOST:-}" ]]; then glab api --hostname "$GITLAB_HOST" "$@"; else glab api "$@"; fi
}

# Portable lowercase (bash 3.2 has no ${x,,}; macOS /usr/bin/env bash is 3.2). Honors the
# case-folded "lexicographic" claimant contract without a bash-4 dependency.
_lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# URL-encode one path segment (for the numeric-id-free projects/<group%2Fproject> form).
_enc() { printf '%s' "${1:-}" | jq -sRr @uri; }

# Resolve REPO (group/project) → numeric project id, needed for the notes endpoint (glab api takes
# no -R, so the project must be in the path; the URL-encoded namespaced path is accepted as :id).
_project_id() { _glab_api "projects/$(_enc "$REPO")" | jq -r '.id'; }

# capabilities — same shape/keys as github so the driver/runbook read it identically.
cmd_caps() {
  cat <<EOF
backend=gitlab
cross_machine_atomic_claim=true
can_open_pr=true
can_respond_to_reviews=true
land_modes=merge,pr
EOF
}

# SYNC — open work-items in scope, normalized to github's {id,title,labels,assignees,state} shape
# (id=iid here). Uses the api + --paginate (one array per page → `jq -s add`) so there is NO silent
# 100-item cap — the analog of github's `--limit 300`. GitLab open state is `opened`, not `open`.
cmd_sync_list() {
  local scope="${1:?scope label required, e.g. wave:4}" pid enc
  pid="$(_project_id)"
  enc="$(_enc "$scope")"
  _glab_api --paginate "projects/${pid}/issues?labels=${enc}&state=opened&per_page=100" \
    | jq -s 'add // [] | [.[] | {iid, title, labels, assignees: [.assignees[].username], state}]'
}

# Run-log resume trail — last N non-system notes, chronological. sort=desc + first-N + reverse so a
# run-log with >100 notes still yields the NEWEST N (a naive sort=asc first page would return the
# OLDEST). System notes (label/assignee events) are excluded — only human entries are the trail.
cmd_runlog_tail() {
  local n="${1:-2}" pid
  pid="$(_project_id)"
  _glab_api "projects/${pid}/issues/${RUNLOG}/notes?sort=desc&order_by=created_at&per_page=100" \
    | jq -r "[.[] | select(.system==false)] | .[0:${n}] | reverse | .[].body"
}

# One item, full — used for the brief, dep parse, contention skip. Aliases description→body and
# iid→number so a cross-backend consumer reading github's field names still works.
cmd_view() {
  _glab issue view "${1:?id required}" --output json \
    | jq '. + {body: (.description // ""), number: .iid}'
}

# Item terminal state as a github-parity token (open|closed) — the dep gate. GitLab uses
# opened/closed; normalize opened→open so the runbook's `== closed` test is backend-neutral.
cmd_item_state() {
  local s
  # Never abort the dispatcher on a transient view failure (parity with github.sh, which emits a bare
  # pipeline that yields empty): a bare `s=$(pipeline)` under set -e/pipefail would abort, breaking the
  # runbook's dep-gate compound `[[ $(track item-state X) == closed ]]`. On failure → empty → `*)` arm
  # echoes empty → the gate reads "not closed" (safe WAIT), exactly like github's tr-on-empty.
  s="$(_glab issue view "${1:?id required}" --output json 2>/dev/null | jq -r '.state' 2>/dev/null || true)"
  case "$s" in
    opened) echo open ;;
    closed) echo closed ;;
    *)      _lc "$s" ;;
  esac
}

# RECONCILE — my in-progress items in scope (the dangling-claim signal). Repeated --label = AND
# (scope AND in-progress); --assignee=@me. Both claim strategies leave the WINNER assigned, so this
# is uniform across strategies. Default state is opened, which is what we want.
cmd_reconcile_mine() {
  local scope="${1:?scope label required}"
  _glab issue list --label "$scope" --label in-progress --assignee=@me --per-page 100 --output json \
    | jq -c '[.[] | {iid, title, labels, assignees: [.assignees[].username]}]'
}

# Is a branch already merged into the base branch? backend-neutral, keyed on the BRANCH name — GitLab
# MR iids (!N) are a DIFFERENT sequence from issue iids (#N), so never grep "Merge #N". BASE_BRANCH is
# resolved by `track` (origin/HEAD, not hardcoded main); :-main is a defensive fallback if sourced raw.
cmd_branch_merged() {
  local branch="${1:?branch required}" base="${BASE_BRANCH:-main}"
  git fetch origin "$base" -q 2>/dev/null || true   # avoid a stale origin/$base → false-negative → needless rebuild
  # merge-commit / rebase landings (merge mode): the branch tip is an ANCESTOR of the base branch.
  if git branch -r --merged "origin/$base" 2>/dev/null | grep -q "/${branch}\$"; then
    echo yes; return 0
  fi
  # squash landings (PR mode; tip is NOT an ancestor): ask GitLab whether an MR for this SOURCE BRANCH merged.
  if _glab mr list --source-branch "$branch" --merged --output json 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
    echo yes; return 0
  fi
  echo no
}

# CLAIM (atomic) → prints won|lost. CLAIM_STRATEGY=assignee (default; additive union, needs a
# multi-assignee tier) | note (Free-tier single-assignee fallback; note-marker CAS).
cmd_claim() {
  local id="${1:?id required}" me
  me="$(_glab_api user 2>/dev/null | jq -r '.username // empty' 2>/dev/null || true)"   # claimant identity; empty → lost (safe)
  [[ -n "$me" ]] || { echo "✋ cannot resolve glab user (the claim identity) — is glab authed / GITLAB_HOST set?" >&2; echo lost; return 0; }
  me="$(_lc "$me")"   # case-fold: honor the lexicographic contract (jq sort is by codepoint)
  if [[ "${CLAIM_STRATEGY:-assignee}" == "note" ]]; then
    _claim_note "$id" "$me"
  else
    _claim_assignee "$id" "$me"
  fi
}

# Default CAS: ADDITIVE assignee union + in-progress, stabilize, re-read, winner = smallest username.
#   `--assignee +me` ADDS without evicting a concurrent racer (a bare `--assignee me` REPLACES =
#   last-writer-wins = a later claimer could steal an in-progress lock). This is the GitLab analog of
#   github's `--add-assignee @me`; same best-effort-CAS contract, same PICK-overlap + git-push-reject backstops.
_claim_assignee() {
  local id="$1" me="$2" winner
  # If the add-edit FAILS, release whatever stuck and report lost — never abort mid-claim (that would
  # leave an orphan in-progress label with no clear winner and print no won|lost for the runbook).
  if ! _glab issue update "$id" --assignee "+$me" --label in-progress >/dev/null 2>&1; then
    cmd_release "$id"; echo lost; return 0
  fi
  # Stabilize against eventual consistency: a concurrent racer's just-added assignee can lag the read,
  # so a naive immediate re-read could see only itself and both racers would "win". Sleep so both
  # re-read a list containing BOTH, then arbitrate: winner = case-folded lexicographically-smallest username.
  sleep 3
  # `|| true`: a transient re-read failure → fall to lost+release (recover next iteration) rather than
  # aborting mid-claim with our assignee still stuck.
  winner="$(_glab issue view "$id" --output json 2>/dev/null | jq -r '[.assignees[].username | ascii_downcase] | sort | .[0] // ""' 2>/dev/null || true)"
  if [[ -n "$winner" && "$winner" == "$me" ]]; then
    echo won
  else
    cmd_release "$id"; echo lost
  fi
}

# Free-tier fallback CAS: in-progress label + a `claimed by <user>` note marker, stabilize, re-read,
# winner = smallest LIVE claimant (computed identically by every racer, so consistent regardless of post
# order — same shape as github's login-sort). The winner takes the single assignee slot so reconcile-mine
# finds it. OWNERSHIP IS IDENTITY-BASED, NO TIME WINDOW (see _gl_owner / cmd_claim_owner): a runner is
# live iff its LATEST note is a claim, not a `released by …` tombstone — so a long build never looks
# crashed and a lingering loser/ghost marker can't re-win (its tombstone retracts it; note mode here is
# distinct-login, so each agent recovers its own claim by reuping the same username).
#   pid is resolved BEFORE any mutation and guarded: if the notes endpoint is unreachable we yield cleanly
#   (echo lost, nothing posted) rather than aborting mid-claim under set -e after stamping label+note.
_claim_note() {
  local id="$1" me="$2" winner pid
  pid="$(_project_id 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then echo lost; return 0; fi   # can't arbitrate without the notes endpoint → yield; nothing stamped
  if ! _glab issue update "$id" --label in-progress >/dev/null 2>&1; then cmd_release "$id"; echo lost; return 0; fi
  if ! _glab issue note "$id" -m "claimed by $me" >/dev/null 2>&1; then cmd_release "$id"; echo lost; return 0; fi
  sleep 3
  winner="$(_gl_owner "$pid" "$id")"
  if [[ -n "$winner" && "$winner" == "$me" ]]; then
    _glab issue update "$id" --assignee "$me" >/dev/null 2>&1 || true   # winner takes the lone assignee slot → reconcile-mine handle
    echo won
  else
    cmd_release "$id"; echo lost
  fi
}

# Event-based live owner of an issue's claim: smallest claimant whose LATEST note is a claim (a
# `released by …` tombstone retracts it). No time window — an issue can't be re-claimed while a claim
# stands (PICK skips in-progress), so every prior claim on a re-claimable issue was released. Notes are
# fetched ASC so the reduce's last-write-wins per user resolves to that user's latest event.
_gl_owner() {   # args: pid id → smallest live claimant username, or ""
  _glab_api "projects/${1}/issues/${2}/notes?per_page=100&sort=asc&order_by=created_at" 2>/dev/null \
    | jq -r '
        reduce (.[] | select(.system==false) | select(.body | test("^(claimed|released) by "))
                 | { who: (.body | capture("^(?:claimed|released) by (?<w>[^ ]+)") | .w | ascii_downcase),
                     act: (.body | capture("^(?<a>claimed|released)") | .a) }) as $e ({}; .[$e.who]=$e.act)
        | [ to_entries[] | select(.value=="claimed") | .key ] | sort | .[0] // ""
      ' 2>/dev/null || true
}

# Live owner for RECONCILE (github-parity verb; see github.sh:cmd_claim_owner). Empty → no live note
# claim (assignee-mode, or all released = free) → caller may adopt.
cmd_claim_owner() {
  local id="${1:?id required}" pid
  pid="$(_project_id 2>/dev/null || true)"; [[ -n "$pid" ]] || { echo ""; return 0; }
  _gl_owner "$pid" "$id"
}

# My claimant id in cmd_claim_owner's shape — RECONCILE compares the two. GitLab keys on the username
# under BOTH strategies (note marker = username; assignee = username), so this is the username either way.
cmd_whoami() { _lc "$(_glab_api user 2>/dev/null | jq -r '.username // empty' 2>/dev/null || true)"; }

# Release my claim (lost race / abort). Additive remove of my assignee (`!me`, not a bare replace) +
# unlabel in-progress. `!` prefix (not `-me`, which the flag parser could read as an option) removes me.
# glab needs the username to remove just MYSELF (no `@me` removal token; `--unassign` would evict the
# WINNER too on a lost-race release). So if identity can't be resolved, leave the claim FULLY intact
# (assignee + in-progress) — reconcile-mine keys on in-progress, so a half-release that drops only the
# label would hide a still-assigned item from the dangling-claim sweep. Intact-and-retried > invisible.
cmd_release() {
  local id="${1:?id required}" me
  me="$(_glab_api user 2>/dev/null | jq -r '.username // empty' 2>/dev/null || true)"
  if [[ -z "$me" ]]; then
    echo "ℹ️  release: could not resolve glab user — leaving claim intact for RECONCILE to retry" >&2
    return 0
  fi
  _glab issue update "$id" --assignee "!$me" --unlabel in-progress >/dev/null 2>&1 || true
  # note strategy: drop a `released by <user>` tombstone so a later re-claim isn't mis-attributed to this
  # now-released claimant (_gl_owner ignores a user whose latest note is a release).
  if [[ "${CLAIM_STRATEGY:-assignee}" == "note" ]]; then
    _glab issue note "$id" -m "released by $(_lc "$me")" >/dev/null 2>&1 || true
  fi
}

# CLOSE — terminal, merge-mode. Close FIRST (the terminal op); if it fails and aborts, the issue stays
# OPEN, still assigned + in-progress, so RECONCILE re-finds and re-closes it. De-labelling first would
# hide a stranded-but-merged issue from reconcile-mine (which filters on the in-progress label).
cmd_close() {
  local id="${1:?id required}"
  _glab issue close "$id"
  _glab issue update "$id" --unlabel in-progress >/dev/null 2>&1 || true
}

# PR-mode handoff — keep the issue OPEN + assigned so PICK skips it and dependents WAIT for a human merge.
cmd_mark_review() {
  local id="${1:?id required}" url="${2:-}"
  _glab issue update "$id" --unlabel in-progress --label in-review >/dev/null
  if [[ -n "$url" ]]; then _glab issue note "$id" -m "MR opened: ${url} — awaiting human merge." >/dev/null || true; fi
}

# LOG — append one run-log entry (arg or stdin). Refuse empty (no blank note, no stdin hang on a tty).
cmd_log() {
  local body="${1:-}"
  if [[ -z "$body" && ! -t 0 ]]; then body="$(cat)"; fi
  if [[ -z "$body" ]]; then echo "✋ log: empty entry (pass a body arg or pipe content)" >&2; return 64; fi
  _glab issue note "$RUNLOG" -m "$body" >/dev/null
}

# Open an MR for the built branch (PR/MR mode), print its web_url. Idempotent + fail-loud.
cmd_open_pr() {
  local branch="${1:?branch required}" id="${2:?id required}" base="${BASE_BRANCH:-main}" url
  # Idempotent: a prior interrupted run may already have opened the MR — return its url, don't double-create.
  url="$(_glab mr view "$branch" --output json 2>/dev/null | jq -r '.web_url // empty' 2>/dev/null || true)"
  if [[ -n "$url" ]]; then echo "$url"; return 0; fi
  # FAIL LOUD on a push failure: otherwise the caller marks the issue in-review with NO MR, parking it
  # and its dependents forever. Return non-zero + no url so the runbook treats it as a build failure.
  if ! git push -u origin "$branch" >/dev/null 2>&1; then
    echo "✋ open-pr: failed to push '$branch' to origin" >&2; return 1
  fi
  # `Closes #${id}` lets GitLab auto-close the issue when this MR merges to the DEFAULT branch, so a
  # human merge IS the close (the PR-mode dep-gate keys on closed; nothing in the loop closes an
  # in-review issue). Fires only when target==default branch; the --fill fallback carries no keyword,
  # so a degraded create lands without auto-close and needs a manual `track close`.
  _glab mr create --source-branch "$branch" --target-branch "$base" --yes \
    --title "#${id} — ${branch}" \
    --description "Automated build for #${id}. Closes #${id}. CI green; awaiting human review/merge." >/dev/null 2>&1 \
    || _glab mr create --source-branch "$branch" --target-branch "$base" --fill --yes >/dev/null 2>&1 || true
  url="$(_glab mr view "$branch" --output json 2>/dev/null | jq -r '.web_url // empty' 2>/dev/null || true)"
  if [[ -z "$url" ]]; then echo "✋ open-pr: MR did not open for '$branch'" >&2; return 1; fi
  echo "$url"
}

# ── REVIEW-RESPONSE (PR/MR mode) — drain human review feedback on an already-open MR ──────────────
# Mirrors github.sh's review verbs verb-for-verb (same {number,title,pr} / {items[]} / reply_to shapes),
# so the runbook is identical. GitLab feedback lives in MR DISCUSSIONS: a resolvable discussion = an
# inline diff thread; an individual/non-resolvable note = a conversation comment. Actionability is the
# SAME self-limiting rule as github (a thread needs work iff its last note isn't mine; conversation uses
# a commit/comment timestamp high-water). reply_to for a thread = the DISCUSSION id (the notes endpoint
# keys on it). "me" = my glab username = the bot; a reviewer under the SAME username reads as self.

# Resolve the OPEN MR iid for issue #N by its source-branch convention ($BRANCH_PREFIX/N-<slug>) — a
# slug-agnostic prefix match (parity with github's _pr_for / branch-merged). Empty → no open MR.
_mr_for() {
  local id="${1:?id required}"
  # Literal prefix match via jq `startswith` with --arg (NOT test()/regex) so a BRANCH_PREFIX with a
  # regex metachar or quote can neither break the filter nor mis-match. `${BRANCH_PREFIX%/}` strips a
  # trailing slash so a `loop/`-style config can't build a `loop//N-` prefix that never matches a real
  # `loop/N-…` branch. NO --state flag: `opened` is glab's DEFAULT, and `--state` is NOT a valid
  # `glab mr list` flag — passing it errors ("Unknown flag: --state"), 2>/dev/null swallows the error,
  # and the verb silently returns no MR (so reviews-pending/review-read find nothing for EVERY issue).
  # 2>/dev/null + trailing || true: a transient list failure yields "" (no MR), never aborts the
  # dispatcher under set -e mid-iteration (reviews-pending's no-feedback path assigns this in a sub).
  _glab mr list --per-page 200 --output json 2>/dev/null \
    | jq -r --arg bp "${BRANCH_PREFIX%/}" --arg id "$id" \
        '[.[] | select(.source_branch | startswith($bp+"/"+$id+"-")) | .iid] | first // empty' 2>/dev/null || true
}

# One MR's discussions + commits, normalized to github's _pr_graphql shape (logins lowercased) so the
# actionable/read jq is parallel. threads = resolvable diff discussions; comments = the rest (human notes).
# GitLab has no separate "reviews" object → reviews is implicitly empty (conversation = notes only).
_mr_norm() {
  local pid="$1" iid="$2" disc commits
  disc="$(_glab_api --paginate "projects/${pid}/merge_requests/${iid}/discussions?per_page=100" 2>/dev/null | jq -s 'add // []')"
  commits="$(_glab_api --paginate "projects/${pid}/merge_requests/${iid}/commits?per_page=100" 2>/dev/null | jq -s 'add // []')"
  jq -n --argjson d "${disc:-[]}" --argjson c "${commits:-[]}" '
    { commits: [ $c[].created_at ],
      comments: [ $d[] | select((any(.notes[]; .resolvable))|not) | .notes[] | select(.system==false)
                  | {author:((.author.username//"")|ascii_downcase), body, at:.created_at} ],
      threads: [ $d[] | select(any(.notes[]; .resolvable))
                 | (.notes | map(select(.system==false))) as $ns
                 | { isResolved: ( [ .notes[] | select(.resolvable) | .resolved ] | all ),
                     reply_to: .id,
                     path: ($ns[0].position.new_path // null),
                     line: ($ns[0].position.new_line // null),
                     last_author: (($ns[-1].author.username // "")|ascii_downcase),
                     comments: [ $ns[] | {author:((.author.username//"")|ascii_downcase), body, at:.created_at} ] } ] }'
}

# Does this MR have actionable feedback for me? → yes|no. Same logic as github's _pr_actionable, minus
# the reviews channel (GitLab has none). max-of-empty is null (sorts lowest) → first human event wins.
_mr_actionable() {
  local pid="$1" iid="$2" me="$3" g
  g="$(_mr_norm "$pid" "$iid" 2>/dev/null || true)"
  [[ -n "$g" ]] || { echo no; return 0; }
  if printf '%s' "$g" | jq -e --arg me "$me" '
      ( ([ .commits[] ] + [ .comments[]|select(.author==$me)|.at ]) | map(select(.!=null)) | (if length>0 then max else null end) ) as $bot
      | ( [ .threads[] | select(.isResolved|not) | select(.last_author!=$me) ] | length > 0 )
        or ( [ .comments[]|select(.author!=$me)|.at ] | map(select(.!=null)) | (if length>0 then max else null end) as $h
             | ($h!=null) and (($bot==null) or ($h>$bot)) )
    ' >/dev/null 2>&1; then echo yes; else echo no; fi
}

# REVIEWS-PENDING — my in-review issues in scope whose MR has actionable feedback → [{number,title,pr}].
cmd_reviews_pending() {
  local scope="${1:?scope label required}" me out='[]' pid issues num title iid
  me="$(cmd_whoami)"
  # Without my own username I can't tell my replies from a human's (self-limiting breaks) — report nothing
  # pending rather than spuriously flag; the next iteration retries once glab auth is back.
  [[ -n "$me" ]] || { echo "[]"; return 0; }
  pid="$(_project_id 2>/dev/null || true)"; [[ -n "$pid" ]] || { echo "[]"; return 0; }
  issues="$(_glab issue list --label "$scope" --label in-review --assignee=@me --per-page 200 --output json 2>/dev/null | jq -c '[.[] | {iid, title}]' 2>/dev/null || echo '[]')"
  while IFS=$'\t' read -r num title; do
    [[ -n "$num" ]] || continue
    iid="$(_mr_for "$num")"; [[ -n "$iid" ]] || continue
    [[ "$(_mr_actionable "$pid" "$iid" "$me")" == "yes" ]] || continue
    out="$(jq -nc --argjson a "$out" --argjson n "$num" --arg t "$title" --argjson p "$iid" '$a + [{number:$n,title:$t,pr:$p}]')"
  done < <(printf '%s' "$issues" | jq -r '.[] | "\(.iid)\t\(.title)"')
  printf '%s\n' "$out"
}

# REVIEW-READ — actionable feedback for issue #N (same item shape as github). reply_to for a thread is
# the discussion id; the aggregate conversation item carries reply_to:"conversation".
cmd_review_read() {
  local id="${1:?id required}" me pid iid g meta
  me="$(cmd_whoami)"
  [[ -n "$me" ]] || { echo "✋ review-read: cannot resolve glab username (is glab authed / GITLAB_HOST set?)" >&2; return 1; }
  pid="$(_project_id 2>/dev/null || true)"; [[ -n "$pid" ]] || { echo "✋ review-read: cannot resolve project id" >&2; return 1; }
  iid="$(_mr_for "$id")"
  [[ -n "$iid" ]] || { echo "✋ review-read: no open MR for #$id (source branch ${BRANCH_PREFIX%/}/${id}-…)" >&2; return 1; }
  g="$(_mr_norm "$pid" "$iid" 2>/dev/null || true)"
  [[ -n "$g" ]] || { echo "✋ review-read: could not fetch discussions for MR !$iid (transient glab error?)" >&2; return 1; }
  meta="$(_glab mr view "$iid" --output json 2>/dev/null | jq '{branch:.source_branch, base:.target_branch, url:.web_url}' 2>/dev/null || echo '{}')"
  printf '%s' "$g" | jq --argjson pr "$iid" --arg me "$me" --argjson meta "$meta" '
    ( ([ .commits[] ] + [ .comments[]|select(.author==$me)|.at ]) | map(select(.!=null)) | (if length>0 then max else null end) ) as $bot
    | { pr:$pr, branch:($meta.branch//null), base:($meta.base//null), url:($meta.url//null),
        items: (
          [ .threads[] | select(.isResolved|not) | select(.last_author!=$me)
            | {kind:"thread", reply_to:.reply_to, path, line, conversation:[.comments[]|{author,body}]} ]
          + ( [ .comments[]|select(.author!=$me)|select(($bot==null) or (.at>$bot))|{author,body} ]
              | if length>0 then [ {kind:"comment", reply_to:"conversation", conversation:.} ] else [] end )
        ) }'
}

# REVIEW-REPLY — reply_to="conversation" → a plain MR note; else a discussion id → a reply note in that
# discussion (POST .../discussions/<id>/notes). Quiet on success.
cmd_review_reply() {
  local id="${1:?id required}" ref="${2:?reply_to token required (a discussion id from review-read, or 'conversation')}" body="${3:?body required}" pid iid
  pid="$(_project_id 2>/dev/null || true)"; [[ -n "$pid" ]] || { echo "✋ review-reply: cannot resolve project id" >&2; return 1; }
  iid="$(_mr_for "$id")"
  [[ -n "$iid" ]] || { echo "✋ review-reply: no open MR for #$id" >&2; return 1; }
  if [[ "$ref" == "conversation" ]]; then
    _glab mr note "$iid" -m "$body" >/dev/null
  else
    _glab_api -X POST "projects/${pid}/merge_requests/${iid}/discussions/${ref}/notes" -f "body=${body}" >/dev/null
  fi
}

# Board projection — convenience only; the loop reads NOTHING from the board. No-op (GitLab boards are
# label-driven, so closing/labeling already moves the card).
cmd_board_done() { :; }
