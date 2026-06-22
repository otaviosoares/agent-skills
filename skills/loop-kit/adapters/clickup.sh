#!/usr/bin/env bash
# adapters/clickup.sh — the ClickUp (REST API v2) tracker adapter.
#
# Mirrors adapters/github.sh VERB-FOR-VERB (identical cmd_* names) so the dispatcher and runbook never
# change — TRACKER_BACKEND=clickup is the only switch. Unlike github/gitlab there is NO official CLI,
# so every call is `curl` against https://api.clickup.com/api/v2 authed with a personal token
# (CLICKUP_TOKEN, the raw `pk_…` value in the Authorization header). Project values
# (CLICKUP_LIST_ID, RUNLOG, BRANCH_PREFIX, CLICKUP_STATUS_DONE) come from plans/loop.config.sh; ./track
# sources both before dispatch.
#
# MODEL MAPPING (ClickUp ≠ a code host):
#   tracker unit   = a ClickUp LIST (CLICKUP_LIST_ID) — the analog of github's REPO. Tasks live here.
#   work-item id   = the ClickUp TASK id (an opaque string like "86b1xyz"); emitted in the `number` field.
#   scope / labels = ClickUp TAGS (space-scoped). `in-progress` / `in-review` must pre-exist in the space.
#   open|closed    = ClickUp STATUS *type* — type closed|done ⇒ closed, anything else ⇒ open (the dep gate).
#   close          = set status to CLICKUP_STATUS_DONE (default "closed"; its type must be closed/done).
#   run-log        = a ClickUp TASK (RUNLOG) whose COMMENTS are the chronological run-log.
#
# The lock CONTRACT this adapter satisfies (see REFERENCE.md) is IDENTICAL to github.sh — only the
# MECHANISM differs: of N racing runners exactly one wins, the loser detects it and yields, the lock is
# owner-releasable, and the claimant id (the ClickUp numeric user id) is stable+unique+comparable+crash-
# surviving. Mechanism: ADD myself to the task's assignee set (ClickUp is natively multi-assignee, so
# this is a true additive union — never a replace) + in-progress tag, stabilize re-read, winner =
# NUMERICALLY-smallest assignee id. Same best-effort-CAS shape as the others; the PICK contention-overlap
# skip and git's non-fast-forward push rejection at LAND are the backstops. REQUIRES each runner authed
# as a DISTINCT ClickUp user (a distinct CLICKUP_TOKEN). One shared token → degrade to single-runner.
#
# CAPABILITY NOTE: ClickUp hosts no code, so there is NO PR/MR. can_open_pr=false, land_modes=merge only
# (the git push to the base branch happens against whatever code host the repo uses; branch-merged is
# git-only). LAND_MODE=pr is unsupported here — open-pr fails loud.
#
# DEPENDENCY: jq + curl. Convention: read verbs print to stdout; mutating verbs are quiet unless they
# return a value (claim → won|lost, branch-merged/item-state → token). Non-fatal cleanup uses || true.

API="${CLICKUP_API:-https://api.clickup.com/api/v2}"

# GET an api path → stdout (raw JSON). Fails loud (curl -fsS) on a non-2xx, like github/gitlab read verbs.
_cu_get() {
  curl -fsS -H "Authorization: ${CLICKUP_TOKEN:?CLICKUP_TOKEN required (the pk_… personal token) in plans/loop.config.sh}" \
    "$API/$1"
}

# Send a mutating request: _cu_send <METHOD> <path> <json-body>. Empty body is fine (tag add/remove).
_cu_send() {
  local method="$1" path="$2" data="${3:-}"
  curl -fsS -X "$method" \
    -H "Authorization: ${CLICKUP_TOKEN:?CLICKUP_TOKEN required (the pk_… personal token) in plans/loop.config.sh}" \
    -H "Content-Type: application/json" \
    --data "$data" "$API/$path"
}

# The claimant identity = my ClickUp numeric user id (stable, unique, comparable, crash-surviving).
_me() { _cu_get user | jq -r '.user.id // empty'; }

# URL-encode one query value (tag names, scope) for the api query string.
_enc() { printf '%s' "${1:-}" | jq -sRr @uri; }

# Add / remove a space tag on a task. POST/DELETE /task/{id}/tag/{name} (the tag must exist in the space).
_add_tag() { _cu_send POST   "task/${1}/tag/$(_enc "$2")" >/dev/null 2>&1; }
_rm_tag()  { _cu_send DELETE "task/${1}/tag/$(_enc "$2")" >/dev/null 2>&1; }

# jq: map one raw ClickUp task → github's {number,title,labels,assignees,state} shape. id→number,
# tags→labels (names), assignees→numeric-id strings, status.type→open|closed.
_NORM='{
  number: .id, title: .name,
  labels: [.tags[].name],
  assignees: [.assignees[].id | tostring],
  state: (if (.status.type=="closed" or .status.type=="done") then "closed" else "open" end)
}'

# capabilities — same shape/keys as github so the driver/runbook read it identically. can_open_pr=false
# (ClickUp hosts no code), land_modes=merge only.
cmd_caps() {
  cat <<EOF
backend=clickup
cross_machine_atomic_claim=true
can_open_pr=false
land_modes=merge
EOF
}

