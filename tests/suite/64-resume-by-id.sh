#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- resume-by-id (one surface for fleet tasks and the root run) ----------

section "resume <id>: live dispatcher — flip only, relaunched on the next tick"
make_fleet_fixture resume-id-live
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md task-b.md --drain --max-parallel 2 > "$WORK/resume-id-live.out" 2>&1 </dev/null &
SUP=$!
ida=""; idb=""
n=0
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  ida=$(fleet_task_id alpha); idb=$(fleet_task_id bravo)
  [ -n "$ida" ] && [ -n "$idb" ] \
    && [ "$(fleet_phase "$ida")" = "PENDING_APPROVAL" ] \
    && [ "$(fleet_phase "$idb")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
# diff every iteration (BAD_FIX appends to notes.txt): a CONTINUE_FIX streak
# would trip STAGNATION_N=2 and STALL task a instead of keeping it mid-run
echo "CONTINUE_FIX,BAD_FIX,BAD_FIX,READY_NOW" > "$(fleet_wt "$ida")/.loop/fake-scenario"
echo "DECLARE_BLOCKED,READY_NOW" > "$(fleet_wt "$idb")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve --all </dev/null >/dev/null 2>&1
n=0   # b fails fast while a is still mid-run -> the dispatcher is provably live
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  [ -f ".loop/fleet/queue/failed/$idb.md" ] && break
  sleep 0.1; n=$((n + 1))
done
out=$(./loop.sh resume "$idb" 2>&1) || true
case "$out" in
  *"next tick"*) ok "resume defers the relaunch to the live dispatcher" ;;
  *) bad "no live-dispatcher note: $out" resume-id-live ;;
esac
qd=""
for d in claimed "done"; do [ -f ".loop/fleet/queue/$d/$idb.md" ] && qd="$d"; done
if [ -n "$qd" ]; then ok "flip re-queued the task for the dispatcher ($qd)"; else bad "task still failed after resume ($(fleet_phase "$idb"))" resume-id-live; fi
wait_sup "$SUP" resume-id-live
check "supervisor exit 0" resume-id-live 0 "$RC"
check "both tasks done" resume-id-live 2 "$(qcount "done")"

section "resume <id>: no dispatcher — inline drain relaunches and completes"
make_fleet_fixture resume-id-dead
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="DECLARE_BLOCKED,READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/resume-id-dead1.out" 2>&1 </dev/null &
wait_sup $! resume-id-dead
check "first drain exit 0" resume-id-dead 0 "$RC"
ida=$(fleet_task_id alpha)
check "task failed BLOCKED" resume-id-dead BLOCKED "$(fleet_phase "$ida")"
RC=0
# the wt's persisted .loop/fake-i makes the relaunch consume READY_NOW
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="DECLARE_BLOCKED,READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh resume "$ida" > "$WORK/resume-id-dead2.out" 2>&1 </dev/null || RC=$?
check "resume <id> exit 0 (inline drain dispatcher)" resume-id-dead 0 "$RC"
if [ -f ".loop/fleet/queue/done/$ida.md" ]; then ok "task completed via the inline dispatcher"; else bad "task not done ($(fleet_phase "$ida"))" resume-id-dead; fi
check "parent value fixed" resume-id-dead fixed "$(cat value.txt)"
if grep -q '"event": "RESUME"' .loop/fleet/journal.jsonl && grep -q '"event": "RESUME_DISPATCH"' .loop/fleet/journal.jsonl; then
  ok "RESUME + RESUME_DISPATCH journaled"
else
  bad "resume journal events missing" resume-id-dead
fi

section "resume <id>: decision states resume only after the in-worktree answer + approve"
make_fleet_fixture resume-id-decision
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/resume-id-dec1.out" 2>&1 </dev/null &
wait_sup $! resume-id-decision
ida=$(fleet_task_id alpha)
check "task failed NEEDS_SPEC_DECISION" resume-id-decision NEEDS_SPEC_DECISION "$(fleet_phase "$ida")"
RC=0
out=$(./loop.sh resume "$ida" 2>&1) || RC=$?
check "resume refused before the answer (exit 2)" resume-id-decision 2 "$RC"
case "$out" in
  *supervisor-guidance.md*) ok "refusal names the answer channel" ;;
  *) bad "no answer-channel hint: $out" resume-id-decision ;;
