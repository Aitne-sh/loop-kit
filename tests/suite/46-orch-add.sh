#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- orchestration add hardening: late adds + manual-task surfacing ----------

section "orch: task added during the integration gate is dispatched before completion"
make_orch_fixture orch-lateadd 2
printf 'charlie task: fix value.txt so the check passes\n' > task-c.md
echo 3 > .loop/fake-sleep   # parent-side calls sleep 3s (workers' worktrees stay fast)
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-lateadd.out" 2>&1 </dev/null &
ORCH=$!
n=0   # the fake records the gate prompt BEFORE sleeping -> a 3s deterministic window
while [ "$n" -lt $((600 * POLL_SCALE)) ]; do
  grep -q 'mode=gate' .loop/fake-review-prompts 2>/dev/null && break
  sleep 0.1; n=$((n + 1))
done
RCA=0
out=$(./loop.sh add task-c.md --auto 2>&1) || RCA=$?
check "late add accepted (exit 0)" orch-lateadd 0 "$RCA"
case "$out" in
  *"before completing"*) ok "add explains the dispatch-before-completion guarantee" ;;
  *) bad "late-add hint missing: $out" orch-lateadd ;;
esac
wait_sup "$ORCH" orch-lateadd
check "orchestration exit 0" orch-lateadd 0 "$RC"
check "state SUCCESS" orch-lateadd SUCCESS "$(cat .loop/state)"
check "all three tasks done (late add included)" orch-lateadd 3 "$(qcount "done")"
if grep -q '"state": "FLEET_LATE_ADD"' .loop/journal.jsonl; then ok "late-add rescan journaled"; else bad "FLEET_LATE_ADD missing" orch-lateadd; fi
n_gates=$(grep -c '"state": "INTEGRATION_GATE_' .loop/journal.jsonl || true)
if [ "$n_gates" -ge 2 ]; then ok "a fresh gate round certified the late task ($n_gates gate records)"; else bad "no second gate round ($n_gates gate records)" orch-lateadd; fi

section "orch: manual add runs outside the plan; its failure surfaces at the end"
make_orch_fixture orch-manualfail 2
printf 'charlie task: fix value.txt so the check passes\n' > task-c.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-manualfail.out" 2>&1 </dev/null &
ORCH=$!
n=0
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  [ "$(qcount claimed)" -ge 1 ] && break
  sleep 0.2; n=$((n + 1))
done
RCA=0
out=$(./loop.sh add task-c.md --auto 2>&1) || RCA=$?
case "$out" in
  *"MANUAL task"*) ok "add warns this runs as a manual task outside the master contract" ;;
  *) bad "manual-task warning missing: $out" orch-manualfail ;;
esac
idc=$(fleet_task_id charlie)
n=0   # fail the manual task: per-worktree scenario, written before its first iteration
wtc=""
while [ "$n" -lt $((600 * POLL_SCALE)) ]; do
  wtc=$(fleet_wt "$idc")
  [ -n "$wtc" ] && [ -d "$wtc/.loop" ] && break
  sleep 0.05; n=$((n + 1))
done
echo DECLARE_BLOCKED > "$wtc/.loop/fake-scenario"
wait_sup "$ORCH" orch-manualfail
check "orchestration surfaces the manual failure (exit 3)" orch-manualfail 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-manualfail NEEDS_SPEC_DECISION "$(cat .loop/state)"
check "planned tasks done (never aborted mid-flight)" orch-manualfail 2 "$(qcount "done")"
check "planned work merged + gated" orch-manualfail fixed "$(cat value.txt)"
check "manual task failed BLOCKED" orch-manualfail BLOCKED "$(fleet_phase "$idc")"
if grep -q 'DR-FLEET-MANUAL' .loop/docs/decision-requests.md && grep -q "$idc" .loop/docs/decision-requests.md; then
  ok "decision request names the manual task"
else
  bad "DR-FLEET-MANUAL missing/incomplete" orch-manualfail
fi
if grep -q '"state": "FLEET_MANUAL_FAILED"' .loop/journal.jsonl; then ok "manual failure journaled"; else bad "FLEET_MANUAL_FAILED missing" orch-manualfail; fi

section "orch: a manual add that MERGES is sanctioned at the gate and audited on SUCCESS"
# E2: the gate reviewer gets the manual-tasks manifest (their scopes are not
# drift), the run still finishes SUCCESS (each manual task passed its own
# pipeline; the gate re-verified the merged whole), and the merge is surfaced
# as an informational decision-request block — audited, never silently blended.
make_orch_fixture orch-manualok 2
printf 'charlie task: fix value.txt so the check passes\n' > task-c.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-manualok.out" 2>&1 </dev/null &
ORCH=$!
n=0
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  [ "$(qcount claimed)" -ge 1 ] && break
  sleep 0.2; n=$((n + 1))
