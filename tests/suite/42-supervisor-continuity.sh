#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- supervisor session continuity (hybrid: resume + rotate) ----------

section "supervisor session: resumed across decisions, rotated on restart and protocol miss"
make_sup_fixture fleet-session
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
ida=$(fleet_task_id alpha)
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md >/dev/null 2>&1
idb=$(fleet_task_id bravo)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$ida.env"
printf 'PLANNED=1\n' >> ".loop/fleet/runs/$idb.env"
RC=0
# both tasks escalate once and get ANSWERed: two supervisor calls in one
# supervisor process — the second must resume the first's session
LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" LOOP_FAKE_SUPERVISE=ANSWER LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain --max-parallel 1 > "$WORK/fleet-session1.out" 2>&1 </dev/null &
wait_sup $! fleet-session
check "supervisor exit 0" fleet-session 0 "$RC"
check "both tasks done" fleet-session 2 "$(qcount "done")"
check "first supervisor call fresh" fleet-session "-" "$(sed -n 1p .loop/fake-resumes)"
r2=$(sed -n 2p .loop/fake-resumes)
if [ -n "$r2" ] && [ "$r2" != "-" ]; then ok "second supervisor call resumed the session ($r2)"; else bad "second call not resumed (got '$r2')" fleet-session; fi
if sed -n 2p .loop/fake-supervise-prompts | grep -q 'session=resumed'; then ok "resumed call carries the session=resumed token"; else bad "session=resumed token missing" fleet-session; fi
if [ -f .loop/fleet/supervisor-session ]; then ok "session handle persisted"; else bad "session store missing" fleet-session; fi
# restart rotation + protocol-miss rotation: a third task escalates under a NEW
# supervisor process; the supervise reply is unparseable, so the retry must be fresh
printf 'charlie task: fix value.txt so the check passes\n' > task-c.md
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-c.md >/dev/null 2>&1
idc=$(fleet_task_id charlie)
printf 'PLANNED=1\n' >> ".loop/fleet/runs/$idc.env"
RC=0
LOOP_FAKE_SCENARIO=DECLARE_SPEC LOOP_FAKE_SUPERVISE=NOVERDICT LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-session2.out" 2>&1 </dev/null &
wait_sup $! fleet-session
check "supervisor exit 0 (task parked)" fleet-session 0 "$RC"
check "third call fresh (restart rotation)" fleet-session "-" "$(sed -n 3p .loop/fake-resumes)"
check "retry after the protocol miss fresh (rotation)" fleet-session "-" "$(sed -n 4p .loop/fake-resumes)"
if [ ! -f .loop/fleet/supervisor-session ]; then ok "session dropped after the failed decision"; else bad "session survived an unparseable verdict" fleet-session; fi

section "supervisor session: FLEET_SUPERVISOR_SESSION=0 keeps every call fresh"
make_sup_fixture fleet-sessionoff
printf 'FLEET_SUPERVISOR_SESSION=0\n' >> fleet.config.sh
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
ida=$(fleet_task_id alpha)
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md >/dev/null 2>&1
idb=$(fleet_task_id bravo)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$ida.env"
printf 'PLANNED=1\n' >> ".loop/fleet/runs/$idb.env"
RC=0
LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" LOOP_FAKE_SUPERVISE=ANSWER LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain --max-parallel 1 > "$WORK/fleet-sessionoff.out" 2>&1 </dev/null &
wait_sup $! fleet-sessionoff
check "supervisor exit 0" fleet-sessionoff 0 "$RC"
check "both tasks done" fleet-sessionoff 2 "$(qcount "done")"
check "no resumed calls with the knob off" fleet-sessionoff "" "$(grep -v '^-$' .loop/fake-resumes || true)"
if [ ! -f .loop/fleet/supervisor-session ]; then ok "no session store with the knob off"; else bad "session store written despite knob=0" fleet-sessionoff; fi

