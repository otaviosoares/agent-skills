#!/usr/bin/env bash
#
# loop-drive.sh — a GENERIC external driver for any context-bounded build loop (loop-kit).
#
# WHY THIS EXISTS
#   An in-session `/loop` resumes the SAME conversation every iteration, so context piles up
#   and can't be force-cleared. This driver instead spawns a BRAND-NEW headless `claude -p`
#   per iteration — each with EMPTY context. All durable state lives OUTSIDE the agent (a
#   tracker file, GitHub issues, a board, …), so each fresh session re-derives it. The driver
#   is stateless; it only decides *when to fire the next session* and *when to stop*.
#
# USAGE   (run from the TARGET repo's root — the repo whose loop you are driving)
#   "$LOOP_KIT_DIR"/loop-drive.sh [runbook] [extra inline context …]
#
#   Most repos add a thin committed launcher (e.g. plans/run-loop.sh) that locates the installed
#   loop-kit skill and exec's THIS script, so a human just types `./plans/run-loop.sh`.
#   The runbook is OPTIONAL: with no runbook arg the driver defaults RUNBOOK to the kit's canonical
#   SKELETON (loop-runbook.md, alongside this script) — a backend/project-neutral state machine.
#   Per-repo judgment lives in the repo's own CLAUDE.md, which every fresh session reads anyway —
#   there is no per-loop script. Examples:
#     ./plans/run-loop.sh                                   # default: the kit's skeleton
#     ./plans/run-loop.sh "Only pick docs issues this run."   # skeleton + extra inline context
#     ./plans/run-loop.sh plans/custom-loop.md              # an explicit, non-default runbook
#
#   The driver derives the TARGET repo from the CWD and exports into each spawned session: LOOP_KIT_DIR
#   (this dir), TRACKER_CONFIG (the repo's plans/loop.config.sh), and — by sourcing the config —
#   READY_LABEL / BRANCH_PREFIX (and the rest of the config). The skeleton's "$LOOP_KIT_DIR"/track verb
#   calls then resolve against the right repo's config, and its "$READY_LABEL"/"$BRANCH_PREFIX" references
#   resolve too.
#
#   Watch:  the live feed prints each iteration's tool calls; or `tail -f` the log path below.
#   Stop:   Ctrl-C  (safe — state is external; just re-run to resume).
#
# ─────────────────────────────────────────────────────────────────────────────────────────
# HOW IT KNOWS WHAT TO DO NEXT — the agent ends every iteration by printing ONE sentinel line:
#     LOOP_STATUS=CONTINUE   more work remains, pickable now      → run the next fresh session
#     LOOP_STATUS=WAIT       work remains but nothing pickable     → sleep WAIT_SECONDS, re-run
#                            yet (a dep is in-flight elsewhere)      (do NOT stop — it'll clear)
#     LOOP_STATUS=COMPLETE   nothing left to do                    → exit 0
#     LOOP_STATUS=BLOCKED    a human decision/input is needed      → exit 2
#   The default prompt below instructs the agent to do exactly one iteration and print this.
#   A runbook that has no WAIT concept (e.g. a single-runner tracker loop) simply never emits
#   it. If a session EXITS CLEANLY but prints no sentinel, the driver assumes CONTINUE and warns.
#
#   INTERRUPTED (a 5th, implicit state): if the session exits NON-ZERO *and* printed no sentinel
#   — e.g. a transient `529 Overloaded` killed it mid-iteration — the true state is UNKNOWN. The
#   driver does NOT assume CONTINUE (the iteration may have done partial, non-atomic work, like
#   merging a branch but not yet closing the issue). It backs off (longer on an overload) and
#   retries, bounded by MAX_FAILS. Recovery relies on the runbook having a RECONCILE step so the
#   next clean run finds and finishes any dangling claim instead of stranding it.
# ─────────────────────────────────────────────────────────────────────────────────────────
#
# PERMISSIONS — headless mode is non-interactive, so it cannot answer permission prompts.
#   Default PERMISSION_MODE=bypassPermissions lets build/test/git steps run unattended, which
#   means arbitrary shell. Only run on a TRUSTED local repo. If your runbook PUSHES or MERGES
#   to a shared remote, those outward-facing actions happen unattended — know that going in.
#   To tighten: PERMISSION_MODE=acceptEdits plus an explicit ALLOWED_TOOLS list.
#
# TUNABLES (all via env, e.g. `MODEL=sonnet WAIT_SECONDS=120 ./plans/run-loop.sh plans/x.md`):
#   MODEL=opus  EFFORT=high  PERMISSION_MODE=bypassPermissions  MAX_BUDGET_USD=  ALLOWED_TOOLS=
#   MAX_ITERS=200  MAX_FAILS=3  WAIT_SECONDS=240  VIEW=stream|text  LOG=  CLAUDE_BIN=
#   OVERLOAD_BACKOFF=60  INTERRUPT_BACKOFF=10   (sleep before retrying after a 529 / other crash)
#   PROTECTED_BRANCHES=   EXPECTED_BRANCH=   ITER_PROMPT=(full override)
#
#   EFFORT (low|medium|high|xhigh|max) is the per-session reasoning level. It is SESSION-WIDE:
#   the sub-agents this orchestrator spawns (builder/reviewer/fixer) inherit it, so `high` is a
#   sensible default for unattended engineering loops. Lower it (medium) for cheap mechanical
#   loops; reserve xhigh/max for review-heavy correctness-critical runs. Empty = CLI default.

