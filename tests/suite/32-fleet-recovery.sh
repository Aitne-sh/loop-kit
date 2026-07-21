#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "fleet: TERM'd supervisor -> first restart recovers the interrupted or still-live run"
make_fleet_fixture fleet-term
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="CONTINUE_FIX,CONTINUE_FIX,READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/fleet-term1.out" 2>&1 </dev/null &
SUP=$!
id=""
n=0
# TERM must land while loop.sh is mid-iteration WITH its trap installed — see
# the crash test above: wt-state RUNNING is the deterministic marker for that
# window (trap set, >=2 fake iterations of runway left before SUCCESS)
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  id=$(fleet_task_id alpha)
  if [ -n "$id" ] && [ "$(fleet_phase "$id")" = "RUNNING" ] \
     && [ "$(cat "$(fleet_wt "$id")/.loop/state" 2>/dev/null)" = "RUNNING" ]; then
    break
  fi
  sleep 0.2; n=$((n + 1))
done
kill -TERM "$SUP" 2>/dev/null || true
wait_sup "$SUP" fleet-term
check "supervisor exits 130 on TERM" fleet-term 130 "$RC"
sleep 1
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-term2.out" 2>&1 </dev/null &
wait_sup $! fleet-term
check "restarted supervisor exit 0" fleet-term 0 "$RC"
# The supervisor signals workers on TERM, but deliberately does not wait forever
# for every worker to finish its own interrupt cleanup. On restart, recover_claimed
# therefore has two correct paths: RESUME a now-dead interrupted worker, or ADOPT
# one that is still live. Assert the durable recovery journal (plus completion
# below), not one console string emitted by only the RESUME branch.
if grep '"event": "RESUME"' .loop/fleet/journal.jsonl | grep -q 'auto-resume at supervisor start'; then
  ok "interrupted run auto-resumed on first restart"
elif grep '"event": "ADOPTED"' .loop/fleet/journal.jsonl | grep -q 'phase=RUNNING'; then
  ok "still-live interrupted run adopted on first restart"
else
  bad "first restart neither resumed nor adopted the interrupted run" fleet-term
fi
check "task completed after recovery" fleet-term fixed "$(cat value.txt)"

section "fleet: 'fleet stop' is honored across restarts (no recovery auto-resume)"
# E7: a human's stop used to be silently un-done by the next supervisor's
# crash-recovery auto-resume. STOPPED_BY=human parks the task in failed/ instead
# (STOP_HONORED); only an explicit resume (the human's decision) clears it.
make_fleet_fixture fleet-stop-honored
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="CONTINUE_FIX,BAD_FIX,BAD_FIX,READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md --auto > "$WORK/fleet-stop1.out" 2>&1 </dev/null &
SUP=$!
id=""
n=0   # stop only once the worker is mid-run with its trap installed (see fleet-term)
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  id=$(fleet_task_id alpha)
  if [ -n "$id" ] && [ "$(fleet_phase "$id")" = "RUNNING" ] \
     && [ "$(cat "$(fleet_wt "$id")/.loop/state" 2>/dev/null)" = "RUNNING" ]; then
    break
  fi
  sleep 0.2; n=$((n + 1))
done
./loop.sh fleet stop "$id" >/dev/null 2>&1 || true
n=0   # the live supervisor's next ticks reap the stopped worker and park it
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  [ -f ".loop/fleet/queue/failed/$id.md" ] && break
  sleep 0.2; n=$((n + 1))
done
if [ -f ".loop/fleet/queue/failed/$id.md" ]; then ok "human-stopped task parked in failed/"; else bad "task not parked (phase: $(fleet_phase "$id"))" fleet-stop-honored; fi
check "parked with RESULT INTERRUPTED" fleet-stop-honored INTERRUPTED "$(fleet_result "$id")"
if grep -q 'STOP_HONORED' .loop/fleet/journal.jsonl; then ok "stop honored + journaled"; else bad "STOP_HONORED missing" fleet-stop-honored; fi
kill -TERM "$SUP" 2>/dev/null || true
wait_sup "$SUP" fleet-stop-honored
check "supervisor exits 130 on TERM" fleet-stop-honored 130 "$RC"
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-stop2.out" 2>&1 </dev/null &
wait_sup $! fleet-stop-honored
check "restarted drain exits 0 with the task still parked" fleet-stop-honored 0 "$RC"
if [ -f ".loop/fleet/queue/failed/$id.md" ] && ! grep -q '"event": "RESUME"' .loop/fleet/journal.jsonl; then
  ok "restart did NOT auto-resume the human-stopped task"
