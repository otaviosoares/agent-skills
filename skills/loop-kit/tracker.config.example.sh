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
#   TRACKER_BACKEND=gitlab LAND_MODE=pr ./plans/run-loop.sh

# Which backend adapter to load: github | gitlab | clickup  (must match the kit's adapters/<backend>.sh;
# a `local` backend is planned but ships no adapter yet — selecting it fails loud).
export TRACKER_BACKEND="${TRACKER_BACKEND:-github}"

# Landing policy: merge = merge to main unattended (autonomous); pr = open a PR/MR + hand off to a human.
# NOTE: clickup hosts no code → it supports merge ONLY (can_open_pr=false). LAND_MODE=pr fails loud there.
export LAND_MODE="${LAND_MODE:-merge}"

# Repo / owner slug for the server backends (github: owner/name; gitlab: group/project). clickup/local: unused.
export REPO="${REPO:-owner/repo}"

# The per-wave run-log handle the adapter resolves
# (github issue number / gitlab issue iid / clickup task id / local file path).
export RUNLOG="${RUNLOG:-<run-log issue#/iid/task-id/file>}"

# Default queue scope label (the runbook usually passes this explicitly; this is the fallback).
export WAVE="${WAVE:-wave:1}"

# Branch / worktree naming. Must stay consistent — RECONCILE's "is it landed?" check greps on it,
# and it is backend-neutral (avoid host-shaped "Merge #N", which breaks on GitLab's !N MR iids).
export BRANCH_PREFIX="${BRANCH_PREFIX:-<prefix>}"

# Claim mechanism (github + gitlab). assignee (default) = add-assignee + login-sort CAS; REQUIRES each
# runner a DISTINCT login. note = comment-marker CAS that lets N agents SHARE ONE login (e.g. a teammate
# running two agents under one account) — every runner still assigns its login up front, so note and
# assignee runners INTEROP safely on the same issue. (gitlab: note is also the Free-tier single-assignee
# fallback.) clickup ignores this. INVARIANT: a given login is wholly one strategy — never both.
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

# ── ClickUp (REST API v2; TRACKER_BACKEND=clickup) ──────────────────────────────────────────────
# ClickUp has no official CLI — the adapter curls the API with a raw `pk_…` personal token. The tracker
# unit is a LIST (not owner/repo); scope/labels are space TAGS; open|closed is the status TYPE. ClickUp
# is natively multi-assignee, so the default assignee-union claim is always safe (no `note` fallback
# needed). REQUIRES each runner authed as a DISTINCT user (a distinct CLICKUP_TOKEN) for multi-runner.
# export CLICKUP_TOKEN="${CLICKUP_TOKEN:-pk_xxx}"          # personal token (raw, in the Authorization header)
# export CLICKUP_LIST_ID="${CLICKUP_LIST_ID:-}"           # the list whose tasks are the loop queue (the REPO analog)
# export CLICKUP_STATUS_DONE="${CLICKUP_STATUS_DONE:-closed}"  # the done/closed status NAME `close` sets (its type must be closed/done)
# export CLICKUP_API="${CLICKUP_API:-https://api.clickup.com/api/v2}"  # override for an enterprise/self-managed endpoint
# PRECONDITION: create the `in-progress` and `in-review` tags in the space once (the runtime attaches
# existing space tags). RUNLOG above = a ClickUp TASK id whose comments are the run-log.

# ── GitHub Projects-v2 board (OPTIONAL; github producer only) ───────────────────────────────────
# materialize-github.mjs places each created issue on a board and sets fields. These ids are
# PER-PROJECT (discover with `gh project list` + `gh project field-list <n> --owner <o>`). Leave the
# core three UNSET and the board hook is a NO-OP (issues are still created; they just aren't placed).
# Field ids are individually optional — an unset field is skipped.
# export GH_PROJECT="${GH_PROJECT:-}"             # project NUMBER (e.g. 1)
# export GH_PROJECT_OWNER="${GH_PROJECT_OWNER:-}" # owner login/org
# export GH_PROJECT_ID="${GH_PROJECT_ID:-}"       # project node id (PVT_…)
# export GH_FIELD_WAVE="${GH_FIELD_WAVE:-}"       # number field id (PVTF_…) ← from the wave:N label
# export GH_FIELD_PLAN="${GH_FIELD_PLAN:-}"       # text field id   ← milestone
# export GH_FIELD_PKGS="${GH_FIELD_PKGS:-}"       # text field id   ← from shared-pkg:* labels
# export GH_FIELD_SIZE="${GH_FIELD_SIZE:-}"       # text field id   ← from the size:* label