set -uo pipefail

# ── args: runbook (OPTIONAL) + optional extra inline context ────────────────────────────────
# The runbook defaults to the kit's canonical SKELETON (loop-runbook.md, next to this script) so the
# common case is a bare `./plans/run-loop.sh`. $1 is taken as an explicit runbook ONLY when it names a
# real file (after we cd into the repo root, below); a non-file first arg (or none) means "use the
# skeleton" and $1 is treated as extra inline context. We can't test the file yet (we cd below), so
# defer the runbook-vs-context decision until after the repo root + SCRIPT_DIR are known.
ARG1="${1:-}"

# ── locate the TARGET repo from the CWD; locate the KIT from this script ────────────────────
# In skill mode the kit lives OUTSIDE the target repo (installed under ~/.claude/skills/…), so the
# repo root must come from where the loop is being RUN (the CWD), NOT the script's own dir — using
# SCRIPT_DIR would cd into the *skill's* repo and never find the runbook. In vendored mode (kit at
# plans/loop-kit/) the CWD is the repo too, so deriving from the CWD is correct in BOTH modes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || { echo "✋ Could not cd into repo root '$REPO_ROOT'" >&2; exit 1; }

# Resolve the runbook now that we're in the repo root: an explicit first arg that names a real file is
# the runbook (then drop it from the positional args so the rest is extra context); otherwise default to
# the kit's SKELETON and keep ALL positional args as extra context.
DEFAULT_RUNBOOK="$SCRIPT_DIR/loop-runbook.md"
if [[ -n "$ARG1" && -f "$ARG1" ]]; then
  RUNBOOK="$ARG1"; shift
else
  RUNBOOK="$DEFAULT_RUNBOOK"
fi
EXTRA_CONTEXT="$*"
[[ -f "$RUNBOOK" ]] || { echo "✋ Runbook not found: $RUNBOOK (looked under $REPO_ROOT; default skeleton is $DEFAULT_RUNBOOK)" >&2; exit 64; }

# Export the vars the spawned `claude -p` inherits (and so do the agent's Bash tool calls), so the
# runbook can call "$LOOP_KIT_DIR/track …" and `track` finds the TARGET repo's config:
#   LOOP_KIT_DIR   = this kit dir (where track + adapters/ + loop-runbook.md live)
#   TRACKER_CONFIG = the target repo's filled config, kept OUTSIDE the kit (so no project IP ships in it).
# An explicit pre-set TRACKER_CONFIG wins (e.g. a non-standard path).
export LOOP_KIT_DIR="$SCRIPT_DIR"
export TRACKER_CONFIG="${TRACKER_CONFIG:-$REPO_ROOT/plans/loop.config.sh}"

# Source the config into the REAL env so READY_LABEL / BRANCH_PREFIX (and the rest) are available to the
# spawned session's bash calls — the skeleton's verb calls pass "$READY_LABEL" and branch as "$BRANCH_PREFIX/…".
# `set -a` exports everything the config sets; every config value uses ${VAR:-default}, so a pre-set env
# value (e.g. READY_LABEL=ready-2 on this launch) still WINS — sourcing respects it rather than clobbering it.
# (The CLAIM_STRATEGY preflight below still sources in a SUBSHELL for its own read; this is the one that
# exports into the driver's real environment.)
[[ -f "$TRACKER_CONFIG" ]] && { set -a; . "$TRACKER_CONFIG"; set +a; }