esac
case "$out" in
  *approve*) ok "refusal names the in-worktree approve" ;;
  *) bad "no approve hint: $out" resume-id-decision ;;
esac
wta=$(fleet_wt "$ida")
echo "REQ-002 wins; proceed with the narrow reading" > "$wta/.loop/supervisor-guidance.md"
(cd "$wta" && ./loop.sh approve) >/dev/null 2>&1
if grep -q '^DECISION_REBOUND=1' "$wta/.loop/run-checkpoint"; then ok "in-worktree approve re-bound the checkpoint"; else bad "DECISION_REBOUND missing in the worktree" resume-id-decision; fi
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh resume "$ida" > "$WORK/resume-id-dec2.out" 2>&1 </dev/null || RC=$?
check "answered resume exit 0" resume-id-decision 0 "$RC"
if [ -f ".loop/fleet/queue/done/$ida.md" ]; then ok "task done after the decision"; else bad "task not done ($(fleet_phase "$ida"))" resume-id-decision; fi
check "parent value fixed" resume-id-decision fixed "$(cat value.txt)"
if grep '"event": "RESUME"' .loop/fleet/journal.jsonl | grep -q 'decision answered'; then
  ok "RESUME detail records the answered decision (rebound checkpoint)"
else
  bad "decision-answered detail missing from RESUME" resume-id-decision
fi

section "resume <id>: refusal matrix (done / unknown / queued)"
make_fleet_fixture resume-id-refuse
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/resume-id-refuse.out" 2>&1 </dev/null &
wait_sup $! resume-id-refuse
ida=$(fleet_task_id alpha)
check "fixture task done" resume-id-refuse 1 "$(qcount "done")"
RC=0; out=$(./loop.sh resume "$ida" 2>&1) || RC=$?
check "done task refused (exit 2)" resume-id-refuse 2 "$RC"
case "$out" in *add*) ok "done refusal points at queueing a follow-up (add)" ;; *) bad "no add hint: $out" resume-id-refuse ;; esac
RC=0; out=$(./loop.sh resume no-such-task 2>&1) || RC=$?
check "unknown id refused (exit 2)" resume-id-refuse 2 "$RC"
case "$out" in *--list*) ok "unknown refusal points at resume --list" ;; *) bad "no --list hint: $out" resume-id-refuse ;; esac
./loop.sh fleet add task-b.md >/dev/null 2>&1
idb=$(fleet_task_id bravo)
RC=0; out=$(./loop.sh resume "$idb" 2>&1) || RC=$?
check "queued task refused (exit 2)" resume-id-refuse 2 "$RC"
case "$out" in *queued*) ok "queued refusal says it is already queued" ;; *) bad "no queued hint: $out" resume-id-refuse ;; esac

section "resume <id>: exit code reflects the relaunched task's real outcome"
# E4/G5: `resume <id>` used to exit 0 even when the relaunch failed again —
# the code now maps the flipped task's post-drain state (0/3/4/5) honestly.
make_fleet_fixture resume-id-exit
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=DECLARE_BLOCKED LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/resume-id-exit1.out" 2>&1 </dev/null &
wait_sup $! resume-id-exit
ida=$(fleet_task_id alpha)
check "task failed BLOCKED" resume-id-exit BLOCKED "$(fleet_phase "$ida")"
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=DECLARE_BLOCKED LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh resume "$ida" > "$WORK/resume-id-exit2.out" 2>&1 </dev/null || RC=$?
check "re-failed relaunch propagates failure (exit 4)" resume-id-exit 4 "$RC"
check "RESULT BLOCKED again" resume-id-exit BLOCKED "$(fleet_result "$ida")"
if grep -q 'approve from another terminal' "$WORK/resume-id-exit2.out"; then
  ok "approve hint printed unconditionally (even with no sibling tasks)"
else
  bad "approve hint missing with others=0" resume-id-exit
