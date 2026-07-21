#!/usr/bin/env bash
# lib.sh — shared harness for the zero-token E2E suite (tests/suite/*.sh).
# Fixtures use the DEPLOYED layout (loop.sh at project root, .loop/ hidden state),
# exercising every terminal state, the review/stop-eval processes, model routing,
# and the tamper protections.
#
# Every tests/suite/*.sh file sources this and is independently runnable:
#     tests/suite/30-fleet-basic.sh
# The usual entry point is the driver, tests/run_tests.sh, which runs the files
# in tests/suite/manifest.txt order — the `parallel` lane concurrently, then the
# `serial` lane alone. Read the driver's header for the lane rules before moving
# a test between lanes.
#
# Do NOT run two copies of the SUITE (or a suite + a real fleet) concurrently:
# fixtures are mktemp-isolated, but PID-liveness validation (`ps -p <pid> |
# grep loop.sh`) is machine-global — a PID recycled by the OTHER run
# can be adopted as a live task/supervisor. The driver's serial lane exists for
# exactly the tests that cannot tolerate that; everything else is lane-safe.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$ROOT/tests/fake_claude.sh"
FAKE_CODEX="$ROOT/tests/fake_codex.sh"
WORK="$(mktemp -d /tmp/loop-tests.XXXXXX)"

# Set by the driver so a crashed lane (set -e mid-file) still reports the
# assertions it did get through, instead of vanishing from the totals.
LANE_RESULT="${LOOP_TEST_RESULT:-}"
LANE_NAME="$(basename "${BASH_SOURCE[1]:-lib}" .sh)"

lane_report() { # counts + exit status -> the driver (or a standalone summary)
  [ -n "$LANE_RESULT" ] || return 0
  printf 'PASS=%s\nFAIL=%s\nFAILED=%s\nRC=%s\n' \
    "$PASS" "$FAIL" "$FAILED" "${1:-0}" > "$LANE_RESULT"
}

cleanup() {
  local rc=$?
  # TERM this lane's live background jobs (supervisors/orchestrations). Their own
  # INT/TERM handlers (on_supervisor_int / on_interrupt) cascade to workers and
  # model children, so job-level TERM is sufficient and never touches processes
  # outside this shell — unlike pkill -f, which could hit a sibling lane (whose
  # fixtures are a different tree entirely) or an unrelated real fleet. Not
  # self-testable from inside the suite; verified manually (Ctrl-C mid-fleet-test
  # leaves no stray loop.sh processes). Normal exits see an empty `jobs -p`.
  local pids
  pids=$(jobs -p 2>/dev/null || true)
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 2
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
  fi
  lane_report "$rc"
  timing_report
  if [ -z "$LANE_RESULT" ]; then
    echo
    echo "passed: $PASS  failed: $FAIL"
    [ "$FAIL" -eq 0 ] || echo "failed tests:$FAILED"
  fi
  rm -rf "$WORK"
  [ "$FAIL" -eq 0 ] || rc=1
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export GIT_AUTHOR_NAME=loop-test GIT_AUTHOR_EMAIL=loop-test@example.com
export GIT_COMMITTER_NAME=loop-test GIT_COMMITTER_EMAIL=loop-test@example.com

PASS=0
FAIL=0
FAILED=""

ok()   { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED="$FAILED $2"; echo "  FAIL: $1"; }
check() { # $1 description, $2 test-name, $3 expected, $4 actual
  if [ "$3" = "$4" ]; then ok "$1"; else bad "$1 (expected '$3', got '$4')" "$2"; fi
}

# stdin -> hex SHA-256. Mirrors loop.sh's sha256() (shasum on macOS/perl, sha256sum
# on coreutils) so the suite runs on any box with either tool — not just macOS.
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi; }