done
./loop.sh add task-c.md --auto >/dev/null 2>&1
wait_sup "$ORCH" orch-manualok
check "orchestration exit 0 (manual merge is not a failure)" orch-manualok 0 "$RC"
check "state SUCCESS" orch-manualok SUCCESS "$(cat .loop/state)"
check "all three tasks done (manual one merged)" orch-manualok 3 "$(qcount "done")"
if grep -q '"state": "FLEET_MANUAL_MERGED"' .loop/journal.jsonl; then ok "manual merge journaled"; else bad "FLEET_MANUAL_MERGED missing" orch-manualok; fi
if grep -q 'DR-FLEET-MANUAL-MERGED' .loop/docs/decision-requests.md; then ok "audit block appended to decision requests"; else bad "DR-FLEET-MANUAL-MERGED missing" orch-manualok; fi
if grep -q 'Manual side-tasks merged' .loop/docs/evidence-report.md; then ok "evidence report carries the manual-merge section"; else bad "manual section missing from evidence" orch-manualok; fi
if grep -q 'manual-tasks=' .loop/fake-review-prompts; then ok "gate review prompt carried the manifest token"; else bad "manual-tasks token missing from the gate prompt" orch-manualok; fi
check "no fix-up burned on sanctioned side-work" orch-manualok 0 "$(cat .loop/fleet/fixup-count 2>/dev/null || echo 0)"

section "orch: add BEFORE the first run parks the task; bare run still decomposes"
# the pre-fix bug: a pre-start manual add made bare `run` misread the queue as
# an in-flight orchestration and FLEET_RESUME forever — the master contract
# was never decomposed and --single/--fresh refused (no escape). The parked
# task must instead be dispatched alongside the decomposed plan.
make_orch_fixture orch-preadd 2
printf 'charlie task: fix value.txt so the check passes\n' > task-c.md
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh add task-c.md --auto >/dev/null 2>&1
check "task parked in new/ before the first run" orch-preadd 1 "$(qcount new)"
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-preadd.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-preadd 0 "$RC"
check "state SUCCESS" orch-preadd SUCCESS "$(cat .loop/state)"
if grep -q '"state": "DECOMPOSE_OK"' .loop/journal.jsonl; then ok "master contract decomposed"; else bad "DECOMPOSE_OK missing — decompose skipped over the parked queue" orch-preadd; fi
if [ -f .loop/docs/task-plan.md ]; then ok "task-plan.md generated"; else bad "task-plan.md missing" orch-preadd; fi
if grep -q '"state": "FLEET_START"' .loop/journal.jsonl; then ok "orchestration STARTED (not resumed)"; else bad "FLEET_START missing" orch-preadd; fi
if ! grep -q '"state": "FLEET_RESUME"' .loop/journal.jsonl; then ok "no phantom FLEET_RESUME"; else bad "FLEET_RESUME journaled for a never-started orchestration" orch-preadd; fi
check "planned AND manual tasks all done" orch-preadd 3 "$(qcount "done")"
if grep -q '"state": "FLEET_MANUAL_MERGED"' .loop/journal.jsonl; then ok "pre-start manual task merged + audited"; else bad "FLEET_MANUAL_MERGED missing" orch-preadd; fi
if grep -q "alongside the planned tasks" "$WORK/orch-preadd.out"; then ok "decompose called out the parked task"; else bad "no parked-task note from decompose" orch-preadd; fi

section "orch: late add AFTER completion resumes over the done/ residue (no re-decompose)"
# documented flow: an add landing after the gate is picked up by the next bare
# run, which RESUMES — the done/ residue proves a lifecycle exists; the
# approved plan must not be decomposed again
echo broken > value.txt
git add -A && git commit -q -m "re-break for the late-add task"
printf 'delta task: fix value.txt so the check passes\n' > task-d.md
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh add task-d.md --auto >/dev/null 2>&1
decok=$(grep -c '"state": "DECOMPOSE_OK"' .loop/journal.jsonl || true)
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-preadd2.out" 2>&1 </dev/null || RC=$?
check "late-add run exit 0" orch-preadd 0 "$RC"
if grep -q '"state": "FLEET_RESUME"' .loop/journal.jsonl; then ok "resumed over the done/ residue"; else bad "FLEET_RESUME missing on a late add" orch-preadd; fi
check "no re-decompose on resume" orch-preadd "$decok" "$(grep -c '"state": "DECOMPOSE_OK"' .loop/journal.jsonl || true)"
check "late task done too" orch-preadd 4 "$(qcount "done")"

