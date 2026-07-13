#!/usr/bin/env bash
# plans/run-loop.sh — human launcher for the loop-kit build loop.
#
# The loop-kit runtime (driver + `track` dispatcher + adapters) is delivered as the
# `loop-kit` agent skill, NOT vendored in this repo. This thin wrapper LOCATES the installed skill and
# hands off to its driver — the one path a human must type that can't yet use $LOOP_KIT_DIR (the
# driver is what SETS it; chicken-and-egg). `init` copies this template in as plans/run-loop.sh.
#
# Usage (paths are repo-relative; run from the repo):
#   ./plans/run-loop.sh                               # launch the loop on the kit's default SKELETON runbook
#                                                     #   (loop-runbook.md)
#   ./plans/run-loop.sh "extra context…"              # same, plus extra inline context for this run
#   ./plans/run-loop.sh <runbook> [extra context…]   # launch on an explicit (non-default) runbook file
#   ./plans/run-loop.sh --print-kit-dir               # print the resolved kit dir (for wiring checks)
#   LOOP_KIT_DIR=/path ./plans/run-loop.sh …          # force a specific kit dir (skips discovery)
# The driver defaults RUNBOOK to the skeleton itself — this launcher doesn't set it. Driver env
# passthrough (TRACKER_BACKEND, MODEL, EFFORT, MAX_ITERS, …) is honored.
set -euo pipefail

# This repo's root (the script lives at <repo>/plans/run-loop.sh).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_kit() {
  # an explicit override wins (and validates it)
  if [[ -n "${LOOP_KIT_DIR:-}" && -x "$LOOP_KIT_DIR/loop-drive.sh" ]]; then
    printf '%s\n' "$LOOP_KIT_DIR"; return 0
  fi
  # search install locations: project-local skill, user skill dir, vendored copy, dev checkout.
  local c
  for c in \
    "$REPO_ROOT/.claude/skills/loop-kit" \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/loop-kit" \
    "$HOME/.claude/skills/loop-kit" \
    "$REPO_ROOT/plans/loop-kit" \
    "$HOME/Projects/agent-skills/skills/loop-kit"; do
    [[ -n "$c" && -x "$c/loop-drive.sh" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

KIT="$(find_kit)" || {
  {
    echo "✋ loop-kit skill not found. Either:"
    echo "     • install it:   npx skills add otaviosoares/agent-skills@loop-kit"
    echo "     • point at it:  LOOP_KIT_DIR=/abs/path/to/loop-kit ./plans/run-loop.sh …"
    echo "     • vendor it:    copy the kit into ./plans/loop-kit/"
  } >&2
  exit 1
}

# --print-kit-dir: just resolve + print (used by wiring checks, e.g. `track caps`).
if [[ "${1:-}" == "--print-kit-dir" ]]; then printf '%s\n' "$KIT"; exit 0; fi

# Run from the repo root so the driver derives THIS repo from the CWD, then hand off.
cd "$REPO_ROOT"
exec "$KIT/loop-drive.sh" "$@"