section "supervisor session: an applied REPLAN rotates the session"
make_sup_fixture fleet-sessionreplan
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SUPERVISE=REPLAN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --drain > "$WORK/fleet-sessionreplan.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "DECLARE_SPEC" > "$(fleet_wt "$id")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-sessionreplan
check "supervisor exit 0" fleet-sessionreplan 0 "$RC"
if [ -f ".loop/fleet/queue/done/fixup-1.md" ]; then ok "replacement completed"; else bad "fixup-1 not done" fleet-sessionreplan; fi
if [ ! -f .loop/fleet/supervisor-session ]; then ok "session rotated after the applied REPLAN"; else bad "session survived a plan mutation" fleet-sessionreplan; fi

section "orch: integration gate REVISE -> one supervisor fix-up -> SUCCESS"
make_orch_fixture orch-fixup 2
printf 'REVISE,APPROVE\n' > .loop/fake-review
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  LOOP_FAKE_SUPERVISE=REPLAN \
  ./loop.sh run >"$WORK/orch-fixup.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-fixup 0 "$RC"
check "state SUCCESS" orch-fixup SUCCESS "$(cat .loop/state)"
if grep -q '"state": "INTEGRATION_REVISE"' .loop/journal.jsonl; then ok "gate rejection journaled"; else bad "INTEGRATION_REVISE missing" orch-fixup; fi
if grep -q '"state": "INTEGRATION_FIXUP"' .loop/journal.jsonl; then ok "fix-up task enqueued"; else bad "INTEGRATION_FIXUP missing" orch-fixup; fi
if [ -f ".loop/fleet/queue/done/fixup-1.md" ]; then ok "fix-up task completed"; else bad "fixup-1 not done" orch-fixup; fi
if grep -q '"state": "INTEGRATION_GATE_SUCCESS"' .loop/journal.jsonl; then ok "second gate certified"; else bad "second gate missing" orch-fixup; fi
if grep -q 'fake-sup' .loop/fake-models; then ok "supervise model routed (MODEL_SUPERVISE)"; else bad "MODEL_SUPERVISE not routed: $(sort -u .loop/fake-models | tr '\n' ' ')" orch-fixup; fi

section "orch: fix-up budget 0 -> gate rejection is terminal BLOCKED (exit 4)"
make_orch_fixture orch-fixcap 2
grep -v '^FLEET_MAX_INTEGRATION_FIXUPS=' fleet.config.sh > fleet.config.tmp && mv fleet.config.tmp fleet.config.sh
printf 'FLEET_MAX_INTEGRATION_FIXUPS=0\n' >> fleet.config.sh
printf 'REVISE\n' > .loop/fake-review
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-fixcap.out" 2>&1 </dev/null || RC=$?
check "exit 4" orch-fixcap 4 "$RC"
check "state BLOCKED" orch-fixcap BLOCKED "$(cat .loop/state)"
if [ -f .loop/review-feedback.md ]; then ok "gate feedback kept"; else bad "gate feedback missing" orch-fixcap; fi

section "orch: integration gate ESCALATE skips fix-up -> NEEDS_SPEC_DECISION"
make_orch_fixture orch-escalate 2
printf 'ESCALATE\n' > .loop/fake-review
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-escalate.out" 2>&1 </dev/null || RC=$?
check "exit 3" orch-escalate 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-escalate NEEDS_SPEC_DECISION "$(cat .loop/state)"
if grep -q 'DR-GATE-' .loop/docs/decision-requests.md; then ok "escalation decision request appended"; else bad "DR-GATE entry missing" orch-escalate; fi
if ! grep -q '"state": "INTEGRATION_FIXUP"' .loop/journal.jsonl; then ok "no supervisor fix-up attempted"; else bad "fix-up ran despite escalation" orch-escalate; fi

section "orch: TERM'd orchestration resumes with a bare ./loop.sh run"
# CHAIN keeps part-b queued behind part-a, so the TERM can only land on a task
# in a resumable phase (RUNNING) — never mid-contract-generation
make_orch_fixture orch-resume 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN LOOP_FAKE_SCENARIO="CONTINUE_FIX,READY_NOW" \
  ./loop.sh run >"$WORK/orch-resume1.out" 2>&1 </dev/null &