else
  bad "human stop was un-done by recovery" fleet-stop-honored
fi
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet resume "$id" >/dev/null 2>&1
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-stop3.out" 2>&1 </dev/null || RC=$?
check "explicit resume + drain completes (exit 0)" fleet-stop-honored 0 "$RC"
check "task done" fleet-stop-honored 1 "$(qcount "done")"
if [ -z "$(grep -E '^STOPPED_BY=' ".loop/fleet/runs/$id.env" | tail -1 | cut -d= -f2-)" ]; then
  ok "resume cleared the STOPPED_BY marker"
else
  bad "STOPPED_BY marker left set after resume" fleet-stop-honored
fi

section "fleet: refuses to run beside a LIVE single loop; stale RUNNING never blocks"
# E5/G7a: a root loop and the fleet must not run together (split-brain). The
# refusal keys on a pid-verified live process, never on the state file alone.
make_fixture fleet-splitbrain
LOOP_FAKE_SLEEP=3 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="CONTINUE_FIX,READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run > "$WORK/splitbrain-root.out" 2>&1 </dev/null &
ROOT_RUN=$!
n=0   # the pidfile + RUNNING state mark the single loop provably live
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  [ -f .loop/run.pid ] && [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ] && break
  sleep 0.1; n=$((n + 1))
done
# enqueue the probe only NOW: a task queued before `run` starts would route the
# bare run into an orchestration resume instead of the classic single loop
./loop.sh fleet add "splitbrain probe: fix value.txt so the check passes" >/dev/null 2>&1
idp=$(fleet_task_id splitbrain)
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain </dev/null 2>&1) || RC=$?
check "fleet run refused beside the live loop (exit 2)" fleet-splitbrain 2 "$RC"
case "$out" in
  *"single-loop run is active"*) ok "refusal names the live single-loop run" ;;
  *) bad "wrong refusal: $out" fleet-splitbrain ;;
esac
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh resume "$idp" </dev/null 2>&1) || RC=$?
check "resume <id> refused beside the live loop (exit 2)" fleet-splitbrain 2 "$RC"
case "$out" in
  *"single-loop run is active"*) ok "resume refusal names the live single-loop run" ;;
  *) bad "wrong resume refusal: $out" fleet-splitbrain ;;
esac
wait_sup "$ROOT_RUN" fleet-splitbrain
check "single loop finished green (exit 0)" fleet-splitbrain 0 "$RC"
if [ ! -f .loop/run.pid ]; then ok "finish removed the pidfile"; else bad "run.pid left after finish" fleet-splitbrain; fi
# stale-state half: a crash leaves RUNNING + a dead pid — warn and proceed
echo broken > value.txt
git add -A && git commit -q -m "re-break for the probe task"
echo RUNNING > .loop/state
echo 999999 > .loop/run.pid
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run --auto --drain > "$WORK/splitbrain-stale.out" 2>&1 </dev/null || RC=$?
check "stale RUNNING state does not block the fleet (exit 0)" fleet-splitbrain 0 "$RC"
if grep -qi 'stale' "$WORK/splitbrain-stale.out"; then ok "stale state called out honestly"; else bad "no stale-state warning" fleet-splitbrain; fi
check "probe task completed" fleet-splitbrain 1 "$(qcount "done")"