# SYNC — open work-items in scope, normalized to github's {number,title,labels,assignees,state}. Walks
# every page (ClickUp caps a page at 100; `last_page` ends it) so there is NO silent cap — the analog of
# github's `--limit 300`. include_closed=false + archived=false ⇒ only live, open tasks. scope = a tag.
cmd_sync_list() {
  local scope="${1:?scope tag required, e.g. wave:4}" list page=0 enc out all='[]'
  list="${CLICKUP_LIST_ID:?CLICKUP_LIST_ID required in plans/loop.config.sh}"
  enc="$(_enc "$scope")"
  while :; do
    out="$(_cu_get "list/${list}/task?archived=false&include_closed=false&page=${page}&tags%5B%5D=${enc}")"
    all="$(jq -n --argjson a "$all" --argjson b "$(printf '%s' "$out" | jq '.tasks')" '$a + $b')"
    [[ "$(printf '%s' "$out" | jq -r '.last_page')" == "true" ]] && break
    page=$((page + 1))
  done
  printf '%s' "$all" | jq "[.[] | $_NORM]"
}

# Run-log resume trail — last N comments on the RUNLOG task, chronological. ClickUp returns comments
# newest-first; sort by .date (epoch-ms string) ascending and take the last N so a long run-log still
# yields the NEWEST N in chronological order (parity with github's `comments[-N:]`).
cmd_runlog_tail() {
  local n="${1:-2}"
  _cu_get "task/${RUNLOG:?RUNLOG (the run-log task id) required in plans/loop.config.sh}/comment" \
    | jq -r --argjson n "$n" '[.comments[] | {t:(.date|tonumber), b:.comment_text}] | sort_by(.t) | .[(-$n):] | .[].b'
}

# One item, full — used for the brief, dep parse, contention skip. Adds body (←description) + number
# (←id) + normalized labels/assignees/state so a cross-backend consumer reading github's field names works.
cmd_view() {
  _cu_get "task/${1:?id required}" \
    | jq ". + {body: (.description // (.text_content // \"\")), $_NORM}"
}

# Item terminal state as a github-parity token (open|closed) — the dep gate. Keyed on the status TYPE
# (closed|done ⇒ closed) so it's robust to whatever the list names its done status. On a transient view
# failure → empty type → `*)` arm echoes open ⇒ the gate reads "not closed" (safe WAIT), like github's
# tr-on-empty.
cmd_item_state() {
  local t
  t="$(_cu_get "task/${1:?id required}" 2>/dev/null | jq -r '.status.type' 2>/dev/null || true)"
  case "$t" in
    closed | done) echo closed ;;
    *)             echo open ;;
  esac
}

# RECONCILE — my in-progress items in scope (the dangling-claim signal). Filter by assignee=me + the two
# tags, then jq-confirm BOTH tags are present (ClickUp's multi `tags[]` filter is OR, so we AND it here).
cmd_reconcile_mine() {
  local scope="${1:?scope tag required}" list me page=0 enc out all='[]'
  list="${CLICKUP_LIST_ID:?CLICKUP_LIST_ID required in plans/loop.config.sh}"
  me="$(_me)"
  [[ -n "$me" ]] || { echo "[]"; return 0; }   # no identity → no claims to reconcile (safe)
  enc="$(_enc "$scope")"
  while :; do
    out="$(_cu_get "list/${list}/task?archived=false&include_closed=false&page=${page}&assignees%5B%5D=${me}&tags%5B%5D=${enc}&tags%5B%5D=in-progress")"
    all="$(jq -n --argjson a "$all" --argjson b "$(printf '%s' "$out" | jq '.tasks')" '$a + $b')"
    [[ "$(printf '%s' "$out" | jq -r '.last_page')" == "true" ]] && break
    page=$((page + 1))
  done
  printf '%s' "$all" \
    | jq --arg s "$scope" "[.[] | $_NORM | select((.labels | index(\$s)) and (.labels | index(\"in-progress\")))]"
}

# Is a branch already merged into the base branch? GIT-ONLY — ClickUp hosts no code, so there is no
# host-side PR/MR to consult (no squash-landing fallback like github/gitlab). The branch tip being an
# ANCESTOR of origin/$BASE_BRANCH is the only signal, which is exactly the merge-mode landing shape.
# BASE_BRANCH is resolved by `track` (origin/HEAD, not hardcoded main); :-main is a defensive fallback.
cmd_branch_merged() {
  local branch="${1:?branch required}" base="${BASE_BRANCH:-main}"
  git fetch origin "$base" -q 2>/dev/null || true   # avoid a stale origin/$base → false-negative → needless rebuild
  if git branch -r --merged "origin/$base" 2>/dev/null | grep -q "/${branch}\$"; then
    echo yes; return 0
  fi
  echo no
}

