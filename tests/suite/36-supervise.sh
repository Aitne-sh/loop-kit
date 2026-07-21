#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- supervision (escalated PLANNED tasks: ANSWER / REPLAN / ESCALATE) ----------

section "supervise: Codex stays fresh and bypasses Claude session persistence"
make_sup_fixture fleet-codex-supervise
printf 'AGENT_SUPERVISE="codex"\nMODEL_SUPERVISE="gpt-5.5-review"\n' >> loop.models.sh
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SLEEP=0.3 LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" \
  LOOP_FAKE_SUPERVISE=ANSWER LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain >"$WORK/fleet-codex-supervise.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(qcount claimed)" -ge 1 ] && break
  sleep 0.2; n=$((n + 1))
done
# fleet startup has already rotated any prior session once the task is claimed.
# Seed a stale handle now: the Codex supervisor path must neither read nor update it.
printf 'stale-claude-session 19\n' > .loop/fleet/supervisor-session
wait_sup "$SUP" fleet-codex-supervise
check "supervisor exit 0" fleet-codex-supervise 0 "$RC"
check "task done" fleet-codex-supervise 1 "$(qcount "done")"
if grep -q '^model=gpt-5.5-review sandbox=read-only approval=never ' .loop/fake-codex-args \
   && grep -q 'loop-supervise/SKILL.md' .loop/fake-codex-prompts; then
  ok "SUPERVISE routed to a fresh read-only Codex call"
else
  bad "Codex supervisor call missing or not read-only" fleet-codex-supervise
fi
check "stale Claude session file was not read/updated by Codex" fleet-codex-supervise \
  "stale-claude-session 19" "$(cat .loop/fleet/supervisor-session 2>/dev/null || echo missing)"

section "supervise: ANSWER writes guidance and relaunches the task to SUCCESS"
make_sup_fixture fleet-supanswer
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" LOOP_FAKE_SUPERVISE=ANSWER LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-supanswer.out" 2>&1 </dev/null &
wait_sup $! fleet-supanswer
check "supervisor exit 0" fleet-supanswer 0 "$RC"
check "task done" fleet-supanswer 1 "$(qcount "done")"
check "parent value fixed" fleet-supanswer fixed "$(cat value.txt)"
if grep -q '"event": "SUPERVISE_PENDING"' .loop/fleet/journal.jsonl; then ok "escalation routed to the supervisor"; else bad "SUPERVISE_PENDING missing" fleet-supanswer; fi
if grep -q '"event": "SUPERVISE_ANSWER"' .loop/fleet/journal.jsonl; then ok "ANSWER journaled with the guidance"; else bad "SUPERVISE_ANSWER missing" fleet-supanswer; fi
if [ -f "$(fleet_wt "$id")/.loop/supervisor-guidance.md" ]; then ok "guidance file written into the worktree"; else bad "guidance file missing" fleet-supanswer; fi
if [ -f ".loop/supervise/$id/queue-snapshot.md" ]; then ok "task-mode call staged the live queue snapshot"; else bad "queue-snapshot.md missing from the task-mode staging" fleet-supanswer; fi

section "supervise: REPLAN supersedes the task and runs the replacement to SUCCESS"
make_sup_fixture fleet-supreplan
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SUPERVISE=REPLAN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --drain > "$WORK/fleet-supreplan.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "DECLARE_SPEC" > "$(fleet_wt "$id")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-supreplan
check "supervisor exit 0" fleet-supreplan 0 "$RC"
check "escalated task superseded (REPLANNED)" fleet-supreplan REPLANNED "$(fleet_phase "$id")"
if [ -d "$(fleet_wt "$id")" ] && git rev-parse -q --verify "loop/$id" >/dev/null; then ok "superseded worktree+branch kept for autopsy"; else bad "autopsy artifacts lost" fleet-supreplan; fi
if [ -f ".loop/fleet/queue/done/fixup-1.md" ]; then ok "replacement task completed"; else bad "fixup-1 not done ($(fleet_phase fixup-1))" fleet-supreplan; fi
check "parent value fixed by the replacement" fleet-supreplan fixed "$(cat value.txt)"
if grep -q '"event": "REPLANNED"' .loop/fleet/journal.jsonl; then ok "supersession journaled"; else bad "REPLANNED missing" fleet-supreplan; fi

