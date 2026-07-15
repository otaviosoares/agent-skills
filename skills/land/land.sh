#!/usr/bin/env bash
# land — post-merge worktree cleanup.
#
# After a PR/MR merges: confirms the host really merged it (gh or glab),
# fast-forwards the default branch from origin, removes the worktree, and
# deletes the local branch. Refuses anything ambiguous or unmerged; no
# --force paths. Auto-detects GitHub vs GitLab from origin's host.
#
# Usage:
#   land.sh [target] [-n|--dry-run]
#
#   target   issue number (76 → sibling <repo>-76), branch name, or worktree
#            path. Omit it to target the worktree you are currently inside.
#   -n       run every check but print the destructive steps instead of
#            executing them.
set -euo pipefail

die() { printf 'land: %s\n' "$*" >&2; exit 1; }

# True if $1 is this process or one of its ancestors — i.e. the claude
# session that locked the worktree is the very session running this script.
pid_is_ancestor() {
  local p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    [ "$p" = "$1" ] && return 0
    p=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}

usage() {
  sed -n '2,16s/^# \{0,1\}//p' "$0"
}

DRY_RUN=false
TARGET=""
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag: $arg (see --help)" ;;
    *) [ -z "$TARGET" ] || die "only one target allowed (got '$TARGET' and '$arg')"; TARGET="$arg" ;;
  esac
done

run() {
  if $DRY_RUN; then
    printf '[dry-run] %s\n' "$*"
  else
    printf '+ %s\n' "$*"
    "$@"
  fi
}

# Resolve the repo from the caller's cwd — the script lives in the skill
# directory, outside any repo, so the cwd is the anchor.
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || die "not inside a git repository — cd into the repo (main checkout or a worktree) first"
MAIN=$(dirname "$COMMON_DIR")
[ -d "$MAIN/.git" ] || die "cannot locate main checkout (resolved: $MAIN)"

DEFAULT_BRANCH=$(git -C "$MAIN" symbolic-ref --short -q refs/remotes/origin/HEAD || true)
DEFAULT_BRANCH=${DEFAULT_BRANCH#origin/}
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main

# ---- pick the forge (GitHub/gh or GitLab/glab) from origin's host ----------
# An explicit LAND_FORGE wins; otherwise detect from the remote. Fail loud on a
# host we can't classify rather than guess the wrong CLI.
FORGE="${LAND_FORGE:-}"
if [ -z "$FORGE" ]; then
  case "$(git -C "$MAIN" remote get-url origin 2>/dev/null)" in
    *github.com*) FORGE=gh ;;
    *gitlab*)     FORGE=glab ;;
    *) die "can't tell GitHub from GitLab for origin's host — set LAND_FORGE=gh|glab" ;;
  esac
fi
case "$FORGE" in
  gh)   PR="PR" SIGIL="#" ;;
  glab) PR="MR" SIGIL="!" ;;
  *) die "LAND_FORGE must be 'gh' or 'glab' (got '$FORGE')" ;;
esac

# Ask the forge about $1's PR/MR. Sets PR_STATE (lowercased), PR_NUM, and PR_SHA
# — the source-branch head the PR recorded, which proves a squash landing.
fetch_pr() {
  local json
  if [ "$FORGE" = gh ]; then
    json=$( (cd "$MAIN" && gh pr view "$1" --json state,number,headRefOid) 2>/dev/null ) \
      || die "no PR found for '$1' (or gh failed) — refusing: merge not confirmed"
    PR_NUM=$(jq -r '.number' <<<"$json"); PR_SHA=$(jq -r '.headRefOid' <<<"$json")
  else
    json=$( (cd "$MAIN" && glab mr view "$1" --output json) 2>/dev/null ) \
      || die "no MR found for '$1' (or glab failed) — refusing: merge not confirmed"
    PR_NUM=$(jq -r '.iid' <<<"$json"); PR_SHA=$(jq -r '.sha' <<<"$json")
  fi
  PR_STATE=$(jq -r '.state' <<<"$json" | tr '[:upper:]' '[:lower:]')
}