ORCH=$!
n=0
while [ "$n" -lt $((200 * POLL_SCALE)) ]; do
  if [ "$(fleet_phase part-a)" = "RUNNING" ] \
     && [ "$(cat "$(fleet_wt part-a)/.loop/state" 2>/dev/null)" = "RUNNING" ]; then
    break
  fi
  sleep 0.2; n=$((n + 1))
done
kill "$ORCH" 2>/dev/null || true
wait_sup "$ORCH" orch-resume
check "orchestration exits 130 on TERM" orch-resume 130 "$RC"
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN LOOP_FAKE_SCENARIO="CONTINUE_FIX,READY_NOW" \
  ./loop.sh run >"$WORK/orch-resume2.out" 2>&1 </dev/null || RC=$?
check "resumed run exit 0" orch-resume 0 "$RC"
check "state SUCCESS after resume" orch-resume SUCCESS "$(cat .loop/state)"
check "both tasks done after resume" orch-resume 2 "$(qcount "done")"
if grep -q '"state": "FLEET_RESUME"' .loop/journal.jsonl; then ok "orchestration resume journaled"; else bad "FLEET_RESUME missing" orch-resume; fi

section "orch: interrupt DURING the integration gate preserves FLEET_RUNNING; bare run finishes the gate"
# E1 (critical): interrupt ≡ crash. The parent state must stay FLEET_RUNNING so
# the ONLY path off it is a finish() inside the orchestration — an interrupt can
# never strand the run in a state whose 'recovery' advice skips the gate.
make_orch_fixture orch-gate-int 2
echo 3 > .loop/fake-sleep   # parent-side calls sleep 3s (worker worktrees stay fast)
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-gate-int1.out" 2>&1 </dev/null &
ORCH=$!
n=0   # the fake records the gate prompt BEFORE sleeping -> a 3s deterministic window
while [ "$n" -lt $((600 * POLL_SCALE)) ]; do
  grep -q 'mode=gate' .loop/fake-review-prompts 2>/dev/null && break
  sleep 0.1; n=$((n + 1))
done
kill -TERM "$ORCH" 2>/dev/null || true
wait_sup "$ORCH" orch-gate-int
check "orchestration exits 130 on TERM" orch-gate-int 130 "$RC"
check "parent state PRESERVED as FLEET_RUNNING (interrupt ≡ crash)" orch-gate-int FLEET_RUNNING "$(cat .loop/state)"
check "queue already drained (nothing queued/claimed)" orch-gate-int 0 "$(( $(qcount new) + $(qcount claimed) ))"
check "both tasks done before the interrupt" orch-gate-int 2 "$(qcount "done")"
rm -f .loop/fake-sleep
# regression (fresh-clear vs orchestration resume): decide_run_mode maps
# FLEET_RUNNING to "fresh" (it only knows single-loop states), but a bare run
# RESUMES the orchestration — the run-scoped fresh-clear must not fire and
# delete this run's root artifacts on the way in
mkdir -p .loop/reports
printf '<html>decision sentinel</html>\n' > .loop/reports/decision.html
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-gate-int2.out" 2>&1 </dev/null || RC=$?
check "bare run resumes straight into the gate (exit 0)" orch-gate-int 0 "$RC"
check "state SUCCESS" orch-gate-int SUCCESS "$(cat .loop/state)"
if grep -q '"state": "FLEET_RESUME"' .loop/journal.jsonl; then ok "gate-phase resume journaled"; else bad "FLEET_RESUME missing" orch-gate-int; fi
if grep -q '"state": "INTEGRATION_GATE_SUCCESS"' .loop/journal.jsonl; then ok "the gate certified the merged result after the interrupt"; else bad "no INTEGRATION_GATE record after resume" orch-gate-int; fi
if ! grep -q 'previous fleet tasks remain' "$WORK/orch-gate-int2.out"; then
  ok "resume never hit the leftover-queue die (old bug's dead end)"
else
  bad "resume dead-ended on the leftover-queue die" orch-gate-int
fi
if [ -f .loop/reports/decision.html ]; then ok "orchestration resume kept the run's root artifacts (no fresh-clear)"; else bad "bare-run resume fresh-cleared the root artifacts" orch-gate-int; fi
rm -f .loop/reports/decision.html