section "supervise: ESCALATE parks the task NEEDS_HUMAN and surfaces it at the parent"
make_sup_fixture fleet-supesc
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SCENARIO=DECLARE_SPEC LOOP_FAKE_SUPERVISE=ESCALATE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-supesc.out" 2>&1 </dev/null &
wait_sup $! fleet-supesc
check "supervisor exit 0 (drained with the parked task)" fleet-supesc 0 "$RC"
check "task parked NEEDS_HUMAN" fleet-supesc NEEDS_HUMAN "$(fleet_phase "$id")"
if grep -q '"event": "SUPERVISE_ESCALATE"' .loop/fleet/journal.jsonl; then ok "escalation journaled"; else bad "SUPERVISE_ESCALATE missing" fleet-supesc; fi
if grep -q "DR-FLEET-$id" .loop/docs/decision-requests.md; then ok "pointer appended to the parent decision requests"; else bad "parent pointer missing" fleet-supesc; fi
check "parent tracked tree left clean (pointer committed)" fleet-supesc "" "$(git status --porcelain -uno)"

section "supervise: intervention cap sends the task straight to a human"
make_sup_fixture fleet-supcap
printf 'FLEET_MAX_SUPERVISE_PER_TASK=0\n' >> fleet.config.sh
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SCENARIO=DECLARE_SPEC LOOP_FAKE_SUPERVISE=ANSWER LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-supcap.out" 2>&1 </dev/null &
wait_sup $! fleet-supcap
check "supervisor exit 0" fleet-supcap 0 "$RC"
check "task parked NEEDS_HUMAN at the cap" fleet-supcap NEEDS_HUMAN "$(fleet_phase "$id")"
if [ ! -f .loop/fake-supervise-i ]; then ok "no supervise call burned at cap 0"; else bad "supervise model called despite the cap" fleet-supcap; fi
if grep -q 'intervention cap' .loop/docs/decision-requests.md; then ok "cap named in the decision request"; else bad "cap reason missing" fleet-supcap; fi

section "supervise: REPLAN that drops an escalated REQ is rejected (union check)"
make_sup_fixture fleet-supdrop
printf '### REQ-002\na second requirement, same gate.\n' >> .loop/docs/product-contract.md
git add -A && git commit -q -m "master gains REQ-002"
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001,REQ-002\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SCENARIO=DECLARE_SPEC LOOP_FAKE_SUPERVISE=REPLAN_DROP LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-supdrop.out" 2>&1 </dev/null &
wait_sup $! fleet-supdrop
check "supervisor exit 0 (drained with the parked task)" fleet-supdrop 0 "$RC"
check "task parked NEEDS_HUMAN (replan rejected)" fleet-supdrop NEEDS_HUMAN "$(fleet_phase "$id")"
if grep -q '"event": "REPLAN_INVALID"' .loop/fleet/journal.jsonl && grep -q 'do not cover' .loop/fleet/journal.jsonl; then
  ok "REPLAN_INVALID journaled with the coverage gap"
else
  bad "REPLAN_INVALID/coverage reason missing" fleet-supdrop
fi
if [ ! -f .loop/fleet/runs/fixup-1.env ]; then ok "no replacement task enqueued from the rejected plan"; else bad "rejected replan still enqueued fixup-1" fleet-supdrop; fi

section "supervise: REPLAN claiming a REQ owned by another live task is rejected"
make_sup_fixture fleet-supconf
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
ida=$(fleet_task_id alpha)
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md >/dev/null 2>&1
idb=$(fleet_task_id bravo)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$ida.env"
printf 'REQS=REQ-001\n' >> ".loop/fleet/runs/$idb.env"
RC=0
# max-parallel 1: a escalates while b (same forged REQ-001) still sits in new/
LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" LOOP_FAKE_SUPERVISE=REPLAN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain --max-parallel 1 > "$WORK/fleet-supconf.out" 2>&1 </dev/null &
wait_sup $! fleet-supconf
check "supervisor exit 0" fleet-supconf 0 "$RC"
if grep -q '"event": "REPLAN_INVALID"' .loop/fleet/journal.jsonl && grep -q 'already owned by' .loop/fleet/journal.jsonl; then
  ok "cross-task REQ conflict journaled as REPLAN_INVALID"