# Speed: the watchdog poll and the fleet dispatch tick (both in loop.sh) are real-time
# sleeps sized for production (2s). The fake agent returns in milliseconds, so
# at production granularity those sleeps ARE the suite's wall clock (~13 min).
# Shrink them here; production defaults are untouched.
export LOOP_WATCHDOG_POLL=0.1
export LOOP_FLEET_TICK=0.2
# tests must NEVER launch a real browser, even if the suite is run in a terminal:
# force a no-op opener globally. HTML tests override this inline with a sentinel
# stub (+ </dev/null) to assert the interactive gate actually suppresses opening.
export LOOP_BROWSER_CMD=true
export LOOP_CODEX_CMD="$FAKE_CODEX"
# Codex itself exports this internal marker in sandboxed sessions. It must not
# collide with loop-kit's separately named, approval-gated sandbox setting.
export CODEX_SANDBOX=seatbelt
# approvals are recorded in an OFF-TREE store (default $HOME/.loop-kit/approvals)
# in addition to the repo-local mirrors. Point the store into the suite workdir so
# tests never touch the real user store and cleanup rides on rm -rf $WORK —
# per-fixture repos hash to distinct repo-ids inside it, so fixtures stay isolated.
export LOOP_APPROVAL_HOME="$WORK/approvals"

# Hang backstops, NOT assertion thresholds. Nothing is proved by a supervisor
# draining in 120s rather than 240s — these bounds only stop a wedged run from
# hanging the suite forever. The driver raises them when lanes share the CPU, so
# contention shows up as a slower suite instead of a spurious "timed out" FAIL.
SUP_WAIT_MAX="${LOOP_TEST_SUP_WAIT_MAX:-120}"
# Multiplier for the bounded poll loops in the suite files (`n -lt N`). Same
# rule: raise the ceiling under load, never the thing being asserted.
POLL_SCALE="${LOOP_TEST_POLL_SCALE:-1}"
poll_max() { echo $(( $1 * POLL_SCALE )); }   # $1 base iterations -> scaled ceiling

# ---------- per-section timing (LOOP_TEST_TIMING=1) ----------
# section "…" prints the same `== … ==` banner the suite always printed and, when
# timing is on, appends the wall time of the PREVIOUS section to a TSV the driver
# aggregates. Purely additive: with timing off it is exactly an echo.
SECTION_NAME=""
SECTION_START=0
TIMING_FILE="${LOOP_TEST_TIMING_FILE:-${TMPDIR:-/tmp}/loop-timing-$$.tsv}"
timing_flush() {
  [ -n "${LOOP_TEST_TIMING:-}" ] || return 0
  [ -n "$SECTION_NAME" ] || return 0
  printf '%s\t%s\t%s\n' "$((SECONDS - SECTION_START))" "$LANE_NAME" "$SECTION_NAME" \
    >> "$TIMING_FILE"
  SECTION_NAME=""
}
section() {
  if [ -n "${LOOP_TEST_TIMING:-}" ]; then
    timing_flush
    SECTION_NAME="$1"
    SECTION_START=$SECONDS
  fi
  echo "== $1 =="
}
timing_report() {
  [ -n "${LOOP_TEST_TIMING:-}" ] || return 0
  timing_flush
  [ -n "${LOOP_TEST_RESULT:-}" ] || echo "  timing: $TIMING_FILE"
}

wait_sup() { # $1 pid, $2 test-name — bounded wait; sets RC (124 = timed out, killed).
  # Every supervisor wait goes through this: a supervisor that never drains is
  # a FAILURE the summary reports, never a silently hung shell.
  local pid=$1 name=$2 start=$SECONDS
  RC=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$SUP_WAIT_MAX" ]; then
      bad "supervisor still alive after ${SUP_WAIT_MAX}s — killed (would have hung the suite)" "$name"
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      RC=124
      return 0
    fi
    sleep 0.2
  done
  wait "$pid" || RC=$?
}

