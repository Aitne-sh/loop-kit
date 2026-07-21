#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- NEEDS_DECOMPOSITION (oversized-task declaration + split nudge) ----------

section "NEEDS_DECOMPOSITION: declared state honored end-to-end (exit 3)"
make_fixture decomp-declare
run_loop "DECLARE_DECOMP" APPROVE CONTINUE
check "exit 3" decomp-declare 3 "$RC"
check "state NEEDS_DECOMPOSITION" decomp-declare NEEDS_DECOMPOSITION "$STATE"
if grep -q 'iteration budget' .loop/docs/decision-requests.md; then ok "decision request written with the split rationale"; else bad "decision request missing" decomp-declare; fi
if [ -f .loop/run-checkpoint ]; then ok "checkpoint kept for the decision rebind"; else bad "checkpoint dropped" decomp-declare; fi

section "split nudge: fleet worker past the budget threshold with unmet REQs"
make_fixture split-nudge
# loop.config.sh is deployed-gitignored — no commit; approve re-hashes it
printf 'SPLIT_NUDGE_AT=50\n' >> loop.config.sh
touch .loop/fleet-worker
./loop.sh approve >/dev/null
# BAD_FIX never fixes verify: identical failures hit REPEAT_FAIL_N=3 -> BLOCKED,
# but the nudge threshold (50% of MAX_ITERATIONS=4 -> iteration 2) fires first
run_loop "BAD_FIX" APPROVE CONTINUE
check "run stopped on repeated failure (exit 4)" split-nudge 4 "$RC"
if [ -f .loop/split-nudge.md ] && grep -q 'NEEDS_DECOMPOSITION' .loop/split-nudge.md; then
  ok "split nudge written past the threshold with unmet REQs"
else
  bad "split nudge missing" split-nudge
fi
if grep -q 'REQ-001' .loop/split-nudge.md; then ok "nudge names the unmet REQ"; else bad "unmet REQ not named" split-nudge; fi

section "split nudge: absent outside a fleet worker (no marker)"
make_fixture split-nudge-off
printf 'SPLIT_NUDGE_AT=50\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "BAD_FIX" APPROVE CONTINUE
check "run stopped on repeated failure (exit 4)" split-nudge-off 4 "$RC"
if [ ! -f .loop/split-nudge.md ]; then ok "no split nudge outside a fleet worker"; else bad "split nudge written in a plain loop" split-nudge-off; fi

section "fleet: NEEDS_DECOMPOSITION routes to the supervisor"
make_sup_fixture fleet-decomp
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SCENARIO=DECLARE_DECOMP LOOP_FAKE_SUPERVISE=ESCALATE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-decomp.out" 2>&1 </dev/null &
wait_sup $! fleet-decomp
check "supervisor exit 0 (drained with the parked task)" fleet-decomp 0 "$RC"
if grep -q '"event": "SUPERVISE_PENDING"' .loop/fleet/journal.jsonl && grep -q 'NEEDS_DECOMPOSITION' .loop/fleet/journal.jsonl; then
  ok "NEEDS_DECOMPOSITION routed to the supervisor"
else
  bad "supervisor routing missing" fleet-decomp
fi
check "parked NEEDS_HUMAN on supervisor ESCALATE" fleet-decomp NEEDS_HUMAN "$(fleet_phase "$id")"

section "carryover: NEEDS_DECOMPOSITION split seeds the chain root with committed work"
make_sup_fixture fleet-carry
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SUPERVISE=REPLAN_CHAIN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --drain > "$WORK/fleet-carry.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "DECLARE_DECOMP" > "$(fleet_wt "$id")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-carry
check "supervisor exit 0" fleet-carry 0 "$RC"
check "escalated task superseded (REPLANNED)" fleet-carry REPLANNED "$(fleet_phase "$id")"
check "seed recorded on the chain root" fleet-carry "loop/$id" "$(grep -E '^SEED_BRANCH=' .loop/fleet/runs/phase-1.env 2>/dev/null | tail -1 | cut -d= -f2-)"
if grep -q '"event": "CARRYOVER_SEEDED"' .loop/fleet/journal.jsonl; then ok "carryover journaled"; else bad "CARRYOVER_SEEDED missing" fleet-carry; fi
check "both phases done" fleet-carry 2 "$(qcount "done")"
check "escalated task's committed work reached the parent" fleet-carry scaffold "$(cat notes.txt 2>/dev/null)"
check "parent value fixed by the chain" fleet-carry fixed "$(cat value.txt)"
if [ -f "$(fleet_wt phase-2)/.loop/phase-context/phase-1/evidence-report.md" ]; then
  ok "replan-produced chain also inherits phase-context"