section "orch: supervisor restart adopts a SUPERVISE_PENDING task (worktree preserved)"
# regression: SUPERVISE_PENDING was missing from recover_claimed's phase list, so
# a restart fell into the mid-bootstrap catch-all and DESTROYED the escalated
# worker's worktree + branch (committed iterations, decision request) as
# STALE_BOOTSTRAP — then re-queued it from scratch, silently burning the budget.
make_orch_fixture orch-suppend 2
echo 10 > .loop/fake-supervise-sleep   # prompt marker is written first; only the supervise call waits
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SUPERVISE=ANSWER \
  LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/orch-suppend1.out" 2>&1 </dev/null &
ORCH=$!
sid=""
n=0   # Wait for BOTH the persistent phase and the fake's pre-sleep prompt marker:
      # this proves the parent is alive inside supervise_task, rather than racing
      # a stale SUPERVISE_PENDING file after the process has already exited.
while [ "$n" -lt $((600 * POLL_SCALE)) ]; do
  kill -0 "$ORCH" 2>/dev/null || break
  for cand in part-a part-b; do
    if [ "$(fleet_phase "$cand")" = "SUPERVISE_PENDING" ] \
       && grep -q "/loop-supervise task=$cand" .loop/fake-supervise-prompts 2>/dev/null \
       && kill -0 "$ORCH" 2>/dev/null; then
      sid="$cand"; break 2
    fi
  done
  sleep 0.2; n=$((n + 1))
done
if [ -z "$sid" ]; then
  bad "supervise call never reached the deterministic in-flight marker" orch-suppend
fi
if ! kill -TERM "$ORCH" 2>/dev/null; then
  bad "orchestration exited before TERM could be delivered" orch-suppend
fi
wait_sup "$ORCH" orch-suppend
check "orchestration exits 130 on TERM" orch-suppend 130 "$RC"
check "phase left SUPERVISE_PENDING by the kill" orch-suppend SUPERVISE_PENDING "$(fleet_phase "$sid")"
swt=$(fleet_wt "$sid")
if [ -d "$swt" ]; then ok "escalated worker's worktree present before the restart"; else bad "worktree missing before restart" orch-suppend; fi
rm -f .loop/fake-supervise-sleep
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SUPERVISE=ANSWER \
  LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/orch-suppend2.out" 2>&1 </dev/null || RC=$?
check "restarted orchestration exit 0" orch-suppend 0 "$RC"
check "state SUCCESS" orch-suppend SUCCESS "$(cat .loop/state)"
check "both tasks done" orch-suppend 2 "$(qcount "done")"
if grep '"event": "ADOPTED"' .loop/fleet/journal.jsonl | grep -q 'SUPERVISE_PENDING'; then ok "restart adopted the SUPERVISE_PENDING task"; else bad "no SUPERVISE_PENDING adoption row" orch-suppend; fi
if ! grep -q 'STALE_BOOTSTRAP' .loop/fleet/journal.jsonl; then ok "no STALE_BOOTSTRAP destruction (worktree survived)"; else bad "restart destroyed the escalated task as STALE_BOOTSTRAP" orch-suppend; fi
if grep -q '"event": "SUPERVISE_ANSWER"' .loop/fleet/journal.jsonl; then ok "the adopted task got its supervisor decision"; else bad "SUPERVISE_ANSWER missing after adoption" orch-suppend; fi