make_fixture() { # $1 name, [$2 variant: nocontract | noapprove] -> deployed fixture, cd'd into
  local dir="$WORK/$1"
  # Fixture builds dominate suite setup (~0.44s x ~200 = ~90s). `loop.sh init`
  # output is path-independent (verified: two inits differ only in .git/index,
  # which the per-fixture commit below rewrites), so build ONE golden deployment
  # via a real init and clone it (cp -R, ~30ms) for every fixture. The dedicated
  # `init`/`update` tests still call the real command; this only speeds the
  # factory. The clone carries init's "loop: kit deployed" commit + .loop/kit-source
  # exactly as a fresh init would, so git history and downstream state are identical.
  # The driver builds the golden ONCE for the whole suite and exports its path, so
  # N lanes pay for one init, not N. Standalone runs fall back to a lane-local one.
  local golden="${LOOP_TEST_GOLDEN:-$WORK/.golden-fixture}"
  if [ ! -e "$golden/.loop" ]; then
    "$ROOT/bin/loop.sh" init "$golden" >/dev/null
  fi
  mkdir -p "$dir"
  cp -R "$golden/." "$dir/"
  cd "$dir"
  echo broken > value.txt
  printf '#!/bin/sh\ngrep -q fixed value.txt\n' > check.sh
  chmod +x check.sh
  echo topsecret > secret.txt
  echo deps > deps.txt
  mkdir -p private
  echo key > private/key.txt
  cat > loop.config.sh <<'EOF'
VERIFY_COMMANDS=("./check.sh")
DENIED_PATHS="secret.txt private/**"
ESCALATE_PATHS="deps.txt"
MAX_ITERATIONS=4
MAX_COST_USD=5
MAX_ITER_SECONDS=60
STAGNATION_N=2
REPEAT_FAIL_N=3
MAX_REVISIONS=3
FUTILE_N=2
REVIEW_MODE="always"
STOP_EVAL="true"
EOF
  cat > loop.models.sh <<'EOF'
MODEL_CONTRACT="fake-con"
MODEL_PLAN="fake-plan"
MODEL_IMPLEMENT="fake-imp"
MODEL_REVIEW="fake-rev"
MODEL_EVIDENCE="fake-evi"
MODEL_STOP_EVAL="fake-stop"
LOOP_EFFORT="xhigh"
EOF
  # classic single-loop fixtures opt out of decomposition (the orchestration
  # fixtures below turn it back on) so every pre-orchestration test keeps its
  # exact call sequence
  printf 'FLEET_DECOMPOSE=0\n' >> fleet.config.sh
  if [ "${2:-}" != "nocontract" ]; then
    cat > .loop/docs/product-contract.md <<'EOF'
# Product Contract
## Goal
value.txt must contain "fixed".
## Requirements
### REQ-001
./check.sh exits 0.
EOF
    cat > .loop/docs/implementation-plan.md <<'EOF'
# Implementation Plan
- [ ] M1: fix value.txt
EOF
  fi
  git add -A
  git commit -q -m fixture
  if [ -z "${2:-}" ]; then
    ./loop.sh approve >/dev/null
  fi
}

run_loop() { # $1 scenario, [$2 review verdicts], [$3 stop-eval verdicts]
  RC=0
  LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="$1" \
    LOOP_FAKE_REVIEW="${2:-APPROVE}" LOOP_FAKE_STOPEVAL="${3:-CONTINUE}" \
    ./loop.sh run >"$WORK/last-run.out" 2>&1 </dev/null || RC=$?
  STATE=$(cat .loop/state 2>/dev/null || echo none)
}

seed_ledger_met() {
  cat > .loop/docs/requirements-ledger.md <<'EOF'
# Requirements Ledger

| REQ | Status | Evidence | Iter |
|---|---|---|---|
| REQ-001 | met | value.txt fixed | 1 |
EOF
}

json_scalar() { # $1 one-line JSON file $2 key -> simple string value
  sed -nE "s/.*\"$2\":\"([^\"]*)\".*/\\1/p" "$1"
}

# ---------- helpers owned by one area of the suite ----------
# These are read by the suite files that need them (see tests/suite/*.sh); the
# out-parameters below (SK, DISCARD_*, RC, STATE) are consumed across the source
# boundary, which shellcheck cannot see from here.

# shellcheck disable=SC2034  # read by 05-static.sh / 90-static-invariants.sh
SK="$ROOT/kit/.claude/skills"
html_block_sha() { awk '/BEGIN loop-html-contract/{f=1} f{print} /END loop-html-contract/{f=0}' "$1" | sha256; }