section "start/auto beside a LIVE run: routed to the queue, memory never reset"
# G7b: `start` beside a verified-live run must NEVER archive+reset the running
# loop's memory (split-brain: the live loop would read a swapped contract and
# an empty progress log). It routes the instruction to the fleet queue (same
# as ./loop.sh add) and exits 0; the queue is processed after this run.
make_fixture start-routes
cp .loop/docs/product-contract.md "$WORK/sr.contract"
cp .loop/docs/progress.md "$WORK/sr.progress"
LOOP_FAKE_SLEEP=3 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="CONTINUE_FIX,READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run > "$WORK/start-routes-root.out" 2>&1 </dev/null &
ROOT_RUN=$!
n=0
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  [ -f .loop/run.pid ] && [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ] && break
  sleep 0.1; n=$((n + 1))
done
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh start "follow-up: also update the docs" </dev/null 2>&1) || RC=$?
check "start routed to the queue (exit 0)" start-routes 0 "$RC"
case "$out" in
  *"routing this instruction to the task queue"*) ok "routing called out honestly" ;;
  *) bad "no routing note: $out" start-routes ;;
esac
check "instruction queued as a fleet task" start-routes 1 "$(qcount new)"
if cmp -s .loop/docs/product-contract.md "$WORK/sr.contract"; then ok "contract byte-identical under the live run"; else bad "contract changed under the live run" start-routes; fi
if cmp -s .loop/docs/progress.md "$WORK/sr.progress"; then ok "progress byte-identical under the live run"; else bad "progress reset under the live run" start-routes; fi
if [ ! -d .loop/docs/run-archive ]; then ok "no archive entry created"; else bad "run-archive created by a routed start" start-routes; fi
if ! grep -q '"state": "MEMORY_RESET"' .loop/journal.jsonl; then ok "no memory reset journaled"; else bad "MEMORY_RESET journaled by a routed start" start-routes; fi
# the add hint beside a live single loop: honest, no fleet-run misdirection
# (fleet run would be refused as split-brain while this loop lives)
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh add "second follow-up while running" </dev/null 2>&1) || RC=$?
check "add beside the live loop (exit 0)" start-routes 0 "$RC"
case "$out" in
  *"will NOT pick this task up"*) ok "hint says the single loop ignores the queue" ;;
  *) bad "hint not honest about a mid-run add: $out" start-routes ;;
esac
case "$out" in
  *"start one: ./loop.sh fleet run"*) bad "hint still misdirects to fleet run (split-brain refused)" start-routes ;;
  *) ok "no fleet-run misdirection in the hint" ;;
esac
# auto "<instr>" routes too, and rides the queue with --auto (nobody is around
# to approve a sub-contract later)
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh auto "third follow-up while running" </dev/null 2>&1) || RC=$?
check "auto <instr> routed to the queue (exit 0)" start-routes 0 "$RC"
idt=$(fleet_task_id third)
if [ -n "$idt" ] && grep -q '^AUTO=1' ".loop/fleet/runs/$idt.env"; then ok "auto-routed task rides the queue with --auto"; else bad "AUTO=1 missing on the auto-routed task" start-routes; fi
# run --fresh beside the live loop: refused before ANY side effect
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run --fresh </dev/null 2>&1) || RC=$?
check "run --fresh refused beside the live loop (exit 2)" start-routes 2 "$RC"
case "$out" in
  *"a run is already active"*) ok "fresh refusal names the live run" ;;
  *) bad "wrong fresh refusal: $out" start-routes ;;
