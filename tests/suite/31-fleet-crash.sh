#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "fleet: crash recovery (kill -9 supervisor + loop) resumes to SUCCESS"
make_fleet_fixture fleet-crash
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="CONTINUE_FIX,CONTINUE_FIX,READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/fleet-crash1.out" 2>&1 </dev/null &
SUP=$!
id=""
n=0
# Kill only once the worktree's .loop/state says RUNNING: PHASE=RUNNING is set
# at process SPAWN, before loop.sh installs its signal trap or writes any state
# — a kill in that window exercises the wrong recovery path. wt-state RUNNING
# is written after the trap, with >=2 of the 3 fake iterations still ahead, so
# the kill deterministically lands mid-run (not too early, not after SUCCESS).
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  id=$(fleet_task_id alpha)
  if [ -n "$id" ] && [ "$(fleet_phase "$id")" = "RUNNING" ] \
     && [ "$(cat "$(fleet_wt "$id")/.loop/state" 2>/dev/null)" = "RUNNING" ]; then
    break
  fi
  sleep 0.2; n=$((n + 1))
done
LOOP_PID=$(grep -E '^PID=' ".loop/fleet/runs/$id.env" | tail -1 | cut -d= -f2)
kill -9 "$SUP" 2>/dev/null || true
kill -9 "$LOOP_PID" 2>/dev/null || true
wait "$SUP" 2>/dev/null || true
sleep 1
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-crash2.out" 2>&1 </dev/null &
wait_sup $! fleet-crash
check "recovery supervisor exit 0" fleet-crash 0 "$RC"
if grep -q "removing stale supervisor lock" "$WORK/fleet-crash2.out"; then ok "stale lock auto-removed"; else bad "stale lock not handled" fleet-crash; fi
if grep -q '"event": "CRASH_RETRY"' .loop/fleet/journal.jsonl; then ok "crash retry journaled"; else bad "CRASH_RETRY missing" fleet-crash; fi
check "task completed after recovery" fleet-crash fixed "$(cat value.txt)"