# Resolve + export BASE_BRANCH (the loop's integration branch) so the spawned session's own git
# rebase/merge targets the repo's real default branch — not the literal `main` — when the config left
# it unset. Same resolver `track` uses, so the driver, the agent, and the adapters all agree. (We're
# at REPO_ROOT here, so origin/HEAD detection resolves against the target repo.)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/resolve-base-branch.sh"

# ── preflight: CLAIM_STRATEGY=note requires a per-agent RUNNER_ID — fail at LAUNCH, not mid-iteration ──
# Resolve the effective strategy the way `track` will (env wins; else the config's default), by sourcing
# the config in a subshell so we read its value without polluting the driver's env. Then refuse to spawn
# a single iteration if note mode has no RUNNER_ID — the operator must fix the command line, and a warning
# buried in one headless agent's stderr would be missed.
_resolved_strategy="$( { [[ -f "$TRACKER_CONFIG" ]] && . "$TRACKER_CONFIG"; } >/dev/null 2>&1; printf '%s' "${CLAIM_STRATEGY:-assignee}" )"
if [[ "$_resolved_strategy" == "note" && -z "${RUNNER_ID:-}" ]]; then
  echo "✋ CLAIM_STRATEGY=note requires a per-agent RUNNER_ID, set on THIS launch (not in loop.config.sh," >&2
  echo "   so two concurrent agents differ). It must be STABLE across restarts and DISTINCT per agent —" >&2
  echo "   a downed agent reups with the same id to recover its own claim. Launch each agent like:" >&2
  echo "     RUNNER_ID=agent-1 ./plans/run-loop.sh" >&2
  echo "     RUNNER_ID=agent-2 ./plans/run-loop.sh" >&2
  exit 1
fi

LOOP_NAME="$(basename "$RUNBOOK" | sed -E 's/\.[^.]+$//')"

# ── tunables ───────────────────────────────────────────────────────────────────────────────
MODEL="${MODEL:-opus}"
EFFORT="${EFFORT-high}"   # unset → high; explicit empty (EFFORT=) → omit flag, inherit CLI default
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"
ALLOWED_TOOLS="${ALLOWED_TOOLS:-}"
MAX_ITERS="${MAX_ITERS:-200}"
MAX_FAILS="${MAX_FAILS:-3}"
WAIT_SECONDS="${WAIT_SECONDS:-240}"
OVERLOAD_BACKOFF="${OVERLOAD_BACKOFF:-60}"   # wait after a transient 529/overload before retrying
INTERRUPT_BACKOFF="${INTERRUPT_BACKOFF:-10}" # wait after any other mid-iteration crash before retrying
VIEW="${VIEW:-stream}"
LOG="${LOG:-$REPO_ROOT/plans/.${LOOP_NAME}-drive.log}"
PROTECTED_BRANCHES="${PROTECTED_BRANCHES:-}"
EXPECTED_BRANCH="${EXPECTED_BRANCH:-}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true   # ensure LOG's dir exists (repos without plans/ would fail `tee`)

# default per-iteration prompt (override wholesale with ITER_PROMPT=…) ──────────────────────
ITER_PROMPT="${ITER_PROMPT:-"You are running HEADLESS under an external driver (non-interactive — you cannot \
prompt the user, and you must NOT schedule any wakeup; the driver controls cadence). Follow ${RUNBOOK} and run \
EXACTLY ONE iteration of the loop, then STOP — do not start a second unit of work. Never guess an OPEN decision; \
on a blocker, record it per the runbook, then stop.${EXTRA_CONTEXT:+ ${EXTRA_CONTEXT}} \
FINISH by printing, on its own final line, exactly one sentinel: \
'LOOP_STATUS=CONTINUE' (more work remains and is pickable now), \
'LOOP_STATUS=WAIT' (work remains but none is pickable yet — waiting on another runner/dep), \
'LOOP_STATUS=COMPLETE' (all done), or 'LOOP_STATUS=BLOCKED' (a human decision/input is needed)."}"

# ── resolve the REAL Claude CLI ────────────────────────────────────────────────────────────
# Interactive `claude` is often a shell ALIAS (invisible to scripts), and PATH may surface an
# UNRELATED `claude`. Pin the native install and verify via --version.
if [[ -z "${CLAUDE_BIN:-}" ]]; then
  for cand in "$HOME/.claude/local/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude" "/usr/bin/claude" "$HOME/.npm-global/bin/claude" "$(command -v claude 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] || continue
    if "$cand" --version 2>/dev/null | grep -qi "claude code"; then CLAUDE_BIN="$cand"; break; fi
  done