section "fleet: a crash between the requeue flip and the queue mv is completed on restart"
# regression: the merge-conflict redo can crash between its PHASE=queued flip and
# the claimed->new mv, leaving claimed/<id> with phase 'queued'. The restart used
# to destroy that as STALE_BOOTSTRAP — it must instead finish the interrupted mv
# and let the tick claim it fresh. (A claim that crashes mid-bootstrap carries no
# phase and correctly stays on the STALE_BOOTSTRAP path — not this one.)
make_fleet_fixture resume-claimed-queued
./loop.sh fleet add task-a.md >/dev/null
cqid=$(fleet_task_id alpha)
printf 'PHASE=queued\n' >> ".loop/fleet/runs/$cqid.env"                    # the redo's flip landed...
mv ".loop/fleet/queue/new/$cqid.md" ".loop/fleet/queue/claimed/$cqid.md"   # ...but its claimed->new mv never did
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run --auto --drain > "$WORK/resume-claimed-queued.out" 2>&1 </dev/null &
wait_sup $! resume-claimed-queued
check "drain exit 0" resume-claimed-queued 0 "$RC"
if [ -f ".loop/fleet/queue/done/$cqid.md" ]; then ok "requeued task ran to done"; else bad "task not done ($(fleet_phase "$cqid"))" resume-claimed-queued; fi
if grep -q '"event": "ADOPTED_REQUEUE"' .loop/fleet/journal.jsonl; then ok "restart completed the interrupted requeue"; else bad "ADOPTED_REQUEUE missing" resume-claimed-queued; fi
if ! grep -q 'STALE_BOOTSTRAP' .loop/fleet/journal.jsonl; then ok "not misclassified as STALE_BOOTSTRAP"; else bad "requeue-window task destroyed as STALE_BOOTSTRAP" resume-claimed-queued; fi

section "orch: interrupted enqueue repairs the queue from the approved plan on resume"
# E1 partial-enqueue: .loop/fleet/enqueue-pending marks an enqueue that never
# finished; the resume re-derives the missing planned tasks deterministically
# (no model call) and only dispatches when the marker hash matches the plan.
make_orch_fixture orch-enqueue-int 2
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR ./loop.sh decompose >"$WORK/orch-enq-dec.out" 2>&1 </dev/null || true
if [ -s .loop/decompose-approved ] && [ -f .loop/fleet/plan/part-a.body ]; then
  ok "plan materialized without dispatching (decompose preview)"
else
  bad "decompose preview did not leave a plan to forge from" orch-enqueue-int
fi
mkdir -p .loop/fleet/queue/new .loop/fleet/queue/claimed .loop/fleet/queue/done \
         .loop/fleet/queue/failed .loop/fleet/queue/tmp .loop/fleet/runs
cp .loop/fleet/plan/part-a.body .loop/fleet/queue/new/part-a.md
cat > .loop/fleet/runs/part-a.env <<EOF
SUMMARY=alpha part - fix value.txt
SRC=task-plan
AUTO=1
PLANNED=1
REQS=REQ-001
SCOPE=value.txt only
EOF
cat .loop/decompose-approved > .loop/fleet/enqueue-pending
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-enq.out" 2>&1 </dev/null || RC=$?
check "repaired orchestration exit 0" orch-enqueue-int 0 "$RC"
check "state SUCCESS" orch-enqueue-int SUCCESS "$(cat .loop/state)"
check "both planned tasks done (part-b re-derived)" orch-enqueue-int 2 "$(qcount "done")"
if grep -q 'FLEET_ENQUEUE_REPAIR' .loop/journal.jsonl; then ok "queue repair journaled"; else bad "FLEET_ENQUEUE_REPAIR missing" orch-enqueue-int; fi

section "orch: enqueue marker with a STALE plan hash fails closed to a human"
make_orch_fixture orch-enqueue-stale 2
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR ./loop.sh decompose >/dev/null 2>&1 </dev/null || true
mkdir -p .loop/fleet/queue/new .loop/fleet/queue/claimed .loop/fleet/queue/done \
         .loop/fleet/queue/failed .loop/fleet/queue/tmp .loop/fleet/runs
cp .loop/fleet/plan/part-a.body .loop/fleet/queue/new/part-a.md
cat > .loop/fleet/runs/part-a.env <<EOF
SUMMARY=alpha part - fix value.txt
SRC=task-plan
AUTO=1
PLANNED=1
REQS=REQ-001
SCOPE=value.txt only
EOF
echo deadbeef > .loop/fleet/enqueue-pending
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-enq-stale.out" 2>&1 </dev/null || RC=$?
check "stale marker refused (exit 3)" orch-enqueue-stale 3 "$RC"
check "state NEEDS_SPEC_DECISION (never dispatch an underivable plan)" orch-enqueue-stale NEEDS_SPEC_DECISION "$(cat .loop/state)"
check "nothing dispatched to done/" orch-enqueue-stale 0 "$(qcount "done")"
if ! grep -q 'FLEET_ENQUEUE_REPAIR' .loop/journal.jsonl; then ok "no repair claimed on a hash mismatch"; else bad "repair ran on a stale hash" orch-enqueue-stale; fi

