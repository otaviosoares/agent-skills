#!/usr/bin/env bash
# tests/runlog-discovery.test.sh — unit tests for run-log resolution by label.
#
# WHAT: drives the ACTUAL `_runlog_pick_jq` selection program from each adapter (sourced, not copied, so
# the test can't drift from the code) over the issue-list shapes the discovery path must handle, and
# asserts which run-log issue id it elects. This locks the subtle part — "which of N open labeled issues
# is the run-log, and what happens when there are none" — without needing a live GitHub/GitLab repo.
#
# WHY jq and not gh/glab: the create-or-reuse dance (search → pick newest → else create) can't run
# offline, but the DECISION it hinges on — pick the newest (highest-numbered) OPEN labeled issue, or
# empty to trigger a create — is a pure function of the list JSON. That is what we pin here; the live
# create/append path wants the smoke test at the bottom of this file before trusting it in anger.
#
# Each adapter is sourced in its OWN subshell (both define cmd_*/_runlog_pick_jq — sourcing both in one
# shell would clobber), mirroring real usage where `track` sources exactly one adapter. A subshell exits
# non-zero on any local failure; the parent ORs those into its exit code.
#
# RUN:  ./tests/runlog-discovery.test.sh        (exits non-zero on any failure)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v jq >/dev/null || { echo "✋ jq required to run these tests" >&2; exit 1; }

# assert <name> <expected> <pick_jq> <raw|slurp> <input-json>  (uses/updates the enclosing pass/fail vars)
#   slurp → pipe through `jq -s` (gitlab paginates a STREAM of page-arrays); raw → a single flat array.
assert() {
  local name="$1" want="$2" prog="$3" mode="$4" input="$5" got
  if [[ "$mode" == "slurp" ]]; then
    got="$(printf '%s' "$input" | jq -s "$prog" 2>/dev/null)"
  else
    got="$(printf '%s' "$input" | jq "$prog" 2>/dev/null)"
  fi
  if [[ "$got" == "$want" ]]; then
    pass=$((pass+1)); printf '  ✓ %s\n' "$name"
  else
    fail=$((fail+1)); printf '  ✗ %s\n      want: %q\n      got:  %q\n' "$name" "$want" "$got"
  fi
}

overall=0

# ── GitHub: input is `gh issue list --json number` output (a flat array of {number}) ───────────────
(
  pass=0; fail=0
  REPO="owner/repo"; TRACKER_BACKEND=github
  # shellcheck disable=SC1091
  source adapters/github.sh
  prog="$(_runlog_pick_jq)"
  echo "github _runlog_pick_jq (newest open labeled issue = highest number):"
  assert "picks the highest number regardless of list order" 7  "$prog" raw '[{"number":3},{"number":7},{"number":5}]'
  assert "single issue → itself"                             10 "$prog" raw '[{"number":10}]'
  assert "empty list → no output (triggers create)"        ''   "$prog" raw '[]'
  echo "  result: $pass passed, $fail failed"
  [[ "$fail" -eq 0 ]]
) || overall=1

# ── GitLab: a STREAM of per-page arrays (glab api --paginate), slurped with `jq -s` ────────────────
(
  pass=0; fail=0
  REPO="group/project"; TRACKER_BACKEND=gitlab
  # shellcheck disable=SC1091
  source adapters/gitlab.sh
  prog="$(_runlog_pick_jq)"
  echo "gitlab _runlog_pick_jq (newest open labeled issue = highest iid, across pages):"
  assert "picks the highest iid across paginated pages"  9 "$prog" slurp '[{"iid":2},{"iid":5}]
[{"iid":9},{"iid":4}]'
  assert "single page, single issue → itself"            6 "$prog" slurp '[{"iid":6}]'
  assert "no pages / empty → no output (triggers create)" '' "$prog" slurp '[]'
  echo "  result: $pass passed, $fail failed"
  [[ "$fail" -eq 0 ]]
) || overall=1

# ── Part B: the create-or-reuse DECISION in _runlog_id ────────────────────────────────────────────
# The pick jq above is pure; the branch AROUND it — "found an open labeled issue → reuse it; none →
# create one, then reuse on the next call" (AC1/AC3) — is the other half. It can't hit a live repo, so
# we STUB the CLI layer (_gh / _glab_api / _project_id) and drive _runlog_id directly, asserting BOTH
# the returned id AND whether a create was issued (a create leaves a marker file — command-substitution
# subshells can't export a flag back, but they can touch a file). This proves reuse never re-creates and
# an empty queue creates exactly once.

# ok/no <name> <cond-exit-status>  — pass iff status is 0 (used with [[ ]] pre-evaluated by the caller)
_ck() { if [[ "$2" == "0" ]]; then pass=$((pass+1)); printf '  ✓ %s\n' "$1"; else fail=$((fail+1)); printf '  ✗ %s\n' "$1"; fi; }

