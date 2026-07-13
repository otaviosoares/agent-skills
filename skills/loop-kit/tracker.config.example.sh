#!/usr/bin/env bash
# tracker.config.example.sh — SANITIZED TEMPLATE for a new repo's tracker config.
#
# This file ships INSIDE the kit and carries NO project IP — it is the placeholder template the
# loop-kit skill copies into a new repo as plans/loop.config.sh (which then lives OUTSIDE the kit).
# `track` sources, in order: $TRACKER_CONFIG → <repo>/plans/loop.config.sh → THIS example (fallback,
# with a warning). The driver (loop-drive.sh) exports TRACKER_CONFIG=<repo>/plans/loop.config.sh, so
# in skill mode the per-repo config is always found. To onboard a repo: copy this to
# plans/loop.config.sh and fill in real values.
#
# Every value uses ${VAR:-default} so an env override always wins, e.g.:
#   TRACKER_BACKEND=gitlab ./plans/run-loop.sh

# Which backend adapter to load: github | gitlab  (must match the kit's adapters/<backend>.sh;
# a `local` backend is planned but ships no adapter yet — selecting it fails loud).
export TRACKER_BACKEND="${TRACKER_BACKEND:-github}"

# Review-response: on (default) = the loop also drains UNADDRESSED human review feedback on
# its open PRs — a responder sub-agent reads the comments, fixes the branch, pushes, and replies inline
# (it never resolves threads, re-requests review, or merges — you stay the gate). off = the pure human-only
# gate: a PR sits untouched until you merge it. Self-limiting: once the bot replies to a
# thread/comment, it is no longer "pending", so there is no re-processing loop.
export REVIEW_RESPONSE="${REVIEW_RESPONSE:-on}"

# Repo / owner slug (github: owner/name; gitlab: group/project).
export REPO="${REPO:-owner/repo}"

# The run-log handle the adapter resolves (github issue number / gitlab issue iid).
export RUNLOG="${RUNLOG:-<run-log issue#/iid>}"

# Default queue scope label (the runbook usually passes this explicitly; this is the fallback).
export WAVE="${WAVE:-wave:1}"

# Branch / worktree naming. Must stay consistent — RECONCILE's "is it landed?" check greps on it,
# and it is backend-neutral (avoid host-shaped "Merge #N", which breaks on GitLab's !N MR iids).
export BRANCH_PREFIX="${BRANCH_PREFIX:-<prefix>}"

# Integration branch: the loop's rebase target, merge/PR/MR base, and the "is it landed?" check.
# LEAVE EMPTY to auto-detect this repo's default branch (origin/HEAD, falling back to main) — so a
# repo whose default is master/trunk works without any config. Set it explicitly only to pin a
# specific integration branch, e.g. a release train: BASE_BRANCH=develop.
export BASE_BRANCH="${BASE_BRANCH:-}"

# Claim mechanism (github + gitlab). assignee (default) = add-assignee + login-sort CAS; REQUIRES each
# runner a DISTINCT login. note = comment-marker CAS that lets N agents SHARE ONE login (e.g. a teammate
# running two agents under one account) — every runner still assigns its login up front, so note and
# assignee runners INTEROP safely on the same issue. (gitlab: note is also the Free-tier single-assignee
# fallback.) INVARIANT: a given login is wholly one strategy — never both.
export CLAIM_STRATEGY="${CLAIM_STRATEGY:-assignee}"

# github note-strategy: REQUIRED, per-AGENT id appended to the login in the claim marker (claimant =
# login#RUNNER_ID). Ownership is identity-based — a downed agent recovers its OWN claim by reuping with
# the SAME id — so the id must be STABLE across restarts AND DISTINCT between concurrent agents. There is
# NO safe default (hostname is stable but collides for two agents on one host; host-pid is unique but
# changes on restart), so set it explicitly per agent and DON'T pass it via loop.config.sh — put it on
# each agent's command line so two agents differ:  RUNNER_ID=agent-1 ./plans/run-loop.sh
#                                                  RUNNER_ID=agent-2 ./plans/run-loop.sh
# (gitlab note mode is username-granular and ignores RUNNER_ID.) No time windows: a build of any length is
# safe, and git's non-fast-forward push remains the final backstop against a double merge.

# ── GitLab (glab CLI; TRACKER_BACKEND=gitlab) ───────────────────────────────────────────────────
# RUN THE LOOP UNDER ITS OWN IDENTITY. The REVIEW-RESPONSE phase is self-limiting on the glab username
# — it tells "my replies" from "human feedback" purely by author. If the loop and the human reviewer
# share ONE glab account, every human comment reads as the bot's own and `reviews-pending` is always
# empty. So auth the loop as a DISTINCT identity (a project/group access token — scope api, role
# Developer; or a second user's PAT) and review as yourself. glab honors GITLAB_TOKEN and it overrides
# ~/.config/glab-cli, so setting it HERE binds the bot identity to the loop (via TRACKER_CONFIG) without
# touching your interactive glab. (Solo is fine: the issue is assigned to the bot; you review as you.)
# export GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-xxx}"   # the loop's bot identity (prefer the secrets file below — keep tokens out of git)
# export GITLAB_HOST="${GITLAB_HOST:-}"              # self-hosted host (e.g. gitlab.example.com); empty = gitlab.com
#
# Keep the token OUT of git: put `export GITLAB_TOKEN=glpat-…` in an UNTRACKED sibling file and source
# it. The `if` guard makes a MISSING file a clean no-op — never an error, even under `set -e` (unlike a
# `&& source` chain, whose failed test can trip errexit):
#   echo 'plans/loop.secrets.sh' >> .gitignore        # then put `export GITLAB_TOKEN=glpat-…` inside it
# if [[ -f "$(dirname "${BASH_SOURCE[0]}")/loop.secrets.sh" ]]; then
#   source "$(dirname "${BASH_SOURCE[0]}")/loop.secrets.sh"
# fi