section "orch: --single/--fresh refuse beside an in-flight fleet; a parked queue proceeds"
# the refusal keys on fleet_inflight (a STARTED lifecycle: FLEET_RUNNING,
# claimed/planned tasks, done/failed residue) — never on a bare non-empty
# queue: tasks added BEFORE the first run are a parked queue, and refusing
# them left no way to ever run (the pre-fix no-escape bug)
make_fixture guard-flags
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh add "guard test task" >/dev/null 2>&1
echo FLEET_RUNNING > .loop/state   # forge: an interrupted orchestration
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run --single >"$WORK/guard-single.out" 2>&1 </dev/null || RC=$?
check "run --single refused (exit 2)" guard-flags 2 "$RC"
if grep -q "orchestration is in flight" "$WORK/guard-single.out"; then ok "refusal names the reason"; else bad "wrong refusal message" guard-flags; fi
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run --fresh >"$WORK/guard-fresh.out" 2>&1 </dev/null || RC=$?
check "run --fresh refused (exit 2)" guard-flags 2 "$RC"
rm -f .loop/state                  # back to the parked pre-start queue
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run --single >"$WORK/guard-parked.out" 2>&1 </dev/null || RC=$?
check "run --single proceeds beside a parked queue (exit 0)" guard-flags 0 "$RC"
check "state SUCCESS" guard-flags SUCCESS "$(cat .loop/state)"
check "parked task untouched by the in-place run" guard-flags 1 "$(qcount new)"
if grep -q "stay parked" "$WORK/guard-parked.out"; then ok "parked queue called out, not silently ignored"; else bad "no parked-queue warning" guard-flags; fi
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run --fresh >"$WORK/guard-parked2.out" 2>&1 </dev/null || RC=$?
check "run --fresh proceeds beside a parked queue (exit 0)" guard-flags 0 "$RC"
if grep -q "stay parked" "$WORK/guard-parked2.out"; then ok "fresh run also calls out the parked queue"; else bad "no parked warning on --fresh" guard-flags; fi

section "fleet: planned tasks redo a merge conflict once from the merged HEAD"
make_sup_fixture fleet-credo
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
ida=$(fleet_task_id alpha)
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md >/dev/null 2>&1
idb=$(fleet_task_id bravo)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$ida.env"
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$idb.env"
base0=$(git rev-parse HEAD)   # pre-fleet base: the redo must NOT keep this as its task baseline
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --drain --max-parallel 2 > "$WORK/fleet-credo.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ -n "$ida" ] && [ -n "$idb" ] \
    && [ "$(fleet_phase "$ida")" = "PENDING_APPROVAL" ] \
    && [ "$(fleet_phase "$idb")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "READY_NOW" > "$(fleet_wt "$ida")/.loop/fake-scenario"
echo "READY_ALT" > "$(fleet_wt "$idb")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve --all </dev/null >/dev/null 2>&1
# the loser is requeued (MERGE_RETRIES=1) and — being a manually-approved task —
# waits in PENDING_APPROVAL again; approve the redo (winner-agnostic).
# Orchestrated tasks carry AUTO=1, so the real flow re-approves automatically.
rid=""
n=0
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  for t in "$ida" "$idb"; do
    if grep -q '^MERGE_RETRIES=1' ".loop/fleet/runs/$t.env" 2>/dev/null; then rid="$t"; fi
  done
  if [ -n "$rid" ] && [ "$(fleet_phase "$rid")" = "PENDING_APPROVAL" ]; then break; fi
  sleep 0.2; n=$((n + 1))