# github: stub _gh so `issue list` returns the (already-picked) id or empty, and `issue create` records
# a marker + prints a realistic issue URL. _runlog_id parses the number from the URL's last path segment.
(
  pass=0; fail=0
  REPO="owner/repo"; TRACKER_BACKEND=github
  # shellcheck disable=SC1091
  source adapters/github.sh
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  _gh() {
    case "$1 $2" in
      "issue list")   printf '%s' "${LIST_OUT:-}" ;;
      # create records a marker; CREATE_FAIL='' → success (print the new issue URL), set → auth fail
      # (empty stdout, exactly what `gh issue create` failing + `|| true` yields).
      "issue create") : >"$tmp/created"; [[ -n "${CREATE_FAIL:-}" ]] || printf 'https://github.com/owner/repo/issues/%s\n' "${CREATE_NUM}" ;;
      *)              : ;;   # label create etc. — no-op
    esac
  }
  echo "github _runlog_id (reuse vs create):"
  rm -f "$tmp/created"; got="$(LIST_OUT=7 _runlog_id)"
  [[ "$got" == 7 ]]; _ck "existing labeled issue → reused (id 7)" "$?"
  [[ ! -e "$tmp/created" ]]; _ck "reuse path issues NO create" "$?"
  rm -f "$tmp/created"; got="$(LIST_OUT='' CREATE_NUM=12 _runlog_id)"
  [[ "$got" == 12 ]]; _ck "empty queue → creates + returns new id (12)" "$?"
  [[ -e "$tmp/created" ]]; _ck "create path issues exactly one create" "$?"
  rm -f "$tmp/created"; got="$(LIST_OUT='' CREATE_FAIL=1 _runlog_id)"   # create failed → empty stdout
  [[ -z "$got" ]]; _ck "create fails (auth) → empty (loud error upstream)" "$?"
  echo "  result: $pass passed, $fail failed"
  [[ "$fail" -eq 0 ]]
) || overall=1

# gitlab: stub _project_id + _glab_api. The list call returns raw page JSON (the REAL pick jq runs on it);
# a `-X POST` call records a marker + returns the created issue object.
(
  pass=0; fail=0
  REPO="group/project"; TRACKER_BACKEND=gitlab
  # shellcheck disable=SC1091
  source adapters/gitlab.sh
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  _project_id() { echo 42; }
  _glab_api() {
    local a; for a in "$@"; do [[ "$a" == "POST" ]] && { : >"$tmp/created"; printf '%s' "${CREATE_OUT:-}"; return 0; }; done
    printf '%s' "${LIST_OUT:-}"
  }
  echo "gitlab _runlog_id (reuse vs create):"
  rm -f "$tmp/created"; got="$(LIST_OUT='[{"iid":9},{"iid":5}]' _runlog_id)"
  [[ "$got" == 9 ]]; _ck "existing labeled issues → reuse newest (iid 9)" "$?"
  [[ ! -e "$tmp/created" ]]; _ck "reuse path issues NO create" "$?"
  rm -f "$tmp/created"; got="$(LIST_OUT='[]' CREATE_OUT='{"iid":12}' _runlog_id)"
  [[ "$got" == 12 ]]; _ck "empty queue → creates + returns new iid (12)" "$?"
  [[ -e "$tmp/created" ]]; _ck "create path issues exactly one create" "$?"
  rm -f "$tmp/created"; got="$(LIST_OUT='[]' CREATE_OUT='{}' _runlog_id)"   # POST returned no iid
  [[ -z "$got" ]]; _ck "create returns no iid → empty (loud error upstream)" "$?"
  echo "  result: $pass passed, $fail failed"
  [[ "$fail" -eq 0 ]]
) || overall=1

echo
[[ "$overall" -eq 0 ]] && echo "ALL PASSED" || echo "SOME FAILED"
exit "$overall"

# ─────────────────────────────────────────────────────────────────────────────────────────────────────
# LIVE SMOKE (manual; not run above). Proves the end-to-end create-or-reuse + append path on a real repo.
#
#   gh repo create my-loop-kit-test --private --clone && cd my-loop-kit-test
#   export REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) TRACKER_BACKEND=github
#   # No run-log issue yet — first log() must create one labeled loop:runlog and append:
#   ../loop-kit/track log "iter 1 — hello"
#   gh issue list --label loop:runlog        # → exactly one issue, the fresh run-log
#   ../loop-kit/track log "iter 2 — again"   # → reuses the SAME issue (no second run-log created)
#   ../loop-kit/track runlog-tail 2          # → the last two entries, in order
#   RUNLOG_LABEL=loop:mylog ../loop-kit/track log "custom label"   # → a distinct run-log under loop:mylog
# ─────────────────────────────────────────────────────────────────────────────────────────────────────