section "orch: an OLD contract's done/ residue never captures a new contract's first run"
# the done/failed resume arm is scoped to the CURRENT plan lifecycle by the
# .loop/decompose-approved marker (removed when a new task is defined): stale
# residue + a pre-run add must fail CLOSED at the decompose residue guard, not
# silently resume a dead orchestration against the old base
make_orch_fixture orch-oldresidue 2
mkdir -p .loop/fleet/queue/new .loop/fleet/queue/claimed .loop/fleet/queue/done \
         .loop/fleet/queue/failed .loop/fleet/queue/tmp .loop/fleet/runs
printf 'old contract task, already merged\n' > .loop/fleet/queue/done/old-a.md
printf 'SUMMARY=old contract task\nPLANNED=1\nREQS=REQ-001\nPHASE=DONE\n' > .loop/fleet/runs/old-a.env
rm -f .loop/decompose-approved      # a new definition would have removed it
printf 'charlie task: fix value.txt so the check passes\n' > task-c.md
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh add task-c.md --auto >/dev/null 2>&1
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-oldresidue.out" 2>&1 </dev/null || RC=$?
check "refused loudly (exit 2)" orch-oldresidue 2 "$RC"
if grep -q "previous fleet tasks remain" "$WORK/orch-oldresidue.out"; then ok "refusal names the residue"; else bad "wrong residue refusal" orch-oldresidue; fi
if ! grep -q '"state": "FLEET_RESUME"' .loop/journal.jsonl; then ok "no phantom resume over the old residue"; else bad "silently resumed a dead orchestration" orch-oldresidue; fi

section "orch: bare run beside a LIVE standalone supervisor refuses with zero queue pollution"
# pre-fix regression risk: fleet_inflight without the supervisor_alive arm let
# a concurrent bare run decompose + enqueue PLANNED tasks (which the live
# supervisor then merges WITHOUT the master integration gate) before dying at
# the singleton lock — the refusal must come with no side effects
make_orch_fixture orch-supbusy 2
printf 'charlie task: fix value.txt so the check passes\n' > task-c.md
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-c.md >/dev/null 2>&1
LOOP_FAKE_SLEEP=3 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run --auto --drain > "$WORK/orch-supbusy-sup.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  [ -f .loop/fleet/supervisor.lock.d/pid ] && break
  sleep 0.1; n=$((n + 1))
done
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR ./loop.sh run >"$WORK/orch-supbusy.out" 2>&1 </dev/null || RC=$?
check "bare run refused beside the live supervisor (exit 2)" orch-supbusy 2 "$RC"
if grep -q "supervisor already running" "$WORK/orch-supbusy.out"; then ok "refusal names the live supervisor"; else bad "wrong supervisor refusal: $(cat "$WORK/orch-supbusy.out")" orch-supbusy; fi
if ! grep -q '"state": "DECOMPOSE_' .loop/journal.jsonl; then ok "no decompose ran beside the supervisor"; else bad "decompose polluted the live supervisor's queue" orch-supbusy; fi
if [ "$(find .loop/fleet/runs -name '*.env' 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then ok "no PLANNED tasks enqueued (queue unpolluted)"; else bad "extra tasks appeared in the queue" orch-supbusy; fi
wait_sup "$SUP" orch-supbusy
check "supervisor drain finished green (exit 0)" orch-supbusy 0 "$RC"

section "orch: a plan id colliding with a parked MANUAL task fails loudly (never adopted)"
make_orch_fixture orch-collide 2
mkdir -p .loop/fleet/queue/new .loop/fleet/queue/claimed .loop/fleet/queue/done \
         .loop/fleet/queue/failed .loop/fleet/queue/tmp .loop/fleet/runs
printf 'manual task squatting on a plan id\n' > .loop/fleet/queue/new/part-a.md
printf 'SUMMARY=manual squatter\nSRC=(inline)\nAUTO=1\n' > .loop/fleet/runs/part-a.env
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-collide.out" 2>&1 </dev/null || RC=$?
check "collision refused (exit 4 BLOCKED)" orch-collide 4 "$RC"
check "state BLOCKED" orch-collide BLOCKED "$(cat .loop/state)"
if grep -q "collides with a queued manual task" "$WORK/orch-collide.out"; then ok "refusal names the collision"; else bad "wrong collision message" orch-collide; fi