else
  bad "REQ-ownership conflict not journaled" fleet-supconf
fi
check "escalated task parked NEEDS_HUMAN" fleet-supconf NEEDS_HUMAN "$(fleet_phase "$ida")"

section "supervise: REPLAN into a phased chain (intra-block DEPENDS) runs to SUCCESS"
make_sup_fixture fleet-supchain
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SUPERVISE=REPLAN_CHAIN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --drain > "$WORK/fleet-supchain.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "DECLARE_SPEC" > "$(fleet_wt "$id")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-supchain
check "supervisor exit 0" fleet-supchain 0 "$RC"
check "escalated task superseded (REPLANNED)" fleet-supchain REPLANNED "$(fleet_phase "$id")"
check "both phases done" fleet-supchain 2 "$(qcount "done")"
if [ -f ".loop/fleet/queue/done/phase-1.md" ] && [ -f ".loop/fleet/queue/done/phase-2.md" ]; then
  ok "chain replacements phase-1 and phase-2 completed"
else
  bad "chain replacements missing (p1=$(fleet_phase phase-1) p2=$(fleet_phase phase-2))" fleet-supchain
fi
base_p2=$(grep -E '^BASE_REF=' ".loop/fleet/runs/phase-2.env" | tail -1 | cut -d= -f2-)
if [ "$(git log --format=%s "$base_p2" 2>/dev/null | grep -c '^fleet: merge phase-1' || true)" -ge 1 ]; then
  ok "phase-2 branched from phase-1's merged result"
else
  bad "phase-2 did not branch from the merged phase-1" fleet-supchain
fi
check "parent value fixed by the chain" fleet-supchain fixed "$(cat value.txt)"

section "supervise: join-less REPLAN fork sharing a REQ is rejected (completing-owner rule)"
make_sup_fixture fleet-supfork
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SCENARIO=DECLARE_SPEC LOOP_FAKE_SUPERVISE=REPLAN_FORK LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-supfork.out" 2>&1 </dev/null &
wait_sup $! fleet-supfork
check "supervisor exit 0 (drained with the parked task)" fleet-supfork 0 "$RC"
check "task parked NEEDS_HUMAN (fork rejected)" fleet-supfork NEEDS_HUMAN "$(fleet_phase "$id")"
if grep -q '"event": "REPLAN_INVALID"' .loop/fleet/journal.jsonl && grep -q 'single completing owner' .loop/fleet/journal.jsonl; then
  ok "REPLAN_INVALID journaled with the completing-owner reason"
else
  bad "completing-owner rejection missing from the journal" fleet-supfork
fi
if [ ! -f .loop/fleet/runs/phase-1.env ]; then ok "no replacement enqueued from the rejected fork"; else bad "rejected fork still enqueued phase-1" fleet-supfork; fi

section "supervise: REPLAN into a fork-join diamond runs to SUCCESS (two roots — carryover skipped)"
make_sup_fixture fleet-supforkjoin
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SUPERVISE=REPLAN_FORKJOIN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --drain > "$WORK/fleet-supforkjoin.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "DECLARE_DECOMP" > "$(fleet_wt "$id")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-supforkjoin
check "supervisor exit 0" fleet-supforkjoin 0 "$RC"
check "escalated task superseded (REPLANNED)" fleet-supforkjoin REPLANNED "$(fleet_phase "$id")"
check "all three diamond replacements done" fleet-supforkjoin 3 "$(qcount "done")"
# two intra-block roots: the NEEDS_DECOMPOSITION carryover has no unique target
if grep -q '"event": "CARRYOVER_SKIPPED"' .loop/fleet/journal.jsonl && grep -q 'no unique root' .loop/fleet/journal.jsonl; then
  ok "carryover skipped with the no-unique-root reason"
else
  bad "CARRYOVER_SKIPPED (no unique root) missing" fleet-supforkjoin
