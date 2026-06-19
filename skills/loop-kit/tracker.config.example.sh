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
#   TRACKER_BACKEND=gitlab LAND_MODE=pr ./plans/run-loop.sh plans/wave-loop.md

# Which backend adapter to load: github | gitlab  (must match the kit's adapters/<backend>.sh;
# a `local` backend is planned but ships no adapter yet — selecting it fails loud).
export TRACKER_BACKEND="${TRACKER_BACKEND:-github}"

# Landing policy: merge = merge to main unattended (autonomous); pr = open a PR/MR + hand off to a human.
export LAND_MODE="${LAND_MODE:-merge}"

# Repo / owner slug for the server backends (github: owner/name; gitlab: group/project). Local: unused.
export REPO="${REPO:-owner/repo}"

# The per-wave run-log handle the adapter resolves (github issue number / gitlab issue iid / local file path).
export RUNLOG="${RUNLOG:-<run-log issue#/iid/file>}"

# Default queue scope label (the runbook usually passes this explicitly; this is the fallback).
export WAVE="${WAVE:-wave:1}"

# Branch / worktree naming. Must stay consistent — RECONCILE's "is it landed?" check greps on it,
# and it is backend-neutral (avoid host-shaped "Merge #N", which breaks on GitLab's !N MR iids).
export BRANCH_PREFIX="${BRANCH_PREFIX:-<prefix>}"

# GitLab-only: claim mechanism. assignee = additive-+ assignee union (needs a paid multi-assignee tier);
# note = note-marker CAS fallback for Free tier (single assignee). Ignored by other backends.
export CLAIM_STRATEGY="${CLAIM_STRATEGY:-assignee}"

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