fi
if ! grep -q 'other queued/claimed task' "$WORK/resume-id-exit2.out"; then
  ok "no sibling-dispatch note for a lone task"
else
  bad "sibling note printed with others=0" resume-id-exit
fi
echo DECLARE_SPEC > "$(fleet_wt "$ida")/.loop/fake-scenario"
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=DECLARE_BLOCKED LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh resume "$ida" > "$WORK/resume-id-exit3.out" 2>&1 </dev/null || RC=$?
check "decision-state relaunch exits 3 (a human must decide)" resume-id-exit 3 "$RC"
check "RESULT NEEDS_SPEC_DECISION" resume-id-exit NEEDS_SPEC_DECISION "$(fleet_result "$ida")"

section "resume <id>: a second resume while the first is live refuses (busy)"
# G4: the busy arm must hold for a LIVE relaunch pid — never race two dispatchers
make_fleet_fixture resume-id-busy
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=DECLARE_BLOCKED LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/resume-id-busy1.out" 2>&1 </dev/null &
wait_sup $! resume-id-busy
ida=$(fleet_task_id alpha)
check "task failed BLOCKED" resume-id-busy BLOCKED "$(fleet_phase "$ida")"
# the relaunch consumes 4 more scenario entries (diff every iteration — see
# resume-id-live) so the worker is provably mid-run for the second resume
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="DECLARE_BLOCKED,CONTINUE_FIX,BAD_FIX,BAD_FIX,READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh resume "$ida" > "$WORK/resume-id-busy2.out" 2>&1 </dev/null &
RES=$!
n=0
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  if [ "$(fleet_phase "$ida")" = "RUNNING" ] \
     && [ "$(cat "$(fleet_wt "$ida")/.loop/state" 2>/dev/null)" = "RUNNING" ]; then
    break
  fi
  sleep 0.2; n=$((n + 1))
done
RC2=0; out=$(./loop.sh resume "$ida" 2>&1) || RC2=$?
check "second resume refused while live (exit 2)" resume-id-busy 2 "$RC2"
case "$out" in
  *"nothing to resume"*) ok "refusal says nothing to resume (busy)" ;;
  *) bad "wrong busy refusal: $out" resume-id-busy ;;
esac
wait_sup "$RES" resume-id-busy
check "first resume completed (exit 0)" resume-id-busy 0 "$RC"
check "task done" resume-id-busy 1 "$(qcount "done")"

section "resume <id>: a supervisor-pending phase points at the supervisor (not 'nothing to resume')"
# H1 consistency: recover_claimed now ADOPTS a claimed:SUPERVISE_PENDING task on
# restart, so the per-task resume must stop mislabeling it 'nothing to resume'
# (terminal-sounding). With no live supervisor it names ./loop.sh run — which
# restarts the supervisor and adopts it. (The genuinely-running busy case above
# still says 'nothing to resume'; only the parent-side pending phases changed.)
make_fleet_fixture resume-id-suppend
./loop.sh fleet add task-a.md >/dev/null
spid=$(fleet_task_id alpha)
printf 'PHASE=SUPERVISE_PENDING\n' >> ".loop/fleet/runs/$spid.env"   # a supervisor-side pending phase...
mv ".loop/fleet/queue/new/$spid.md" ".loop/fleet/queue/claimed/$spid.md"  # ...on a claimed task, no live supervisor
RC=0; out=$(./loop.sh resume "$spid" 2>&1) || RC=$?
check "supervise-pending resume refused (exit 2)" resume-id-suppend 2 "$RC"
case "$out" in
  *"nothing to resume"*) bad "still mislabels SUPERVISE_PENDING as 'nothing to resume': $out" resume-id-suppend ;;
  *"./loop.sh run"*)     ok "points at the supervisor restart (./loop.sh run)" ;;
  *) bad "no supervisor-restart hint: $out" resume-id-suppend ;;
esac