# CLAIM (atomic) → prints won|lost. Add myself to the assignee set (ClickUp is natively multi-assignee:
# {"assignees":{"add":[id]}} is a true union, never a replace) + in-progress tag, stabilize, re-read,
# winner = NUMERICALLY-smallest assignee id (computed identically by every racer). Loser releases.
cmd_claim() {
  local id="${1:?id required}" me winner
  me="$(_me 2>/dev/null || true)"   # claimant identity; empty → treated as lost (safe)
  [[ -n "$me" ]] || { echo "✋ cannot resolve ClickUp user id (the claim identity) — is CLICKUP_TOKEN set/valid?" >&2; echo lost; return 0; }
  # Add our claim. If the edit FAILS, release whatever stuck and report lost — never abort mid-claim (that
  # would leave an orphan in-progress tag with no clear winner and print no won|lost for the runbook).
  if ! _cu_send PUT "task/${id}" "{\"assignees\":{\"add\":[${me}]}}" >/dev/null 2>&1; then
    cmd_release "$id"; echo lost; return 0
  fi
  _add_tag "$id" in-progress || true
  # Stabilize against eventual consistency: a concurrent racer's just-added assignee can lag the read, so
  # a naive immediate re-read could see only itself and both racers would "win". Sleep so both re-read a
  # set containing BOTH, then arbitrate: winner = numerically-smallest assignee id. Best-effort CAS; the
  # PICK contention-overlap skip and git's non-fast-forward push rejection at LAND are the backstops.
  sleep 3
  # `|| true`: a transient re-read failure → fall to lost+release (recover next iteration) rather than
  # aborting mid-claim with our assignee still stuck.
  winner="$(_cu_get "task/${id}" 2>/dev/null | jq -r '[.assignees[].id] | sort | .[0] // empty' 2>/dev/null || true)"
  if [[ -n "$winner" && "$winner" == "$me" ]]; then
    echo won
  else
    cmd_release "$id"; echo lost
  fi
}

# Release my claim (lost race / abort). Remove ONLY myself from the assignee set ({"rem":[me]}, never a
# bare clear which would evict the WINNER too) + drop in-progress. If identity can't be resolved, leave
# the claim FULLY intact (assignee + tag) so reconcile-mine (which keys on in-progress) still re-finds it.
cmd_release() {
  local id="${1:?id required}" me
  me="$(_me 2>/dev/null || true)"
  if [[ -z "$me" ]]; then
    echo "ℹ️  release: could not resolve ClickUp user id — leaving claim intact for RECONCILE to retry" >&2
    return 0
  fi
  _cu_send PUT "task/${id}" "{\"assignees\":{\"rem\":[${me}]}}" >/dev/null 2>&1 || true
  _rm_tag "$id" in-progress || true
}

# CLOSE — terminal, merge-mode. Set the done status FIRST (the terminal op, fail-loud); if it fails and
# aborts, the task stays open + assigned + in-progress, so RECONCILE re-finds and re-closes it. Removing
# the tag first would hide a stranded-but-merged task from reconcile-mine (which filters on in-progress).
cmd_close() {
  local id="${1:?id required}"
  _cu_send PUT "task/${id}" "{\"status\":\"${CLICKUP_STATUS_DONE:-closed}\"}" >/dev/null
  _rm_tag "$id" in-progress || true
}

# PR-mode handoff — kept for verb parity, but ClickUp has no PR (open-pr fails loud), so this is normally
# unreachable. If reached: swap in-progress→in-review and note the URL, keeping the task OPEN + assigned.
cmd_mark_review() {
  local id="${1:?id required}" url="${2:-}"
  _rm_tag "$id" in-progress || true
  _add_tag "$id" in-review || true
  if [[ -n "$url" ]]; then
    _cu_send POST "task/${id}/comment" "$(jq -n --arg t "PR opened: ${url} — awaiting human merge." '{comment_text:$t,notify_all:false}')" >/dev/null || true
  fi
}

# LOG — append one run-log entry (arg or stdin) as a comment on the RUNLOG task. Refuse empty (no blank
# comment, no stdin hang on a tty).
cmd_log() {
  local body="${1:-}"
  if [[ -z "$body" && ! -t 0 ]]; then body="$(cat)"; fi
  if [[ -z "$body" ]]; then echo "✋ log: empty entry (pass a body arg or pipe content)" >&2; return 64; fi
  _cu_send POST "task/${RUNLOG:?RUNLOG (the run-log task id) required in plans/loop.config.sh}/comment" \
    "$(jq -n --arg t "$body" '{comment_text:$t,notify_all:false}')" >/dev/null
}

# Open a PR — UNSUPPORTED on ClickUp (it hosts no code). Fail loud so the runbook treats it as a build
# failure (release + BLOCKED) instead of marking a task in-review with no PR. Use LAND_MODE=merge.
cmd_open_pr() {
  echo "✋ open-pr: the clickup backend has no code host — ClickUp cannot open a PR/MR." >&2
  echo "   ClickUp supports LAND_MODE=merge only (caps: can_open_pr=false). Host code on GitHub/GitLab for PR mode." >&2
  return 1
}

# Board projection — no-op. ClickUp board views are status/tag-driven, so the close (status change) +
# tag edits already move the card.
cmd_board_done() { :; }