# ---- parse `git worktree list --porcelain` into parallel arrays ------------
WT_PATHS=()
WT_BRANCHES=()
WT_STATES=()   # ok | detached | locked
WT_REASONS=()  # lock reason, if any
cur_path="" cur_branch="" cur_state="ok" cur_reason=""
flush_entry() {
  if [ -n "$cur_path" ] && [ "$cur_path" != "$MAIN" ]; then
    WT_PATHS+=("$cur_path")
    WT_BRANCHES+=("$cur_branch")
    WT_STATES+=("$cur_state")
    WT_REASONS+=("$cur_reason")
  fi
  cur_path="" cur_branch="" cur_state="ok" cur_reason=""
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*) cur_path=${line#worktree } ;;
    "branch refs/heads/"*) cur_branch=${line#branch refs/heads/} ;;
    detached) cur_state="detached" ;;
    "locked "*) cur_state="locked"; cur_reason=${line#locked } ;;
    locked) cur_state="locked" ;;
    "") flush_entry ;;
  esac
done < <(git -C "$MAIN" worktree list --porcelain; echo)
flush_entry

# ---- resolve the target -----------------------------------------------------
# An explicit argument always wins over "which worktree am I standing in".
WT_PATH="" BRANCH="" WT_STATE="" WT_REASON=""
if [ -n "$TARGET" ]; then
  target_abs=$(cd "$TARGET" 2>/dev/null && pwd || true)
  match=-1
  if [ "${#WT_PATHS[@]}" -gt 0 ]; then
    for ((i = 0; i < ${#WT_PATHS[@]}; i++)); do
      p=${WT_PATHS[$i]} b=${WT_BRANCHES[$i]}
      hit=false
      [ "$p" = "$TARGET" ] || [ "$p" = "$target_abs" ] || [ "$p" = "$MAIN-$TARGET" ] || [ "$(basename "$p")" = "$TARGET" ] && hit=true
      [ -n "$b" ] && { [ "$b" = "$TARGET" ] && hit=true; case "$b" in */"$TARGET"-*|"$TARGET"-*) hit=true ;; esac; }
      if $hit; then
        [ "$match" -ge 0 ] && [ "$match" != "$i" ] && die "'$TARGET' is ambiguous: matches ${WT_PATHS[$match]} and $p"
        match=$i
      fi
    done
  fi
  if [ "$match" -ge 0 ]; then
    WT_PATH=${WT_PATHS[$match]} BRANCH=${WT_BRANCHES[$match]} WT_STATE=${WT_STATES[$match]} WT_REASON=${WT_REASONS[$match]}
  else
    # No worktree — maybe a leftover branch from an interrupted run.
    candidates=$(git -C "$MAIN" for-each-ref --format='%(refname:short)' \
      "refs/heads/$TARGET" "refs/heads/*/$TARGET-*" "refs/heads/$TARGET-*" | sort -u)
    if git -C "$MAIN" show-ref --verify -q "refs/heads/$TARGET"; then
      candidates=$TARGET   # an exact branch name beats prefix matches
    fi
    count=$(printf '%s' "$candidates" | grep -c . || true)
    [ "$count" -eq 0 ] && die "nothing matches '$TARGET' — no worktree, no branch"
    [ "$count" -gt 1 ] && die "'$TARGET' is ambiguous between branches:
$candidates"
    BRANCH=$candidates
    printf 'No worktree for %s — branch-only cleanup of %s\n' "$TARGET" "$BRANCH"
  fi
else
  cwd_top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$cwd_top" ] || die "cannot determine current worktree — pass an issue number, branch, or worktree path"
  [ "$cwd_top" != "$MAIN" ] \
    || die "you're in the main checkout — pass an issue number, branch, or worktree path"
  WT_PATH=$cwd_top
  if [ "${#WT_PATHS[@]}" -gt 0 ]; then
    for ((i = 0; i < ${#WT_PATHS[@]}; i++)); do
      if [ "${WT_PATHS[$i]}" = "$WT_PATH" ]; then
        BRANCH=${WT_BRANCHES[$i]} WT_STATE=${WT_STATES[$i]} WT_REASON=${WT_REASONS[$i]}
      fi
    done
  fi
  [ -n "$BRANCH$WT_STATE" ] || die "cwd worktree $WT_PATH is not in 'git worktree list'"
fi

# ---- safety gates (all before anything destructive) -------------------------
# Locks: Claude Code locks a worktree while a session works in it, stamping
# "claude session <name> (pid N ...)" as the reason. If that pid is gone (or
# was recycled by a non-claude process) the lock is stale — the merge/dirt
# gates below still protect the content, so unlock and continue. A live
# claude pid, or any lock we can't attribute, still refuses.
NEED_UNLOCK=false
if [ -n "$WT_PATH" ]; then
  [ "$WT_STATE" = "detached" ] && die "$WT_PATH has a detached HEAD (mid-rebase/bisect?) — resolve it manually"
  if [ "$WT_STATE" = "locked" ]; then
    lock_pid=$(printf '%s' "$WT_REASON" | sed -nE 's/^claude session .*\(pid ([0-9]+)[ )].*/\1/p')
    if [ -z "$lock_pid" ]; then
      die "$WT_PATH is locked (reason: ${WT_REASON:-none given}) — 'git worktree unlock $WT_PATH' first if you're sure"
    fi
    lock_cmd=$(ps -p "$lock_pid" -o command= 2>/dev/null || true)
    case "$lock_cmd" in
      *claude*)
        if pid_is_ancestor "$lock_pid"; then
          # Landing from inside your own worktree: the locking session is the
          # one running this script. Unlocking your own lock overrides nobody;
          # the merge/dirt gates below still decide whether removal happens.
          printf 'Lock is held by this session (pid %s) — will unlock before removal\n' "$lock_pid"
        else
          die "$WT_PATH is locked by a live claude session (pid $lock_pid) — end that session and re-run, or 'git worktree unlock $WT_PATH' if you're sure it's only idling"
        fi
        ;;
      *)
        printf 'Lock is stale (claude session pid %s is gone) — will unlock before removal\n' "$lock_pid"
        ;;
    esac
    NEED_UNLOCK=true
  fi
  [ -n "$BRANCH" ] || die "cannot determine the branch checked out in $WT_PATH"
fi

STALE=false
DS_JUNK=""
if [ -n "$WT_PATH" ]; then
  if [ ! -d "$WT_PATH" ]; then
    STALE=true
    printf '%s no longer exists on disk — will remove the stale worktree entry\n' "$WT_PATH"
  else
    wt_status=$(git -C "$WT_PATH" status --porcelain)
    DS_JUNK=$(printf '%s\n' "$wt_status" | grep -E '^\?\? (.*/)?\.DS_Store$' || true)
    real_dirt=$(printf '%s\n' "$wt_status" | grep -vE '^\?\? (.*/)?\.DS_Store$' | grep -v '^$' || true)
    [ -z "$real_dirt" ] || die "$WT_PATH has uncommitted changes — commit, stash, or discard them first:
$real_dirt"
  fi
fi

main_head=$(git -C "$MAIN" symbolic-ref --short -q HEAD || true)
[ "$main_head" = "$DEFAULT_BRANCH" ] || die "main checkout is on '${main_head:-detached HEAD}', not $DEFAULT_BRANCH — fix that first"
main_dirt=$(git -C "$MAIN" status --porcelain --untracked-files=no)
[ -z "$main_dirt" ] || die "main checkout has uncommitted changes — a pull could clash:
$main_dirt"

printf 'Fetching origin (--prune)...\n'
git -C "$MAIN" fetch origin --prune --quiet

# The PR/MR itself is the only proof of merge. An ancestor check alone would
# pass for a fresh zero-commit branch (nothing merged, worktree env still
# valuable) — so host confirmation is unconditional.
printf "Checking %s state for '%s'...\n" "$PR" "$BRANCH"
fetch_pr "$BRANCH"
[ "$PR_STATE" = "merged" ] || die "$PR $SIGIL$PR_NUM for '$BRANCH' is '$PR_STATE', not merged"

TIP=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH")
DELETE_WHY=""
if git -C "$MAIN" merge-base --is-ancestor "$TIP" "origin/$DEFAULT_BRANCH"; then
  DELETE_FLAG="-d"    # tip fully contained in the default branch (normal merge commit)
elif [ "$TIP" = "$PR_SHA" ]; then
  DELETE_FLAG="-D"    # tip is exactly the merged PR/MR head → squash or rebase merge
  DELETE_WHY="branch tip $(git -C "$MAIN" rev-parse --short "$TIP") is exactly what $PR $SIGIL$PR_NUM merged"
else
  # SHA lineage can't account for the tip — rebase-before-merge and multi-
  # commit squashes rewrite it on the server. Fall back to content: merge the
  # branch into origin/<default> in memory; if the result IS origin/<default>'s
  # tree, the branch holds nothing that hasn't already landed. Any genuinely
  # unmerged change yields a different tree (or a conflict) and still refuses.
  main_tree=$(git -C "$MAIN" rev-parse "origin/$DEFAULT_BRANCH^{tree}")
  merged_tree=$(git -C "$MAIN" merge-tree --write-tree "origin/$DEFAULT_BRANCH" "$TIP" 2>/dev/null | head -n1) || merged_tree=""
  if [ -n "$merged_tree" ] && [ "$merged_tree" = "$main_tree" ]; then
    DELETE_FLAG="-D"
    DELETE_WHY="merging '$BRANCH' into origin/$DEFAULT_BRANCH changes nothing — its content already landed via $PR $SIGIL$PR_NUM"
  else
    # Content genuinely beyond the merge — deleting would orphan it.
    die "local '$BRANCH' has content beyond merged $PR $SIGIL$PR_NUM — push or salvage it first (+ = patch not found upstream):
$(git -C "$MAIN" cherry -v "origin/$DEFAULT_BRANCH" "refs/heads/$BRANCH")"
  fi
fi
printf '%s %s%s is merged; local tip accounted for.\n' "$PR" "$SIGIL" "$PR_NUM"

# ---- do it -------------------------------------------------------------------
run git -C "$MAIN" pull --ff-only origin "$DEFAULT_BRANCH"
if [ -n "$WT_PATH" ]; then
  if $NEED_UNLOCK; then
    run git -C "$MAIN" worktree unlock "$WT_PATH"
  fi
  if [ -n "$DS_JUNK" ] && [ "$STALE" = false ]; then
    run find "$WT_PATH" -name .DS_Store -delete
  fi
  run git -C "$MAIN" worktree remove "$WT_PATH"
fi
run git -C "$MAIN" branch "$DELETE_FLAG" "$BRANCH"
if [ "$DELETE_FLAG" = "-D" ]; then
  printf '(-D was safe: %s)\n' "$DELETE_WHY"
fi

# ---- report ------------------------------------------------------------------
printf '\nDone%s:\n' "$($DRY_RUN && printf ' (dry run — nothing changed)')"
[ -n "$WT_PATH" ] && printf '  removed worktree  %s\n' "$WT_PATH"
printf '  deleted branch    %s (%s %s%s)\n' "$BRANCH" "$PR" "$SIGIL" "$PR_NUM"
printf '  %s now at       %s\n' "$DEFAULT_BRANCH" "$(git -C "$MAIN" log -1 --oneline)"
printf '\nRemaining worktrees:\n'
git -C "$MAIN" worktree list
if [ -n "$WT_PATH" ] && [ "$DRY_RUN" = false ]; then
  case "$PWD/" in
    "$WT_PATH"/*) printf '\nNOTE: your shell is inside the removed worktree — cd %s\n' "$MAIN" ;;
  esac
fi