make_fleet_fixture() { # $1 name — deployed fixture WITHOUT contract + two task files
  make_fixture "$1" nocontract
  printf 'alpha task: fix value.txt so the check passes\n' > task-a.md
  printf 'bravo task: fix value.txt so the check passes\n' > task-b.md
}

fleet_task_id() { # $1 substring -> matching task id (searches every queue dir)
  local f
  for f in .loop/fleet/queue/*/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in *"$1"*) basename "$f" .md; return 0 ;; esac
  done
  echo ""
}

fleet_phase()  { grep -E '^PHASE='  ".loop/fleet/runs/$1.env" 2>/dev/null | tail -1 | cut -d= -f2 || true; }
fleet_result() { grep -E '^RESULT=' ".loop/fleet/runs/$1.env" 2>/dev/null | tail -1 | cut -d= -f2 || true; }
fleet_wt()     { grep -E '^WT='     ".loop/fleet/runs/$1.env" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
qcount()      { find ".loop/fleet/queue/$1" -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }

ts_plus() { date -v+"$1"S +%Y%m%d-%H%M%S 2>/dev/null || date -d "+$1 seconds" +%Y%m%d-%H%M%S; }
make_orch_fixture() { # $1 name, [$2 reqs: 1|2] — approved fixture with decompose ON
  make_fixture "$1"
  grep -v '^FLEET_DECOMPOSE=' fleet.config.sh > fleet.config.tmp && mv fleet.config.tmp fleet.config.sh
  printf 'FLEET_DECOMPOSE=1\n' >> fleet.config.sh
  printf 'MODEL_DECOMPOSE="fake-dec"\nMODEL_SUPERVISE="fake-sup"\n' >> loop.models.sh
  if [ "${2:-1}" = 2 ]; then
    cat >> .loop/docs/product-contract.md <<'EOF'
### REQ-002
./check.sh exits 0 (second requirement, same gate).
EOF
    git add -A && git commit -q -m orch-master
    ./loop.sh approve >/dev/null
  fi
}

make_sup_fixture() { # $1 name — fleet fixture + real master contract (PLANNED context)
  local source refname plan_hash authority
  make_fleet_fixture "$1"
  cat > .loop/docs/product-contract.md <<'EOF'
# Product Contract (master)
## Goal
value.txt must contain "fixed".
## Requirements
### REQ-001
./check.sh exits 0.
EOF
  git add -A && git commit -q -m master
  # Supervision tests mark their queued task PLANNED below. Give that synthetic
  # plan the same immutable authority a real decomposition publishes, so REPLAN
  # replacements exercise the production enqueue invariant instead of relying
  # on the pre-authority test shortcut.
  source=$(git rev-parse HEAD)
  refname=$(git symbolic-ref -q HEAD)
  plan_hash=$(sha256 < .loop/docs/product-contract.md)
  authority=$(printf '%s\n' loop-plan-v1 "$plan_hash" "$source" "$refname" | sha256)
  mkdir -p .loop/fleet
  cat > .loop/fleet/plan-authority.env <<EOF
VERSION=1
AUTHORITY=$authority
PLAN_HASH=$plan_hash
SOURCE_REF=$source
SOURCE_REFNAME=$refname
CREATED_AT=test
EOF
}

discard_archive_dir() { # newest/only cancellation archive in the current fixture
  local d found=""
  for d in .loop/docs/run-archive/*-discard*; do
    [ -d "$d" ] || continue
    found="$d"
  done
  printf '%s' "$found"
}

seed_unstarted_discard_plan() { # $1 task id — mirrors v1 authority + planned enqueue
  local id="$1" plan_hash
  mkdir -p .loop/fleet/queue/tmp .loop/fleet/queue/new \
           .loop/fleet/queue/claimed .loop/fleet/queue/done \
           .loop/fleet/queue/failed .loop/fleet/runs
  cat > .loop/docs/task-plan.md <<EOF
# Task Plan

Synthetic zero-token fixture for whole-plan discard.

<!-- TASK-PLAN-BEGIN v1 -->
TASK: $id
SUMMARY: planned discard fixture
DEPENDS: -
SCOPE: value.txt
REQS: REQ-001
BODY-BEGIN
Fix value.txt for REQ-001.
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
  git add .loop/docs/task-plan.md
  git commit -q -m "test: seed an unstarted planned queue"
  DISCARD_SOURCE=$(git rev-parse HEAD)
  DISCARD_REFNAME=$(git symbolic-ref -q HEAD)
  plan_hash=$(cat .loop/docs/product-contract.md .loop/docs/task-plan.md | sha256)
  DISCARD_AUTHORITY=$(printf '%s\n' loop-plan-v1 "$plan_hash" "$DISCARD_SOURCE" "$DISCARD_REFNAME" | sha256)
  cat > .loop/fleet/plan-authority.env <<EOF
VERSION=1
AUTHORITY=$DISCARD_AUTHORITY
PLAN_HASH=$plan_hash
SOURCE_REF=$DISCARD_SOURCE
SOURCE_REFNAME=$DISCARD_REFNAME
CREATED_AT=test
EOF
  printf '%s\n' "$DISCARD_SOURCE" > .loop/fleet/base-ref
  cat > ".loop/fleet/runs/$id.env" <<EOF
SUMMARY=planned discard fixture
SRC=task-plan
AUTO=1
PLANNED=1
PLAN_AUTHORITY=$DISCARD_AUTHORITY
PLAN_SOURCE_REF=$DISCARD_SOURCE
PLAN_SOURCE_REFNAME=$DISCARD_REFNAME
REQS=REQ-001
SCOPE=value.txt
ADDED_AT=test
PHASE=queued
EOF
  printf 'planned task %s\n' "$id" > ".loop/fleet/queue/new/$id.md"
  echo FLEET_RUNNING > .loop/state
}

make_discard_merged_fixture() { # $1 fixture — one attributed merge, dependents held
  local name="$1"
  make_orch_fixture "$name" 2
  RC=0
  LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN_SHARED LOOP_FAKE_SCENARIO=READY_TOUCH \
    LOOP_FAKE_PLAN_REVIEW=ESCALATE \
    ./loop.sh run >"$WORK/$name-setup.out" 2>&1 </dev/null || RC=$?
  check "setup stops at the phase-boundary decision" "$name" 3 "$RC"
  if [ -f .loop/fleet/queue/done/phase-a.md ] && [ -f .loop/fleet/queue/new/phase-b.md ]; then
    ok "setup leaves one attributed merge and queued dependents"
  else
    bad "discard rollback setup did not reach the stable merge boundary" "$name"
  fi
  # out-parameters for 50-discard.sh
  # shellcheck disable=SC2034
  DISCARD_SOURCE=$(sed -n 's/^SOURCE_REF=//p' .loop/fleet/plan-authority.env)
  # shellcheck disable=SC2034
  DISCARD_AUTHORITY=$(sed -n 's/^AUTHORITY=//p' .loop/fleet/plan-authority.env)
  # shellcheck disable=SC2034
  DISCARD_MERGE_COMMIT=$(sed -n 's/^MERGE_COMMIT=//p' .loop/fleet/runs/phase-a.env | tail -1)
  # shellcheck disable=SC2034
  DISCARD_PRE=$(git rev-parse HEAD)
}

resume_run() { # $1 scenario, $2 loop.sh args... -> sets RC, STATE (fake agent, headless)
  local scen="$1"; shift
  RC=0
  LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="$scen" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
    ./loop.sh "$@" >"$WORK/resume-last.out" 2>&1 </dev/null || RC=$?
  # shellcheck disable=SC2034  # out-parameter, read by the calling suite file
  STATE=$(cat .loop/state 2>/dev/null || echo none)
}
ckpt_field() { grep -E "^$1=" .loop/run-checkpoint 2>/dev/null | tail -1 | cut -d= -f2- || true; }
run_starts() { grep -c '"state": "RUN_START"' .loop/journal.jsonl 2>/dev/null || echo 0; }