fi
if [[ -z "${CLAUDE_BIN:-}" ]]; then
  echo "✋ No working Claude Code CLI found. Interactive 'claude' may be a shell alias (scripts can't see aliases)." >&2
  echo "   Fix: CLAUDE_BIN=/abs/path/to/claude $0 $RUNBOOK   (yours is likely ~/.claude/local/claude)" >&2
  exit 1
fi

JQ="$(command -v jq 2>/dev/null || true)"
[[ "$VIEW" == "stream" && -z "$JQ" ]] && { echo "ℹ️  jq not found → falling back to text view."; VIEW="text"; }

# ── branch policy (opt-in via env) ─────────────────────────────────────────────────────────
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
for p in $PROTECTED_BRANCHES; do
  [[ "$branch" == "$p" ]] && { echo "✋ Refusing to run on protected branch '$branch' (PROTECTED_BRANCHES)." >&2; exit 1; }
done
[[ -n "$EXPECTED_BRANCH" && "$branch" != "$EXPECTED_BRANCH" ]] && \
  echo "ℹ️  On '$branch' (expected '$EXPECTED_BRANCH')." | tee -a "$LOG"

# ── live feed: one stream-json event → one readable line (sub-agent work indented) ─────────
JQ_FILTER='
  def trunc($s): if ($s|length)>140 then $s[0:140]+"…" else $s end;
  def toolview:
    .name as $n | (.input // {}) as $in
    | if   $n=="Bash" then "$ " + trunc($in.command // ($in|tojson))
      elif ($n=="Read" or $n=="Edit" or $n=="Write" or $n=="NotebookEdit")
           then "\($n) " + ($in.file_path // $in.notebook_path // ($in|tojson))
      elif $n=="Grep" then "Grep /\($in.pattern // "")/" + (if ($in.path // "")!="" then " in \($in.path)" else "" end)
      elif $n=="Glob" then "Glob \($in.pattern // "")"
      elif ($n=="Task" or $n=="Agent") then "\($n) ▸ " + ($in.description // $in.subagent_type // trunc($in|tojson))
      else "\($n) " + trunc($in|tojson) end;
  (.parent_tool_use_id // null) as $sub | (if $sub then "    ⤷ " else "" end) as $p
  | if   .type=="system" and .subtype=="init" then "▸ init · \(.model) · perm=\(.permissionMode)\n"
    elif .type=="assistant" then ([ .message.content[]?
           | if   .type=="text" and ((.text|gsub("[[:space:]]";"")|length)>0) then "\($p)💬 \(.text)"
             elif .type=="tool_use" then "\($p)🔧 " + toolview
             else empty end ] | map(.+"\n") | join(""))
    elif .type=="user" then ([ .message.content[]?
           | if .type=="tool_result" then "\($p)   ↳ " + (if (.is_error//false) then "⚠ error" else "ok" end)
             else empty end ] | map(.+"\n") | join(""))
    elif .type=="result" then "✅ \(.subtype) · \(.num_turns) turns · $\( ((.total_cost_usd//0)*100|round)/100 )\n"
    else empty end
'

# ── run one fresh headless iteration; mirror output to LOG + a per-iter capture file ───────
ITER_OUT=""
cleanup() { [[ -n "$ITER_OUT" && -f "$ITER_OUT" ]] && rm -f "$ITER_OUT"; }
trap 'cleanup; echo; echo "✋ Interrupted — state is external, just re-run to resume." | tee -a "$LOG"; exit 130' INT TERM
trap cleanup EXIT

run_iteration() {
  local -a cmd=("$CLAUDE_BIN" -p "$ITER_PROMPT" --permission-mode "$PERMISSION_MODE")
  [[ -n "$MODEL" ]]          && cmd+=(--model "$MODEL")
  [[ -n "$EFFORT" ]]         && cmd+=(--effort "$EFFORT")
  [[ -n "$MAX_BUDGET_USD" ]] && cmd+=(--max-budget-usd "$MAX_BUDGET_USD")
  # shellcheck disable=SC2206
  [[ -n "$ALLOWED_TOOLS" ]]  && cmd+=(--allowedTools $ALLOWED_TOOLS)
  if [[ "$VIEW" == "stream" ]]; then
    "${cmd[@]}" --output-format stream-json --verbose 2>>"$LOG" \
      | "$JQ" -rj --unbuffered "$JQ_FILTER" \
      | tee -a "$LOG" "$ITER_OUT"
    return "${PIPESTATUS[0]}"
  else
    "${cmd[@]}" 2>&1 | tee -a "$LOG" "$ITER_OUT"; return "${PIPESTATUS[0]}"
  fi
}

parse_sentinel() { grep -oE 'LOOP_STATUS=(CONTINUE|WAIT|COMPLETE|BLOCKED)' "$1" 2>/dev/null | tail -1 | cut -d= -f2; }
is_overload()   { grep -qiE '\b529\b|overloaded' "$1" 2>/dev/null; }

# ── the loop ───────────────────────────────────────────────────────────────────────────────
echo "▶ ${LOOP_NAME} driver — runbook '$RUNBOOK' · branch '$branch' · claude '$CLAUDE_BIN' · view=$VIEW · model=$MODEL · effort=${EFFORT:-default} · $(date)" | tee -a "$LOG"
fails=0

for ((i=1; i<=MAX_ITERS; i++)); do
  echo "── iter $i  $(date '+%Y-%m-%d %H:%M:%S') ──────────────────────────────" | tee -a "$LOG"
  ITER_OUT="$(mktemp "${TMPDIR:-/tmp}/${LOOP_NAME}-iter.XXXXXX")"

  run_iteration; rc=$?
  status="$(parse_sentinel "$ITER_OUT")"
  overloaded=0; is_overload "$ITER_OUT" && overloaded=1
  rm -f "$ITER_OUT"; ITER_OUT=""

  # INTERRUPTED = the process failed AND the agent never reported a status → the iteration's
  # true state is UNKNOWN. Critically, do NOT assume CONTINUE here: it may have done partial,
  # non-atomic work (e.g. merged a branch but not yet closed the issue), and silently firing
  # the next session could strand that work. We back off and retry; the runbook's RECONCILE
  # step makes the next clean run self-heal any dangling claim. Bounded by MAX_FAILS.
  if [[ $rc -ne 0 && -z "$status" ]]; then
    fails=$((fails+1))
    if [[ $overloaded -eq 1 ]]; then backoff="$OVERLOAD_BACKOFF"; cause="a transient overload (529)"
    else                             backoff="$INTERRUPT_BACKOFF"; cause="an error"; fi
    echo "⚠ iteration INTERRUPTED by ${cause} (rc=$rc, no LOOP_STATUS · failure $fails/$MAX_FAILS). State UNKNOWN — not assuming CONTINUE." | tee -a "$LOG"
    if (( fails >= MAX_FAILS )); then
      echo "✋ ${MAX_FAILS} consecutive interrupted iterations — stopping. VERIFY state before re-running" | tee -a "$LOG"
      echo "   (e.g. a merged-but-open issue still labelled in-progress). See $LOG." | tee -a "$LOG"
      exit 5
    fi
    echo "   Work may be partly done; the next run will RECONCILE any dangling claim per the runbook. Backing off ${backoff}s…" | tee -a "$LOG"
    sleep "$backoff"; continue
  fi

  # Reached here → the iteration produced a usable result (clean exit, or a sentinel despite a
  # trailing non-zero exit). Trust the sentinel; reset the failure streak.
  fails=0
  [[ -z "$status" ]] && { status="CONTINUE"; echo "⚠ no LOOP_STATUS sentinel this iteration — assuming CONTINUE" | tee -a "$LOG"; }
  echo "   → state: $status" | tee -a "$LOG"

  case "$status" in
    COMPLETE) echo "✅ ${LOOP_NAME} COMPLETE — $(date)" | tee -a "$LOG"; exit 0 ;;
    BLOCKED)  echo "⛔ ${LOOP_NAME} BLOCKED — resolve the open decision(s), then re-run." | tee -a "$LOG"; exit 2 ;;
    WAIT)     echo "── starved — work remains but nothing pickable; sleeping ${WAIT_SECONDS}s ──" | tee -a "$LOG"; sleep "$WAIT_SECONDS" ;;
  esac
done

echo "✋ Hit MAX_ITERS=$MAX_ITERS — stopping. Re-run to continue." | tee -a "$LOG"
exit 4
