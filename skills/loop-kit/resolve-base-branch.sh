#!/usr/bin/env bash
# resolve-base-branch.sh — resolve + export BASE_BRANCH, the loop's integration branch.
#
# BASE_BRANCH is the branch the loop rebases onto, merges into, opens PRs/MRs against, and that the
# adapters' "is it landed?" check keys on (cmd_branch_merged: `git fetch origin $BASE_BRANCH`,
# `git branch -r --merged origin/$BASE_BRANCH`; cmd_open_pr: --base / --target-branch). It used to be
# the literal `main`, which is WRONG for a repo whose default branch is master/trunk/develop.
#
# Sourced by BOTH `track` (so the adapter sees it) and loop-drive.sh (so the spawned session's own
# git rebase/merge sees the SAME value) AFTER each has sourced the project config — so an explicit
# value (env override or BASE_BRANCH= in plans/loop.config.sh) always WINS; this only fills the gap
# when it is unset/empty. ONE implementation, no drift between the dispatcher and the driver.
#
# Resolution when empty:
#   1) the remote's declared default branch (origin/HEAD, set by `git clone`), minus the origin/ prefix
#   2) origin/HEAD may be unset (fetch-only / CI / manually-added remote) — probe the common names
#   3) nothing resolved (no remote yet) — assume main
# Safe under `set -e`/`pipefail` (the detecting pipe is guarded with `|| true`). Idempotent.

if [[ -z "${BASE_BRANCH:-}" ]]; then
  BASE_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  if [[ -z "$BASE_BRANCH" ]]; then
    for _bb in main master trunk; do
      if git rev-parse --verify --quiet "refs/remotes/origin/$_bb" >/dev/null 2>&1; then BASE_BRANCH="$_bb"; break; fi
    done
    unset _bb
  fi
  [[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="main"
fi
export BASE_BRANCH
