#!/usr/bin/env bash
# tests/config-caps.test.sh — the v2 config surface: `track caps` resolves READY_LABEL / RUNLOG_LABEL,
# and an env override beats the config-file value.
#
# WHAT: drives the REAL `track` dispatcher (via TRACKER_CONFIG pointing at a throwaway config) so the
# test exercises the actual source-order (config → env-override-wins → adapter → cmd_caps), not a copy.
# `caps` is the one verb that needs no gh/glab network, so it pins the config plumbing offline: the
# queue label the loop picks on (READY_LABEL) and the run-log discovery label (RUNLOG_LABEL) both echo
# out of `caps`, and env must win over the file for each (every config value is `${VAR:-default}`).
#
# WHY this locks issue #8: "the driver exports the config into each session" only helps if a fresh
# session can READ the resolved queue label deterministically and override it per-launch. `caps` is the
# wiring check's probe (see init), so making it report the labels is also how init verifies the config.
#
# RUN:  ./tests/config-caps.test.sh        (exits non-zero on any failure)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TRACK="./track"
pass=0; fail=0

# caps_val <backend> <var-line-key> [ENV_ASSIGNMENTS...] with a temp config → the value after `=`.
# The temp config sets both labels to a file-provided value; callers add env overrides to prove wins.
run_caps() {
  local backend="$1"; shift
  local cfg; cfg="$(mktemp)"
  cat >"$cfg" <<EOF
export TRACKER_BACKEND="\${TRACKER_BACKEND:-$backend}"
export REPO="\${REPO:-owner/repo}"
export READY_LABEL="\${READY_LABEL:-cfg-ready}"
export RUNLOG_LABEL="\${RUNLOG_LABEL:-cfg-runlog}"
export BRANCH_PREFIX="\${BRANCH_PREFIX:-loop}"
EOF
  # shellcheck disable=SC2068 — deliberate word-split of KEY=VAL env assignments
  env $@ TRACKER_CONFIG="$cfg" "$TRACK" caps
  rm -f "$cfg"
}

assert_line() {
  local name="$1" want="$2" out="$3" got
  got="$(printf '%s\n' "$out" | sed -n "s/^${want%%=*}=//p")"
  if [[ "$got" == "${want#*=}" ]]; then
    pass=$((pass+1)); printf '  ✓ %s\n' "$name"
  else
    fail=$((fail+1)); printf '  ✗ %s\n      want: %q\n      got:  %q\n' "$name" "${want#*=}" "$got"
  fi
}

for backend in github gitlab; do
  echo "── $backend ──"
  out="$(run_caps "$backend")"
  assert_line "$backend: backend echoed"          "backend=$backend"     "$out"
  assert_line "$backend: config READY_LABEL wins when no env" "ready_label=cfg-ready"  "$out"
  assert_line "$backend: config RUNLOG_LABEL read"           "runlog_label=cfg-runlog" "$out"

  out="$(run_caps "$backend" READY_LABEL=env-ready)"
  assert_line "$backend: env READY_LABEL beats config"       "ready_label=env-ready"  "$out"

  out="$(run_caps "$backend" RUNLOG_LABEL=env-runlog)"
  assert_line "$backend: env RUNLOG_LABEL beats config"      "runlog_label=env-runlog" "$out"
done

# Default when neither env nor a value is set: caps must fall back to the documented defaults.
echo "── defaults ──"
bare="$(mktemp)"
cat >"$bare" <<'EOF'
export TRACKER_BACKEND="${TRACKER_BACKEND:-github}"
export REPO="${REPO:-owner/repo}"
EOF
out="$(env TRACKER_CONFIG="$bare" "$TRACK" caps)"
rm -f "$bare"
assert_line "default READY_LABEL = ready-for-agent" "ready_label=ready-for-agent" "$out"
assert_line "default RUNLOG_LABEL = loop:runlog"    "runlog_label=loop:runlog"    "$out"

echo
echo "result: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