fi
if ! grep -qE '^SEED_BRANCH=' .loop/fleet/runs/half-a.env 2>/dev/null \
   && ! grep -qE '^SEED_BRANCH=' .loop/fleet/runs/half-b.env 2>/dev/null; then
  ok "no seed recorded on either fork root"
else
  bad "SEED_BRANCH recorded despite the two-root fork" fleet-supforkjoin
fi
# guarded: when the diamond scenario itself failed, join-c.env never exists —
# that must surface as this block's own bad-assertions, not abort the suite
base_jc=$(grep -E '^BASE_REF=' ".loop/fleet/runs/join-c.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ "$(git log --format=%s "$base_jc" 2>/dev/null | grep -c '^fleet: merge half-a' || true)" -ge 1 ] \
   && [ "$(git log --format=%s "$base_jc" 2>/dev/null | grep -c '^fleet: merge half-b' || true)" -ge 1 ]; then
  ok "join-c branched from both merged halves"
else
  bad "join-c did not branch from both merged halves" fleet-supforkjoin
fi
check "parent value fixed by the diamond" fleet-supforkjoin fixed "$(cat value.txt)"

section "supervise: REPLAN with an intra-block dependency cycle is rejected"
make_sup_fixture fleet-supcycle
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SCENARIO=DECLARE_SPEC LOOP_FAKE_SUPERVISE=REPLAN_CYCLE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-supcycle.out" 2>&1 </dev/null &
wait_sup $! fleet-supcycle
check "supervisor exit 0 (drained with the parked task)" fleet-supcycle 0 "$RC"
check "task parked NEEDS_HUMAN (cycle rejected)" fleet-supcycle NEEDS_HUMAN "$(fleet_phase "$id")"
if grep -q '"event": "REPLAN_INVALID"' .loop/fleet/journal.jsonl && grep -q 'dependency cycle' .loop/fleet/journal.jsonl; then
  ok "REPLAN_INVALID journaled with the cycle reason"
else
  bad "cycle rejection missing from the journal" fleet-supcycle
fi

section "supervise: a REPLAN depending on a failed task is rejected (dead-on-arrival guard)"
make_sup_fixture fleet-supdeaddep
# a superseded leftover from an earlier replan: still in runs/ + queue/failed/ —
# a stale conversational view of the plan could name it as a DEPENDS target
mkdir -p .loop/fleet/queue/failed .loop/fleet/runs
printf '# dead\n' > .loop/fleet/queue/failed/dead-task.md
printf 'PHASE=REPLANNED\nRESULT=REPLANNED\n' > .loop/fleet/runs/dead-task.env
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SCENARIO=DECLARE_SPEC LOOP_FAKE_SUPERVISE=REPLAN_DEADDEP LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-supdeaddep.out" 2>&1 </dev/null &
wait_sup $! fleet-supdeaddep
check "supervisor exit 0 (drained with the parked task)" fleet-supdeaddep 0 "$RC"
check "task parked NEEDS_HUMAN (payload rejected)" fleet-supdeaddep NEEDS_HUMAN "$(fleet_phase "$id")"
if grep -q '"event": "REPLAN_INVALID"' .loop/fleet/journal.jsonl && grep -q 'depends on failed task' .loop/fleet/journal.jsonl; then
  ok "REPLAN_INVALID journaled with the failed-dependency reason"
else
  bad "failed-dependency rejection missing from the journal" fleet-supdeaddep
fi
if [ ! -f .loop/fleet/runs/fixup-1.env ]; then ok "no dead-on-arrival replacement enqueued"; else bad "fixup-1 enqueued despite the dead dep" fleet-supdeaddep; fi

section "supervise: a rejected REPLAN escalates with the REAL reason (not a generic message)"
make_sup_fixture fleet-supreason
printf 'FLEET_MAX_REPLAN_TASKS=1\n' >> fleet.config.sh
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
id=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$id.env"
RC=0
LOOP_FAKE_SCENARIO=DECLARE_SPEC LOOP_FAKE_SUPERVISE=REPLAN_CHAIN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --auto --drain > "$WORK/fleet-supreason.out" 2>&1 </dev/null &
wait_sup $! fleet-supreason
check "supervisor exit 0 (drained with the parked task)" fleet-supreason 0 "$RC"
check "task parked NEEDS_HUMAN (budget exceeded)" fleet-supreason NEEDS_HUMAN "$(fleet_phase "$id")"
if grep -q '"event": "SUPERVISE_ESCALATE"' .loop/fleet/journal.jsonl && grep '"event": "SUPERVISE_ESCALATE"' .loop/fleet/journal.jsonl | grep -q 'replan budget exceeded'; then
  ok "escalation carries the real rejection reason (replan budget exceeded)"
else
  bad "escalation masked the budget reason: $(grep '"event": "SUPERVISE_ESCALATE"' .loop/fleet/journal.jsonl | tail -1 | cut -c1-200)" fleet-supreason
fi

section "supervise: a fork BRANCH re-escalates — the joined sibling is no REQ conflict"
# live fork: alpha ∥ bravo -> join, all owning REQ-001 (the join declares the
# fork). When branch alpha escalates and is REPLANned, its parallel sibling
# bravo must NOT be flagged as a REQ conflict — fork_join_related exempts it
# via the joining owner.
make_sup_fixture fleet-forkresc
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
ida=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$ida.env"
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md --auto >/dev/null 2>&1
idb=$(fleet_task_id bravo)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$idb.env"
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add "join: certify REQ-001 over both merged branches" --auto --after "$ida,$idb" >/dev/null 2>&1
idj=$(fleet_task_id join)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$idj.env"
RC=0
LOOP_FAKE_SUPERVISE=REPLAN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --drain > "$WORK/fleet-forkresc.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$ida")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "DECLARE_SPEC" > "$(fleet_wt "$ida")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$ida" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-forkresc
check "supervisor exit 0" fleet-forkresc 0 "$RC"
check "escalated branch superseded (REPLANNED)" fleet-forkresc REPLANNED "$(fleet_phase "$ida")"
if [ -f ".loop/fleet/queue/done/fixup-1.md" ]; then
  ok "replacement accepted despite the joined sibling owning the REQ"
