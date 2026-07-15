#!/usr/bin/env bash
# loop.sh — loop-kit: contract-based loop engineering harness for Claude Code.
#
# Deployed layout (inside the target project; only this file + conf files are visible):
#   loop.sh              main entry (this file, copied by `loop.sh init`)
#   loop.config.sh       contract stop conditions (hash-approved, never sourced unverified)
#   loop.models.sh       model roles per process (safe-parsed, never sourced)
#   loop-instruction.md  optional: your task instruction for `./loop.sh` auto flow
#   .claude/skills/      loop-* skills (the encoded process)
#   .loop/               everything else: bin/evaluate.sh, docs/ (contract, plan,
#                        progress, drift, evidence, decisions), logs, journal, state,
#                        kit-source (where this was deployed from, for `update`)
#
# `init` deploys the kit; `update` re-pulls the harness (loop.sh, evaluator,
# skills) from that kit while preserving your contract/config/models/docs.
# `uninstall` removes everything init/update deployed — plus run state and fleet
# worktrees/branches — restoring the project to its pre-kit layout (confirmed).
#
# The kit's own files (loop.sh, loop.config.sh, loop.models.sh, loop-instruction.md,
# .claude/skills/loop-*/) are auto-appended to the project's .gitignore on `init` and
# before each run, so the loop's own `git add -A` never commits the harness into your
# project. .loop/ is self-ignored except docs/ (the tracked, auditable loop memory).
#
# A loop = trigger -> verifiable goal -> execution -> per-iteration review ->
# external verification -> named stop state. The agent's self-report is never
# sufficient for SUCCESS; the deterministic evaluator (.loop/bin/evaluate.sh) and
# an independent reviewer gate it.
#
# Exit codes: 0 SUCCESS/NO_OP | 2 usage/config error | 3 escalation (human decision)
#             4 BLOCKED/STALLED | 5 BUDGET_EXCEEDED | 130 interrupted

# This script uses bash features (process substitution `< <(...)`, `[[ ]]`, arrays).
# If started with a POSIX shell (e.g. `sh loop.sh`) — on macOS `/bin/sh` is bash in
# POSIX mode, which disables process substitution and aborts with a line-651 syntax
# error — re-exec under real bash. The re-exec guard (sentinel + unset) is loop-safe.
if { [ -z "${BASH_VERSION:-}" ] || shopt -qo posix 2>/dev/null; } && [ -z "${LOOP_BASH_REEXEC:-}" ]; then
  unset POSIXLY_CORRECT 2>/dev/null || true
  LOOP_BASH_REEXEC=1 exec bash "$0" "$@"
fi

set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
CLAUDE_CMD="${LOOP_CLAUDE_CMD:-claude}"
TOTAL_COST=0
CHILD_PID=""
AGENT_PID=""
TASK_ID=""
RUN_ID=""
REVIEW_SCOPE=""
TASK_START_REF=""
TASK_START_REF_EXPECTED=""
TASK_START_REF_PATH=""
TASK_START_REF_PINNED=0
OBS_MANIFEST_EXPECTED=""
OBS_MANIFEST_PINNED=0
# Stop-heuristic streaks are PROCESS MEMORY (like TOTAL_COST): the .loop/met-count
# and .loop/futile-count files are display mirrors only — a file value is never
# read back into arithmetic (a forged "999999" would force the gate after one
# MET; a non-numeric value would kill the run under set -u). A resume starts a
# new process, so both streaks restart at 0 — the safe side.
STOP_EVAL_MET_STREAK=0
STOP_EVAL_FUTILE_STREAK=0
# Agent subtree isolation: launch every `claude` as its OWN process-group leader
# so an interrupt/timeout can signal the WHOLE agent subtree (claude + MCP servers
# + tool subprocesses + sub-agents), not just the top pid. A background job of a
# non-interactive shell has SIGINT set to SIG_IGN — a terminal Ctrl+C would never
# reach the agent's descendants — so the trap MUST TERM the group itself. Needs perl
# (ships on macOS/Linux) to enter a new process group; when unavailable — or when
# LOOP_AGENT_PGROUP=0 opts out — this degrades to today's behavior: a plain launch
# in loop.sh's group, and kill_agent_group() falls back to a single-pid kill.
# On MSYS/Cygwin (Git Bash) POSIX process groups don't map, and perl's setpgrp can
# error or hang the exec — and Git Bash *bundles* perl, so `command -v perl` would
# wrongly enable the pgroup path and break agent launch. Force the already-tested
# single-pid fallback there (single-run mode only; the fleet is WSL/Linux on Windows).
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _msys=1 ;; *) _msys=0 ;; esac
if [ "${LOOP_AGENT_PGROUP:-1}" = 1 ] && [ "$_msys" = 0 ] && command -v perl >/dev/null 2>&1; then
  AGENT_PGROUP_OK=1
else
  AGENT_PGROUP_OK=0
fi
AUTO_MODE="${LOOP_AUTO:-0}"   # 1 = never stop for approval (auto-approve, audit-journaled)

# ---- mode detection: deployed (inside a project) vs kit repo (bin/loop.sh) ----
MODE="deployed"
EVALUATOR="$SCRIPT_DIR/.loop/bin/evaluate.sh"
KIT_ASSETS=""; KIT_BIN=""; KIT_ROOT=""
if [ ! -f "$EVALUATOR" ] && [ -f "$SCRIPT_DIR/evaluate.sh" ] && [ -d "$SCRIPT_DIR/../kit" ]; then
  MODE="kit"
  EVALUATOR="$SCRIPT_DIR/evaluate.sh"
  KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  KIT_ASSETS="$KIT_ROOT/kit"
  KIT_BIN="$KIT_ROOT/bin"
fi
if [ "$MODE" = "deployed" ]; then
  cd "$SCRIPT_DIR"   # the main sh always operates on its own project directory
fi

usage() {
  cat <<'EOF'
loop — run Claude Code as a contract-driven loop. Define what "done" means,
approve it, then let it iterate. Parallel work fans out to a fleet of task
loops in isolated git worktrees.

Usage: ./loop.sh <command> [options]

DEFINE & APPROVE
  (no command)          Guided setup: write the contract (from loop-instruction.md
                        if present), ask, approve, then run
  start <instr|file>    Define a loop interactively — you approve / revise / exit
  auto [instr|file]     Define + approve + run, fully autonomous (assumptions
                        recorded, not asked; stops only for escalations)
  approve               Approve the contract, config and harness (records hashes)
  contract-review       Independent read-only review of the loop definition
                        (auto/fleet run it before any unattended approval;
                        disable with LOOP_CONTRACT_REVIEW=0)

RUN
  run [--fresh] [--single]
                        Run the approved contract. It first DECOMPOSES into tasks:
                        one -> in-place loop, several -> parallel fleet. Auto-resumes
                        after a crash. --single skips decomposition; --fresh restarts
                        clean from iteration 1.
  decompose [--force]   Preview/refresh the task split (task-plan.md) without running
  resume [<id>|--list] [--auto] [--note '<text>']
                        Continue a stopped run (BLOCKED / STALLED, or BUDGET_EXCEEDED
                        after raising MAX_ITERATIONS). --note guides the next
                        iteration; <id> resumes one fleet task; --list shows sessions
  refine ['<note>']     At a human sign-off gate (BLOCKED): open an interactive session
                        to adjust reversible within-contract knobs and preview live.
                        End it (Ctrl-C / /exit), then confirm to sign off + re-certify.
                        For a REQUIRED-behavior change use /loop-contract, not this.
  watch [--interval s] [--max-runs n]
                        Re-run `run` on an interval until success or escalation

PARALLEL FLEET
  add <task> [--auto] [--after <id,id>]
                        Queue a task any time (file or quoted text); --after
                        serializes it behind other tasks. Alias for `fleet add`
  fleet <command>       Supervisor surface: run / status / report / logs / stop /
                        resume / merge / clean ...  (see: ./loop.sh fleet help)

INSPECT
  status                Loop state, approval and cost
  report [--text|--open|--no-open]
                        Evidence / spec-drift / decisions / cost. Opens the HTML view
                        in an interactive terminal; --text forces plain text
  open <file>           Open an HTML report or mockup in the browser

KIT (deploy / upgrade)
  init <dir> [--template t]
                        Deploy the kit into a project directory (kit repo only)
  update [dir] [--from k] [--approve]
                        Upgrade the harness to the latest kit; keeps your
                        contract / config / models / docs
  uninstall [dir] [--force]
                        Remove the deployed kit from a project (asks to confirm)

REVIEW   .loop/docs/product-contract.md   .loop/docs/evidence-report.md
CONFIG   loop.config.sh (stop conditions)   loop.models.sh (models per process)
HTML     authored only when a rubric warrants it; LOOP_HTML=1/0 forces on/off,
         LOOP_BROWSER_CMD overrides the opener
EOF
}

die()  { echo "loop: error: $*" >&2; exit 2; }
note() { echo "loop: $*"; }
# die_next <problem> <recovery> — an error that ENDS with the exact command to run
# next, on its own line, so the user is never stranded at a dead-end message. This
# is the canonical form for single-step error paths; the boxed print_next_actions
# is for multi-option stops. Recovery is optional (set -u safe) but should be given.
die_next() {
  echo "loop: error: $1" >&2
  [ -n "${2:-}" ] && echo "  → next: $2" >&2
  exit 2
}

# Optional override for the NEXT ACTION box context finish() selects (default: a
# per-state mapping). A caller sets it (e.g. NEXT_ACTION_CTX=api-stall before
# `finish BLOCKED`) to request a specific box without inventing a new state or
# exit code. Process-scoped; only ever set right before the finish() it steers.
NEXT_ACTION_CTX=""

# print_next_actions <context> — a scannable, boxed "what to do next" block, shown
# at every human-facing stop. Contexts: blocked / decision / refine-exit keep the TWO
# human channels visually distinct so a *requirement change* is never fed to
# `resume --note` again (that path rejects it as drift) and an *unchanged* re-approval
# is never mistaken for applying feedback; stalled / budget / api-stall carry the
# futility, budget-raise, and rate-limit-wait guidance so those stops are never
# mis-worded as sign-off gates. finish() selects the context per state, or from
# $NEXT_ACTION_CTX when a caller overrides it (see the api-stall classifier).
# Pure text; harmless in headless/fleet logs (informational).
print_next_actions() {
  local ctx="${1:-}"
  echo
  echo "──────────────────────  NEXT ACTION  ──────────────────────"
  case "$ctx" in
    blocked)
      echo " This run is paused. Pick the path that matches your situation:"
      echo
      echo " ▸ Paused for HUMAN sign-off and it looks right → finish:"
      echo "     mark the 'human' row(s) 'verified' in .loop/docs/acceptance-checklist.md,"
      echo "     then:  ./loop.sh resume       (the evaluator re-checks the cmd/run rows and an"
      echo "                                    independent reviewer certifies SUCCESS)"
      echo
      echo " ▸ Tweak WITHIN the contract (amount of motion, speed of a swirl — reversible knobs):"
      echo "     ./loop.sh refine '<what to change>'          interactive: adjust + preview live  (recommended)"
      echo "     ./loop.sh resume --note '<what to change>'   one headless iteration"
      echo
      echo " ▸ CHANGE the contract (remove/alter a REQUIRED behavior — a verified AC or a REQ):"
      echo "     revise it with /loop-contract, then:  ./loop.sh approve"
      echo "     NOTE: a contract change will NOT go through 'resume --note' (rejected as drift)."
      echo
      echo " ▸ Start over: ./loop.sh run --fresh"
      ;;
    decision)
      echo " This run is paused for a HUMAN decision (see the decision request above)."
      echo
      echo " ▸ Answer by CHANGING the contract (add / remove / alter a requirement):"
      echo "     edit .loop/docs/product-contract.md (or use /loop-contract),"
      echo "     then:  ./loop.sh approve && ./loop.sh run"
      echo "     NOTE: if you 'approve' WITHOUT editing the contract, the loop keeps the SAME"
      echo "           contract and stops again at the same place — approving is not applying feedback."
      echo
      echo " ▸ Answer WITHIN the contract (choose a default / give guidance, no requirement change):"
      echo "     record it in .loop/docs/assumptions.md, then:  ./loop.sh approve && ./loop.sh run"
      ;;
    refine-exit)
      echo " Interactive refine session ended."
      echo
      echo " ▸ Satisfied → sign off the 'human' row(s) 'verified' in"
      echo "     .loop/docs/acceptance-checklist.md, then:  ./loop.sh resume   (re-verifies + certifies)"
      echo
      echo " ▸ Need a REQUIRED behavior changed (a verified AC / a REQ)? That is a contract change:"
      echo "     /loop-contract → ./loop.sh approve      (not 'resume --note')"
      echo
      echo " ▸ Not done yet: run ./loop.sh refine again, or ./loop.sh status to see where things stand."
      ;;
    stalled)
      echo " This run STALLED — it kept iterating without making progress. It is NOT"
      echo " waiting on your sign-off; it could not get unstuck on its own."
      echo
      echo " ▸ Give it a different steer (a hint, a constraint, an approach to try):"
      echo "     ./loop.sh resume --note '<what to try differently>'   (counters + cost preserved)"
      echo
      echo " ▸ The goal may be wrong or unreachable — CHANGE the contract:"
      echo "     revise it with /loop-contract, then:  ./loop.sh approve"
      echo
      echo " ▸ Start over from a clean slate: ./loop.sh run --fresh"
      ;;
    budget)
      echo " This run hit its budget cap (iterations, cost, or wall-clock)."
      echo
      echo " ▸ Give it more room, then continue where it left off:"
      echo "     raise MAX_ITERATIONS / MAX_COST_USD / MAX_RUN_SECONDS in loop.config.sh,"
      echo "     then:  ./loop.sh approve && ./loop.sh resume   (counters + cost preserved)"
      echo
      echo " ▸ Start over: ./loop.sh run --fresh   (discard the checkpoint; re-decompose)"
      ;;
    api-stall)
      echo " The agent call kept failing — this looks like a rate / usage limit, not a"
      echo " problem with your loop. Your progress is saved (checkpoint + counters intact)."
      echo
      echo " ▸ Wait for the limit to reset, then continue where it left off:"
      echo "     ./loop.sh resume   (counters + cost preserved)"
      echo
      echo " ▸ If it keeps failing it may not be a limit — check:"
      echo "     .loop/logs/failed/     the raw error from the last call"
      echo "     your Claude auth / plan, or the LOOP_CLAUDE_CMD you pointed at"
      ;;
  esac
  echo "────────────────────────────────────────────────────────────"
}

# ---------- HTML report/mockup viewing (interactive only; never headless) ----------
# The harness never RENDERS html (the model authors self-contained pages into
# .loop/reports/ while it already has a session open). loop.sh only OPENS them,
# and only when a human is present, so fleet/auto/headless stay pure text.

default_browser_cmd() { # macOS `open`, Windows (Git Bash/Cygwin) cygstart/PowerShell, else `xdg-open`
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo open ;;
    MINGW*|MSYS*|CYGWIN*)
      # bare `start` is a cmd builtin (not on PATH), so open_file_now's `command -v`
      # guard would reject it — prefer openers that actually resolve on PATH.
      if   command -v cygstart   >/dev/null 2>&1; then echo cygstart
      elif command -v powershell >/dev/null 2>&1; then echo "powershell -NoProfile -Command Start-Process"
      else echo start; fi ;;
    *)      echo xdg-open ;;
  esac
}

# open_html <file> — show an HTML page in the user's browser, but ONLY with a human
# present: interactive stdin AND not auto mode. fleet, `auto`, and every headless
# run start loop.sh with stdin from /dev/null, so this is a silent no-op there (the
# text surfaces already cover those). LOOP_BROWSER_CMD overrides the opener (and is
# the seam the test suite stubs). Never fatal.
# low-level launcher: resolve the opener and open the file. NO human-presence
# gating — each caller decides that (see open_html vs cmd_open). Never fatal.
open_file_now() {
  local f="${1:-}" opener
  [ -n "$f" ] && [ -f "$f" ] || { note "nothing to open (missing file): $f"; return 0; }
  case "$f" in /*) ;; *) f="$PWD/$f" ;; esac   # absolute path: openers are cwd-agnostic
  opener="${LOOP_BROWSER_CMD:-$(default_browser_cmd)}"
  if ! command -v "${opener%% *}" >/dev/null 2>&1; then
    note "open it manually (no '${opener%% *}' on PATH): $f"
    return 0
  fi
  note "opening $f in your browser"
  # word-split $opener ON PURPOSE so LOOP_BROWSER_CMD can carry args (e.g. "open -a Safari")
  # shellcheck disable=SC2086
  $opener "$f" >/dev/null 2>&1 || note "could not open $f — open it manually"
  return 0
}

# AUTOMATIC opener (report banner / finish): open only when a human is present at
# THIS process — interactive stdin AND not auto. fleet, `auto`, and headless start
# loop.sh with stdin from /dev/null, so this is a silent no-op there. Missing file
# = no-op. (Explicit `./loop.sh open` uses cmd_open, which does NOT require a TTY.)
open_html() {
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  { [ -t 0 ] && [ "$AUTO_MODE" != "1" ]; } || return 0
  open_file_now "$1"
}

# Whether an agent should author the HTML view, emitted as a skill-prompt token so
# headless agents need not read the environment. Tri-state: HTML is never authored
# unconditionally and never suppressed purely by mode — under html=auto the skill
# applies the pre-declared rubric per deliverable, and the harness journals its
# HTML-DECISION declaration (record_html_decision). Advisory, never breaks autonomy.
html_arg() {
  case "${LOOP_HTML:-}" in
    1) printf ' html=on' ;;      # force-author (human demands the view)
    0) printf ' html=off' ;;     # force-never (token saving / CI)
    *) printf ' html=auto' ;;    # skill applies the pre-declared rubric per deliverable
  esac
}

ask_arg() { # opt-in: headless generation may raise CRITICAL unknowns instead of assuming
  [ "${LOOP_ASK_CRITICAL:-0}" = "1" ] && printf ' ask=critical' || true
}

need_awk() { # journal + cost accounting are done in awk (POSIX, ships on every
  # Unix/macOS/Linux by default); a missing awk must fail at startup with a clear
  # message, never mid-run. In practice this guard should never trip.
  command -v awk >/dev/null 2>&1 \
    || die_next "awk not found — required for the journal and cost accounting" \
                "install awk (gawk/mawk) — it ships by default on macOS & Linux"
}

SHA_TOOL=""   # resolved once on first use (avoids a per-call `command -v` + awk fork).
              # sha256() is on every approval/tamper hot path (~30+ calls/run). On
              # macOS `shasum` is a Perl script (~18ms/call just to start perl); the
              # coreutils `sha256sum` binary is ~5x faster (~4ms), so PREFER it when
              # present and fall back to shasum (always available on macOS). SHA-256
              # output is identical whichever tool runs, so recorded approval/harness
              # hashes stay comparable across tools and machines (guarded by the
              # "sha256() parity" test).
sha256() { # stdin -> hex digest: the leading hex field only, byte-identical to the
  # old `... | awk '{print $1}'`. need_sha guarantees at startup one tool exists.
  if [ -z "$SHA_TOOL" ]; then
    if command -v sha256sum >/dev/null 2>&1; then SHA_TOOL=sha256sum; else SHA_TOOL=shasum; fi
  fi
  local out
  if [ "$SHA_TOOL" = sha256sum ]; then out=$(sha256sum); else out=$(shasum -a 256); fi
  printf '%s\n' "${out%% *}"
}

need_sha() { # every approval / tamper check is a SHA-256 compare; a missing tool
  # yields empty hashes and an undiagnosable permanent "changed" — die up front.
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
    || die_next "no SHA-256 tool found (shasum or sha256sum) — required for approval and tamper detection" \
                "install coreutils (sha256sum) or perl (shasum) — both ship by default on macOS & Linux"
}

# need_claude — one guard for the CLI every model call needs, with a single
# canonical message, replacing the open-coded `command -v "$CLAUDE_CMD"` checks.
# Pass fleet=1 to route the error through the fleet prefix/recovery helper.
need_claude() {
  command -v "$CLAUDE_CMD" >/dev/null 2>&1 && return 0
  if [ "${1:-}" = fleet ]; then
    fdie_next "claude CLI not found ('$CLAUDE_CMD')" "install Claude Code, or point LOOP_CLAUDE_CMD at its path"
  else
    die_next "claude CLI not found ('$CLAUDE_CMD')" "install Claude Code, or point LOOP_CLAUDE_CMD at its path"
  fi
}

# ---------- config / models (verify-then-load; models are parsed, never sourced) ----------

need_kit() {
  [ -f loop.config.sh ] || die "no loop.config.sh in $(pwd) — deploy the kit first: <kit>/bin/loop.sh init ."
}

contract_hash() {
  cat .loop/docs/product-contract.md loop.config.sh 2>/dev/null | sha256
}

harness_hash() {
  {
    cat "$SELF" "$EVALUATOR" 2>/dev/null
    cat .claude/skills/loop-*/SKILL.md 2>/dev/null
    # session config that changes what FUTURE agent sessions may do (permission
    # allowlists, MCP servers). These are often gitignored by the project, so
    # the evaluator's diff policy cannot see them — only this hash can.
    cat .claude/settings.json .claude/settings.local.json .mcp.json 2>/dev/null || true
  } | sha256
}

models_hash() {
  # loop.models.sh / fleet.config.sh are freely editable BETWEEN runs (no
  # re-approval, by design), but they are gitignored, so the evaluator's diff
  # policy cannot see a mid-run edit. The in-memory baseline taken at run
  # start closes that: any change while the loop is running can only come
  # from inside the loop and is flagged as tampering.
  {
    cat loop.models.sh 2>/dev/null || true
    cat fleet.config.sh 2>/dev/null || true
  } | sha256
}

approval_home() { # root of the OFF-TREE approval store. The repo-local records
  # (.loop/approved*) are agent-writable — a store outside the project tree is
  # the provenance anchor a forged mirror cannot reach (worker sessions get Bash
  # allowlists scoped to the project; acceptEdits auto-approves only inside it).
  # The literal value `repo` opts back into repo-local-only behavior (escape
  # hatch for no-HOME/container environments).
  printf '%s' "${LOOP_APPROVAL_HOME:-$HOME/.loop-kit/approvals}"
}

approval_slot() { # -> <home>/<repo-id>/<slot-id> for THIS working directory.
  # repo-id = sha256 of the absolutized git COMMON dir: every worktree of one
  # repository groups under it (cmd_uninstall sweeps the whole group). slot-id =
  # sha256 of the absolute git dir: each worktree gets its OWN slot (.git vs
  # .git/worktrees/<id>) — fleet workers run `./loop.sh approve` concurrently
  # inside their worktrees, and a single shared record would be clobbered by
  # every worker approval. Non-git fallback: both ids from $PWD.
  local common gitdir repo_id slot_id
  if common=$(git rev-parse --git-common-dir 2>/dev/null) && [ -n "$common" ]; then
    case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
    gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || gitdir="$common"
    repo_id=$(printf '%s' "$common" | sha256)
    slot_id=$(printf '%s' "$gitdir" | sha256)
  else
    repo_id=$(printf '%s' "$PWD" | sha256)
    slot_id="$repo_id"
  fi
  printf '%s/%s/%s' "$(approval_home)" "$repo_id" "$slot_id"
}

task_start_ref_file() { # off-tree task baseline (integrity-checked while this process lives)
  [ "$(approval_home)" != "repo" ] || return 0
  printf '%s/task-start-ref' "$(approval_slot)"
}

record_task_start_ref() { # $1 first fresh-run base; write once per task, atomically
  local ref path tmp
  ref=$(canonical_commit_id "$1") \
    || die "cannot record task baseline: '$1' is not a full commit object id"
  path=$(task_start_ref_file)
  [ -n "$path" ] || return 0
  [ ! -e "$path" ] || return 0
  mkdir -p "${path%/*}"
  tmp="${path%/*}/.task-start-ref.tmp.$$"
  printf '%s\n' "$ref" > "$tmp"
  # A concurrent sanctioned fresh start is already refused by the singleton;
  # the no-clobber check above defines the first run as the task baseline.
  [ -e "$path" ] || mv -f "$tmp" "$path"
  rm -f "$tmp"
}

canonical_commit_id() { # $1 must be a full SHA-1/SHA-256 commit id; prints canonical id
  local ref="${1:-}" oid
  case "${#ref}" in 40|64) ;; *) return 1 ;; esac
  case "$ref" in *[!0-9A-Fa-f]*) return 1 ;; esac
  oid=$(git rev-parse --verify "${ref}^{commit}" 2>/dev/null) || return 1
  case "${#oid}" in 40|64) ;; *) return 1 ;; esac
  printf '%s' "$oid"
}

pin_task_start_ref() { # load once; later checks detect deletion/replacement in this run
  local raw="" canonical=""
  TASK_START_REF_PATH=$(task_start_ref_file)
  TASK_START_REF=""
  TASK_START_REF_EXPECTED=""
  TASK_START_REF_PINNED=1
  [ -n "$TASK_START_REF_PATH" ] || return 1
  raw=$(cat "$TASK_START_REF_PATH" 2>/dev/null || true)
  TASK_START_REF_EXPECTED="$raw"
  canonical=$(canonical_commit_id "$raw" 2>/dev/null || true)
  [ -n "$canonical" ] || return 1
  # Store only canonical full ids. In particular, a moving symbolic ref such as
  # HEAD must never be re-resolved later and silently shrink the task diff.
  [ "$raw" = "$canonical" ] || return 1
  TASK_START_REF="$canonical"
  return 0
}

task_start_ref_intact() { # exact byte-value check against the process-pinned copy
  local current=""
  [ "$TASK_START_REF_PINNED" -eq 1 ] || return 0
  [ -n "$TASK_START_REF_PATH" ] || return 0   # LOOP_APPROVAL_HOME=repo: no anchor
  current=$(cat "$TASK_START_REF_PATH" 2>/dev/null || true)
  [ "$current" = "$TASK_START_REF_EXPECTED" ]
}

observation_manifest_state() { # type-aware state; deletion/symlink swaps cannot alias empty
  local path=.loop/observations-manifest.jsonl digest target
  if [ -L "$path" ]; then
    target=$(readlink "$path" 2>/dev/null) || return 1
    printf 'symlink:%s' "$target"
  elif [ -f "$path" ]; then
    digest=$(sha256 < "$path") || return 1
    [ -n "$digest" ] || return 1
    printf 'file:%s' "$digest"
  elif [ -e "$path" ]; then
    printf 'other'
  else
    printf 'absent'
  fi
}

pin_observation_manifest() { # call at run start and after trusted evaluator writes
  OBS_MANIFEST_EXPECTED=$(observation_manifest_state) || return 1
  case "$OBS_MANIFEST_EXPECTED" in absent|file:*) ;; *) return 1 ;; esac
  OBS_MANIFEST_PINNED=1
}

observation_manifest_intact() {
  local current
  [ "$OBS_MANIFEST_PINNED" -eq 1 ] || return 0
  current=$(observation_manifest_state) || return 1
  [ "$current" = "$OBS_MANIFEST_EXPECTED" ]
}

clear_task_start_ref() { # NEW task boundary; amendments deliberately keep it
  local path
  path=$(task_start_ref_file)
  [ -z "$path" ] || rm -f "$path"
}

verify_approval() { # dies unless both hashes match the approved ones
  [ -f .loop/approved ] || die "contract not approved — review .loop/docs/product-contract.md + loop.config.sh, then: ./loop.sh approve"
  if [ "$(cat .loop/approved)" != "$(contract_hash)" ]; then
    die "contract or loop.config.sh changed since approval — review the change, then: ./loop.sh approve"
  fi
  # fail CLOSED on a missing harness record: cmd_approve always writes it, so its
  # absence means an old/partial deployment or a deleted file — either way the
  # harness baseline is unverifiable and must be re-established by a human.
  [ -f .loop/approved-harness ] \
    || die "harness approval record missing (.loop/approved-harness) — re-approve: ./loop.sh approve"
  if [ "$(cat .loop/approved-harness)" != "$(harness_hash)" ]; then
    die "harness or session config changed since approval (loop.sh / evaluate.sh / skills / .claude settings / .mcp.json) — if intentional, re-run: ./loop.sh approve"
  fi
  # off-tree approval store: the trust anchor BEHIND the (agent-writable) repo
  # mirrors above. The mirrors keep their checks and messages for honest, fast
  # diagnostics; the store then proves a human (or sanctioned auto flow) ran
  # `approve` for exactly these hashes. Fails closed — never silently repo-only.
  if [ "$(approval_home)" != "repo" ]; then
    local slot
    slot=$(approval_slot)
    { [ -f "$slot/approved" ] && [ -f "$slot/approved-harness" ]; } \
      || die "contract not approved in the approval store ($slot) — repo-local records alone are no longer trusted (they are agent-writable); re-approve: ./loop.sh approve"
    if [ "$(cat "$slot/approved")" != "$(contract_hash)" ] \
       || [ "$(cat "$slot/approved-harness")" != "$(harness_hash)" ]; then
      die "contract or harness changed since the store-recorded approval (approval store: $slot) — review the change, then re-approve: ./loop.sh approve"
    fi
  fi
}

# ---------- resume checkpoint (durable per-run state, so a crashed/interrupted
# run continues where it left off instead of restarting from iteration 1) ----------
# The checkpoint lives at .loop/run-checkpoint, a KEY=VALUE file that is PARSED as
# data and NEVER sourced (same discipline as loop.models.sh / fleet's runs/*.env).
# It is under .loop/ (agent-writable, excluded from the diff policy and git), so it
# carries no integrity weight: no field is read on the SUCCESS path, and every
# possible forgery is bounded above by a fresh run (see the resume-mode logic).

config_hash_sans_budget() {
  # contract + config with the budget knobs normalized out. Lets `resume` tell a
  # human who raised ONLY MAX_ITERATIONS / MAX_COST_USD / MAX_RUN_SECONDS (and
  # re-approved) apart from any other config change — so an exhausted run can
  # continue under a bigger budget instead of restarting.
  {
    cat .loop/docs/product-contract.md 2>/dev/null
    grep -vE '^[[:space:]]*(MAX_ITERATIONS|MAX_COST_USD|MAX_RUN_SECONDS)=' loop.config.sh 2>/dev/null || true
  } | sha256
}

ckpt_get() { # $1 KEY -> last value for KEY, or empty. Always returns 0 (set -e safe).
  local line=""
  if [ -f .loop/run-checkpoint ]; then
    line=$(grep -E "^$1=" .loop/run-checkpoint 2>/dev/null | tail -1 || true)
  fi
  echo "${line#*=}"
}

ckpt_int() { # $1 KEY $2 default -> a sanitized non-negative integer (never trusts a forged value)
  local v; v=$(ckpt_get "$1")
  case "$v" in
    ""|*[!0-9]*) echo "$2" ;;
    *)           echo "$v" ;;
  esac
}

# CK_* run constants are set once by the fresh/resume setup in cmd_run; the mutable
# fields (iteration, counters, cost, resume-count) are passed per write.
ckpt_write() { # $1 iter $2 agent_failures $3 gate_revise $4 iter_revise $5 resume_count
  local tmp=.loop/run-checkpoint.tmp
  {
    echo "ITERATION=$1"
    echo "RUN_START_REF=${CK_RUN_START_REF:-}"
    echo "RUN_ID=${CK_RUN_ID:-${RUN_ID:-}}"
    echo "AGENT_FAILURES=$2"
    echo "GATE_REVISE_COUNT=$3"
    echo "ITER_REVISE_COUNT=$4"
    echo "TOTAL_COST=$TOTAL_COST"
    echo "CONTRACT_HASH=${RUN_CONTRACT_HASH:-}"
    echo "HARNESS_HASH=${RUN_HARNESS_HASH:-}"
    echo "CONFIG_HASH_SANS_BUDGET=${CK_CONFIG_SB:-}"
    echo "MAX_ITERATIONS_AT_START=${CK_MAXIT_START:-}"
    echo "RESUME_COUNT=$5"
    echo "CREATED_AT=${CK_CREATED_AT:-}"
    echo "UPDATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '')"
  } > "$tmp"
  mv -f "$tmp" .loop/run-checkpoint
}

new_run_id() { date -u '+run-%Y%m%d-%H%M%S' 2>/dev/null || echo "run-unknown-$$"; }

initialize_run_identity() { # $1 fresh|resume; before any run/decompose model call
  local mode="$1" saved=""
  TASK_ID=$(cat .loop/task-id 2>/dev/null || true)
  if ! valid_log_segment "$TASK_ID"; then
    assign_new_task_id
    TASK_ID=$(cat .loop/task-id)
  fi
  if fleet_inflight && [ -s .loop/fleet/run-id ]; then
    saved=$(cat .loop/fleet/run-id 2>/dev/null || true)
  elif [ "$mode" = "resume" ]; then
    saved=$(ckpt_get RUN_ID)
  fi
  valid_log_segment "$saved" || saved=""
  RUN_ID="${saved:-$(new_run_id)}"
}

ckpt_rebind_decision() { # $1 the decision state being answered — atomic field rewrite.
  # Re-binds the checkpoint to the NEW approved hashes so `run` RESUMES the stopped
  # run (counters/cost intact) instead of restarting fresh and re-asking the same
  # question. Only cmd_approve calls this, with the human present (see there).
  # $$-unique temp: cmd_approve can run while a loop process is mid-ckpt_write —
  # a shared temp path would let the two writers clobber each other's staging file
  local st="$1" tmp=.loop/run-checkpoint.tmp.$$
  {
    grep -vE '^(CONTRACT_HASH|HARNESS_HASH|DECISION_REBOUND|DECISION_STATE)=' .loop/run-checkpoint || true
    echo "CONTRACT_HASH=$(contract_hash)"
    echo "HARNESS_HASH=$(harness_hash)"
    echo "DECISION_REBOUND=1"
    echo "DECISION_STATE=$st"
  } > "$tmp"
  mv -f "$tmp" .loop/run-checkpoint
  # answer channel: loop-iterate already treats supervisor-guidance.md as the
  # human decision (same contract the fleet ANSWER path writes) — zero skill edits
  {
    echo "# Human decision ($st answered; contract re-approved)"
    echo "# Treat the CURRENT .loop/docs/product-contract.md (+ loop.config.sh) as the"
    echo "# authoritative answer to the pending request(s) in .loop/docs/decision-requests.md."
    echo "# Re-read both before implementing; fold this into progress.md, then delete this file."
  } > .loop/supervisor-guidance.md
  journal_append "approve" "DECISION_REBIND" "checkpoint re-bound after $st — run will resume with counters/cost intact"
  note "decision answered — './loop.sh run' resumes the run (iteration counters and cost preserved)"
}

load_config() {
  # SECURITY: only call after verify_approval — this executes shell code.
  # shellcheck disable=SC1091
  . ./loop.config.sh
  : "${MAX_ITERATIONS:=10}"
  : "${MAX_COST_USD:=}"        # empty = no USD cap (subscription-first default)
  : "${MAX_RUN_SECONDS:=}"     # empty = no wall-clock cap; seconds, per-process
                               # (a resume gets a fresh window)
  if [ -n "$MAX_RUN_SECONDS" ]; then
    case "$MAX_RUN_SECONDS" in
      *[!0-9]*) die_next "MAX_RUN_SECONDS must be an integer number of seconds" "fix MAX_RUN_SECONDS in loop.config.sh" ;;
    esac
  fi
  : "${MAX_ITER_SECONDS:=900}"
  : "${STAGNATION_N:=2}"
  : "${REPEAT_FAIL_N:=3}"
  : "${MAX_REVISIONS:=3}"
  : "${FUTILE_N:=2}"
  : "${REVIEW_MODE:=always}"     # always | candidate | off
  : "${HOLISTIC_EVERY_N:=3}"     # every Nth interim review audits the WHOLE run diff (0 = off)
  : "${HOLISTIC_TRIGGER_LINES:=400}" # iteration diffs >= this many lines also widen the review (0 = off)
  : "${STOP_EVAL:=true}"
  : "${MET_FORCE_N:=2}"          # consecutive MET stop-evals + verify green -> force the success gate (0 = off)
  : "${LOOP_OBS_MAX_FILE_KB:=2048}"
  : "${LOOP_OBS_MAX_TOTAL_MB:=50}"
  case "$LOOP_OBS_MAX_FILE_KB:$LOOP_OBS_MAX_TOTAL_MB" in
    *[!0-9:]*) die_next "LOOP_OBS_MAX_FILE_KB and LOOP_OBS_MAX_TOTAL_MB must be integer size limits" "fix the observation limits in loop.config.sh" ;;
  esac
  : "${SPLIT_NUDGE_AT:=70}"      # fleet workers: past this % of MAX_ITERATIONS with
                                 # unmet ledger REQs, nudge the agent to declare
                                 # NEEDS_DECOMPOSITION at a clean boundary (0 = off)
  case "$SPLIT_NUDGE_AT" in
    *[!0-9]*) die_next "SPLIT_NUDGE_AT must be an integer percent (0 disables)" "fix SPLIT_NUDGE_AT in loop.config.sh" ;;
  esac
  : "${PERMISSION_MODE:=acceptEdits}"   # deny-enforcing; bypassPermissions would IGNORE DISALLOWED_TOOLS
  : "${ALLOWED_TOOLS:=Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit}"
  : "${DISALLOWED_TOOLS:=}"             # opt-in tool deny-list (primary control); empty = deny nothing
  # bounded retry when the gate reviewer is UNAVAILABLE (call fails twice):
  # 0 = current fail-closed behavior (immediate BLOCKED). In the approval hash
  # deliberately — the gate's retry policy is part of the contracted gate.
  : "${GATE_RETRY_N:=0}"
  case "$GATE_RETRY_N" in
    *[!0-9]*) die_next "GATE_RETRY_N must be an integer 0-5" "fix GATE_RETRY_N in loop.config.sh" ;;
  esac
  [ "$GATE_RETRY_N" -le 5 ] || die_next "GATE_RETRY_N must be an integer 0-5" "fix GATE_RETRY_N in loop.config.sh"
  : "${GATE_RETRY_WAITS:=60 300}"   # seconds before retry k (last entry repeats)
  local _w _wn=0
  for _w in $GATE_RETRY_WAITS; do
    case "$_w" in
      *[!0-9]*) die_next "GATE_RETRY_WAITS must be space-separated integer seconds" "fix GATE_RETRY_WAITS in loop.config.sh" ;;
    esac
    _wn=$((_wn + 1))
  done
  # a whitespace-only value would word-split to nothing and validate vacuously,
  # turning every retry into a zero-backoff hot loop against an outage
  [ "$_wn" -ge 1 ] || [ "$GATE_RETRY_N" -eq 0 ] \
    || die_next "GATE_RETRY_WAITS must contain at least one integer (seconds)" "fix GATE_RETRY_WAITS in loop.config.sh"
  # runaway backstop for resume: max consecutive resumes that never complete an
  # iteration. Set here (not in the contract) so it is NOT part of the approval
  # hash — a pure guard, tunable between runs without re-approval.
  : "${MAX_RESUMES:=10}"
}

get_model() { # $1 role var, $2 default — safe key=value parse, no code execution
  local v=""
  if [ -f loop.models.sh ]; then
    v=$(grep -E "^[[:space:]]*$1=" loop.models.sh | tail -1 \
        | sed -E 's/^[^=]+=//; s/#.*$//; s/"//g; s/[[:space:]]//g') || v=""
  fi
  echo "${v:-$2}"
}

resolve_effort() { # $1 optional role key (e.g. REVIEW) — echoes the effective
  # reasoning effort for that role, or nothing.
  # Same safe key=value parse as get_model (efforts live in loop.models.sh
  # alongside the model roles — a tuning choice, not part of the approval hash).
  # Resolution: EFFORT_<ROLE> if valid, else LOOP_EFFORT if valid, else no flag
  # (CLI default). An unrecognized value FALLS THROUGH/drops rather than dying:
  # this resolves lazily inside every call, so a between-runs typo must degrade
  # to the inherited effort, never kill a mid-run loop (unlike the loop.config.sh
  # enums, which are whitelist-validated once at load and may die loudly).
  local e
  if [ -n "${1:-}" ]; then
    e=$(get_model "EFFORT_$1" "")
    case "$e" in low|medium|high|xhigh|max) printf '%s' "$e"; return 0 ;; esac
  fi
  e=$(get_model LOOP_EFFORT "")
  case "$e" in
    low|medium|high|xhigh|max) printf '%s' "$e" ;;
    *) : ;;
  esac
}

effort_opt() { # $1 optional role key — echoes '--effort <level>' for that role's
  # effective effort, else nothing. Unquoted expansion at the call site
  # word-splits this into two args (the level has no spaces); when empty it
  # vanishes, adding no argument.
  local e; e=$(resolve_effort "${1:-}")
  [ -z "$e" ] || printf -- '--effort %s' "$e"
}

resolve_iter_timeout() { # $1 optional role key — echoes the effective per-call
  # wall-clock watchdog (seconds) for that role. Resolution: TIMEOUT_<ROLE> when
  # it is a positive integer, else the global MAX_ITER_SECONDS (default 900). A
  # blank / zero / non-numeric override can never widen-by-typo or break a live
  # loop — it silently falls back to the approved global (same fail-safe posture
  # as resolve_effort). Lets a heavy IMPLEMENT call outlast a clerical STOP_EVAL.
  #
  # Per-role overrides live in loop.config.sh (NOT loop.models.sh): the watchdog
  # is an anti-runaway SAFETY budget, so widening it must pass through the
  # approval hash (contract_hash) — never the freely-editable, un-hashed model
  # file, which would let a run raise its own runaway ceiling without re-approval.
  # loop.config.sh is sourced after that hash check, so TIMEOUT_<ROLE> is a plain
  # shell var here; the pre-approval paths that never source it (contract
  # gen/review, manual fleet supervise) leave it unset -> global fallback.
  local base="${MAX_ITER_SECONDS:-900}" key val
  if [ -n "${1:-}" ]; then
    key="TIMEOUT_$1"
    val="${!key:-}"
    case "$val" in
      ''|*[!0-9]*) ;;                        # unset / non-numeric -> global
      *) [ "$val" -gt 0 ] && base="$val" ;;  # positive integer    -> per-role
    esac
  fi
  printf '%s' "$base"
}

load_models() {
  # (MODEL_CONTRACT is resolved inline at contract-definition time via get_model,
  #  not here — load_models runs in cmd_run, after the contract already exists.)
  MODEL_PLAN=$(get_model MODEL_PLAN opus)
  MODEL_IMPLEMENT=$(get_model MODEL_IMPLEMENT opus)
  MODEL_REVIEW=$(get_model MODEL_REVIEW opus)
  # interim reviews only (steering feedback each iteration); empty = inherit
  # MODEL_REVIEW. The gate/decompose/contract reviews (certification) always
  # use MODEL_REVIEW — this knob never weakens an approval-adjacent check.
  MODEL_REVIEW_INTERIM=$(get_model MODEL_REVIEW_INTERIM "")
  MODEL_EVIDENCE=$(get_model MODEL_EVIDENCE sonnet)
  MODEL_STOP_EVAL=$(get_model MODEL_STOP_EVAL haiku)
  MODEL_DECOMPOSE=$(get_model MODEL_DECOMPOSE opus)
  # shellcheck disable=SC2034  # consumed by the supervise step (fleet dispatcher)
  MODEL_SUPERVISE=$(get_model MODEL_SUPERVISE opus)
}

ensure_loop_dir() {
  mkdir -p .loop/bin .loop/docs .loop/logs .loop/reports
  # self-ignoring state dir; docs stay tracked (auditable loop memory).
  # .loop/reports/ (model-authored HTML views) is a disposable projection of the
  # tracked .md docs — the `*` rule below keeps it untracked, like logs.
  printf '*\n!.gitignore\n!docs\n!docs/**\n' > .loop/.gitignore
}

# The kit's own files, deployed at the project root. The loop runs `git add -A`
# while it works, so without ignoring these it would sweep its own harness into
# the user's project history. (.loop/ is handled by .loop/.gitignore above,
# which keeps only docs/ tracked.)
LOOP_IGNORE_MARKER="# loop-kit: harness files (do not commit into your project)"
FLEET_IGNORE_MARKER="# loop-kit: fleet files (parallel supervisor; do not commit)"

ensure_gitignore() { # $1 = project dir (default: current dir). Additive + idempotent.
  local gi="${1:-.}/.gitignore" sep=""
  # each block is keyed on its own marker so deployments that predate a block
  # pick it up on the next run without touching the blocks already installed
  if ! { [ -f "$gi" ] && grep -qF "$LOOP_IGNORE_MARKER" "$gi"; }; then
    # separate our block from any existing content with one blank line — decided
    # BEFORE the append redirect opens, so we never read and write $gi at once
    [ -s "$gi" ] && sep=$'\n'
    {
      printf '%s' "$sep"
      printf '%s\n' "$LOOP_IGNORE_MARKER"
      printf '/loop.sh\n'
      printf '/loop.config.sh\n'
      printf '/loop.models.sh\n'
      printf '/loop-instruction.md\n'
      printf '/.claude/skills/loop-*/\n'
    } >> "$gi"
    note "harness added to $gi — kit files will not be committed to your project"
  fi
  if ! grep -qF "$FLEET_IGNORE_MARKER" "$gi" 2>/dev/null; then
    {
      printf '\n%s\n' "$FLEET_IGNORE_MARKER"
      printf '/fleet.sh\n'
      printf '/fleet.config.sh\n'
    } >> "$gi"
  fi
}

strip_gitignore_blocks() { # $1 = project dir — exact inverse of ensure_gitignore.
  # Removes only the lines the kit's two blocks install (plus the one blank
  # separator ensure_gitignore put before each marker); the user's own entries
  # and spacing are untouched. Deletes .gitignore if nothing but whitespace is left.
  local gi="$1/.gitignore" tmp
  [ -f "$gi" ] || return 0
  tmp="$gi.uninstall.$$"
  awk -v m1="$LOOP_IGNORE_MARKER" -v m2="$FLEET_IGNORE_MARKER" '
    function ours(l) {
      return l == m1 || l == m2 || l == "/loop.sh" || l == "/loop.config.sh" \
          || l == "/loop.models.sh" || l == "/loop-instruction.md" \
          || l == "/.claude/skills/loop-*/" || l == "/fleet.sh" || l == "/fleet.config.sh"
    }
    {
      if ($0 == "") { if (held) print ""; held = 1; next }   # hold one blank line
      if (ours($0)) { if ($0 == m1 || $0 == m2) held = 0; next }  # marker eats its separator
      if (held) { print ""; held = 0 }
      print
    }
    END { if (held) print "" }
  ' "$gi" > "$tmp"
  mv -f "$tmp" "$gi"
  grep -q '[^[:space:]]' "$gi" 2>/dev/null || rm -f "$gi"
}

# ---------- small helpers ----------

# ---------- JSON in POSIX awk (no python/jq dependency) ----------
# json_escape: stdin -> a JSON string body (no surrounding quotes). Char-by-char
# so the escapes live in string-concatenation context, not gsub's replacement
# grammar (whose backslash rules differ across awks) — portable to BSD awk and
# gawk/mawk alike. Real newlines in the input become the two-char sequence \n.
json_escape() {
  awk '
    {
      line = $0; esc = ""; m = length(line)
      for (k = 1; k <= m; k++) {
        ch = substr(line, k, 1)
        if      (ch == "\\") esc = esc "\\\\"
        else if (ch == "\"") esc = esc "\\\""
        else if (ch == "\t") esc = esc "\\t"
        else if (ch == "\r") esc = esc "\\r"
        else                 esc = esc ch
      }
      out = (NR == 1 ? esc : out "\\n" esc)
    }
    END { printf "%s", out }
  '
}

json_num() { # $1 numeric string -> fixed-point decimal (Python-float style), always [0-9.]+
  awk -v x="${1:-0}" 'BEGIN{
    if (x == "") x = 0
    s = sprintf("%.6f", x + 0)
    sub(/0+$/, "", s)      # trim trailing zeros: 0.010000 -> 0.01
    sub(/\.$/, ".0", s)    # keep one decimal: 0. -> 0.0  (matches json.dumps of a float)
    printf "%s", s
  }'
}

json_field() { # $1 file, $2 field, $3 default -> top-level scalar value (JSON-unescaped if a string)
  [ -f "$1" ] || { printf '%s\n' "$3"; return 0; }   # missing/unreadable file -> default (matches the old python)
  awk -v want="$2" -v def="$3" '
    function skip_ws(s, i, n,   c) {
      while (i <= n) { c = substr(s, i, 1); if (c==" "||c=="\t"||c=="\n"||c=="\r") i++; else break }
      return i
    }
    function hex2dec(h,   i, c, d, r) {
      r = 0; h = tolower(h)
      for (i = 1; i <= length(h); i++) { c = substr(h, i, 1); d = index("0123456789abcdef", c) - 1; if (d < 0) d = 0; r = r*16 + d }
      return r
    }
    function utf8(code,   b1, b2, b3) {
      if (code < 128) return sprintf("%c", code)
      else if (code < 2048) { b1 = 192 + int(code/64); b2 = 128 + (code%64); return sprintf("%c%c", b1, b2) }
      else { b1 = 224 + int(code/4096); b2 = 128 + int((code/64)%64); b3 = 128 + (code%64); return sprintf("%c%c%c", b1, b2, b3) }
    }
    function parse_string(s, i, n,   out, c, e, code) {   # s[i] is the opening quote; sets RESULT_STR, returns index past the close
      i++; out = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") {
          i++; e = substr(s, i, 1)
          if      (e == "n") out = out "\n"
          else if (e == "t") out = out "\t"
          else if (e == "r") out = out "\r"
          else if (e == "b") out = out "\b"
          else if (e == "f") out = out "\f"
          else if (e == "/") out = out "/"
          else if (e == "\"") out = out "\""
          else if (e == "\\") out = out "\\"
          else if (e == "u") { code = hex2dec(substr(s, i+1, 4)); out = out utf8(code); i += 4 }
          else out = out e
          i++
        } else if (c == "\"") { i++; break }
        else { out = out c; i++ }
      }
      RESULT_STR = out; return i
    }
    function skip_container(s, i, n,   c, depth, instr) {   # s[i] is { or [; returns index past the matching close
      depth = 0; instr = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (instr) { if (c == "\\") { i += 2; continue } if (c == "\"") instr = 0; i++; continue }
        if (c == "\"") { instr = 1; i++; continue }
        if (c == "{" || c == "[") { depth++; i++; continue }
        if (c == "}" || c == "]") { depth--; i++; if (depth == 0) return i; continue }
        i++
      }
      return i
    }
    { data = (NR == 1 ? $0 : data "\n" $0) }
    END {
      n = length(data); i = 1
      while (i <= n && substr(data, i, 1) != "{") i++
      if (i > n) { print def; exit }
      i++
      while (i <= n) {
        i = skip_ws(data, i, n); c = substr(data, i, 1)
        if (c == "}") { print def; exit }
        if (c != "\"") { print def; exit }
        i = parse_string(data, i, n); key = RESULT_STR
        i = skip_ws(data, i, n); if (substr(data, i, 1) != ":") { print def; exit }
        i++; i = skip_ws(data, i, n); c = substr(data, i, 1)
        if (c == "\"") {
          i = parse_string(data, i, n); val = RESULT_STR
          if (key == want) { print val; exit }
        } else if (c == "{" || c == "[") {
          i = skip_container(data, i, n)
          if (key == want) { print def; exit }   # a container is not a scalar field
        } else {
          j = i
          while (j <= n) { cc = substr(data, j, 1); if (cc==","||cc=="}"||cc=="]"||cc==" "||cc=="\t"||cc=="\n"||cc=="\r") break; j++ }
          val = substr(data, i, j - i); i = j
          if (key == want) { if (val == "null") print def; else print val; exit }   # JSON null -> default, like the old python
        }
        i = skip_ws(data, i, n); c = substr(data, i, 1)
        if (c == ",") { i++; continue }
        print def; exit
      }
      print def
    }
  ' "$1" 2>/dev/null
}

add_cost() { # $1 usd — TOTAL_COST (in-memory) is authoritative; the file is display-only
  TOTAL_COST=$(awk -v a="$TOTAL_COST" -v b="$1" 'BEGIN{printf "%.6f", a + b}')
  echo "$TOTAL_COST" > .loop/cost-total
}

budget_exceeded() { # never true when MAX_COST_USD is empty (no cap configured)
  [ -n "$MAX_COST_USD" ] || return 1
  awk -v t="$TOTAL_COST" -v m="$MAX_COST_USD" 'BEGIN{exit !(t >= m)}'
}

remaining_budget() { # only meaningful when MAX_COST_USD is set
  awk -v m="$MAX_COST_USD" -v t="$TOTAL_COST" 'BEGIN{r = m - t; if (r < 0.01) r = 0.01; printf "%.2f", r}'
}

derive_allowed_tools() {
  # The ALLOW side (broad by default). The loop runs in a deny-enforcing mode
  # (acceptEdits) so tools must be granted explicitly here; such a mode can't
  # wildcard-grant MCP, so to use a server in the loop add its mcp__<server> id to
  # ALLOWED_TOOLS. RESTRICTIONS go in DISALLOWED_TOOLS (deny wins over allow). Note:
  # bypassPermissions grants everything incl MCP but then ignores DISALLOWED_TOOLS.
  # The fallback (pre-approval callers that never source loop.config.sh, e.g. the
  # headless contract generator) must stay identical to load_config's default.
  echo "${ALLOWED_TOOLS:-Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit}"
}

launch_agent() { # "$@" = the full claude argv; backgrounds it in its OWN process
  # group and sets AGENT_PID (== the agent pid, which is the group leader). Runs in
  # THIS shell (not a subshell), so AGENT_PID persists to the caller. Any stdout/
  # stderr redirection on the CALL is inherited by the backgrounded agent.
  if [ "$AGENT_PGROUP_OK" = 1 ]; then
    # perl's exec replaces the image (pid preserved, so kill -0/wait stay valid);
    # setpgrp(0,0) puts it in a new group with pgid == pid. </dev/null is REQUIRED:
    # a child in its own group is no longer the tty's foreground group, so if the
    # agent ever read the controlling terminal it would get SIGTTIN and *stop*
    # (not exit), hanging wait forever. claude -p takes its prompt from -p, not
    # stdin, so detaching stdin is harmless (mirrors the fleet launches below).
    perl -e 'setpgrp(0,0); exec @ARGV or die "exec: $!"' -- "$@" </dev/null &
  else
    "$@" </dev/null &
  fi
  AGENT_PID=$!
}

kill_agent_group() { # $1 = agent pid (its own process-group leader via launch_agent).
  # Stops the whole agent subtree: SIGTERM the group, brief grace, then SIGKILL any
  # survivor. This is NOT cgroup-level containment — a descendant that calls
  # setsid()/setpgid() to leave the group escapes it — but it is strictly better
  # than a single-pid kill (which never reaches the agent's MCP/tool/sub-agent
  # children). Fallback: when the agent is NOT a group leader (perl unavailable),
  # the group `<pid>` is empty, so kill -<pid> ESRCHs and the || arm sends the
  # single-pid signal instead — exactly today's behavior. loop.sh's own group is
  # never targeted (only the recorded agent pid, which leads its own group or none).
  local pid="$1" i
  [ -n "$pid" ] || return 0
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do   # up to ~2s, but return the instant it's gone
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

valid_log_segment() { # ids are path segments, never relative-path operators
  local v="${1:-}"
  [ -n "$v" ] || return 1
  [ "$v" != "." ] && [ "$v" != ".." ] || return 1
  case "$v" in *[!A-Za-z0-9._:-]*) return 1 ;; esac
  return 0
}

active_log_dir() { # current in-memory task/run namespace; never revive stale disk ids
  local tid="${TASK_ID:-}" rid="${RUN_ID:-}"
  if valid_log_segment "$tid" && valid_log_segment "$rid"; then
    printf '%s/%s/%s' .loop/logs "$tid" "$rid"
  else
    printf '%s' .loop/logs/unassigned
  fi
}

agent_log_path() { # $1 label, $2 json|err
  printf '%s/%s.%s' "$(active_log_dir)" "$1" "$2"
}

run_claude() { # $1 label, $2 prompt, $3 model, $4 mode: full|reader,
  # $5 optional role key (EFFORT_<role> override; omitted = global effort only)
  # — cost accumulated
  local label="$1" prompt="$2" model="$3" mode="$4" role="${5:-}"
  local logdir out err
  logdir=$(active_log_dir)
  mkdir -p "$logdir"
  out="$logdir/${label}.json"
  err="$logdir/${label}.err"
  local pid status elapsed cost is_err timed_out=0
  AGENT_FAIL_DIAG=""   # set on failure; consumed by journal reasons + terminal messages

  # per-call USD cap only when a total budget is configured — subscription
  # usage has no per-token charge (see MAX_COST_USD in loop.config.sh)
  if [ -n "${MAX_COST_USD:-}" ]; then
    set -- --max-budget-usd "$(remaining_budget)"
  else
    set --
  fi

  # reasoning effort for this call (per-role EFFORT_* override, else the global
  # LOOP_EFFORT; empty resolution passes no flag -> the CLI's own default effort)
  local eff; eff=$(resolve_effort "$role")
  [ -z "$eff" ] || set -- "$@" --effort "$eff"

  # per-call wall-clock watchdog: a per-role TIMEOUT_<ROLE> override (else the
  # global MAX_ITER_SECONDS) — a heavy IMPLEMENT iteration can legitimately
  # outlast the clerical STOP_EVAL/EVIDENCE calls, so the ceiling is per role.
  local iter_timeout; iter_timeout=$(resolve_iter_timeout "$role")

  # opt-in session continuity (supervisor role): the caller sets
  # CLAUDE_RESUME_SESSION for ONE call; every tool/effort/model flag is still
  # passed explicitly per call, so a resumed session never widens permissions
  if [ -n "${CLAUDE_RESUME_SESSION:-}" ]; then
    set -- "$@" --resume "$CLAUDE_RESUME_SESSION"
    CLAUDE_RESUME_SESSION=""
  fi

  if [ "$mode" = "reader" ]; then
    # structurally read-only: editors and Bash do not exist in the session
    launch_agent "$CLAUDE_CMD" -p "$prompt" \
      --output-format json \
      --model "$model" \
      --fallback-model "sonnet" \
      --tools "Read,Glob,Grep" \
      "$@" \
      > "$out" 2> "$err"
  else
    # Full session: broad ALLOWED_TOOLS grants the worker its tools; DISALLOWED_TOOLS
    # (opt-in, loop.config.sh) restricts and wins over allow. Enforced under the
    # deny-enforcing acceptEdits mode (bypassPermissions would ignore the deny-list).
    [ -n "${DISALLOWED_TOOLS:-}" ] && set -- "$@" --disallowedTools "$DISALLOWED_TOOLS"
    launch_agent "$CLAUDE_CMD" -p "$prompt" \
      --output-format json \
      --model "$model" \
      --fallback-model "sonnet" \
      --permission-mode "$PERMISSION_MODE" \
      --allowedTools "$(derive_allowed_tools)" \
      "$@" \
      > "$out" 2> "$err"
  fi
  pid=$AGENT_PID
  CHILD_PID=$pid

  # Liveness poll. LOOP_WATCHDOG_POLL exists for the zero-token test suite: a
  # fake agent returns in milliseconds, so a fixed 2s poll would tax every one
  # of its ~100 calls with ~2s of pure sleep (minutes per suite run). Real runs
  # keep the 2s default. Elapsed time comes from bash's SECONDS so fractional
  # poll intervals cannot drift the integer arithmetic.
  local watch_start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    run_beat   # keep the run heartbeat fresh THROUGHOUT a long agent call, so a
               # live loop never reads stale to single_loop_alive/task_pid_alive
    sleep "${LOOP_WATCHDOG_POLL:-2}"
    elapsed=$((SECONDS - watch_start))
    if [ "$elapsed" -ge "$iter_timeout" ]; then
      note "watchdog: '$label' exceeded ${iter_timeout}s — killing agent"
      timed_out=1
      kill_agent_group "$pid"   # TERM→grace→KILL the whole agent subtree
      break
    fi
  done
  status=0
  wait "$pid" || status=$?
  CHILD_PID=""

  cost=$(json_field "$out" total_cost_usd 0)
  add_cost "$cost"
  echo "$cost" > .loop/last-cost
  # agent turns of THIS call (top-level scalar in the result JSON): the cheap
  # deterministic runaway-context signal — cache-read cost is a per-turn
  # multiplier, so turns is the per-call lever the harness can actually see
  json_field "$out" num_turns 0 > .loop/last-turns
  is_err=$(json_field "$out" is_error false)
  # session handle of THIS call's conversation (print-mode --resume may fork a
  # new id per call, so the freshest id is the only valid handle for the next
  # resume). In-memory only; the supervisor wrapper persists it when enabled.
  LAST_SESSION_ID=$(json_field "$out" session_id "")

  if [ "$status" -ne 0 ] || [ "$is_err" = "True" ] || [ "$is_err" = "true" ]; then
    # the CLI reports API-level failures in the stdout JSON (is_error/result),
    # NOT on stderr — surface both, and preserve the evidence before the next
    # run's identically-labeled call overwrites it
    local msg="" errtail=""
    msg=$(json_field "$out" result "" | head -c 200 | tr '\n' ' ')
    [ ! -s "$err" ] || errtail=$(tail -c 200 "$err" | tr '\n' ' ')
    AGENT_FAIL_DIAG="exit=$status is_error=$is_err"
    [ "$timed_out" = 0 ] || AGENT_FAIL_DIAG="$AGENT_FAIL_DIAG (watchdog kill after ${iter_timeout}s)"
    [ -z "$msg" ] || AGENT_FAIL_DIAG="$AGENT_FAIL_DIAG; msg: $msg"
    [ -z "$errtail" ] || AGENT_FAIL_DIAG="$AGENT_FAIL_DIAG; stderr: $errtail"
    preserve_failed_call "$label" "$out" "$err"
    note "agent call '$label' failed ($AGENT_FAIL_DIAG) — preserved: .loop/logs/failed/"
    return 1
  fi
  return 0
}

preserve_failed_call() { # $1 label $2 stdout-JSON $3 stderr — preserve globally
  # sidecars out of the per-run log dir (fixed names get overwritten by the next
  # run's identically-labeled call) into .loop/logs/failed/, pruned to the newest
  # 20 failures so evidence survives without unbounded growth.
  local label="$1" out="$2" err="$3" ts f
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p .loop/logs/failed
  for f in "$out" "$err"; do
    [ -s "$f" ] || continue
    cp "$f" ".loop/logs/failed/${label}.${ts}${f##*"$label"}" 2>/dev/null || true
  done
  # shellcheck disable=SC2012  # ls -t is the portable newest-first choice (macOS find lacks -printf)
  ls -t .loop/logs/failed/*.json 2>/dev/null | tail -n +21 | while IFS= read -r f; do
    rm -f "$f" "${f%.json}.err"
  done
  # orphan .err sidecars (empty-JSON failures) get the same bound
  # shellcheck disable=SC2012
  ls -t .loop/logs/failed/*.err 2>/dev/null | tail -n +21 | while IFS= read -r f; do
    [ -f "${f%.err}.json" ] || rm -f "$f"
  done
}

agent_result() { # $1 label -> the agent's final text
  json_field "$(agent_log_path "$1" json)" result ""
}

commit_if_changes() { # $1 message
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -q -m "$1"
  fi
}

journal_append() { # $1 iteration-label, $2 state, $3 reason
  local cost reason ts turns
  cost=$(cat .loop/last-cost 2>/dev/null || echo 0)
  turns=$(cat .loop/last-turns 2>/dev/null || echo 0)
  # UTC with Z suffix — same clock as fleet.sh's utcnow(), so the two journals and
  # the runs/*.env timestamps stay comparable. iteration/state are controlled
  # tokens (no quotes/backslashes) so they need no escaping; reason is free agent
  # text and is JSON-escaped. Field order + ", "/": " spacing reproduce Python's
  # json.dumps default — the test suite greps exact journal substrings ("turns"
  # is appended LAST so every pre-existing substring assertion stays valid).
  # AUDIT RULE: cost_usd/turns belong to the most recent agent CALL — bookkeeping
  # rows journaled between calls (nudges, gate retries, flake notes) inherit the
  # preceding call's values. Sum per-call cost from call-bearing state rows only
  # (cmd_report's role table does); total_usd is always safe to read.
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  reason=$(printf '%s' "$3" | json_escape)
  printf '{"ts": "%s", "iteration": "%s", "state": "%s", "reason": "%s", "cost_usd": %s, "total_usd": %s, "turns": %s}\n' \
    "$ts" "$1" "$2" "$reason" "$(json_num "$cost")" "$(json_num "$TOTAL_COST")" "$(json_num "$turns")" \
    >> .loop/journal.jsonl
}

finish() { # $1 state, $2 reason
  local state="$1" reason="$2"
  echo "$state" > .loop/state
  echo 0 > .loop/last-cost
  echo 0 > .loop/last-turns   # the terminal event is not an agent call
  rm -f .loop/run.pid .loop/run.heartbeat   # the liveness signals die with the run
  journal_append "final" "$state" "$reason"
  echo
  echo "══════════════════════════════════════════════════"
  echo " RESULT: $state"
  if [ -n "$reason" ]; then echo " $reason"; fi
  echo " total cost this run: \$$TOTAL_COST"
  echo " details: ./loop.sh report   |   trail: git log --oneline"
  # For states that KEEP the checkpoint (see the case below), print the exact
  # continue command so a human can retry immediately. It is `resume`, NOT a
  # bare `run`: decide_run_mode maps STALLED/BLOCKED→fresh without
  # --require-resume, so `run` would re-decompose from iteration 1 and drop the
  # progress this run already made. `resume` picks up from the saved checkpoint
  # with iteration counters + cost intact.
  # Every checkpoint-keeping stop shows a one-line signpost here so counters/cost
  # stay visible; the full, scannable choices are the boxed NEXT ACTION below.
  case "$state" in
    BLOCKED|STALLED|BUDGET_EXCEEDED)
      local _at; _at=$(ckpt_int ITERATION 0)
      if [ "$_at" -gt 0 ] 2>/dev/null; then
        echo " paused at iteration $_at (counters + cost preserved)"
      fi
      echo " next:    ↓ see NEXT ACTION below"
      ;;
  esac
  echo "══════════════════════════════════════════════════"
  case "$state" in
    SUCCESS|NO_OP)
      # the run reached its goal: nothing left to resume. Every OTHER terminal
      # state KEEPS .loop/run-checkpoint so `./loop.sh resume` (or, for a crash/
      # interrupt, a bare `./loop.sh run`) can continue.
      rm -f .loop/run-checkpoint
      # nothing left to run for this contract; the only forward move is a new task
      echo
      echo " Done — nothing left to run for this contract."
      echo " To start another task:  ./loop.sh start \"<requirement>\""
      # show the HTML evidence view when a human ran this interactively; no-op in
      # headless/auto, and the file exists only when HTML authoring was on
      open_html .loop/reports/evidence.html
      exit 0 ;;
    NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|RISK_REQUIRES_APPROVAL|PENDING_APPROVAL)
      echo
      echo "── Human decision required ──"
      if [ -f .loop/docs/decision-requests.md ]; then cat .loop/docs/decision-requests.md; fi
      # if the iteration authored a visual decision brief, show it too (no-op headless)
      open_html .loop/reports/decision.html
      if [ "$state" = "NEEDS_DECOMPOSITION" ]; then
        # NEEDS_DECOMPOSITION is NOT decision-rebound (cmd_approve deliberately
        # omits it): the re-run restarts fresh and re-plans — a structural split
        # must not inherit the stuck run's iteration counters
        echo
        echo "Next: decide, update .loop/docs/product-contract.md (and loop.config.sh) if needed,"
        echo "then: ./loop.sh approve && ./loop.sh run   (the run restarts and re-plans;"
        echo "progress.md carries the memory forward)"
      else
        # spec/arch/risk/pending: the exact trap this messaging exists to prevent is
        # "approve WITHOUT editing the contract" → the loop keeps the same contract and
        # re-stops. print_next_actions spells out the edit-vs-not fork.
        print_next_actions decision
        if [ "$state" = "RISK_REQUIRES_APPROVAL" ]; then
          echo " NOTE: approving without reverting accepts this change permanently — review the diff first."
        fi
      fi
      exit 3 ;;
    BLOCKED|STALLED)
      # a BLOCKED dead-end may still carry a decision request the human must
      # read (a `human` checklist row awaiting sign-off, 3 failed fix attempts
      # on one error) — show it like the NEEDS_* states do, or the "what should
      # I look at" the loop wrote stays buried in .loop/docs. Gate on a real
      # numbered entry, not the template marker: agents may append entries
      # without stripping the pristine marker.
      if grep -qE '^## DR-[0-9]' .loop/docs/decision-requests.md 2>/dev/null; then
        echo
        echo "── Decision request(s) from this run ──"
        cat .loop/docs/decision-requests.md
      fi
      # BLOCKED → the sign-off / within-contract-steer / contract-change box;
      # STALLED → the futility box (it is not a sign-off gate). A caller may
      # override (e.g. NEXT_ACTION_CTX=api-stall for a rate/usage-limit stall).
      if [ -n "${NEXT_ACTION_CTX:-}" ]; then
        print_next_actions "$NEXT_ACTION_CTX"
      elif [ "$state" = STALLED ]; then
        print_next_actions stalled
      else
        print_next_actions blocked
      fi
      exit 4 ;;
    BUDGET_EXCEEDED)
      print_next_actions "${NEXT_ACTION_CTX:-budget}"
      exit 5 ;;
    *)
      exit 4 ;;
  esac
}

on_contract_int() { # contract definition interrupted (no run exists yet: no
  # checkpoint/state semantics) — the only job is to never orphan the agent subtree
  kill_agent_group "$CHILD_PID"
  exit 130
}

on_interrupt() {
  # State FIRST, then kill: kill_agent_group blocks up to ~2s for the grace, and
  # the checkpoint/pidfile must be durable regardless of how long the subtree
  # takes to die (a relaunch — e.g. the fleet crash-recovery path — may read them
  # while the grace is still running).
  echo INTERRUPTED > .loop/state 2>/dev/null || true
  rm -f .loop/run.pid .loop/run.heartbeat 2>/dev/null || true
  # journal the interrupt (append-only, trap-safe): without this row a killed
  # run is indistinguishable in the journal from one that silently hung. Zero
  # the per-call scratch first — the in-flight call recorded no cost/turns, and
  # inheriting the PREVIOUS call's values would double-count them on this row.
  echo 0 > .loop/last-cost 2>/dev/null || true
  echo 0 > .loop/last-turns 2>/dev/null || true
  journal_append "run" "RUN_INTERRUPTED" "interrupted (SIGINT/SIGTERM) at iteration $(ckpt_int ITERATION 0) — agent subtree killed; resume: ./loop.sh run" 2>/dev/null || true
  kill_agent_group "$CHILD_PID"
  echo
  # the checkpoint (written at the top of every iteration) is left in place so the
  # run continues where it left off, counters and iteration budget intact.
  local at=""
  at=$(ckpt_int ITERATION 0)
  if [ "$at" -gt 0 ] 2>/dev/null; then
    note "interrupted at iteration $at — resume: ./loop.sh run   |   restart: ./loop.sh run --fresh"
  else
    note "interrupted — state saved; resume: ./loop.sh run   |   restart: ./loop.sh run --fresh"
  fi
  exit 130
}

check_harness() { # $1 when — compares against the run's IN-MEMORY baselines, so a
  # forged .loop/approved-harness (agent-writable) cannot defeat this check.
  # RISK_REQUIRES_APPROVAL (exit 3): human decision; watch must not retry this.
  if [ "$(harness_hash)" != "$RUN_HARNESS_HASH" ]; then
    finish RISK_REQUIRES_APPROVAL "harness or session config changed $1 (loop.sh/evaluate.sh/skills/.claude settings/.mcp.json) — possible tampering; review the change, then ./loop.sh approve if intentional"
  fi
  if [ "$(models_hash)" != "$RUN_MODELS_HASH" ]; then
    finish RISK_REQUIRES_APPROVAL "loop.models.sh or fleet.config.sh changed $1 — these files are gitignored (invisible to the diff policy), so a mid-run change can only come from inside the loop; review it, revert if unintended, then re-run"
  fi
  if ! task_start_ref_intact; then
    finish RISK_REQUIRES_APPROVAL "task-start-ref changed or disappeared $1 — the task review baseline is no longer trustworthy; inspect the approval slot and start a new approved task if the change was intentional"
  fi
  if ! observation_manifest_intact; then
    finish RISK_REQUIRES_APPROVAL "observations-manifest changed or disappeared $1 outside the trusted evaluator — evidence freshness can no longer be established; restore it or start a new approved task"
  fi
}

# ---------- review + stop-eval (per-iteration processes) ----------

extract_verdict() { # $1 response text, $2 verdict pattern (e.g. 'VERDICT: (APPROVE|REVISE)')
  # Models reason first and conclude last, and sometimes decorate or fence the
  # verdict line. Scan the WHOLE text (not just line 1): strip leading/trailing
  # whitespace and markdown decorations per line, keep lines matching the
  # verdict pattern, and return the LAST one — a verdict quoted mid-reasoning
  # never beats the final conclusion. Empty output = no parseable verdict.
  # The LEADING strip iterates (BSD-sed-safe label form): nested decorations
  # like '> - `VERDICT: ...' shed one layer per pass — every verdict pattern
  # starts with an uppercase token, so iteration can never eat into the verdict
  # itself. The trailing strip stays single-pass.
  # The pattern must end at a token boundary (whitespace or end of line):
  # every caller's pattern ends in an enum alternation, and a bare prefix
  # grep would accept near-miss tokens ("VERDICT: APPROVED", "STOP-EVAL:
  # METHOD", "REQ-001: METICULOUS") as valid verdicts.
  # shellcheck disable=SC2016  # the backtick in the sed class is a literal markdown character
  printf '%s\n' "$1" \
    | sed -E -e ':a' -e 's/^[[:space:]]*[*_`>#-]+[[:space:]]*//; ta' \
             -e 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]*[*_`]+$//' \
    | grep -E "^$2([[:space:]]|\$)" | tail -1 || true
}

html_lint() { # $1 authored page -> one finding per line (empty output = clean)
  # Advisory presentation checks only — same philosophy as record_html_decision:
  # a scruffy page is a presentation defect, never a gate. Check the RENDERED
  # text: drop <pre>…</pre> blocks and inline <code>…</code> spans first, because
  # raw log and diff excerpts legitimately contain backticks and markdown-looking
  # characters.
  local page="$1" text h1s
  text=$(awk '/<pre[ >]/{skip=1} skip==0{print} /<\/pre>/{skip=0}' "$page" \
    | sed -E 's|<code[^>]*>[^<]*</code>||g')
  # shellcheck disable=SC2016  # literal backtick class: markdown residue, not expansion
  printf '%s' "$text" | grep -q '`'   && echo "markdown backticks in rendered text"
  printf '%s' "$text" | grep -qF '**' && echo "markdown ** emphasis in rendered text"
  printf '%s' "$text" | grep -qF '](' && echo "markdown link syntax in rendered text"
  grep -qi '<html[^>]*lang=' "$page"  || echo "missing <html lang=...>"
  h1s=$({ grep -oi '<h1[ >]' "$page" || true; } | wc -l | tr -d ' ')
  [ "$h1s" -eq 1 ]                    || echo "expected exactly one <h1>, found $h1s"
  grep -qi 'lorem ipsum' "$page"      && echo "placeholder text (lorem ipsum)"
  return 0
}

record_html_decision() { # $1 run_claude label, $2 journal iteration-label — advisory:
  # journal the model's authored/skipped declaration and verify a claimed file exists.
  # Never fails the run: a broken page is a presentation defect, not a contract breach.
  local label="$1" iter="$2" res line file lint
  case "$(html_arg)" in *html=off*) return 0 ;; esac
  res=$(agent_result "$label")
  line=$(extract_verdict "$res" "HTML-DECISION: (authored|skipped)")
  case "$line" in
    "HTML-DECISION: authored"*)
      file=$(printf '%s' "$line" | awk '{print $3}')
      case "$file" in
        .loop/reports/*.html)
          if [ -s "$file" ]; then
            journal_append "$iter" "HTML_AUTHORED" "$file"
            lint=$(html_lint "$file")
            if [ -n "$lint" ]; then
              journal_append "$iter" "HTML_LINT_WARN" "$file — $(printf '%s' "$lint" | tr '\n' ';')"
              note "html: presentation lint warnings for $file (advisory, journaled)"
            fi
          else
            journal_append "$iter" "HTML_MISSING" "declared '$file' but it is missing or empty"
            note "html: declared $file is missing (journaled; the markdown remains canonical)"
          fi ;;
        *) journal_append "$iter" "HTML_MISSING" "declared a path outside .loop/reports/: $file" ;;
      esac ;;
    "HTML-DECISION: skipped"*)
      journal_append "$iter" "HTML_SKIPPED" "${line#HTML-DECISION: skipped }" ;;
    *)
      journal_append "$iter" "HTML_UNDECLARED" "no HTML-DECISION line from '$label'" ;;
  esac
  return 0
}

req_ids_from_contract() { # -> one REQ id per line, sorted unique
  # HEADING lines only (### REQ-001: ...): prose mentions of a REQ id (e.g. a
  # sibling task's REQ inside Non-goals) must not create obligations here.
  # Keep this extraction in sync with evaluate.sh section 6.5.
  grep -E '^#{1,6}[[:space:]]*REQ-[0-9]+' .loop/docs/product-contract.md 2>/dev/null \
    | grep -oE 'REQ-[0-9]+' | sort -u || true
}

bootstrap_requirements_ledger() { # create/repair .loop/docs/requirements-ledger.md (idempotent)
  # Deterministic bootstrap of the loop's requirement-satisfaction memory: one
  # row per contract REQ heading, status `unstarted`. Adds missing rows only —
  # existing rows belong to the agent (its honest status self-report, verified
  # by the reviewer each review and enforced by evaluate.sh at the gate).
  local ledger=.loop/docs/requirements-ledger.md ids rid
  ids=$(req_ids_from_contract)
  [ -n "$ids" ] || return 0   # contract without REQ headings: ledger not applicable
  if [ ! -f "$ledger" ]; then
    {
      echo "# Requirements Ledger"
      echo
      echo "| REQ | Status | Evidence | Iter |"
      echo "|---|---|---|---|"
    } > "$ledger"
  fi
  # rows added below make the file live state — drop the pristine-template
  # marker so a future `init` refresh can never clobber recorded statuses
  if grep -q '<!-- TEMPLATE -->' "$ledger"; then
    sed -i.bak 's/<!-- TEMPLATE -->//' "$ledger" && rm -f "$ledger.bak"
  fi
  while IFS= read -r rid; do
    grep -qE "^\|[[:space:]]*${rid}[[:space:]]*\|" "$ledger" \
      || printf '| %s | unstarted | | |\n' "$rid" >> "$ledger"
  done <<EOF
$ids
EOF
}

check_gate_req_verdicts() { # $1 gate-review reply -> 0 all REQs MET (or no REQs);
  # 1 otherwise, with the offending lines in GATE_REQ_PROBLEMS. Always rewrites
  # .loop/req-verdicts with the parsed per-REQ table (evidence reads it).
  # This is the analytic backstop behind the reviewer's holistic verdict: a
  # single APPROVE can hide an unmet requirement (halo effect); one independent
  # MET-line per REQ cannot.
  GATE_REQ_PROBLEMS=""
  local ids rid line problems=""
  ids=$(req_ids_from_contract)
  : > .loop/req-verdicts
  [ -n "$ids" ] || return 0
  while IFS= read -r rid; do
    line=$(extract_verdict "$1" "$rid: (MET|PARTIAL|UNMET|REGRESSED)")
    if [ -z "$line" ]; then
      echo "$rid: MISSING" >> .loop/req-verdicts
      problems="$problems
- $rid: the reviewer rendered no per-requirement verdict for this REQ — re-judge it explicitly"
      continue
    fi
    echo "$line" >> .loop/req-verdicts
    case "$line" in
      "$rid: MET"*) ;;
      *) problems="$problems
- $line" ;;
    esac
  done <<EOF
$ids
EOF
  [ -z "$problems" ] && return 0
  GATE_REQ_PROBLEMS="$problems"
  return 1
}

iter_diff_lines() { # $1 base ref -> changed lines (adds+dels) vs HEAD, excluding harness bookkeeping
  git diff --numstat "$1" HEAD -- . ':(exclude).loop' ':(exclude).claude' 2>/dev/null \
    | awk '{ if ($1 != "-") s += $1; if ($2 != "-") s += $2 } END { print s+0 }'
}

append_review_escalation_dr() { # $1 iter, $2 mode, $3 question, $4 review log path
  # A gate reviewer's VERDICT: ESCALATE means a human must decide (e.g. an
  # assumption whose soundness the contract cannot adjudicate). Record it as a
  # decision request — finish() prints this file on NEEDS_SPEC_DECISION.
  {
    echo
    echo "## DR-GATE-$1: escalated by the independent gate reviewer — $(date -u '+%Y-%m-%d' 2>/dev/null || echo n/a)"
    echo "- Why a decision is needed: the $2 reviewer judged this beyond what the contract can answer"
    echo "- Concrete question for the human: $3"
    echo "- Full review: $4"
  } >> .loop/docs/decision-requests.md
}

run_review() { # $1 iter, $2 diff-base-ref, $3 mode (interim|gate), $4 scope (iter|run),
  # $5 extra prompt token(s), appended verbatim (e.g. the fleet gate's
  # ` manual-tasks=<path>` manifest pointer) -> sets REVIEW_VERDICT + writes/clears feedback
  REVIEW_VERDICT="SKIPPED"
  REVIEW_SCOPE=""
  local mode="${3:-interim}" scope="${4:-iter}" extra="${5:-}" res="" verdict="" base_prompt prompt label vpat vhint
  # harness bookkeeping (.loop/docs, .claude) is excluded: the reviewer judges the
  # project change only, and must never penalize the loop's own progress notes
  git diff "$2" HEAD -- . ':(exclude).loop' ':(exclude).claude' > .loop/review-diff.patch 2>/dev/null \
    || : > .loop/review-diff.patch
  if [ ! -s .loop/review-diff.patch ]; then
    if [ "$mode" != "gate" ]; then return 0; fi
    # An empty task diff is not evidence that the approved contract is met.
    # Gate mode therefore reviews the current implementation state, checklist,
    # observations and verify log instead of silently treating SKIPPED as pass.
    scope="state"
  fi
  if [ "$mode" = "gate" ]; then REVIEW_SCOPE="diff"; fi
  [ "$scope" != "state" ] || REVIEW_SCOPE="state"
  # per-mode model: interim reviews may run on a cheaper (and different-family)
  # tier — cost tiering that also spreads the maker-checker blind spot
  local rmodel="$MODEL_REVIEW"
  if [ "$mode" = "interim" ] && [ -n "${MODEL_REVIEW_INTERIM:-}" ]; then rmodel="$MODEL_REVIEW_INTERIM"; fi
  base_prompt="/loop-review base=$2 mode=$mode"
  # scope=run widens an interim review to the whole run diff (erosion/coherence
  # audit); the skill changes what it judges accordingly
  case "$scope" in
    run)   base_prompt="$base_prompt scope=run" ;;
    state) base_prompt="$base_prompt scope=state" ;;
  esac
  [ -z "$extra" ] || base_prompt="$base_prompt$extra"
  prompt="$base_prompt"
  # the gate may also ESCALATE (a human-only question surfaced at the gate);
  # mid-loop reviews stay two-valued — an interim escalation would only stall
  # the loop on questions the gate re-asks anyway
  vpat="VERDICT: (APPROVE|REVISE)"
  vhint="'VERDICT: APPROVE <summary>' or 'VERDICT: REVISE <summary>'"
  if [ "$mode" = "gate" ]; then
    vpat="VERDICT: (APPROVE|REVISE|ESCALATE)"
    vhint="'VERDICT: APPROVE <summary>', 'VERDICT: REVISE <summary>' or 'VERDICT: ESCALATE <question>'"
  fi
  # separate log per mode: a forced gate runs in the same iteration as an
  # interim review, and must not overwrite its audit log
  label="iter-$1-review"
  if [ "$mode" = "gate" ]; then label="iter-$1-review-gate"; fi
  for _ in 1 2; do   # up to twice: retry on launch failure OR unparseable verdict
    run_claude "$label" "$prompt" "$rmodel" reader REVIEW || continue
    res=$(agent_result "$label")
    verdict=$(extract_verdict "$res" "$vpat")
    [ -z "$verdict" ] || break
    prompt="$base_prompt (FORMAT REMINDER: the LAST line of your reply must be exactly $vhint — plain text, no code fence. Your previous attempt contained no parseable verdict.)"
  done
  if [ -z "$res" ]; then
    REVIEW_VERDICT="ERROR"
    journal_append "$1" "REVIEW_ERROR" "reviewer call failed twice${AGENT_FAIL_DIAG:+ — last error: $AGENT_FAIL_DIAG}"
    return 0
  fi
  if [ -z "$verdict" ]; then
    # fail safe for the gate, but say so honestly everywhere it is recorded
    REVIEW_VERDICT="REVISE"
    verdict="VERDICT: REVISE (unparseable reviewer output after a format-reminder retry — treated as revise)"
    res="$verdict
$res"
    note "review ($mode) -> REVISE (unparseable verdict)"
  else
    case "$verdict" in
      "VERDICT: APPROVE"*)  REVIEW_VERDICT="APPROVE" ;;
      "VERDICT: ESCALATE"*) REVIEW_VERDICT="ESCALATE" ;;
      *)                    REVIEW_VERDICT="REVISE" ;;
    esac
    note "review ($mode) -> $REVIEW_VERDICT"
  fi
  if [ "$mode" = "gate" ] && [ "$REVIEW_VERDICT" != "ESCALATE" ]; then
    # analytic backstop (fail closed): parse the reviewer's per-REQ verdict
    # lines into .loop/req-verdicts regardless of the holistic verdict, and
    # never let an APPROVE stand while any REQ verdict is missing or non-MET
    if ! check_gate_req_verdicts "$res" && [ "$REVIEW_VERDICT" = "APPROVE" ]; then
      REVIEW_VERDICT="REVISE"
      verdict="VERDICT: REVISE (harness downgrade: gate APPROVE without a clean per-requirement verdict table)"
      res="$verdict
Must-fix — the analytic per-REQ check found:$GATE_REQ_PROBLEMS

--- original reviewer reply below ---
$res"
      note "review (gate) -> REVISE (downgraded: per-REQ verdicts incomplete or non-MET)"
    fi
  fi
  if [ "$REVIEW_VERDICT" = "ESCALATE" ]; then
    local question="${verdict#VERDICT: ESCALATE}"
    question="${question# }"
    append_review_escalation_dr "$1" "$mode" "${question:-see the full review}" "$(agent_log_path "$label" json)"
  elif [ "$REVIEW_VERDICT" = "REVISE" ]; then
    {
      echo "# Reviewer feedback (iteration $1, $mode review) — address the must-fix items FIRST next iteration"
      echo
      printf '%s\n' "$res"
    } > .loop/review-feedback.md
  else
    rm -f .loop/review-feedback.md
  fi
  journal_append "$1" "REVIEW_$REVIEW_VERDICT" "[$mode] $verdict"
  return 0
}

run_stop_eval() { # $1 iter, $2 pre-ref -> updates futility + MET counters; may finish STALLED.
  # Maintains STOP_EVAL_MET_STREAK / STOP_EVAL_FUTILE_STREAK (in-memory, the
  # authoritative streaks — see their declarations) plus their display-mirror
  # files, and .loop/stop-nudge.md, which the next /loop-iterate reads.
  [ "$STOP_EVAL" = "true" ] || return 0
  local res line sv pre_ref="${2:-HEAD}" preflight_line preflight_state
  if ! run_claude "iter-$1-stopeval" "/loop-stop-eval" "$MODEL_STOP_EVAL" reader STOP_EVAL; then
    STOP_EVAL_MET_STREAK=0
    echo 0 > .loop/met-count
    rm -f .loop/stop-nudge.md
    journal_append "$1" "STOP_EVAL_ERROR" "stop evaluator call failed (advisory — ignored)${AGENT_FAIL_DIAG:+ — $AGENT_FAIL_DIAG}"
    return 0
  fi
  res=$(agent_result "iter-$1-stopeval")
  line=$(extract_verdict "$res" "STOP-EVAL: (MET|FUTILE|CONTINUE)")
  case "$line" in
    "STOP-EVAL: MET"*)    sv="MET" ;;
    "STOP-EVAL: FUTILE"*) sv="FUTILE" ;;
    *)                    sv="CONTINUE"
                          [ -n "$line" ] || line="(no parseable STOP-EVAL line) $(printf '%s\n' "$res" | head -1)" ;;
  esac
  journal_append "$1" "STOP_EVAL_$sv" "$line"
  if [ "$sv" = "FUTILE" ]; then
    STOP_EVAL_FUTILE_STREAK=$((STOP_EVAL_FUTILE_STREAK + 1))
    echo "$STOP_EVAL_FUTILE_STREAK" > .loop/futile-count   # display mirror
    if [ "$STOP_EVAL_FUTILE_STREAK" -ge "$FUTILE_N" ]; then
      finish STALLED "stop evaluator judged the loop futile $STOP_EVAL_FUTILE_STREAK times in a row: ${line#STOP-EVAL: FUTILE}"
    fi
  else
    STOP_EVAL_FUTILE_STREAK=0
    echo 0 > .loop/futile-count
  fi
  if [ "$sv" = "MET" ]; then
    # MET is advisory. Count it only after the model-free evaluator proves the
    # just-finished iteration still has a green verify log and closed ledger,
    # checklist and observation obligations. A failed preflight breaks the
    # streak: the streak means consecutive *deterministically eligible* METs.
    # Pin discipline: the manifest must be UNCHANGED going in (the stop-eval
    # reader call sits between the last check and here), because the re-pin
    # after the trusted preflight stamper below would otherwise adopt — and
    # so launder — a manifest replaced outside the evaluator.
    observation_manifest_intact \
      || finish RISK_REQUIRES_APPROVAL "observations-manifest changed before the stop-eval preflight — outside the trusted evaluator; review the change, restore the manifest, or start a new approved task"
    if ! preflight_line=$("$evaluator" --pre-ref "$pre_ref" --preflight \
          --approved-hash "$RUN_CONTRACT_HASH"); then
      preflight_line="CONTINUE deterministic preflight crashed"
    fi
    pin_observation_manifest \
      || finish BLOCKED "deterministic preflight left an unreadable or invalid observations manifest"
    preflight_state=${preflight_line%% *}
    if [ "$preflight_state" != "SUCCESS_CANDIDATE" ]; then
      STOP_EVAL_MET_STREAK=0
      echo 0 > .loop/met-count
      rm -f .loop/stop-nudge.md
      journal_append "$1" "FORCED_GATE_REFUSED" "MET but deterministic preflight failed: ${preflight_line#* }"
      note "forced gate refused: deterministic preflight failed (${preflight_line#* })"
      return 0
    fi
    STOP_EVAL_MET_STREAK=$((STOP_EVAL_MET_STREAK + 1))
    echo "$STOP_EVAL_MET_STREAK" > .loop/met-count   # display mirror
    cat > .loop/stop-nudge.md <<'EOF'
# Stop evaluator: acceptance criteria appear MET

The advisory stop evaluator judged that the contract's acceptance criteria look
satisfied already. If ALL plan milestones are truly complete, verification
passes, and no reviewer must-fix items remain: do NOT start new work — declare
`READY_FOR_REVIEW` in .loop/agent-state. If real work remains, ignore this note.
EOF
  else
    STOP_EVAL_MET_STREAK=0
    echo 0 > .loop/met-count
    rm -f .loop/stop-nudge.md
  fi
}

unmet_ledger_reqs() { # -> space-prefixed list of contract REQ ids (headings) that
  # do NOT have exactly one ledger row with status exactly `met`; empty when all
  # met (or no REQ headings). Mirror of evaluate.sh's 6.5 rule — keep the awk in
  # sync: duplicate rows for one REQ (e.g. met + regressed) are a contradiction
  # and count as unmet, matching the evaluator's strict parse.
  local rid req_ids out="" ledger_rows row
  req_ids=$(req_ids_from_contract)
  [ -n "$req_ids" ] || { printf ''; return 0; }
  ledger_rows=$(awk -F'|' '
    /^\|[[:space:]]*REQ-[0-9]+[[:space:]]*\|/ {
      id=$2; st=$3
      gsub(/^[ \t]+/,"",id); gsub(/[ \t]+$/,"",id)
      gsub(/^[ \t]+/,"",st); gsub(/[ \t]+$/,"",st)
      n[id]++; s[id]=st
    }
    END { for (id in n) if (n[id] == 1 && s[id] == "met") print id }
  ' .loop/docs/requirements-ledger.md 2>/dev/null || true)
  while IFS= read -r rid; do
    printf '%s\n' "$ledger_rows" | grep -qx "$rid" || out="$out $rid"
  done <<EOF
$req_ids
EOF
  printf '%s' "$out"
}

checklist_all_verified() { # -> 0 when the acceptance checklist has no AC row with
  # status != verified. Mirror of evaluate.sh's 6.6 rule, same semantics:
  # absent file or no AC rows = checklist not in use = clean.
  [ -f .loop/docs/acceptance-checklist.md ] || return 0
  local unv
  unv=$(awk -F'|' '
    /^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
      st=$6
      gsub(/^[ \t]+/,"",st); gsub(/[ \t]+$/,"",st)
      if (st != "verified") { print "x"; exit }
    }' .loop/docs/acceptance-checklist.md 2>/dev/null || true)
  [ -z "$unv" ]
}

write_split_nudge() { # $1 iteration — fleet workers only. Deterministic budget
  # signal: past SPLIT_NUDGE_AT% of MAX_ITERATIONS with unmet ledger REQs, nudge
  # the next /loop-iterate to either declare NEEDS_DECOMPOSITION at a clean
  # commit boundary or justify continuing. Advisory only — the declaration is
  # the sole stop path; the stop-nudge (wrap-up) always wins over this one.
  local i="$1" thr unmet=""
  if [ ! -f .loop/fleet-worker ] || [ "${SPLIT_NUDGE_AT:-0}" -le 0 ] || [ -f .loop/stop-nudge.md ]; then
    rm -f .loop/split-nudge.md
    return 0
  fi
  thr=$((MAX_ITERATIONS * SPLIT_NUDGE_AT / 100))
  [ "$thr" -ge 1 ] || thr=1
  if [ "$i" -lt "$thr" ]; then
    rm -f .loop/split-nudge.md
    return 0
  fi
  unmet=$(unmet_ledger_reqs)
  if [ -z "$unmet" ]; then
    rm -f .loop/split-nudge.md
    return 0
  fi
  cat > .loop/split-nudge.md <<EOF
# Budget signal: iteration $i of $MAX_ITERATIONS with unmet requirements

Still not met:${unmet}. If the remaining work does not clearly fit in the
iterations left, do NOT push on: bring the tree to a clean, committed boundary,
write a decision request stating exactly what is DONE (with evidence) and what
REMAINS (as a proposed sequence of phases), and declare NEEDS_DECOMPOSITION in
.loop/agent-state — the supervisor can split the remainder into phased tasks.
If the remaining work clearly fits, justify continuing in progress.md and
ignore this note.
EOF
  return 0
}

beat_sleep() { # $1 seconds — sleep in <=20s chunks, refreshing the liveness
  # heartbeats each chunk so a long backoff never lets a freshness window (60s)
  # go stale mid-wait: liveness must not degrade while a loop is deliberately
  # idle. Both beats are self-guarded owner-only refreshers: run_beat no-ops
  # outside a worker/root loop, beat no-ops unless THIS process holds the fleet
  # supervisor lock — so calling both covers the single-loop gate AND the fleet
  # integration gate without ever forging someone else's heartbeat.
  local left="$1" step
  case "$left" in ''|*[!0-9]*) return 0 ;; esac
  while [ "$left" -gt 0 ]; do
    step="$left"
    [ "$step" -le 20 ] || step=20
    sleep "$step"
    run_beat
    beat
    left=$((left - step))
  done
}

gate_review_retry() { # "$@" = run_review argv for a GATE call ($1 = iter label).
  # Bounded, journaled retry on reviewer UNAVAILABILITY only (REVIEW_VERDICT=
  # ERROR — the call itself failed twice inside run_review): a transient outage
  # at the gate should not hard-BLOCK an otherwise green run. Any parsed verdict
  # (APPROVE/REVISE/ESCALATE) returns immediately. Fail-closed exhaustion: after
  # the last retry the caller's ERROR branch runs unchanged — certification
  # still never happens without an explicit APPROVE + clean per-REQ table.
  local k=0 wait
  run_review "$@"
  [ "$REVIEW_VERDICT" = "ERROR" ] || return 0
  while [ "$k" -lt "${GATE_RETRY_N:-0}" ]; do
    case "$AGENT_FAIL_DIAG" in
      *"watchdog kill"*)
        # deterministic per-call timeout (the run diff is too big for
        # MAX_ITER_SECONDS) — backoff cannot shrink it; retrying would burn
        # N more doomed reviewer calls. Fail closed now with the real cause.
        note "gate reviewer hit the per-call watchdog — not retrying (raise MAX_ITER_SECONDS / TIMEOUT_REVIEW or shrink the diff)"
        return 0 ;;
    esac
    k=$((k + 1))
    wait=$(printf '%s\n' "$GATE_RETRY_WAITS" | awk -v k="$k" '{ print (k <= NF) ? $k : $NF }')
    journal_append "$1" "GATE_RETRY" "reviewer unavailable at the gate — retry $k/$GATE_RETRY_N after ${wait}s"
    note "gate reviewer unavailable — retry $k/$GATE_RETRY_N in ${wait}s"
    beat_sleep "$wait"
    run_review "$@"
    [ "$REVIEW_VERDICT" = "ERROR" ] || return 0
  done
  return 0
}

write_turns_nudge() { # $1 iteration — advisory runaway-context signal. When the
  # implement call that just finished consumed >= TURNS_NUDGE_AT agent turns
  # (loop.models.sh; empty/non-numeric = off), nudge the NEXT /loop-iterate to
  # re-plan into a smaller step instead of resuming mid-flight — long-tail
  # iterations are where cache-read cost explodes. Advisory only; the stop-nudge
  # (wrap-up) always wins, exactly like the split-nudge.
  local i="$1" thr turns
  thr=$(get_model TURNS_NUDGE_AT "")
  case "$thr" in ''|*[!0-9]*) rm -f .loop/context-nudge.md; return 0 ;; esac
  if [ "$thr" -le 0 ] || [ -f .loop/stop-nudge.md ]; then
    rm -f .loop/context-nudge.md
    return 0
  fi
  turns=$(cat .loop/last-turns 2>/dev/null || echo 0)
  case "$turns" in ''|*[!0-9]*) turns=0 ;; esac
  if [ "$turns" -lt "$thr" ]; then
    rm -f .loop/context-nudge.md
    return 0
  fi
  cat > .loop/context-nudge.md <<EOF
# Context signal: the last implement call used $turns agent turns (threshold $thr)

The working set is growing past what one iteration handles well. Next
iteration, do NOT resume mid-flight work by re-reading everything: re-read the
plan, pick the SMALLEST committable next step, and rely on progress.md
summaries instead of re-reading large files already summarized there. If the
current milestone is genuinely indivisible, justify continuing in progress.md
and ignore this note.
EOF
  journal_append "$i" "CONTEXT_NUDGE" "implement call used $turns turns (>= $thr) — advisory re-plan/split nudge written"
  return 0
}

sha_file_or_empty() { # deterministic content hash even when an optional file is absent
  if [ -f "$1" ]; then sha256 < "$1"; else printf '' | sha256; fi
}

observation_tokens() { # stdin -> supported observation path tokens
  # Path-boundary anchored (start of line, whitespace, '(', '[' or a markdown
  # backtick): '/tmp/.loop/observations/x' or '../.loop/observations/x' must
  # NOT normalize to the canonical token — a report could then display one
  # path while validation binds a different file. Keep this boundary set in
  # sync with evaluate.sh's 6.6(e) evidence-cell parser.
  grep -oE '(^|[[:space:]([`])\.loop/observations/[A-Za-z0-9_./-]*[A-Za-z0-9_-]' 2>/dev/null \
    | sed -E 's/^[[:space:]([`]//' \
    | LC_ALL=C sort -u || true
}

checklist_observation_paths() { # verified run-row artifact paths only
  [ -f .loop/docs/acceptance-checklist.md ] || return 0
  awk -F'|' '
    /^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
      m=$5; st=$6; ev=$7
      gsub(/^[ \t]+|[ \t]+$/, "", m)
      gsub(/^[ \t]+|[ \t]+$/, "", st)
      gsub(/^[ \t]+|[ \t]+$/, "", ev)
      if (m == "run" && st == "verified") print ev
    }
  ' .loop/docs/acceptance-checklist.md 2>/dev/null | observation_tokens
}

supported_observation_path() { # strict lexical + filesystem check; no symlink traversal
  local path="${1:-}" rest oldifs part cur
  case "$path" in .loop/observations/?*) ;; *) return 1 ;; esac
  case "$path" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  rest=${path#.loop/observations/}
  case "/$rest/" in *//*|*/./*|*/../*) return 1 ;; esac
  [ ! -L .loop ] && [ ! -L .loop/observations ] || return 1
  cur=.loop/observations
  oldifs=$IFS; IFS=/; set -f
  # shellcheck disable=SC2086 # slash splitting is the intended component walk
  set -- $rest
  set +f; IFS=$oldifs
  for part in "$@"; do
    [ -n "$part" ] && [ "$part" != "." ] && [ "$part" != ".." ] || return 1
    cur="$cur/$part"
    [ ! -L "$cur" ] || return 1
  done
  [ "$cur" = "$path" ] && [ -f "$path" ] && [ -r "$path" ] && [ -s "$path" ]
}

manifest_artifact_sha() { # $1 path -> last exact path row's artifact sha
  local row
  [ -f .loop/observations-manifest.jsonl ] || return 0
  row=$(awk -v path="$1" '
    index($0, "\"artifact_path\":\"" path "\"") { row=$0 }
    END { if (row != "") print row }
  ' .loop/observations-manifest.jsonl 2>/dev/null || true)
  printf '%s\n' "$row" | sed -nE 's/.*"artifact_sha256":"([^"]*)".*/\1/p'
}

authority_file_record() { # $1 path -> type + content/link hash material
  local f="$1" digest target
  if [ -L "$f" ]; then
    target=$(readlink "$f" 2>/dev/null) || return 1
    printf 'symlink\t%s\n' "$target"
  elif [ -f "$f" ]; then
    digest=$(sha256 < "$f") || return 1
    [ -n "$digest" ] || return 1
    printf 'file\t%s\n' "$digest"
  elif [ -e "$f" ]; then
    printf 'other\n'
  else
    printf 'missing\n'
  fi
}

certification_inputs_hash() { # authority fixed before evidence; report/log are outputs
  local f path
  {
    for f in \
      .loop/docs/product-contract.md loop.config.sh \
      .loop/docs/requirements-ledger.md .loop/docs/acceptance-checklist.md \
      .loop/req-verdicts .loop/ac-seen .loop/agent-state \
      .loop/observations-manifest.jsonl; do
      printf '%s\t' "$f"
      authority_file_record "$f" || return 1
    done
    checklist_observation_paths | while IFS= read -r path; do
      [ -n "$path" ] || continue
      printf '%s\t' "$path"
      authority_file_record "$path" || return 1
    done
  } | sha256
}

validate_current_evidence_report() { # binds every report artifact to checklist+manifest
  local report=.loop/docs/evidence-report.md bytes checklist_paths report_paths path expected actual
  EVIDENCE_REPORT_REASON=""
  [ ! -L "$report" ] && [ -f "$report" ] && [ -r "$report" ] && [ -s "$report" ] \
    || { EVIDENCE_REPORT_REASON="evidence report missing, empty, unreadable, or a symlink"; return 1; }
  grep -q '<!-- TEMPLATE -->' "$report" 2>/dev/null \
    && { EVIDENCE_REPORT_REASON="evidence report is still the template"; return 1; }
  bytes=$(wc -c < "$report" 2>/dev/null | tr -d '[:space:]') \
    || { EVIDENCE_REPORT_REASON="cannot measure evidence report"; return 1; }
  case "$bytes" in ''|*[!0-9]*) EVIDENCE_REPORT_REASON="invalid evidence report size"; return 1 ;; esac
  [ "$bytes" -le 5242880 ] \
    || { EVIDENCE_REPORT_REASON="evidence report exceeds 5MB"; return 1; }

  checklist_paths=$(checklist_observation_paths)
  report_paths=$(observation_tokens < "$report")
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\n' "$report_paths" | grep -Fqx "$path" \
      || { EVIDENCE_REPORT_REASON="report omits checklist observation: $path"; return 1; }
  done <<EOF
$checklist_paths
EOF
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\n' "$checklist_paths" | grep -Fqx "$path" \
      || { EVIDENCE_REPORT_REASON="report cites an observation outside the verified checklist: $path"; return 1; }
    supported_observation_path "$path" \
      || { EVIDENCE_REPORT_REASON="report observation is unsafe, missing, empty, or unreadable: $path"; return 1; }
    expected=$(manifest_artifact_sha "$path")
    actual=$(sha256 < "$path") \
      || { EVIDENCE_REPORT_REASON="cannot hash report observation: $path"; return 1; }
    [ -n "$expected" ] && [ "$expected" = "$actual" ] \
      || { EVIDENCE_REPORT_REASON="report observation does not match the evaluator manifest: $path"; return 1; }
  done <<EOF
$report_paths
EOF
  return 0
}

post_review_product_changes() { # $1 reviewed commit -> tracked + untracked product paths
  {
    git diff --name-only "$1" -- . ':(exclude).loop' ':(exclude).claude' 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null \
      | grep -Ev '^(\.loop|\.claude)(/|$)' || true
  } | LC_ALL=C sort -u
}

canonicalize_live_manifest() {
  if [ -s .loop/observations-manifest.jsonl ]; then
    compact_observations_manifest .loop/observations-manifest.jsonl .loop/observations-manifest.jsonl \
      || return 1
  fi
  pin_observation_manifest
}

write_certification() { # $1 state $2 task base $3 run base $4 reviewed HEAD $5 preflight status
  local final_state="$1" task_base="$2" run_base="$3" reviewed_head="$4" preflight_status="$5"
  local review_verdict="${REVIEW_VERDICT:-}" review_scope="${REVIEW_SCOPE:-}" finished tmp
  local req_sha verify_sha manifest_sha
  if [ "$REVIEW_MODE" = "off" ] && [ -z "$review_verdict" ]; then
    review_verdict="OFF"; review_scope="off"
  fi
  [ -n "$review_scope" ] || review_scope="diff"
  canonicalize_live_manifest || return 1
  req_sha=$(sha_file_or_empty .loop/req-verdicts)
  verify_sha=$(sha_file_or_empty .loop/last-verify.log)
  manifest_sha=$(sha_file_or_empty .loop/observations-manifest.jsonl)
  finished=$(utcnow)
  mkdir -p .loop/docs
  tmp=".loop/docs/.certification.tmp.$$"
  printf '{"task_id":"%s","run_id":"%s","contract_hash":"%s","harness_hash":"%s","task_start_ref":"%s","run_start_ref":"%s","reviewed_head":"%s","preflight":"%s","review_verdict":"%s","review_scope":"%s","requirements_verdict_sha256":"%s","verify_log_sha256":"%s","evidence_manifest_sha256":"%s","final_state":"%s","finished_at":"%s"}\n' \
    "$(printf '%s' "$TASK_ID" | json_escape)" \
    "$(printf '%s' "$RUN_ID" | json_escape)" \
    "$RUN_CONTRACT_HASH" "$RUN_HARNESS_HASH" \
    "$(printf '%s' "$task_base" | json_escape)" \
    "$(printf '%s' "$run_base" | json_escape)" \
    "$(printf '%s' "$reviewed_head" | json_escape)" \
    "$(printf '%s' "$preflight_status" | json_escape)" \
    "$(printf '%s' "$review_verdict" | json_escape)" \
    "$(printf '%s' "$review_scope" | json_escape)" \
    "$req_sha" "$verify_sha" "$manifest_sha" "$final_state" "$finished" > "$tmp"
  mv -f "$tmp" .loop/docs/certification.json
  if [ -f .loop/docs/evidence-report.md ]; then
    {
      echo
      echo "## certification.json"
      echo
      echo "- task_id: $TASK_ID"
      echo "- run_id: $RUN_ID"
      echo "- final_state: $final_state"
      echo "- review_verdict: $review_verdict ($review_scope)"
      echo "- reviewed_head: $reviewed_head"
      echo "- machine record: .loop/docs/certification.json"
    } >> .loop/docs/evidence-report.md
  fi
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add -- .loop/docs/certification.json .loop/docs/evidence-report.md 2>/dev/null || return 1
    git diff --cached --quiet -- .loop/docs/certification.json .loop/docs/evidence-report.md 2>/dev/null \
      || git -c core.hooksPath=/dev/null commit -q -m "loop: certify $final_state" -- .loop/docs/certification.json .loop/docs/evidence-report.md \
      || return 1
  fi
  return 0
}

run_success_gate() { # $1 iter, $2 run-start-ref, $3 pre-ref, $4 forced (0|1)
  # The success gate: gate review of the FULL run diff -> evidence -> final
  # deterministic re-check. Exits via finish() on SUCCESS/NO_OP/BLOCKED.
  # ALWAYS returns 0 when the reviewer sent the loop back to work, so callers
  # can invoke it bare — an `|| true` call would suppress set -e inside.
  # forced=1 means the stop evaluator (not the agent) triggered this gate:
  # a rejection then must NOT count toward MAX_REVISIONS — that budget is for
  # candidates the agent itself claimed ready.
  local i="$1" base="$2" pre="$3" forced="$4"
  local reviewed_ref evidence_diff final_line final_state preflight_line preflight_state evidence_logs
  local task_base="$base" task_base_valid=0 authority_before authority_after

  # Every success path, not only forced MET, carries a fresh deterministic
  # preflight result into certification. This catches a task-tree/observation
  # change made between candidate evaluation and the gate without paying for a
  # reviewer first.
  # Same pin discipline as run_stop_eval: an unchanged manifest is a
  # precondition for entering the trusted preflight stamper — the re-pin
  # below must only ever adopt the stamper's own writes.
  observation_manifest_intact \
    || finish RISK_REQUIRES_APPROVAL "observations-manifest changed before the success-gate preflight — outside the trusted evaluator; review the change, restore the manifest, or start a new approved task"
  if ! preflight_line=$("$evaluator" --pre-ref "$pre" --preflight \
        --approved-hash "$RUN_CONTRACT_HASH"); then
    preflight_line="CONTINUE deterministic preflight crashed"
  fi
  pin_observation_manifest \
    || finish BLOCKED "success-gate preflight left an unreadable or invalid observations manifest"
  preflight_state=${preflight_line%% *}
  if [ "$preflight_state" != "SUCCESS_CANDIDATE" ]; then
    STOP_EVAL_MET_STREAK=0
    echo 0 > .loop/met-count
    rm -f .loop/stop-nudge.md
    journal_append "$i" "GATE_PREFLIGHT_REFUSED" "${preflight_line#* }"
    note "success gate preflight refused — continuing (${preflight_line#* })"
    return 0
  fi

  # A run baseline is reset by --fresh; the task baseline is not. Use ONLY the
  # canonical full object id pinned in memory before any agent call. Re-reading a
  # symbolic ref here (notably HEAD) would make the baseline move and shrink the
  # reviewed diff. check_harness separately detects replacement/deletion of the
  # backing file during this process.
  if [ -n "$TASK_START_REF" ] \
     && git merge-base --is-ancestor "$TASK_START_REF" HEAD >/dev/null 2>&1; then
    task_base="$TASK_START_REF"
    task_base_valid=1
  else
    journal_append "$i" "TASK_BASE_FALLBACK" "task-start-ref missing or invalid; reviewing from run baseline $base; NO_OP disabled"
    note "warning: task-start-ref missing or invalid — reviewing from the run baseline; NO_OP is disabled"
  fi

  # 3a. REVIEW GATE: independent reviewer examines the FULL task diff, or the
  # current implementation state when the task diff is empty.
  if [ "$REVIEW_MODE" != "off" ]; then
    gate_review_retry "$i" "$task_base" gate
    if [ "$REVIEW_VERDICT" = "ERROR" ]; then
      finish BLOCKED "reviewer unavailable at success gate — cannot certify success${AGENT_FAIL_DIAG:+ (last error: $AGENT_FAIL_DIAG)}"
    fi
    if [ "$REVIEW_VERDICT" = "ESCALATE" ]; then
      # the gate reviewer hit a question only a human can answer (e.g. an
      # assumption the contract cannot adjudicate). Not a revision — sending
      # it back to the implementer would burn budget on an unanswerable item.
      finish NEEDS_SPEC_DECISION "gate reviewer escalated to the human — see .loop/docs/decision-requests.md"
    fi
    if [ "$REVIEW_VERDICT" = "REVISE" ]; then
      # reset the MET streak AND drop the wrap-up nudge on EVERY gate REVISE
      # (forced or agent-declared): the reviewer just said work remains, so a
      # leftover streak would re-force the gate on the next MET and a stale
      # "declare READY" note would hand the next iteration two contradictory
      # instructions
      STOP_EVAL_MET_STREAK=0
      echo 0 > .loop/met-count
      rm -f .loop/stop-nudge.md
      if [ "$forced" -eq 1 ]; then
        note "forced gate: reviewer requested revisions — continuing (not counted toward MAX_REVISIONS)"
        return 0
      fi
      gate_revise_count=$((gate_revise_count + 1))
      if [ "$gate_revise_count" -ge "$MAX_REVISIONS" ]; then
        finish BLOCKED "reviewer rejected $gate_revise_count consecutive success candidates — needs human review (.loop/review-feedback.md)"
      fi
      note "reviewer requested revisions — continuing (feedback in .loop/review-feedback.md)"
      return 0
    fi
    gate_revise_count=0
    if [ "$REVIEW_VERDICT" != "APPROVE" ]; then
      finish BLOCKED "success gate requires an explicit reviewer APPROVE (got: ${REVIEW_VERDICT:-none})"
    fi
  fi
  # 3b. EVIDENCE + FINAL RE-CHECK. The evidence agent runs AFTER the
  # reviewer, so freeze every certification input first. The report is an output
  # view and is deliberately excluded; it is deleted before the call so a stale
  # prior report can never satisfy the current generation requirement.
  check_harness "during the success-gate review"
  canonicalize_live_manifest \
    || finish BLOCKED "could not canonicalize the observation manifest before evidence generation"
  authority_before=$(certification_inputs_hash) \
    || finish BLOCKED "could not snapshot certification inputs before evidence generation"
  reviewed_ref=$(git rev-parse HEAD)
  evidence_logs=$(active_log_dir)
  rm -f .loop/docs/evidence-report.md
  note "generating evidence report (/loop-evidence, $MODEL_EVIDENCE)"
  if ! run_claude "iter-$i-evidence" "/loop-evidence baseline=$task_base logs=$evidence_logs task=$TASK_ID$(html_arg)" "$MODEL_EVIDENCE" full EVIDENCE; then
    finish BLOCKED "evidence generation failed — cannot certify success without evidence${AGENT_FAIL_DIAG:+ ($AGENT_FAIL_DIAG)}"
  fi
  check_harness "during evidence generation"
  authority_after=$(certification_inputs_hash) \
    || finish BLOCKED "could not re-check certification inputs after evidence generation"
  if [ "$authority_after" != "$authority_before" ]; then
    finish BLOCKED "evidence step changed certification inputs after review (contract/ledger/checklist/verdicts/manifest/observations)"
  fi
  if ! validate_current_evidence_report; then
    finish BLOCKED "current evidence report is invalid: $EVIDENCE_REPORT_REASON"
  fi
  # Require the post-review product diff (tracked + untracked, excluding loop
  # memory) to be empty BEFORE committing the report.
  evidence_diff=$(post_review_product_changes "$reviewed_ref")
  if [ -n "$evidence_diff" ]; then
    finish BLOCKED "evidence step changed code after review (unreviewed): $(echo "$evidence_diff" | tr '\n' ' ')"
  fi
  commit_if_changes "loop: iter $i — evidence report"
  # the evidence call's cost was previously invisible (finish() zeroes last-cost
  # before the final journal row) — give the role its own cost-bearing row
  journal_append "$i" "EVIDENCE" "evidence report generated ($MODEL_EVIDENCE)"
  record_html_decision "iter-$i-evidence" "$i"
  if [ "$forced" -eq 1 ]; then
    final_line=$("$evaluator" --pre-ref "$pre" --final --assume-ready --approved-hash "$RUN_CONTRACT_HASH") \
      || final_line="BLOCKED final evaluation crashed"
  else
    final_line=$("$evaluator" --pre-ref "$pre" --final --approved-hash "$RUN_CONTRACT_HASH") \
      || final_line="BLOCKED final evaluation crashed"
  fi
  final_state=${final_line%% *}
  if [ -f .loop/verify-flake.log ]; then
    journal_append "final" "VERIFY_FLAKE" "final re-check failed then passed on a full rerun — suspected environment flake: $(grep -m1 '^\[FAIL\]' .loop/verify-flake.log | cut -c1-160)"
  fi
  if [ "$final_state" = "SUCCESS" ]; then
    check_harness "after the final deterministic re-check"
    authority_after=$(certification_inputs_hash) \
      || finish BLOCKED "could not re-check certification inputs before certification"
    [ "$authority_after" = "$authority_before" ] \
      || finish BLOCKED "certification inputs changed after the evidence snapshot"
    evidence_diff=$(post_review_product_changes "$reviewed_ref")
    [ -z "$evidence_diff" ] \
      || finish BLOCKED "product tree changed after review: $(echo "$evidence_diff" | tr '\n' ' ')"
    if [ "$task_base_valid" -eq 1 ] \
       && [ -z "$(git diff --name-only "$task_base" -- . ':(exclude).loop' ':(exclude).claude' 2>/dev/null)" ]; then
      write_certification NO_OP "$task_base" "$base" "$reviewed_ref" PASS \
        || finish BLOCKED "failed to write or commit certification.json"
      check_harness "after certification"
      finish NO_OP "verification passes with no code changes needed"
    fi
    write_certification SUCCESS "$task_base" "$base" "$reviewed_ref" PASS \
      || finish BLOCKED "failed to write or commit certification.json"
    check_harness "after certification"
    finish SUCCESS "${final_line#* }"
  fi
  finish BLOCKED "post-evidence re-check failed: $final_line"
}

# ---------- fleet engine (parallel supervisor; formerly bin/fleet.sh) ----------
# The fleet engine — loop-kit parallel supervisor: ONE resident dispatcher, many task
# loops, each in its own git worktree + branch. Deployed next to loop.sh by
# `loop.sh init` / `loop.sh update`.
#
# Architecture (research-backed: single dispatcher + durable mutable queue is
# the pattern every surveyed system converges on — Gas Town's one-Refinery-per-
# repo merge queue, MultiDevin's single manager, GNU parallel's jobqueue,
# maildir spools; concurrent dispatchers over one repo are a documented
# split-brain hazard):
#
#   .loop/fleet/queue/{tmp,new,claimed,done,failed}/<task-id>.md
#       maildir-style: tasks are written into tmp/ then atomically mv'd into
#       new/; every state transition is an atomic rename, so `add` needs no
#       locks and double-dispatch is structurally impossible.
#   .loop/fleet/runs/<task-id>.env
#       per-task metadata (safe-parsed key=value, never sourced).
#   ../<project>-loops/<task-id>/
#       the task's git worktree (branch loop/<task-id>) — a full deployed
#       loop-kit layout; the untouched loop.sh engine runs inside it.
#
# The fleet dispatcher NEVER invokes claude itself. It creates worktrees and drives the
# hash-verified ./loop.sh inside each; contract approval, tamper defenses and
# the review/evidence gates are loop.sh's, unchanged and per-worktree.
# Repo-mutating git operations (worktree add, merges) run only inside this
# single process, serially — shared-.git lock contention cannot occur.
#
# Task lifecycle:
#   add -> new/ -> claimed/ [BOOTSTRAP -> CONTRACT_GEN -> PENDING_APPROVAL
#        -> APPROVED -> RUNNING -> MERGE_PENDING] -> done/ | failed/
# Tasks can be added AT ANY TIME (./loop.sh fleet add) — the dispatcher re-scans
# new/ every tick. Approval happens per task from any terminal
# (./loop.sh fleet approve <id>), or automatically with --auto / LOOP_AUTO=1
# (each contract must still pass the independent contract review first).
#
# STATE-MACHINE INVARIANTS (what any observer may rely on):
#   I1  A task's queue directory (new/claimed/done/failed) is the source of
#       truth for its existence; every transition is one atomic mv/ln.
#   I2  PHASE in runs/<id>.env is the commit point of every multi-step
#       transition: prerequisite fields (PID, APPROVED_AT, WT) are written
#       BEFORE the PHASE that makes them meaningful; renv writes are
#       lock-serialized, so no concurrent writer can drop a field.
#   I3  Exactly one supervisor runs per repo (mkdir lock, owner-only release).
#       Liveness = holder pid alive AND (ps identity OR fresh heartbeat) — the
#       heartbeat, refreshed every tick, keeps one environment's ps quirks from
#       ever marking a live supervisor stale. A lock is stolen (atomic rename)
#       only after staleness is observed twice, 1s apart.
#   I4  done/ implies the task's branch was serially merged into the parent
#       (or was a NO_OP); failed/ implies worktree+branch are kept for autopsy.
#   I5  Drain-exit protocol: releasing the lock is the linearization point; a
#       final new/ scan after release means a task whose publisher observed a
#       live supervisor is either claimed by it or the publisher was told to
#       start a new one. No silently stranded tasks.
#   I6  Every supervisor start journals an ADOPTED entry (found phase) for
#       every claimed task, and every recovery action (RESUME, CRASH_RETRY,
#       STALE_BOOTSTRAP) is journaled — recovery is always auditable.
#
# Exit codes: 0 ok | 2 usage/config error | 3 human decision required
#             (--drain: merges blocked by a dirty parent tree) | 130 interrupted

FLEET_DIR=".loop/fleet"
QUEUE_DIR="$FLEET_DIR/queue"
RUNS_DIR="$FLEET_DIR/runs"
LOCK_DIR="$FLEET_DIR/supervisor.lock.d"
TICK_SECONDS="${LOOP_FLEET_TICK:-2}"   # dispatch tick; tests shrink it (zero-token suite)
SETUP_CMD=""                    # resolved from fleet.config.sh in cmd_fleet_run
MAX_PARALLEL=2
LAST_DEFER_NOTE=""              # merge-deferred dedup (note once, not every tick)

# worktrees live in a SIBLING directory, not inside the repo: test runners,
# grep and editors in the parent must never discover N copies of the project,
# and `rm -rf .loop` must never destroy live worktrees
WT_ROOT="${LOOP_WORKTREE_ROOT:-$(dirname "$PWD")/$(basename "$PWD")-loops}"

fdie()  { echo "fleet: error: $*" >&2; exit 2; }
fnote() { echo "fleet: $*"; }
fdie_next() { # fleet twin of die_next: error + trailing "→ next:" recovery line
  echo "fleet: error: $1" >&2
  [ -n "${2:-}" ] && echo "  → next: $2" >&2
  exit 2
}
utcnow() { date -u +%Y-%m-%dT%H:%M:%SZ; }

fleet_usage() {
  cat <<'EOF'
The parallel supervisor: one dispatcher, many task loops in isolated git
worktrees, results merged back one at a time.

Usage: ./loop.sh fleet <command>

RUN & QUEUE
  run [task ...] [--auto] [--max-parallel N] [--drain]
                        Start the supervisor (foreground, singleton). Positional
                        tasks (files or "text") are queued first.
                        --auto     approve every contract without stopping (each
                                   still passes an independent review; a refusal
                                   demotes the task to PENDING_APPROVAL)
                        --drain    exit once the queue and all runs finish (exits 3
                                   if only merges remain and the tree is dirty)
  add <task> [--auto] [--after <id,id>]
                        Queue a task any time, from any terminal. A running
                        supervisor picks it up next tick; --after serializes it
  approve <id ...|--all>
                        Review + approve contracts waiting in PENDING_APPROVAL

INSPECT
  status [--overlap]    Queue/run table; --overlap flags changed-file overlap
                        between branches (merge-conflict early warning)
  report [id]           Summary + per-task evidence report and cost
  logs <id>             Show a task's contract-generation and run logs

CONTROL
  stop <id>             TERM a running task loop (state saved; resumable)
  resume <id>           Flip an interrupted/failed task runnable (the supervisor
                        relaunches it; `./loop.sh resume <id>` also dispatches)
  ack-plan <id|--all>   Acknowledge a plan-review escalation (DR-FLEET-PLAN-<id>)
                        to release the held queued phases (restarts don't)
  merge <id>            Manually retry a merge (the supervisor does this itself)
  clean <id ...|--done|--orphans> [--force]
                        Remove worktree + branch + queue entry
                        (--orphans: gc leftovers that lost their queue entry)
  unlock                Remove a stale supervisor lock

Tasks queue as files in .loop/fleet/queue/. On merge, project code goes back via
git, .loop/docs is kept from the parent, and the run's contract + evidence are
archived under .loop/docs/run-archive/<id>/.
EOF
}

need_project() {
  [ -f loop.sh ] && [ -f loop.config.sh ] \
    || fdie "not a deployed loop-kit project — deploy first: <kit>/bin/loop.sh init ."
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fdie "not a git repository — run: git init && git add -A && git commit -m init"
  # the fleet journal is written in awk (POSIX, ubiquitous) on nearly every
  # command; fail here with a clear message, never mid-dispatch
  command -v awk >/dev/null 2>&1 \
    || fdie_next "awk not found — required for the fleet journal" "install awk (gawk/mawk) — it ships by default on macOS & Linux"
  # every per-task approval/tamper check is a SHA-256 compare (same rationale
  # as need_sha): fail at the command boundary, never mid-dispatch
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
    || fdie_next "no SHA-256 tool found (shasum or sha256sum) — required for approval and tamper detection" "install coreutils (sha256sum) or perl (shasum) — both ship by default on macOS & Linux"
}

ensure_fleet_dirs() {
  mkdir -p "$QUEUE_DIR/tmp" "$QUEUE_DIR/new" "$QUEUE_DIR/claimed" \
           "$QUEUE_DIR/done" "$QUEUE_DIR/failed" "$RUNS_DIR"
}

fcfg() { # $1 key, $2 default — safe key=value parse of fleet.config.sh, no code execution
  local v=""
  if [ -f fleet.config.sh ]; then
    v=$(grep -E "^[[:space:]]*$1=" fleet.config.sh | tail -1 \
        | sed -E "s/^[[:space:]]*$1=//; s/[[:space:]]+#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^\"//; s/\"$//") || v=""
  fi
  echo "${v:-$2}"
}

journal() { # $1 task-id, $2 event, $3 detail
  local detail
  # UTC with Z suffix — same clock as utcnow() and loop.sh's journal. task/event
  # are controlled tokens; detail is free text and is JSON-escaped. Field order +
  # ", "/": " spacing reproduce Python's json.dumps default — tests grep exact substrings.
  detail=$(printf '%s' "$3" | json_escape)
  printf '{"ts": "%s", "task": "%s", "event": "%s", "detail": "%s"}\n' \
    "$(utcnow)" "$1" "$2" "$detail" >> "$FLEET_DIR/journal.jsonl"
}

# ---------- per-task metadata (runs/<id>.env: key=value, never sourced) ----------

renv_get() { # $1 id, $2 key, [$3 default]
  local v=""
  if [ -f "$RUNS_DIR/$1.env" ]; then
    v=$(grep -E "^$2=" "$RUNS_DIR/$1.env" | tail -1 | cut -d= -f2-) || v=""
  fi
  echo "${v:-${3:-}}"
}

renv_set() { # $1 id, $2 key, $3 value (single line) — atomic, mutually exclusive rewrite.
  # $$ in the temp name: the supervisor and a user terminal (approve/add) can
  # both write the same task's env; a shared temp path would let one clobber
  # the other's half-written file. The per-task lock closes the remaining
  # lost-update window: two concurrent read-modify-writes would each rewrite
  # from the same snapshot and one writer's line (e.g. PID) would vanish.
  # mkdir is the atomic primitive (macOS has no flock). Stealing is OWNER-PID
  # based and conservative: a time-only threshold would re-introduce the lost
  # update against a slow-but-alive writer, which is the exact bug this lock
  # exists to prevent. So: holder provably dead -> steal immediately; no pid
  # recorded after ~2s (holder died in the mkdir->echo window) -> steal;
  # holder ALIVE -> keep waiting, and after ~30s fail CLOSED with a loud error
  # instead of corrupting task state (a live 30s hold of a millisecond lock
  # means something is deeply wrong and needs a human).
  local f="$RUNS_DIR/$1.env" tmp="$RUNS_DIR/.$1.env.tmp.$$" lock="$RUNS_DIR/.$1.env.lock.d" n=0 holder
  until mkdir "$lock" 2>/dev/null; do
    holder=$(cat "$lock/pid" 2>/dev/null || echo "")
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$lock"     # dead holder; remove-and-retry — exactly one racer wins mkdir
      continue
    fi
    n=$((n + 1))
    if [ -z "$holder" ] && [ "$n" -ge 100 ]; then
      rm -rf "$lock"
      continue
    fi
    if [ "$n" -ge 1500 ]; then
      fdie "runs/$1.env lock held ${n}x20ms by live pid ${holder:-?} — refusing to steal (a forced steal could drop a concurrent write); inspect and remove $lock"
    fi
    sleep 0.02
  done
  echo $$ > "$lock/pid"
  {
    if [ -f "$f" ]; then grep -vE "^$2=" "$f" || true; fi
    printf '%s=%s\n' "$2" "$3"
  } > "$tmp"
  mv -f "$tmp" "$f"
  rm -rf "$lock"
}

# ---------- queue (maildir semantics: state = directory, transition = mv) ----------

task_qdir() { # $1 id -> new|claimed|done|failed|"" on stdout
  local d
  for d in new claimed "done" failed; do
    if [ -f "$QUEUE_DIR/$d/$1.md" ]; then echo "$d"; return 0; fi
  done
  echo ""
}

tasks_in() { # $1 dir -> task ids, id-lexical order (ids embed a second-resolution
  # timestamp, so this is add order EXCEPT same-second adds, which order by slug —
  # use --after for strict sequencing)
  local f
  for f in "$QUEUE_DIR/$1"/*.md; do
    [ -f "$f" ] || continue
    basename "$f" .md
  done
}

all_task_ids() { tasks_in new; tasks_in claimed; tasks_in "done"; tasks_in failed; }

slugify() { tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-24; }

gen_task_id() { # $1 content -> unique id <YYYYmmdd-HHMMSS>-<slug>
  local slug ts id n
  slug=$(printf '%s' "$1" | head -1 | slugify)
  [ -n "$slug" ] || slug="task"
  ts=$(date +%Y%m%d-%H%M%S)
  id="$ts-$slug"
  n=2
  while [ -n "$(task_qdir "$id")" ] || [ -f "$RUNS_DIR/$id.env" ]; do
    id="$ts-$slug-$n"
    n=$((n + 1))
  done
  echo "$id"
}

dup_task_of() { # $1 content-sha -> id of a queued/claimed task with the same SRC_SHA, or ""
  local sha="$1" id
  for id in $(tasks_in new) $(tasks_in claimed); do
    if [ "$(renv_get "$id" SRC_SHA "")" = "$sha" ]; then echo "$id"; return 0; fi
  done
  echo ""
}

enqueue_task() { # $1 content, $2 src label, $3 auto(0|1) — maildir add; echoes id
  local content="$1" src="$2" auto="$3" id summary tmp tries=0 src_sha dup
  summary=$(printf '%s' "$content" | head -1 | tr -d '\n' | cut -c1-80)
  # duplicate awareness (WARN only, never refuse): scan BEFORE publishing so the
  # new task's own metadata can never match itself
  src_sha=$(printf '%s' "$content" | sha256)
  dup=$(dup_task_of "$src_sha")
  while :; do
    id=$(gen_task_id "$content")
    tmp="$QUEUE_DIR/tmp/$id.$$.md"                     # $$-unique: concurrent adds never share a temp
    printf '%s\n' "$content" > "$tmp"
    # publish with ln, not mv: atomic AND refuses to clobber, so two same-second
    # adds that computed the same id can never silently overwrite each other —
    # the loser retries with a fresh id
    if ln "$tmp" "$QUEUE_DIR/new/$id.md" 2>/dev/null; then
      rm -f "$tmp"
      break
    fi
    rm -f "$tmp"
    tries=$((tries + 1))
    [ "$tries" -lt 5 ] || fdie_next "could not enqueue task (id collisions): $summary" "inspect ./loop.sh fleet status, then retry"
    sleep 1
  done
  renv_set "$id" SUMMARY "$summary"
  renv_set "$id" SRC "$src"
  renv_set "$id" AUTO "$auto"
  renv_set "$id" SRC_SHA "$src_sha"
  renv_set "$id" ADDED_AT "$(utcnow)"
  if [ -n "$dup" ]; then
    # STDERR on purpose: callers capture this function's stdout as the new id
    echo "fleet: warning: task content identical to '$dup' (already queued) — queued anyway" >&2
    journal "$id" DUP_CONTENT "identical to $dup"
  fi
  journal "$id" ADDED "$summary"
  echo "$id"
}

# ---------- supervisor singleton lock (mkdir: atomic on POSIX, no flock on macOS) ----------

supervisor_pid()   { cat "$LOCK_DIR/pid" 2>/dev/null || echo ""; }

# GNU `stat -c %Y` first, then BSD `stat -f %m`. Order matters: on GNU/Linux
# `-f` means --file-system, so `stat -f %m "$1"` treats %m AND "$1" as FILE
# operands — it prints "$1"'s filesystem block (a multi-line "  File: ..." dump)
# to stdout while erroring on %m (nonzero exit), so the BSD form would BOTH
# pollute the value and fall through to the %Y form, yielding a "File:"-tainted
# multi-line string that later breaks `$((now - m))` under set -u (File: unbound
# variable). Trying the GNU form first means GNU never runs -f; BSD's stat has no
# -c and fails it cleanly (no stdout) before reaching the working -f form.
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo ""; }

path_mtime_fresh() { # $1 file, $2 max-age-seconds (default 60) — a beat/refresh
  # inside the window. Shared by the ps-independent liveness fallbacks so a live
  # holder is never read as dead just because `ps -o command=` formatting varies.
  local m now; m=$(mtime_of "$1"); [ -n "$m" ] || return 1
  now=$(date +%s); [ $((now - m)) -le "${2:-60}" ]
}

heartbeat_fresh() { # the running supervisor refreshes $LOCK_DIR/heartbeat every
  # tick and around every blocking call (see beat) — a beat within the window
  # can only come from a live supervisor, never from a recycled PID
  local m now
  m=$(mtime_of "$LOCK_DIR/heartbeat")
  [ -n "$m" ] || return 1
  now=$(date +%s)
  [ $((now - m)) -le "${LOOP_FLEET_HEARTBEAT_STALE:-60}" ]
}

beat() { # owner-only heartbeat refresh (a successor's lock must never be touched)
  if [ "$(supervisor_pid)" = "$$" ]; then
    : > "$LOCK_DIR/heartbeat" 2>/dev/null || true
  fi
}

# ---------- single-loop run heartbeat (the ps-independent liveness half) ----------
# The supervisor already proved ps parsing is a fragile aliveness signal (see
# supervisor_alive): `ps -o command=` formatting varies across shells, exec
# wrappers and OSes, so a LIVE process can read as "not loop.sh". Its answer is a
# heartbeat — refreshed only by the live owner — that a ps miss falls back to.
# single_loop_alive / task_pid_alive / the orphan gc guard need the same fallback
# (a false "dead" there inverts a safety boundary: fleet runs beside a live root
# loop, a busy task's resume is stolen, a live worktree is gc'd). run_beat gives
# the single-loop run path (and every fleet worker, which IS a single loop) that
# heartbeat; run_heartbeat_fresh reads it.
run_heartbeat_fresh() { # $1 = tree dir (default .): is $tree/.loop/run.heartbeat
  # within the freshness window? A beat inside it can only come from a live loop —
  # a crashed loop stops beating, so a recycled pid can never look fresh.
  path_mtime_fresh "${1:-.}/.loop/run.heartbeat" "${LOOP_RUN_HEARTBEAT_STALE:-60}"
}

run_beat() { # refresh THIS tree's run heartbeat when a loop is working here: a
  # fleet worker tree (marker, set before contract-gen — so CONTRACT_GEN counts as
  # live too) OR a root single loop (owns .loop/run.pid = its own $$). A
  # supervisor/decompose in the parent tree matches NEITHER, so its run_claude
  # calls never forge a run heartbeat there (single_loop_alive gates on run.pid).
  if [ -f .loop/fleet-worker ] || [ "$(cat .loop/run.pid 2>/dev/null)" = "$$" ]; then
    : > .loop/run.heartbeat 2>/dev/null || true
  fi
}

supervisor_alive() { # aliveness must NOT hinge on parsing ps output: `ps -o
  # command=` formatting varies across environments, and one false "stale" on a
  # LIVE supervisor lets a second dispatcher steal the lock — two supervisors
  # then interleave over the same queue and worktrees (the worst fleet failure
  # mode). Decision order, most authoritative first:
  #   1. recorded pid is DEAD        -> stale (kill -0 cannot false-negative here)
  #   2. pid alive + looks-like-fleet -> alive (the normal case)
  #   3. pid alive, ps parse says no  -> trust a fresh heartbeat over ps: a beat
  #      within the window proves the real supervisor is running; without one,
  #      the pid is a recycled stranger and the lock is stale.
  local pid
  pid=$(supervisor_pid)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q "loop\.sh" && return 0
  heartbeat_fresh
}

try_acquire_lock() { # non-dying acquire — used by the drain exit protocol only
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  echo $$ > "$LOCK_DIR/pid"
  : > "$LOCK_DIR/heartbeat"
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    : > "$LOCK_DIR/heartbeat"
    return 0
  fi
  if supervisor_alive; then
    fdie "supervisor already running (pid $(supervisor_pid)) — one dispatcher per repo; add tasks with: ./loop.sh fleet add <task>"
  fi
  # confirm before stealing: staleness must be observed TWICE, 1s apart — a
  # transient hiccup (pid file mid-write, ps blip) must never cost a live
  # supervisor its lock. A genuinely dead holder fails both checks instantly.
  sleep 1
  supervisor_alive && fdie "supervisor already running (pid $(supervisor_pid)) — add tasks with: ./loop.sh fleet add <task>"
  fnote "removing stale supervisor lock (pid '$(supervisor_pid)' is gone)"
  # steal by RENAME: atomic with exactly one winner — two racing recoveries can
  # never both remove-and-recreate the lock (the rm+mkdir sequence could)
  mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null \
    || fdie "another supervisor is taking over the stale lock — try again"
  rm -rf "$LOCK_DIR.stale.$$"
  mkdir "$LOCK_DIR" 2>/dev/null || fdie "another supervisor grabbed the lock — try again"
  echo $$ > "$LOCK_DIR/pid"
}

release_lock() { # remove only OUR lock: a signal landing inside the drain-exit
  # window (lock already released, successor may hold it) must never delete a
  # successor supervisor's lock. Missing/foreign pid file -> leave it alone.
  if [ "$(supervisor_pid)" = "$$" ]; then rm -rf "$LOCK_DIR"; fi
}

# ---------- worktree bootstrap (a fresh worktree contains NO harness: the kit ----------
# files are gitignored by design, and the tracked .loop/docs it inherits hold the
# PARENT's filled-in contract — both must be fixed before anything runs)

wt_path() { echo "$WT_ROOT/$1"; }

next_fleet_index() { # monotonic per-project counter — hook for un-isolated resources (ports, DB names)
  local n
  n=$(cat "$FLEET_DIR/next-index" 2>/dev/null || echo 1)
  echo $((n + 1)) > "$FLEET_DIR/next-index"
  echo "$n"
}

bootstrap_seed_merge() { # $1 id, $2 wt, $3 seed-branch — carryover: merge the
  # escalated predecessor's committed work into this fresh worktree. Branch from
  # merged HEAD as always and merge the seed tip IN, so sibling work merged in
  # the meantime is kept. NEVER fails the bootstrap: a conflict (or a vanished
  # branch) skips the carryover with a journaled CARRYOVER_SKIPPED — the work
  # then still lives on the archived seed branch.
  local id="$1" wt="$2" seed="$3" added f
  if ! git rev-parse -q --verify "$seed" >/dev/null 2>&1; then
    journal "$id" CARRYOVER_SKIPPED "seed branch $seed no longer exists"
    return 0
  fi
  if ! ( cd "$wt" && git merge --no-ff --no-commit "$seed" ) >> "$RUNS_DIR/$id/plan.log" 2>&1; then
    ( cd "$wt" && { git merge --abort 2>/dev/null || git reset --hard HEAD >/dev/null 2>&1; } ) || true
    journal "$id" CARRYOVER_SKIPPED "seed merge of $seed conflicted — the carried work remains on $seed"
    fnote "[$id] carryover skipped (conflict) — escalated work remains on $seed"
    return 0
  fi
  # parent-wins docs strip (mirrors merge_task): the seed's tracked .loop/docs
  # (its sub-contract/progress) must not ride into the fresh worktree — the
  # docs hard-reset below re-seeds pristine templates for THIS task
  ( cd "$wt" && git checkout HEAD -- .loop/docs 2>/dev/null ) || true
  added=$(cd "$wt" && git diff --cached --name-only --diff-filter=A -- .loop/docs 2>/dev/null || true)
  if [ -n "$added" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && ( cd "$wt" && git rm -qf "$f" ) >/dev/null 2>&1 || true
    done <<EOF
$added
EOF
  fi
  if ( cd "$wt" && git commit -q -m "fleet: carryover partial work from $seed" ) >> "$RUNS_DIR/$id/plan.log" 2>&1; then
    journal "$id" CARRYOVER_SEEDED "merged $seed into the fresh worktree"
    fnote "[$id] carryover: seeded with the escalated task's committed work ($seed)"
  else
    ( cd "$wt" && { git merge --abort 2>/dev/null || git reset --hard HEAD >/dev/null 2>&1; } ) || true
    journal "$id" CARRYOVER_SKIPPED "seed merge commit failed — the carried work remains on $seed"
  fi
  return 0
}

bootstrap_worktree() { # $1 id — worktree + full harness re-deploy; nonzero on failure
  local id="$1" wt base d name seed dep pcf
  wt=$(wt_path "$id")
  base=$(git rev-parse HEAD) || return 1
  mkdir -p "$WT_ROOT" || return 1
  git worktree add "$wt" -b "loop/$id" "$base" >> "$RUNS_DIR/$id/plan.log" 2>&1 || return 1
  renv_set "$id" BRANCH "loop/$id"
  renv_set "$id" WT "$wt"
  renv_set "$id" BASE_REF "$base"

  # carryover seed (NEEDS_DECOMPOSITION splits): must run BEFORE the harness
  # copy / docs reset below dirty the tree — git merge refuses over uncommitted
  # tracked changes
  seed=$(renv_get "$id" SEED_BRANCH "")
  [ -z "$seed" ] || bootstrap_seed_merge "$id" "$wt" "$seed"

  # harness: copy from THIS deployment (not the kit) so every worktree runs
  # byte-identical loop.sh/evaluator/skills — per-worktree harness hashes then
  # verify exactly what the user approved here
  cp loop.sh "$wt/loop.sh" || return 1
  chmod +x "$wt/loop.sh"
  mkdir -p "$wt/.loop/bin" "$wt/.loop/docs" "$wt/.loop/logs" "$wt/.claude/skills" || return 1
  cp .loop/bin/evaluate.sh "$wt/.loop/bin/evaluate.sh" || return 1
  chmod +x "$wt/.loop/bin/evaluate.sh"
  for d in .claude/skills/loop-*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    # legacy repos may have COMMITTED skills (pre-gitignore deployments): the
    # worktree then materializes the old version, and cp -R into an existing
    # dir would NEST the fresh copy one level down where Claude never reads it
    rm -rf "${wt:?}/.claude/skills/$name"
    cp -R "$d" "$wt/.claude/skills/$name" || return 1
  done
  cp loop.config.sh "$wt/loop.config.sh" || return 1          # seed; /loop-contract rewrites per task
  [ ! -f loop.models.sh ] || cp loop.models.sh "$wt/loop.models.sh" || return 1
  printf '*\n!.gitignore\n!docs\n!docs/**\n' > "$wt/.loop/.gitignore"
  ensure_gitignore "$wt" >/dev/null   # same marker blocks; note silenced (supervisor stdout)

  # docs hard-reset: the worktree inherited the parent's tracked, FILLED-IN docs;
  # without this reset contract_is_defined() is already true and the loop would
  # silently run the parent's old contract instead of this task
  cp .loop/templates/*.md "$wt/.loop/docs/" || return 1

  # the task instruction itself (task files are untracked — checkout can't provide them)
  cp "$QUEUE_DIR/claimed/$id.md" "$wt/loop-instruction.md" || return 1

  # orchestrated (PLANNED) tasks: inject the parent's approved MASTER contract as
  # read-only context for the sub-contract generator and its reviewer. It lives
  # outside .loop/docs (untracked, never part of the sub-contract approval hash);
  # the parent pins its hash in runs/<id>.env — a location the worktree agent
  # cannot reach — and re-verifies the copy before every review/approval
  # (master_intact), so a worker cannot widen its own goalposts by editing it.
  if [ "$(renv_get "$id" PLANNED 0)" = "1" ] \
     && [ -f .loop/docs/product-contract.md ] \
     && ! grep -q '<!-- TEMPLATE -->' .loop/docs/product-contract.md; then
    cp .loop/docs/product-contract.md "$wt/.loop/master-contract.md" || return 1
    renv_set "$id" MASTER_HASH "$(sha256 < .loop/docs/product-contract.md)"
  fi

  # phase-context: a later phase of a chained workflow inherits each merged
  # predecessor's archived sub-contract + evidence report + assumptions ledger —
  # the WHY behind the code already in this tree (decisions taken, known gaps,
  # assumptions). The assumptions ledger is what lets a fork's JOIN reconcile
  # cross-branch decisions (loop-decompose: "the join reconciles the branches").
  # TRANSITIVE closure (env_dep_ancestors), not just direct DEPENDS_ON: in a
  # chain a -> b -> c, phase c has a's code merged in its tree too — a's
  # decisions must not go dark just because b sits in between.
  # Advisory context only, never authority: no hash pin; the pinned
  # master-contract.md above stays the sole authority, and a predecessor's
  # "met" claims are phase-scoped (the skills say so).
  for dep in $(env_dep_ancestors "$id"); do
    [ -d ".loop/docs/run-archive/$dep" ] || continue
    mkdir -p "$wt/.loop/phase-context/$dep"
    for pcf in evidence-report.md product-contract.md assumptions.md; do
      [ ! -f ".loop/docs/run-archive/$dep/$pcf" ] \
        || cp ".loop/docs/run-archive/$dep/$pcf" "$wt/.loop/phase-context/$dep/" || true
    done
  done

  # worker marker: tells the loop engine inside this worktree that it is a fleet
  # task (always the single-loop path — a worker must never decompose recursively)
  printf '%s\n' "$PWD" > "$wt/.loop/fleet-worker"
  printf '%s\n' "$id" > "$wt/.loop/task-id"

  if [ -n "$SETUP_CMD" ]; then
    fnote "[$id] setup: $SETUP_CMD"
    ( cd "$wt" && /bin/sh -c "$SETUP_CMD" ) >> "$RUNS_DIR/$id/plan.log" 2>&1 || return 1
  fi
  return 0
}

# ---------- task phase transitions ----------

task_pid_alive() {
  local pid wt
  pid=$(renv_get "$1" PID "")
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # PIDs recycle: a pid recorded before a crash may now belong to a stranger —
  # adopting it would freeze the task at RUNNING and burn a slot forever. Confirm
  # identity, most authoritative first; a ps miss must NEVER flip a live task to
  # "dead" (that reaps real work and drops the busy-resume guard):
  #   1. worktree .loop/run.pid == pid — the worker exec'd `loop.sh run`, which
  #      writes its own $$ there; environment-independent proof it is our loop.
  #   2. ps says loop.sh — fallback (its -o command= format varies across envs).
  #   3. fresh run heartbeat — the ps-independent liveness half (see run_beat).
  wt=$(renv_get "$1" WT "")
  [ -n "$wt" ] && [ "$(cat "$wt/.loop/run.pid" 2>/dev/null)" = "$pid" ] && return 0
  ps -p "$pid" -o command= 2>/dev/null | grep -q "loop\.sh" && return 0
  [ -n "$wt" ] && run_heartbeat_fresh "$wt"
}

wt_state() { cat "$(renv_get "$1" WT "")/.loop/state" 2>/dev/null || echo ""; }

single_loop_alive() { # is a live single-loop `run` recorded in ./.loop/run.pid?
  # cmd_run writes the pidfile just before its iteration loop; finish() and
  # on_interrupt remove it. Liveness = pid alive AND identity (mirrors
  # supervisor_alive): a recycled pid must never make a crashed loop look alive,
  # and a stale RUNNING state alone must never block the fleet. A dead pid is
  # caught by kill -0; identity, most authoritative first:
  #   ps says loop.sh  -> our loop (normal case).
  #   ps parse says no -> trust a fresh run heartbeat over ps, whose -o command=
  #     format varies across shells/exec-wrappers/OS. A beat in the window proves
  #     a LIVE loop; without one the alive pid is a recycled stranger. Erring to
  #     ps here would be the dangerous direction: a false "dead" lets the fleet
  #     run beside a live root loop (both move HEAD — the split-brain we refuse).
  local pid
  pid=$(cat .loop/run.pid 2>/dev/null || echo "")
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q "loop\.sh" && return 0
  run_heartbeat_fresh .
}

task_done() { # $1 id, $2 detail
  mv -f "$QUEUE_DIR/claimed/$1.md" "$QUEUE_DIR/done/$1.md" 2>/dev/null || true
  renv_set "$1" PHASE DONE
  renv_set "$1" ENDED_AT "$(utcnow)"
  journal "$1" DONE "$2"
  fnote "[$1] done — $2"
}

task_fail() { # $1 id, $2 result-state, $3 detail
  mv -f "$QUEUE_DIR/claimed/$1.md" "$QUEUE_DIR/failed/$1.md" 2>/dev/null || true
  renv_set "$1" PHASE "$2"
  renv_set "$1" RESULT "$2"
  renv_set "$1" ENDED_AT "$(utcnow)"
  journal "$1" FAILED "$2: $3"
  fnote "[$1] $2 — $3"
}

claim_task() { # $1 id — new/ -> claimed/ (atomic), then bootstrap + contract gen
  local id="$1"
  [ -f "$RUNS_DIR/$id.env" ] || return 0   # `add` is still writing metadata — claim next tick
  mv "$QUEUE_DIR/new/$id.md" "$QUEUE_DIR/claimed/$id.md" 2>/dev/null || return 0
  renv_set "$id" CLAIMED_AT "$(utcnow)"
  renv_set "$id" FLEET_INDEX "$(next_fleet_index)"
  mkdir -p "$RUNS_DIR/$id"
  journal "$id" CLAIMED ""
  fnote "[$id] claimed — creating worktree $(wt_path "$id")"
  if bootstrap_worktree "$id"; then
    start_contract_gen "$id"
  else
    git worktree remove --force "$(wt_path "$id")" >/dev/null 2>&1 || true
    git branch -D "loop/$id" >/dev/null 2>&1 || true
    task_fail "$id" BOOTSTRAP_FAILED "worktree/setup failed — see $RUNS_DIR/$id/plan.log"
  fi
}

start_contract_gen() { # $1 id — headless contract via loop.sh's non-TTY start path
  local id="$1" wt
  wt=$(renv_get "$id" WT)
  # LOOP_AUTO is forced to 0: a leaked LOOP_AUTO=1 would auto-approve AND run
  # here — approval must stay a separate, human (or explicitly --auto) step.
  # LOOP_ASK_CRITICAL is forced to 0: workers keep assumptions mode — their
  # question-answerer is the supervise path, and a parked worker contract would
  # deadlock the dispatcher's approval wait instead of asking anyone.
  ( cd "$wt" && LOOP_AUTO=0 LOOP_ASK_CRITICAL=0 exec ./loop.sh start loop-instruction.md </dev/null ) \
    >> "$RUNS_DIR/$id/plan.log" 2>&1 &
  renv_set "$id" PID $!
  : > "$wt/.loop/run.heartbeat" 2>/dev/null || true   # seed liveness for the
  # launch→first-beat window (the child's run_claude refreshes it thereafter), so
  # task_pid_alive never reaps this live worker on a ps miss
  renv_set "$id" PHASE CONTRACT_GEN
  journal "$id" CONTRACT_GEN ""
  fnote "[$id] generating contract headlessly"
}

start_run() { # $1 id — the actual loop; `exec` makes PID be loop.sh itself so
  # TERM reaches loop.sh's on_interrupt (kills its claude child, saves state).
  # --prefer-resume: a relaunch continues where an interrupted/failed run left off
  # (iteration budget + streak counters intact) when a valid checkpoint exists, and
  # falls back to a fresh run otherwise (first launch, or a changed contract). So a
  # crash-retry / `./loop.sh fleet resume` resumes instead of restarting from iteration 1.
  local id="$1" wt idx
  wt=$(renv_get "$id" WT)
  idx=$(renv_get "$id" FLEET_INDEX 0)
  ( cd "$wt" && LOOP_FLEET_INDEX="$idx" exec ./loop.sh run --prefer-resume </dev/null ) \
    >> "$RUNS_DIR/$id/run.log" 2>&1 &
  renv_set "$id" PID $!
  : > "$wt/.loop/run.heartbeat" 2>/dev/null || true   # seed liveness for the
  # launch→first-beat window (before the child writes run.pid + beats), so
  # task_pid_alive never reaps this live worker on a ps miss
  renv_set "$id" PHASE RUNNING
  renv_set "$id" LAUNCHED_AT "$(utcnow)"
  journal "$id" LAUNCHED ""
  fnote "[$id] running (watch: ./loop.sh fleet logs $id)"
}

park_human_stopped() { # $1 id — STOPPED_BY=human (set by cmd_fleet_stop before the
  # kill): the stop is a human intervention no recovery may silently un-do, so the
  # task parks in failed/ (resumable via resume_class's relaunch arm; keeps --drain
  # terminable) instead of auto-resuming. Inside an orchestration the existing
  # ORCH_INTERRUPTED_PARKED journal contract is kept ALONGSIDE the stop record.
  local id="$1"
  journal "$id" STOP_HONORED "human stop (fleet stop) honored — parked, not auto-resumed"
  if [ "$(cat .loop/state 2>/dev/null)" = "FLEET_RUNNING" ]; then
    journal "$id" ORCH_INTERRUPTED_PARKED "stopped externally during orchestration"
  fi
  task_fail "$id" INTERRUPTED "stopped by human (fleet stop) — resume: ./loop.sh fleet resume $id"
}

reap_task() { # $1 id — its process died; derive the outcome from the worktree state
  local id="$1" phase state wt retries rc=0
  phase=$(renv_get "$id" PHASE)
  set +e
  wait "$(renv_get "$id" PID 0)" 2>/dev/null
  rc=$?
  set -e
  case "$phase" in
    CONTRACT_GEN)
      wt=$(renv_get "$id" WT)
      if [ -f "$wt/.loop/docs/product-contract.md" ] \
         && ! grep -q '<!-- TEMPLATE -->' "$wt/.loop/docs/product-contract.md"; then
        renv_set "$id" PHASE CONTRACT_READY
        journal "$id" CONTRACT_READY ""
      else
        task_fail "$id" CONTRACT_FAILED "contract generation failed — see $RUNS_DIR/$id/plan.log"
      fi
      ;;
    RUNNING)
      state=$(wt_state "$id")
      renv_set "$id" RESULT "$state"
      case "$state" in
        SUCCESS)
          renv_set "$id" PHASE MERGE_PENDING
          journal "$id" EXIT_SUCCESS ""
          fnote "[$id] SUCCESS — queued for serial merge"
          ;;
        NO_OP)
          task_done "$id" "NO_OP: verification passes with no changes needed"
          ;;
        NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION)
          if [ "$(renv_get "$id" PLANNED 0)" = "1" ] && [ "$(fcfg FLEET_SUPERVISE 1)" != "0" ]; then
            # orchestrated tasks: the supervisor judges the question against the
            # human-approved MASTER contract first (ANSWER / REPLAN — a
            # NEEDS_DECOMPOSITION is normally a REPLAN into a phased chain);
            # only what the master cannot answer goes to a human (tick step 2.5)
            renv_set "$id" PHASE SUPERVISE_PENDING
            journal "$id" SUPERVISE_PENDING "$state"
            fnote "[$id] escalated ($state) — queued for a supervisor decision"
          else
            # manual tasks: exit-3 escalations are NEVER auto-retried (same rule
            # as loop.sh watch) — a human decides in the worktree, then resume
            task_fail "$id" "$state" "human decision required — read $(renv_get "$id" WT)/.loop/docs/decision-requests.md; after deciding: (cd $(renv_get "$id" WT) && ./loop.sh approve), then ./loop.sh fleet resume $id"
          fi
          ;;
        RISK_REQUIRES_APPROVAL)
          # NEVER supervised, planned or not: this state covers harness-tamper
          # detections — an autonomous supervisor "approving" it would defeat
          # the trust model (and the worktree's approval hashes block a relaunch)
          task_fail "$id" "$state" "human decision required — read $(renv_get "$id" WT)/.loop/docs/decision-requests.md; after deciding: (cd $(renv_get "$id" WT) && ./loop.sh approve), then ./loop.sh fleet resume $id"
          ;;
        BLOCKED|STALLED|BUDGET_EXCEEDED)
          task_fail "$id" "$state" "see ./loop.sh fleet logs $id (worktree + branch kept)"
          ;;
        INTERRUPTED)
          if [ "$(renv_get "$id" STOPPED_BY "")" = "human" ]; then
            park_human_stopped "$id"
          else
            renv_set "$id" PHASE INTERRUPTED
            journal "$id" INTERRUPTED ""
            fnote "[$id] interrupted — resume with: ./loop.sh fleet resume $id"
          fi
          ;;
        RUNNING|"")
          # died without writing a terminal state = crashed mid-iteration.
          # loop.sh run resumes safely (memory = .loop/docs + git): retry once.
          retries=$(renv_get "$id" RETRIES 0)
          if [ "$retries" -lt 1 ]; then
            renv_set "$id" RETRIES $((retries + 1))
            renv_set "$id" PHASE APPROVED
            journal "$id" CRASH_RETRY "died without terminal state (rc=$rc) — relaunching once"
            fnote "[$id] crashed mid-run — relaunching once"
          else
            task_fail "$id" CRASHED "died twice without a terminal state (rc=$rc)"
          fi
          ;;
        *)
          task_fail "$id" "$state" "unexpected terminal state"
          ;;
      esac
      ;;
  esac
}

contract_review_ok() { # $1 id — independent check before an UNATTENDED approval.
  # A human running ./loop.sh fleet approve IS the reviewer; this runs only on the
  # tick's auto path. Synchronous by design: it briefly pauses dispatch (one
  # reader call), which is simpler and safer than a fourth async phase — a
  # crash mid-review leaves the task in CONTRACT_READY and it is re-reviewed
  # on restart. LOOP_CONTRACT_REVIEW=0 disables (mirrors loop.sh auto).
  # Nonzero = refused (REVISE, exit 4) OR reviewer unavailable (exit 2): both
  # demote to PENDING_APPROVAL — never approve unattended on an open question.
  [ "${LOOP_CONTRACT_REVIEW:-1}" != "0" ] || return 0
  ( cd "$(renv_get "$1" WT)" && LOOP_AUTO=0 ./loop.sh contract-review ) \
    >> "$RUNS_DIR/$1/plan.log" 2>&1
}

deps_state() { # $1 id -> ready | waiting | failed:<dep>  (DEPENDS_ON gating)
  # A dependency is satisfied only when its task is in done/ — i.e. MERGED
  # (invariant I4): the dependent's worktree branches from parent HEAD, so a
  # merged dependency's code is exactly what it inherits. A terminally failed
  # dependency parks the dependent (DEP_FAILED) instead of livelocking --drain.
  # Scan ALL deps — failed beats waiting, so a [waiting,failed] dependent parks
  # immediately instead of hiding the dead dependency behind a running one.
  # A merged dependency with an unresolved phase-boundary plan-review
  # (PLAN_REVIEW=PENDING|ESCALATED) still counts as waiting: dependents must
  # not start while the queued plan may be revised — a durable hold across
  # crashes (the marker lives in the env). This is the synchronization story for
  # a DEPENDENCY-triggered review; a DRIFT-triggered review (the merged phase has
  # no dependents, so this hold is a no-op) is instead ordered by tick's
  # merge->plan-review->claim sequence within one tick, and its ESCALATE is held
  # by the global plan_review_escalated -> finish (never a silent release).
  local id="$1" dep deps state=ready
  deps=$(renv_get "$id" DEPENDS_ON "")
  [ -n "$deps" ] || { echo ready; return 0; }
  for dep in $(printf '%s' "$deps" | tr ',' ' '); do
    case "$(task_qdir "$dep")" in
      "done") case "$(renv_get "$dep" PLAN_REVIEW "")" in
                PENDING|ESCALATED) state=waiting ;;
              esac ;;
      failed) echo "failed:$dep"; return 0 ;;
      *)      state=waiting ;;
    esac
  done
  echo "$state"
}

task_has_queued_dependents() { # $1 id — does any new/ task DEPENDS_ON it?
  local d
  for d in $(tasks_in new); do
    case ",$(renv_get "$d" DEPENDS_ON "" | tr -d ' ')," in
      *",$1,"*) return 0 ;;
    esac
  done
  return 1
}

any_queued_planned() { # any PLANNED task still in new/ — i.e. is there queued
  # orchestrated work a phase-boundary plan-review could actually revise?
  local d
  for d in $(tasks_in new); do
    [ "$(renv_get "$d" PLANNED 0)" = "1" ] && return 0
  done
  return 1
}

merged_task_recorded_drift() { # $1 id — did the worker leave "Drift detected: yes"
  # in its spec-drift-report? A contract-TOUCHING drift already escalated
  # (NEEDS_SPEC_DECISION) and never merged, so a merged task carrying this marker
  # is the "reality shifted but I handled it locally and proceeded" case — a
  # low-frequency, intentional handoff (see loop-iterate's drift-summary rule)
  # worth a plan-review of the queued remainder. Read the WORKTREE copy: arming
  # runs before the merge commit, so the run-archive does not exist yet. Anchored
  # to the summary rollup line, not a checks-table cell (the worker's own verdict).
  local wt report
  wt=$(renv_get "$1" WT "")
  report="$wt/.loop/docs/spec-drift-report.md"
  [ -f "$report" ] || return 1
  grep -qE '^- Drift detected:[[:space:]]*yes[[:space:]]*$' "$report"
}

plan_review_escalated() { # any merged task holding dependents on a human decision?
  local d
  for d in $(tasks_in "done"); do
    [ "$(renv_get "$d" PLAN_REVIEW "")" = "ESCALATED" ] && return 0
  done
  return 1
}

fleet_plan_held() { # a plan-review escalation is the SOLE blocker: nothing runs,
  # nothing is claimable, and only a human ack (fleet ack-plan) can release the
  # held dependents — waiting would never make progress
  local id
  plan_review_escalated || return 1
  for id in $(tasks_in new); do
    [ "$(deps_state "$id")" = "waiting" ] || return 1
  done
  [ -z "$(tasks_in claimed)" ]
}

dep_fail_task() { # $1 id (in new/), $2 failed dep — park a never-claimed dependent
  mv -f "$QUEUE_DIR/new/$1.md" "$QUEUE_DIR/failed/$1.md" 2>/dev/null || return 0
  renv_set "$1" PHASE DEP_FAILED
  renv_set "$1" RESULT DEP_FAILED
  renv_set "$1" ENDED_AT "$(utcnow)"
  journal "$1" DEP_FAILED "dependency $2 failed — fix/resume the dependency, then: ./loop.sh fleet resume $1"
  fnote "[$1] dependency $2 failed — parked as DEP_FAILED"
}

master_intact() { # $1 id — orchestrated tasks: verify the worktree's master-contract
  # copy against the hash pinned at bootstrap (runs/<id>.env, unreachable from the
  # worktree). On mismatch: restore from the parent, journal MASTER_TAMPER, return
  # nonzero — callers demote/refuse, failing toward a human. Non-orchestrated
  # tasks (no MASTER_HASH) pass vacuously.
  local id="$1" mh wt cur
  mh=$(renv_get "$id" MASTER_HASH "")
  [ -n "$mh" ] || return 0
  wt=$(renv_get "$id" WT "")
  cur=$(sha256 < "$wt/.loop/master-contract.md" 2>/dev/null) || cur=""
  if [ "$cur" = "$mh" ]; then return 0; fi
  cp .loop/docs/product-contract.md "$wt/.loop/master-contract.md" 2>/dev/null || true
  journal "$id" MASTER_TAMPER "worktree master-contract copy diverged from the pinned hash — restored from the parent"
  fnote "[$id] master-contract copy was modified inside the worktree — restored (journaled)"
  return 1
}

approve_task() { # $1 id, $2 journal-event — record the approval inside the worktree.
  # Returns nonzero on failure: callers must handle it — one task's broken
  # worktree must never take the whole dispatcher down.
  local id="$1"
  if ! ( cd "$(renv_get "$id" WT)" && ./loop.sh approve ) >> "$RUNS_DIR/$id/plan.log" 2>&1; then
    return 1
  fi
  # APPROVED_AT first, PHASE last: the dispatcher may launch the moment it sees
  # PHASE=APPROVED and record a PID — a later env write from THIS process
  # (read-modify-write) could drop that PID line. PHASE is the commit point.
  renv_set "$id" APPROVED_AT "$(utcnow)"
  renv_set "$id" PHASE APPROVED
  journal "$id" "$2" ""
}

# ---------- supervision (mid-run decisions on escalated orchestrated tasks) ----------
# A PLANNED task that stops with NEEDS_SPEC_DECISION / NEEDS_ARCHITECTURE_DECISION
# is judged by a READ-ONLY supervisor call against the human-approved MASTER
# contract: ANSWER (harness writes guidance, task relaunches), REPLAN (task is
# superseded by replacement tasks), or ESCALATE (parked NEEDS_HUMAN for a human).
# The supervisor model writes nothing; every write below is the harness's, and
# every decision is journaled. Interventions are capped per task (count guard).

# ---------- supervisor session continuity (hybrid: resume + rotate) ----------
# The supervisor role (task decisions + phase-boundary plan-reviews) reuses ONE
# conversational session across calls via `claude -p --resume`, so repeat calls
# skip re-reading skills and unchanged docs. The session is a CACHE, never
# authority: files stay the single source of truth, every payload passes the
# same deterministic validators, and the session is dropped (rotated) on any
# call failure, an unparseable verdict, a supervisor restart, the call-count
# cap — and after every applied plan mutation, so a stale conversational view
# of the plan can never outlive the files. The flow-designer role (decompose)
# and the reviewers stay fresh-per-call by design.

SUPERVISOR_SESSION_FILE=".loop/fleet/supervisor-session"

supervisor_session_drop() { rm -f "$SUPERVISOR_SESSION_FILE"; }

run_claude_supervisor() { # $1 label, $2 prompt — reader call with session reuse
  local label="$1" prompt="$2" sid="" count=0 line max
  max=$(fcfg FLEET_SUPERVISOR_SESSION_MAX 20)
  case "$max" in ''|*[!0-9]*) max=20 ;; esac
  if [ "$(fcfg FLEET_SUPERVISOR_SESSION 1)" != "0" ] && [ -f "$SUPERVISOR_SESSION_FILE" ]; then
    line=$(head -1 "$SUPERVISOR_SESSION_FILE" 2>/dev/null || echo "")
    sid=${line%% *}
    count=${line##* }
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    if [ -n "$sid" ] && [ "$count" -lt "$max" ]; then
      CLAUDE_RESUME_SESSION="$sid"
      # the token tells the skill: same fleet, unchanged contract+plan since
      # your last call (the harness rotates otherwise) — read only the freshly
      # staged files
      prompt="$prompt session=resumed"
    else
      supervisor_session_drop
      count=0
    fi
  else
    count=0
  fi
  if ! run_claude "$label" "$prompt" "$MODEL_SUPERVISE" reader SUPERVISE; then
    # a failed/killed call may leave the conversation unusable — rotate
    supervisor_session_drop
    return 1
  fi
  if [ "$(fcfg FLEET_SUPERVISOR_SESSION 1)" != "0" ] && [ -n "${LAST_SESSION_ID:-}" ]; then
    # always store the LAST result's id: print-mode --resume may fork a new
    # session id per call, so only the freshest handle resumes correctly
    printf '%s %s\n' "$LAST_SESSION_ID" "$((count + 1))" > "$SUPERVISOR_SESSION_FILE"
  fi
  return 0
}

write_queue_snapshot() { # $1 dst-file — the LIVE queue for a supervisor call.
  # .loop/docs/task-plan.md is the ORIGINAL approved plan and is never rewritten
  # by replans/revisions (its hash binds contract<->plan); this snapshot is the
  # current truth about what is queued/running — the supervisor must take task
  # ids and DEPENDS targets from HERE, never from the (possibly superseded) plan.
  local dst="$1" d
  {
    echo "# Queue snapshot (harness-written: the LIVE queue — task-plan.md is the"
    echo "# original approved plan and may have been superseded by replans)"
    echo
    echo "## Revisable: queued tasks (new/, not yet claimed)"
    for d in $(tasks_in new); do
      echo "### $d"
      echo "- SUMMARY: $(renv_get "$d" SUMMARY "")"
      echo "- DEPENDS_ON: $(renv_get "$d" DEPENDS_ON "-")"
      echo "- REQS: $(renv_get "$d" REQS "-")"
      echo "- SCOPE: $(renv_get "$d" SCOPE "-")"
      echo "- body:"
      sed 's/^/    /' "$QUEUE_DIR/new/$d.md" 2>/dev/null || true
      echo
    done
    [ -n "$(tasks_in new)" ] || echo "(none)"
    echo
    echo "## Untouchable: claimed/running tasks (a REPLAN/REVISE may not touch their REQs)"
    for d in $(tasks_in claimed); do
      echo "- $d [$(renv_get "$d" PHASE "")] REQS: $(renv_get "$d" REQS "-")"
    done
    [ -n "$(tasks_in claimed)" ] || echo "(none)"
  } > "$dst"
}

stage_supervise_inputs() { # $1 id — copy the worker's decision state to the parent
  # (deterministic input set for the read-only call; no cross-tree reads)
  local id="$1" wt dst
  wt=$(renv_get "$id" WT "")
  dst=".loop/supervise/$id"
  rm -rf "$dst"
  mkdir -p "$dst"
  cp "$wt/.loop/docs/product-contract.md" "$dst/task-contract.md" 2>/dev/null || true
  cp "$wt/.loop/docs/decision-requests.md" "$dst/decision-requests.md" 2>/dev/null || true
  cp "$wt/.loop/docs/assumptions.md" "$dst/assumptions.md" 2>/dev/null || true
  cp "$wt/.loop/docs/progress.md" "$dst/progress.md" 2>/dev/null || true
  cp "$wt/.loop/last-verify.log" "$dst/last-verify.log" 2>/dev/null || true
  cp "$wt/.loop/state" "$dst/state" 2>/dev/null || true
  cp "$wt/.loop/agent-state" "$dst/agent-state" 2>/dev/null || true
  # the LIVE queue: a REPLAN's DEPENDS targets must come from here — after any
  # prior replan/revision, task-plan.md still shows the superseded original plan
  write_queue_snapshot "$dst/queue-snapshot.md"
}

extract_between() { # $1 text, $2 begin-marker, $3 end-marker -> the block body
  # markers must be exact lines (ASCII, machine tokens) — fail-closed callers
  # treat an empty result as a malformed payload
  printf '%s\n' "$1" | awk -v b="$2" -v e="$3" '
    $0 == e { on = 0 }
    on == 1 { print }
    $0 == b { on = 1 }
  '
}

supervise_escalate() { # $1 id, $2 why — park for a human + surface at the parent
  local id="$1" why="$2" wt
  wt=$(renv_get "$id" WT "")
  journal "$id" SUPERVISE_ESCALATE "$why"
  task_fail "$id" NEEDS_HUMAN "$why — decide in $wt/.loop/docs/decision-requests.md; after deciding: (cd $wt && ./loop.sh approve), then ./loop.sh fleet resume $id"
  {
    echo
    echo "## DR-FLEET-$id"
    echo "- Task: $id ($(renv_get "$id" SUMMARY ""))"
    echo "- Why: $why"
    echo "- Worker's question: $wt/.loop/docs/decision-requests.md"
    echo "- Then: (cd $wt && ./loop.sh approve) && ./loop.sh fleet resume $id"
  } >> .loop/docs/decision-requests.md
  # decision-requests.md is tracked: commit at once so a dirty parent tree never
  # blocks the sibling merges (merge_task defers on uncommitted tracked changes)
  commit_if_changes "fleet: decision request for $id"
}

env_dep_ancestors() { # $1 id -> transitive DEPENDS_ON closure over runs/*.env,
  # space-joined. Enqueue-time validation keeps the graph acyclic; the visited
  # set guards the walk regardless.
  local frontier="$1" next anc="" d dep
  while [ -n "$frontier" ]; do
    next=""
    for d in $frontier; do
      for dep in $(renv_get "$d" DEPENDS_ON "" | tr ',' ' '); do
        case " $anc " in *" $dep "*) ;; *) anc="$anc $dep"; next="$next $dep" ;; esac
      done
    done
    frontier="$next"
  done
  printf '%s' "${anc# }"
}

dep_related() { # $1 id, $2 id — rc 0 when the two tasks sit on one DEPENDS chain
  # (either direction). Chain members legally share a REQ (phased work).
  case " $(env_dep_ancestors "$1") " in *" $2 "*) return 0 ;; esac
  case " $(env_dep_ancestors "$2") " in *" $1 "*) return 0 ;; esac
  return 1
}

fork_join_related() { # $1 owner, $2 anchor, $3 REQ — rc 0 when some live
  # (non-REPLANNED) task owning $3 has BOTH $1 and $2 in its transitive DEPENDS
  # closure: the two are parallel branches of a DECLARED fork whose joining
  # owner completes the REQ — the live-queue mirror of check_req_chains'
  # completing-owner rule. Fail closed: no such join found -> the conflict
  # stands (a join-less parallel co-owner is still illegal).
  local owner="$1" anchor="$2" req="$3" j anc
  for j in $(all_task_ids); do
    [ "$j" = "$owner" ] && continue
    [ "$j" = "$anchor" ] && continue
    case "$(task_qdir "$j")" in
      "") continue ;;
      failed) [ "$(renv_get "$j" RESULT "")" = "REPLANNED" ] && continue ;;
    esac
    case ",$(renv_get "$j" REQS "" | tr -d ' ')," in
      *",$req,"*) ;;
      *) continue ;;
    esac
    anc=" $(env_dep_ancestors "$j") "
    case "$anc" in *" $owner "*)
      case "$anc" in *" $anchor "*) return 0 ;; esac
    esac
  done
  return 1
}

req_owner_elsewhere() { # $1 REQ id, $2 exclude-task, $3 include_done (1|0),
  # $4 chain-ok id (""=none) -> owner id, rc 0 on conflict.
  # cross-fleet REQ uniqueness re-verification: the decompose validator proved it
  # once, but replans/fix-ups mutate ownership later — re-check against the LIVE
  # queue. Failed-but-resumable (non-REPLANNED) tasks still own their REQs.
  # An owner dep-related to $4 is NOT a conflict (phases of one piece of work
  # share REQs), and neither is a parallel branch joined to $4 by a live
  # joining owner (fork_join_related) — the plan validators already proved the
  # completing-owner shape (chain or fork-join).
  local req="$1" excl="$2" incl_done="$3" chain_ok="${4:-}" other qd
  for other in $(all_task_ids); do
    [ "$other" = "$excl" ] && continue
    qd=$(task_qdir "$other")
    case "$qd" in
      "") continue ;;
      done) [ "$incl_done" = "1" ] || continue ;;
      failed) [ "$(renv_get "$other" RESULT "")" = "REPLANNED" ] && continue ;;  # superseded tasks own nothing
    esac
    case ",$(renv_get "$other" REQS "" | tr -d ' ')," in
      *",$req,"*)
        if [ -n "$chain_ok" ]; then
          dep_related "$other" "$chain_ok" && continue
          fork_join_related "$other" "$chain_ok" "$req" && continue
        fi
        echo "$other"; return 0 ;;
    esac
  done
  return 1
}

replan_invalid() { # $1 id, $2 reason — journal the rejection AND expose the
  # reason to the caller (REPLAN_FAIL_REASON): supervise_task folds it into the
  # human-facing escalation, so a budget/validation cause is never masked by a
  # generic "invalid payload" message (the journal alone is easy to miss).
  REPLAN_FAIL_REASON="$2"
  journal "$1" REPLAN_INVALID "$2"
}

block_roots() { # $1 out-dir, $2 "ids" -> block members with NO intra-block DEPENDS
  # (the SOURCE / first-executing phases), space-joined. A carryover seed attaches
  # to the UNIQUE such root so the chain builds FORWARD on the escalated task's
  # committed work: bootstrap_seed_merge merges the seed into the root's fresh
  # worktree at claim, and every later phase branches from that root's merged
  # result. Both carryover paths (supervise_replan, apply_plan_revision) MUST use
  # this — computing sinks here instead delivers the seed to the last phase, where
  # it lands on top of already-redone work and typically conflicts away.
  local out="$1" ids="$2" t dep deps has_intra roots=""
  for t in $ids; do
    has_intra=0
    deps=$(plan_meta "$out" "$t" DEPENDS)
    if [ "$deps" != "-" ]; then
      for dep in $(printf '%s' "$deps" | tr ',' ' '); do
        case " $ids " in *" $dep "*) has_intra=1 ;; esac
      done
    fi
    [ "$has_intra" = 1 ] || roots="$roots $t"
  done
  printf '%s' "${roots# }"
}

block_sinks() { # $1 out-dir, $2 "ids" -> block members NO other member DEPENDS on
  # (the terminal phases), space-joined. The dual of block_roots: used to rewire
  # an external dependent of a replaced task onto the block's tail(s).
  local out="$1" ids="$2" t dep deps referenced="" sinks=""
  for t in $ids; do
    deps=$(plan_meta "$out" "$t" DEPENDS)
    [ "$deps" = "-" ] && continue
    for dep in $(printf '%s' "$deps" | tr ',' ' '); do
      case " $ids " in *" $dep "*) referenced="$referenced $dep" ;; esac
    done
  done
  for t in $ids; do
    case " $referenced " in *" $t "*) ;; *) sinks="$sinks $t" ;; esac
  done
  printf '%s' "${sinks# }"
}

supervise_replan() { # $1 escalated-id, $2 REPLAN block body -> 0 on success.
  # Replacement tasks use the task-plan grammar; their DEPENDS may reference
  # existing tasks AND other replacements in the block (an intra-block chain or
  # fork-join is how one oversized task becomes phases) — but never the escalated
  # task itself (it closes as REPLANNED, which would DEP_FAIL the dependent).
  # The Kahn check inside validate_plan_structure keeps the block acyclic, so a
  # never-claimable cycle still cannot be enqueued.
  local id="$1" block="$2" tmp=.loop/fleet/replan.md out=.loop/fleet/replan-plan
  local ids topo t dep deps total cap n=0 own_reqs new_reqs seen_reqs="" owner known=""
  local roots="" seed=""
  cap=$(fcfg FLEET_MAX_REPLAN_TASKS 6)
  total=$(cat .loop/fleet/replan-count 2>/dev/null || echo 0)
  {
    echo "<!-- TASK-PLAN-BEGIN v1 -->"
    printf '%s\n' "$block"
    echo "<!-- TASK-PLAN-END -->"
  } > "$tmp"
  if ! ids=$(parse_task_plan "$tmp" "$out" 2> .loop/fleet/replan.err | tr '\n' ' '); then
    replan_invalid "$id" "$(head -2 .loop/fleet/replan.err 2>/dev/null | tr '\n' '; ')"
    return 1
  fi
  ids="${ids% }"
  own_reqs=$(renv_get "$id" REQS "")
  for t in $(all_task_ids); do
    [ "$t" = "$id" ] || known="$known $t"
  done
  for t in $ids; do
    n=$((n + 1))
    if [ -n "$(task_qdir "$t")" ] || [ -f "$RUNS_DIR/$t.env" ]; then
      replan_invalid "$id" "replacement id '$t' already exists"
      return 1
    fi
  done
  # structural validation (dep resolution incl. intra-block refs, acyclicity);
  # stdout is the topological enqueue order
  if ! topo=$(validate_plan_structure "$out" "$ids" "" "$(fcfg FLEET_MAX_TASKS 12)" "$known" 2> .loop/fleet/replan.err); then
    replan_invalid "$id" "$(head -2 .loop/fleet/replan.err 2>/dev/null | tr '\n' '; ')"
    return 1
  fi
  topo=$(printf '%s\n' "$topo" | tr '\n' ' '); topo="${topo% }"
  # a DEPENDS on a failed/ task (REPLANNED included) can never be satisfied —
  # deps_state would park the replacement DEP_FAILED at claim time. Reject the
  # payload instead: a stale conversational view of the plan names dead ids
  # (the queue snapshot staged for the call is the live truth).
  for t in $ids; do
    deps=$(plan_meta "$out" "$t" DEPENDS)
    [ "$deps" = "-" ] && continue
    for dep in $(printf '%s' "$deps" | tr ',' ' '); do
      case " $ids " in *" $dep "*) continue ;; esac
      if [ "$(task_qdir "$dep")" = "failed" ]; then
        replan_invalid "$id" "replacement '$t' depends on failed task '$dep' — it would park DEP_FAILED at claim"
        return 1
      fi
    done
  done
  for t in $ids; do
    # replacement scope may not exceed the escalated task's REQ ownership
    if [ -n "$own_reqs" ]; then
      new_reqs=$(plan_meta "$out" "$t" REQS | tr ',' ' ')
      for dep in $new_reqs; do
        case ",$own_reqs," in
          *",$dep,"*) ;;
          *) replan_invalid "$id" "replacement '$t' claims $dep outside the escalated task's REQs ($own_reqs)"
             return 1 ;;
        esac
        # cross-fleet uniqueness: no OTHER live/parked/merged task may own it —
        # except the escalated task's own chain (phased sharing is legal there)
        if owner=$(req_owner_elsewhere "$dep" "$id" 1 "$id"); then
          replan_invalid "$id" "replacement '$t' claims $dep already owned by task '$owner'"
          return 1
        fi
      done
      seen_reqs="$seen_reqs $new_reqs"
    fi
  done
  # union check: the replacements together must own EXACTLY the escalated task's
  # REQs — no gap (a dropped REQ silently exits the plan). Several replacements
  # may share a REQ only with a single completing owner — a chain or an
  # intra-block fork-join (check_req_chains).
  if [ -n "$own_reqs" ]; then
    local own_sorted plan_sorted
    # shellcheck disable=SC2086  # word-split seen_reqs on purpose: one REQ per line
    plan_sorted=$(printf '%s\n' $seen_reqs | grep -v '^$' | sort -u)
    own_sorted=$(printf '%s' "$own_reqs" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$' | sort -u)
    if [ "$plan_sorted" != "$own_sorted" ]; then
      replan_invalid "$id" "replacements do not cover the escalated task's REQs (own: $(printf '%s' "$own_sorted" | tr '\n' ' ')— plan: $(printf '%s' "$plan_sorted" | tr '\n' ' '))"
      return 1
    fi
    if ! check_req_chains "$out" "$ids" "$topo" 2> .loop/fleet/replan.err; then
      replan_invalid "$id" "$(head -2 .loop/fleet/replan.err 2>/dev/null | tr '\n' '; ')"
      return 1
    fi
  fi
  if [ $((total + n)) -gt "$cap" ]; then
    replan_invalid "$id" "replan budget exceeded ($total + $n > FLEET_MAX_REPLAN_TASKS=$cap)"
    return 1
  fi
  # carryover: a healthy NEEDS_DECOMPOSITION split keeps the escalated task's
  # COMMITTED work — seed the block's unique root (the member with no
  # intra-block DEPENDS) with the escalated branch. Read RESULT here: the
  # commit point below overwrites it with REPLANNED.
  if [ "$(renv_get "$id" RESULT "")" = "NEEDS_DECOMPOSITION" ] \
     && [ "$(fcfg FLEET_SPLIT_CARRYOVER 1)" != "0" ]; then
    roots=$(block_roots "$out" "$ids")
    # shellcheck disable=SC2086  # word-split on purpose: count the roots
    set -- $roots
    if [ $# -eq 1 ]; then
      seed="$1"
    else
      # a fork block has 2+ roots: no unambiguous seed target — journal the
      # drop (mirrors apply_plan_revision); the work stays on the branch
      journal "$id" CARRYOVER_SKIPPED "replacement block has no unique root — the carried work remains on loop/$id"
    fi
  fi
  # commit point: close the escalated task as superseded (worktree/branch kept
  # for autopsy per invariant I4), then enqueue the replacements in topo order
  mv -f "$QUEUE_DIR/claimed/$id.md" "$QUEUE_DIR/failed/$id.md" 2>/dev/null || true
  renv_set "$id" PHASE REPLANNED
  renv_set "$id" RESULT REPLANNED
  renv_set "$id" ENDED_AT "$(utcnow)"
  echo $((total + n)) > .loop/fleet/replan-count
  journal "$id" REPLANNED "superseded by: $ids"
  fnote "[$id] superseded by replacement task(s): $ids"
  for t in $topo; do
    enqueue_task_planned "$t" "$out/$t.body" "$out" || {
      replan_invalid "$t" "enqueue failed"
      return 1
    }
  done
  if [ -n "$seed" ]; then
    # honored by bootstrap_worktree when the root is claimed; survives the
    # merge-conflict-redo re-queue (runs/<id>.env is kept), so a re-claim
    # re-attempts the same seed from the new merged HEAD
    renv_set "$seed" SEED_BRANCH "loop/$id"
    journal "$seed" CARRYOVER_PLANNED "will seed from loop/$id (the escalated task's committed work)"
  fi
  replan_rewire_dependents "$id" "$ids" "$out"
  return 0
}

replan_rewire_dependents() { # $1 replanned id, $2 "block ids", $3 out-dir.
  # Unclaimed dependents of a REPLANNED task would otherwise cascade DEP_FAILED
  # (deps_state sees failed/) even though its scope lives on in the replacements.
  # Point them at the block's sinks (members no other member depends on) instead.
  # Only new/ tasks can hold such a dep: claiming requires the dep to be MERGED,
  # and merged tasks never escalate.
  local id="$1" ids="$2" out="$3" dep deps sinks="" d new_deps x
  sinks=$(block_sinks "$out" "$ids")
  [ -n "$sinks" ] || return 0
  for d in $(tasks_in new); do
    deps=$(renv_get "$d" DEPENDS_ON "")
    case ",$(printf '%s' "$deps" | tr -d ' ')," in
      *",$id,"*) ;;
      *) continue ;;
    esac
    new_deps=""
    for dep in $(printf '%s' "$deps" | tr ', ' '  '); do
      [ -n "$dep" ] || continue
      [ "$dep" = "$id" ] && dep="$sinks"
      for x in $dep; do
        case ",$new_deps," in *",$x,"*) ;; *) new_deps="${new_deps:+$new_deps,}$x" ;; esac
      done
    done
    renv_set "$d" DEPENDS_ON "$new_deps"
    journal "$d" DEPS_REWIRED "dependency $id was replanned — now depends on: $new_deps"
    fnote "[$d] dependency $id replanned — rewired to: $new_deps"
  done
}

supervise_task() { # $1 id — ONE supervisor decision for a SUPERVISE_PENDING task
  local id="$1" n cap res="" verdict="" guidance replan wt prompt label
  cap=$(fcfg FLEET_MAX_SUPERVISE_PER_TASK 2)
  n=$(renv_get "$id" SUPERVISE_COUNT 0)
  wt=$(renv_get "$id" WT "")
  if [ "$n" -ge "$cap" ]; then
    supervise_escalate "$id" "supervisor intervention cap reached ($n/$cap)"
    return 0
  fi
  stage_supervise_inputs "$id"
  fnote "[$id] supervisor deciding (/loop-supervise, $MODEL_SUPERVISE, read-only)"
  label="supervise-$id-$((n + 1))"
  prompt="/loop-supervise task=$id"
  for _ in 1 2; do   # retry once on launch failure OR unparseable verdict
    if run_claude_supervisor "$label" "$prompt"; then
      res=$(agent_result "$label")
      verdict=$(extract_verdict "$res" "SUPERVISE: (ANSWER|REPLAN|ESCALATE)")
      [ -z "$verdict" ] || break
      supervisor_session_drop   # a protocol miss taints the conversation — retry fresh
      prompt="/loop-supervise task=$id (FORMAT REMINDER: the LAST line must be exactly 'SUPERVISE: ANSWER <summary>', 'SUPERVISE: REPLAN <summary>' or 'SUPERVISE: ESCALATE <question>'; ANSWER carries a GUIDANCE-BEGIN/GUIDANCE-END block, REPLAN a REPLAN-BEGIN/REPLAN-END block.)"
    fi
  done
  renv_set "$id" SUPERVISE_COUNT $((n + 1))
  case "$verdict" in
    "SUPERVISE: ANSWER"*)
      guidance=$(extract_between "$res" "GUIDANCE-BEGIN" "GUIDANCE-END")
      if [ -z "$guidance" ]; then
        supervise_escalate "$id" "ANSWER verdict without a GUIDANCE block (fail closed)"
        return 0
      fi
      {
        echo "# Supervisor guidance (decided within the approved master contract)"
        echo "# Treat as the human decision for the pending decision request."
        echo
        printf '%s\n' "$guidance"
      } > "$wt/.loop/supervisor-guidance.md"
      journal "$id" SUPERVISE_ANSWER "$(printf '%s' "$guidance" | tr '\n' ' ' | cut -c1-500)"
      renv_set "$id" PHASE APPROVED   # relaunched next tick; docs+git carry memory
      fnote "[$id] supervisor answered — task relaunches with the guidance"
      ;;
    "SUPERVISE: REPLAN"*)
      replan=$(extract_between "$res" "REPLAN-BEGIN" "REPLAN-END")
      REPLAN_FAIL_REASON=""
      if [ -z "$replan" ]; then
        supervise_escalate "$id" "REPLAN verdict without a REPLAN-BEGIN/END block (fail closed)"
      elif ! supervise_replan "$id" "$replan"; then
        supervise_escalate "$id" "REPLAN rejected: ${REPLAN_FAIL_REASON:-malformed payload} (fail closed)"
      else
        # applied plan mutation: the session's conversational view of the
        # task-plan/queue is now stale — rotate (files are the truth)
        supervisor_session_drop
      fi
      ;;
    *)
      supervisor_session_drop
      supervise_escalate "$id" "${verdict:-no parseable SUPERVISE verdict after a format-reminder retry}"
      ;;
  esac
}

# ---------- phase-boundary plan-review (chained workflows) ----------
# When a task with queued dependents merges, reality is now known: a read-only
# supervisor call re-judges the QUEUED remainder of the plan (KEEP / REVISE
# unclaimed tasks / ESCALATE to the human). deps_state holds the dependents
# until the review resolves; the marker in runs/<id>.env survives crashes.

stage_plan_review_inputs() { # $1 merged id — deterministic input set for the
  # read-only call: the merged phase's archived contract+evidence plus a queue
  # snapshot (revisable new/ tasks with bodies; claimed tasks marked untouchable)
  local id="$1" dst
  dst=".loop/supervise/plan-review/$id"
  rm -rf "$dst"
  mkdir -p "$dst"
  cp ".loop/docs/run-archive/$id/product-contract.md" "$dst/merged-task-contract.md" 2>/dev/null || true
  cp ".loop/docs/run-archive/$id/evidence-report.md" "$dst/merged-task-evidence.md" 2>/dev/null || true
  write_queue_snapshot "$dst/queue-snapshot.md"
}

apply_plan_revision() { # $1 merged id (context), $2 REPLAN block body -> 0 applied.
  # Deterministic validation of a plan-review REVISE. The block implicitly
  # targets the QUEUED tasks whose REQ sets its REQ union covers (R):
  #   - every owner of a block REQ must be in new/ (or done/ — completed chain
  #     phases legitimately share, or REPLANNED — owns nothing); a claimed or
  #     parked-failed owner rejects the revision
  #   - the block's REQ union must EXACTLY equal R's REQ union (REQ-conserving)
  #   - intra-block DEPENDS are validated (resolution + Kahn) with all
  #     non-replaced ids as external deps; shared REQs need a completing owner
  #     (chain or fork-join, check_req_chains)
  #   - no surviving queued task may depend on a replaced one (the supervisor
  #     must include such dependents in the block)
  local mid="$1" block="$2" tmp=.loop/fleet/plan-review.md out=.loop/fleet/plan-review-plan
  local ids topo t dep req d owner known="" block_reqs="" r_ids="" r_reqs=""
  local live=0 rn=0 bn=0 cap seed="" s roots="" deps
  {
    echo "<!-- TASK-PLAN-BEGIN v1 -->"
    printf '%s\n' "$block"
    echo "<!-- TASK-PLAN-END -->"
  } > "$tmp"
  if ! ids=$(parse_task_plan "$tmp" "$out" 2> .loop/fleet/plan-review.err | tr '\n' ' '); then
    journal "$mid" PLAN_REVIEW_INVALID "$(head -2 .loop/fleet/plan-review.err 2>/dev/null | tr '\n' '; ')"
    return 1
  fi
  ids="${ids% }"
  for t in $ids; do
    bn=$((bn + 1))
    if [ -n "$(task_qdir "$t")" ] || [ -f "$RUNS_DIR/$t.env" ]; then
      journal "$mid" PLAN_REVIEW_INVALID "replacement id '$t' already exists"
      return 1
    fi
    block_reqs="$block_reqs $(plan_meta "$out" "$t" REQS | tr ',' ' ')"
  done
  if [ "$bn" -gt "$(fcfg FLEET_MAX_REPLAN_TASKS 6)" ]; then
    journal "$mid" PLAN_REVIEW_INVALID "revision block has $bn tasks > FLEET_MAX_REPLAN_TASKS=$(fcfg FLEET_MAX_REPLAN_TASKS 6)"
    return 1
  fi
  # resolve R (the replaced set) from the block's REQ union
  # shellcheck disable=SC2086  # word-split on purpose: one REQ per line
  for req in $(printf '%s\n' $block_reqs | grep -v '^$' | sort -u); do
    for d in $(all_task_ids); do
      case ",$(renv_get "$d" REQS "" | tr -d ' ')," in
        *",$req,"*)
          case "$(task_qdir "$d")" in
            new) case " $r_ids " in *" $d "*) ;; *) r_ids="$r_ids $d" ;; esac ;;
            "done") ;;   # a completed chain phase legitimately shares the REQ
            failed)
              [ "$(renv_get "$d" RESULT "")" = "REPLANNED" ] || {
                journal "$mid" PLAN_REVIEW_INVALID "REQ $req belongs to parked task '$d' — not revisable"
                return 1
              } ;;
            *)
              journal "$mid" PLAN_REVIEW_INVALID "REQ $req belongs to claimed task '$d' — a revision may only touch unclaimed tasks"
              return 1 ;;
          esac ;;
      esac
    done
  done
  r_ids="${r_ids# }"
  if [ -z "$r_ids" ]; then
    journal "$mid" PLAN_REVIEW_INVALID "the revision's REQs match no queued task — nothing to replace"
    return 1
  fi
  for d in $r_ids; do
    rn=$((rn + 1))
    r_reqs="$r_reqs $(renv_get "$d" REQS "" | tr ',' ' ')"
  done
  # REQ conservation: block union == union of the replaced queued tasks' REQs
  # shellcheck disable=SC2086  # word-split on purpose: one REQ per line
  if [ "$(printf '%s\n' $block_reqs | grep -v '^$' | sort -u)" != "$(printf '%s\n' $r_reqs | grep -v '^$' | sort -u)" ]; then
    journal "$mid" PLAN_REVIEW_INVALID "revision does not conserve the replaced tasks' REQ union (replaced:$r_ids)"
    return 1
  fi
  # no surviving queued task may depend on a replaced one
  for d in $(tasks_in new); do
    case " $r_ids " in *" $d "*) continue ;; esac
    for dep in $(renv_get "$d" DEPENDS_ON "" | tr ',' ' '); do
      case " $r_ids " in
        *" $dep "*)
          journal "$mid" PLAN_REVIEW_INVALID "queued task '$d' depends on replaced task '$dep' — include it in the revision"
          return 1 ;;
      esac
    done
  done
  # structural validation; external deps = every existing id except R
  for d in $(all_task_ids); do
    case " $r_ids " in *" $d "*) ;; *) known="$known $d" ;; esac
  done
  if ! topo=$(validate_plan_structure "$out" "$ids" "" "$(fcfg FLEET_MAX_TASKS 12)" "$known" 2> .loop/fleet/plan-review.err); then
    journal "$mid" PLAN_REVIEW_INVALID "$(head -2 .loop/fleet/plan-review.err 2>/dev/null | tr '\n' '; ')"
    return 1
  fi
  topo=$(printf '%s\n' "$topo" | tr '\n' ' '); topo="${topo% }"
  # a DEPENDS on a failed/ task can never be satisfied (deps_state -> DEP_FAILED
  # at claim); reject the revision instead of enqueueing a dead-on-arrival task
  for t in $ids; do
    deps=$(plan_meta "$out" "$t" DEPENDS)
    [ "$deps" = "-" ] && continue
    for dep in $(printf '%s' "$deps" | tr ',' ' '); do
      case " $ids " in *" $dep "*) continue ;; esac
      if [ "$(task_qdir "$dep")" = "failed" ]; then
        journal "$mid" PLAN_REVIEW_INVALID "revision task '$t' depends on failed task '$dep' — it would park DEP_FAILED at claim"
        return 1
      fi
    done
  done
  if ! check_req_chains "$out" "$ids" "$topo" 2> .loop/fleet/plan-review.err; then
    journal "$mid" PLAN_REVIEW_INVALID "$(head -2 .loop/fleet/plan-review.err 2>/dev/null | tr '\n' '; ')"
    return 1
  fi
  # queue-size cap after the swap
  for d in $(tasks_in new) $(tasks_in claimed); do live=$((live + 1)); done
  cap=$(fcfg FLEET_MAX_TASKS 12)
  if [ $((live - rn + bn)) -gt "$cap" ]; then
    journal "$mid" PLAN_REVIEW_INVALID "revision would put $((live - rn + bn)) tasks in flight > FLEET_MAX_TASKS=$cap"
    return 1
  fi
  # preserve a pending carryover: a replaced-but-unclaimed chain root may hold
  # SEED_BRANCH — move it to the block's unique root (the work lives on that
  # branch either way; without a unique root the seed is dropped, journaled)
  for d in $r_ids; do
    s=$(renv_get "$d" SEED_BRANCH "")
    [ -n "$s" ] && seed="$s"
  done
  if [ -n "$seed" ]; then
    # the seed must land on the block's SOURCE (first-executing) root so the
    # chain builds forward on it — same rule as supervise_replan. (This block
    # previously computed sinks here and seeded the LAST phase, which delivered
    # the carried work on top of already-redone earlier phases.)
    roots=$(block_roots "$out" "$ids")
    # shellcheck disable=SC2086  # word-split on purpose: count the roots
    set -- $roots
    if [ $# -ne 1 ]; then
      journal "$mid" CARRYOVER_SKIPPED "revision has no unique root — the carried work remains on $seed"
      seed=""
    else
      roots="$1"
    fi
  fi
  # commit point: close R as superseded, then enqueue the block in topo order
  for d in $r_ids; do
    mv -f "$QUEUE_DIR/new/$d.md" "$QUEUE_DIR/failed/$d.md" 2>/dev/null || true
    renv_set "$d" PHASE REPLANNED
    renv_set "$d" RESULT REPLANNED
    renv_set "$d" ENDED_AT "$(utcnow)"
    journal "$d" REPLANNED "superseded by plan-review after '$mid' merged: $ids"
  done
  for t in $topo; do
    enqueue_task_planned "$t" "$out/$t.body" "$out" || {
      journal "$t" PLAN_REVIEW_INVALID "enqueue failed"
      return 1
    }
  done
  if [ -n "$seed" ]; then
    renv_set "$roots" SEED_BRANCH "$seed"
    journal "$roots" CARRYOVER_PLANNED "will seed from $seed (moved from a replaced task)"
  fi
  fnote "plan-review: replaced [$r_ids] with: $ids"
  return 0
}

plan_review_task() { # $1 merged id — ONE plan-review decision at a phase boundary
  local id="$1" res="" verdict="" block prompt label rounds cap
  cap=$(fcfg FLEET_MAX_PLAN_REVISIONS 4)
  rounds=$(cat .loop/fleet/plan-review-count 2>/dev/null || echo 0)
  if [ "$rounds" -ge "$cap" ]; then
    # deterministic: no call is spent past the cap — the approved plan continues
    renv_set "$id" PLAN_REVIEW DONE
    journal "$id" PLAN_REVIEW_CAPPED "revision rounds exhausted ($rounds/$cap) — keeping the queued plan"
    return 0
  fi
  stage_plan_review_inputs "$id"
  fnote "[$id] phase boundary — plan-review (/loop-supervise mode=plan-review, $MODEL_SUPERVISE, read-only)"
  label="plan-review-$id"
  prompt="/loop-supervise mode=plan-review merged=$id"
  for _ in 1 2; do   # retry once on launch failure OR unparseable verdict
    if run_claude_supervisor "$label" "$prompt"; then
      res=$(agent_result "$label")
      verdict=$(extract_verdict "$res" "PLAN-REVIEW: (KEEP|REVISE|ESCALATE)")
      [ -z "$verdict" ] || break
      supervisor_session_drop   # a protocol miss taints the conversation — retry fresh
      prompt="/loop-supervise mode=plan-review merged=$id (FORMAT REMINDER: the LAST line must be exactly 'PLAN-REVIEW: KEEP <reason>', 'PLAN-REVIEW: REVISE <summary>' or 'PLAN-REVIEW: ESCALATE <question>'; REVISE carries a REPLAN-BEGIN/REPLAN-END block of TASK blocks.)"
    fi
  done
  case "$verdict" in
    "PLAN-REVIEW: KEEP"*)
      renv_set "$id" PLAN_REVIEW DONE
      journal "$id" PLAN_REVIEW_KEEP "$(printf '%s' "${verdict#PLAN-REVIEW: KEEP}" | cut -c1-300)"
      ;;
    "PLAN-REVIEW: REVISE"*)
      block=$(extract_between "$res" "REPLAN-BEGIN" "REPLAN-END")
      if [ -n "$block" ] && apply_plan_revision "$id" "$block"; then
        echo $((rounds + 1)) > .loop/fleet/plan-review-count
        renv_set "$id" PLAN_REVIEW DONE
        journal "$id" PLAN_REVIEW_REVISED "queued phases revised after '$id' merged"
        supervisor_session_drop   # applied plan mutation — rotate the session
      else
        # a refused MUTATION must not stop the fleet (contrast supervise_task,
        # where the escalated TASK is stuck): degrade to KEEP, journaled
        renv_set "$id" PLAN_REVIEW DONE
        journal "$id" PLAN_REVIEW_INVALID "REVISE payload rejected — continuing with the queued plan"
        fnote "[$id] plan-review REVISE rejected by the validators — queued plan continues"
      fi
      ;;
    "PLAN-REVIEW: ESCALATE"*)
      renv_set "$id" PLAN_REVIEW ESCALATED
      journal "$id" PLAN_REVIEW_ESCALATE "$(printf '%s' "${verdict#PLAN-REVIEW: ESCALATE}" | cut -c1-300)"
      {
        echo
        echo "## DR-FLEET-PLAN-$id"
        echo "- After merging phase '$id', the supervisor flagged a plan-level question only a human can answer:"
        echo "- ${verdict#PLAN-REVIEW: ESCALATE }"
        echo "- Queued phases are HELD until this is decided."
        echo "- Decide (edit/clean the queue if needed: ./loop.sh fleet status), then release the"
        echo "  held phases: ./loop.sh fleet ack-plan $id — and resume: ./loop.sh run"
        echo "- Rerunning without the ack stops at this same request (never a silent release)."
      } >> .loop/docs/decision-requests.md
      commit_if_changes "fleet: plan-review decision request for $id"
      fnote "[$id] plan-review escalated — queued phases held (release: ./loop.sh fleet ack-plan $id)"
      ;;
    *)
      # advisory checkpoint: liveness wins — treat as KEEP, journaled
      renv_set "$id" PLAN_REVIEW DONE
      journal "$id" PLAN_REVIEW_ERROR "${verdict:-no parseable PLAN-REVIEW verdict after a format-reminder retry} — treated as KEEP"
      supervisor_session_drop
      ;;
  esac
}

# ---------- serial merge (Refinery pattern: one landing at a time, in-process) ----------

unique_archive_dir() { # $1 wanted path -> echoes $1, or $1-2/-3... if already taken.
  # Second-resolution archive names collide (two resets in one second, a fleet
  # slug reused across runs) and `mkdir -p` + conditional copies would silently
  # merge old and new evidence into one hybrid dir — always publish to a name
  # nobody holds.
  local d="$1" n=2
  while [ -e "$d" ]; do d="$1-$n"; n=$((n + 1)); done
  printf '%s' "$d"
}

verify_archived_manifest() { # $1 archive dir -> 0 when every manifest row's artifact
  # bytes exist under <dir>/observations/ and hash-match its artifact_sha256.
  # Manifest bytes are preserved verbatim on archive (rows keep the live
  # `.loop/observations/<rel>` paths; rewriting them would break certificate
  # hashes) — consumers resolve rows against the archive root, and this check
  # applies that same resolution as an integrity gate. Absent/empty manifest =
  # nothing to verify. Sets ARCHIVE_MANIFEST_PROBLEM on failure.
  ARCHIVE_MANIFEST_PROBLEM=""
  local dir="$1" pairs path sha rel actual
  [ -s "$dir/observations-manifest.jsonl" ] || return 0
  pairs=$(awk '
    index($0, "\"artifact_path\":\"") && index($0, "\"artifact_sha256\":\"") {
      p=$0; sub(/^.*"artifact_path":"/, "", p); sub(/".*/, "", p)
      s=$0; sub(/^.*"artifact_sha256":"/, "", s); sub(/".*/, "", s)
      if (p != "" && s != "") print p "\t" s
    }' "$dir/observations-manifest.jsonl" 2>/dev/null) \
    || { ARCHIVE_MANIFEST_PROBLEM="unreadable archived manifest"; return 1; }
  while IFS=$'\t' read -r path sha; do
    [ -n "$path" ] || continue
    rel="${path#.loop/observations/}"
    if [ "$rel" = "$path" ] || [ -z "$rel" ]; then
      ARCHIVE_MANIFEST_PROBLEM="non-canonical manifest artifact path: $path"; return 1
    fi
    case "/$rel/" in
      *"/../"*|*"//"*) ARCHIVE_MANIFEST_PROBLEM="unsafe manifest artifact path: $path"; return 1 ;;
    esac
    if [ -L "$dir/observations/$rel" ] || [ ! -f "$dir/observations/$rel" ] \
       || [ ! -r "$dir/observations/$rel" ]; then
      ARCHIVE_MANIFEST_PROBLEM="archived observation missing, unreadable, or a symlink: $rel"; return 1
    fi
    actual=$(sha256 < "$dir/observations/$rel") || actual=""
    if [ -z "$actual" ] || [ "$actual" != "$sha" ]; then
      ARCHIVE_MANIFEST_PROBLEM="archived observation does not match its manifest hash: $rel"; return 1
    fi
  done <<EOF
$pairs
EOF
  return 0
}

archive_worker_docs() { # $1 id, $2 worktree — build, verify, atomically publish
  # .loop/docs/run-archive/<id>/, fail CLOSED (any I/O failure returns 1; the
  # caller must abort the merge — the integration gate certifies against this
  # evidence, so an incomplete archive must never ride a merge into done/).
  # merge_task runs in a `||` list, so set -e is inert here: every step is
  # explicitly checked. A pre-existing archive under this reusable fleet id
  # (an earlier orchestration's part-a) is retired to <id>-superseded-<ts>
  # first: readers of run-archive/<id> (plan review, the integration-gate
  # reviewer, the evidence bundle) must only ever see THIS run's evidence,
  # never a hybrid — retired copies stay browsable for lesson carryover.
  ARCHIVE_PROBLEM=""
  ARCHIVE_SUPERSEDED=""
  local id="$1" wt="$2" dst tmp f ts
  dst=".loop/docs/run-archive/$id"
  tmp=".loop/docs/run-archive/.tmp-$id.$$"
  rm -rf "$tmp" 2>/dev/null || true
  mkdir -p "$tmp" || { ARCHIVE_PROBLEM="cannot create staging dir $tmp"; return 1; }
  # the worker's assumptions ledger + drift report: parent .loop/docs is reset to
  # the master's every merge, so these per-phase records survive ONLY here. The
  # integration-gate reviewer reads the archived assumptions to catch cross-task
  # conflicts (loop-review gate mode); the drift report is the audit trail behind
  # a drift-triggered plan-review. The per-task checklist is archived because the
  # ROOT checklist's statuses are never maintained during a fleet run.
  for f in product-contract.md evidence-report.md assumptions.md \
           spec-drift-report.md acceptance-checklist.md certification.json; do
    [ -f "$wt/.loop/docs/$f" ] || continue
    cp "$wt/.loop/docs/$f" "$tmp/$f" \
      || { ARCHIVE_PROBLEM="cannot copy $f"; rm -rf "$tmp"; return 1; }
  done
  if [ -f "$wt/.loop/task-id" ]; then
    cp "$wt/.loop/task-id" "$tmp/task-id" \
      || { ARCHIVE_PROBLEM="cannot copy task-id"; rm -rf "$tmp"; return 1; }
  fi
  if [ -d "$wt/.loop/observations" ]; then
    cp -R "$wt/.loop/observations" "$tmp/observations" \
      || { ARCHIVE_PROBLEM="cannot copy observations"; rm -rf "$tmp"; return 1; }
    if [ -n "$(find "$tmp/observations" -type l 2>/dev/null | head -1)" ]; then
      ARCHIVE_PROBLEM="observations contain symlinks"; rm -rf "$tmp"; return 1
    fi
  fi
  if [ -s "$wt/.loop/observations-manifest.jsonl" ]; then
    compact_observations_manifest "$wt/.loop/observations-manifest.jsonl" \
        "$tmp/observations-manifest.jsonl" \
      || { ARCHIVE_PROBLEM="cannot compact the observations manifest"; rm -rf "$tmp"; return 1; }
    verify_archived_manifest "$tmp" \
      || { ARCHIVE_PROBLEM="$ARCHIVE_MANIFEST_PROBLEM"; rm -rf "$tmp"; return 1; }
  fi
  if [ -e "$dst" ]; then
    ts=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || echo archive)
    ARCHIVE_SUPERSEDED=$(unique_archive_dir "$dst-superseded-$ts")
    mv "$dst" "$ARCHIVE_SUPERSEDED" \
      || { ARCHIVE_PROBLEM="cannot retire the previous archive at $dst"; ARCHIVE_SUPERSEDED=""; rm -rf "$tmp"; return 1; }
  fi
  mv "$tmp" "$dst" || { ARCHIVE_PROBLEM="cannot publish $dst"; rm -rf "$tmp"; return 1; }
  return 0
}

merge_task() { # $1 id — parent tracked tree must be clean; defers (rc 1) if not
  local id="$1" branch wt summary added conflicts f merge_rc=0 mlog
  branch=$(renv_get "$id" BRANCH)
  wt=$(renv_get "$id" WT)
  summary=$(renv_get "$id" SUMMARY "$id")
  mlog="$RUNS_DIR/$id/merge.log"
  # untracked files are allowed (merge refuses by itself if one is in the way);
  # uncommitted TRACKED changes mean a human is mid-edit — never merge over them
  if [ -n "$(git status --porcelain -uno)" ]; then
    if [ "$LAST_DEFER_NOTE" != "$id" ]; then
      fnote "[$id] merge deferred — parent has uncommitted changes (commit or stash first)"
      LAST_DEFER_NOTE="$id"
    fi
    return 1
  fi
  LAST_DEFER_NOTE=""
  # phase-boundary plan-review marker: written BEFORE the merge commit, so a
  # crash between the commit and the marker can never skip the review. The
  # marker is only consulted for done/ tasks — on any non-merge outcome
  # (conflict redo, refusal) it is inert until the task eventually merges.
  # Armed when this merged phase has queued dependents (build-on-me boundary),
  # OR — with FLEET_PLAN_REVIEW_ON_DRIFT — when it recorded drift and other
  # queued PLANNED work remains (so an INDEPENDENT phase's drift can still
  # re-plan the remainder, not only a dependency merge).
  if [ "$(fcfg FLEET_PLAN_REVIEW 1)" != "0" ] && [ "$(fcfg FLEET_SUPERVISE 1)" != "0" ] \
     && [ "$(renv_get "$id" PLANNED 0)" = "1" ] \
     && { task_has_queued_dependents "$id" \
          || { [ "$(fcfg FLEET_PLAN_REVIEW_ON_DRIFT 1)" != "0" ] \
               && merged_task_recorded_drift "$id" && any_queued_planned; }; }; then
    renv_set "$id" PLAN_REVIEW PENDING
  fi
  journal "$id" MERGE_START "$branch"
  mkdir -p "$RUNS_DIR/$id"
  git merge --no-ff --no-commit "$branch" > "$mlog" 2>&1 || merge_rc=$?
  if [ "$merge_rc" -ne 0 ] && ! git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    # merge refused outright (e.g. an untracked file would be overwritten):
    # nothing was staged, so this must NOT fall through to the commit path
    git merge --abort >/dev/null 2>&1 || true
    task_fail "$id" MERGE_FAILED "git merge refused: $(tail -2 "$mlog" | tr '\n' ' ')"
    return 0
  fi

  # .loop/docs is rewritten by EVERY run (contract/plan/progress), so collisions
  # there are structural noise: always keep the parent's docs, and archive the
  # run's contract + evidence as the tracked audit trail instead
  git checkout HEAD -- .loop/docs 2>/dev/null || true
  added=$(git diff --cached --name-only --diff-filter=A -- .loop/docs 2>/dev/null || true)
  if [ -n "$added" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && git rm -qf "$f" >/dev/null 2>&1 || true
    done <<EOF
$added
EOF
  fi

  conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
  if [ -n "$conflicts" ]; then
    git merge --abort 2>/dev/null || git reset --hard HEAD >/dev/null 2>&1
    if [ "$(renv_get "$id" PLANNED 0)" = "1" ] && [ "$(fcfg FLEET_SUPERVISE 1)" != "0" ] \
       && [ "$(renv_get "$id" MERGE_RETRIES 0)" = "0" ]; then
      # orchestrated tasks get ONE redo from the merged HEAD (the merge-queue
      # rebase-and-retry pattern): the new worktree then CONTAINS the sibling
      # work it conflicted with, so the conflict dissolves structurally. The
      # conflicting branch is archived (renamed) for autopsy — deleting it
      # would lose the work, keeping the name would block the re-claim's
      # `git worktree add -b`. A second conflict goes to a human, same as any
      # manual task.
      git worktree remove --force "$wt" >/dev/null 2>&1 || true
      git worktree prune 2>/dev/null || true
      git branch -m "$branch" "$branch-conflict-1" 2>/dev/null || true
      renv_set "$id" MERGE_RETRIES 1
      renv_set "$id" PHASE queued
      renv_set "$id" RESULT ""
      # PLAN_REVIEW is armed BEFORE the merge attempt; a redo discards that attempt,
      # so clear the marker and let the eventual successful merge re-derive it from
      # the redo's own drift/queue state (else a stale PENDING could fire a review
      # the redo no longer warrants).
      renv_set "$id" PLAN_REVIEW ""
      mv -f "$QUEUE_DIR/claimed/$id.md" "$QUEUE_DIR/new/$id.md" 2>/dev/null || true
      journal "$id" MERGE_CONFLICT_REDO "conflicts: $(echo "$conflicts" | tr '\n' ' ')— branch archived as $branch-conflict-1; re-running once from the merged HEAD"
      fnote "[$id] merge conflict — redoing once from the merged HEAD (conflicting branch archived: $branch-conflict-1)"
      return 0
    fi
    task_fail "$id" MERGE_CONFLICT "conflicts: $(echo "$conflicts" | tr '\n' ' ')(branch $branch kept — merge by hand, or rework the task)"
    return 0
  fi

  if ! archive_worker_docs "$id" "$wt"; then
    # fail CLOSED: an incomplete or unverifiable evidence archive must never
    # ride a merge into done/ — the integration gate certifies against it
    # (same unwind as the commit-failure path below; the branch is kept)
    git merge --abort 2>/dev/null || git reset --hard HEAD >/dev/null 2>&1
    task_fail "$id" MERGE_FAILED "worker evidence archive failed: ${ARCHIVE_PROBLEM:-unknown} (branch $branch kept — fix the cause, then ./loop.sh fleet merge $id, or rework the task)"
    return 0
  fi
  # shellcheck disable=SC2086  # ARCHIVE_SUPERSEDED is a single path or empty
  if ! git add -- ".loop/docs/run-archive/$id" ${ARCHIVE_SUPERSEDED:+"$ARCHIVE_SUPERSEDED"} 2>>"$mlog"; then
    git merge --abort 2>/dev/null || git reset --hard HEAD >/dev/null 2>&1
    task_fail "$id" MERGE_FAILED "could not stage the worker evidence archive: $(tail -1 "$mlog" | tr '\n' ' ')(branch $branch kept)"
    return 0
  fi

  if git diff --cached --quiet 2>/dev/null; then
    git merge --abort 2>/dev/null || true
    task_done "$id" "no changes to merge"
    return 0
  fi
  if ! git commit -q -m "fleet: merge $id — $summary" >> "$mlog" 2>&1; then
    # a commit hook / signing failure here must NOT fall through to task_done:
    # that would report "merged" with nothing committed, leave the parent stuck
    # mid-merge, and invite a `clean` that deletes the only copy of the work
    git merge --abort 2>/dev/null || git reset --hard HEAD >/dev/null 2>&1
    task_fail "$id" MERGE_FAILED "merge commit failed (hook? signing?): $(tail -2 "$mlog" | tr '\n' ' ')(branch $branch kept)"
    return 0
  fi
  renv_set "$id" MERGED_AT "$(utcnow)"
  task_done "$id" "merged ($branch) — clean up when ready: ./loop.sh fleet clean $id"
}

# ---------- mutual awareness: each agent is told what runs beside it ----------
# Layer 1 is structural (worktrees: other tasks' changes don't exist in this
# tree). Layer 2 is this file, regenerated every tick and read by the
# loop-iterate / loop-plan / loop-contract skills.

write_parallel_context() {
  local id other wt qd found
  for id in $(tasks_in claimed); do
    wt=$(renv_get "$id" WT "")
    [ -n "$wt" ] && [ -d "$wt/.loop" ] || continue
    {
      echo "# Parallel loops in this project (generated by the fleet supervisor — do not edit)"
      echo
      echo "This worktree runs ONE task: $(renv_get "$id" SUMMARY "$id")"
      echo "(branch $(renv_get "$id" BRANCH "")). The sibling tasks below live in"
      echo "their own isolated worktrees/branches. NONE of their changes exist in"
      echo "this tree (not even the already-merged ones — this tree branched off"
      echo "earlier); the supervisor integrates every task separately."
      echo
      echo "Rules:"
      echo "- Work ONLY on this worktree's task. Never implement, 'fix', or revert"
      echo "  anything that belongs to another task's scope — including re-doing"
      echo "  work a merged or paused sibling already owns."
      echo "- If something looks missing, unfamiliar, or half-done, do NOT repair"
      echo "  or remove it — another task may own it. Note it in progress.md instead."
      echo
      echo "## Sibling tasks"
      found=0
      for other in $(all_task_ids); do
        [ "$other" = "$id" ] && continue
        found=1
        qd=$(task_qdir "$other")
        case "$qd" in
          claimed) echo "- [running: $(renv_get "$other" PHASE "")] $other — branch $(renv_get "$other" BRANCH "-"): $(renv_get "$other" SUMMARY "")" ;;
          new)     echo "- [queued] $other: $(renv_get "$other" SUMMARY "")" ;;
          "done")  echo "- [merged — not in your tree; do not re-implement] $other: $(renv_get "$other" SUMMARY "")" ;;
          failed)  echo "- [paused: $(renv_get "$other" RESULT "?")] $other — its worktree/branch still owns its scope: $(renv_get "$other" SUMMARY "")" ;;
        esac
      done
      [ "$found" = 1 ] || echo "- (none right now)"
    } > "$wt/.loop/.parallel-context.md.tmp.$$" 2>/dev/null \
      && mv -f "$wt/.loop/.parallel-context.md.tmp.$$" "$wt/.loop/parallel-context.md" 2>/dev/null \
      || rm -f "$wt/.loop/.parallel-context.md.tmp.$$" 2>/dev/null || true   # wt vanished mid-tick: not fatal
  done
}

# ---------- the dispatch loop ----------

active_slots() { # live claude-bearing children (contract gen or run)
  local id n=0
  for id in $(tasks_in claimed); do
    case "$(renv_get "$id" PHASE)" in
      CONTRACT_GEN|RUNNING) task_pid_alive "$id" && n=$((n + 1)) ;;
    esac
  done
  echo "$n"
}

tick() {
  local id phase
  beat   # aliveness heartbeat: refreshed every tick and around blocking calls
  # 1. reap children that finished
  for id in $(tasks_in claimed); do
    case "$(renv_get "$id" PHASE)" in
      CONTRACT_GEN|RUNNING) task_pid_alive "$id" || reap_task "$id" ;;
    esac
  done
  # 2. contracts that became ready: auto-approve or hand to the human
  for id in $(tasks_in claimed); do
    [ "$(renv_get "$id" PHASE)" = "CONTRACT_READY" ] || continue
    if [ "$AUTO_MODE" = "1" ] || [ "$(renv_get "$id" AUTO 0)" = "1" ]; then
      beat   # the synchronous contract review below can block for a while
      if ! master_intact "$id"; then
        # tampered master context: never approve unattended on top of it
        renv_set "$id" PHASE PENDING_APPROVAL
        journal "$id" PENDING_APPROVAL "master-contract tamper — demoted to human approval"
      elif ! contract_review_ok "$id"; then
        if [ "$(renv_get "$id" PLANNED 0)" = "1" ] && [ "$(renv_get "$id" CONTRACT_RETRIES 0)" = "0" ]; then
          # orchestrated tasks get ONE self-repair round: regenerate the
          # sub-contract against the reviewer feedback (the worktree's headless
          # contract path folds .loop/contract-review-feedback.md in), then a
          # second refusal goes to a human like any other task.
          renv_set "$id" CONTRACT_RETRIES 1
          journal "$id" CONTRACT_REGEN "sub-contract regenerating once against reviewer feedback"
          fnote "[$id] sub-contract review refused — regenerating once against the feedback"
          start_contract_gen "$id"
        else
          renv_set "$id" PHASE PENDING_APPROVAL
          journal "$id" CONTRACT_REVIEW_REFUSED "auto-approval demoted to human approval — see $RUNS_DIR/$id/plan.log"
          fnote "[$id] contract review refused unattended approval — review it yourself:"
          fnote "[$id]   feedback: $(renv_get "$id" WT)/.loop/contract-review-feedback.md | approve: ./loop.sh fleet approve $id"
        fi
      elif approve_task "$id" AUTO_APPROVED; then
        fnote "[$id] auto-approved (contract review passed; journaled)"
      else
        task_fail "$id" APPROVE_FAILED "in-worktree './loop.sh approve' failed — see $RUNS_DIR/$id/plan.log"
      fi
    else
      renv_set "$id" PHASE PENDING_APPROVAL
      journal "$id" PENDING_APPROVAL ""
      fnote "[$id] contract ready — review from any terminal: ./loop.sh fleet approve $id"
    fi
  done
  # 2.5 supervisor decisions: at most ONE per tick (serialized like merges);
  # only orchestrated tasks ever reach SUPERVISE_PENDING (see reap_task)
  for id in $(tasks_in claimed); do
    if [ "$(renv_get "$id" PHASE)" = "SUPERVISE_PENDING" ]; then
      beat   # a supervisor decision is a synchronous model call
      supervise_task "$id"
      break
    fi
  done
  # 3. merge queue: at most ONE landing per tick, serialized in this process
  for id in $(tasks_in claimed); do
    if [ "$(renv_get "$id" PHASE)" = "MERGE_PENDING" ]; then
      beat   # merges (and their commit hooks) can also block
      merge_task "$id" || true
      break
    fi
  done
  # 3.5 phase-boundary plan-review: at most ONE per tick, after merges (the
  # merged evidence exists in run-archive) and before claims (deps_state holds
  # every dependent of a PENDING/ESCALATED phase, so nothing it may revise can
  # have been claimed since the merge)
  for id in $(tasks_in "done"); do
    if [ "$(renv_get "$id" PLAN_REVIEW "")" = "PENDING" ]; then
      beat   # a plan-review is a synchronous model call
      plan_review_task "$id"
      break
    fi
  done
  # 3.6 a plan-review ESCALATE freezes the ENTIRE queue until a human acks: the
  # outer loop finishes on plan_review_escalated, but that check runs AFTER this
  # tick returns, so without this guard steps 4-5 would still launch/claim in the
  # same tick. deps_state only holds a phase's DEPENDENTS — a drift-triggered
  # escalate on an INDEPENDENT phase leaves other queued PLANNED work with no
  # hold, so it would be pulled into flight before the human ever decides. Skip
  # all new launch/claim; already-running tasks finish their current phase.
  if plan_review_escalated; then
    write_parallel_context
    return 0
  fi
  # 4. launch approved tasks into free slots. active_slots spawns ps/grep per
  # claimed task, so count once per tick and track launches locally instead of
  # re-deriving inside the loops (O(claimed) instead of O(claimed^2) subprocesses)
  local slots
  slots=$(active_slots)
  for id in $(tasks_in claimed); do
    [ "$slots" -lt "$MAX_PARALLEL" ] || break
    if [ "$(renv_get "$id" PHASE)" = "APPROVED" ]; then
      start_run "$id"
      slots=$((slots + 1))
    fi
  done
  # 5. claim queued tasks into free slots (this is how tasks added mid-run join).
  # DEPENDS_ON gating: waiting tasks stay in new/; a task whose dependency
  # terminally failed is parked as DEP_FAILED so --drain can terminate.
  local dstate
  for id in $(tasks_in new); do
    [ "$slots" -lt "$MAX_PARALLEL" ] || break
    dstate=$(deps_state "$id")
    case "$dstate" in
      waiting)  continue ;;
      failed:*) dep_fail_task "$id" "${dstate#failed:}"; continue ;;
    esac
    claim_task "$id"
    # a failed bootstrap does not consume a slot (the task went to failed/)
    [ "$(renv_get "$id" PHASE)" = "CONTRACT_GEN" ] && slots=$((slots + 1))
  done
  # 6. refresh mutual awareness in every live worktree
  write_parallel_context
}

fleet_idle() { # no queued work and nothing claimed (pending approval counts as busy)
  [ -z "$(tasks_in new)" ] && [ -z "$(tasks_in claimed)" ]
}

fleet_merge_blocked() { # every claimed task is MERGE_PENDING and the parent's
  # tracked tree is dirty: no merge can land until a human commits/stashes, so
  # a --drain supervisor spinning on this is a livelock, not patience. (A dirty
  # parent is legitimate while OTHER phases can still progress — this is only
  # "blocked" when merging is the sole remaining work.)
  local id any=0
  for id in $(tasks_in new); do
    # a queued task that could still be claimed means progress is possible;
    # one waiting on a dependency cannot move while the merge is stuck
    [ "$(deps_state "$id")" = "waiting" ] || return 1
  done
  for id in $(tasks_in claimed); do
    [ "$(renv_get "$id" PHASE)" = "MERGE_PENDING" ] || return 1
    any=1
  done
  [ "$any" -eq 1 ] || return 1
  [ -n "$(git status --porcelain -uno 2>/dev/null)" ]
}

recover_claimed() { # supervisor (re)start: adopt whatever the previous one left.
  # INVARIANT (auditability): every claimed task gets an ADOPTED journal entry
  # with the phase it was found in, so a restart's recovery decisions are
  # always traceable later — even when no state change was needed.
  local id phase
  for id in $(tasks_in claimed); do
    phase=$(renv_get "$id" PHASE "")
    journal "$id" ADOPTED "supervisor start found phase=${phase:-none}"
    case "$phase" in
      CONTRACT_GEN|RUNNING)
        if task_pid_alive "$id"; then
          fnote "[$id] still running — adopted"
        else
          reap_task "$id"                             # crashed supervisor's orphans
          # a TERM'd/Ctrl-C'd supervisor leaves phase RUNNING; the reap above
          # just turned it INTERRUPTED — that IS the interrupted-run case, so
          # resume it NOW, not on the restart after this one. A human `fleet
          # stop` marker means the reap already parked it (STOP_HONORED) into
          # failed/ — the queue check keeps that park honored.
          if [ "$(renv_get "$id" PHASE)" = "INTERRUPTED" ] && [ "$(task_qdir "$id")" = "claimed" ]; then
            renv_set "$id" PHASE APPROVED
            journal "$id" RESUME "auto-resume at supervisor start"
            fnote "[$id] resuming interrupted run"
          fi
        fi ;;
      INTERRUPTED)
        if [ "$(renv_get "$id" STOPPED_BY "")" = "human" ]; then
          park_human_stopped "$id"                    # a human stop is never un-done
        else
          renv_set "$id" PHASE APPROVED               # interrupted before this restart
          journal "$id" RESUME "auto-resume at supervisor start"
          fnote "[$id] resuming interrupted run"
        fi ;;
      CONTRACT_READY|PENDING_APPROVAL|APPROVED|MERGE_PENDING|SUPERVISE_PENDING)
        # tick handles these normally. SUPERVISE_PENDING is a persistent claimed
        # phase (reap_task sets it while the escalated worker awaits a supervisor
        # decision) — tick step 2.5 re-enters supervise_task on the next tick,
        # the same crash re-entry pattern as a PLAN_REVIEW=PENDING marker. It
        # must never fall into the destructive catch-all below: the worktree
        # holds the worker's committed iterations and its decision request.
        ;;
      queued)
        # claimed/ with PHASE=queued means the merge-conflict redo crashed between
        # its `renv_set PHASE queued` flip and the `mv claimed->new` that requeues
        # it (merge_task's redo arm is the only writer of PHASE=queued in claimed/).
        # Complete that interrupted requeue instead of failing it. The worktree/
        # branch cleanup is a no-op here (the redo already removed the worktree and
        # archived the branch as *-conflict-1) — it mirrors fleet_resume_flip's
        # requeue class, and stays defensive against any future claimed:queued path.
        # NOTE: a claim that crashed mid-bootstrap carries NO phase (enqueue never
        # sets one), so it correctly falls to the STALE_BOOTSTRAP catch-all below.
        git worktree remove --force "$(wt_path "$id")" >/dev/null 2>&1 || true
        git branch -D "loop/$id" >/dev/null 2>&1 || true
        git worktree prune 2>/dev/null || true
        mv -f "$QUEUE_DIR/claimed/$id.md" "$QUEUE_DIR/new/$id.md" 2>/dev/null || true
        journal "$id" ADOPTED_REQUEUE "completed an interrupted requeue (claimed:queued -> new/)"
        fnote "[$id] re-queued (an interrupted requeue was completed)" ;;
      *)
        # no/unknown phase = the previous supervisor died mid-bootstrap; the
        # worktree may be half-built — fail it cleanly so it can be re-added
        git worktree remove --force "$(wt_path "$id")" >/dev/null 2>&1 || true
        git branch -D "loop/$id" >/dev/null 2>&1 || true
        task_fail "$id" STALE_BOOTSTRAP "supervisor died mid-bootstrap — re-queue with: ./loop.sh fleet add $QUEUE_DIR/failed/$id.md" ;;
    esac
  done
}

confirm_setup_cmd() { # WORKTREE_SETUP_CMD is executed code — confirm per session
  SETUP_CMD=$(fcfg WORKTREE_SETUP_CMD "")
  [ -n "$SETUP_CMD" ] || return 0
  if [ "$AUTO_MODE" = "1" ]; then
    journal "-" SETUP_CMD_AUTO_OK "$SETUP_CMD"
    return 0
  fi
  if [ -t 0 ]; then
    printf 'fleet: each new worktree will first run: %s\n' "$SETUP_CMD"
    printf 'fleet: proceed? [y/N] '
    local ans
    read -r ans || ans=n
    case "$ans" in y|Y) return 0 ;; *) fdie "declined WORKTREE_SETUP_CMD — edit fleet.config.sh" ;; esac
  fi
  fdie "WORKTREE_SETUP_CMD is set but there is no TTY to confirm it — run with LOOP_AUTO=1 (accepts + journals) or clear the setting"
}

on_supervisor_int() {
  echo
  fnote "interrupt — stopping running loops (each saves state; resume with ./loop.sh fleet run)"
  # TERM the worker loop.sh processes FIRST so each runs its OWN on_interrupt
  # (which group-kills that worker's agent subtree) concurrently with the grace
  # below — a single-pid TERM is right here: the recorded PID is the worker loop.sh
  # (launched with `exec ./loop.sh`), not an agent, and its trap does the cascade.
  local id pid
  for id in $(tasks_in claimed); do
    case "$(renv_get "$id" PHASE)" in
      CONTRACT_GEN|RUNNING)
        pid=$(renv_get "$id" PID "")
        if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
        ;;
    esac
  done
  # then stop any parent-side model call in flight (supervise/decompose/gate
  # review/evidence): group-kill its whole subtree, never leave an orphan agent.
  kill_agent_group "$CHILD_PID"
  sleep 2
  release_lock
  trap - EXIT
  exit 130
}

# ---------- commands ----------

cmd_fleet_add() {
  need_project
  ensure_fleet_dirs
  local auto=0 after="" force_after=0 args=() a dep qd id all_files=1 ahead
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto)  auto=1; shift ;;
      --after) after="${2:?--after needs task id(s), comma-separated}"; shift 2 ;;
      --force-after) force_after=1; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ "${#args[@]}" -ge 1 ] || fdie "usage: ./loop.sh fleet add <task-file | \"instruction text\"> [--auto] [--after <id,id>] [--force-after]"
  if [ -n "$after" ]; then
    for dep in $(printf '%s' "$after" | tr ',' ' '); do
      qd=$(task_qdir "$dep")
      [ -n "$qd" ] || fdie "--after: unknown task id '$dep' (see ./loop.sh fleet status)"
      if [ "$qd" = "failed" ] && [ "$force_after" != 1 ]; then
        fdie "--after: dependency '$dep' already FAILED ($(renv_get "$dep" RESULT "")) — the new task would park DEP_FAILED on the first tick; resume it first (./loop.sh resume $dep) or accept the cascade with --force-after"
      fi
    done
  fi
  for a in "${args[@]}"; do [ -f "$a" ] || all_files=0; done
  if [ "$all_files" = 1 ]; then
    for a in "${args[@]}"; do
      ahead=$(tasks_in new | wc -l | tr -d ' ')
      id=$(enqueue_task "$(cat "$a")" "$a" "$auto")
      [ -z "$after" ] || renv_set "$id" DEPENDS_ON "$after"
      fnote "queued $id (from $a)${after:+ — after: $after}"
      fnote "queue: $ahead ahead in new/ | slots: $(active_slots)/$(fcfg FLEET_MAX_PARALLEL 3) busy${after:+ | waits for: $after (must be merged)} | order: id-lexical (--after for strict order)"
    done
  else
    ahead=$(tasks_in new | wc -l | tr -d ' ')
    id=$(enqueue_task "${args[*]}" "(inline)" "$auto")
    [ -z "$after" ] || renv_set "$id" DEPENDS_ON "$after"
    fnote "queued $id${after:+ — after: $after}"
    fnote "queue: $ahead ahead in new/ | slots: $(active_slots)/$(fcfg FLEET_MAX_PARALLEL 3) busy${after:+ | waits for: $after (must be merged)} | order: id-lexical (--after for strict order)"
  fi
  # honest dispatch hint: who (if anyone) will pick this task up, and when
  if [ "$(cat .loop/state 2>/dev/null)" = "FLEET_RUNNING" ] && supervisor_alive; then
    fnote "warning: an orchestration is in flight — this runs as a MANUAL task OUTSIDE the master contract (no supervisor decisions, no master-contract context); if it fails, the planned work still completes and this task is surfaced at the end (NEEDS_SPEC_DECISION)"
    if plan_review_escalated; then
      fnote "a plan-review escalation is pending: the orchestration exits for that decision (NEEDS_SPEC_DECISION) WITHOUT dispatching this task — release the hold first (./loop.sh fleet ack-plan <merged-id>), then ./loop.sh run"
    else
      fnote "the orchestration dispatches and integration-gates this task before completing"
    fi
  elif supervisor_alive; then
    fnote "the running supervisor picks new tasks up on its next tick"
  elif [ "$(cat .loop/state 2>/dev/null)" = "FLEET_RUNNING" ]; then
    fnote "orchestration interrupted/crashed — resume it (this task included): ./loop.sh run"
  elif [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ] && single_loop_alive; then
    fnote "a single-loop run is active (pid $(cat .loop/run.pid 2>/dev/null)) — it will NOT pick this task up mid-run; dispatch the queue after it finishes: ./loop.sh fleet run"
  else
    fnote "no supervisor running — start one: ./loop.sh fleet run"
  fi
}

cmd_fleet_run() {
  need_project
  ensure_fleet_dirs
  MAX_PARALLEL=$(fcfg FLEET_MAX_PARALLEL 3)
  local drain=0 args=() a auto_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) AUTO_MODE=1; shift ;;
      --max-parallel) MAX_PARALLEL="${2:?--max-parallel needs a number}"; shift 2 ;;
      --drain) drain=1; shift ;;
      -*) fdie_next "unknown option for run: $1" "see ./loop.sh fleet help" ;;
      *) args+=("$1"); shift ;;
    esac
  done
  case "$MAX_PARALLEL" in
    ''|*[!0-9]*|0) fdie_next "FLEET_MAX_PARALLEL / --max-parallel must be a positive integer (got '$MAX_PARALLEL')" "fix FLEET_MAX_PARALLEL in fleet.config.sh, or pass a valid --max-parallel" ;;
  esac
  [ -d .loop/templates ] && [ -n "$(ls .loop/templates/*.md 2>/dev/null)" ] \
    || fdie "this deployment has no .loop/templates (pristine doc templates) — run: ./loop.sh update"
  # a manual `fleet run` must not adopt PLANNED tasks whose contract has since
  # changed (same guard as run_fleet_orchestration — no single choke point exists)
  check_fleet_contract_binding
  need_claude fleet
  # the supervise step (tick 2.5) calls run_claude from THIS process; give it
  # the pieces load_config/load_models would provide in an orchestrated run
  # (loop.config.sh cannot be sourced here — no approval verification happened)
  MAX_ITER_SECONDS="${MAX_ITER_SECONDS:-900}"
  MODEL_SUPERVISE=$(get_model MODEL_SUPERVISE opus)
  mkdir -p .loop/logs   # run_claude writes its call logs here (init may not have)
  [ "$AUTO_MODE" = "1" ] && auto_flag=1
  if [ "${#args[@]}" -ge 1 ]; then
    for a in "${args[@]}"; do
      if [ -f "$a" ]; then
        fnote "queued $(enqueue_task "$(cat "$a")" "$a" "${auto_flag:-0}") (from $a)"
      else
        fnote "queued $(enqueue_task "$a" "(inline)" "${auto_flag:-0}")"
      fi
    done
  fi
  confirm_setup_cmd
  acquire_lock
  trap release_lock EXIT
  trap on_supervisor_int INT TERM
  # NOTE: a restart deliberately does NOT clear plan-review escalations — only
  # an explicit `./loop.sh fleet ack-plan <id>` releases the held queued phases
  supervisor_session_drop   # restart = session rotation (fresh conversation)
  if [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ]; then
    # split-brain refusal: a live root loop and the fleet must never share the
    # repo (both commit + move HEAD). Refuse ONLY on a verified-live process;
    # stale RUNNING left by a crash gets an honest warning and proceeds.
    if single_loop_alive; then
      fdie "a single-loop run is active (pid $(cat .loop/run.pid 2>/dev/null)) — a root loop and the fleet must not run together; wait for it or stop it (Ctrl-C / kill $(cat .loop/run.pid 2>/dev/null))"
    fi
    fnote "warning: .loop/state is RUNNING but no live loop process found (stale after a crash) — proceeding"
  fi
  # same policy as ./loop.sh run: a dirty parent tree becomes a snapshot commit,
  # so worktrees branch from a defined state and serial merges are never
  # blocked by leftovers (e.g. the gitignore update right after ./loop.sh update).
  # NEVER snapshot over an in-progress merge: `git add -A` would stage conflict
  # markers as resolved and silently conclude the merge as the snapshot commit.
  if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    fdie "the parent repository has a merge in progress — resolve it or 'git merge --abort' first"
  fi
  if [ -n "$(git status --porcelain)" ]; then
    fnote "parent working tree dirty — creating pre-fleet snapshot commit"
    git add -A
    git commit -q -m "fleet: pre-fleet snapshot"
  fi
  recover_claimed
  fnote "supervisor up — max parallel $MAX_PARALLEL$([ "$AUTO_MODE" = "1" ] && echo ", auto-approve on" || true)"
  fnote "add tasks any time (any terminal): ./loop.sh fleet add <task>   status: ./loop.sh fleet status"
  # --drain: two layers guard dynamic adds against a racing shutdown.
  #
  # Layer 1 (politeness): exit only after FLEET_DRAIN_GRACE_TICKS consecutive
  # idle ticks, so bursts of adds keep one supervisor instead of thrashing.
  #
  # Layer 2 (the actual guarantee — the EXIT PROTOCOL): tick counting alone is
  # a timing bet; a task published a microsecond after the last idle check
  # would meet a dead supervisor whose lock said "alive" when `add` looked.
  # Releasing the lock is therefore the linearization point: from that instant
  # `add` tells its caller "no supervisor running — start one". ONE final queue
  # scan AFTER the release catches everything published before it (ln into
  # new/ is atomic and immediately visible); if anything is there, re-acquire
  # and keep dispatching. Net invariant: a task whose publisher observed a live
  # supervisor is either claimed by that supervisor, or its publisher was told
  # to start a new one — no task is ever silently stranded in between.
  local idle_ticks=0 drain_grace blocked_ticks=0
  local human_cap stall_cap human_ticks=0 stall_ticks=0 last_fp="" fp needs_human=0
  drain_grace=$(fcfg FLEET_DRAIN_GRACE_TICKS 3)
  case "$drain_grace" in ''|*[!0-9]*|0) drain_grace=3 ;; esac
  # drain watchdogs (E6): a --drain supervisor promises to TERMINATE. When every
  # remaining task waits for a human approval (nothing in-process can grant it),
  # exit 3 after FLEET_DRAIN_HUMAN_TICKS (default 150 — generous: humans approve
  # from a second terminal mid-drain; 0 disables). When nothing needs a human
  # and nothing progresses, exit 4 after FLEET_STALL_TICKS (0 disables).
  human_cap=$(fcfg FLEET_DRAIN_HUMAN_TICKS 150)
  case "$human_cap" in ''|*[!0-9]*) human_cap=150 ;; esac
  stall_cap=$(fcfg FLEET_STALL_TICKS 30)
  case "$stall_cap" in ''|*[!0-9]*) stall_cap=30 ;; esac
  while :; do
    tick
    # Livelock guard: when merging is the ONLY remaining work and the parent
    # tracked tree stays dirty, no tick will ever make progress — a --drain
    # supervisor must escalate to the human (exit 3, same semantics as the
    # core loop's decision states) instead of spinning forever. The finished
    # branches stay MERGE_PENDING; the next `./loop.sh fleet run --drain` after a
    # commit/stash lands them (recover_claimed adopts MERGE_PENDING as-is).
    if [ "$drain" = "1" ] && fleet_merge_blocked; then
      blocked_ticks=$((blocked_ticks + 1))
      if [ "$blocked_ticks" -ge 15 ]; then   # ~30s at the production tick
        fnote "drain: merges blocked by uncommitted parent changes — exiting"
        fnote "commit or stash the parent tree, then './loop.sh fleet run --drain' lands the finished branches"
        journal "-" DRAIN_MERGE_BLOCKED "parent tracked tree dirty; finished branches kept as MERGE_PENDING"
        exit 3
      fi
    else
      blocked_ticks=0
    fi
    # plan-review escalation as the sole blocker: nothing runs and nothing can
    # be claimed until a human decides + acks — no tick will ever progress, so
    # a --drain supervisor exits 3 immediately instead of hitting the stall
    # watchdog with a generic message
    if [ "$drain" = "1" ] && fleet_plan_held; then
      journal "-" DRAIN_PLAN_ESCALATED "a plan-review escalation holds every remaining task — a human must acknowledge"
      fnote "drain: a plan-review escalation holds the queued phases — exiting"
      fnote "decide the DR-FLEET-PLAN-* question in .loop/docs/decision-requests.md, then release: ./loop.sh fleet ack-plan <merged-id> (or --all) and re-run './loop.sh fleet run --drain'"
      exit 3
    fi
    # approval watchdog (drain only): every claimed task parked in
    # PENDING_APPROVAL and nothing claimable — surface the decision request
    # WITHOUT auto-committing (a standalone drain must never `git add -A` a
    # human's mid-edit tree) and exit 3.
    needs_human=0
    if [ "$drain" = "1" ]; then fleet_needs_human && needs_human=1; fi
    if [ "$needs_human" = 1 ] && [ "$human_cap" -gt 0 ]; then
      human_ticks=$((human_ticks + 1))
      if [ "$human_ticks" -ge "$human_cap" ]; then
        journal "-" DRAIN_APPROVAL_BLOCKED "every claimed task waits in PENDING_APPROVAL — a human must approve"
        {
          echo
          echo "## DR-FLEET-APPROVAL"
          echo "- Task(s) waiting for human contract approval: $(tasks_in claimed | tr '\n' ' ')"
          echo "- Review feedback: <wt>/.loop/contract-review-feedback.md"
          echo "- Then: ./loop.sh fleet approve <id>   (or --all), then: ./loop.sh fleet run --drain"
        } >> .loop/docs/decision-requests.md
        fnote "drain: task(s) wait for human contract approval — exiting"
        fnote "decision request appended to .loop/docs/decision-requests.md — commit when ready; approve with: ./loop.sh fleet approve <id>, then re-run './loop.sh fleet run --drain'"
        exit 3
      fi
    else
      human_ticks=0
    fi
    # stall watchdog (drain only; evaluated only when no human approval is the
    # blocker — else all-PENDING_APPROVAL would trip this long before the
    # approval watchdog above): unchanged phase fingerprint + zero live workers
    # for FLEET_STALL_TICKS ticks = no tick will ever make progress.
    if [ "$drain" = "1" ] && [ "$stall_cap" -gt 0 ] && [ "$needs_human" != 1 ]; then
      fp=$(fleet_fingerprint)
      if [ "$fp" = "$last_fp" ] && [ "$(active_slots)" -eq 0 ] && ! fleet_idle; then
        stall_ticks=$((stall_ticks + 1))
        if [ "$stall_ticks" -ge "$stall_cap" ]; then
          journal "-" DRAIN_STALLED "no live workers and no phase change for $stall_ticks ticks: $(fleet_fingerprint | tr '\n' ' ')"
          fnote "drain: no progress for $stall_ticks ticks — exiting (inspect: ./loop.sh fleet status, then ./loop.sh resume <id>)"
          exit 4
        fi
      else
        stall_ticks=0
      fi
      last_fp="$fp"
    else
      stall_ticks=0
    fi
    if [ "$drain" = "1" ] && fleet_idle; then
      idle_ticks=$((idle_ticks + 1))
      if [ "$idle_ticks" -ge "$drain_grace" ]; then
        release_lock          # linearization point — see the exit protocol note
        trap - EXIT
        if [ -n "$(tasks_in new)" ]; then
          if try_acquire_lock; then
            trap release_lock EXIT
            fnote "a task arrived during shutdown — resuming dispatch"
            journal "-" DRAIN_RESUMED "task published during the drain window"
            idle_ticks=0
            sleep "$TICK_SECONDS"
            continue
          fi
          # a successor supervisor grabbed the lock in the release window —
          # it will claim what appeared; journal the handoff so the trail
          # explains why THIS supervisor exited with a non-empty queue
          fnote "queued tasks remain but a successor supervisor holds the lock — handing off"
          journal "-" DRAIN_HANDOFF "queued tasks left to the successor supervisor"
          break
        fi
        fnote "queue drained (idle for $idle_ticks ticks) — exiting"
        break
      fi
    else
      idle_ticks=0
    fi
    sleep "$TICK_SECONDS"
  done
}

cmd_fleet_approve() {
  need_project
  ensure_fleet_dirs
  local ids=() all=0 a id
  for a in "$@"; do
    case "$a" in
      --all) all=1 ;;
      *) ids+=("$a") ;;
    esac
  done
  if [ "$all" = 1 ]; then
    for id in $(tasks_in claimed); do
      case "$(renv_get "$id" PHASE)" in CONTRACT_READY|PENDING_APPROVAL) ids+=("$id") ;; esac
    done
  fi
  [ "${#ids[@]}" -ge 1 ] || fdie "nothing awaiting approval (see ./loop.sh fleet status)"
  for id in "${ids[@]}"; do
    approve_one "$id"
  done
}

approve_one() { # $1 id — show the contract, then record approval in the worktree
  local id="$1" wt phase ans=y
  phase=$(renv_get "$id" PHASE "")
  case "$phase" in
    CONTRACT_READY|PENDING_APPROVAL) ;;
    *) fnote "[$id] not awaiting approval (phase: ${phase:-unknown})"; return 0 ;;
  esac
  if ! master_intact "$id"; then
    # the sub-contract shown below may have been generated against the tampered
    # copy — leave the task pending; the human re-runs approve after reviewing
    fnote "[$id] left pending — re-run after reviewing: ./loop.sh fleet approve $id"
    return 0
  fi
  wt=$(renv_get "$id" WT)
  echo "════════ $id ════════"
  sed -n '1,40p' "$wt/.loop/docs/product-contract.md"
  echo "──── stop conditions (from $wt/loop.config.sh) ────"
  grep -E '^[[:space:]]*(VERIFY_COMMANDS|"|DENIED_PATHS|ESCALATE_PATHS|MAX_ITERATIONS|MAX_ITER_SECONDS|TIMEOUT_[A-Z_]+)' "$wt/loop.config.sh" 2>/dev/null | head -15 || true
  echo "═══════════════════════"
  local event=APPROVED
  if [ "$AUTO_MODE" = "1" ]; then
    event=AUTO_APPROVED   # honest audit trail: no human read this contract
  elif [ -t 0 ]; then
    printf 'fleet: approve %s and let it run? [y/N/s(kip)] ' "$id"
    read -r ans || ans=n
  else
    # no TTY and not auto: NEVER default to yes — this gate exists so a human
    # actually reads the contract. The only sanctioned bypass is journaled auto.
    fnote "[$id] no TTY — left pending. Approve interactively, or bypass explicitly: LOOP_AUTO=1 ./loop.sh fleet approve $id"
    return 0
  fi
  case "$ans" in
    y|Y)
      if approve_task "$id" "$event"; then
        fnote "[$id] approved — launches when a slot frees"
      else
        fnote "[$id] approve FAILED — see $RUNS_DIR/$id/plan.log"
      fi
      ;;
    s|S)
      fnote "[$id] skipped (still pending)"
      ;;
    *)
      fnote "[$id] NOT approved — revise: edit $wt/.loop/docs/product-contract.md (+loop.config.sh), then ./loop.sh fleet approve $id; or discard: ./loop.sh fleet clean $id --force"
      ;;
  esac
}

cmd_fleet_status() {
  need_project
  ensure_fleet_dirs
  if supervisor_alive; then
    echo "supervisor: running (pid $(supervisor_pid))"
  else
    echo "supervisor: not running   (start: ./loop.sh fleet run)"
  fi
  echo
  printf '%-8s %-36s %-20s %s\n' "QUEUE" "TASK" "PHASE" "SUMMARY"
  local d id phase live deps
  for d in new claimed "done" failed; do
    for id in $(tasks_in "$d"); do
      phase=$(renv_get "$id" PHASE queued)
      if [ "$d" = "new" ]; then
        deps=$(renv_get "$id" DEPENDS_ON "")
        [ -z "$deps" ] || phase="queued(after:$deps)"
      fi
      live=""
      case "$phase" in
        CONTRACT_GEN|RUNNING) if task_pid_alive "$id"; then live=" *"; else live=" †"; fi ;;
      esac
      printf '%-8s %-36s %-20s %s\n' "$d" "$id" "$phase$live" "$(renv_get "$id" SUMMARY "" | cut -c1-48)"
    done
  done
  [ "${1:-}" = "--overlap" ] && print_overlap
  return 0
}

print_overlap() { # changed-file intersection between branches — merge early warning
  echo
  echo "changed-file overlap between task branches:"
  local ids=() id i j a b fa fb inter any=0
  for id in $(tasks_in claimed) $(tasks_in failed); do
    [ -n "$(renv_get "$id" BRANCH "")" ] && ids+=("$id")
  done
  local n="${#ids[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    j=$((i + 1))
    while [ "$j" -lt "$n" ]; do
      a="${ids[$i]}"; b="${ids[$j]}"
      fa=$(git diff --name-only "$(renv_get "$a" BASE_REF)..$(renv_get "$a" BRANCH)" -- . ':(exclude).loop' 2>/dev/null | sort || true)
      fb=$(git diff --name-only "$(renv_get "$b" BASE_REF)..$(renv_get "$b" BRANCH)" -- . ':(exclude).loop' 2>/dev/null | sort || true)
      inter=$(comm -12 <(printf '%s\n' "$fa") <(printf '%s\n' "$fb") | grep -v '^$' || true)
      if [ -n "$inter" ]; then
        any=1
        echo "  $a <-> $b:"
        printf '%s\n' "$inter" | sed 's/^/    /'
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done
  [ "$any" = 1 ] || echo "  (no overlap)"
}

cmd_fleet_report() {
  need_project
  ensure_fleet_dirs
  local id="${1:-}" wt total c
  if [ -n "$id" ]; then
    wt=$(renv_get "$id" WT "")
    echo "task:     $id"
    echo "queue:    $(task_qdir "$id")   phase: $(renv_get "$id" PHASE "")   result: $(renv_get "$id" RESULT "-")"
    echo "branch:   $(renv_get "$id" BRANCH "-")   worktree: ${wt:--}"
    echo "cost:     \$$(cat "$wt/.loop/cost-total" 2>/dev/null || echo 0)"
    if [ -n "$wt" ] && [ -f "$wt/.loop/docs/evidence-report.md" ] \
       && ! grep -q '<!-- TEMPLATE -->' "$wt/.loop/docs/evidence-report.md"; then
      echo "════════ evidence ════════"
      cat "$wt/.loop/docs/evidence-report.md"
    fi
    return 0
  fi
  cmd_fleet_status
  total=0
  for id in $(all_task_ids); do
    wt=$(renv_get "$id" WT "")
    [ -n "$wt" ] || continue
    c=$(cat "$wt/.loop/cost-total" 2>/dev/null || echo 0)
    total=$(awk -v a="$total" -v b="$c" 'BEGIN{printf "%.4f", a + b}')
  done
  echo
  echo "total cost across live runs: \$$total"
}

cmd_fleet_logs() {
  need_project
  local id="${1:?usage: ./loop.sh fleet logs <task-id>}"
  if [ -f "$RUNS_DIR/$id/plan.log" ]; then
    echo "════════ plan.log (bootstrap + contract) ════════"
    tail -n 40 "$RUNS_DIR/$id/plan.log"
  fi
  if [ -f "$RUNS_DIR/$id/run.log" ]; then
    echo "════════ run.log ════════"
    tail -n 100 "$RUNS_DIR/$id/run.log"
  fi
}

cmd_fleet_stop() {
  need_project
  local id="${1:?usage: ./loop.sh fleet stop <task-id>}" pid
  pid=$(renv_get "$id" PID "")
  { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || fdie_next "no live process for $id" "./loop.sh fleet status"
  # marker BEFORE the kill: whoever reaps this task (live tick, recover_claimed
  # at any later start) must park it instead of auto-resuming — a human stop is
  # honored until a human resume clears the marker (fleet_resume_flip)
  renv_set "$id" STOPPED_BY human
  kill "$pid"
  fnote "sent TERM to $id — loop.sh saves state; resume later with ./loop.sh fleet resume $id"
}

resume_class() { # $1 id -> class token (pure; the listing and the flip share this)
  local qd phase result
  qd=$(task_qdir "$1"); phase=$(renv_get "$1" PHASE ""); result=$(renv_get "$1" RESULT "$phase")
  case "$qd" in
    "")     echo unknown ;;
    done)   echo "done" ;;
    new)    echo queued ;;
    failed) case "$result" in
              CONTRACT_FAILED|BOOTSTRAP_FAILED|STALE_BOOTSTRAP|APPROVE_FAILED|DEP_FAILED) echo requeue ;;
              MERGE_CONFLICT|MERGE_FAILED) echo merge-decision ;;
              NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|NEEDS_HUMAN|RISK_REQUIRES_APPROVAL) echo decision ;;
              REPLANNED) echo superseded ;;
              *) echo relaunch ;;   # BLOCKED|STALLED|BUDGET_EXCEEDED|CRASHED|INTERRUPTED(orch-parked)
            esac ;;
    claimed) case "$phase" in
              INTERRUPTED|CRASHED) echo relaunch-claimed ;;
              PENDING_APPROVAL)    echo approval ;;
              CONTRACT_GEN|RUNNING)
                # "running" is only as true as the recorded pid: a dead process
                # behind a RUNNING phase is a crashed dispatcher's leftover
                if task_pid_alive "$1"; then echo busy; else echo stale-running; fi ;;
              *)                   echo busy ;;
            esac ;;
  esac
}

resume_gate_decision() { # decision-state worker: resumable only AFTER the human
  # answered IN the worktree. The in-worktree `approve` rebinds the run-checkpoint
  # (DECISION_REBOUND=1, see ckpt_rebind_decision) so the relaunch RESUMES with
  # counters/cost intact; without it, `run --prefer-resume` maps NEEDS_* to a
  # FRESH run (decide_run_mode) that just re-asks the same question — burned budget.
  local id="$1" wt
  wt=$(renv_get "$id" WT "")
  if grep -q '^DECISION_REBOUND=1' "$wt/.loop/run-checkpoint" 2>/dev/null; then
    mv "$QUEUE_DIR/failed/$id.md" "$QUEUE_DIR/claimed/$id.md"
    renv_set "$id" PHASE APPROVED
    renv_set "$id" RESULT ""
    renv_set "$id" STOPPED_BY ""   # an explicit resume IS the human's decision
    journal "$id" RESUME "decision answered (rebound checkpoint) — relaunching"
    fnote "[$id] answered decision — queued for relaunch (resumes, counters intact)"
  else
    fnote "[$id] stopped for a human decision — answer it first:"
    fnote "  1. read  $wt/.loop/docs/decision-requests.md"
    fnote "  2. write your answer to $wt/.loop/supervisor-guidance.md (the worker treats it as the decision)"
    fnote "  3. (cd $wt && ./loop.sh approve)     # rebinds the checkpoint so the run RESUMES"
    fdie "then re-run: ./loop.sh resume $id"
  fi
}

fleet_resume_flip() { # $1 id, [$2 internal: "recursed" bounds the stale-running
  # inline reap to ONE recursion] — one state flip toward runnable, by
  # resume_class; fdies on every non-resumable class (the listing and the flip
  # stay in sync)
  local id="$1" recursed="${2:-}" phase
  phase=$(renv_get "$id" PHASE "")
  case "$(resume_class "$id")" in
    unknown) fdie "unknown task: $id — list sessions: ./loop.sh resume --list" ;;
    done) fdie "$id is already done — queue a follow-up instead: ./loop.sh add <task>" ;;
    queued) fdie "$id is still queued — it runs when a slot frees" ;;
    superseded) fdie "$id was superseded by a replacement (REPLANNED) — nothing to resume" ;;
    requeue)
      # nothing runnable exists yet (no contract / broken worktree) — a
      # relaunch would die at verify_approval. Scrap the artifacts and
      # re-queue the task for a completely fresh claim instead.
      git worktree remove --force "$(renv_get "$id" WT "")" >/dev/null 2>&1 || true
      git branch -D "loop/$id" >/dev/null 2>&1 || true
      git worktree prune 2>/dev/null || true
      if git rev-parse -q --verify "loop/$id" >/dev/null 2>&1; then
        # a silently-surviving branch would make every fresh claim fail at
        # `git worktree add -b` with no hint — refuse loudly instead
        fdie "could not delete branch loop/$id (git busy? supervisor merging?) — retry in a moment"
      fi
      renv_set "$id" PHASE queued
      renv_set "$id" RESULT ""
      mv "$QUEUE_DIR/failed/$id.md" "$QUEUE_DIR/new/$id.md"
      journal "$id" RESUME "re-queued for a fresh claim (was: $phase)"
      fnote "[$id] re-queued from scratch (was: $phase)"
      ;;
    merge-decision)
      fdie "$id needs a merge decision, not a resume — retry with: ./loop.sh fleet merge $id, merge by hand, or discard: ./loop.sh fleet clean $id --force"
      ;;
    decision)
      resume_gate_decision "$id"
      ;;
    relaunch)
      mv "$QUEUE_DIR/failed/$id.md" "$QUEUE_DIR/claimed/$id.md"
      renv_set "$id" PHASE APPROVED
      renv_set "$id" RESULT ""
      renv_set "$id" STOPPED_BY ""   # an explicit resume IS the human's decision
      journal "$id" RESUME "from failed ($phase)"
      fnote "[$id] queued for relaunch (was: $phase)"
      fnote "note: if you edited its contract, re-approve first: (cd $(renv_get "$id" WT) && ./loop.sh approve)"
      ;;
    relaunch-claimed)
      renv_set "$id" PHASE APPROVED
      renv_set "$id" STOPPED_BY ""   # an explicit resume IS the human's decision
      journal "$id" RESUME "from $phase"
      fnote "[$id] queued for relaunch"
      ;;
    stale-running)
      # claimed CONTRACT_GEN/RUNNING whose recorded process is DEAD. A live
      # dispatcher reaps it on its own tick — never race one; with none, reap
      # inline (safe outside the dispatcher: the non-child wait is +e-guarded,
      # renv writes are per-task-locked, queue moves atomic) and act on the
      # outcome the reap derived from the worktree state.
      if supervisor_alive; then
        fnote "[$id] its recorded process is dead — a live dispatcher (pid $(supervisor_pid)) will reap it on its next tick"
        return 0
      fi
      fnote "[$id] recorded process is dead — reaping inline (was: $phase)"
      reap_task "$id"
      case "$(task_qdir "$id"):$(renv_get "$id" PHASE "")" in
        claimed:APPROVED)
          fnote "[$id] queued for relaunch (crash retry)" ;;
        claimed:INTERRUPTED)
          renv_set "$id" PHASE APPROVED    # same flip as relaunch-claimed:
          renv_set "$id" STOPPED_BY ""     # an explicit resume IS the human's decision
          journal "$id" RESUME "from INTERRUPTED (dead process reaped inline)"
          fnote "[$id] queued for relaunch" ;;
        done:*)
          fnote "[$id] done — the dead process had already finished its work" ;;
        failed:*)
          if [ -n "$recursed" ]; then
            fnote "[$id] reaped to failed/ ($(renv_get "$id" RESULT "?")) — resume again: ./loop.sh resume $id"
          else
            fleet_resume_flip "$id" recursed   # exactly one bounded recursion
          fi ;;
        *)
          fnote "[$id] reaped — phase now $(renv_get "$id" PHASE "?") (the dispatcher takes it from here)" ;;
      esac
      ;;
    approval) fdie "$id awaits approval, not resume: ./loop.sh fleet approve $id" ;;
    busy)
      # resume_class collapses two shapes to "busy": a task genuinely running
      # (CONTRACT_GEN/RUNNING behind a LIVE pid — resume_class already routed a
      # dead pid to stale-running) and a parent-side pending phase the SUPERVISOR,
      # not a per-task resume, advances (APPROVED, MERGE_PENDING, SUPERVISE_PENDING,
      # CONTRACT_READY, or a redo's claimed:queued). Keep the running case terse;
      # for the pending ones name the supervisor so a CRASHED one is recoverable —
      # recover_claimed adopts exactly these phases on the next start (H1).
      case "$phase" in
        CONTRACT_GEN|RUNNING) fdie "$id is $phase — nothing to resume" ;;
        *) if supervisor_alive; then
             fdie "$id is $phase — the running supervisor advances it (watch: ./loop.sh fleet status)"
           else
             fdie "$id is $phase — the supervisor advances this phase, not a per-task resume; start it: ./loop.sh run"
           fi ;;
      esac ;;
  esac
}

cmd_fleet_resume() {
  need_project
  ensure_fleet_dirs
  local id="${1:?usage: ./loop.sh fleet resume <task-id>}"
  fleet_resume_flip "$id"
  if supervisor_alive; then
    fnote "the running supervisor relaunches it on the next tick"
  else
    fnote "start the supervisor to continue: ./loop.sh fleet run"
  fi
}

cmd_fleet_ack_plan() { # ./loop.sh fleet ack-plan <merged-id | --all> — a HUMAN
  # acknowledges a plan-review escalation (DR-FLEET-PLAN-<id>): clear the
  # ESCALATED marker so the queue resumes — it un-freezes the tick-level hold
  # plan_review_escalated imposes on ALL new claims, and lets deps_state release
  # any dependents of the merged phase. This is
  # the ONLY release path — a supervisor restart never clears it (task
  # escalations demand an explicit `fleet resume <id>`; plan escalations demand
  # this, for the same reason: a habitual rerun must not silently convert
  # "a human must decide" into "decided"). PENDING markers are never touched:
  # a crash mid-review re-enters the review on the next supervisor run.
  need_project
  ensure_fleet_dirs
  local id="${1:?usage: ./loop.sh fleet ack-plan <merged-task-id | --all>}" d n=0
  for d in $(tasks_in "done"); do
    [ "$id" = "--all" ] || [ "$d" = "$id" ] || continue
    if [ "$(renv_get "$d" PLAN_REVIEW "")" = "ESCALATED" ]; then
      renv_set "$d" PLAN_REVIEW DONE
      journal "$d" PLAN_REVIEW_ACK "human acknowledged the plan-review escalation — held phases released"
      fnote "[$d] plan-review escalation acknowledged — held queued phases released"
      n=$((n + 1))
    fi
  done
  if [ "$n" -eq 0 ]; then
    if [ "$id" = "--all" ]; then
      fdie "no plan-review escalation to acknowledge (markers: ./loop.sh fleet status)"
    fi
    [ "$(renv_get "$id" PLAN_REVIEW "")" = "PENDING" ] \
      && fdie "task '$id' has a PENDING plan-review (interrupted mid-review) — the next supervisor run re-enters it; nothing to acknowledge"
    fdie "task '$id' holds no plan-review escalation (PLAN_REVIEW: $(renv_get "$id" PLAN_REVIEW "-"); only merged tasks in done/ can hold one)"
  fi
  fnote "resume the run to dispatch the released phases: ./loop.sh run"
}

cmd_fleet_merge() {
  need_project
  ensure_fleet_dirs
  local id="${1:?usage: ./loop.sh fleet merge <task-id>}" qd
  supervisor_alive && fdie "supervisor is running — it merges automatically (stop it to merge by hand)"
  qd=$(task_qdir "$id")
  [ -n "$qd" ] || fdie_next "unknown task: $id" "list tasks: ./loop.sh fleet status"
  case "$(renv_get "$id" PHASE "")" in
    MERGE_PENDING) ;;
    MERGE_CONFLICT|MERGE_FAILED)
      mv "$QUEUE_DIR/failed/$id.md" "$QUEUE_DIR/claimed/$id.md" 2>/dev/null || true
      renv_set "$id" PHASE MERGE_PENDING
      ;;
    *) fdie_next "$id is not awaiting merge (phase: $(renv_get "$id" PHASE "?"))" "./loop.sh fleet status" ;;
  esac
  merge_task "$id" || fdie_next "merge deferred — parent working tree is dirty" "commit or stash the parent tree, then ./loop.sh fleet merge $id"
}

cmd_fleet_clean() {
  need_project
  ensure_fleet_dirs
  local force=0 all_done=0 orphans=0 ids=() a id
  for a in "$@"; do
    case "$a" in
      --force)   force=1 ;;
      --done)    all_done=1 ;;
      --orphans) orphans=1 ;;
      *) ids+=("$a") ;;
    esac
  done
  if [ "$orphans" = 1 ]; then
    clean_orphans
    { [ "$all_done" = 1 ] || [ "${#ids[@]}" -ge 1 ]; } || return 0
  fi
  if [ "$all_done" = 1 ] && [ "${#ids[@]}" -eq 0 ]; then
    for id in $(tasks_in "done"); do ids+=("$id"); done
    if [ "${#ids[@]}" -eq 0 ]; then
      fnote "nothing merged to clean"
      return 0
    fi
  elif [ "$all_done" = 1 ]; then
    for id in $(tasks_in "done"); do ids+=("$id"); done
  fi
  [ "${#ids[@]}" -ge 1 ] || fdie "usage: ./loop.sh fleet clean <task-id ...> | --done | --orphans  [--force]"
  for id in "${ids[@]}"; do
    clean_one "$id" "$force"
  done
  git worktree prune 2>/dev/null || true
}

clean_orphans() { # gc: worktrees under $WT_ROOT and loop/* branches whose task has
  # NO queue entry AND no runs/<id>.env — a live task always has both indices, so
  # only true leftovers (crash mid-clean, manual surgery) qualify; anything else
  # is a task's property and is never touched. Removal mirrors clean_one.
  local cand="" seen="" line b id wt pid any=0
  while IFS= read -r line; do
    case "$line" in
      "worktree $WT_ROOT/"*) id="${line#worktree "$WT_ROOT"/}"; id="${id%%/*}"; cand="$cand $id" ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null || true)
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    cand="$cand ${b#loop/}"
  done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/loop/*' 2>/dev/null || true)
  for id in $cand; do
    case " $seen " in *" $id "*) continue ;; esac
    seen="$seen $id"
    { [ -z "$(task_qdir "$id")" ] && [ ! -f "$RUNS_DIR/$id.env" ]; } || continue
    any=1
    wt=$(wt_path "$id")
    # liveness guard: orphans have no runs/<id>.env, so task_pid_alive is
    # unusable — the worktree's own .loop/run.pid (written by its loop.sh run) is
    # the only honest probe. This is a destructive gate, and its ONLY catastrophic
    # error is deleting a tree out from under a live loop, so an ALIVE recorded pid
    # is decisive: keep the tree, no ps/heartbeat identity gate. Deliberately NOT
    # ps-based — a ps `-o command=` miss (format varies by shell/exec/OS) would
    # read a live loop as dead and delete its tree. The cost of the other direction
    # (a recycled pid keeps a dead orphan one extra run) is trivial and self-heals:
    # the pid dies, the next --orphans reclaims it.
    pid=$(cat "$wt/.loop/run.pid" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      fnote "[$id] a live process (pid $pid) holds .loop/run.pid in this worktree — not cleaning; stop it first"
      continue
    fi
    [ ! -d "$wt" ] || git worktree remove --force "$wt" >/dev/null 2>&1 || true
    git branch -D "loop/$id" >/dev/null 2>&1 || true
    if git rev-parse -q --verify "loop/$id" >/dev/null 2>&1; then
      # never silently leave an orphan branch behind (git busy — e.g. a supervisor merging)
      fnote "[$id] warning: branch loop/$id could not be deleted — remove manually: git branch -D loop/$id"
    fi
    journal "$id" ORPHAN_CLEANED ""
    fnote "[$id] orphan cleaned (worktree/branch removed; it had no queue entry)"
  done
  [ "$any" = 1 ] || fnote "no orphans found"
  git worktree prune 2>/dev/null || true
}

clean_one() { # $1 id, $2 force
  local id="$1" force="$2" qd wt branch slot=""
  qd=$(task_qdir "$id")
  [ -n "$qd" ] || { fnote "unknown task: $id"; return 0; }
  if [ "$qd" != "done" ] && [ "$force" != "1" ]; then
    fnote "[$id] not merged (in $qd/) — kept for inspection; force with: ./loop.sh fleet clean $id --force"
    return 0
  fi
  case "$(renv_get "$id" PHASE "")" in
    CONTRACT_GEN|RUNNING)
      if task_pid_alive "$id"; then
        fnote "[$id] still running — stop it first: ./loop.sh fleet stop $id"
        return 0
      fi
      ;;
  esac
  wt=$(renv_get "$id" WT "")
  branch=$(renv_get "$id" BRANCH "")
  # approval-store hygiene: compute the worktree's slot BEFORE the worktree is
  # removed (its git dir is unresolvable afterwards). Removal is best-effort —
  # a leftover slot is ~130 bytes of garbage, swept wholesale by `uninstall`.
  if [ "$(approval_home)" != "repo" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
    slot=$(cd "$wt" 2>/dev/null && approval_slot) || slot=""
  fi
  if [ -n "$wt" ]; then git worktree remove --force "$wt" >/dev/null 2>&1 || true; fi
  [ -z "$slot" ] || rm -rf "$slot" 2>/dev/null || true
  if [ -n "$branch" ]; then git branch -D "$branch" >/dev/null 2>&1 || true; fi
  if [ -n "$branch" ] && git rev-parse -q --verify "$branch" >/dev/null 2>&1; then
    # never silently leave an orphan branch behind (git busy — e.g. a supervisor merging)
    fnote "[$id] warning: branch $branch could not be deleted — remove manually: git branch -D $branch"
  fi
  rm -rf "${RUNS_DIR:?}/${id:?}" "$RUNS_DIR/$id.env"
  rm -f "$QUEUE_DIR/$qd/$id.md"
  journal "$id" CLEANED "from $qd"
  fnote "[$id] cleaned (worktree + branch removed)"
}

cmd_fleet_unlock() {
  if supervisor_alive; then
    fdie "supervisor pid $(supervisor_pid) is alive — not removing its lock"
  fi
  # unconditional removal (release_lock is owner-checked and would no-op here):
  # the holder was just verified dead, and this is an explicit human command
  rm -rf "$LOCK_DIR"
  fnote "lock removed"
}

cmd_fleet() { # ./loop.sh fleet <subcommand> — the former standalone fleet.sh surface
  local sub="${1:-}"
  if [ $# -gt 0 ]; then shift; fi
  case "$sub" in
    run)     cmd_fleet_run "$@" ;;
    add)     cmd_fleet_add "$@" ;;
    approve) cmd_fleet_approve "$@" ;;
    status)  cmd_fleet_status "$@" ;;
    report)  cmd_fleet_report "$@" ;;
    logs)    cmd_fleet_logs "$@" ;;
    stop)    cmd_fleet_stop "$@" ;;
    resume)  cmd_fleet_resume "$@" ;;
    ack-plan) cmd_fleet_ack_plan "$@" ;;
    merge)   cmd_fleet_merge "$@" ;;
    clean)   cmd_fleet_clean "$@" ;;
    unlock)  cmd_fleet_unlock ;;
    ""|-h|--help|help) fleet_usage ;;
    *) fleet_usage; exit 2 ;;
  esac
}

# ---------- decomposition (supervisor: approved master contract -> task plan) ----------
# The single entry point's routing brain: after the human approves the MASTER
# contract, /loop-decompose splits it into the smallest set of non-conflicting
# tasks (.loop/docs/task-plan.md, fixed grammar). A deterministic parser +
# validator (unique ids, resolvable+acyclic DEPENDS, exact REQ coverage, task
# cap) gates every plan; an independent read-only review gates the boundaries.
# n=1 routes to the classic in-place loop; n>1 enqueues into the fleet.

plan_perr() { echo "task-plan: $*" >&2; }

plan_meta() { # $1 out-dir, $2 id, $3 key -> value (parsed, never sourced)
  grep -E "^$3=" "$1/$2.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

parse_task_plan() { # $1 plan-file, $2 out-dir — stdout: task ids in file order.
  # Strict fixed grammar (see the loop-decompose skill): TASK blocks between the
  # TASK-PLAN markers, keys at column 0, body between BODY-BEGIN/BODY-END.
  # Writes <out>/<id>.body and <out>/<id>.meta. Nonzero + stderr on violation.
  local plan="$1" out="$2"
  local in_plan=0 in_task=0 in_body=0 id="" summary="" depends="" scope="" reqs="" line n=0 seen=""
  [ -f "$plan" ] || { plan_perr "missing file: $plan"; return 1; }
  rm -rf "${out:?}"
  mkdir -p "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$in_plan" = 0 ]; then
      [ "$line" = "<!-- TASK-PLAN-BEGIN v1 -->" ] && in_plan=1
      continue
    fi
    [ "$in_plan" = 1 ] || continue
    if [ "$in_body" = 1 ]; then
      case "$line" in
        BODY-END) in_body=2 ;;
        BODY-BEGIN|TASK-END|"TASK: "*|"<!-- TASK-PLAN-"*)
          plan_perr "line $n: marker '$line' inside the body of '$id'"; return 1 ;;
        *) printf '%s\n' "$line" >> "$out/$id.body" ;;
      esac
      continue
    fi
    case "$line" in
      "<!-- TASK-PLAN-END -->")
        [ "$in_task" = 0 ] || { plan_perr "line $n: plan ends inside task '$id'"; return 1; }
        in_plan=2 ;;
      "TASK: "*)
        [ "$in_task" = 0 ] || { plan_perr "line $n: TASK before TASK-END of '$id'"; return 1; }
        id="${line#TASK: }"
        printf '%s' "$id" | grep -qE '^[a-z0-9][a-z0-9-]{0,23}$' \
          || { plan_perr "line $n: bad task id '$id' (want [a-z0-9][a-z0-9-], max 24 chars)"; return 1; }
        case " $seen " in *" $id "*) plan_perr "line $n: duplicate task id '$id'"; return 1 ;; esac
        in_task=1; in_body=0; summary=""; depends=""; scope=""; reqs=""
        : > "$out/$id.body" ;;
      "SUMMARY: "*)
        { [ "$in_task" = 1 ] && [ -z "$summary" ]; } || { plan_perr "line $n: misplaced/duplicate SUMMARY"; return 1; }
        summary="${line#SUMMARY: }" ;;
      "DEPENDS: "*)
        { [ "$in_task" = 1 ] && [ -z "$depends" ]; } || { plan_perr "line $n: misplaced/duplicate DEPENDS"; return 1; }
        depends="${line#DEPENDS: }" ;;
      "SCOPE: "*)
        { [ "$in_task" = 1 ] && [ -z "$scope" ]; } || { plan_perr "line $n: misplaced/duplicate SCOPE"; return 1; }
        scope="${line#SCOPE: }" ;;
      "REQS: "*)
        { [ "$in_task" = 1 ] && [ -z "$reqs" ]; } || { plan_perr "line $n: misplaced/duplicate REQS"; return 1; }
        reqs="${line#REQS: }" ;;
      BODY-BEGIN)
        [ "$in_task" = 1 ] || { plan_perr "line $n: BODY-BEGIN outside a task"; return 1; }
        { [ -n "$summary" ] && [ -n "$depends" ] && [ -n "$scope" ] && [ -n "$reqs" ]; } \
          || { plan_perr "line $n: task '$id' is missing SUMMARY/DEPENDS/SCOPE/REQS before BODY-BEGIN"; return 1; }
        in_body=1 ;;
      TASK-END)
        { [ "$in_task" = 1 ] && [ "$in_body" = 2 ]; } || { plan_perr "line $n: TASK-END without a completed body"; return 1; }
        [ -s "$out/$id.body" ] || { plan_perr "line $n: task '$id' has an empty body"; return 1; }
        {
          echo "SUMMARY=$summary"
          echo "DEPENDS=$depends"
          echo "SCOPE=$scope"
          echo "REQS=$reqs"
        } > "$out/$id.meta"
        seen="$seen $id"
        printf '%s\n' "$id"
        in_task=0; in_body=0; id="" ;;
      "") ;;
      *) plan_perr "line $n: unexpected line inside the plan block: $line"; return 1 ;;
    esac
  done < "$plan"
  [ "$in_plan" = 2 ] || { plan_perr "missing or unterminated TASK-PLAN markers"; return 1; }
  [ -n "$seen" ] || { plan_perr "no TASK blocks in the plan"; return 1; }
  return 0
}

plan_ancestors() { # $1 out-dir, $2 "plan ids", $3 id -> in-plan transitive DEPENDS
  # closure, space-joined. Callers run the Kahn check first, so the walk
  # terminates; the visited set guards it regardless.
  local out="$1" plan_ids="$2" frontier="$3" next anc="" d dep deps
  while [ -n "$frontier" ]; do
    next=""
    for d in $frontier; do
      deps=$(plan_meta "$out" "$d" DEPENDS)
      [ "$deps" = "-" ] && continue
      for dep in $(printf '%s' "$deps" | tr ',' ' '); do
        case " $plan_ids " in *" $dep "*) ;; *) continue ;; esac
        case " $anc " in *" $dep "*) ;; *) anc="$anc $dep"; next="$next $dep" ;; esac
      done
    done
    frontier="$next"
  done
  printf '%s' "${anc# }"
}

check_req_chains() { # $1 out-dir, $2 "plan ids", $3 "topo ids" — a REQ owned by
  # several tasks is legal ONLY when it has a single COMPLETING OWNER: the
  # topo-last owner must be a DEPENDS-descendant (plan_ancestors) of EVERY
  # other owner. Two shapes pass, nothing else:
  #   chain:     p1 -> p2 -> p3           (sequential phases)
  #   fork-join: p1 -> {c ∥ d} -> join    (parallel branches; the join owns the
  #                                        REQ too — ownership IS the fork
  #                                        declaration)
  # Parallel owners with no owning join have no completing owner -> reject.
  # The completing owner certifies the REQ in full; earlier owners are
  # phase/branch-scoped. Uniqueness is structural, not topo-order luck: when no
  # owner descends from all others, whichever sorts last is missing a sibling
  # from its ancestor set -> deterministic rejection.
  local out="$1" plan_ids="$2" topo="$3" id req all="" owners last anc b
  for id in $plan_ids; do
    all="$all $(plan_meta "$out" "$id" REQS | tr ',' ' ')"
  done
  # shellcheck disable=SC2086  # word-split on purpose: one REQ per line
  for req in $(printf '%s\n' $all | grep -v '^$' | sort -u); do
    owners=""
    for id in $topo; do
      case ",$(plan_meta "$out" "$id" REQS | tr -d ' ')," in
        *",$req,"*) owners="$owners $id" ;;
      esac
    done
    # shellcheck disable=SC2086  # word-split on purpose: positional owner list
    set -- $owners
    [ $# -le 1 ] && continue
    last=""
    for b in "$@"; do last="$b"; done
    anc=" $(plan_ancestors "$out" "$plan_ids" "$last") "
    for b in "$@"; do
      [ "$b" = "$last" ] && continue
      case "$anc" in
        *" $b "*) ;;
        *) plan_perr "REQ '$req' is shared by tasks '$b' and '$last' with no single completing owner (a shared REQ needs a strictly sequential DEPENDS chain, or a fork-join whose final owner depends on all other owners)"
           return 1 ;;
      esac
    done
  done
  return 0
}

validate_plan_structure() { # $1 out-dir, $2 "id id ...", $3 verdict-n(""=skip), $4 cap, $5 external-dep-ids
  # Deterministic, model-free, REQ-free checks. stdout: topological enqueue order.
  # $5 lists ids a DEPENDS may reference that are satisfied outside this plan
  # (REPLAN tasks may depend on already-merged tasks). Nonzero + stderr on error.
  local out="$1" plan_ids="$2" vn="$3" cap="$4" known="$5"
  local n=0 id dep deps
  local remaining topo="" progressed pick rest
  for id in $plan_ids; do n=$((n + 1)); done
  [ "$n" -ge 1 ] || { plan_perr "no tasks"; return 1; }
  [ "$n" -le "$cap" ] || { plan_perr "$n tasks exceeds FLEET_MAX_TASKS=$cap"; return 1; }
  if [ -n "$vn" ] && [ "$vn" != "$n" ]; then
    plan_perr "the DECOMPOSE verdict says n=$vn but the plan defines $n tasks"; return 1
  fi
  for id in $plan_ids; do
    deps=$(plan_meta "$out" "$id" DEPENDS)
    [ "$deps" = "-" ] && continue
    for dep in $(printf '%s' "$deps" | tr ',' ' '); do
      [ "$dep" != "$id" ] || { plan_perr "task '$id' depends on itself"; return 1; }
      case " $plan_ids $known " in
        *" $dep "*) ;;
        *) plan_perr "task '$id' depends on unknown task '$dep'"; return 1 ;;
      esac
    done
  done
  # Kahn's algorithm: repeatedly peel tasks whose in-plan deps are all peeled;
  # leftovers with no progress = a dependency cycle. Output order = enqueue order.
  remaining="$plan_ids"
  while [ -n "$(printf '%s' "$remaining" | tr -d ' ')" ]; do
    progressed=0
    rest=""
    for id in $remaining; do
      deps=$(plan_meta "$out" "$id" DEPENDS)
      pick=1
      if [ "$deps" != "-" ]; then
        for dep in $(printf '%s' "$deps" | tr ',' ' '); do
          case " $plan_ids " in
            *" $dep "*) case " $topo " in *" $dep "*) ;; *) pick=0 ;; esac ;;
          esac
        done
      fi
      if [ "$pick" = 1 ]; then
        topo="$topo $id"
        progressed=1
      else
        rest="$rest $id"
      fi
    done
    remaining="$rest"
    if [ "$progressed" = 0 ]; then
      plan_perr "dependency cycle among:$remaining"
      return 1
    fi
  done
  # shellcheck disable=SC2086  # word-split on purpose: one id per line
  printf '%s\n' $topo
  return 0
}

validate_plan_reqs() { # $1 out-dir, $2 "id id ...", $3 "topo ids"
  # REQ ownership: every master REQ covered, nothing invented, every task owns
  # at least one REQ. A REQ owned by several tasks must have a single
  # completing owner — a phased chain or a fork-join (check_req_chains).
  local out="$1" plan_ids="$2" topo="$3"
  local id reqs all_reqs="" master_reqs plan_reqs
  master_reqs=$(grep -oE 'REQ-[0-9]+' .loop/docs/product-contract.md 2>/dev/null | sort -u)
  [ -n "$master_reqs" ] || { plan_perr "the master contract defines no REQ-xxx ids"; return 1; }
  for id in $plan_ids; do
    reqs=$(plan_meta "$out" "$id" REQS | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$' || true)
    [ -n "$reqs" ] || { plan_perr "task '$id' owns no REQs"; return 1; }
    all_reqs="$all_reqs
$reqs"
  done
  all_reqs=$(printf '%s\n' "$all_reqs" | grep -v '^$')
  plan_reqs=$(printf '%s\n' "$all_reqs" | sort -u)
  if [ "$plan_reqs" != "$master_reqs" ]; then
    plan_perr "REQ coverage mismatch — master: $(printf '%s' "$master_reqs" | tr '\n' ' ')/ plan: $(printf '%s' "$plan_reqs" | tr '\n' ' ')"
    return 1
  fi
  check_req_chains "$out" "$plan_ids" "$topo" || return 1
  return 0
}

validate_task_plan() { # $1 out-dir, $2 "id id ...", $3 verdict-n(""=skip), $4 cap, $5 external-dep-ids
  # Deterministic, model-free checks. stdout: topological enqueue order.
  local topo
  topo=$(validate_plan_structure "$1" "$2" "$3" "$4" "$5") || return 1
  validate_plan_reqs "$1" "$2" "$(printf '%s\n' "$topo" | tr '\n' ' ')" || return 1
  printf '%s\n' "$topo"
  return 0
}

enqueue_task_planned() { # $1 id, $2 body-file, $3 out-dir — fixed-id enqueue of a
  # decomposed task (parked manual tasks may share the queue — the enqueue loop
  # in cmd_decompose_flow fails loudly on an id collision before calling this)
  local id="$1" body="$2" out="$3" deps
  { [ -z "$(task_qdir "$id")" ] && [ ! -f "$RUNS_DIR/$id.env" ]; } \
    || { plan_perr "task id '$id' already exists in the queue"; return 1; }
  cp "$body" "$QUEUE_DIR/tmp/$id.$$.md" || return 1
  ln "$QUEUE_DIR/tmp/$id.$$.md" "$QUEUE_DIR/new/$id.md" || { rm -f "$QUEUE_DIR/tmp/$id.$$.md"; return 1; }
  rm -f "$QUEUE_DIR/tmp/$id.$$.md"
  renv_set "$id" SUMMARY "$(plan_meta "$out" "$id" SUMMARY)"
  renv_set "$id" SRC "task-plan"
  renv_set "$id" AUTO 1
  renv_set "$id" PLANNED 1
  renv_set "$id" REQS "$(plan_meta "$out" "$id" REQS)"
  renv_set "$id" SCOPE "$(plan_meta "$out" "$id" SCOPE)"
  deps=$(plan_meta "$out" "$id" DEPENDS)
  [ "$deps" = "-" ] || renv_set "$id" DEPENDS_ON "$deps"
  renv_set "$id" ADDED_AT "$(utcnow)"
  journal "$id" ADDED "planned: $(plan_meta "$out" "$id" SUMMARY)"
}

decompose_plan_hash() { # contract + plan — the reuse marker's identity
  cat .loop/docs/product-contract.md .loop/docs/task-plan.md 2>/dev/null | sha256
}

plan_rationale() { # first prose line of the task plan (≤200 chars) — the skill
  # mandates free-prose rationale before the machine block; surface it in the
  # journal so "why single-task?" is answerable without opening the plan file
  sed -n '/<!-- TASK-PLAN-BEGIN/q;p' .loop/docs/task-plan.md 2>/dev/null \
    | grep -v '^#' | grep -m1 . | cut -c1-200
}

normalize_task_plan() { # $1 plan-file — deterministically repair MECHANICAL
  # task-id violations (charset/length) before parsing: slugify + truncate to 24
  # + strip trailing hyphens, rewriting the TASK: line and every DEPENDS:
  # reference in place (plan hash, queue ids and the human-auditable file stay
  # consistent). Anything non-mechanical — empty result, still-invalid,
  # collision with another plan id — is left untouched for the validator, whose
  # feedback reaches the retry. Round-tripping a 30-char id to the model burned
  # two calls in production; a rename is a decision the harness can make itself.
  local plan="$1" all_ids id new maplist=""
  [ -f "$plan" ] || return 0
  # ids come from INSIDE the machine block only — prose above the markers may
  # legally contain "TASK: "-looking lines and must neither be rewritten nor
  # veto a legitimate rename via the collision check
  all_ids=$(sed -n '/^<!-- TASK-PLAN-BEGIN v1 -->$/,/^<!-- TASK-PLAN-END -->$/p' "$plan" \
    | grep -E '^TASK: ' | sed 's/^TASK: //')
  [ -n "$all_ids" ] || return 0
  while IFS= read -r id; do
    printf '%s' "$id" | grep -qE '^[a-z0-9][a-z0-9-]{0,23}$' && continue
    # a tab inside an id would corrupt the tab-separated map line (the awk
    # would skip it while the journal loop still announced a rename) — leave
    # such pathological ids to the validator
    case "$id" in *"	"*) continue ;; esac
    new=$(printf '%s' "$id" | slugify | sed -E 's/-+$//')
    printf '%s' "$new" | grep -qE '^[a-z0-9][a-z0-9-]{0,23}$' || continue
    # collision with any other plan id (original or an already-chosen rename)?
    case "
$all_ids
$(printf '%s' "$maplist" | cut -f2)
" in
      *"
$new
"*) continue ;;
    esac
    maplist="${maplist}${id}	${new}
"
  done <<EOF
$all_ids
EOF
  [ -n "$maplist" ] || return 0
  # the map rides a FILE, not `awk -v` — BSD awk rejects newlines in -v values
  printf '%s' "$maplist" > "$plan.map.$$"
  if ! awk -v mapfile="$plan.map.$$" '
    BEGIN {
      while ((getline line < mapfile) > 0) {
        if (split(line, kv, "\t") == 2 && kv[1] != "") M[kv[1]] = kv[2]
      }
      close(mapfile)
      in_plan = 0
      in_body = 0
    }
    /^<!-- TASK-PLAN-BEGIN v1 -->$/ { in_plan = 1 }
    /^<!-- TASK-PLAN-END -->$/      { in_plan = 0 }
    /^BODY-BEGIN$/ { in_body = 1 }
    /^BODY-END$/   { in_body = 0 }
    in_plan && !in_body && /^TASK: / { id = substr($0, 7); if (id in M) { print "TASK: " M[id]; next } }
    in_plan && !in_body && /^DEPENDS: / {
      deps = substr($0, 10)
      if (deps != "-") {
        m = split(deps, d, ",")
        out = ""
        for (j = 1; j <= m; j++) {
          t = d[j]; gsub(/^[ \t]+|[ \t]+$/, "", t)
          if (t in M) t = M[t]
          out = out (j > 1 ? "," : "") t
        }
        print "DEPENDS: " out; next
      }
    }
    { print }
  ' "$plan" > "$plan.norm.$$"; then
    # rewrite failed: leave the plan as-is for the validator (fail open to the
    # existing feedback loop, never half-rewrite)
    rm -f "$plan.norm.$$" "$plan.map.$$"
    return 0
  fi
  mv "$plan.norm.$$" "$plan"
  rm -f "$plan.map.$$"
  while IFS='	' read -r id new; do
    [ -n "$id" ] || continue
    journal_append "decompose" "DECOMPOSE_NORMALIZED" "task id '$id' -> '$new' (mechanical: charset/length)"
    note "decompose: normalized task id '$id' -> '$new'"
  done <<EOF
$maplist
EOF
  return 0
}

run_decompose_once() { # $1 label, $2 optional prompt suffix (retry feedback pointer)
  # — one generate+parse+validate round.
  # Success: ORCH_TOPO (space-separated topological order) + ORCH_N set, rc 0.
  # Failure: .loop/decompose-feedback.md written for the retry, rc 1. The file
  # must survive into the NEXT attempt (the skill reads it to fix the violations)
  # — it is cleared on success here and at the start of a fresh flow, never
  # between attempts.
  local label="$1" res verdict vn ids topo stray errf=.loop/decompose-parse.err
  ORCH_TOPO=""; ORCH_N=0
  if ! run_claude "$label" "/loop-decompose${2:+ $2}" "$MODEL_DECOMPOSE" full DECOMPOSE; then
    echo "decompose agent call failed${AGENT_FAIL_DIAG:+ — $AGENT_FAIL_DIAG} (evidence: .loop/logs/failed/)" > .loop/decompose-feedback.md
    return 1
  fi
  # containment: this step may only write under .loop/ (the plan file). Any
  # project-file diff means the decomposer did implementation work — fail
  # closed to a human (the pre-decompose snapshot protects user work).
  stray=$(git status --porcelain -- . ':(exclude).loop' 2>/dev/null || true)
  if [ -n "$stray" ]; then
    finish RISK_REQUIRES_APPROVAL "decompose step changed project files (it may only write .loop/docs/task-plan.md): $(echo "$stray" | head -3 | tr '\n' ' ')"
  fi
  res=$(agent_result "$label")
  verdict=$(extract_verdict "$res" "DECOMPOSE: TASKS n=[0-9]+")
  if [ -z "$verdict" ]; then
    echo "the reply had no parseable 'DECOMPOSE: TASKS n=<N>' last line" > .loop/decompose-feedback.md
    return 1
  fi
  vn=$(printf '%s' "$verdict" | sed -E 's/.*n=([0-9]+).*/\1/')
  normalize_task_plan .loop/docs/task-plan.md
  if ! ids=$(parse_task_plan .loop/docs/task-plan.md .loop/fleet/plan 2> "$errf" | tr '\n' ' '); then
    cat "$errf" > .loop/decompose-feedback.md
    rm -f "$errf"
    return 1
  fi
  if ! topo=$(validate_task_plan .loop/fleet/plan "$ids" "$vn" "$(fcfg FLEET_MAX_TASKS 12)" "" 2> "$errf" | tr '\n' ' '); then
    cat "$errf" > .loop/decompose-feedback.md
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"
  rm -f .loop/decompose-feedback.md
  ORCH_TOPO="${topo% }"
  ORCH_N="$vn"
  return 0
}

run_decompose_review() { # independent read-only check of the task plan itself.
  # Mirrors run_contract_review: retry-once on format failure, fail-closed.
  # 0 = APPROVE; 1 = REVISE (.loop/decompose-review-feedback.md written).
  local res="" verdict="" prompt="/loop-decompose-review"
  note "decompose review: independent check of the task plan ($MODEL_REVIEW, read-only)"
  for _ in 1 2; do
    run_claude "decompose-review" "$prompt" "$MODEL_REVIEW" reader REVIEW || continue
    res=$(agent_result "decompose-review")
    verdict=$(extract_verdict "$res" "DECOMPOSE-REVIEW: (APPROVE|REVISE)")
    [ -z "$verdict" ] || break
    prompt="/loop-decompose-review (FORMAT REMINDER: the LAST line of your reply must be exactly 'DECOMPOSE-REVIEW: APPROVE <summary>' or 'DECOMPOSE-REVIEW: REVISE <must-fix list>' — plain text, no code fence. Your previous attempt contained no parseable verdict.)"
  done
  if [ -z "$res" ]; then
    journal_append "decompose" "DECOMPOSE_REVIEW_ERROR" "decompose reviewer call failed twice"
    die "decompose review unavailable (see $(agent_log_path decompose-review err)) — review .loop/docs/task-plan.md yourself, or disable with LOOP_DECOMPOSE_REVIEW=0"
  fi
  if [ -z "$verdict" ]; then
    verdict="DECOMPOSE-REVIEW: REVISE (unparseable reviewer output after a format-reminder retry — treated as revise)"
    res="$verdict
$res"
  fi
  if [ "${verdict#DECOMPOSE-REVIEW: APPROVE}" != "$verdict" ]; then
    rm -f .loop/decompose-review-feedback.md
    journal_append "decompose" "DECOMPOSE_REVIEW_APPROVE" "$verdict"
    note "decompose review -> APPROVE"
    return 0
  fi
  {
    echo "# Decompose reviewer feedback — the task plan was rejected"
    echo
    printf '%s\n' "$res"
  } > .loop/decompose-review-feedback.md
  journal_append "decompose" "DECOMPOSE_REVIEW_REVISE" "$verdict"
  note "decompose review -> REVISE (feedback: .loop/decompose-review-feedback.md)"
  return 1
}

cmd_decompose_flow() { # $1 force(0|1), $2 enqueue(0|1) — the routing brain.
  # Requires verify_approval + load_config + load_models done by the caller.
  # rc 0: fleet mode — ORCH_TOPO/ORCH_N set (tasks enqueued when $2=1).
  # rc 1: single mode (n=1; nothing enqueued). Terminal escalations finish().
  local force="$1" enqueue="$2" t n
  ensure_fleet_dirs
  if [ -n "$(tasks_in claimed)" ] || planned_pending || supervisor_alive; then
    die "fleet tasks are already claimed or planned, or a fleet supervisor is running — resume/join it (./loop.sh run), or inspect it first (./loop.sh fleet status)"
  fi
  if [ -n "$(tasks_in new)" ]; then
    # a PARKED queue (manual `add` before the first run) never blocks the plan:
    # a parallel plan's orchestration dispatches parked tasks alongside the
    # planned ones; a single-task plan runs in place and leaves them parked
    note "manual task(s) already queued (./loop.sh add) — a parallel plan dispatches them alongside the planned tasks; a single-task plan leaves them parked (./loop.sh fleet run)"
  fi
  # snapshot before the decomposer runs, so its containment check sees only its
  # own writes and user work is already committed
  if [ -n "$(git status --porcelain)" ]; then
    note "working tree dirty — creating pre-decompose snapshot commit"
    git add -A
    git commit -q -m "loop: pre-decompose snapshot"
  fi

  local reused=0 ids topo
  if [ "$force" != 1 ] && [ -f .loop/docs/task-plan.md ] && [ -f .loop/decompose-approved ] \
     && [ "$(cat .loop/decompose-approved)" = "$(decompose_plan_hash)" ]; then
    # the approved plan still matches this contract: re-validate deterministically
    # (free) and skip the model calls entirely
    if ids=$(parse_task_plan .loop/docs/task-plan.md .loop/fleet/plan 2>/dev/null | tr '\n' ' ') \
       && topo=$(validate_task_plan .loop/fleet/plan "$ids" "" "$(fcfg FLEET_MAX_TASKS 12)" "" 2>/dev/null | tr '\n' ' '); then
      ORCH_TOPO="${topo% }"
      ORCH_N=0
      for t in $ORCH_TOPO; do ORCH_N=$((ORCH_N + 1)); done
      journal_append "decompose" "DECOMPOSE_REUSE" "reusing the approved task plan (n=$ORCH_N)$(r=$(plan_rationale); printf '%s' "${r:+ — rationale: $r}")"
      note "reusing the approved task plan (n=$ORCH_N) — regenerate with: ./loop.sh decompose --force"
      reused=1
    fi
  fi

  if [ "$reused" = 0 ]; then
    note "decomposing the approved contract into tasks (/loop-decompose, $MODEL_DECOMPOSE)"
    # fresh flow: drop feedback left over from a previous (possibly abandoned)
    # decompose — the contract may have changed since it was written
    rm -f .loop/decompose-feedback.md
    if ! run_decompose_once "decompose-1"; then
      journal_append "decompose" "DECOMPOSE_INVALID" "$(head -3 .loop/decompose-feedback.md 2>/dev/null | tr '\n' '; ')"
      note "decompose attempt 1 invalid — retrying once against the validator feedback"
      if ! run_decompose_once "decompose-2" "(VALIDATOR FEEDBACK: your previous plan was rejected by the deterministic validator — read .loop/decompose-feedback.md and fix every listed violation)"; then
        journal_append "decompose" "DECOMPOSE_INVALID" "$(head -3 .loop/decompose-feedback.md 2>/dev/null | tr '\n' '; ')"
        finish NEEDS_SPEC_DECISION "decomposition failed twice (.loop/decompose-feedback.md) — split the work manually (./loop.sh add), or run single: ./loop.sh run --single"
      fi
    fi
    if [ "${LOOP_DECOMPOSE_REVIEW:-1}" != "0" ]; then
      if ! run_decompose_review; then
        note "regenerating the task plan once against the reviewer feedback"
        journal_append "decompose" "DECOMPOSE_REGEN" "regenerating after decompose-review REVISE"
        if ! run_decompose_once "decompose-3" || ! run_decompose_review; then
          finish NEEDS_SPEC_DECISION "task plan failed the independent decompose review (.loop/decompose-review-feedback.md) — fix the plan or contract, or run single: ./loop.sh run --single"
        fi
      fi
    fi
    decompose_plan_hash > .loop/decompose-approved
    commit_if_changes "loop: task plan"
  fi

  if [ "$ORCH_N" = 1 ]; then
    journal_append "decompose" "DECOMPOSE_SINGLE" "plan yields one task — running in place against the master contract$(r=$(plan_rationale); printf '%s' "${r:+ — rationale: $r}")"
    note "decomposition: one task — running the classic in-place loop"
    return 1
  fi
  journal_append "decompose" "DECOMPOSE_OK" "n=$ORCH_N tasks: $ORCH_TOPO"
  if [ "$enqueue" = 1 ]; then
    # plan ids double as queue ids: leftovers from a PREVIOUS orchestration
    # (done/failed) would collide — make the operator archive them first
    if [ -n "$(tasks_in "done")$(tasks_in failed)" ]; then
      die "previous fleet tasks remain in the queue — if the last orchestration was interrupted or stopped early, resume it instead: ./loop.sh run (queue dispatch + the integration gate). Archiving them (./loop.sh fleet clean --done) skips the mandatory integration gate for that run — only do that after a fully completed run (and inspect failed/: ./loop.sh fleet status)"
    fi
    # partial-enqueue marker: a crash between the first and the last publish
    # would otherwise dispatch a plan with partial REQ coverage on resume.
    # Written BEFORE the loop (same-dir tmp+mv), removed after it; content =
    # the plan identity hash, so the orchestration resume can verify it is
    # topping up the SAME approved plan (repair_pending_enqueue).
    decompose_plan_hash > ".loop/fleet/.enqueue-pending.tmp.$$"
    mv -f ".loop/fleet/.enqueue-pending.tmp.$$" .loop/fleet/enqueue-pending
    for t in $ORCH_TOPO; do
      # skip-if-exists: the resume repair re-runs this loop over a partial
      # enqueue — already-published ids must not fail the whole flow. Only a
      # PLANNED entry counts as already published: a parked MANUAL task holding
      # a plan id would otherwise be silently adopted and that plan task's REQ
      # coverage lost — fail loudly instead so the operator renames/cleans it
      if [ -n "$(task_qdir "$t")" ] || [ -f "$RUNS_DIR/$t.env" ]; then
        [ "$(renv_get "$t" PLANNED 0)" = "1" ] \
          || finish BLOCKED "plan task id '$t' collides with a queued manual task — remove or rename it (./loop.sh fleet clean $t --force) and run again"
        continue
      fi
      enqueue_task_planned "$t" ".loop/fleet/plan/$t.body" ".loop/fleet/plan" \
        || finish BLOCKED "could not enqueue planned task '$t' — inspect ./loop.sh fleet status, then ./loop.sh run"
    done
    rm -f .loop/fleet/enqueue-pending
    journal_append "decompose" "PLAN_ENQUEUED" "n=$ORCH_N planned tasks published: $ORCH_TOPO"
    note "enqueued $ORCH_N planned tasks (topological order): $ORCH_TOPO"
  fi
  return 0
}

repair_pending_enqueue() { # .loop/fleet/enqueue-pending survived a crash between
  # the decompose approval and the last planned publish: the queue may cover only
  # part of the approved plan. Re-derive the plan DETERMINISTICALLY (no model),
  # verify the marker recorded the same plan identity, and top up the missing
  # ids with the same skip-if-exists loop. Fail closed to a human on any
  # mismatch/parse failure — never dispatch a plan you cannot re-derive.
  local marker_hash ids topo t
  marker_hash=$(cat .loop/fleet/enqueue-pending 2>/dev/null || echo "")
  if [ "$marker_hash" != "$(decompose_plan_hash)" ]; then
    finish NEEDS_SPEC_DECISION "an interrupted enqueue left .loop/fleet/enqueue-pending, but its recorded plan identity no longer matches the contract+plan — the partial enqueue cannot be reconstructed safely; inspect ./loop.sh fleet status, regenerate the plan (./loop.sh decompose --force) or clean the queue"
  fi
  if ! ids=$(parse_task_plan .loop/docs/task-plan.md .loop/fleet/plan 2>/dev/null | tr '\n' ' ') \
     || ! topo=$(validate_task_plan .loop/fleet/plan "$ids" "" "$(fcfg FLEET_MAX_TASKS 12)" "" 2>/dev/null | tr '\n' ' '); then
    finish NEEDS_SPEC_DECISION "could not re-derive the approved task plan while repairing an interrupted enqueue (.loop/docs/task-plan.md) — regenerate it: ./loop.sh decompose --force"
  fi
  topo="${topo% }"
  for t in $topo; do
    if [ -n "$(task_qdir "$t")" ] || [ -f "$RUNS_DIR/$t.env" ]; then continue; fi
    enqueue_task_planned "$t" ".loop/fleet/plan/$t.body" ".loop/fleet/plan" \
      || finish BLOCKED "could not enqueue planned task '$t' while repairing an interrupted enqueue — inspect ./loop.sh fleet status, then ./loop.sh run"
  done
  rm -f .loop/fleet/enqueue-pending
  journal_append "fleet" "FLEET_ENQUEUE_REPAIR" "re-derived the approved plan and topped up missing planned tasks: $topo"
  fnote "enqueue repair: interrupted plan publish completed (plan re-derived deterministically)"
}

on_orch_int() { # orchestration interrupt: children save state. The parent state
  # STAYS FLEET_RUNNING (interrupt ≡ crash — a kill -9 leaves it anyway), so the
  # ONLY path off it is a finish() inside a resumed orchestration: a bare
  # `./loop.sh run` (or no-arg `resume`) picks the run up even with an empty
  # queue and still walks the gate/evidence/final-eval tail — the integration
  # gate can never be skipped by following an interrupt. Explicit rewrite, not
  # just deletion: self-heals whatever an interrupted child half-wrote.
  echo FLEET_RUNNING > .loop/state 2>/dev/null || true
  on_supervisor_int
}

orch_park_interrupted() { # inside orchestration, an external `fleet stop <id>` is a
  # human intervention this process cannot adjudicate — park it for the human
  # instead of silently un-stopping it (auto-resume would make `fleet stop` a no-op)
  local id
  for id in $(tasks_in claimed); do
    [ "$(renv_get "$id" PHASE)" = "INTERRUPTED" ] || continue
    journal "$id" ORCH_INTERRUPTED_PARKED "stopped externally during orchestration"
    task_fail "$id" INTERRUPTED "stopped externally during orchestration — resume: ./loop.sh fleet resume $id, then ./loop.sh run"
  done
}

fleet_needs_human() { # progress requires an approval no in-process actor can grant:
  # every claimed task waits in PENDING_APPROVAL and nothing in new/ is claimable
  local id any=0
  for id in $(tasks_in new); do
    [ "$(deps_state "$id")" = "waiting" ] || return 1
  done
  for id in $(tasks_in claimed); do
    [ "$(renv_get "$id" PHASE)" = "PENDING_APPROVAL" ] || return 1
    any=1
  done
  [ "$any" -eq 1 ]
}

fleet_fingerprint() { # phase snapshot; equality across ticks = zero dispatch progress
  local id
  for id in $(all_task_ids); do
    echo "$id:$(task_qdir "$id"):$(renv_get "$id" PHASE "")"
  done | sort
}

orch_manual_failed() { # -> failed non-PLANNED, non-REPLANNED ids (space-joined)
  local id out=""
  for id in $(tasks_in failed); do
    [ "$(renv_get "$id" PLANNED 0)" = "1" ] && continue
    [ "$(renv_get "$id" RESULT "")" = "REPLANNED" ] && continue
    out="$out $id"
  done
  printf '%s' "$out"
}

orch_manual_merged() { # -> done non-PLANNED ids (space-joined; fixups are PLANNED=1)
  local id out=""
  for id in $(tasks_in "done"); do
    [ "$(renv_get "$id" PLANNED 0)" = "1" ] && continue
    out="$out $id"
  done
  printf '%s' "$out"
}

write_manual_manifest() { # manifest of manual (non-PLANNED) tasks already MERGED
  # into this orchestration — regenerated before every gate round so the gate
  # reviewer (and a fix-up supervisor) can tell human-sanctioned side-work from
  # unrequested drift. Removed when empty (the common case: prompts unchanged).
  local manifest=.loop/fleet/manual-manifest.md tmp=".loop/fleet/.manual-manifest.tmp.$$"
  local id branch base_ref any=0
  {
    echo "# Manual tasks merged into this orchestration (generated by loop.sh — do not edit)"
    for id in $(orch_manual_merged); do
      any=1
      echo
      echo "## $id"
      echo "- SUMMARY: $(renv_get "$id" SUMMARY "")"
      echo "- RESULT: $(renv_get "$id" RESULT "(not recorded — merged as NO_OP)")"
      branch=$(renv_get "$id" BRANCH "")
      base_ref=$(renv_get "$id" BASE_REF "")
      if [ -n "$branch" ] && [ -n "$base_ref" ] && git rev-parse -q --verify "$branch" >/dev/null 2>&1; then
        echo "- FILES:"
        git diff --name-only "$base_ref..$branch" -- . ':(exclude).loop' 2>/dev/null | sed 's/^/  - /'
      else
        echo "- FILES: (branch cleaned — see .loop/docs/run-archive/$id/)"
      fi
    done
  } > "$tmp"
  if [ "$any" = 1 ]; then
    mv -f "$tmp" "$manifest"
  else
    rm -f "$tmp" "$manifest"
  fi
}

orch_check_failures() { # finish() on any non-superseded failed PLANNED task; else
  # return 0. Manual (non-PLANNED) tasks never abort the planned work mid-flight —
  # they are surfaced at the end of the run instead (orch_manual_failed).
  local id human="" other=""
  for id in $(tasks_in failed); do
    [ "$(renv_get "$id" PLANNED 0)" = "1" ] || continue
    case "$(renv_get "$id" RESULT "")" in
      REPLANNED) ;;   # superseded by a replacement — not a blocker
      NEEDS_HUMAN|NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|RISK_REQUIRES_APPROVAL|INTERRUPTED)
        human="$human $id" ;;
      *) other="$other $id" ;;
    esac
  done
  if [ -n "$human" ]; then
    finish NEEDS_SPEC_DECISION "fleet task(s) need a human decision:$human — see .loop/docs/decision-requests.md and ./loop.sh fleet status; after deciding: ./loop.sh fleet resume <id>, then ./loop.sh run"
  fi
  if [ -n "$other" ]; then
    finish BLOCKED "fleet task(s) failed:$other — inspect: ./loop.sh fleet status / ./loop.sh fleet logs <id>; then ./loop.sh fleet resume <id> and ./loop.sh run"
  fi
  return 0
}

integration_fixup() { # $1 base — ask the supervisor for EXACTLY ONE fix-up task
  # (read-only call; branches from the merged HEAD, so it sees all landed work)
  local base="$1" res="" verdict="" replan prompt label ids t n=0 deps dep qd req owner mtok=""
  local tmp=.loop/fleet/fixup.md out=.loop/fleet/fixup-plan
  mkdir -p .loop/supervise/integration
  git diff --name-only "$base" HEAD -- . ':(exclude).loop' > .loop/supervise/integration/changed-files.txt 2>/dev/null || true
  label="supervise-integration-$(cat .loop/fleet/fixup-count 2>/dev/null || echo 1)"
  # sanctioned manual side-work: the fix-up author must know those scopes are
  # human-approved, not drift to revert (same token the gate review carries)
  [ ! -f .loop/fleet/manual-manifest.md ] || mtok=" manual-tasks=.loop/fleet/manual-manifest.md"
  prompt="/loop-supervise mode=integration$mtok"
  for _ in 1 2; do
    if run_claude "$label" "$prompt" "$MODEL_SUPERVISE" reader SUPERVISE; then
      res=$(agent_result "$label")
      verdict=$(extract_verdict "$res" "SUPERVISE: (REPLAN|ESCALATE)")
      [ -z "$verdict" ] || break
      prompt="/loop-supervise mode=integration$mtok (FORMAT REMINDER: reply with exactly ONE fix-up task in a REPLAN-BEGIN/REPLAN-END block and the last line 'SUPERVISE: REPLAN <summary>', or 'SUPERVISE: ESCALATE <question>'.)"
    fi
  done
  case "$verdict" in
    "SUPERVISE: REPLAN"*) ;;
    *) journal_append "fleet" "FIXUP_ESCALATE" "${verdict:-no parseable SUPERVISE verdict}"; return 1 ;;
  esac
  replan=$(extract_between "$res" "REPLAN-BEGIN" "REPLAN-END")
  [ -n "$replan" ] || { journal_append "fleet" "FIXUP_INVALID" "REPLAN verdict without a block"; return 1; }
  {
    echo "<!-- TASK-PLAN-BEGIN v1 -->"
    printf '%s\n' "$replan"
    echo "<!-- TASK-PLAN-END -->"
  } > "$tmp"
  if ! ids=$(parse_task_plan "$tmp" "$out" 2> .loop/fleet/fixup.err | tr '\n' ' '); then
    journal_append "fleet" "FIXUP_INVALID" "$(head -2 .loop/fleet/fixup.err 2>/dev/null | tr '\n' '; ')"
    return 1
  fi
  ids="${ids% }"
  for t in $ids; do n=$((n + 1)); done
  [ "$n" = 1 ] || { journal_append "fleet" "FIXUP_INVALID" "integration fix-up must be exactly ONE task (got $n)"; return 1; }
  t="$ids"
  if [ -n "$(task_qdir "$t")" ] || [ -f "$RUNS_DIR/$t.env" ]; then
    journal_append "fleet" "FIXUP_INVALID" "fix-up id '$t' already exists"
    return 1
  fi
  deps=$(plan_meta "$out" "$t" DEPENDS)
  if [ "$deps" != "-" ]; then
    for dep in $(printf '%s' "$deps" | tr ',' ' '); do
      qd=$(task_qdir "$dep")
      [ -n "$qd" ] || { journal_append "fleet" "FIXUP_INVALID" "fix-up depends on unknown task '$dep'"; return 1; }
      # failed/ (REPLANNED included) would DEP_FAIL the fix-up at claim time
      [ "$qd" != "failed" ] || { journal_append "fleet" "FIXUP_INVALID" "fix-up depends on failed task '$dep'"; return 1; }
    done
  fi
  # cross-fleet REQ re-verification (belt — structurally unreachable today: the
  # queue is drained before the gate runs): a fix-up legitimately revisits merged
  # REQs (include_done=0) but must never collide with a live/parked task's scope
  for req in $(plan_meta "$out" "$t" REQS | tr ',' ' '); do
    if owner=$(req_owner_elsewhere "$req" "$t" 0); then
      journal_append "fleet" "FIXUP_INVALID" "fix-up claims $req owned by live task '$owner'"
      return 1
    fi
  done
  enqueue_task_planned "$t" "$out/$t.body" "$out" || return 1
  journal_append "fleet" "INTEGRATION_FIXUP" "enqueued fix-up task '$t'"
  fnote "[$t] integration fix-up enqueued (branches from the merged HEAD)"
  return 0
}

planned_pending() { # any PLANNED (orchestrated) task waiting in new/ or claimed/?
  local id
  for id in $(tasks_in new) $(tasks_in claimed); do
    [ "$(renv_get "$id" PLANNED 0)" = "1" ] && return 0
  done
  return 1
}

fleet_inflight() { # TRUE iff a bare run must RESUME an orchestration (and
  # --single/--fresh must refuse to start beside it): a LIVE supervisor (its
  # queue is being claimed right now — routing into resume hits the singleton
  # lock's loud refusal instead of decomposing/enqueueing beside it),
  # FLEET_RUNNING (live or crashed — even with a drained queue the integration
  # gate still has to run), or pending queue work that belongs to a STARTED
  # lifecycle: claimed tasks, queued PLANNED tasks (a crash between plan
  # enqueue and FLEET_START), or a late add over finished/failed tasks OF THE
  # CURRENT PLAN (.loop/decompose-approved survives a completed run but is
  # removed when a NEW task is defined — an old contract's leftover residue
  # must never capture the new contract's first run into a phantom resume; it
  # fails closed in cmd_decompose_flow instead). A new/ queue holding ONLY
  # never-claimed manual adds is a PARKED queue (./loop.sh add before the
  # first run), NOT an orchestration — resuming it would skip decompose
  # forever (no task plan, no FLEET_START, the planned work never attempted).
  # .loop/fleet/base-ref is deliberately not consulted (it is never cleaned
  # up, so it would misroute every repo that ever ran a fleet once).
  supervisor_alive && return 0
  [ "$(cat .loop/state 2>/dev/null)" = "FLEET_RUNNING" ] && return 0
  [ -n "$(tasks_in claimed)" ] && return 0
  [ -n "$(tasks_in new)" ] || return 1
  planned_pending && return 0
  [ -n "$(tasks_in "done")$(tasks_in failed)" ] && [ -f .loop/decompose-approved ]
}

check_fleet_contract_binding() { # fail closed when queued PLANNED tasks belong to
  # ANOTHER contract. .loop/decompose-approved (written when the plan is accepted)
  # binds contract<->plan via decompose_plan_hash; an interrupted orchestration
  # whose contract was then edited+re-approved must NEVER be resumed — its tasks
  # would be dispatched, merged and gated against a contract they were not
  # planned for (the fleet analogue of the single-loop checkpoint CONTRACT_HASH
  # guard in decide_run_mode). Manual (non-PLANNED) tasks carry their own
  # per-worktree contract and are exempt.
  planned_pending || return 0
  # neither a plan nor a marker: no decompose ever ran here — the task was
  # flagged PLANNED by hand (surgical repair / test synthesis); there is nothing
  # to bind against, and the per-task MASTER_HASH pin still guards the injected
  # master copy. A plan WITHOUT its marker (or a mismatch) is the dangerous
  # state — the contract or plan changed under a live queue — and fails closed.
  [ -f .loop/docs/task-plan.md ] || [ -f .loop/decompose-approved ] || return 0
  if [ ! -f .loop/decompose-approved ] \
     || [ "$(cat .loop/decompose-approved)" != "$(decompose_plan_hash)" ]; then
    die "queued tasks were planned for a DIFFERENT contract (the contract or task plan changed after the orchestration started) — restore the previous contract to resume, or inspect/clean the queued work: ./loop.sh fleet status | ./loop.sh fleet clean <id> [--force]"
  fi
}

run_fleet_orchestration() { # $1 start|resume — dispatch the planned queue, then
  # certify the MERGED result against the MASTER contract (integration gate).
  # Runs inside cmd_run's process: the in-memory RUN_*_HASH baselines, config
  # and models are loaded, so the whole fleet inherits the single-loop trust
  # model. Individual task success is NEVER enough — the gate review, the
  # evidence report and the deterministic evaluator certify the merged whole.
  # Never returns (every path ends in finish()/die()).
  local phase="$1" base id blocked_ticks=0 gate_i=1 fixups fixup_cap
  local human_ticks=0 stall_ticks=0 last_fp="" fp stall_cap manual manual_merged run_wall_start=$SECONDS
  local reviewed_ref evidence_diff final_line final_state evidence_logs authority_before authority_after
  ensure_fleet_dirs
  if [ "$phase" = "start" ] || [ ! -s .loop/fleet/run-id ]; then
    printf '%s\n' "$RUN_ID" > .loop/fleet/run-id
  else
    RUN_ID=$(cat .loop/fleet/run-id)
    valid_log_segment "$RUN_ID" \
      || die "invalid fleet run id in .loop/fleet/run-id — inspect possible state corruption, then restart the orchestration"
  fi
  check_fleet_contract_binding
  MAX_PARALLEL=$(fcfg FLEET_MAX_PARALLEL 3)
  fixup_cap=$(fcfg FLEET_MAX_INTEGRATION_FIXUPS 1)
  stall_cap=$(fcfg FLEET_STALL_TICKS 30)     # 0 disables the stall watchdog
  case "$stall_cap" in ''|*[!0-9]*) stall_cap=30 ;; esac
  mkdir -p .loop/logs
  confirm_setup_cmd
  acquire_lock
  trap release_lock EXIT
  trap on_orch_int INT TERM
  # supervisor restart = session rotation: a recorded conversation from a prior
  # process may be stale or gone — every restart begins with a fresh session
  supervisor_session_drop
  if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    die "the repository has a merge in progress — resolve it or 'git merge --abort' first"
  fi
  if [ -n "$(git status --porcelain)" ]; then
    note "working tree dirty — creating pre-fleet snapshot commit"
    git add -A
    git commit -q -m "fleet: pre-fleet snapshot"
  fi
  # the gate's diff base. Held in memory for this process; mirrored to disk only
  # for a resume across process restarts, and then re-validated as an ancestor
  # of HEAD (an unusable recorded base degrades to HEAD — same policy as the
  # single-loop resume). Known-accepted edge: if the PARENT history was rewritten
  # between runs (reset --hard/rebase over merged work), base=HEAD makes the gate
  # diff empty, so the run can label itself NO_OP over work that WAS merged —
  # weaker certification than a fresh run there. VERIFY_COMMANDS still run via
  # --final, so it is never an unverified merge; fixing it outright would need a
  # durable original-base record for a synthetic, human-made situation.
  if [ "$phase" = "start" ]; then
    base=$(git rev-parse HEAD)
    printf '%s\n' "$base" > .loop/fleet/base-ref
    rm -f .loop/fleet/fixup-count .loop/fleet/replan-count .loop/fleet/plan-review-count
    journal_append "fleet" "FLEET_START" "base $base"
  else
    base=$(cat .loop/fleet/base-ref 2>/dev/null || echo "")
    if [ -z "$base" ] \
       || ! git rev-parse --verify "${base}^{commit}" >/dev/null 2>&1 \
       || ! git merge-base --is-ancestor "$base" HEAD >/dev/null 2>&1; then
      note "orchestration resume: no valid recorded base — using HEAD as the gate base"
      base=$(git rev-parse HEAD)
      printf '%s\n' "$base" > .loop/fleet/base-ref
    fi
    journal_append "fleet" "FLEET_RESUME" "base $base"
    # NOTE: a resume deliberately does NOT clear plan-review escalations — the
    # run exits again with the same decision request until a human runs
    # `./loop.sh fleet ack-plan <id>` (idempotent, never a silent release)
  fi
  echo FLEET_RUNNING > .loop/state
  # a crash mid-enqueue left the pending marker: complete the plan publish
  # BEFORE adopting/dispatching anything (never run partial REQ coverage)
  if [ "$phase" != "start" ] && [ -f .loop/fleet/enqueue-pending ]; then
    repair_pending_enqueue
  fi
  recover_claimed
  note "orchestration up — max parallel $MAX_PARALLEL (status: ./loop.sh status | add: ./loop.sh add)"

  while :; do
    # a USD cap (when configured) also bounds the parent-side calls: check at
    # the same cadence as run_iteration_loop — before each round's spending
    if budget_exceeded; then
      finish BUDGET_EXCEEDED "spent \$$TOTAL_COST >= cap \$$MAX_COST_USD during orchestration"
    fi
    if [ -n "${MAX_RUN_SECONDS:-}" ] && [ $((SECONDS - run_wall_start)) -ge "$MAX_RUN_SECONDS" ]; then
      finish BUDGET_EXCEEDED "wall clock $((SECONDS - run_wall_start))s >= MAX_RUN_SECONDS=${MAX_RUN_SECONDS} during orchestration"
    fi
    # each round starts a fresh watchdog window (a late-add rescan round must not
    # inherit the previous round's stuck-ness counters)
    blocked_ticks=0; human_ticks=0; stall_ticks=0; last_fp=""
    # ---- dispatch until the queue drains (supervision runs inside tick) ----
    while :; do
      tick
      orch_park_interrupted
      # the wall-clock cap must also bound a long dispatch phase per tick, not
      # only the round boundary above (a round can run for hours)
      if [ -n "${MAX_RUN_SECONDS:-}" ] && [ $((SECONDS - run_wall_start)) -ge "$MAX_RUN_SECONDS" ]; then
        finish BUDGET_EXCEEDED "wall clock $((SECONDS - run_wall_start))s >= MAX_RUN_SECONDS=${MAX_RUN_SECONDS} during orchestration dispatch"
      fi
      if fleet_merge_blocked; then
        blocked_ticks=$((blocked_ticks + 1))
        if [ "$blocked_ticks" -ge 15 ]; then
          journal_append "fleet" "FLEET_MERGE_BLOCKED" "parent tracked tree dirty; finished branches kept as MERGE_PENDING"
          {
            echo
            echo "## DR-FLEET-MERGE"
            echo "- The parent tree has uncommitted tracked changes; serial merges cannot land."
            echo "- Commit or stash them, then: ./loop.sh run   (the orchestration resumes)"
          } >> .loop/docs/decision-requests.md
          finish NEEDS_SPEC_DECISION "merges blocked by uncommitted parent changes — commit/stash them, then ./loop.sh run"
        fi
      else
        blocked_ticks=0
      fi
      # approval-blocked: inside auto orchestration no in-process actor may grant
      # a demoted PENDING_APPROVAL (tamper / twice-refused review) — bounded wait,
      # then escalate to the human instead of waiting silently forever
      if fleet_needs_human; then
        human_ticks=$((human_ticks + 1))
        if [ "$human_ticks" -ge 15 ]; then
          journal_append "fleet" "FLEET_APPROVAL_BLOCKED" "task(s) demoted to PENDING_APPROVAL — auto-approval refused; a human must approve"
          {
            echo
            echo "## DR-FLEET-APPROVAL"
            echo "- Task(s) waiting for human contract approval: $(tasks_in claimed | tr '\n' ' ')"
            echo "- Review feedback: <wt>/.loop/contract-review-feedback.md"
            echo "- Then: ./loop.sh fleet approve <id>   (or --all), then: ./loop.sh run"
          } >> .loop/docs/decision-requests.md
          commit_if_changes "fleet: approval decision request"
          finish NEEDS_SPEC_DECISION "fleet sub-contract(s) await human approval — ./loop.sh fleet approve <id>, then ./loop.sh run"
        fi
      else
        human_ticks=0
      fi
      # plan-review escalation: dependents are deterministically held
      # (deps_state) while a human decides — exit with the decision request
      # instead of spinning into the stall watchdog
      if plan_review_escalated; then
        journal_append "fleet" "FLEET_PLAN_ESCALATED" "plan-review escalated after a phase merge — queued phases held for a human decision"
        finish NEEDS_SPEC_DECISION "plan-review escalated after a phase merge — see .loop/docs/decision-requests.md (DR-FLEET-PLAN-*); decide, release with ./loop.sh fleet ack-plan <merged-id>, then ./loop.sh run"
      fi
      # stall watchdog (generic backstop): no live worker AND an unchanged phase
      # fingerprint for FLEET_STALL_TICKS ticks = zero dispatch progress — every
      # stuck condition must terminate in a finish state, never a silent spin
      if [ "$stall_cap" -gt 0 ]; then
        fp=$(fleet_fingerprint)
        if [ "$fp" = "$last_fp" ] && [ "$(active_slots)" -eq 0 ]; then
          stall_ticks=$((stall_ticks + 1))
          if [ "$stall_ticks" -ge "$stall_cap" ]; then
            journal_append "fleet" "FLEET_STALLED" "no live workers and no phase change for $stall_ticks ticks: $(fleet_fingerprint | tr '\n' ' ')"
            finish BLOCKED "orchestration made no progress for $stall_ticks ticks — inspect ./loop.sh fleet status, then ./loop.sh run to resume"
          fi
        else
          stall_ticks=0
        fi
        last_fp="$fp"
      fi
      fleet_idle && break
      sleep "$TICK_SECONDS"
    done
    orch_check_failures
    if budget_exceeded; then
      finish BUDGET_EXCEEDED "spent \$$TOTAL_COST >= cap \$$MAX_COST_USD before the integration gate"
    fi

    # ---- integration gate: the merged whole vs the MASTER contract ----
    check_harness "before the integration gate"
    verify_approval
    # manual-task manifest: regenerated every gate round — merged human-queued
    # side-work is declared to the reviewer as sanctioned, never left to look
    # like unrequested scope (absent when no manual task merged)
    write_manual_manifest
    # deliberate: the integration gate ignores REVIEW_MODE=off — the merged
    # whole is always reviewed (the knob tunes the workers' per-iteration
    # cadence, never the master certification)
    if [ -f .loop/fleet/manual-manifest.md ]; then
      gate_review_retry "fleet$gate_i" "$base" gate "" " manual-tasks=.loop/fleet/manual-manifest.md"
    else
      gate_review_retry "fleet$gate_i" "$base" gate
    fi
    if [ "$REVIEW_VERDICT" = "ERROR" ]; then
      finish BLOCKED "reviewer unavailable at the integration gate — cannot certify the merged result${AGENT_FAIL_DIAG:+ (last error: $AGENT_FAIL_DIAG)}"
    fi
    if [ "$REVIEW_VERDICT" = "ESCALATE" ]; then
      # a human-only question at the integration gate: the supervisor's only
      # authority is the master contract, which by definition cannot answer
      # this — skip the fix-up machinery and go straight to the human
      finish NEEDS_SPEC_DECISION "integration gate reviewer escalated to the human — see .loop/docs/decision-requests.md"
    fi
    if [ "$REVIEW_VERDICT" = "REVISE" ]; then
      fixups=$(cat .loop/fleet/fixup-count 2>/dev/null || echo 0)
      # sanitize before arithmetic (ckpt_int convention): the parent-repo gate's
      # VERIFY_COMMANDS could corrupt this counter; garbage must read as 0, not
      # kill the supervisor mid-gate
      case "$fixups" in ''|*[!0-9]*) fixups=0 ;; esac
      if [ "$fixups" -ge "$fixup_cap" ]; then
        finish BLOCKED "integration review rejected the merged result after $fixups fix-up round(s) (.loop/review-feedback.md) — branches and feedback kept; fix per that file, then ./loop.sh fleet run"
      fi
      echo $((fixups + 1)) > .loop/fleet/fixup-count
      journal_append "fleet" "INTEGRATION_REVISE" "gate rejected the merged result — asking the supervisor for one fix-up task"
      note "integration review -> REVISE — asking the supervisor for one fix-up task"
      if ! integration_fixup "$base"; then
        finish BLOCKED "integration review rejected the merged result and no valid fix-up was produced (.loop/review-feedback.md) — address it, then ./loop.sh fleet run"
      fi
      gate_i=$((gate_i + 1))
      continue   # dispatch the fix-up, then re-gate
    fi
    if [ "$REVIEW_VERDICT" != "APPROVE" ]; then
      finish BLOCKED "integration success gate requires an explicit reviewer APPROVE (got: ${REVIEW_VERDICT:-none})"
    fi
    # APPROVE: the certification tail runs INSIDE
    # the round loop, so a task added during the gate triggers a rescan round
    # (below) instead of being silently stranded until the next manual run.

    if [ "$REVIEW_VERDICT" = "APPROVE" ]; then
      # Evidence for the MERGED whole. Freeze the reviewer-approved authority
      # inputs and require a newly-generated report before any report commit.
      check_harness "during the integration-gate review"
      canonicalize_live_manifest \
        || finish BLOCKED "could not canonicalize the observation manifest before integration evidence"
      authority_before=$(certification_inputs_hash) \
        || finish BLOCKED "could not snapshot integration certification inputs"
      reviewed_ref=$(git rev-parse HEAD)
      evidence_logs=$(active_log_dir)
      rm -f .loop/docs/evidence-report.md
      note "generating the master evidence report (/loop-evidence, $MODEL_EVIDENCE)"
      if ! run_claude "fleet-evidence" "/loop-evidence baseline=$base logs=$evidence_logs task=$TASK_ID$(html_arg)" "$MODEL_EVIDENCE" full EVIDENCE; then
        finish BLOCKED "evidence generation failed — cannot certify the merged result without evidence${AGENT_FAIL_DIAG:+ ($AGENT_FAIL_DIAG)}"
      fi
      check_harness "during integration evidence"
      authority_after=$(certification_inputs_hash) \
        || finish BLOCKED "could not re-check integration certification inputs"
      if [ "$authority_after" != "$authority_before" ]; then
        finish BLOCKED "integration evidence changed certification inputs after review (contract/ledger/checklist/verdicts/manifest/observations)"
      fi
      if ! validate_current_evidence_report; then
        finish BLOCKED "current integration evidence report is invalid: $EVIDENCE_REPORT_REASON"
      fi
      evidence_diff=$(post_review_product_changes "$reviewed_ref")
      if [ -n "$evidence_diff" ]; then
        finish BLOCKED "evidence step changed code after the integration review (unreviewed): $(echo "$evidence_diff" | tr '\n' ' ')"
      fi
      commit_if_changes "fleet: integration evidence report"
      journal_append "fleet" "EVIDENCE" "integration evidence report generated ($MODEL_EVIDENCE)"
      record_html_decision "fleet-evidence" "fleet"
    fi
    # final deterministic re-check over the full fleet diff (--assume-ready: no
    # .loop/agent-state exists at the parent; the diff policy still runs in full)
    final_line=$("$evaluator" --pre-ref "$base" --final --assume-ready --approved-hash "$RUN_CONTRACT_HASH") \
      || final_line="BLOCKED final evaluation crashed"
    final_state=${final_line%% *}
    if [ -f .loop/verify-flake.log ]; then
      journal_append "fleet" "VERIFY_FLAKE" "integration re-check failed then passed on a full rerun — suspected environment flake: $(grep -m1 '^\[FAIL\]' .loop/verify-flake.log | cut -c1-160)"
    fi
    journal_append "fleet" "INTEGRATION_GATE_$final_state" "$final_line"
    if [ "$final_state" = "SUCCESS" ]; then
      # late-add rescan: a task published while the synchronous gate/evidence ran
      # would otherwise be stranded with a dead dispatcher. A fresh round re-gates
      # the merged whole INCLUDING the late task — certification is never partial.
      # (An add landing after this check but before process exit is picked up by
      # the next bare `./loop.sh run`, which resumes on any non-empty queue.)
      if [ -n "$(tasks_in new)" ]; then
        journal_append "fleet" "FLEET_LATE_ADD" "task(s) arrived during the gate — dispatching before completion"
        note "task(s) added during the integration gate — dispatching them before completing"
        gate_i=$((gate_i + 1))
        continue   # back to dispatch; a fresh gate round certifies the late task too
      fi
      # manual (non-PLANNED) task failures never abort the planned work mid-flight
      # (orch_check_failures skips them) but must never be silently dropped either:
      # surface them as a decision request instead of declaring SUCCESS over them
      manual=$(orch_manual_failed)
      if [ -n "$manual" ]; then
        {
          echo
          echo "## DR-FLEET-MANUAL"
          echo "- Manually-added task(s) failed while the orchestration ran:$manual"
          echo "- The planned work passed the integration gate and is merged; these side tasks did not land."
          echo "- Inspect: ./loop.sh fleet status (claimed tasks also have ./loop.sh fleet logs <id>) | resume: ./loop.sh resume <id> | discard: ./loop.sh fleet clean <id> --force"
        } >> .loop/docs/decision-requests.md
        commit_if_changes "fleet: manual task failure(s) surfaced"
        journal_append "fleet" "FLEET_MANUAL_FAILED" "$manual"
        finish NEEDS_SPEC_DECISION "manual task(s) failed during the orchestration:$manual — planned work is merged and gated; decide on the side task(s)"
      fi
      # manual (non-PLANNED) merges are surfaced, never silently absorbed: each
      # passed its own full per-worktree pipeline before merging and the gate
      # just re-verified the merged whole WITH the manifest in hand — so this
      # stays SUCCESS, with a journal record, a harness-written evidence-report
      # section and an explicitly informational decision-request block as the
      # audit trail.
      manual_merged=$(orch_manual_merged)
      if [ -n "$manual_merged" ] && [ -f .loop/fleet/manual-manifest.md ]; then
        journal_append "fleet" "FLEET_MANUAL_MERGED" "$manual_merged"
        {
          echo
          echo "## Manual side-tasks merged in this run"
          echo
          echo "(appended by the harness: these tasks were queued by a human while the"
          echo "orchestration ran, each under its own approved sub-contract, and the"
          echo "integration gate re-verified the merged whole with this manifest in hand.)"
          echo
          cat .loop/fleet/manual-manifest.md
        } >> .loop/docs/evidence-report.md
        {
          echo
          echo "## DR-FLEET-MANUAL-MERGED"
          echo "- Informational audit record — no action required."
          echo "- Manually-added task(s) merged during this orchestration:$manual_merged"
          echo "- These tasks ran outside the master contract, each under its own human-/auto-approved sub-contract; details: .loop/docs/evidence-report.md (Manual side-tasks merged in this run)."
        } >> .loop/docs/decision-requests.md
        commit_if_changes "fleet: manual side-task merge audit"
      fi
      if [ -z "$(git diff --name-only "$base" HEAD -- . ':(exclude).loop' ':(exclude).claude' 2>/dev/null)" ]; then
        evidence_diff=$(post_review_product_changes "$reviewed_ref")
        [ -z "$evidence_diff" ] \
          || finish BLOCKED "product tree changed after the integration review: $(echo "$evidence_diff" | tr '\n' ' ')"
        write_certification NO_OP "$base" "$base" "$reviewed_ref" NOT_APPLICABLE \
          || finish BLOCKED "failed to write or commit integration certification.json"
        check_harness "after integration certification"
        finish NO_OP "verification passes with no code changes needed (fleet)"
      fi
      evidence_diff=$(post_review_product_changes "$reviewed_ref")
      [ -z "$evidence_diff" ] \
        || finish BLOCKED "product tree changed after the integration review: $(echo "$evidence_diff" | tr '\n' ' ')"
      write_certification SUCCESS "$base" "$base" "$reviewed_ref" NOT_APPLICABLE \
        || finish BLOCKED "failed to write or commit integration certification.json"
      check_harness "after integration certification"
      finish SUCCESS "integration gate passed — the merged fleet result meets the master contract (${final_line#* })"
    fi
    finish BLOCKED "integration re-check failed: $final_line"
  done
}

cmd_decompose() { # preview/refresh the task plan without enqueueing or running
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) die_next "unknown option for decompose: $1" "see ./loop.sh -h" ;;
    esac
  done
  need_kit
  ensure_loop_dir
  need_awk
  need_sha
  need_claude
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git repository — run: git init && git add -A && git commit -m init"
  verify_approval
  load_config
  load_models
  RUN_CONTRACT_HASH=$(contract_hash)
  RUN_HARNESS_HASH=$(harness_hash)
  RUN_MODELS_HASH=$(models_hash)
  if cmd_decompose_flow "$force" 0; then
    note "task plan ready (n=$ORCH_N): .loop/docs/task-plan.md — start it with: ./loop.sh run"
  else
    note "task plan ready (n=1, runs in place): .loop/docs/task-plan.md — start it with: ./loop.sh run"
  fi
}

# ---------- kit deployment (init + update share these) ----------

# The harness = main sh + evaluator + loop-* skills. This is exactly what the
# approval hash (harness_hash) covers, so `update` reports "up to date" iff a
# re-approval would not be needed.
target_harness_sha() { # $1 target dir
  {
    cat "$1/loop.sh" "$1/.loop/bin/evaluate.sh" 2>/dev/null
    cat "$1"/.claude/skills/loop-*/SKILL.md 2>/dev/null
    cat "$1/.claude/settings.json" "$1/.claude/settings.local.json" "$1/.mcp.json" 2>/dev/null || true
  } | sha256
}

refresh_harness() { # $1 src-bin, $2 src-assets, $3 target — copy harness + pristine doc templates
  local sbin="$1" sassets="$2" tgt="$3" d name f base
  mkdir -p "$tgt/.loop/bin" "$tgt/.loop/docs" "$tgt/.claude/skills"

  # main sh: stage then atomically rename, so refreshing loop.sh's own file while
  # it is the running script is safe (the live process keeps the old inode).
  cp "$sbin/loop.sh" "$tgt/.loop/loop.sh.new"
  chmod +x "$tgt/.loop/loop.sh.new"
  mv -f "$tgt/.loop/loop.sh.new" "$tgt/loop.sh"

  cp "$sbin/evaluate.sh" "$tgt/.loop/bin/evaluate.sh"
  chmod +x "$tgt/.loop/bin/evaluate.sh"

  # the fleet supervisor is part of loop.sh now — remove a previously-deployed
  # standalone fleet.sh so a stale copy can never be run against the new layout
  rm -f "$tgt/fleet.sh"

  # skills: manage only loop-* (leave the user's own skills untouched) and prune
  # any loop-* skill that was removed from the kit, so stale process files go away.
  for d in "$tgt"/.claude/skills/loop-*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    [ -d "$sassets/.claude/skills/$name" ] || rm -rf "$d"
  done
  cp -R "$sassets/.claude/skills/." "$tgt/.claude/skills/"

  # doc templates: refresh only those still pristine (TEMPLATE marker) or absent —
  # never clobber a contract/plan/progress the loop or the user has filled in.
  for f in "$sassets"/loop-docs/*.md; do
    base=$(basename "$f")
    if [ ! -f "$tgt/.loop/docs/$base" ] || grep -q '<!-- TEMPLATE -->' "$tgt/.loop/docs/$base"; then
      cp "$f" "$tgt/.loop/docs/$base"
    fi
  done

  # pristine copies of the doc templates, kept verbatim: fleet.sh resets each
  # worktree's .loop/docs from these so a new run never inherits the parent's
  # filled-in contract/plan/progress (which would silently run the wrong task)
  mkdir -p "$tgt/.loop/templates"
  cp "$sassets"/loop-docs/*.md "$tgt/.loop/templates/"

  printf '*\n!.gitignore\n!docs\n!docs/**\n' > "$tgt/.loop/.gitignore"
}

config_drift_note() { # $1 kit template, $2 user file, $3 label — list keys the kit added
  [ -f "$1" ] && [ -f "$2" ] || return 0
  local missing="" k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    grep -qE "^[[:space:]]*$k=" "$2" || missing="$missing $k"
  done < <(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$1" | sed -E 's/[[:space:]]//g; s/=$//' | sort -u)
  [ -n "$missing" ] || return 0
  note "note: kit's $3 has keys your file lacks (new options; your file keeps its values):$missing"
  note "      compare with: diff \"$2\" \"$1\""
}

config_drift_merge() { # $1 kit template, $2 user file — APPEND kit keys the user
  # file lacks, verbatim (each key's contiguous comment block + its KEY=value
  # line) from the template. fleet.config.sh ONLY: it is outside every approval
  # hash (contract_hash/harness_hash), so appending is re-approval-safe and lands
  # between runs. Idempotent (a present key is never re-added); prints what it
  # added. This closes the silent drift where a key-missing file ran on the code
  # fallback instead of the shipped value.
  [ -f "$1" ] && [ -f "$2" ] || return 0
  local tmpl="$1" user="$2" k added=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    # present as an active assignment OR deliberately commented out (a user who
    # disabled a key must not have it silently re-added uncommented)
    grep -qE "^[[:space:]]*#?[[:space:]]*$k=" "$user" && continue
    added="$added $k"
  done < <(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$tmpl" | sed -E 's/[[:space:]]//g; s/=$//' | sort -u)
  [ -n "$added" ] || return 0
  {
    echo ""
    echo "# --- added by ./loop.sh update (new kit options; edit freely) ---"
    for k in $added; do
      echo ""
      # the key's immediately-preceding comment block (contiguous # lines) + the
      # key line, lifted verbatim; a blank/non-comment line resets the block so a
      # far-away section header is not dragged along
      awk -v key="$k" '
        $0 ~ "^[[:space:]]*" key "=" { for (i=1;i<=n;i++) print buf[i]; print $0; exit }
        /^[[:space:]]*#/ { buf[++n]=$0; next }
        { n=0 }
      ' "$tmpl"
    done
  } >> "$user"
  note "note: ./loop.sh update added new fleet.config.sh key(s) from the kit:$added"
}

# ---------- commands ----------

cmd_init() {
  [ "$MODE" = "kit" ] || die "init must be run from the kit repository: <kit>/bin/loop.sh init <dir>"
  local target="" template=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --template) template="${2:?--template needs a name}"; shift 2 ;;
      -*) die_next "unknown option for init: $1" "see ./loop.sh -h" ;;
      *) target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || die "usage: loop.sh init <dir> [--template <name>]"
  mkdir -p "$target"
  target=$(cd "$target" && pwd)

  # harness (loop.sh, evaluator, skills) + pristine doc templates
  refresh_harness "$KIT_BIN" "$KIT_ASSETS" "$target"
  # user-owned, tunable files: seed only when absent (never clobber tuned values)
  [ -f "$target/loop.config.sh" ] || cp "$KIT_ASSETS/loop.config.sh" "$target/loop.config.sh"
  [ -f "$target/loop.models.sh" ] || cp "$KIT_ASSETS/loop.models.sh" "$target/loop.models.sh"
  if [ ! -f "$target/fleet.config.sh" ] && [ -f "$KIT_ASSETS/fleet.config.sh" ]; then
    cp "$KIT_ASSETS/fleet.config.sh" "$target/fleet.config.sh"
  fi
  # remember where this deployment came from, so `./loop.sh update` can find the
  # kit later without being told (git-ignored: machine-local path, never committed)
  printf '%s\n' "$KIT_ROOT" > "$target/.loop/kit-source"

  if [ -n "$template" ]; then
    [ -d "$KIT_ROOT/examples/$template" ] || die "unknown template '$template' (see examples/)"
    cp -R "$KIT_ROOT/examples/$template/." "$target/"
  fi

  # keep the kit's own files out of the project's git (after any template
  # .gitignore is copied in, so our block is appended rather than overwritten)
  ensure_gitignore "$target"

  local created=0
  if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$target" init -q -b main
    created=1
  fi
  if [ "$created" -eq 1 ]; then
    git -C "$target" add -A
    git -C "$target" commit -q -m "loop: kit deployed"
  else
    note "kit files copied into existing repo — review and commit them when ready"
  fi
  note "kit deployed into $target"
  note "next: cd $target && ./loop.sh            (auto flow: reads loop-instruction.md)"
  note "  or: cd $target && ./loop.sh start \"<instruction>\""
  note "later, to pull kit fixes:  cd $target && ./loop.sh update"
}

cmd_update() {
  local target="" from="" do_approve=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)    from="${2:?--from needs a path}"; shift 2 ;;
      --approve) do_approve=1; shift ;;
      -*)        die_next "unknown option for update: $1" "see ./loop.sh -h" ;;
      *)         target="$1"; shift ;;
    esac
  done

  # resolve (kit source, target) for both call sites:
  #   from the kit repo:   <kit>/bin/loop.sh update <project-dir>
  #   inside a project:    ./loop.sh update            (kit found via .loop/kit-source or --from)
  local src_bin src_assets
  if [ "$MODE" = "kit" ]; then
    [ -n "$target" ] || die "usage (from kit repo): <kit>/bin/loop.sh update <project-dir> [--approve]"
    src_bin="$KIT_BIN"; src_assets="$KIT_ASSETS"
  else
    [ -z "$target" ] || die "inside a project, run 'update' with no dir (self-update); to update another project, run it from the kit repo"
    target="$SCRIPT_DIR"
    local kitroot="$from"
    [ -n "$kitroot" ] || kitroot=$(cat .loop/kit-source 2>/dev/null || echo "")
    [ -n "$kitroot" ] || die "don't know where the kit is — point at it once: ./loop.sh update --from <kit-repo> (remembered afterwards)"
    [ -d "$kitroot" ] || die "kit source not found: $kitroot — pass a valid path with --from <kit-repo>"
    kitroot=$(cd "$kitroot" && pwd)
    src_bin="$kitroot/bin"; src_assets="$kitroot/kit"
  fi

  [ -f "$src_bin/loop.sh" ] && [ -f "$src_bin/evaluate.sh" ] && [ -d "$src_assets/.claude/skills" ] \
    || die "not a valid kit at ${src_bin%/bin} (need bin/loop.sh, bin/evaluate.sh, kit/.claude/skills)"
  target=$(cd "$target" && pwd)
  { [ -f "$target/loop.sh" ] || [ -f "$target/loop.config.sh" ] || [ -d "$target/.loop" ]; } \
    || die "$target is not a loop project yet — deploy first: <kit>/bin/loop.sh init \"$target\""
  # record where the update came from (only now that the kit is confirmed valid),
  # so a later bare `./loop.sh update` finds it (git-ignored, machine-local)
  mkdir -p "$target/.loop"
  printf '%s\n' "${KIT_ROOT:-$(cd "$src_bin/.." && pwd)}" > "$target/.loop/kit-source"

  local before after
  before=$(target_harness_sha "$target")
  refresh_harness "$src_bin" "$src_assets" "$target"
  ensure_gitignore "$target"   # also brings pre-gitignore deployments up to date
  after=$(target_harness_sha "$target")

  note "updated $target from kit at ${src_bin%/bin}"
  if [ "$before" = "$after" ]; then
    note "harness already up to date (loop.sh / evaluate.sh / skills unchanged)"
  else
    note "harness refreshed: loop.sh, .loop/bin/evaluate.sh, .claude/skills/loop-*"
    note "preserved: loop.config.sh, loop.models.sh, and any filled-in .loop/docs/*"
    note "review the change: (cd \"$target\" && git status && git diff -- loop.sh .claude/skills)"
  fi

  # Does the deployed harness still match the recorded approval? (target_harness_sha
  # is computed exactly like harness_hash, so approved-harness is directly comparable.)
  # If not, the next `run` will refuse to start — re-approve (opt-in) or tell the user.
  local approved_h=""
  if [ -f "$target/.loop/approved-harness" ]; then approved_h=$(cat "$target/.loop/approved-harness"); fi
  if [ -n "$approved_h" ] && [ "$approved_h" != "$after" ]; then
    if [ "$do_approve" -eq 1 ]; then
      if ( cd "$target" && "$target/loop.sh" approve ); then
        note "re-approved with the updated harness — ready to run"
      else
        note "auto re-approval failed — run it yourself: (cd \"$target\" && ./loop.sh approve)"
      fi
    else
      note "the recorded approval no longer matches the deployed harness (stale)."
      note "re-approve before the next run: (cd \"$target\" && ./loop.sh approve)   [or re-run with --approve]"
    fi
  elif [ "$do_approve" -eq 1 ] && [ -z "$approved_h" ] && [ -f "$target/.loop/docs/product-contract.md" ]; then
    note "approving the current contract + harness (requested via --approve)"
    ( cd "$target" && "$target/loop.sh" approve ) || note "approve step skipped"
  fi

  # loop.config.sh is approval-bound (contract_hash) — never auto-edit it; just
  # note drift. loop.models.sh: note only (leave the user's file authoritative).
  config_drift_note "$src_assets/loop.config.sh" "$target/loop.config.sh" "loop.config.sh"
  config_drift_note "$src_assets/loop.models.sh" "$target/loop.models.sh" "loop.models.sh"
  # fleet.config.sh is outside every approval hash — self-heal missing keys so a
  # key-absent deployment stops silently running on the (now-aligned) code fallback
  config_drift_merge "$src_assets/fleet.config.sh" "$target/fleet.config.sh"
}

cmd_uninstall() { # remove everything init/update deployed + run state + fleet artifacts
  local target="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      -*)         die_next "unknown option for uninstall: $1" "see ./loop.sh -h" ;;
      *)          target="$1"; shift ;;
    esac
  done
  if [ "$MODE" = "kit" ]; then
    [ -n "$target" ] || die "usage (from kit repo): <kit>/bin/loop.sh uninstall <project-dir> [--force]"
    [ -d "$target" ] || die "no such directory: $target"
    target=$(cd "$target" && pwd)
    case "$target" in
      "$KIT_ROOT"|"$KIT_ROOT"/*) die "refusing to uninstall the kit repository itself ($target)" ;;
    esac
  else
    [ -z "$target" ] || die "inside a project, run 'uninstall' with no dir (self-uninstall); to uninstall another project, run it from the kit repo"
    target="$SCRIPT_DIR"
  fi
  { [ -f "$target/loop.sh" ] || [ -d "$target/.loop" ] || [ -f "$target/loop.config.sh" ]; } \
    || die "no loop-kit deployment found in $target — nothing to uninstall"

  # never uninstall under a live fleet: the supervisor and its task loops would
  # have their engine and state deleted out from under them mid-run
  # liveness here is a destructive-action gate: a false "dead" deletes the engine
  # out from under a live fleet, so a ps miss must fall back to a heartbeat (never
  # uninstall on ps alone). Same layering as supervisor_alive / task_pid_alive.
  local lockpid envf pid id wt
  lockpid=$(cat "$target/.loop/fleet/supervisor.lock.d/pid" 2>/dev/null || true)
  if [ -n "$lockpid" ] && kill -0 "$lockpid" 2>/dev/null \
     && { ps -p "$lockpid" -o command= 2>/dev/null | grep -qE "loop\.sh|fleet\.sh" \
          || path_mtime_fresh "$target/.loop/fleet/supervisor.lock.d/heartbeat" "${LOOP_FLEET_HEARTBEAT_STALE:-60}"; }; then
    die "fleet supervisor is running (pid $lockpid) — stop it (Ctrl-C) before uninstalling"
  fi
  for envf in "$target"/.loop/fleet/runs/*.env; do
    [ -f "$envf" ] || continue
    id=$(basename "$envf" .env)
    pid=$(grep -E '^PID=' "$envf" | tail -1 | cut -d= -f2-) || pid=""
    wt=$(grep -E '^WT=' "$envf" | tail -1 | cut -d= -f2-) || wt=""
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
       && { { [ -n "$wt" ] && [ "$(cat "$wt/.loop/run.pid" 2>/dev/null)" = "$pid" ]; } \
            || ps -p "$pid" -o command= 2>/dev/null | grep -q "loop\.sh" \
            || { [ -n "$wt" ] && run_heartbeat_fresh "$wt"; }; }; then
      die "fleet task '$id' is still running (pid $pid) — stop it first: ./loop.sh fleet stop $id"
    fi
  done

  # fleet worktrees + branches recorded by past runs (metadata is safe-parsed;
  # they reference this repo's .git, so they must go before the metadata does)
  local wts=() branches=() wt br
  for envf in "$target"/.loop/fleet/runs/*.env; do
    [ -f "$envf" ] || continue
    wt=$(grep -E '^WT=' "$envf" | tail -1 | cut -d= -f2-) || wt=""
    br=$(grep -E '^BRANCH=' "$envf" | tail -1 | cut -d= -f2-) || br=""
    if [ -n "$wt" ] && [ -d "$wt" ]; then wts+=("$wt"); fi
    if [ -n "$br" ] && git -C "$target" rev-parse -q --verify "refs/heads/$br" >/dev/null 2>&1; then
      branches+=("$br")
    fi
  done

  echo "loop: this removes the loop-kit deployment from $target:"
  local f
  for f in loop.sh fleet.sh loop.config.sh loop.models.sh fleet.config.sh; do
    if [ -f "$target/$f" ]; then echo "  $f"; fi
  done
  if [ -d "$target/.loop" ]; then
    echo "  .loop/  (contract, evidence, plan/progress docs, logs, journal, fleet queue)"
  fi
  if ls -d "$target"/.claude/skills/loop-*/ >/dev/null 2>&1; then
    echo "  .claude/skills/loop-*/  (your own skills are kept)"
  fi
  if [ -f "$target/.gitignore" ]; then
    echo "  the loop-kit blocks in .gitignore (your own entries are kept)"
  fi
  if [ "${#wts[@]}" -gt 0 ]; then
    echo "  ${#wts[@]} fleet worktree(s): ${wts[*]}"
  fi
  if [ "${#branches[@]}" -gt 0 ]; then
    echo "  ${#branches[@]} fleet branch(es): ${branches[*]}  <- UNMERGED WORK ON THEM IS LOST"
  fi
  if [ "$(cat "$target/.loop/state" 2>/dev/null)" = "RUNNING" ]; then
    echo "  WARNING: .loop/state says RUNNING — make sure no ./loop.sh run is active"
  fi

  if [ "$force" -ne 1 ]; then
    if [ -t 0 ]; then
      local ans
      printf 'loop: remove all of the above? [y/N] '
      read -r ans || ans=n
      case "$ans" in
        y|Y) ;;
        *)   note "aborted — nothing removed"; exit 0 ;;
      esac
    else
      die "uninstall is destructive and there is no TTY to confirm — re-run with --force"
    fi
  fi

  if [ "${#wts[@]}" -gt 0 ]; then
    for wt in "${wts[@]}"; do
      git -C "$target" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    done
  fi
  git -C "$target" worktree prune >/dev/null 2>&1 || true
  if [ "${#branches[@]}" -gt 0 ]; then
    for br in "${branches[@]}"; do
      git -C "$target" branch -D "$br" >/dev/null 2>&1 \
        || note "warning: could not delete branch $br — remove manually: git branch -D $br"
    done
  fi
  # the sibling worktree root, only if the removals emptied it (never forced:
  # anything else in there is not ours)
  rmdir "${LOOP_WORKTREE_ROOT:-$(dirname "$target")/$(basename "$target")-loops}" 2>/dev/null || true

  # off-tree approval store: remove this repository's whole record group
  # (<home>/<repo-id> covers the root slot AND every worktree slot). Computed
  # from the target's git dir BEFORE .loop goes away; best-effort by design.
  local ahome acommon arepo_id
  ahome="${LOOP_APPROVAL_HOME:-${HOME:-}/.loop-kit/approvals}"
  if [ "$ahome" != "repo" ] && [ "$ahome" != "/.loop-kit/approvals" ]; then
    if acommon=$(git -C "$target" rev-parse --git-common-dir 2>/dev/null) && [ -n "$acommon" ]; then
      case "$acommon" in /*) ;; *) acommon="$target/$acommon" ;; esac
    else
      acommon="$target"
    fi
    arepo_id=$(printf '%s' "$acommon" | sha256 2>/dev/null) || arepo_id=""
    [ -z "$arepo_id" ] || rm -rf "${ahome:?}/${arepo_id}"
  fi

  rm -rf "${target:?}/.loop"
  local d
  for d in "$target"/.claude/skills/loop-*/; do
    [ -d "$d" ] || continue
    rm -rf "$d"
  done
  rmdir "$target/.claude/skills" "$target/.claude" 2>/dev/null || true
  strip_gitignore_blocks "$target"
  rm -f "$target/fleet.sh" "$target/loop.config.sh" "$target/loop.models.sh" "$target/fleet.config.sh"
  # loop.sh last — unlinking the running script is safe (the live process keeps
  # its inode), and everything above already succeeded by the time it goes
  rm -f "$target/loop.sh"

  note "uninstalled — the loop-kit deployment is removed from $target"
  [ ! -f "$target/loop-instruction.md" ] \
    || note "kept: loop-instruction.md (your instruction text — delete it yourself if unwanted)"
  if git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [ -n "$(git -C "$target" status --porcelain 2>/dev/null)" ]; then
    note "git: removals of tracked files (.loop/docs, .gitignore) are uncommitted — commit when ready:"
    note "  (cd \"$target\" && git add -A && git commit -m \"loop: kit removed\")"
  fi
}

contract_is_defined() {
  [ -f .loop/docs/product-contract.md ] && ! grep -q '<!-- TEMPLATE -->' .loop/docs/product-contract.md
}

contract_is_approved() {
  # store mode also requires the slot record: a migrated/forged deployment then
  # answers "not approved" here, so post_definition_flow self-heals by
  # re-approving instead of dying later in cmd_run's verify_approval
  local slot
  [ -f .loop/approved ] && [ "$(cat .loop/approved)" = "$(contract_hash)" ] || return 1
  [ "$(approval_home)" = "repo" ] && return 0
  slot=$(approval_slot)
  [ -f "$slot/approved" ] && [ "$(cat "$slot/approved")" = "$(contract_hash)" ]
}

# ---------- contract-scoped loop memory (lifecycle boundary: NEW task) ----------
# Artifact lifecycle scopes (enforced by tests/artifact-lifecycle.txt):
#   run-scoped      — reset at every fresh run (cmd_run pre-routing block + FRESH list)
#   contract-scoped — this section: archived + reset when a NEW task is DEFINED
#   persistent      — journal, run-archive/, approval records, git history
# Everything under .loop/docs (except run-archive/) plus the HTML views and the
# definition/decompose feedback files is CONTRACT-SCOPED: the memory of ONE task.
# Without a boundary reset, a new task inherits the old one's memory — stale
# decision requests printed as current, old 'met' ledger rows aliasing the new
# contract's REQ ids (defeating the premature-READY gate), an inherited
# implementation plan. The intent signal is the ENTRY POINT, because a hash can
# never distinguish an amendment from a replacement:
#   ./loop.sh start / first definition in cmd_auto  -> NEW task: reset here
#   hand-edit product-contract.md + approve         -> amendment: memory kept
#                                                      (see cmd_approve's stamp)
#   approval_prompt 'r' (revise with Claude)        -> same task: memory kept
# Fleet worktrees never take this path (gated on .loop/fleet-worker): their docs
# are hard-reset from templates at bootstrap_worktree, and they carry no
# .loop/templates of their own.

doc_differs_from_template() { # $1 doc path -> 0 iff filled in. Compare against the
  # pristine template, NOT the '<!-- TEMPLATE -->' marker: append-style docs
  # (decision-requests.md — the incident file) keep their marker forever, so a
  # marker test would call a DR-filled file "pristine" and leak it.
  local t
  t=".loop/templates/$(basename "$1")"
  [ -f "$t" ] || return 0        # no template (e.g. task-plan.md) -> live by existence
  ! cmp -s "$1" "$t"
}

loop_memory_live() { # any contract-scoped doc OTHER than the contract filled in?
  local f
  for f in .loop/docs/*.md; do
    [ -f "$f" ] || continue
    case "$f" in */product-contract.md) continue ;; esac
    doc_differs_from_template "$f" && return 0
  done
  return 1
}

compact_observations_manifest() { # $1 source $2 destination; keep last row per (AC,path)
  local src="$1" dst="$2" tmp="${2}.tmp.$$"
  # Two passes preserve the source order of each key's LAST row. Iterating an
  # awk associative array is deliberately unspecified and produced different
  # archive bytes (and therefore broken certificate hashes) across awk builds.
  if ! awk '
    FNR == NR {
      aid=$0; sub(/^.*"ac_id":"/, "", aid); sub(/".*/, "", aid)
      path=$0; sub(/^.*"artifact_path":"/, "", path); sub(/".*/, "", path)
      if (aid != "" && path != "") last[aid SUBSEP path]=FNR
      next
    }
    {
      aid=$0; sub(/^.*"ac_id":"/, "", aid); sub(/".*/, "", aid)
      path=$0; sub(/^.*"artifact_path":"/, "", path); sub(/".*/, "", path)
      key=aid SUBSEP path
      if (aid != "" && path != "" && FNR == last[key]) print
    }
  ' "$src" "$src" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dst"
}

assign_new_task_id() { # NEW root-task boundary; fleet workers receive queue id at bootstrap
  local id
  id=$(gen_task_id root)
  printf '%s\n' "$id" > .loop/task-id
}

retire_previous_evidence_report() { # fresh run: archive stale view/certificate
  local report=.loop/docs/evidence-report.md cert=.loop/docs/certification.json ts dst live=0
  if [ -f "$report" ] && doc_differs_from_template "$report"; then live=1; fi
  [ -s "$cert" ] && live=1
  if [ "$live" -ne 1 ]; then
    [ -f "$report" ] || { [ ! -f .loop/templates/evidence-report.md ] \
      || cp .loop/templates/evidence-report.md "$report"; }
    return 0
  fi
  ts=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || echo archive)
  dst=$(unique_archive_dir ".loop/docs/run-archive/$ts-prevrun")
  mkdir -p .loop/docs/run-archive 2>/dev/null || true   # leaf mkdir below reports failure
  mkdir "$dst" \
    || die_next "cannot create the archive dir $dst" "fix permissions/disk space, then ./loop.sh run"
  if [ -f "$report" ] && doc_differs_from_template "$report"; then
    cp "$report" "$dst/evidence-report.md" \
      || die_next "could not archive the previous evidence report to $dst (nothing was reset)" "fix permissions/disk space, then ./loop.sh run"
  fi
  if [ -f .loop/templates/evidence-report.md ]; then
    cp .loop/templates/evidence-report.md "$report"
  else
    : > "$report"
  fi
  if [ -s "$cert" ]; then
    cp "$cert" "$dst/certification.json" \
      || die_next "could not archive the previous certification.json to $dst (certificate not deleted)" "fix permissions/disk space, then ./loop.sh run"
  fi
  rm -f "$cert"
}

reset_contract_scoped_docs() { # [--keep-contract] — archive + reset the loop memory.
  # Archive lands in .loop/docs/run-archive/<ts>-root/ — the same location
  # merge_task uses for fleet tasks and the place the loop-contract skill already
  # reads as intake context, so past traps stay discoverable without any skill
  # change. Commits are PATHSPEC-SCOPED to .loop/docs: user WIP is never swept.
  local keep_contract=0 ts dst f
  [ "${1:-}" = "--keep-contract" ] && keep_contract=1
  clear_task_start_ref
  [ -d .loop/templates ] && [ -n "$(ls .loop/templates/*.md 2>/dev/null)" ] \
    || die "this deployment has no .loop/templates (pristine doc templates) — run: ./loop.sh update"
  # 1. archive every filled-in doc (tracked -> the commit is the audit trail).
  # Every copy is fail-CLOSED with an explicit die_next: step 3 below DELETES
  # the originals (rm -rf .loop/observations, rm -f the manifest), so a failed
  # copy that fell through would destroy the only remaining evidence.
  ts=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || echo archive)
  dst=$(unique_archive_dir ".loop/docs/run-archive/$ts-root")
  mkdir -p .loop/docs/run-archive 2>/dev/null || true   # leaf mkdir below reports failure
  mkdir "$dst" \
    || die_next "cannot create the archive dir $dst" "fix permissions/disk space, then retry the new task definition"
  for f in .loop/docs/*.md; do
    [ -f "$f" ] || continue
    doc_differs_from_template "$f" && { cp "$f" "$dst/" \
      || die_next "could not archive $f to $dst — task reset aborted (nothing was deleted)" "fix permissions/disk space, then retry the new task definition"; }
  done
  if [ -s .loop/docs/certification.json ]; then
    cp .loop/docs/certification.json "$dst/" \
      || die_next "could not archive certification.json to $dst — task reset aborted (nothing was deleted)" "fix permissions/disk space, then retry the new task definition"
  fi
  if [ -s .loop/task-id ]; then
    cp .loop/task-id "$dst/task-id" \
      || die_next "could not archive .loop/task-id to $dst — task reset aborted (nothing was deleted)" "fix permissions/disk space, then retry the new task definition"
  fi
  if [ -d .loop/observations ]; then
    cp -R .loop/observations "$dst/observations" \
      || die_next "could not archive .loop/observations to $dst — task reset aborted (nothing was deleted)" "fix permissions/disk space, then retry the new task definition"
  fi
  if [ -s .loop/observations-manifest.jsonl ]; then
    compact_observations_manifest .loop/observations-manifest.jsonl "$dst/observations-manifest.jsonl" \
      || die_next "could not archive the observations manifest to $dst — task reset aborted (nothing was deleted)" "inspect .loop/observations-manifest.jsonl, then retry the new task definition"
  fi
  rmdir "$dst" 2>/dev/null || true   # nothing was live -> no empty archive dir
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add -- .loop/docs 2>/dev/null || true
    git diff --cached --quiet -- .loop/docs 2>/dev/null \
      || git commit -q -m "loop: new task — archive previous loop memory" -- .loop/docs
  fi
  # 2. reset the docs from the pristine templates (bootstrap_worktree's move)
  for f in .loop/templates/*.md; do
    [ "$keep_contract" = 1 ] && [ "$(basename "$f")" = "product-contract.md" ] && continue
    cp "$f" ".loop/docs/$(basename "$f")"
  done
  rm -f .loop/docs/task-plan.md   # decomposer output; has no template
  rm -f .loop/docs/certification.json
  # 3. contract-scoped ephemera outside docs/: HTML views (disposable projections
  # of the docs), definition/decompose feedback, the decision-answer channel, and
  # the approve stamp. journal.jsonl, run-archive/ and run-checkpoint stay — an
  # aborted definition must never destroy a resumable run, and a checkpoint can
  # never resume under a changed contract anyway (decide_run_mode hash check).
  rm -f .loop/reports/*.html \
        .loop/supervisor-guidance.md .loop/last-verify.log .loop/req-verdicts \
        .loop/baseline-verify.log \
        .loop/contract-review-feedback.md .loop/last-instruction.md \
        .loop/decompose-approved .loop/decompose-feedback.md \
        .loop/decompose-review-feedback.md .loop/state .loop/docs-contract
  rm -rf .loop/observations
  rm -f .loop/observations-manifest.jsonl .loop/task-id
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add -- .loop/docs 2>/dev/null || true
    git diff --cached --quiet -- .loop/docs 2>/dev/null \
      || git commit -q -m "loop: new task — reset loop memory to templates" -- .loop/docs
  fi
  journal_append "contract" "MEMORY_RESET" "new task definition — previous loop memory archived ($dst) and reset"
  note "new task: previous loop memory archived ($dst) and reset to templates"
}

guard_new_definition() { # refuse/reset before a NEW-task definition session.
  # Fleet workers skip entirely: their worktree was hard-reset at bootstrap and
  # runs its own single-task definition (no .loop/templates inside a worktree).
  [ ! -f .loop/fleet-worker ] || return 0
  # a live/parked orchestration still needs the CURRENT docs (its integration
  # gate reviews against them) — never define a new task over one
  if [ -n "$(tasks_in new)$(tasks_in claimed)" ] \
     || [ "$(cat .loop/state 2>/dev/null)" = "FLEET_RUNNING" ] || supervisor_alive; then
    die "fleet tasks are queued or an orchestration is in flight — run them first (./loop.sh run), or inspect/clean the queue (./loop.sh fleet status | ./loop.sh fleet clean <id> [--force]) before defining a new task"
  fi
  # hard backstop (protects ANY caller, even one that skipped the routing in
  # cmd_start/cmd_auto): a LIVE single-loop run still needs the current docs —
  # never archive+reset them under it. Verified-live only: a stale RUNNING
  # (dead pid) must not block a new definition forever.
  if [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ] && single_loop_alive; then
    die "a run is already active in this repo (pid $(cat .loop/run.pid 2>/dev/null)) — wait for it or stop it (Ctrl-C / kill $(cat .loop/run.pid 2>/dev/null)); queue a follow-up task instead: ./loop.sh add \"<instruction>\""
  fi
  if [ -n "$(tasks_in "done")$(tasks_in failed)" ]; then
    note "warning: finished/failed fleet tasks remain (./loop.sh fleet status) — a new plan cannot enqueue over them"
  fi
  if contract_is_defined || loop_memory_live || [ -d .loop/observations ] \
     || [ -s .loop/observations-manifest.jsonl ] || [ -s .loop/docs/certification.json ] \
     || [ -s .loop/task-id ]; then
    reset_contract_scoped_docs
  fi
  assign_new_task_id
}

route_new_task_to_fleet_add() { # "$@" = the raw new-task argv from start/auto.
  # A NEW-task definition beside a VERIFIED-LIVE run must never archive+reset
  # the running loop's memory. Instead of refusing, enqueue the instruction as
  # a follow-up fleet task (exactly `./loop.sh add`) and exit 0. Only LIVE
  # states route: a parked/stale orchestration keeps guard_new_definition's
  # refusal, and a stale RUNNING (dead pid) proceeds into a normal definition.
  # Argv passes through verbatim: a single existing-file arg enqueues that file
  # (same as resolve_instruction reads it); an instruction that literally
  # starts with --auto/--after/--force-after is parsed as an `add` flag
  # (pathological input — put it in a file instead). Fleet workers never
  # route: a worker legitimately (re)defines the contract in its own worktree.
  [ ! -f .loop/fleet-worker ] || return 0
  if supervisor_alive; then
    note "a fleet orchestration is LIVE — routing this instruction to the task queue instead of resetting the running loop's memory (same as: ./loop.sh add)"
    cmd_fleet_add "$@"
    exit 0
  fi
  if [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ]; then
    if single_loop_alive; then
      note "a run is LIVE in this repo (pid $(cat .loop/run.pid 2>/dev/null)) — routing this instruction to the task queue instead of resetting the running loop's memory (same as: ./loop.sh add)"
      cmd_fleet_add "$@"
      exit 0
    fi
    note "warning: .loop/state is RUNNING but no live loop process found (stale after a crash) — proceeding with the new definition"
  fi
}

resolve_instruction() { # "$@" -> echoes instruction text (arg text, arg file, or default files)
  if [ $# -ge 1 ]; then
    if [ -f "$1" ] && [ $# -eq 1 ]; then cat "$1"; else echo "$*"; fi
    return 0
  fi
  local f
  for f in loop-instruction.md instruction.md .loop/instruction.md; do
    if [ -f "$f" ]; then
      note "found instruction file: $f" >&2
      cat "$f"
      return 0
    fi
  done
  return 1
}

park_contract_questions() { # $1 reason — PENDING_APPROVAL park (never auto-approve on open questions)
  local why="$1"
  if ! grep -q '^## DR-CONTRACT' .loop/docs/decision-requests.md 2>/dev/null; then
    {
      echo
      echo "## DR-CONTRACT-0"
      echo "- The headless contract generator raised critical unknowns but wrote no question block."
      echo "- Generator said: $why"
      echo "- Read .loop/docs/product-contract.md, resolve the unknowns, then: ./loop.sh approve && ./loop.sh run"
    } >> .loop/docs/decision-requests.md
  fi
  # (the HTML decision for this generation is journaled ONCE by
  # generate_contract_headless, right after contract_is_defined — not here)
  journal_append "contract" "CONTRACT_QUESTIONS" "$why"
  finish PENDING_APPROVAL "contract generation raised critical unknowns — answer .loop/docs/decision-requests.md, edit the contract, then ./loop.sh approve && ./loop.sh run"
}

generate_contract_headless() { # $1 instruction — no questions asked interactively;
  # assumptions recorded. With LOOP_ASK_CRITICAL=1 (ask=critical) the generator may
  # instead raise CRITICAL unknowns — those park the run for a human (never assumed).
  # Deliberately does NOT source loop.config.sh (no approval baseline exists yet);
  # uses safe fixed defaults for this one call.
  local MAX_ITER_SECONDS="${MAX_ITER_SECONDS:-900}"
  local PERMISSION_MODE="${PERMISSION_MODE:-acceptEdits}"
  local MAX_COST_USD="${MAX_COST_USD:-}"   # no USD cap unless the caller sets one
  local VERIFY_COMMANDS=()
  local res verdict
  # keep the raw instruction: the contract reviewer judges the definition AGAINST
  # it, and the regenerate-once path replays it (harness state, gitignored)
  printf '%s\n' "$1" > .loop/last-instruction.md
  local prompt
  prompt="/loop-contract auto:$(ask_arg)$(html_arg) $1"
  if [ -f .loop/contract-review-feedback.md ]; then
    prompt="$prompt

(A previous auto-generated definition was REJECTED by the independent contract
reviewer. Read .loop/contract-review-feedback.md and address every must-fix
item in the regenerated definition.)"
  fi
  note "generating the loop definition headlessly (/loop-contract auto, $(get_model MODEL_CONTRACT opus))"
  if [ -n "$(ask_arg)" ]; then
    note "critical unknowns park the run for a human (LOOP_ASK_CRITICAL=1); the rest become assumptions"
  else
    note "open questions are recorded as assumptions in the contract instead of being asked"
  fi
  run_claude "contract-auto" "$prompt" "$(get_model MODEL_CONTRACT opus)" full CONTRACT \
    || die_next "contract generation failed (see $(agent_log_path contract-auto err))" "fix the cause, then retry: ./loop.sh start \"<what to build>\""
  contract_is_defined || die_next "contract generation did not produce a contract (see $(agent_log_path contract-auto json))" "retry: ./loop.sh start \"<what to build>\""
  # journal the generation's HTML decision exactly ONCE, before the paths below
  # diverge (READY continues; QUESTIONS/ESCALATE park via park_contract_questions,
  # which deliberately does NOT record it again)
  record_html_decision "contract-auto" "contract"
  if [ -n "$(ask_arg)" ]; then
    res=$(agent_result "contract-auto")
    verdict=$(extract_verdict "$res" "CONTRACT-GEN: (READY|QUESTIONS)")
    case "$verdict" in
      "CONTRACT-GEN: READY"*) ;;   # proceed to review/approval as today
      "CONTRACT-GEN: QUESTIONS"*)
        park_contract_questions "${verdict#CONTRACT-GEN: QUESTIONS }" ;;
      *)
        journal_append "contract" "CONTRACT_QUESTIONS_MALFORMED" "ask=critical set but no parseable CONTRACT-GEN verdict — failing closed to a human"
        park_contract_questions "unparseable generator output (treated as open questions)" ;;
    esac
  fi
  journal_append "contract" "CONTRACT_AUTO" "loop definition generated headlessly from instruction"
  note "loop definition written: .loop/docs/product-contract.md + loop.config.sh"
}

run_contract_review() { # independent read-only check of the loop definition ITSELF.
  # Auto mode approves a contract the model wrote: without this gate the loop
  # grades itself against goalposts it chose (self-grading skew — the evaluator
  # is deterministic but only as good as the VERIFY_COMMANDS the model picked).
  # Returns 0 on APPROVE; on REVISE writes .loop/contract-review-feedback.md and
  # returns 1. With ask mode active (LOOP_ASK_CRITICAL=1) the reviewer may also
  # ESCALATE a human-only question: returns 2, question in CONTRACT_REVIEW_QUESTION.
  # Reviewer unavailable = fail closed (die): running unattended against an
  # unvetted definition is exactly what this gate exists to prevent.
  # Disable with LOOP_CONTRACT_REVIEW=0 (the callers check it, not this function).
  local MAX_ITER_SECONDS="${MAX_ITER_SECONDS:-900}"
  local MAX_COST_USD="${MAX_COST_USD:-}"
  local model res="" verdict="" prompt vpat vhint
  prompt="/loop-contract-review$(ask_arg)"
  CONTRACT_REVIEW_QUESTION=""
  # without ask mode the two-valued pattern is kept: a stray ESCALATE stays
  # unparseable and lands in the REVISE fail-safe — backward compatible. The
  # ` ask=critical` token on the prompt is what makes ESCALATE observable to
  # the reviewer: the harness honors it only when the token was sent.
  vpat="CONTRACT-REVIEW: (APPROVE|REVISE)"
  vhint="'CONTRACT-REVIEW: APPROVE <summary>' or 'CONTRACT-REVIEW: REVISE <must-fix list>'"
  if [ -n "$(ask_arg)" ]; then
    vpat="CONTRACT-REVIEW: (APPROVE|REVISE|ESCALATE)"
    vhint="$vhint or 'CONTRACT-REVIEW: ESCALATE <question>'"
  fi
  model=$(get_model MODEL_REVIEW opus)
  note "contract review: independent check of the loop definition ($model, read-only)"
  for _ in 1 2; do   # up to twice: retry on launch failure OR unparseable verdict
    run_claude "contract-review" "$prompt" "$model" reader REVIEW || continue
    res=$(agent_result "contract-review")
    verdict=$(extract_verdict "$res" "$vpat")
    [ -z "$verdict" ] || break
    prompt="/loop-contract-review$(ask_arg) (FORMAT REMINDER: the LAST line of your reply must be exactly $vhint — plain text, no code fence. Your previous attempt contained no parseable verdict.)"
  done
  if [ -z "$res" ]; then
    journal_append "contract" "CONTRACT_REVIEW_ERROR" "contract reviewer call failed twice"
    die "contract review unavailable (see $(agent_log_path contract-review err)) — read the contract yourself, then: ./loop.sh approve && ./loop.sh run"
  fi
  if [ -z "$verdict" ]; then
    # fail safe: an unvetted definition must not run unattended — say so honestly
    verdict="CONTRACT-REVIEW: REVISE (unparseable reviewer output after a format-reminder retry — treated as revise)"
    res="$verdict
$res"
  fi
  if [ "${verdict#CONTRACT-REVIEW: APPROVE}" != "$verdict" ]; then
    rm -f .loop/contract-review-feedback.md
    journal_append "contract" "CONTRACT_REVIEW_APPROVE" "$verdict"
    note "contract review -> APPROVE"
    return 0
  fi
  if [ "${verdict#CONTRACT-REVIEW: ESCALATE}" != "$verdict" ]; then
    # a human-only question about the definition itself: no regen round — the
    # generator cannot answer what the reviewer could not (caller parks, rc 2)
    CONTRACT_REVIEW_QUESTION="${verdict#CONTRACT-REVIEW: ESCALATE}"
    CONTRACT_REVIEW_QUESTION="${CONTRACT_REVIEW_QUESTION# }"
    journal_append "contract" "CONTRACT_REVIEW_ESCALATE" "$verdict"
    note "contract review -> ESCALATE (a human must answer before this definition runs)"
    return 2
  fi
  {
    echo "# Contract reviewer feedback — the loop definition was rejected before approval"
    echo
    printf '%s\n' "$res"
  } > .loop/contract-review-feedback.md
  journal_append "contract" "CONTRACT_REVIEW_REVISE" "$verdict"
  note "contract review -> REVISE (feedback: .loop/contract-review-feedback.md)"
  return 1
}

contract_session_interactive() { # $1 instruction — TTY only; retries once on launch failure
  local rc=0
  # Interactive DEFINITION session. Default permission-mode is `auto` (Claude
  # Code's classifier-gated mode): the human stays in the conversation and still
  # answers every SUBSTANTIVE question — clarifying AskUserQuestion prompts, the
  # "which approach?" step after an HTML mockup opens, and the final y/r/n
  # approval — but routine tool calls (repo exploration: grep/ls/git/read) no
  # longer raise a per-command permission prompt. AskUserQuestion and the y/r/n
  # gate are NOT permission prompts, so they survive any mode. Override with
  # LOOP_CONTRACT_PERMISSION_MODE (acceptEdits on an older Claude Code that lacks
  # `auto`; bypassPermissions to drop the classifier entirely). This governs ONLY
  # the pre-approval definition session — the gated run loop keeps its own
  # PERMISSION_MODE (loop.config.sh), a separate, hash-approved trust context.
  local pmode="${LOOP_CONTRACT_PERMISSION_MODE:-auto}"
  note "launching interactive contract session (explore -> minimal questions -> loop definition; permission-mode=$pmode)"
  # shellcheck disable=SC2046  # effort_opt word-splits into '--effort <level>' or nothing on purpose
  "$CLAUDE_CMD" --model "$(get_model MODEL_CONTRACT opus)" $(effort_opt CONTRACT) --permission-mode "$pmode" \
    "/loop-contract$(html_arg) $1" || rc=$?
  if [ "$rc" -ne 0 ] && ! contract_is_defined; then
    # retry on the SAFE, universally-supported mode: if $pmode failed because the
    # installed Claude Code doesn't accept `auto`, acceptEdits still launches.
    note "contract session failed to launch (rc=$rc) — retrying once with sonnet (permission-mode=acceptEdits)"
    # shellcheck disable=SC2046  # effort_opt word-splits on purpose
    "$CLAUDE_CMD" --model sonnet $(effort_opt CONTRACT) --permission-mode acceptEdits "/loop-contract$(html_arg) $1" || true
  fi
}

approval_prompt() { # interactive approve->run / revise / exit
  local ans
  while :; do
    printf 'loop: approve the contract and start the loop? [y=approve&run / r=revise with Claude / n=exit] '
    read -r ans || ans="n"
    case "$ans" in
      y|Y)
        cmd_approve
        cmd_run
        ;;
      r|R)
        # revise is the same interactive definition surface — same permission
        # mode as contract_session_interactive (auto by default; override via
        # LOOP_CONTRACT_PERMISSION_MODE)
        # shellcheck disable=SC2046  # effort_opt word-splits on purpose
        "$CLAUDE_CMD" --model "$(get_model MODEL_CONTRACT opus)" $(effort_opt CONTRACT) --permission-mode "${LOOP_CONTRACT_PERMISSION_MODE:-auto}" \
          "/loop-contract revise: the user wants to revise the current loop definition. Read .loop/docs/product-contract.md and loop.config.sh, ask what should change, apply the changes, then re-present the full loop definition summary and ask for approval."
        ;;
      n|N)
        note "exiting — approve later with: ./loop.sh approve && ./loop.sh run"
        exit 0
        ;;
    esac
  done
}

park_review_escalation() { # the contract reviewer raised a human-only question
  # (ask mode, rc 2): append it as a DR-CONTRACT block, then park — no regen
  # round, the generator cannot answer what the reviewer could not. Never returns.
  local q="${CONTRACT_REVIEW_QUESTION:-unstated question (see $(agent_log_path contract-review json))}"
  {
    echo
    echo "## DR-CONTRACT-REVIEW"
    echo "- The independent contract reviewer escalated: $q"
    echo "- Answer it (edit .loop/docs/product-contract.md / loop.config.sh), then: ./loop.sh approve && ./loop.sh run"
  } >> .loop/docs/decision-requests.md
  park_contract_questions "contract reviewer escalated: $q"
}

post_definition_flow() { # contract exists; decide approval path and run
  local crc
  if contract_is_approved; then
    cmd_run
  fi
  if [ "$AUTO_MODE" = "1" ]; then
    # No human reads the definition on this path — an INDEPENDENT contract
    # review must, or the loop runs against goalposts the model set for itself.
    # One self-repair round (regenerate against the feedback), then escalate:
    # a definition that cannot pass an independent check is a human decision
    # (exit 3 — watch never retries it). A reviewer ESCALATE (rc 2, ask mode)
    # parks immediately instead. LOOP_CONTRACT_REVIEW=0 opts out.
    if [ "${LOOP_CONTRACT_REVIEW:-1}" != "0" ]; then
      crc=0
      run_contract_review || crc=$?
      [ "$crc" != 2 ] || park_review_escalation
      if [ "$crc" -ne 0 ]; then
        if [ -f .loop/last-instruction.md ]; then
          note "regenerating the loop definition once against the reviewer feedback"
          journal_append "contract" "CONTRACT_REGEN" "regenerating after contract-review REVISE"
          generate_contract_headless "$(cat .loop/last-instruction.md)"
          crc=0
          run_contract_review || crc=$?
          [ "$crc" != 2 ] || park_review_escalation
        fi
        if [ "$crc" -ne 0 ]; then
          finish NEEDS_SPEC_DECISION "loop definition failed independent contract review (.loop/contract-review-feedback.md) — fix the contract/config, or define interactively: ./loop.sh start"
        fi
      fi
    fi
    note "auto mode: approving the loop definition and starting (audited in .loop/journal.jsonl)"
    cmd_approve
    journal_append "contract" "AUTO_APPROVED" "approved without interactive review (auto mode)"
    cmd_run
  fi
  note "contract is defined but not approved. Summary:"
  echo "----------------------------------------------"
  sed -n '1,25p' .loop/docs/product-contract.md
  echo "----------------------------------------------"
  # the acceptance gate IS what the human is approving — show it at the prompt.
  # Extracted textually, never sourced: pre-approval config is unverified input
  # (same posture as the fleet approve preview's grep).
  echo "verify gate (every command must exit 0 for SUCCESS):"
  awk '/^[[:space:]]*VERIFY_COMMANDS=\(/ { f=1 }
       f { print "  " $0 }
       f && /\)[[:space:]]*$/ { exit }' loop.config.sh 2>/dev/null || true
  echo "----------------------------------------------"
  note "full contract: .loop/docs/product-contract.md | stop conditions: loop.config.sh | models: loop.models.sh"
  if [ -t 0 ]; then
    approval_prompt
  else
    note "no TTY for the approval prompt. Either:"
    note "  review + approve manually:  ./loop.sh approve && ./loop.sh run"
    note "  or run fully autonomous:    ./loop.sh auto      (auto-approves, never stops here)"
    exit 0
  fi
}

cmd_start() {
  [ $# -ge 1 ] || die "usage: ./loop.sh start <instruction | instruction-file>"
  need_kit
  ensure_loop_dir
  need_awk
  need_sha
  # a LIVE run routes the instruction to the queue and exits 0 — BEFORE the
  # claude-CLI check (`add` needs no model) and BEFORE guard_new_definition
  # (which would archive+reset the live run's memory)
  route_new_task_to_fleet_add "$@"
  need_claude
  trap on_contract_int INT TERM   # never orphan the contract-gen model child
  # `start` DEFINES A NEW TASK: the previous task's loop memory must not leak
  # into it (stale DRs, aliased 'met' ledger rows, an inherited plan) — archive
  # and reset it now, before the definition session reads anything
  guard_new_definition
  local instr
  instr=$(resolve_instruction "$@")
  if [ -t 0 ] && [ "$AUTO_MODE" != "1" ]; then
    contract_session_interactive "$instr"
  else
    [ "$AUTO_MODE" = "1" ] || note "no TTY — the interactive Q&A is unavailable; generating the definition headlessly"
    generate_contract_headless "$instr"
  fi
  if contract_is_defined; then
    post_definition_flow
  else
    note "no contract was written — run ./loop.sh start again, or ./loop.sh auto \"<instruction>\""
    exit 2
  fi
}

cmd_auto() { # ./loop.sh with no arguments (guided) or `./loop.sh auto` (AUTO_MODE=1)
  need_kit
  ensure_loop_dir
  need_awk
  need_sha
  # an argv instruction beside a LIVE run routes to the queue, same as
  # cmd_start. Args imply `./loop.sh auto` (AUTO_MODE=1, see the dispatcher),
  # so the task rides the queue with --auto — nobody is around to approve a
  # sub-contract later. Bare `./loop.sh` (no args) NEVER routes: with a live
  # run, cmd_run's guard reports it (contract defined) or guard_new_definition's
  # backstop refuses (contract missing) — a leftover loop-instruction.md must
  # never silently enqueue itself on every invocation.
  [ $# -eq 0 ] || route_new_task_to_fleet_add --auto "$@"
  need_claude
  trap on_contract_int INT TERM   # never orphan the contract-gen model child
  if ! contract_is_defined; then
    # first definition = NEW task: reset any residual loop memory (a deleted or
    # never-written contract can still leave filled-in docs behind)
    guard_new_definition
    local instr
    if ! instr=$(resolve_instruction "$@"); then
      echo "loop: no contract and no instruction yet."
      echo "  1) write your task into loop-instruction.md (markdown), then run ./loop.sh again"
      echo "  2) or: ./loop.sh start \"<instruction>\"   (interactive definition)"
      echo "  3) or: ./loop.sh auto \"<instruction>\"    (fully autonomous, no approval stop)"
      exit 2
    fi
    if [ -t 0 ] && [ "$AUTO_MODE" != "1" ]; then
      contract_session_interactive "$instr"
      contract_is_defined || { note "no contract was written — try again, or: ./loop.sh auto"; exit 2; }
    else
      [ "$AUTO_MODE" = "1" ] || note "no TTY — generating the loop definition headlessly (interactive Q&A unavailable)"
      generate_contract_headless "$instr"
    fi
  elif [ $# -gt 0 ]; then
    # a defined contract wins over an argv instruction — never silently: the
    # user may believe they just started a NEW task while the OLD one runs
    note "warning: a contract is already defined — the instruction argument is IGNORED (running the existing contract). New task: ./loop.sh start \"<instruction>\""
  fi
  post_definition_flow
}

cmd_contract_review() { # standalone gate: exit 0 APPROVE / 4 REVISE / 2 error.
  # fleet.sh runs this before ANY unattended approval; humans can run it too
  # as a second opinion before ./loop.sh approve.
  need_kit
  ensure_loop_dir
  need_awk
  need_sha
  need_claude
  contract_is_defined || die_next "no loop definition to review (.loop/docs/product-contract.md is missing or still the template)" "define a task first: ./loop.sh start \"<what to build>\""
  trap on_contract_int INT TERM   # never orphan the reviewer model child
  run_contract_review || exit 4
}

approve_definition_lint() { # deterministic definition checks BEFORE the hashes
  # are written (dynamic-evaluator theory: coverage/traceability/oracle-safety
  # audits belong at contract-fix time, not at the first failing gate).
  # Violations: interactive TTY -> list + explicit y/N override; unattended
  # (AUTO_MODE, fleet worker, or no TTY) -> refuse with exit 3. On the auto
  # path the independent contract review (run BEFORE approval) is the
  # model-driven fix round for these same defect classes; this lint is the
  # deterministic backstop behind it, so its refusal parks for a human.
  local cl=.loop/docs/acceptance-checklist.md pc=.loop/docs/product-contract.md
  local lint="" row_ids="" anchor_ids="" req_ids="" row_reqs="" dup="" bad="" miss="" x
  if [ -f "$cl" ]; then
    row_ids=$(awk -F'|' '/^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
        id=$2; gsub(/^[ \t]+/,"",id); gsub(/[ \t]+$/,"",id); print id }' "$cl" 2>/dev/null || true)
  fi
  if [ -n "$row_ids" ]; then
    # (a) duplicate AC ids — two rows claiming one id make its status ambiguous
    dup=$(printf '%s\n' "$row_ids" | sort | uniq -d | tr '\n' ' ' | sed 's/ $//')
    [ -z "$dup" ] || lint="$lint
  - duplicate AC ids in the checklist: $dup"
    # (b) dangling REQ references — a row tracing to a REQ the contract does
    # not define is invented scope (or a typo that silently unlinks the row)
    req_ids=$(req_ids_from_contract)
    if [ -n "$req_ids" ]; then
      row_reqs=$(awk -F'|' '/^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
          r=$3; gsub(/^[ \t]+/,"",r); gsub(/[ \t]+$/,"",r); print r }' "$cl" 2>/dev/null | sort -u || true)
      while IFS= read -r x; do
        [ -n "$x" ] || continue
        printf '%s\n' "$req_ids" | grep -qx "$x" || bad="$bad $x"
      done <<EOF
$row_reqs
EOF
      [ -z "$bad" ] || lint="$lint
  - checklist rows reference REQ ids the contract does not define:$bad"
    fi
  fi
  # (c) contract-anchored AC ids with no checklist row — the evaluator (6.6)
  # would refuse the success gate forever; surface it at approval instead
  # (extraction mirrors evaluate.sh's 6.6 anchor rule: list items only)
  anchor_ids=$(sed -nE 's/^[[:space:]]*[-*][[:space:]]*(AC-[0-9]+).*/\1/p' "$pc" 2>/dev/null | sort -u || true)
  if [ -n "$anchor_ids" ]; then
    while IFS= read -r x; do
      [ -n "$x" ] || continue
      printf '%s\n' "$row_ids" | grep -qx "$x" || miss="$miss $x"
    done <<EOF
$anchor_ids
EOF
    [ -z "$miss" ] || lint="$lint
  - contract Acceptance Criteria name AC ids with no checklist row:$miss"
  fi
  # (d) destructive gate commands — the evaluator re-runs VERIFY_COMMANDS via
  # /bin/sh every iteration, and on the unattended path they are model-authored
  # (allowlist-oracle theory adapted: the gate stays the project's own commands,
  # but a headless run never executes sudo / rm -rf on absolute paths /
  # pipe-to-shell / force pushes / raw device writes unconfirmed). Textual scan
  # only — the config is deliberately NOT sourced before approval.
  local vc_text="" danger=""
  vc_text=$(awk '/^VERIFY_COMMANDS=\(/{f=1} f{print} f&&/\)[[:space:]]*$/{f=0}' loop.config.sh 2>/dev/null \
            | grep -vE '^[[:space:]]*#' || true)
  if [ -n "$vc_text" ]; then
    if printf '%s\n' "$vc_text" | grep -qE '(^|[^[:alnum:]_])sudo[[:space:]]'; then danger="$danger sudo"; fi
    if printf '%s\n' "$vc_text" | grep -qE "rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+[\"']?(/|~|\\\$HOME)"; then danger="$danger rm-rf-on-absolute-path"; fi
    if printf '%s\n' "$vc_text" | grep -qE '(curl|wget)[^|]*\|[[:space:]]*(ba|z)?sh'; then danger="$danger pipe-to-shell"; fi
    if printf '%s\n' "$vc_text" | grep -qE "git[[:space:]]+push[[:space:]][^&;|]*(--force|[[:space:]]-f)([[:space:]\"']|$)"; then danger="$danger git-force-push"; fi
    if printf '%s\n' "$vc_text" | grep -qE 'dd[[:space:]][^&;|]*of=/dev/'; then danger="$danger dd-to-device"; fi
    if printf '%s\n' "$vc_text" | grep -qE "(^|[[:space:]\"'])mkfs"; then danger="$danger mkfs"; fi
    [ -z "$danger" ] || lint="$lint
  - destructive pattern(s) in VERIFY_COMMANDS:$danger (the evaluator re-runs the gate every iteration)"
  fi
  # (e) no REQ headings at all — REQ ids are extracted from HEADING lines only
  # (### REQ-001: ...), and that extraction arms the whole requirement-first
  # machinery: the evaluator's ledger gate (6.5), the gate reviewer's per-REQ
  # verdict backstop, and lint (b) above. A contract whose requirements are
  # prose or bullets leaves all of it vacuously disarmed — refuse at approval,
  # where fixing the format costs one edit instead of a silent unguarded run.
  [ -n "${req_ids:-}" ] || req_ids=$(req_ids_from_contract)
  [ -n "$req_ids" ] || lint="$lint
  - the contract defines no REQ headings (write each requirement as a heading: '### REQ-001: <name>') — without them the per-REQ gates are disarmed"
  [ -n "$lint" ] || return 0
  if [ -t 0 ] && [ -t 1 ] && [ "$AUTO_MODE" != "1" ] && [ ! -f .loop/fleet-worker ]; then
    printf 'loop: the loop definition failed the approval lint:%s\n' "$lint"
    local ans=""
    printf 'loop: approve anyway? [y/N] '
    read -r ans || ans=n
    case "$ans" in
      y|Y)
        journal_append "contract" "APPROVE_LINT_OVERRIDE" "human approved despite:$(printf '%s' "$lint" | tr '\n' ' ')"
        return 0 ;;
    esac
    journal_append "contract" "APPROVE_REFUSED" "definition lint failed; human declined the override"
    echo "loop: approval aborted — fix the definition, or re-run approve and answer y to override" >&2
    exit 3
  fi
  journal_append "contract" "APPROVE_REFUSED" "definition lint failed (unattended):$(printf '%s' "$lint" | tr '\n' ' ')"
  { echo "loop: error: the loop definition failed the approval lint:"
    printf '%s\n' "$lint"
    echo "loop: fix the definition (contract / acceptance checklist / loop.config.sh), or approve interactively to override."
  } >&2
  exit 3
}

cmd_approve() {
  need_kit
  [ -f .loop/docs/product-contract.md ] || die_next "no .loop/docs/product-contract.md to approve" "define a task first: ./loop.sh start \"<what to build>\""
  ensure_loop_dir
  need_sha
  local old_hash st slot tmp
  # ---- amendment vs replacement: the stamp records WHICH product contract the
  # current loop memory (docs) belongs to. The stamp hashes product-contract.md
  # ALONE (contract_hash also covers loop.config.sh — a budget tweak must not
  # look like a new task). A definition session (./loop.sh start) resets docs AND
  # removes the stamp, so this trigger fires only for a contract changed OUTSIDE
  # a definition session — i.e. a hand edit. Hand edits are usually AMENDMENTS
  # (the documented decision-answer flow: edit + approve + run), so memory is
  # kept by default; only the human can say "this is actually a new task".
  local pc_sha stamp reset_memory=0
  pc_sha=$(sha256 < .loop/docs/product-contract.md)
  stamp=$(cat .loop/docs-contract 2>/dev/null || echo "")
  if [ -n "$stamp" ] && [ "$stamp" != "$pc_sha" ] && loop_memory_live; then
    st=$(cat .loop/state 2>/dev/null || echo "")
    if [ -t 0 ] && [ -t 1 ] && [ "$AUTO_MODE" != "1" ] && [ ! -f .loop/fleet-worker ]; then
      local ans=""
      while :; do
        printf 'loop: the product contract changed since the last approval. Is this an\nloop: (a)mendment of the same task (KEEP loop memory: progress, ledger, decision requests)\nloop: or a (n)ew task (ARCHIVE + RESET the loop memory)? [a/n] '
        read -r ans || ans=a
        case "$ans" in
          a|A) break ;;
          n|N) reset_memory=1; break ;;
        esac
      done
    elif [ "$AUTO_MODE" = "1" ]; then
      case "$st" in
        NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|RISK_REQUIRES_APPROVAL|PENDING_APPROVAL)
          note "auto mode: contract amended while answering a decision — keeping loop memory" ;;
        *)
          # unattended + replaced outside both a definition session and the
          # decision-answer flow: no human can supply the intent — fail closed
          journal_append "contract" "APPROVE_REFUSED" "contract replaced outside a definition session (auto mode) — intent unknown"
          echo "loop: error: the product contract was REPLACED outside a definition session — auto mode cannot tell an amendment from a new task." >&2
          echo "loop: for a new task: ./loop.sh start \"<instruction>\"   |   to amend keeping memory: ./loop.sh approve (interactively or as a human)" >&2
          exit 3 ;;
      esac
    else
      note "warning: the product contract changed since the last approval — KEEPING the loop memory (progress.md, requirements-ledger.md, decision-requests.md, implementation-plan.md)."
      note "if this is a NEW task, reset it: ./loop.sh start \"<instruction>\" (archives + resets), or approve interactively to choose."
      journal_append "contract" "MEMORY_CARRIED" "contract changed at approve; loop memory kept (headless default)"
    fi
  fi
  if [ "$reset_memory" = 1 ]; then
    reset_contract_scoped_docs --keep-contract
    assign_new_task_id
  fi
  approve_definition_lint
  echo "$pc_sha" > .loop/docs-contract
  old_hash=$(cat .loop/approved 2>/dev/null || echo "")
  # ---- unchanged-re-approval guard: a run that stopped for a spec/architecture
  # decision is ANSWERED by editing the contract (that is the whole point of the
  # NEEDS_*_DECISION escalation). If a human re-approves a byte-identical
  # contract+config while such a decision is open, the loop keeps the SAME contract
  # and re-stops at the SAME gate — the exact trap where "I gave feedback, ran
  # approve, and it stopped again" comes from (the feedback was a contract change
  # fed through an unchanged approval). Warn and require explicit confirmation.
  # TTY human only: AUTO/fleet supervisors legitimately re-approve unchanged to
  # answer a WITHIN-contract decision (guidance channel), so they keep behavior.
  st=$(cat .loop/state 2>/dev/null || echo "")
  case "$st" in
    NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION)
      if [ -n "$old_hash" ] && [ "$(contract_hash)" = "$old_hash" ]; then
        if [ -t 0 ] && [ -t 1 ] && [ "$AUTO_MODE" != "1" ] && [ ! -f .loop/fleet-worker ]; then
          local reans=""
          note "⚠ the contract + config are UNCHANGED, but this run stopped for a decision"
          note "  (see .loop/docs/decision-requests.md). Re-approving as-is tells the loop to KEEP"
          note "  the current contract — it will re-stop at the same gate. Approving is NOT applying"
          note "  feedback: to change a requirement, edit the contract first (/loop-contract or"
          note "  .loop/docs/product-contract.md). Only continue if your answer needs no contract change."
          while :; do
            printf 'loop: approve the UNCHANGED contract anyway? [y/N] '
            read -r reans || reans="n"
            case "$reans" in
              y|Y) journal_append "contract" "APPROVE_UNCHANGED" "unchanged re-approval confirmed at $st (human)"; break ;;
              n|N|"")
                journal_append "contract" "APPROVE_ABORTED" "unchanged re-approval declined at $st — no change written"
                note "approve aborted — nothing was changed."
                print_next_actions decision
                exit 0 ;;
            esac
          done
        else
          # headless / auto / fleet: no human to confirm, so keep today's behavior
          # (re-approve → decision rebind → resume), but make the choice auditable —
          # a within-contract decision legitimately answers by re-approving unchanged.
          journal_append "contract" "APPROVE_UNCHANGED" "unchanged re-approval at $st (contract+config byte-identical; kept as-is)"
        fi
      fi ;;
  esac
  contract_hash > .loop/approved
  harness_hash > .loop/approved-harness
  # off-tree approval store: written IN ADDITION to the repo mirrors above (the
  # mirrors stay authoritative for status/UX and the standalone evaluator; the
  # store is what verify_approval ultimately trusts — see approval_home)
  if [ "$(approval_home)" != "repo" ]; then
    slot=$(approval_slot)
    mkdir -p "$slot"
    tmp="$slot/.approved.tmp.$$"
    contract_hash > "$tmp"
    mv -f "$tmp" "$slot/approved"
    tmp="$slot/.approved-harness.tmp.$$"
    harness_hash > "$tmp"
    mv -f "$tmp" "$slot/approved-harness"
  fi
  note "approved: contract + config ($(cut -c1-12 < .loop/approved)…), harness ($(cut -c1-12 < .loop/approved-harness)…)"
  note "any change to the contract, loop.config.sh, loop.sh, evaluate.sh, the skills,"
  note "or the session config (.claude settings, .mcp.json) now stops the loop until you re-approve."
  # ---- decision rebind: re-approving after a decision stop re-binds the run
  # checkpoint to the NEW hashes so `run` resumes with counters/cost intact.
  # Same trust move as the budget-only exception: the human is present and is
  # approving exactly this contract; the checkpoint still carries no field a
  # fresh run wouldn't grant (counters bound budget downward, refs re-validated).
  # Precondition: the checkpoint belongs to the run being answered (its
  # CONTRACT_HASH matches the PREVIOUS approval). LOOP_DECISION_RESUME=0 opts out.
  st=$(cat .loop/state 2>/dev/null || echo "")
  case "$st" in
    NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|RISK_REQUIRES_APPROVAL)
      if [ "${LOOP_DECISION_RESUME:-1}" != "0" ] && [ -f .loop/run-checkpoint ] \
         && [ -n "$old_hash" ] && [ "$(ckpt_get CONTRACT_HASH)" = "$old_hash" ]; then
        ckpt_rebind_decision "$st"
      fi ;;
  esac
}

decide_run_mode() { # $1 force_fresh $2 require_resume $3 prefer_resume -> echoes: fresh | resume | refuse:<msg>
  # Pure decision (no side effects; the only stdout is the chosen mode). Reads
  # .loop/state + the checkpoint, and validates the checkpoint against the
  # IN-MEMORY approved hashes (RUN_CONTRACT_HASH/RUN_HARNESS_HASH). Never trusts a
  # checkpoint field for anything a fresh run wouldn't already allow.
  #   require_resume (explicit `./loop.sh resume`): resume from a terminal failure
  #     too; on any not-resumable condition REFUSE (loudly) rather than restart.
  #   prefer_resume (fleet's relaunch): same eligibility as require_resume, but on a
  #     not-resumable condition fall back to FRESH instead of refusing (so a fleet
  #     task never dead-ends — it just restarts).
  local force_fresh="$1" require_resume="$2" prefer_resume="${3:-0}"
  local st="" ck=0 cki want_resume=0
  [ "$require_resume" = 1 ] && want_resume=1
  [ "$prefer_resume" = 1 ] && want_resume=1
  st=$(cat .loop/state 2>/dev/null || echo "")
  [ -f .loop/run-checkpoint ] && ck=1

  if [ "$force_fresh" = 1 ]; then
    [ "$require_resume" = 1 ] && { echo "refuse:--fresh and resume are mutually exclusive"; return 0; }
    echo fresh; return 0
  fi
  if [ "$ck" = 0 ]; then
    [ "$require_resume" = 1 ] && { echo "refuse:no interrupted run to resume — start one with ./loop.sh run"; return 0; }
    echo fresh; return 0
  fi

  # the checkpoint must belong to THIS approved contract + harness
  local contract_ok=0
  if [ "$(ckpt_get CONTRACT_HASH)" = "$RUN_CONTRACT_HASH" ]; then
    contract_ok=1
  else
    # tolerate a budget-only re-approval: a human who raised ONLY MAX_ITERATIONS /
    # MAX_COST_USD (and re-approved) may continue the same run under the bigger cap
    local ck_sb ck_maxit
    ck_sb=$(ckpt_get CONFIG_HASH_SANS_BUDGET)
    ck_maxit=$(ckpt_int MAX_ITERATIONS_AT_START 0)
    if [ -n "$ck_sb" ] && [ "$ck_sb" = "$(config_hash_sans_budget)" ] \
       && [ "$ck_maxit" -gt 0 ] && [ "$MAX_ITERATIONS" -ge "$ck_maxit" ]; then
      contract_ok=1
    fi
  fi
  if [ "$contract_ok" = 0 ]; then
    [ "$require_resume" = 1 ] && { echo "refuse:contract changed since the interrupted run — start fresh with ./loop.sh run (progress.md + git carry the memory forward)"; return 0; }
    echo fresh; return 0
  fi
  if [ "$(ckpt_get HARNESS_HASH)" != "$RUN_HARNESS_HASH" ]; then
    [ "$require_resume" = 1 ] && { echo "refuse:harness changed since the interrupted run — start fresh with ./loop.sh run"; return 0; }
    echo fresh; return 0
  fi

  cki=$(ckpt_int ITERATION 1)
  case "$st" in
    RUNNING|INTERRUPTED)
      # in-flight, no human decision: bare `run` resumes these too (fleet's
      # crash/interrupt recovery relies on it)
      echo resume ;;
    BLOCKED|STALLED)
      if [ "$want_resume" = 1 ]; then echo resume; else echo fresh; fi ;;
    BUDGET_EXCEEDED)
      if [ "$cki" -le "$MAX_ITERATIONS" ]; then
        if [ "$want_resume" = 1 ]; then echo resume; else echo fresh; fi
      elif [ "$require_resume" = 1 ]; then
        echo "refuse:iteration budget exhausted — raise MAX_ITERATIONS in loop.config.sh and ./loop.sh approve, then ./loop.sh resume (or ./loop.sh run --fresh)"
      else
        echo fresh
      fi ;;
    NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|RISK_REQUIRES_APPROVAL)
      if [ "$(ckpt_get DECISION_REBOUND)" = "1" ]; then
        echo resume        # re-approval already re-bound the hashes (cmd_approve)
      elif [ "$require_resume" = 1 ]; then
        echo "refuse:this run stopped for a human decision — resolve it (.loop/docs/decision-requests.md), then ./loop.sh approve && ./loop.sh run"
      else
        echo fresh
      fi ;;
    SUCCESS|NO_OP)
      if [ "$require_resume" = 1 ]; then echo "refuse:the last run already completed ($st) — nothing to resume"; else echo fresh; fi ;;
    *)
      if [ "$require_resume" = 1 ]; then echo "refuse:no resumable run state (.loop/state='$st')"; else echo fresh; fi ;;
  esac
  return 0
}

cmd_run() {
  local force_fresh=0 require_resume=0 prefer_resume=0 single=0 resume_note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --fresh)          force_fresh=1; shift ;;
      --single)         single=1; shift ;;           # skip decomposition: classic in-place loop
      --require-resume) require_resume=1; shift ;;   # internal: set by cmd_resume
      --prefer-resume)  prefer_resume=1; shift ;;    # internal: fleet relaunch (resume if possible, else fresh)
      --note)           resume_note="${2:-}"
                        [ -n "$resume_note" ] || die "resume --note needs a value: ./loop.sh resume --note '<guidance>'"
                        shift 2 ;;
      *) die_next "unknown option for run: $1" "see ./loop.sh -h" ;;
    esac
  done
  [ -z "$resume_note" ] || [ "$require_resume" = 1 ] \
    || die "--note is only valid with resume: ./loop.sh resume --note '<guidance>'"

  need_kit
  ensure_loop_dir
  # split-brain guard for EVERY mode, before ANY side effect: without it a
  # `run --fresh` beside a LIVE loop deletes that run's run-scoped artifacts
  # (the fresh-clear below) and can even launch a decompose/fleet next to it —
  # only the resume branch was guarded. Verified-live only (pid + ps-or-
  # heartbeat); a stale RUNNING (dead pid) proceeds: fresh warns below, resume
  # journals RUN_ABEND as before. The resume-branch guard stays as a TOCTOU belt.
  if [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ] && single_loop_alive; then
    die "a run is already active in this repo (pid $(cat .loop/run.pid 2>/dev/null)) — wait for it or stop it (Ctrl-C / kill $(cat .loop/run.pid 2>/dev/null)) before running again"
  fi
  # SECURITY: verify hashes BEFORE sourcing any config shell code
  verify_approval
  load_config
  load_models

  # Tamper-proof baselines: like TOTAL_COST, these live in loop.sh's memory for
  # the whole run. The agent can write the on-disk .loop/approved* files, but
  # cannot alter these copies — the evaluator receives the contract hash as an
  # argument and the harness hash is re-checked against memory at every step.
  RUN_CONTRACT_HASH=$(contract_hash)
  RUN_HARNESS_HASH=$(harness_hash)
  RUN_MODELS_HASH=$(models_hash)

  need_claude
  need_awk
  need_sha
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git repository — run: git init && git add -A && git commit -m init"
  # declare -p guard first: an entirely missing declaration would otherwise crash
  # bash <4.4 under set -u instead of producing this message
  if ! declare -p VERIFY_COMMANDS >/dev/null 2>&1 || [ "${#VERIFY_COMMANDS[@]}" -eq 0 ]; then
    die_next "loop.config.sh defines no VERIFY_COMMANDS — a loop needs a verifiable goal" "add VERIFY_COMMANDS=(...) to loop.config.sh, then ./loop.sh approve"
  fi
  [ -f .claude/skills/loop-iterate/SKILL.md ] || die "loop skills missing in .claude/skills/ — redeploy the kit"
  local evaluator="$EVALUATOR"
  if [ -f .loop/bin/evaluate.sh ]; then evaluator="$(pwd)/.loop/bin/evaluate.sh"; fi

  local identity_mode
  identity_mode=$(decide_run_mode "$force_fresh" "$require_resume" "$prefer_resume")
  case "$identity_mode" in refuse:*) die "${identity_mode#refuse:}" ;; esac
  initialize_run_identity "$identity_mode"
  pin_observation_manifest \
    || die "observations manifest is unreadable or not a regular file — inspect .loop/observations-manifest.jsonl before running"

  # before the loop starts committing, make sure the harness is git-ignored
  # (covers projects deployed before this was added; no-op once installed)
  [ "$MODE" = "deployed" ] && ensure_gitignore

  trap on_interrupt INT TERM

  # A fresh run must never consume a PRIOR run's run-scoped artifacts:
  #   decision.html/evidence.html — fixed-name disposable views; open_html() only
  #     checks existence, so finish() would open a days-old unrelated page
  #   supervisor-guidance.md — the decision-answer channel; loop-iterate treats it
  #     as THE human decision, so a stale one answers a question this run never asked
  #   last-verify.log / req-verdicts — a stale green log/verdict set would satisfy
  #     this run's forced-gate precondition and evidence context
  # Clear them so each exists iff THIS run produced it. A resume keeps its own
  # in-flight artifacts (same logical run) — the root decision-answer flow rebinds
  # the checkpoint and resolves to resume, so the guidance it just wrote survives.
  # Fleet workers are exempt from clearing the supervisor guidance below: the
  # parent writes it immediately before a relaunch that may fall back to fresh.
  # They are NOT exempt from retiring stale evidence/certification views.
  # Must run BEFORE the routing block: cmd_decompose_flow can finish() (e.g.
  # decompose failed twice) without any iteration ever running.
  # An in-flight orchestration is exempt too: decide_run_mode maps FLEET_RUNNING
  # to "fresh" (it only knows single-loop states), but a bare `run` there RESUMES
  # the orchestration — clearing would make `run` and `resume` diverge in side
  # effects on the same resume. Safe to skip: every fleet_inflight path either
  # dies (--single/--fresh) or enters run_fleet_orchestration (never returns)
  # before the in-place loop, and the integration gate regenerates
  # last-verify.log / req-verdicts / evidence itself.
  if ! fleet_inflight && [ "$identity_mode" = "fresh" ]; then
    # Evidence reports and certificates describe one completed run. Preserve
    # them in history, but never expose them as the current run's output.
    retire_previous_evidence_report
  fi
  if [ ! -f .loop/fleet-worker ] && ! fleet_inflight && [ "$identity_mode" = "fresh" ]; then
    # (baseline-verify.log: a stale one would let evidence report a red->green
    #  flip this run never measured — the FRESH branch rewrites it anyway)
    rm -f .loop/reports/decision.html .loop/reports/evidence.html \
          .loop/supervisor-guidance.md .loop/last-verify.log .loop/req-verdicts \
          .loop/verify-flake.log .loop/baseline-verify.log
  fi

  # ---- orchestration routing (the single entry point decides here) ----
  # A fleet worker (marker file) and `run --single` always take the classic
  # in-place loop. An active fleet queue resumes its orchestration. Otherwise a
  # FRESH run may decompose the approved master contract into parallel tasks
  # (FLEET_DECOMPOSE=0 in fleet.config.sh opts a project out entirely).
  # --single/--fresh must never run BESIDE an in-flight orchestration: a parent
  # loop and a live fleet over the same repo is exactly the split-brain the
  # singleton supervisor exists to prevent — refuse loudly instead.
  if [ ! -f .loop/fleet-worker ] && { [ "$single" = 1 ] || [ "$force_fresh" = 1 ]; }; then
    if fleet_inflight; then
      die "an orchestration is in flight — --single/--fresh cannot start beside it; resume it with ./loop.sh run, or inspect/clean the fleet first (./loop.sh fleet status)"
    fi
  fi
  if [ ! -f .loop/fleet-worker ] && [ "$single" != 1 ]; then
    if fleet_inflight; then
      # an orchestration is in flight (or crashed before its gate): resume it —
      # with an already-drained queue this goes straight to the integration gate.
      # A PARKED pre-start queue (manual adds only, nothing ever started) is NOT
      # in flight: it falls through so the contract still decomposes, and the
      # orchestration start dispatches the parked tasks alongside the planned ones.
      run_fleet_orchestration resume
    fi
    if [ "$(fcfg FLEET_DECOMPOSE 1)" != "0" ]; then
      local route_mode
      route_mode=$(decide_run_mode "$force_fresh" "$require_resume" "$prefer_resume")
      if [ "$route_mode" = "fresh" ]; then
        # --fresh restarts the LOOP fresh but still reuses an approved plan that
        # matches the contract; regenerating the plan is `./loop.sh decompose --force`
        if cmd_decompose_flow 0 1; then
          run_fleet_orchestration start
        fi
      fi
    fi
  fi

  # anything that reaches the in-place loop with queued fleet tasks left is the
  # PARKED case (--single, FLEET_DECOMPOSE=0, or a one-task plan): the classic
  # loop never claims them — say so instead of silently ignoring the queue
  if [ ! -f .loop/fleet-worker ] && [ -n "$(tasks_in new)" ]; then
    note "warning: $(tasks_in new | wc -l | tr -d ' ') queued fleet task(s) stay parked during this in-place run — dispatch them afterwards: ./loop.sh fleet run"
  fi

  # ---- continue an interrupted/failed run, or start a fresh one? ----
  local mode
  mode=$(decide_run_mode "$force_fresh" "$require_resume" "$prefer_resume")
  case "$mode" in refuse:*) die "${mode#refuse:}" ;; esac

  local i run_start_ref agent_failures gate_revise_count iter_revise_count resumes

  if [ "$mode" = "resume" ]; then
    # ================= RESUME: pick the run up where it left off =================
    CK_RUN_START_REF=$(ckpt_get RUN_START_REF)
    CK_RUN_ID=$(ckpt_get RUN_ID)
    valid_log_segment "$CK_RUN_ID" || CK_RUN_ID="$RUN_ID"
    RUN_ID="$CK_RUN_ID"
    CK_CONFIG_SB=$(config_hash_sans_budget)
    CK_MAXIT_START=$(ckpt_int MAX_ITERATIONS_AT_START "$MAX_ITERATIONS")
    CK_CREATED_AT=$(ckpt_get CREATED_AT)

    run_start_ref="$CK_RUN_START_REF"
    # the recorded review base must still be a real ancestor of HEAD; else the
    # gate diff would be nonsense. Falling back to HEAD is never weaker than a
    # fresh run (which resets the base to the interruption point anyway).
    if [ -z "$run_start_ref" ] \
       || ! git rev-parse --verify "${run_start_ref}^{commit}" >/dev/null 2>&1 \
       || ! git merge-base --is-ancestor "$run_start_ref" HEAD >/dev/null 2>&1; then
      note "resume: recorded base '$run_start_ref' is not an ancestor of HEAD — using HEAD as the review base"
      run_start_ref=$(git rev-parse HEAD)
      CK_RUN_START_REF="$run_start_ref"
    fi
    # Load the task anchor exactly once before the resumed implementer runs.
    # Invalid/legacy content is an explicit fallback (NO_OP disabled), not a
    # moving ref that is re-resolved at the gate.
    pin_task_start_ref || true

    i=$(ckpt_int ITERATION 1)
    agent_failures=$(ckpt_int AGENT_FAILURES 0)
    gate_revise_count=$(ckpt_int GATE_REVISE_COUNT 0)
    iter_revise_count=$(ckpt_int ITER_REVISE_COUNT 0)
    # restore the running cost from the freshest mirror so a cumulative
    # MAX_COST_USD is honored across the resume boundary
    TOTAL_COST=$(cat .loop/cost-total 2>/dev/null || true)
    [ -n "$TOTAL_COST" ] || TOTAL_COST=$(ckpt_get TOTAL_COST)
    [ -n "$TOTAL_COST" ] || TOTAL_COST=0

    resumes=$(ckpt_int RESUME_COUNT 0)
    resumes=$((resumes + 1))
    # what the run looked like when it died: INTERRUPTED = the trap ran;
    # RUNNING = it died without even the trap (crash/SIGKILL/power loss);
    # STALLED/BLOCKED = a human explicitly resumed a terminal failure
    local prev_state
    prev_state=$(cat .loop/state 2>/dev/null || echo "")
    # split-brain guard: RUNNING may mean a LIVE loop, not a crashed one — a
    # second `run` here would steal its checkpoint and journal a false ABEND.
    # single_loop_alive is the robust probe (pid + ps-or-heartbeat, never ps
    # alone); a genuinely dead process fails it and resumes normally.
    # Known-accepted gap: TWO simultaneous resumes of an INTERRUPTED/dead run
    # both pass this guard (no process is alive to probe; there is no single-
    # loop lock). Deliberate: the harness assumes one human operator per repo,
    # and MAX_RESUMES plus the iteration budget bound the damage of a race.
    if [ "$prev_state" = "RUNNING" ] && single_loop_alive; then
      die "a run is already active in this repo (pid $(cat .loop/run.pid 2>/dev/null)) — wait for it or stop it (Ctrl-C / kill $(cat .loop/run.pid 2>/dev/null)) before running again"
    fi
    echo RUNNING > .loop/state
    # liveness pidfile the instant state flips (see the FRESH branch below for
    # the full rationale): covers the resume recovery window too. Ordered AFTER
    # the RUNNING-guard above so we never read our own fresh pid as a rival run;
    # run.pid precedes run_beat; a finish() below (MAX_RESUMES) removes it.
    echo $$ > .loop/run.pid
    run_beat
    # crash-loop backstop: too many resumes without the run ever moving forward
    # (a resumed run that completes an iteration resets this to 0 — see below)
    if [ "$resumes" -ge "$MAX_RESUMES" ]; then
      finish BLOCKED "resumed $resumes times without making progress — needs human review (./loop.sh run --fresh to restart from iteration 1)"
    fi
    # persist the incremented resume count BEFORE the recovery commit, so a crash
    # inside the recovery window still advances the backstop
    ckpt_write "$i" "$agent_failures" "$gate_revise_count" "$iter_revise_count" "$resumes"

    # recover any uncommitted edits from the interrupted iteration so the reviewer
    # SEES them (a fresh run would bury them in a baseline snapshot). The resumed
    # iteration re-runs idempotently on top.
    if [ -n "$(git status --porcelain)" ]; then
      note "resume: committing uncommitted work from the interrupted iteration $i"
      git add -A
      git commit -q -m "loop: iter $i — recovered uncommitted work on resume"
    fi

    echo 0 > .loop/last-cost   # the resume event itself costs nothing (match RUN_START's cost_usd=0)
    echo 0 > .loop/last-turns
    if [ "$prev_state" = "RUNNING" ]; then
      # not even the interrupt trap ran: the previous process died silently.
      # Journal it here — the death itself had no chance to.
      journal_append "run" "RUN_ABEND" "previous process died without a terminal state or interrupt trap (crash/SIGKILL/power loss)"
    fi
    # explicit resume of a terminal failure gets a FRESH stop-heuristic window
    # across ALL the streaks that produce STALLED/BLOCKED — stagnation, futile
    # verdicts, repeat-fail fingerprints, the review-rejection counters, and
    # the agent-failure streak. The human decided the context changed; granting
    # a fresh window to one streak but not another would make e.g. a repeat-fail
    # BLOCKED re-block on the very first identical failure even after a
    # legitimate fix (or an agent-failure BLOCKED re-block on ONE new transient
    # error instead of two). Bounded: iteration budget is preserved and
    # MAX_RESUMES backstops resume loops. Crash/interrupt resumes
    # (RUNNING/INTERRUPTED) are the SAME logical run and keep every counter.
    local stag_reset=""
    case "$prev_state" in
      STALLED|BLOCKED)
        rm -f .loop/stagnation-count .loop/futile-count .loop/fail-fingerprints
        gate_revise_count=0
        iter_revise_count=0
        agent_failures=0
        stag_reset="; stop-heuristic windows reset" ;;
    esac
    journal_append "run" "RUN_RESUME" "resuming at iteration $i from $run_start_ref (resume #$resumes; previous state: ${prev_state:-unknown}$stag_reset)"
    if [ -n "$resume_note" ]; then
      # the human's steer rides the existing supervisor-guidance channel — the
      # next /loop-iterate already treats that file as THE human decision
      {
        echo "# Human guidance on resume ($(utcnow))"
        echo
        printf '%s\n' "$resume_note"
      } > .loop/supervisor-guidance.md
      journal_append "run" "RUN_NUDGE" "$resume_note"
    elif [ "$prev_state" = "STALLED" ]; then
      note "resuming a STALLED run with unchanged context — consider: ./loop.sh resume --note '<what to try differently>'"
    fi
    note "resuming interrupted run at iteration $i/$MAX_ITERATIONS (resume #$resumes, spent: \$$TOTAL_COST)"
    note "models: implement=$MODEL_IMPLEMENT review=$MODEL_REVIEW plan=$MODEL_PLAN evidence=$MODEL_EVIDENCE stop-eval=$MODEL_STOP_EVAL"
    note "effort: $(resolve_effort | grep . || echo 'cli-default') (all in-loop calls)"
  else
    # ================= FRESH: start a new run at iteration 1 =================
    if [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ]; then
      note "warning: .loop/state is RUNNING but no live loop process found (stale after a crash) — starting fresh"
    fi
    rm -f .loop/run-checkpoint

    if [ -n "$(git status --porcelain)" ]; then
      note "working tree dirty — creating pre-run snapshot commit"
      git add -A
      git commit -q -m "loop: pre-run snapshot"
    fi

    # baseline verification: run the gate once so tool side-effects (lockfiles,
    # caches created by the project's own commands) land in the BASELINE snapshot
    # and are never attributed to the agent's diff by the reviewer.
    # Each command's status is also captured to .loop/baseline-verify.log — the
    # run's red->green record (same [PASS]/[FAIL] grammar as last-verify.log):
    # a command that FAILS here and passes at the end demonstrably discriminates,
    # and /loop-evidence reports that baseline-vs-final flip per command.
    note "baseline: running verification once (tool side-effects -> baseline snapshot)"
    local _cmd _rc _red=0 _green=0
    : > .loop/baseline-verify.log
    for _cmd in "${VERIFY_COMMANDS[@]}"; do
      echo "\$ $_cmd" >> .loop/baseline-verify.log
      if /bin/sh -c "$_cmd" >/dev/null 2>&1; then
        echo "[PASS] $_cmd" >> .loop/baseline-verify.log
        _green=$((_green + 1))
      else
        _rc=$?
        echo "[FAIL] $_cmd (exit $_rc)" >> .loop/baseline-verify.log
        _red=$((_red + 1))
      fi
    done
    note "baseline verify: red=$_red green=$_green (per-command: .loop/baseline-verify.log)"
    commit_if_changes "loop: baseline verify snapshot"

    run_start_ref=$(git rev-parse HEAD)
    record_task_start_ref "$run_start_ref"
    pin_task_start_ref || true
    rm -f .loop/agent-state .loop/stagnation-count .loop/fail-fingerprints .loop/last-cost \
          .loop/futile-count .loop/review-feedback.md .loop/review-diff.patch \
          .loop/met-count .loop/stop-nudge.md .loop/split-nudge.md .loop/last-turns \
          .loop/context-nudge.md .loop/ac-seen
    # seed the run-scoped AC-id ledger from the checklist as it stands at run
    # start: rows present NOW are recorded before iteration 1 can touch them,
    # so a row deleted in the very first iteration is still caught by the
    # evaluator's monotonicity check (6.6); the evaluator keeps accumulating
    # ids from there. NOT a stop heuristic — an explicit resume keeps it.
    awk -F'|' '/^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
        id=$2; gsub(/^[ \t]+/,"",id); gsub(/[ \t]+$/,"",id); print id
      }' .loop/docs/acceptance-checklist.md 2>/dev/null | sort -u > .loop/ac-seen || true
    [ -s .loop/ac-seen ] || rm -f .loop/ac-seen
    TOTAL_COST=0
    echo 0 > .loop/cost-total          # display mirror; the in-memory total is authoritative
    echo RUNNING > .loop/state
    # single-loop liveness pidfile — seed it the INSTANT state flips to RUNNING,
    # BEFORE the slow iteration-0 planning call below (a real model call lasting
    # seconds→minutes). Every split-brain guard keys on
    # state==RUNNING && single_loop_alive; a pidfile written only after the plan
    # call would leave the whole iter-0 window RUNNING-yet-invisible, so a
    # concurrent start/run would archive+reset this run's live memory (and the
    # watchdog's run_beat — gated on run.pid==$$ — would not even refresh the
    # heartbeat during that call). Single-loop path only (the orchestration
    # branches above never return); run.pid must precede run_beat, and a die in
    # planning leaves a dead pid that single_loop_alive treats as stale (self-
    # correcting). finish()/on_interrupt remove it.
    echo $$ > .loop/run.pid
    run_beat
    journal_append "run" "RUN_START" "baseline $run_start_ref"
    # journaled AFTER RUN_START on purpose: per-segment aggregation treats
    # RUN_START as the segment boundary, so this row must belong to THIS run
    journal_append "run" "BASELINE_VERIFY" "red=$_red green=$_green (per-command: .loop/baseline-verify.log)"
    note "models: implement=$MODEL_IMPLEMENT review=$MODEL_REVIEW plan=$MODEL_PLAN evidence=$MODEL_EVIDENCE stop-eval=$MODEL_STOP_EVAL"
    note "effort: $(resolve_effort | grep . || echo 'cli-default') (all in-loop calls)"

    # iteration 0: implementation plan (mutable by design; the contract is not)
    if [ ! -s .loop/docs/implementation-plan.md ] || grep -q '<!-- TEMPLATE -->' .loop/docs/implementation-plan.md; then
      note "iteration 0: generating implementation plan (/loop-plan, $MODEL_PLAN)"
      run_claude "iter-0-plan" "/loop-plan" "$MODEL_PLAN" full PLAN || die_next "planning agent failed${AGENT_FAIL_DIAG:+ — $AGENT_FAIL_DIAG} (evidence: .loop/logs/failed/)" "fix the cause, then ./loop.sh run"
      commit_if_changes "loop: iter 0 — implementation plan"
      journal_append "0" "PLAN" "implementation plan generated"
    fi

    CK_RUN_START_REF="$run_start_ref"
    CK_RUN_ID="$RUN_ID"
    CK_CONFIG_SB=$(config_hash_sans_budget)
    CK_MAXIT_START="$MAX_ITERATIONS"
    CK_CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '')
    i=1; agent_failures=0; gate_revise_count=0; iter_revise_count=0; resumes=0
    ckpt_write 1 0 0 0 0
  fi

  # requirements ledger: deterministic bootstrap/repair (one row per contract
  # REQ heading) so every iteration, review and the evaluator's gate check see
  # the same requirement-satisfaction memory. Idempotent; covers fresh + resume.
  bootstrap_requirements_ledger
  commit_if_changes "loop: requirements ledger bootstrap"

  # (the single-loop liveness pidfile + heartbeat were seeded the instant state
  # flipped to RUNNING, in each branch above — see the comments there — so the
  # whole RUNNING window is covered, including iteration-0 planning.)
  run_iteration_loop "$i" "$run_start_ref" "$agent_failures" "$gate_revise_count" "$iter_revise_count" "$resumes"
}

run_iteration_loop() { # $1 i $2 run_start_ref $3 agent_failures $4 gate_revise $5 iter_revise $6 resumes
  local i="$1" run_start_ref="$2" agent_failures="$3" gate_revise_count="$4" iter_revise_count="$5" resumes="$6"
  local state_line state reason pre_ref review_base review_scope run_wall_start=$SECONDS
  while [ "$i" -le "$MAX_ITERATIONS" ]; do
    run_beat   # covers the between-agent-call bookkeeping (git commits, parsing)
    if budget_exceeded; then
      finish BUDGET_EXCEEDED "spent \$$TOTAL_COST >= cap \$$MAX_COST_USD before iteration $i"
    fi
    if [ -n "${MAX_RUN_SECONDS:-}" ] && [ $((SECONDS - run_wall_start)) -ge "$MAX_RUN_SECONDS" ]; then
      finish BUDGET_EXCEEDED "wall clock $((SECONDS - run_wall_start))s >= MAX_RUN_SECONDS=${MAX_RUN_SECONDS} before iteration $i"
    fi
    check_harness "before iteration $i"
    # durable checkpoint: records the iteration about to run + the current counters,
    # so a crash/kill here resumes at EXACTLY this point (idempotent to re-run).
    ckpt_write "$i" "$agent_failures" "$gate_revise_count" "$iter_revise_count" "$resumes"

    note "── iteration $i/$MAX_ITERATIONS (spent: \$$TOTAL_COST) ──"
    pre_ref=$(git rev-parse HEAD)
    rm -f .loop/agent-state
    write_split_nudge "$i"   # fleet-worker budget signal (advisory; no-op otherwise)
    REVIEW_VERDICT=""   # per-iteration; a stale verdict must not gate the forced-gate check

    # 1. IMPLEMENT (fresh context; reads contract/plan/progress + reviewer feedback)
    if run_claude "iter-$i" "/loop-iterate$(html_arg)" "$MODEL_IMPLEMENT" full IMPLEMENT; then
      agent_failures=0
    else
      agent_failures=$((agent_failures + 1))
      journal_append "$i" "AGENT_ERROR" "agent call failed ($agent_failures consecutive)${AGENT_FAIL_DIAG:+ — $AGENT_FAIL_DIAG}"
      if [ "$agent_failures" -ge 2 ]; then
        # A rate/usage limit is a transient API failure, not a loop problem: steer
        # the human to wait-and-retry (the api-stall box) instead of the sign-off /
        # contract box the generic BLOCKED stop would show. Lowercase via tr (not
        # ${x,,}) so the classifier works on bash 3.2 (macOS default).
        local _diaglc; _diaglc=$(printf '%s' "${AGENT_FAIL_DIAG:-}" | tr '[:upper:]' '[:lower:]')
        case "$_diaglc" in
          *"rate limit"*|*"rate_limit"*|*overloaded*|*"usage limit"*|*429*|*quota*|*"too many requests"*)
            NEXT_ACTION_CTX=api-stall
            finish BLOCKED "agent call kept failing — likely a rate/usage limit, not your loop${AGENT_FAIL_DIAG:+ — last error: $AGENT_FAIL_DIAG} (evidence: .loop/logs/failed/)" ;;
          *)
            finish BLOCKED "agent failed twice in a row${AGENT_FAIL_DIAG:+ — last error: $AGENT_FAIL_DIAG} (evidence: .loop/logs/failed/)" ;;
        esac
      fi
      i=$((i + 1))
      continue
    fi

    # 2. EXTERNAL EVALUATION (deterministic, model-free). The harness is
    # re-checked first so an evaluator tampered with during implementation
    # is never executed; the approved hash comes from memory, not disk.
    check_harness "during iteration $i (implementation)"
    if ! state_line=$("$evaluator" --pre-ref "$pre_ref" --approved-hash "$RUN_CONTRACT_HASH"); then
      state_line="BLOCKED external evaluator crashed"
    fi
    # The normal evaluator validates but never writes the observations
    # manifest; its VERIFY_COMMANDS are arbitrary project shell, so any
    # manifest change across this call is tampering, not a stamp. Catch it
    # HERE — the stop-eval/gate paths re-pin after their trusted --preflight
    # stamper, and a check only at the next iteration head would let a
    # MET/candidate path launder the replaced manifest through that re-pin.
    observation_manifest_intact \
      || finish RISK_REQUIRES_APPROVAL "observations-manifest changed during iteration $i's verification commands — only the evaluator's preflight stamper may write it; review the change, restore the manifest, or start a new approved task"
    state=${state_line%% *}
    reason=${state_line#* }
    if [ "$reason" = "$state_line" ]; then reason=""; fi

    commit_if_changes "loop: iter $i — $state"
    journal_append "$i" "$state" "$reason"
    # opt-in VERIFY_RETRIES left evidence of a red-then-green rerun: journal it
    # so a flaky gate is visible in the audit trail, never silently absorbed
    if [ -f .loop/verify-flake.log ]; then
      journal_append "$i" "VERIFY_FLAKE" "verify failed then passed on a full rerun — suspected environment flake: $(grep -m1 '^\[FAIL\]' .loop/verify-flake.log | cut -c1-160)"
    fi
    # this iteration produced an evaluated result: the (possibly resumed) process
    # is making forward progress, so clear the crash-loop backstop counter — and
    # persist the cleared value NOW. Waiting for the next iteration's start
    # checkpoint would lose the reset to any interrupt during the review/
    # stop-eval/gate calls below (long model-call windows), so repeated benign
    # interrupts there would falsely accumulate toward MAX_RESUMES.
    resumes=0
    ckpt_write "$i" "$agent_failures" "$gate_revise_count" "$iter_revise_count" "$resumes"
    note "iteration $i -> $state${reason:+ ($reason)} [\$$(cat .loop/last-cost 2>/dev/null || echo 0), $(cat .loop/last-turns 2>/dev/null || echo 0) turns]"
    # runaway-context check against THIS iteration's implement call (last-turns
    # still holds it here — review/stop-eval calls below overwrite the file)
    write_turns_nudge "$i"

    case "$state" in
      SUCCESS_CANDIDATE)
        run_success_gate "$i" "$run_start_ref" "$pre_ref" 0
        ;;
      CONTINUE)
        # 3. REVIEW every implementation (maker-checker; feedback drives next
        # iteration). Interim rejections have their own counter: they never
        # count against the success-gate MAX_REVISIONS budget.
        # Every Nth review — or any unusually large iteration diff — widens its
        # scope from this iteration's diff to the WHOLE run: per-diff review is
        # structurally blind to cross-iteration erosion (duplicated logic, dead
        # code, contradictory approaches), which accumulates while each diff
        # looks locally fine. Same single review call, wider base.
        if [ "$REVIEW_MODE" = "always" ]; then
          review_base="$pre_ref" review_scope="iter"
          if { [ "$HOLISTIC_EVERY_N" -gt 0 ] && [ $((i % HOLISTIC_EVERY_N)) -eq 0 ]; } \
             || { [ "$HOLISTIC_TRIGGER_LINES" -gt 0 ] \
                  && [ "$(iter_diff_lines "$pre_ref")" -ge "$HOLISTIC_TRIGGER_LINES" ]; }; then
            review_base="$run_start_ref" review_scope="run"
            note "interim review widened to the whole run (erosion/coherence audit)"
          fi
          run_review "$i" "$review_base" interim "$review_scope"
          if [ "$REVIEW_VERDICT" = "REVISE" ]; then
            iter_revise_count=$((iter_revise_count + 1))
            if [ "$iter_revise_count" -ge "$MAX_REVISIONS" ]; then
              finish BLOCKED "reviewer rejected $iter_revise_count consecutive iterations — review churn; needs human review (.loop/review-feedback.md)"
            fi
          elif [ "$REVIEW_VERDICT" = "APPROVE" ]; then
            iter_revise_count=0
          fi
        fi
        # 4. STOP-EVAL (lightweight advisory model; can only stop, never approve)
        run_stop_eval "$i" "$pre_ref"
        # 5. FORCED GATE (backstop): the harness does not wait forever for the
        # agent to declare readiness. N consecutive MET verdicts that each
        # passed deterministic preflight force the success gate — the gate
        # reviewer, evidence step and final deterministic re-check still decide;
        # the stop evaluator never grants success by itself. Never force while THIS
        # iteration's interim review rejected (known must-fix items are
        # outstanding — the gate would only burn budget) or errored (a
        # transient reviewer failure is tolerated mid-loop, but inside the
        # gate it would escalate to a terminal BLOCKED).
        if [ "$MET_FORCE_N" -gt 0 ] && [ "${STOP_EVAL_MET_STREAK:-0}" -ge "$MET_FORCE_N" ] \
           && [ "${REVIEW_VERDICT:-}" != "REVISE" ] && [ "${REVIEW_VERDICT:-}" != "ERROR" ] \
           && [ -s .loop/last-verify.log ] && ! grep -q '^\[FAIL\]' .loop/last-verify.log; then
          note "stop evaluator reported MET ${STOP_EVAL_MET_STREAK}x with deterministic preflight green — forcing the success gate"
          journal_append "$i" "FORCED_GATE" "preflight-qualified MET x$STOP_EVAL_MET_STREAK — success gate forced (review + evidence still decide)"
          run_success_gate "$i" "$run_start_ref" "$pre_ref" 1
        fi
        ;;
      NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|RISK_REQUIRES_APPROVAL|BLOCKED|STALLED)
        # journal whether the iteration declared a decision/escalation page (D6 —
        # advisory; the markdown decision request remains canonical)
        record_html_decision "iter-$i" "$i"
        finish "$state" "$reason"
        ;;
      *)
        finish BLOCKED "evaluator returned unknown state: $state_line"
        ;;
    esac

    if budget_exceeded; then
      finish BUDGET_EXCEEDED "spent \$$TOTAL_COST >= cap \$$MAX_COST_USD after iteration $i"
    fi
    i=$((i + 1))
  done

  # budget exhausted: record the NEXT iteration (past the cap) so `resume` can tell
  # an exhausted run apart from a mid-run one — raising MAX_ITERATIONS + re-approving
  # then continues from here rather than re-running the last iteration.
  ckpt_write "$i" "$agent_failures" "$gate_revise_count" "$iter_revise_count" "$resumes"
  finish BUDGET_EXCEEDED "hit MAX_ITERATIONS=$MAX_ITERATIONS without reaching the goal"
}

cmd_resume() { # resume | resume --list | resume <id> [--auto]
  case "${1:-}" in
    "")      cmd_run --require-resume ;;          # unchanged no-arg meaning (see decide_run_mode)
    --list)  cmd_resume_list ;;
    --auto)  fdie "resume --auto needs a task id: ./loop.sh resume <id> --auto" ;;
    -*)      cmd_run --require-resume "$@" ;;     # unknown flags keep dying in cmd_run, as today
    *)       cmd_resume_task "$@" ;;
  esac
}

signoff_human_rows() { # flip every not-yet-verified 'human' acceptance row to
  # verified with a sign-off note. The HUMAN is certifying (they answered the [y]
  # confirm) — this is their call, exactly the manual "mark the row verified" the
  # decision request describes, NOT the model self-grading. cmd/run rows are still
  # re-verified by the evaluator, and the independent reviewer still certifies, on
  # the closing resume — so the maker/checker boundary holds. Echoes the count.
  local f=.loop/docs/acceptance-checklist.md ts tmp n
  [ -f "$f" ] || { note "no acceptance checklist to sign off ($f)"; return 1; }
  ts=$(utcnow)
  tmp="$f.tmp.$$"
  # POSIX/BSD-awk safe: no gsub backslash grammar, ASCII replacement, [[:space:]] ok.
  n=$(awk -v ts="$ts" -v TMP="$tmp" '
    /^\| *AC-[0-9]+ / && /\| *human *\|/ && $0 !~ /\| *human *\| *verified *\|/ {
      sub(/\| *human *\| *[A-Za-z-]+ *\|/, "| human | verified |")
      sub(/ *\|[[:space:]]*$/, " - human sign-off (refine) " ts " |")
      c++
    }
    { print > TMP }
    END { print c+0 }
  ' "$f") || { rm -f "$tmp"; note "sign-off failed (awk error)"; return 1; }
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    mv -f "$tmp" "$f"
    journal_append "refine" "HUMAN_SIGNOFF" "$n human acceptance row(s) signed off via refine confirm"
    note "signed off $n human acceptance row(s) as verified (evidence noted in the checklist)."
    return 0
  fi
  rm -f "$tmp"
  note "no pending human rows to sign off (already verified?)."
  return 0
}

cmd_refine() { # ./loop.sh refine ['<opening note>'] — interactive design-gate session.
  # A run stops BLOCKED at a HUMAN sign-off gate (a 'human' acceptance row it cannot
  # self-close). refine hands the human a LIVE Claude Code session to adjust the
  # reversible, within-contract knobs and preview, instead of paying a full headless
  # iteration per tweak. It is NOT a shortcut to SUCCESS: the closing `resume` re-runs
  # the evaluator (cmd/run rows) and the independent success-gate reviewer. The
  # contract is immutable here — a REQUIRED-behavior change is /loop-contract's job.
  need_project
  need_awk
  need_claude
  local st note_arg="${1:-}" rc=0 ans=""
  st=$(cat .loop/state 2>/dev/null || echo "")
  if [ "$st" != "BLOCKED" ]; then
    note "refine is for a run paused at a human sign-off gate (state BLOCKED); current state: ${st:-<none>}."
    case "$st" in
      RUNNING)          note "a run is in flight — steer it with Ctrl-C, then: ./loop.sh resume --note '<...>'." ;;
      NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|RISK_REQUIRES_APPROVAL|PENDING_APPROVAL)
                        note "this run needs a human DECISION — read .loop/docs/decision-requests.md, then: ./loop.sh approve." ;;
      SUCCESS|NO_OP)    note "the last run already completed ($st) — nothing to refine." ;;
      *)                note "nothing to refine — run ./loop.sh status to see where things stand." ;;
    esac
    exit 2
  fi
  if [ ! -t 0 ]; then
    note "refine needs an interactive terminal (no TTY). Steer headlessly instead:"
    note "  ./loop.sh resume --note '<what to change>'"
    exit 2
  fi
  local pmode="${LOOP_REFINE_PERMISSION_MODE:-auto}"
  note "launching interactive refine session (adjust reversible within-contract knobs, preview live; permission-mode=$pmode)"
  note "the contract is IMMUTABLE here — to change a REQUIRED behavior, end the session and use /loop-contract."
  # Swallow INT/TERM for THIS shell during the session so Ctrl-C ends the Claude REPL
  # and returns to the sign-off prompt below (the human's "Ctrl-C then y"), instead of
  # killing loop.sh before it can offer to re-certify. The Claude child (same process
  # group) still receives its own SIGINT and handles it. Restored right after.
  trap ':' INT TERM
  # shellcheck disable=SC2046  # effort_opt word-splits into '--effort <level>' or nothing on purpose
  "$CLAUDE_CMD" --model "$(get_model MODEL_CONTRACT opus)" $(effort_opt CONTRACT) --permission-mode "$pmode" \
    "/loop-refine ${note_arg}" || rc=$?
  trap - INT TERM
  journal_append "refine" "REFINE_SESSION" "interactive refine session ended (rc=$rc)"
  echo
  printf 'loop: satisfied? sign off the human acceptance row(s) and re-certify now?\n'
  printf 'loop:   [y] sign off + ./loop.sh resume   [e] edit the rows yourself   [N] not yet / discard\n'
  printf 'loop: choice [y/e/N] '
  read -r ans || ans="n"
  case "$ans" in
    y|Y)
      signoff_human_rows
      note "re-certifying via ./loop.sh resume (evaluator re-checks cmd/run rows; independent reviewer certifies) ..."
      cmd_resume
      ;;
    e|E)
      note "sign off the 'human' row(s) as 'verified' in .loop/docs/acceptance-checklist.md, then: ./loop.sh resume"
      print_next_actions refine-exit
      ;;
    *)
      note "nothing signed off."
      print_next_actions refine-exit
      ;;
  esac
}

cmd_resume_task() { # $1 id [--auto] — flip the task runnable, then actually run it
  need_project
  ensure_fleet_dirs
  local id="" auto="" a others
  for a in "$@"; do
    case "$a" in
      --auto) auto=1 ;;
      --note|--note=*)
        # without this, the note text would silently become the task id
        fdie "--note applies to the root-run resume only (./loop.sh resume --note '<guidance>'); steer a task by answering its decision request in its worktree" ;;
      *) id="$a" ;;
    esac
  done
  # split-brain refusal BEFORE any state flip (same probe as cmd_fleet_run): a
  # live root loop and a fleet dispatch must never share the repo
  if [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ] && single_loop_alive; then
    fdie "a single-loop run is active (pid $(cat .loop/run.pid 2>/dev/null)) — a root loop and the fleet must not run together; wait for it or stop it (Ctrl-C / kill $(cat .loop/run.pid 2>/dev/null))"
  fi
  # orphan detection BEFORE the flip so the error is precise
  if [ -z "$(task_qdir "$id")" ] && [ ! -f "$RUNS_DIR/$id.env" ]; then
    if [ -d "$(wt_path "$id")" ] || git rev-parse -q --verify "loop/$id" >/dev/null 2>&1; then
      fdie "'$id' has a worktree/branch but no queue entry (orphan) — gc: ./loop.sh fleet clean --orphans"
    fi
    fdie "unknown session id '$id' — list sessions: ./loop.sh resume --list"
  fi
  fleet_resume_flip "$id"                       # fdies on every non-resumable class
  if supervisor_alive; then                     # live dispatcher: the flip is enough
    fnote "[$id] a live dispatcher holds the lock (pid $(supervisor_pid)) — it relaunches this on its next tick (watch: ./loop.sh fleet status)"
    return 0
  fi
  if [ "$(cat .loop/state 2>/dev/null)" = "FLEET_RUNNING" ]; then
    # crashed/interrupted orchestration: resume the WHOLE orchestration — a
    # lone-task drain would skip the integration gate (individual task success
    # is NEVER enough) and leave state=FLEET_RUNNING lying
    fnote "[$id] an orchestration is in flight with no live supervisor — resuming the WHOLE orchestration (queue dispatch + integration gate)"
    journal "$id" RESUME_DISPATCH "orchestration resume via cmd_run"
    cmd_run                                     # routes to run_fleet_orchestration resume; never returns
    # shellcheck disable=SC2317  # defensive: unreachable while cmd_run never returns here
    return 0
  fi
  # standalone fleet: inline drain dispatcher (one dispatcher per repo — tick has
  # no per-task filter, and a filter would strand adopted-but-never-launched siblings)
  others=$(( $(tasks_in new | wc -l) + $(tasks_in claimed | wc -l) - 1 ))
  fnote "note: tasks needing contract approval wait in PENDING_APPROVAL — approve from another terminal: ./loop.sh fleet approve <id>"
  [ "$others" -gt 0 ] && fnote "note: $others other queued/claimed task(s) will also be dispatched (one dispatcher per repo)"
  journal "$id" RESUME_DISPATCH "inline drain dispatcher"
  cmd_fleet_run --drain ${auto:+--auto}
  # post-drain honesty: the exit code reflects what happened to THIS task, never
  # merely that the drain loop ended. (The drain's merge-blocked / approval /
  # stall watchdogs exit 3/3/4 directly inside cmd_fleet_run and never return.)
  local qd res wt
  qd=$(task_qdir "$id")
  case "$qd" in
    "done")
      fnote "[$id] done"
      exit 0 ;;
    new)
      fnote "[$id] handed off to a successor supervisor — still queued"
      exit 0 ;;
    failed|claimed)
      res=$(renv_get "$id" RESULT "")
      [ -n "$res" ] || res=$(renv_get "$id" PHASE "")
      wt=$(renv_get "$id" WT "")
      case "$res" in
        NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|NEEDS_HUMAN|RISK_REQUIRES_APPROVAL)
          fnote "[$id] stopped for a human decision ($res) — read $wt/.loop/docs/decision-requests.md, decide, (cd $wt && ./loop.sh approve), then ./loop.sh resume $id"
          exit 3 ;;
        PENDING_APPROVAL)
          fnote "[$id] waits for contract approval — ./loop.sh fleet approve $id, then ./loop.sh resume $id"
          exit 3 ;;
        BUDGET_EXCEEDED)
          fnote "[$id] stopped on budget ($res) — raise the budget in $wt/loop.config.sh, re-approve there, then ./loop.sh resume $id"
          exit 5 ;;
        *)
          fnote "[$id] did not finish ($res) — inspect: ./loop.sh fleet logs $id"
          exit 4 ;;
      esac ;;
    *)
      fnote "[$id] no longer in the queue (cleaned mid-drain?) — nothing left to report"
      exit 0 ;;
  esac
}

cmd_resume_list() { # every session in this repo and whether/how it resumes
  need_project
  local st ck=0 root_verdict id qd phase verdict
  st=$(cat .loop/state 2>/dev/null || echo "")
  [ -f .loop/run-checkpoint ] && ck=1
  # lightweight state mapping, deliberately NOT decide_run_mode (which needs
  # verify_approval + load_config and can die) — this listing must never die
  case "$st" in
    FLEET_RUNNING)       root_verdict="orchestration — resume: ./loop.sh run" ;;
    RUNNING|INTERRUPTED) if [ "$ck" = 1 ]; then root_verdict="yes — ./loop.sh run (auto-resumes)"; else root_verdict="no"; fi ;;
    BLOCKED|STALLED|BUDGET_EXCEEDED)
                         if [ "$ck" = 1 ]; then root_verdict="yes — ./loop.sh resume"; else root_verdict="no"; fi ;;
    NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|RISK_REQUIRES_APPROVAL|PENDING_APPROVAL)
                         root_verdict="after deciding — ./loop.sh approve && ./loop.sh run" ;;
    *)                   root_verdict="no" ;;
  esac
  printf '%-38s %-8s %-24s %s\n' "SESSION" "QUEUE" "PHASE" "RESUMABLE"
  printf '%-38s %-8s %-24s %s\n' "(root)" "-" "${st:-(none)}" "$root_verdict"
  for id in $(all_task_ids); do
    qd=$(task_qdir "$id")
    phase=$(renv_get "$id" PHASE queued)
    [ "$qd" != "failed" ] || phase=$(renv_get "$id" RESULT "$phase")
    case "$(resume_class "$id")" in
      requeue)                   verdict="yes (re-queues fresh) — ./loop.sh resume $id" ;;
      relaunch|relaunch-claimed) verdict="yes — ./loop.sh resume $id" ;;
      stale-running)             verdict="yes — ./loop.sh resume $id (process dead)"; phase="${phase}†" ;;
      decision)                  verdict="answer in worktree first — ./loop.sh resume $id prints the steps" ;;
      merge-decision)            verdict="no — ./loop.sh fleet merge $id" ;;
      approval)                  verdict="no — ./loop.sh fleet approve $id" ;;
      queued)                    verdict="queued (runs when a slot frees)" ;;
      busy)                      verdict="running/in-progress" ;;
      *)                         verdict="no" ;;   # done | superseded
    esac
    printf '%-38s %-8s %-24s %s\n' "$id" "${qd:--}" "$phase" "$verdict"
  done
  echo
  if supervisor_alive; then
    echo "supervisor: running (pid $(supervisor_pid))"
  else
    echo "supervisor: not running   (start: ./loop.sh fleet run)"
  fi
}

cmd_watch() {
  need_kit
  local interval=900 max_runs=10 runs=0 rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) interval="${2:?}"; shift 2 ;;
      --max-runs) max_runs="${2:?}"; shift 2 ;;
      *) die_next "unknown option for watch: $1" "see ./loop.sh -h" ;;
    esac
  done
  while [ "$runs" -lt "$max_runs" ]; do
    runs=$((runs + 1))
    note "watch: run $runs/$max_runs"
    rc=0
    "$SELF" run || rc=$?
    case "$rc" in
      0) note "watch: success — done"; exit 0 ;;
      3) note "watch: human decision required — stopping (retrying would burn budget)"; exit 3 ;;
      2) exit 2 ;;
      *) note "watch: rc=$rc — retrying in ${interval}s"; sleep "$interval" ;;
    esac
  done
  note "watch: max runs reached"
  exit 5
}

cmd_status() {
  need_kit
  local st="(none)" ap="no"
  if [ -f .loop/state ]; then st=$(cat .loop/state); fi
  if [ -f .loop/approved ]; then
    if [ "$(cat .loop/approved)" = "$(contract_hash)" ]; then ap="yes"; else ap="STALE — re-run ./loop.sh approve"; fi
  fi
  echo "state:    $st"
  echo "approved: $ap"
  # lifetime = sum over run segments of each segment's MAX total_usd. Max, not
  # last: the NEXT process's decompose/contract rows land between a finished
  # run's final row and the next RUN_START carrying a freshly-reset (smaller)
  # total — taking the last would clobber the finished run's whole total.
  # Within one process the total is monotonic, so max == that run's real total.
  local lifeline=""
  if [ -f .loop/journal.jsonl ]; then
    lifeline=$(awk '
      /"state": "RUN_START"/ { sum += seg; seg = 0; runs++ }
      { if (match($0, /"total_usd": [0-9.eE+-]+/)) { t = substr($0, RSTART+13, RLENGTH-13) + 0; if (t > seg) seg = t } }
      END { sum += seg; printf "$%.4f lifetime, %d runs", sum, runs }
    ' .loop/journal.jsonl)
  fi
  echo "cost:     \$$(cat .loop/cost-total 2>/dev/null || echo 0) (last run)${lifeline:+ / $lifeline}"
  echo "models:   implement=$(get_model MODEL_IMPLEMENT opus) review=$(get_model MODEL_REVIEW opus) stop-eval=$(get_model MODEL_STOP_EVAL haiku)"
  local _eo="" _r _v
  for _r in IMPLEMENT REVIEW PLAN CONTRACT EVIDENCE STOP_EVAL DECOMPOSE SUPERVISE; do
    _v=$(get_model "EFFORT_$_r" "")
    case "$_v" in low|medium|high|xhigh|max) _eo="$_eo $(printf '%s' "$_r" | tr '[:upper:]_' '[:lower:]-')=$_v" ;; esac
  done
  echo "effort:   $(resolve_effort | grep . || echo 'cli-default')${_eo:+ (overrides:${_eo})}"
  if [ -f .loop/journal.jsonl ]; then
    echo "journal:  $(wc -l < .loop/journal.jsonl | tr -d ' ') records (.loop/journal.jsonl)"
  fi
  # when the run is paused/non-done, a one-line pointer to the recovery command
  # (mirrors finish(); `./loop.sh report` shows the full NEXT ACTION box) so
  # `status` alone never leaves the user wondering what to run next.
  local hint=""
  case "$st" in
    BLOCKED)          hint="./loop.sh resume (sign off), ./loop.sh refine '<change>', or ./loop.sh resume --note '<change>'  — full guidance: ./loop.sh report" ;;
    STALLED)          hint="./loop.sh resume --note '<what to try differently>', or ./loop.sh run --fresh" ;;
    BUDGET_EXCEEDED)  hint="raise MAX_ITERATIONS/MAX_COST_USD in loop.config.sh, then ./loop.sh approve && ./loop.sh resume" ;;
    NEEDS_*|RISK_REQUIRES_APPROVAL|PENDING_APPROVAL) hint="decide (.loop/docs/decision-requests.md), then ./loop.sh approve && ./loop.sh run  — full guidance: ./loop.sh report" ;;
    INTERRUPTED)      hint="./loop.sh run   (resume where it left off)" ;;
  esac
  [ -n "$hint" ] && echo "next:     $hint"
  # orchestration/fleet state, when any task exists (same table as fleet status)
  if [ -d "$QUEUE_DIR" ] && [ -n "$(all_task_ids)" ]; then
    echo
    cmd_fleet_status
  fi
}

cmd_open() { # ./loop.sh open <file> — EXPLICIT open (the interactive contract session
  # calls this to show mockups/briefings). Unlike the automatic openers it does NOT
  # require a TTY: an agent's Bash tool calls have no controlling terminal even while
  # a human drives the session, so gating `open` on [ -t 0 ] would silently do
  # nothing. Suppressed only in fully-autonomous mode, where no human is watching.
  need_kit
  [ -n "${1:-}" ] || die "usage: ./loop.sh open <file.html>"
  if [ "$AUTO_MODE" = "1" ]; then
    note "auto mode — not opening a browser: $1"
    return 0
  fi
  open_file_now "$1"
}

cmd_report() {
  need_kit
  need_awk
  local want_html=1 open_pref=auto f html=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --text)    want_html=0 ;;
      --html)    want_html=1 ;;
      --open)    open_pref=yes ;;
      --no-open) open_pref=no ;;
      *) die "report: unknown option '$1' (use --text / --html / --open / --no-open)" ;;
    esac
    shift
  done
  # HTML view: the model authors self-contained pages into .loop/reports/ while it
  # already has a session open (evidence / escalation). `report` only OPENS the
  # freshest one — no model call, no converter here. With a human present it opens
  # the browser and returns; otherwise it falls through to the text dump below,
  # which stays the audit-friendly, headless-safe surface (--text forces it).
  if [ "$want_html" != 0 ] && [ "$open_pref" != no ]; then
    if [ -f .loop/reports/evidence.html ]; then
      html=.loop/reports/evidence.html
    else
      # newest .html; ls -t is the portable choice here (macOS find lacks -printf)
      # shellcheck disable=SC2012
      html=$(ls -t .loop/reports/*.html 2>/dev/null | head -1 || true)
    fi
  fi
  if [ -n "$html" ] && [ -t 0 ] && [ "$AUTO_MODE" != "1" ]; then
    note "opening HTML report (plain-text view: ./loop.sh report --text)"
    open_html "$html"
    return 0
  fi
  for f in evidence-report spec-drift-report assumptions decision-requests unknowns; do
    if [ -f ".loop/docs/$f.md" ] && ! grep -q '<!-- TEMPLATE -->' ".loop/docs/$f.md"; then
      echo "════════ .loop/docs/$f.md ════════"
      cat ".loop/docs/$f.md"
      echo
    fi
  done
  echo "════════ run summary ════════"
  if [ -f .loop/journal.jsonl ]; then
    # each journal line is one compact JSON object we wrote; jget() is the same
    # top-level scalar extractor as json_field, applied per line so free text in
    # "reason" (which may contain "state": ...-looking bytes) never confuses the scan
    awk '
      function skip_ws(s, i, n,   c) { while (i <= n) { c = substr(s, i, 1); if (c==" "||c=="\t"||c=="\n"||c=="\r") i++; else break } return i }
      function hex2dec(h,   i, c, d, r) { r = 0; h = tolower(h); for (i=1;i<=length(h);i++){ c=substr(h,i,1); d=index("0123456789abcdef",c)-1; if(d<0)d=0; r=r*16+d } return r }
      function utf8(code,   b1, b2, b3) { if (code<128) return sprintf("%c",code); else if (code<2048){ b1=192+int(code/64); b2=128+(code%64); return sprintf("%c%c",b1,b2) } else { b1=224+int(code/4096); b2=128+int((code/64)%64); b3=128+(code%64); return sprintf("%c%c%c",b1,b2,b3) } }
      function parse_string(s, i, n,   out, c, e, code) {
        i++; out = ""
        while (i <= n) {
          c = substr(s, i, 1)
          if (c == "\\") { i++; e = substr(s, i, 1)
            if (e=="n") out=out "\n"; else if (e=="t") out=out "\t"; else if (e=="r") out=out "\r"
            else if (e=="b") out=out "\b"; else if (e=="f") out=out "\f"; else if (e=="/") out=out "/"
            else if (e=="\"") out=out "\""; else if (e=="\\") out=out "\\"
            else if (e=="u") { code=hex2dec(substr(s,i+1,4)); out=out utf8(code); i+=4 } else out=out e
            i++
          } else if (c == "\"") { i++; break } else { out = out c; i++ }
        }
        RESULT_STR = out; return i
      }
      function skip_container(s, i, n,   c, depth, instr) {
        depth = 0; instr = 0
        while (i <= n) { c = substr(s, i, 1)
          if (instr) { if (c=="\\") { i+=2; continue } if (c=="\"") instr=0; i++; continue }
          if (c == "\"") { instr=1; i++; continue }
          if (c=="{"||c=="[") { depth++; i++; continue }
          if (c=="}"||c=="]") { depth--; i++; if (depth==0) return i; continue }
          i++
        }
        return i
      }
      function jget(data, want,   n, i, c, key, val, j, cc) {
        n = length(data); i = 1
        while (i <= n && substr(data, i, 1) != "{") i++
        if (i > n) return ""
        i++
        while (i <= n) {
          i = skip_ws(data, i, n); c = substr(data, i, 1)
          if (c == "}") return ""
          if (c != "\"") return ""
          i = parse_string(data, i, n); key = RESULT_STR
          i = skip_ws(data, i, n); if (substr(data, i, 1) != ":") return ""
          i++; i = skip_ws(data, i, n); c = substr(data, i, 1)
          if (c == "\"") { i = parse_string(data, i, n); val = RESULT_STR; if (key == want) return val }
          else if (c == "{" || c == "[") { i = skip_container(data, i, n); if (key == want) return "" }
          else { j = i; while (j <= n) { cc = substr(data, j, 1); if (cc==","||cc=="}"||cc=="]"||cc==" "||cc=="\t"||cc=="\n"||cc=="\r") break; j++ } val = substr(data, i, j-i); i = j; if (key == want) return val }
          i = skip_ws(data, i, n); c = substr(data, i, 1)
          if (c == ",") { i++; continue }
          return ""
        }
        return ""
      }
      { lines[NR] = $0 }
      END {
        total = NR; startidx = 1
        for (k = 1; k <= total; k++) if (jget(lines[k], "state") == "RUN_START") startidx = k
        iters = 0; reviews = 0; approve = 0; revise = 0; lasttotal = "0"; finalstate = ""; finalreason = ""
        c_impl = 0; c_fail = 0; c_rint = 0; c_rgate = 0; c_rerr = 0; c_stop = 0; c_plan = 0; c_evid = 0
        maxturns = 0; maxit = ""
        iset = " CONTINUE SUCCESS_CANDIDATE AGENT_ERROR NEEDS_SPEC_DECISION NEEDS_ARCHITECTURE_DECISION NEEDS_DECOMPOSITION RISK_REQUIRES_APPROVAL BLOCKED STALLED BUDGET_EXCEEDED "
        for (k = startidx; k <= total; k++) {
          st = jget(lines[k], "state"); it = jget(lines[k], "iteration"); tu = jget(lines[k], "total_usd")
          cu = jget(lines[k], "cost_usd") + 0; rsn = jget(lines[k], "reason"); tn = jget(lines[k], "turns") + 0
          if (tu != "") lasttotal = tu
          if (it != "final" && it != "run" && it != "0" && index(iset, " " st " ") > 0) {
            iters++
            if (st == "AGENT_ERROR") c_fail += cu; else c_impl += cu
            if (tn > maxturns) { maxturns = tn; maxit = it }
          }
          if (substr(st, 1, 7) == "REVIEW_") {
            reviews++; if (st == "REVIEW_APPROVE") approve++; if (st == "REVIEW_REVISE") revise++
            if      (st == "REVIEW_ERROR")               c_rerr  += cu
            else if (substr(rsn, 1, 9) == "[interim]")   c_rint  += cu
            else if (substr(rsn, 1, 6) == "[gate]")      c_rgate += cu
            else                                         c_rerr  += cu
          }
          if (substr(st, 1, 10) == "STOP_EVAL_") c_stop += cu
          if (st == "PLAN")     c_plan += cu
          if (st == "EVIDENCE") c_evid += cu
          if (it == "final") { finalstate = st; finalreason = jget(lines[k], "reason") }
        }
        # lifetime: sum of every run segment (all lines, not just the last run).
        # Segment value is the MAX total_usd, not the last: the next process
        # journals decompose rows (with a reset, smaller total) BEFORE its
        # RUN_START, which would otherwise clobber the finished-run total.
        life = 0; seg = 0; runs = 0
        for (k = 1; k <= total; k++) {
          if (jget(lines[k], "state") == "RUN_START") { life += seg; seg = 0; runs++ }
          tu = jget(lines[k], "total_usd"); if (tu != "") { tu += 0; if (tu > seg) seg = tu }
        }
        life += seg
        printf "iterations (last run): %d\n", iters
        printf "reviews: %d (%d approve / %d revise)\n", reviews, approve, revise
        printf "total cost (last run): $%.4f\n", lasttotal + 0
        printf "cost by role (last run): implement $%.4f | review interim $%.4f / gate $%.4f | plan $%.4f | evidence $%.4f | stop-eval $%.4f\n", c_impl, c_rint, c_rgate, c_plan, c_evid, c_stop
        if (c_fail > 0 || c_rerr > 0) printf "  failed/unattributed calls: agent $%.4f, review $%.4f\n", c_fail, c_rerr
        if (maxturns > 0) printf "max turns in one implement call: %d (iteration %s)\n", maxturns, maxit
        printf "lifetime cost: $%.4f across %d runs\n", life, runs
        if (finalstate != "") {
          printf "result: %s — %s\n", finalstate, finalreason
          if (finalstate == "SUCCESS") printf "cost per accepted change: $%.4f\n", lasttotal + 0
        }
      }
    ' .loop/journal.jsonl
  else
    echo "(no journal yet — run ./loop.sh)"
  fi
  # report must exit 0 — this trailing hint is cosmetic, and a bare `[ -n ] &&`
  # as the last command would leak exit 1 to scripted callers when no HTML exists
  [ -z "$html" ] || note "HTML view available: ./loop.sh report --open   ($html)"
}

# ---------- dispatch ----------

cmd="${1:-}"
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  "")
    if [ "$MODE" = "deployed" ]; then cmd_auto; else usage; fi
    ;;
  auto)    AUTO_MODE=1; cmd_auto "$@" ;;
  start)   cmd_start "$@" ;;
  fleet)   cmd_fleet "$@" ;;
  add)     cmd_fleet_add "$@" ;;
  init)    cmd_init "$@" ;;
  update)  cmd_update "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  approve) cmd_approve "$@" ;;
  decompose) cmd_decompose "$@" ;;
  contract-review) cmd_contract_review "$@" ;;
  run)     cmd_run "$@" ;;
  resume)  cmd_resume "$@" ;;
  refine)  cmd_refine "$@" ;;
  watch)   cmd_watch "$@" ;;
  status)  cmd_status "$@" ;;
  report)  cmd_report "$@" ;;
  open)    cmd_open "$@" ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