section "resume --list: root pseudo-entry + per-task resumability verdicts"
make_fleet_fixture resume-list
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=DECLARE_BLOCKED LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/resume-list1.out" 2>&1 </dev/null &
wait_sup $! resume-list
ida=$(fleet_task_id alpha)
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-b.md --auto --drain > "$WORK/resume-list2.out" 2>&1 </dev/null &
wait_sup $! resume-list
idb=$(fleet_task_id bravo)
./loop.sh add "third thing to do later" >/dev/null 2>&1
idc=$(fleet_task_id third)
out=$(./loop.sh resume --list 2>&1) || true
case "$out" in
  *"(root)"*) ok "root pseudo-entry present" ;;
  *) bad "no (root) row: $out" resume-list ;;
esac
if printf '%s\n' "$out" | grep "$ida" | grep -q 'yes'; then ok "failed BLOCKED task listed resumable"; else bad "BLOCKED row wrong: $(printf '%s\n' "$out" | grep "$ida" || echo missing)" resume-list; fi
if printf '%s\n' "$out" | grep "$idb" | grep -q 'no'; then ok "done task listed non-resumable"; else bad "done row wrong: $(printf '%s\n' "$out" | grep "$idb" || echo missing)" resume-list; fi
if printf '%s\n' "$out" | grep "$idc" | grep -q 'queued'; then ok "new task listed as queued"; else bad "queued row wrong: $(printf '%s\n' "$out" | grep "$idc" || echo missing)" resume-list; fi

section "resume --list: parked root states point at approve && run (never a blind resume)"
# G3: PENDING_APPROVAL (ask-first park) and NEEDS_SPEC_DECISION root rows
make_fixture resume-list-parked nocontract
echo "migrate the data store" > loop-instruction.md
RC=0
LOOP_ASK_CRITICAL=1 LOOP_FAKE_CONTRACT=QUESTIONS LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  ./loop.sh auto >"$WORK/resume-list-parked.out" 2>&1 </dev/null || RC=$?
check "run parked PENDING_APPROVAL (exit 3)" resume-list-parked 3 "$RC"
out=$(./loop.sh resume --list 2>&1) || true
if printf '%s\n' "$out" | grep '(root)' | grep -q 'after deciding'; then
  ok "PENDING_APPROVAL root row says 'after deciding'"
else
  bad "root row wrong for PENDING_APPROVAL: $(printf '%s\n' "$out" | grep '(root)' || echo missing)" resume-list-parked
fi
printf '\n## Decision\n- park unconvertible rows, never delete\n' >> .loop/docs/product-contract.md
git add -A && git commit -q -m "human answered"
./loop.sh approve >/dev/null
run_loop "DECLARE_SPEC"
check "run stopped NEEDS_SPEC_DECISION (exit 3)" resume-list-parked 3 "$RC"
out=$(./loop.sh resume --list 2>&1) || true
if printf '%s\n' "$out" | grep '(root)' | grep -q 'after deciding'; then
  ok "NEEDS_SPEC_DECISION root row says 'after deciding'"
else
  bad "root row wrong for NEEDS_SPEC_DECISION: $(printf '%s\n' "$out" | grep '(root)' || echo missing)" resume-list-parked
fi

section "resume <id>: orphan detection + fleet clean --orphans"
make_fixture resume-orphan
git worktree add "$WORK/resume-orphan-loops/ghost-1" -b loop/ghost-1 >/dev/null 2>&1
RC=0
out=$(./loop.sh resume ghost-1 2>&1) || RC=$?
check "orphan refused (exit 2)" resume-orphan 2 "$RC"
case "$out" in
  *orphan*) ok "refusal names the orphan state" ;;
  *) bad "no orphan hint: $out" resume-orphan ;;
esac
./loop.sh fleet clean --orphans >/dev/null 2>&1 || true
if [ ! -d "$WORK/resume-orphan-loops/ghost-1" ]; then ok "orphan worktree removed"; else bad "orphan worktree left" resume-orphan; fi
if ! git rev-parse -q --verify refs/heads/loop/ghost-1 >/dev/null; then ok "orphan branch removed"; else bad "orphan branch left" resume-orphan; fi
if grep -q '"event": "ORPHAN_CLEANED"' .loop/fleet/journal.jsonl; then ok "gc journaled as ORPHAN_CLEANED"; else bad "ORPHAN_CLEANED missing" resume-orphan; fi