else
  bad "replacement rejected/missing (fixup-1: $(fleet_phase fixup-1))" fleet-forkresc
fi
if ! grep -q 'already owned by' .loop/fleet/journal.jsonl; then ok "no false REQ-conflict journaled"; else bad "joined sibling flagged as a REQ conflict" fleet-forkresc; fi
check "sibling, replacement and join all done" fleet-forkresc 3 "$(qcount "done")"
check "parent value fixed" fleet-forkresc fixed "$(cat value.txt)"

section "supervise: replanned dependency is rewired to the replacement sinks (no DEP_FAILED)"
make_sup_fixture fleet-suprewire
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md >/dev/null 2>&1
ida=$(fleet_task_id alpha)
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md --auto --after "$ida" >/dev/null 2>&1
idb=$(fleet_task_id bravo)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$ida.env"
RC=0
LOOP_FAKE_SUPERVISE=REPLAN LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh fleet run --drain > "$WORK/fleet-suprewire.out" 2>&1 </dev/null &
SUP=$!
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$ida")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "DECLARE_SPEC" > "$(fleet_wt "$ida")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$ida" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-suprewire
check "supervisor exit 0" fleet-suprewire 0 "$RC"
check "escalated task superseded (REPLANNED)" fleet-suprewire REPLANNED "$(fleet_phase "$ida")"
dep_b=$(grep -E '^DEPENDS_ON=' ".loop/fleet/runs/$idb.env" | tail -1 | cut -d= -f2-)
check "dependent rewired onto the replacement" fleet-suprewire fixup-1 "$dep_b"
if grep -q '"event": "DEPS_REWIRED"' .loop/fleet/journal.jsonl; then ok "rewiring journaled"; else bad "DEPS_REWIRED missing" fleet-suprewire; fi
if [ -f ".loop/fleet/queue/done/$idb.md" ]; then ok "dependent completed after the replacement merged"; else bad "dependent not done (phase=$(fleet_phase "$idb") result=$(fleet_result "$idb"))" fleet-suprewire; fi

