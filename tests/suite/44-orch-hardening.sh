#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- orchestration hardening: stuck states escalate, never hang ----------

section "orch: external fleet stop mid-orchestration parks + escalates; resume completes"
make_orch_fixture orch-stop 2
RC=0
# every iteration must produce a real diff: a CONTINUE_FIX streak rewrites the
# same content (no diff) and trips STAGNATION_N=2 -> the worker would STALL
# instead of surviving to be stopped/resumed. BAD_FIX appends to notes.txt
# (verify stays green after iter 1), so all 4 iterations count as progress.
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR \
  LOOP_FAKE_SCENARIO="CONTINUE_FIX,BAD_FIX,BAD_FIX,READY_NOW" \
  ./loop.sh run >"$WORK/orch-stop1.out" 2>&1 </dev/null &
ORCH=$!
n=0   # stop only once part-a is mid-run with its trap installed (see orch-resume)
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  if [ "$(fleet_phase part-a)" = "RUNNING" ] \
     && [ "$(cat "$(fleet_wt part-a)/.loop/state" 2>/dev/null)" = "RUNNING" ]; then
    break
  fi
  sleep 0.2; n=$((n + 1))
done
./loop.sh fleet stop part-a >/dev/null 2>&1 || true
wait_sup "$ORCH" orch-stop
check "orchestration escalates instead of hanging (exit 3)" orch-stop 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-stop NEEDS_SPEC_DECISION "$(cat .loop/state)"
check "part-a parked INTERRUPTED" orch-stop INTERRUPTED "$(fleet_result part-a)"
if grep -q '"event": "ORCH_INTERRUPTED_PARKED"' .loop/fleet/journal.jsonl; then ok "park journaled (external stop honored, not un-stopped)"; else bad "ORCH_INTERRUPTED_PARKED missing" orch-stop; fi
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet resume part-a >/dev/null 2>&1 || true
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR \
  LOOP_FAKE_SCENARIO="CONTINUE_FIX,BAD_FIX,BAD_FIX,READY_NOW" \
  ./loop.sh run >"$WORK/orch-stop2.out" 2>&1 </dev/null &
wait_sup $! orch-stop
check "resumed orchestration exit 0" orch-stop 0 "$RC"
check "state SUCCESS after resume" orch-stop SUCCESS "$(cat .loop/state)"
check "both tasks done" orch-stop 2 "$(qcount "done")"

section "orch: PENDING_APPROVAL deadlock escalates to the human (approval watchdog)"
make_orch_fixture orch-penda 2
RC=0
# both sub-contracts refused twice (REVISE + failed regen) -> demoted to
# PENDING_APPROVAL with no in-process approver -> bounded wait, then exit 3
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  LOOP_FAKE_CONTRACT_REVIEW=REVISE \
  ./loop.sh run >"$WORK/orch-penda1.out" 2>&1 </dev/null &
wait_sup $! orch-penda
check "exit 3 (a human must approve)" orch-penda 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-penda NEEDS_SPEC_DECISION "$(cat .loop/state)"
if grep -q '"event": "CONTRACT_REVIEW_REFUSED"' .loop/fleet/journal.jsonl; then ok "review refusal journaled"; else bad "CONTRACT_REVIEW_REFUSED missing" orch-penda; fi
if grep -q '"state": "FLEET_APPROVAL_BLOCKED"' .loop/journal.jsonl; then ok "approval deadlock journaled"; else bad "FLEET_APPROVAL_BLOCKED missing" orch-penda; fi
check "part-a still PENDING_APPROVAL (nothing auto-approved)" orch-penda PENDING_APPROVAL "$(fleet_phase part-a)"
check "part-b still PENDING_APPROVAL" orch-penda PENDING_APPROVAL "$(fleet_phase part-b)"
if grep -q '^## DR-FLEET-APPROVAL' .loop/docs/decision-requests.md; then ok "decision request written"; else bad "DR-FLEET-APPROVAL missing" orch-penda; fi
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve --all </dev/null >/dev/null 2>&1
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-penda2.out" 2>&1 </dev/null &
wait_sup $! orch-penda
check "human-approved orchestration completes (exit 0)" orch-penda 0 "$RC"
check "both tasks done" orch-penda 2 "$(qcount "done")"

section "orch: zero-progress watchdog (FLEET_STALL_TICKS) exits BLOCKED with evidence"
make_orch_fixture orch-stall
printf 'FLEET_STALL_TICKS=5\n' >> fleet.config.sh
mkdir -p .loop/fleet/queue/new .loop/fleet/queue/claimed .loop/fleet/queue/done \
         .loop/fleet/queue/failed .loop/fleet/queue/tmp .loop/fleet/runs
# forge a mixed-stuck state no single guard covers: x waits for an approval,
# y waits on a merge blocked by a dirty parent -> no live worker, no phase change
mkdir -p "$WORK/orch-stall-loops/x/.loop" "$WORK/orch-stall-loops/y/.loop"
printf 'stuck task x\n' > .loop/fleet/queue/claimed/x.md
printf 'stuck task y\n' > .loop/fleet/queue/claimed/y.md
printf 'SUMMARY=stuck x\nPHASE=PENDING_APPROVAL\nWT=%s\n' "$WORK/orch-stall-loops/x" > .loop/fleet/runs/x.env
git branch loop/y >/dev/null 2>&1
printf 'SUMMARY=stuck y\nPHASE=MERGE_PENDING\nBRANCH=loop/y\nWT=%s\n' "$WORK/orch-stall-loops/y" > .loop/fleet/runs/y.env
echo "# human mid-edit" >> check.sh          # dirty tracked file defers y's merge
echo FLEET_RUNNING > .loop/state
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/orch-stall.out" 2>&1 </dev/null &
wait_sup $! orch-stall
check "exit 4" orch-stall 4 "$RC"
check "state BLOCKED" orch-stall BLOCKED "$(cat .loop/state)"
if grep -q '"state": "FLEET_STALLED"' .loop/journal.jsonl; then ok "stall journaled with the phase fingerprint"; else bad "FLEET_STALLED missing" orch-stall; fi