else
  bad "phase-context missing for the replan chain" fleet-carry
fi

section "carryover: a seeded fork-join lands the seed on the unique root"
# root-p -> {half-a ∥ half-b} -> join-c (4 replacements — needs a raised
# FLEET_MAX_REPLAN_TASKS): the committed work seeds root-p, the only member
# with no intra-block DEPENDS
make_sup_fixture fleet-carryfork
printf 'FLEET_MAX_REPLAN_TASKS=4\n' >> fleet.config.sh
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SUPERVISE=REPLAN_FORKJOIN_CARRY LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --drain > "$WORK/fleet-carryfork.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "DECLARE_DECOMP" > "$(fleet_wt "$id")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-carryfork
check "supervisor exit 0" fleet-carryfork 0 "$RC"
check "escalated task superseded (REPLANNED)" fleet-carryfork REPLANNED "$(fleet_phase "$id")"
check "seed recorded on the unique root" fleet-carryfork "loop/$id" "$(grep -E '^SEED_BRANCH=' .loop/fleet/runs/root-p.env 2>/dev/null | tail -1 | cut -d= -f2-)"
if grep -q '"event": "CARRYOVER_SEEDED"' .loop/fleet/journal.jsonl; then ok "carryover journaled"; else bad "CARRYOVER_SEEDED missing" fleet-carryfork; fi
check "all four replacements done" fleet-carryfork 4 "$(qcount "done")"
check "escalated task's committed work reached the parent" fleet-carryfork scaffold "$(cat notes.txt 2>/dev/null)"
check "parent value fixed" fleet-carryfork fixed "$(cat value.txt)"

section "carryover: FLEET_SPLIT_CARRYOVER=0 keeps replacements clean"
make_sup_fixture fleet-carryoff
printf 'FLEET_SPLIT_CARRYOVER=0\n' >> fleet.config.sh
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SUPERVISE=REPLAN_CHAIN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --drain > "$WORK/fleet-carryoff.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "DECLARE_DECOMP" > "$(fleet_wt "$id")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-carryoff
check "supervisor exit 0" fleet-carryoff 0 "$RC"
if ! grep -qE '^SEED_BRANCH=' .loop/fleet/runs/phase-1.env 2>/dev/null; then ok "no seed recorded with the knob off"; else bad "SEED_BRANCH recorded despite knob=0" fleet-carryoff; fi
if [ ! -f notes.txt ]; then ok "escalated work NOT carried (stays on the archived branch)"; else bad "carryover happened despite knob=0" fleet-carryoff; fi
check "chain still completed" fleet-carryoff 2 "$(qcount "done")"

section "carryover: a conflicting seed is skipped (journaled) and the task still runs"
make_fleet_fixture fleet-carryskip
# stage ONLY notes.txt: `git add -A` would commit the (untracked) task files
# onto loop/dead, and checking main back out would delete task-a.md from the
# working tree — fleet add would then enqueue the string as an inline task
git checkout -q -b loop/dead
echo seedwork > notes.txt
git add notes.txt && git commit -q -m "seed work on the dead branch"
git checkout -q -
echo parentwork > notes.txt
git add notes.txt && git commit -q -m "conflicting parent note"
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md --auto >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'SEED_BRANCH=loop/dead\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain > "$WORK/fleet-carryskip.out" 2>&1 </dev/null &
wait_sup $! fleet-carryskip
check "supervisor exit 0" fleet-carryskip 0 "$RC"
if grep -q '"event": "CARRYOVER_SKIPPED"' .loop/fleet/journal.jsonl && grep -q 'conflicted' .loop/fleet/journal.jsonl; then
  ok "conflicting seed skipped with the journaled reason"
else
  bad "CARRYOVER_SKIPPED missing" fleet-carryskip
fi
check "task still completed on a clean tree" fleet-carryskip 1 "$(qcount "done")"
check "parent note untouched by the dead seed" fleet-carryskip parentwork "$(cat notes.txt)"