done
if [ -n "$rid" ]; then ok "loser requeued for a redo ($([ "$rid" = "$ida" ] && echo alpha || echo bravo))"; else bad "no redo detected" fleet-credo; fi
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$rid" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-credo
check "supervisor exit 0" fleet-credo 0 "$RC"
check "both tasks done (loser redone, none failed)" fleet-credo 2 "$(qcount "done")"
check "failed queue empty" fleet-credo 0 "$(qcount failed)"
if grep -q '"event": "MERGE_CONFLICT_REDO"' .loop/fleet/journal.jsonl; then ok "redo journaled"; else bad "MERGE_CONFLICT_REDO missing" fleet-credo; fi
check "conflicting branch archived for autopsy" fleet-credo 1 "$(git branch --list 'loop/*-conflict-1' | wc -l | tr -d ' ')"
check "parent value converged" fleet-credo fixed "$(cat value.txt)"
# the redo removed the old worktree; its off-tree slot must have gone with it,
# so the redo's fresh run records a NEW task baseline that CONTAINS the
# winner's merged work (the recorded ref is a worktree-local descendant of the
# merge commit — contract-gen commits sit on top — so assert ancestry, which
# is still strictly stronger than "differs from the stale pre-fleet ref")
rwt=$(fleet_wt "$rid")
if [ -n "$rid" ] && [ -d "$rwt" ]; then
  winner=$([ "$rid" = "$ida" ] && echo "$idb" || echo "$ida")
  expect=$(git log --first-parent --merges --format='%H %s' \
    | awk -v pat="fleet: merge $winner " 'found { next } index($0, pat) { split($0, a, " "); print a[1]; found=1 }')
  rcommon=$(cd "$rwt" && git rev-parse --git-common-dir)
  case "$rcommon" in /*) ;; *) rcommon="$rwt/$rcommon" ;; esac
  rgitdir=$(cd "$rwt" && git rev-parse --absolute-git-dir)
  tref=$(cat "$LOOP_APPROVAL_HOME/$(printf '%s' "$rcommon" | sha256)/$(printf '%s' "$rgitdir" | sha256)/task-start-ref" 2>/dev/null || echo missing)
  if [ -n "$expect" ] && [ "$tref" != missing ] \
     && git merge-base --is-ancestor "$expect" "$tref" 2>/dev/null; then
    ok "redo task baseline contains the winner's merge commit"
  else
    bad "redo task baseline '$tref' does not descend from the winner's merge commit '$expect' (pre-fleet base was $base0)" fleet-credo
  fi
else
  bad "redo worktree missing for the slot assertion" fleet-credo
fi

section "update: fleet.config.sh self-heals a missing key (append), idempotently"
make_fixture drift-note
grep -v '^FLEET_DECOMPOSE=' fleet.config.sh > fleet.config.tmp && mv fleet.config.tmp fleet.config.sh
if grep -qE '^FLEET_DECOMPOSE=' fleet.config.sh; then bad "precondition: FLEET_DECOMPOSE not removed" drift-note; else ok "precondition: FLEET_DECOMPOSE removed"; fi
cd "$WORK"
# capture, then bash pattern-match — `update | grep -q` would SIGPIPE update
# under pipefail (same pitfall as the git-log note below). fleet.config.sh is
# outside every approval hash, so update APPENDS the missing key from the kit
# (loop.config.sh, which is approval-bound, still only gets a print-only note).
upd_out=$("$ROOT/bin/loop.sh" update "$WORK/drift-note" 2>&1) || true
case "$upd_out" in
  *"added new fleet.config.sh key"*) ok "missing fleet.config.sh key reported as added" ;;
  *) bad "fleet.config.sh self-heal note missing" drift-note ;;
esac
check "FLEET_DECOMPOSE re-added from the kit" drift-note 1 "$(grep -cE '^FLEET_DECOMPOSE=' "$WORK/drift-note/fleet.config.sh")"
# idempotent: a second update must not re-append
upd_out2=$("$ROOT/bin/loop.sh" update "$WORK/drift-note" 2>&1) || true
case "$upd_out2" in
  *"added new fleet.config.sh key"*) bad "second update re-added keys (not idempotent)" drift-note ;;
  *) ok "second update adds nothing (idempotent)" ;;
esac
check "still exactly one FLEET_DECOMPOSE line" drift-note 1 "$(grep -cE '^FLEET_DECOMPOSE=' "$WORK/drift-note/fleet.config.sh")"

section "config: FLEET_MAX_* defaults agree across code fallback, README, fleet.config.sh"
# guard the three-way mirror so a future edit to one place can't silently diverge
# (the exact drift Fix B closed: code fallback that disagreed with the shipped value)
mirror_ok=1
for key in FLEET_MAX_PARALLEL FLEET_MAX_TASKS FLEET_MAX_REPLAN_TASKS FLEET_MAX_PLAN_REVISIONS; do
  shipped=$(grep -E "^${key}=" "$ROOT/kit/fleet.config.sh" | tail -1 | sed -E 's/[^0-9]//g')
  badfb=$(grep -oE "fcfg ${key} [0-9]+" "$ROOT/bin/loop.sh" | awk -v s="$shipped" '$3!=s{print}')
  readme_n=$(grep -E "^\| .${key}. \|" "$ROOT/README.md" | head -1 | awk -F'|' '{gsub(/[^0-9]/,"",$3); print $3}')
  [ -n "$shipped" ] || { mirror_ok=0; echo "  $key: no shipped value parsed"; }
  [ -z "$badfb" ] || { mirror_ok=0; echo "  $key: fcfg fallback(s) != shipped $shipped: $badfb"; }
  [ "$readme_n" = "$shipped" ] || { mirror_ok=0; echo "  $key: README=$readme_n != shipped=$shipped"; }
done
if [ "$mirror_ok" = 1 ]; then ok "config default 3-way mirror agrees"; else bad "config default 3-way mirror drift" config-mirror; fi

section "orch: a configured USD cap also stops parent-side orchestration spending"
make_orch_fixture orch-budget 2
grep -v '^MAX_COST_USD=' loop.config.sh > loop.config.tmp && mv loop.config.tmp loop.config.sh
printf 'MAX_COST_USD=0.02\n' >> loop.config.sh
./loop.sh approve >/dev/null
RC=0
LOOP_FAKE_COST=0.05 LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh run >"$WORK/orch-budget.out" 2>&1 </dev/null || RC=$?
check "exit 5" orch-budget 5 "$RC"
check "state BUDGET_EXCEEDED" orch-budget BUDGET_EXCEEDED "$(cat .loop/state)"
if grep -q 'during orchestration' "$WORK/orch-budget.out"; then ok "stopped at the orchestration budget check"; else bad "wrong budget stop point" orch-budget; fi

section "orch: MAX_RUN_SECONDS fires MID-DISPATCH (per tick, not only per round)"
# E12e: the wall cap used to be checked once per round — a single round's
# dispatch+gate could overrun it indefinitely. LOOP_FAKE_SLEEP pads every worker
# call so dispatch is provably still in flight when the 1s cap trips.
make_orch_fixture orch-wallcap 2
printf 'MAX_RUN_SECONDS=1\n' >> loop.config.sh
./loop.sh approve >/dev/null
RC=0
LOOP_FAKE_SLEEP=1 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-wallcap.out" 2>&1 </dev/null || RC=$?
check "exit 5" orch-wallcap 5 "$RC"
check "state BUDGET_EXCEEDED" orch-wallcap BUDGET_EXCEEDED "$(cat .loop/state)"
if grep -q 'MAX_RUN_SECONDS' "$WORK/orch-wallcap.out"; then ok "stop reason names MAX_RUN_SECONDS"; else bad "no MAX_RUN_SECONDS in the reason" orch-wallcap; fi
check "stopped mid-dispatch (nothing reached done/)" orch-wallcap 0 "$(qcount "done")"
if ! grep -q '"state": "INTEGRATION_GATE_' .loop/journal.jsonl; then
  ok "no integration gate ran (the cap fired inside the dispatch loop)"
else
  bad "gate ran despite the mid-dispatch cap" orch-wallcap
fi

