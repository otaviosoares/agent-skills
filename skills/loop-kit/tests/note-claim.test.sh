#!/usr/bin/env bash
# tests/note-claim.test.sh — unit tests for the github note-strategy claim arbitration.
#
# WHAT: drives the ACTUAL `_owner_filter` jq program from adapters/github.sh (sourced, not copied, so the
# test can't drift from the code) through every concurrency scenario the two-level CAS must survive, and
# asserts the elected owner. This locks the subtle part — who wins a race, and who owns a claim after a
# crash / abort / re-claim — without needing a live GitHub repo.
#
# WHY jq and not gh: gh's `--jq` is gojq; this harness pipes the same filter through the system `jq`.
# Both implement reduce/capture/test/to_entries/ascii_downcase/startswith identically for these programs.
# The end-to-end gh path (eventual consistency, real comments) still wants the live smoke test at the
# bottom of this file — run it by hand against a throwaway repo before trusting multi-runner in anger.
#
# RUN:  ./tests/note-claim.test.sh        (exits non-zero on any failure)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v jq >/dev/null || { echo "✋ jq required to run these tests" >&2; exit 1; }

# Source the adapter for the real _owner_filter + _lc. REPO is referenced only inside _gh at call time,
# so sourcing with a dummy is safe and executes nothing.
REPO="owner/repo"; TRACKER_BACKEND=github
# shellcheck disable=SC1091
source adapters/github.sh

pass=0; fail=0
# assert <name> <prefix> <expected> <comment-body…>  — each extra arg is one comment body, in order.
assert() {
  local name="$1" pfx="$2" want="$3"; shift 3
  local arr="[]" b
  for b in "$@"; do arr="$(jq -c --arg b "$b" '. + [{body:$b}]' <<<"$arr")"; done
  local got; got="$(jq -r "$(_owner_filter "$pfx")" <<<"{\"comments\":$arr}")"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass+1)); printf '  ✓ %s\n' "$name"
  else
    fail=$((fail+1)); printf '  ✗ %s\n      want: %q\n      got:  %q\n' "$name" "$want" "$got"
  fi
}

echo "claim-owner (all logins — RECONCILE's gate):"
assert "single round: smallest wins even if it posted FIRST"        "" "bob#a1" \
  "claimed by bob#a1" "claimed by bob#a2"
assert "single round: smallest wins even if loser posted LAST"      "" "bob#a1" \
  "claimed by bob#a2" "claimed by bob#a1"
assert "abort+takeover: a1 releases, a2 claims → a2 owns"           "" "bob#a2" \
  "claimed by bob#a1" "released by bob#a1" "claimed by bob#a2"
assert "crash (no release): a1's claim still owns — a1 must reup"   "" "bob#a1" \
  "claimed by bob#a1" "claimed by bob#a2"
assert "a1 reups after its own release → a1 owns again"             "" "bob#a1" \
  "claimed by bob#a1" "released by bob#a1" "claimed by bob#a2" "claimed by bob#a1"
assert "all released → free (empty)"                                "" "" \
  "claimed by bob#a1" "released by bob#a1"
assert "assignee-mode / no markers → empty"                        "" "" \
  "PR opened: http://x — awaiting human merge."
assert "cross-login: smallest login owns (alice < bob)"            "" "alice#z" \
  "claimed by bob#a1" "claimed by alice#z"

echo "level-2 (login-scoped — _claim_note's tie-break within the winning login):"
assert "scope bob#: ignore alice, smallest live bob wins"          "bob#" "bob#a1" \
  "claimed by alice#z" "claimed by bob#a2" "claimed by bob#a1"
assert "scope bob#: a2 wins after a1 released"                     "bob#" "bob#a2" \
  "claimed by bob#a1" "released by bob#a1" "claimed by bob#a2"
assert "scope bob#: no bob markers → empty"                        "bob#" "" \
  "claimed by alice#z"

echo
echo "result: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

# ─────────────────────────────────────────────────────────────────────────────────────────────────────
# LIVE SMOKE (manual; not run above). Proves the end-to-end gh path + eventual consistency on a real repo.
#
#   gh repo create my-loop-kit-test --private --clone && cd my-loop-kit-test
#   gh label create in-progress; gh label create wave:1
#   ISSUE=$(gh issue create --title "race me" --label wave:1 --json number --jq .number)
#   export REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) TRACKER_BACKEND=github CLAIM_STRATEGY=note
#   # Two agents under ONE login, distinct RUNNER_IDs, racing the SAME issue — expect exactly one `won`:
#   ( RUNNER_ID=agent-1 ./track claim "$ISSUE" ) & ( RUNNER_ID=agent-2 ./track claim "$ISSUE" ) & wait
#   # Expect: one prints `won`, one prints `lost`. Then check the elected owner is the winner:
#   ./track claim-owner "$ISSUE"      # → the winning login#runner
#   RUNNER_ID=agent-2 ./track whoami  # → bob#agent-2 ; compare for the reconcile gate
# ─────────────────────────────────────────────────────────────────────────────────────────────────────
