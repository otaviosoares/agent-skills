#!/usr/bin/env bash
# tests/deps.test.sh — unit tests for the `track deps N` extraction logic (both backends).
#
# WHAT: drives the ACTUAL pure pieces of `cmd_deps` — each adapter's native-link jq filter
# (_deps_native_filter) and the shared `## Blocked by` body parser (_deps_body) — sourced from the
# adapters, not copied, so the test can't drift from the code. This locks the two things `deps` must
# get right (which native relationships count as blockers, and how the body-text fallback is parsed)
# WITHOUT needing a live GitHub/GitLab repo. The end-to-end `gh api …` / `glab api …` round-trips
# still want the manual live smoke at the bottom of this file.
#
# WHY jq/awk and not the CLIs: the native fetch is a thin `api … | jq FILTER`; this harness feeds
# sample API JSON through the SAME filter. The body parse is a thin `awk` program; this feeds sample
# issue bodies through the SAME awk. Both are the exact code paths cmd_deps runs after the fetch.
#
# RUN:  ./tests/deps.test.sh        (exits non-zero on any failure)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v jq  >/dev/null || { echo "✋ jq required to run these tests"  >&2; exit 1; }
command -v awk >/dev/null || { echo "✋ awk required to run these tests" >&2; exit 1; }

# Subshells (one per adapter, since both define same-named cmd_/helper funcs) tally into a shared file.
RESULTS="$(mktemp)"; trap 'rm -f "$RESULTS"' EXIT

# assert <name> <want> <got>  — want/got are newline-joined id lists ("" = empty output).
assert() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then
    printf 'P\n' >>"$RESULTS"; printf '  ✓ %s\n' "$name"
  else
    printf 'F\n' >>"$RESULTS"; printf '  ✗ %s\n      want: %q\n      got:  %q\n' "$name" "$want" "$got"
  fi
}

# ── GitHub ────────────────────────────────────────────────────────────────────────────────────────
(
  REPO="owner/repo"; TRACKER_BACKEND=github
  # shellcheck disable=SC1091
  source adapters/github.sh

  echo "github — native blocked_by dependencies → ids:"
  # The blocked_by endpoint returns an array of issue objects; every one is a blocker (open or closed —
  # PICK gates on state via item-state, deps only enumerates).
  assert "lists every blocker number, in order" $'3\n7' \
    "$(jq -r "$(_deps_native_filter)" <<<'[{"number":3,"state":"open"},{"number":7,"state":"closed"}]')"
  assert "no native links → empty" "" \
    "$(jq -r "$(_deps_native_filter)" <<<'[]')"

  echo "github — body fallback (## Blocked by → #K):"
  assert "extracts only refs under the section" $'5\n12' \
    "$(_deps_body <<<$'## What\n\nunrelated #99\n\n## Blocked by\n\n- Depends on #5\n- Also #12\n\n## Acceptance\n\n- [ ] done #77')"
  assert "dedupes repeated refs, keeps first-seen order" $'5\n8' \
    "$(_deps_body <<<$'## Blocked by\n\n- #5\n- #8\n- #5 again')"
  assert "tolerates a trailing colon in the heading" $'5' \
    "$(_deps_body <<<$'## Blocked by:\n\n- #5')"
  assert "'None — can start immediately' → empty" "" \
    "$(_deps_body <<<$'## Blocked by\n\nNone — can start immediately')"
  assert "no Blocked-by section → empty" "" \
    "$(_deps_body <<<$'## Summary\n\nrefs #1 #2 but no section')"
  assert "empty body → empty" "" "$(_deps_body <<<'')"
)

# ── GitLab ────────────────────────────────────────────────────────────────────────────────────────
(
  REPO="group/proj"; TRACKER_BACKEND=gitlab
  # shellcheck disable=SC1091
  source adapters/gitlab.sh

  echo "gitlab — native is_blocked_by links → iids:"
  # The links endpoint returns every linked issue with a link_type; only is_blocked_by are blockers
  # (relates_to / blocks are NOT — a `blocks` edge means THIS issue blocks the other, not the reverse).
  assert "keeps only is_blocked_by, drops relates_to/blocks" $'4\n11' \
    "$(jq -r "$(_deps_native_filter)" <<<'[{"iid":4,"link_type":"is_blocked_by"},{"iid":9,"link_type":"relates_to"},{"iid":11,"link_type":"is_blocked_by"},{"iid":2,"link_type":"blocks"}]')"
  assert "no is_blocked_by links → empty" "" \
    "$(jq -r "$(_deps_native_filter)" <<<'[{"iid":9,"link_type":"relates_to"}]')"

  echo "gitlab — body fallback (## Blocked by → #K):"
  assert "extracts refs under the section" $'5\n12' \
    "$(_deps_body <<<$'## Blocked by\n\n- #5\n- #12')"
  assert "no section → empty" "" \
    "$(_deps_body <<<$'## What to build\n\njust text')"
)

echo
pass="$(grep -c '^P$' "$RESULTS")"; fail="$(grep -c '^F$' "$RESULTS")"
echo "result: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

# ─────────────────────────────────────────────────────────────────────────────────────────────────────
# LIVE SMOKE (manual; not run above). Proves the end-to-end native round-trip on a real repo/project.
#
#  GitHub (native issue dependencies):
#   gh repo create my-deps-test --private --clone && cd my-deps-test
#   B=$(gh issue create --title blocker --json number --jq .number)
#   N=$(gh issue create --title child   --json number --jq .number)
#   BID=$(gh api repos/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/issues/$B --jq .id)
#   gh api --method POST repos/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/issues/$N/dependencies/blocked_by -F issue_id=$BID
#   export REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) TRACKER_BACKEND=github
#   ./track deps $N        # → prints the blocker number ($B)
#
#  Body fallback (either backend): create an issue whose body has a `## Blocked by` section listing
#  `#K`, no native link, then `./track deps <that issue>` → prints K.
# ─────────────────────────────────────────────────────────────────────────────────────────────────────