esac
wait_sup "$ROOT_RUN" start-routes
check "live run finished green despite the routed traffic (exit 0)" start-routes 0 "$RC"
# stale RUNNING (dead pid) + start: proceeds into a normal definition (the
# queue is emptied first — queued tasks block a new definition by design)
rm -f .loop/fleet/queue/new/*.md .loop/fleet/runs/*.env
echo RUNNING > .loop/state
echo 999999 > .loop/run.pid
RC=0
LOOP_FAKE_CONTRACT=READY LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh start "brand new task after the crash" >"$WORK/start-stale.out" 2>&1 </dev/null || RC=$?
check "stale RUNNING does not block start (exit 0)" start-routes 0 "$RC"
if grep -q "stale after a crash" "$WORK/start-stale.out"; then ok "stale state called out honestly"; else bad "no stale-state warning from start" start-routes; fi
if grep -q '"state": "MEMORY_RESET"' .loop/journal.jsonl; then ok "normal definition reset the old memory"; else bad "MEMORY_RESET missing after stale start" start-routes; fi
if grep -q 'auto-generated' .loop/docs/product-contract.md; then ok "new definition written"; else bad "new contract missing after stale start" start-routes; fi
# parked queue (nothing live) + start: still refused — defining a new master
# contract over a pending queue is ambiguous, never silent
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh add "parked task" >/dev/null 2>&1
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh start "another task" </dev/null 2>&1) || RC=$?
check "start refused over a parked queue (exit 2)" start-routes 2 "$RC"
case "$out" in
  *"fleet tasks are queued"*) ok "refusal names the queued tasks" ;;
  *) bad "wrong parked refusal: $out" start-routes ;;
esac
rm -f .loop/fleet/queue/new/*.md .loop/fleet/runs/*.env
echo FLEET_RUNNING > .loop/state
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh start "yet another task" </dev/null 2>&1) || RC=$?
check "start refused over an interrupted orchestration (exit 2)" start-routes 2 "$RC"
rm -f .loop/state

section "start/second-run DURING iteration-0 planning: run.pid seeded, memory preserved"
# Regression for the run.pid write-timing window (run-pid-window-findings.md):
# cmd_run set .loop/state=RUNNING but wrote .loop/run.pid only AFTER the slow
# iteration-0 planning call, so throughout planning a fresh run was RUNNING yet
# invisible to single_loop_alive — every split-brain guard silently passed and a
# concurrent `start` archived+reset the live run's memory (or a second `run`
# started beside it). The fix seeds run.pid the instant state flips. Unlike the
# block above (which waits for run.pid and so steps PAST the window), this test
# fires the probes INSIDE it: it waits for state==RUNNING with the plan call in
# flight and deliberately does NOT wait for run.pid. Fails on the old ordering.
make_fixture start-iter0
# the stock fixture ships a NON-template plan (iter-0 planning is skipped); a
# template plan forces the /loop-plan call, whose fake-sleep is the window
printf '<!-- TEMPLATE -->\n# Implementation Plan\n' > .loop/docs/implementation-plan.md
git add -A && git commit -q -m "template plan for the iter-0 window test"
./loop.sh approve >/dev/null
cp .loop/docs/product-contract.md "$WORK/iw.contract"
cp .loop/docs/progress.md "$WORK/iw.progress"
echo 4 > .loop/fake-sleep           # a wide, deterministic iter-0 planning window
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run > "$WORK/start-iter0-root.out" 2>&1 </dev/null &
ROOT_RUN=$!
n=0
while [ "$n" -lt $((400 * POLL_SCALE)) ]; do
  # in flight = the plan model is logged (fake writes it BEFORE its sleep) and
  # state is RUNNING; NOT gated on run.pid — that is the window the old code left
  # blind (in the old ordering run.pid does not exist yet at this point)
  [ "$(cat .loop/state 2>/dev/null)" = "RUNNING" ] \
    && grep -q 'fake-plan' .loop/fake-models 2>/dev/null && break
  sleep 0.05; n=$((n + 1))
done
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh start "iter-0 window follow-up" </dev/null 2>&1) || RC=$?
check "start routed during iter-0 planning (exit 0)" start-iter0 0 "$RC"
case "$out" in
  *"routing this instruction to the task queue"*) ok "iter-0 start routed, not reset" ;;
  *) bad "iter-0 start not routed — run.pid invisible in the window: $out" start-iter0 ;;
esac
check "iter-0 instruction queued as a fleet task" start-iter0 1 "$(qcount new)"
if cmp -s .loop/docs/product-contract.md "$WORK/iw.contract"; then ok "contract intact during iter-0 planning"; else bad "contract reset during the iter-0 window" start-iter0; fi
if cmp -s .loop/docs/progress.md "$WORK/iw.progress"; then ok "progress intact during iter-0 planning"; else bad "progress reset during the iter-0 window" start-iter0; fi
if ! grep -q '"state": "MEMORY_RESET"' .loop/journal.jsonl; then ok "no memory reset during the iter-0 window"; else bad "MEMORY_RESET journaled in the iter-0 window" start-iter0; fi
# a second `run` in the same window is refused, not started beside the first
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run </dev/null 2>&1) || RC=$?
check "second run refused during iter-0 planning (exit 2)" start-iter0 2 "$RC"
case "$out" in
  *"a run is already active"*) ok "second run names the live iter-0 run" ;;
  *) bad "second run not refused in the iter-0 window: $out" start-iter0 ;;
esac
rm -f .loop/fake-sleep              # let the background run drain fast to green
wait_sup "$ROOT_RUN" start-iter0
check "iter-0-window run finished green despite the probes (exit 0)" start-iter0 0 "$RC"
if [ ! -f .loop/run.pid ]; then ok "finish removed the pidfile"; else bad "run.pid left after finish" start-iter0; fi

section "start beside a LIVE fleet supervisor: routed to the queue"
make_fleet_fixture start-fleetlive
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
LOOP_FAKE_SLEEP=3 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run --auto --drain > "$WORK/start-fleetlive.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  [ "$(qcount claimed)" -ge 1 ] && break
  sleep 0.2; n=$((n + 1))
done
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh start "follow-up: fix value.txt so the check passes" </dev/null 2>&1) || RC=$?
check "start routed beside the live supervisor (exit 0)" start-fleetlive 0 "$RC"
case "$out" in
  *"a fleet orchestration is LIVE"*) ok "routing names the live orchestration" ;;
  *) bad "no live-orchestration note: $out" start-fleetlive ;;
esac
wait_sup "$SUP" start-fleetlive
check "drain finished green with the routed task (exit 0)" start-fleetlive 0 "$RC"
check "routed task processed by the drain" start-fleetlive 0 "$(qcount new)"

section "bare ./loop.sh never routes: backstop refuses beside a live run"
# a leftover loop-instruction.md must never silently enqueue itself; with a
# live run and no contract, guard_new_definition's backstop refuses instead
make_fixture start-backstop nocontract
printf 'instruction from a file\n' > loop-instruction.md
echo RUNNING > .loop/state
echo $$ > .loop/run.pid            # the suite's own pid: alive, ps shows no
: > .loop/run.heartbeat            # loop.sh — the fresh heartbeat proves live
RC=0; out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh </dev/null 2>&1) || RC=$?
check "bare invocation refused beside the live run (exit 2)" start-backstop 2 "$RC"
case "$out" in
  *"a run is already active"*) ok "backstop names the live run" ;;
  *) bad "wrong backstop refusal: $out" start-backstop ;;
esac
check "loop-instruction.md not enqueued" start-backstop 0 "$(qcount new)"
if ! grep -q '"state": "MEMORY_RESET"' .loop/journal.jsonl 2>/dev/null; then ok "no memory reset behind the backstop"; else bad "backstop reset memory" start-backstop; fi
rm -f .loop/state .loop/run.pid .loop/run.heartbeat

section "fleet: worktree never inherits the parent's filled-in contract (stale-contract trap)"
make_fixture fleet-stale
echo "PARENT-ONLY-MARKER" >> .loop/docs/product-contract.md
git add -A && git commit -qm "filled parent docs"
./loop.sh approve >/dev/null
printf 'delta task: fix value.txt so the check passes\n' > task-d.md
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-d.md --auto --drain > "$WORK/fleet-stale.out" 2>&1 </dev/null &
wait_sup $! fleet-stale
check "supervisor exit 0" fleet-stale 0 "$RC"
idd=$(fleet_task_id delta)
if grep -q "PARENT-ONLY-MARKER" ".loop/docs/run-archive/$idd/product-contract.md" 2>/dev/null; then
  bad "worktree ran the PARENT's stale contract" fleet-stale
else
  ok "worktree did not inherit the parent's contract"
fi
if grep -q 'auto-generated' ".loop/docs/run-archive/$idd/product-contract.md" 2>/dev/null; then ok "fresh contract generated for the task"; else bad "archived contract missing" fleet-stale; fi
check "parent contract untouched by the merge" fleet-stale 1 "$(grep -c PARENT-ONLY-MARKER .loop/docs/product-contract.md)"
check "task done" fleet-stale 1 "$(qcount "done")"

section "fleet: planned task — master contract injected; tamper caught, restored, approve refused"
make_fleet_fixture fleet-master
cat > .loop/docs/product-contract.md <<'EOF'
# Product Contract (master)
## Goal
value.txt must contain "fixed".
## Requirements
### REQ-001
./check.sh exits 0.
EOF
git add -A && git commit -q -m master
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --drain > "$WORK/fleet-master.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
check "planned task waits in PENDING_APPROVAL" fleet-master PENDING_APPROVAL "$(fleet_phase "$id")"
if [ -f "$(fleet_wt "$id")/.loop/master-contract.md" ]; then ok "master contract injected into the worktree"; else bad "master-contract.md missing" fleet-master; fi
if grep -q '^MASTER_HASH=' ".loop/fleet/runs/$id.env"; then ok "master hash pinned in parent metadata"; else bad "MASTER_HASH missing" fleet-master; fi
if [ -f "$(fleet_wt "$id")/.loop/fleet-worker" ]; then ok "fleet-worker marker written"; else bad "fleet-worker marker missing" fleet-master; fi
echo "EXTRA GOALPOST" >> "$(fleet_wt "$id")/.loop/master-contract.md"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
check "tampered approve refused (still pending)" fleet-master PENDING_APPROVAL "$(fleet_phase "$id")"
if grep -q '"event": "MASTER_TAMPER"' .loop/fleet/journal.jsonl; then ok "tamper journaled"; else bad "MASTER_TAMPER missing" fleet-master; fi
if ! grep -q 'EXTRA GOALPOST' "$(fleet_wt "$id")/.loop/master-contract.md"; then ok "master copy restored from the parent"; else bad "tampered copy kept" fleet-master; fi
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-master
check "supervisor exit 0" fleet-master 0 "$RC"
check "task completed after clean approve" fleet-master fixed "$(cat value.txt)"

section "fleet: planned sub-contract review REVISE regenerates once, then approves"
make_fleet_fixture fleet-regen
cat > .loop/docs/product-contract.md <<'EOF'
# Product Contract (master)
## Goal
value.txt must contain "fixed".
## Requirements
### REQ-001
./check.sh exits 0.
EOF
git add -A && git commit -q -m master
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_CONTRACT_REVIEW="REVISE,APPROVE" LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-regen.out" 2>&1 </dev/null &
wait_sup $! fleet-regen
check "supervisor exit 0" fleet-regen 0 "$RC"
if grep -q '"event": "CONTRACT_REGEN"' .loop/fleet/journal.jsonl; then ok "sub-contract regen journaled"; else bad "CONTRACT_REGEN missing" fleet-regen; fi
check "task done after regen + approve" fleet-regen 1 "$(qcount "done")"
check "parent value fixed" fleet-regen fixed "$(cat value.txt)"
if grep -q '"event": "AUTO_APPROVED"' .loop/fleet/journal.jsonl; then ok "second review auto-approved"; else bad "AUTO_APPROVED missing after regen" fleet-regen; fi

section "fleet: non-planned task still demotes immediately on review REVISE (no regen)"
make_fleet_fixture fleet-nregen
RC=0
LOOP_FAKE_CONTRACT_REVIEW="REVISE" LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/fleet-nregen.out" 2>&1 </dev/null &
SUP=$!
id=""
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  id=$(fleet_task_id alpha)
  [ -n "$id" ] && [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
check "demoted without regen" fleet-nregen PENDING_APPROVAL "$(fleet_phase "$id")"
if ! grep -q '"event": "CONTRACT_REGEN"' .loop/fleet/journal.jsonl; then ok "no regen for manual tasks"; else bad "manual task regenerated" fleet-nregen; fi
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-nregen
check "supervisor exit 0" fleet-nregen 0 "$RC"

section "fleet: --after serializes tasks; dependent branches from the merged result"
make_fleet_fixture fleet-deps
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
ida=$(fleet_task_id alpha)
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md --after "$ida" >/dev/null 2>&1
idb=$(fleet_task_id bravo)
if grep -q "^DEPENDS_ON=$ida\$" ".loop/fleet/runs/$idb.env"; then ok "dependency recorded"; else bad "DEPENDS_ON missing" fleet-deps; fi
if LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet status | grep -q "queued(after:$ida)"; then ok "status shows the wait"; else bad "status missing dep annotation" fleet-deps; fi
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain --max-parallel 2 > "$WORK/fleet-deps.out" 2>&1 </dev/null &
wait_sup $! fleet-deps
check "supervisor exit 0" fleet-deps 0 "$RC"
check "both tasks done" fleet-deps 2 "$(qcount "done")"
base_b=$(grep -E '^BASE_REF=' ".loop/fleet/runs/$idb.env" | tail -1 | cut -d= -f2-)
# grep -c (reads all input), not grep -q: -q exits at first match, git log takes
# SIGPIPE, and under `set -o pipefail` the whole condition goes false at random
merge_in_base=$(git log --format=%s "$base_b" 2>/dev/null | grep -c "^fleet: merge $ida" || true)
if [ "$merge_in_base" -ge 1 ]; then
  ok "dependent claimed only AFTER the dependency merged (base contains the merge)"
else
  bad "dependent did not branch from the merged result" fleet-deps
fi
check "parent value fixed" fleet-deps fixed "$(cat value.txt)"

section "fleet: failed dependency cascades to DEP_FAILED; resume re-queues it"
make_fleet_fixture fleet-depfail
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
ida=$(fleet_task_id alpha)
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md --after "$ida" >/dev/null 2>&1
idb=$(fleet_task_id bravo)
RC=0
LOOP_FAKE_SCENARIO=DECLARE_BLOCKED LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-depfail.out" 2>&1 </dev/null &
wait_sup $! fleet-depfail
check "supervisor exit 0 (drain completed, nothing stranded)" fleet-depfail 0 "$RC"
check "dependency failed BLOCKED" fleet-depfail BLOCKED "$(fleet_phase "$ida")"
check "dependent parked DEP_FAILED" fleet-depfail DEP_FAILED "$(fleet_phase "$idb")"
if grep -q '"event": "DEP_FAILED"' .loop/fleet/journal.jsonl; then ok "cascade journaled"; else bad "DEP_FAILED missing" fleet-depfail; fi
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet resume "$idb" >/dev/null 2>&1
if [ -f ".loop/fleet/queue/new/$idb.md" ]; then ok "DEP_FAILED resume re-queues from scratch"; else bad "resume did not re-queue ($(fleet_phase "$idb"))" fleet-depfail; fi

section "fleet: --after a FAILED dependency refused; --force-after accepts the cascade"
make_fleet_fixture add-afterfail
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
ida=$(fleet_task_id alpha)
RC=0
LOOP_FAKE_SCENARIO=DECLARE_BLOCKED LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/add-afterfail.out" 2>&1 </dev/null &
wait_sup $! add-afterfail
check "dependency failed BLOCKED" add-afterfail BLOCKED "$(fleet_phase "$ida")"
RC=0
out=$(./loop.sh fleet add task-b.md --after "$ida" 2>&1) || RC=$?
check "add --after a failed dep refused (exit 2)" add-afterfail 2 "$RC"
case "$out" in
  *"$ida"*) ok "refusal names the failed dependency" ;;
  *) bad "refusal does not name the dep: $out" add-afterfail ;;
esac
case "$out" in
  *resume*) ok "refusal points at resume first" ;;
  *) bad "no resume hint: $out" add-afterfail ;;
esac
RC=0
./loop.sh fleet add task-b.md --after "$ida" --force-after >/dev/null 2>&1 || RC=$?
check "--force-after queues the task anyway (exit 0)" add-afterfail 0 "$RC"
idb=$(fleet_task_id bravo)
if grep -q "^DEPENDS_ON=$ida\$" ".loop/fleet/runs/$idb.env"; then
  ok "dependency recorded under --force-after"
else
  bad "DEPENDS_ON missing after --force-after" add-afterfail
fi

