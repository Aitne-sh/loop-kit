#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "resume: a recycled RUNNING pid is listed '(process dead)' and resume reaps+relaunches"
# E11/G7b: phase RUNNING with a dead pid used to be an unresumable 'busy' —
# liveness makes it a stale-running class the human can act on directly. Make
# the stronger PID-reuse case deterministic: a SIGKILL-stale run.pid must not
# turn an unrelated, still-live process into permanent task liveness.
make_fleet_fixture resume-stale
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="CONTINUE_FIX,CONTINUE_FIX,READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --auto > "$WORK/resume-stale1.out" 2>&1 </dev/null &
SUP=$!
id=""
n=0   # kill only mid-run with the trap installed (see the fleet-crash note)
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
sleep 300 &
DECOY_PID=$!
printf 'PID=%s\n' "$DECOY_PID" >> ".loop/fleet/runs/$id.env"
printf '%s\n' "$DECOY_PID" > "$(fleet_wt "$id")/.loop/run.pid"
rm -f "$(fleet_wt "$id")/.loop/run.heartbeat"
check "phase left RUNNING with its pid recycled by a foreign process" resume-stale RUNNING "$(fleet_phase "$id")"
out=$(./loop.sh resume --list 2>&1) || true
if printf '%s\n' "$out" | grep "$id" | grep -q '(process dead)'; then
  ok "listing rejects stale run.pid ownership and flags the task (process dead)"
else
  bad "no (process dead) verdict: $(printf '%s\n' "$out" | grep "$id" || echo missing)" resume-stale
fi
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh resume "$id" > "$WORK/resume-stale2.out" 2>&1 </dev/null || RC=$?
if kill -0 "$DECOY_PID" 2>/dev/null; then
  ok "stale ownership cleanup never signals the recycled foreign process"
else
  bad "resume killed the recycled foreign process" resume-stale
fi
kill "$DECOY_PID" 2>/dev/null || true
wait "$DECOY_PID" 2>/dev/null || true
check "resume reaps the corpse and relaunches inline (exit 0)" resume-stale 0 "$RC"
if [ -f ".loop/fleet/queue/done/$id.md" ]; then ok "task completed after the stale-running resume"; else bad "task not done ($(fleet_phase "$id"))" resume-stale; fi
check "parent value fixed" resume-stale fixed "$(cat value.txt)"

