#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- orchestration end-to-end (decompose -> parallel -> integration gate) ----------

section "orch: two parallel tasks -> merged -> integration gate -> SUCCESS"
make_orch_fixture orch-par 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-par.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-par 0 "$RC"
check "state SUCCESS" orch-par SUCCESS "$(cat .loop/state)"
check "both planned tasks done" orch-par 2 "$(qcount "done")"
check "parent value fixed" orch-par fixed "$(cat value.txt)"
if grep -q '"state": "DECOMPOSE_OK"' .loop/journal.jsonl; then ok "decomposition journaled"; else bad "DECOMPOSE_OK missing" orch-par; fi
if grep -q '"state": "INTEGRATION_GATE_SUCCESS"' .loop/journal.jsonl; then ok "integration gate certified the merged result"; else bad "INTEGRATION_GATE_SUCCESS missing" orch-par; fi
wa=$(fleet_wt "$(fleet_task_id part-a)")
if [ -f "$wa/.loop/master-contract.md" ]; then ok "master contract injected into planned worktrees"; else bad "master injection missing" orch-par; fi
if [ -f .loop/docs/evidence-report.md ] && ! grep -q '<!-- TEMPLATE -->' .loop/docs/evidence-report.md; then ok "master evidence report written"; else bad "master evidence missing" orch-par; fi
if [ -s .loop/docs/certification.json ]; then
  check "integration certificate marks per-task preflight N/A" orch-par NOT_APPLICABLE "$(json_scalar .loop/docs/certification.json preflight)"
  bundle=$(json_scalar .loop/docs/certification.json worker_evidence_sha256)
  if printf '%s' "$bundle" | grep -qE '^[0-9a-f]{64}$'; then
    ok "integration certificate binds the worker evidence bundle"
  else
    bad "worker_evidence_sha256 missing/malformed: '$bundle'" orch-par
  fi
else
  bad "integration certification.json missing" orch-par
fi
if grep -q 'run-archive/part-a' .loop/docs/evidence-report.md \
   && grep -q 'run-archive/part-b' .loop/docs/evidence-report.md; then
  ok "master evidence report covers both merged task archives"
else
  bad "master report missing merged-task archive coverage" orch-par
fi
merges=$(git log --format=%s | grep -c '^fleet: merge' || true)
if [ "$merges" -ge 1 ]; then ok "serial merge(s) landed ($merges)"; else bad "no merge commits" orch-par; fi

section "orch: parent's approved Codex sandbox posture survives a worker config rewrite"
make_orch_fixture orch-codex-posture 2
# loop.config.sh / loop.models.sh are gitignored in a deployment — the posture
# change needs only re-approval (contract_hash covers loop.config.sh), no commit
printf 'LOOP_CODEX_NETWORK=0\n' >> loop.config.sh
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
./loop.sh approve >/dev/null
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  LOOP_FAKE_CONTRACT_STRIP_CODEX_KEYS=1 \
  ./loop.sh run >"$WORK/orch-codex-posture.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-codex-posture 0 "$RC"
check "state SUCCESS" orch-codex-posture SUCCESS "$(cat .loop/state)"
wa=$(fleet_wt "$(fleet_task_id part-a)")
if [ -f "$wa/loop.config.sh" ] && ! grep -q '^LOOP_CODEX_' "$wa/loop.config.sh"; then
  ok "worker sub-contract rewrite dropped the Codex keys (fixture precondition)"
else
  bad "strip hook did not run — inheritance not exercised" orch-codex-posture
fi
if [ -s "$wa/.loop/fake-codex-args" ] \
   && grep -q 'sandbox=workspace-write' "$wa/.loop/fake-codex-args" \
   && ! grep -q 'sandbox_workspace_write.network_access=true' "$wa/.loop/fake-codex-args"; then
  ok "worker inherited the parent's approved network-off posture"
else
  bad "worker regained network despite parent LOOP_CODEX_NETWORK=0: $(cat "$wa/.loop/fake-codex-args" 2>/dev/null | tr '\n' ' ')" orch-codex-posture
fi

section "orch: final-verify tampering with the contract is caught before certification"
make_orch_fixture orch-tamper-final 2
# the tamper arms only at the parent's integration gate: workers have no
# .loop/fleet, and the parent runs no evaluator before the gate's --final
cat > check.sh <<'EOF'
#!/bin/sh
if [ -f .loop/fleet/base-ref ] && [ -n "$(ls .loop/docs/run-archive 2>/dev/null)" ]; then
  echo "<!-- gate tamper -->" >> .loop/docs/product-contract.md
fi
grep -q fixed value.txt
EOF
git add -A && git commit -q -m "gate-tampering verify"
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-tamper-final.out" 2>&1 </dev/null || RC=$?
check "exit 4" orch-tamper-final 4 "$RC"
check "state BLOCKED" orch-tamper-final BLOCKED "$(cat .loop/state)"
if grep -q "integration certification inputs changed after the evidence snapshot" "$WORK/orch-tamper-final.out"; then
  ok "post-final authority re-check caught the tamper"
else
  bad "post-final tamper not named" orch-tamper-final
fi
if [ ! -s .loop/docs/certification.json ]; then ok "tampered gate was never certified"; else bad "certificate written over a tampered contract" orch-tamper-final; fi

section "orch: master report omitting a merged worker's archive is refused; stale archives are superseded"
make_orch_fixture orch-omit 2
mkdir -p .loop/docs/run-archive/part-a
echo stale > .loop/docs/run-archive/part-a/stale-marker.txt
git add -A && git commit -q -m "stale archive from a previous orchestration"
RC=0
LOOP_FAKE_EVIDENCE=OMIT_MERGED LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-omit.out" 2>&1 </dev/null || RC=$?
check "exit 4" orch-omit 4 "$RC"
check "state BLOCKED" orch-omit BLOCKED "$(cat .loop/state)"
if grep -q "evidence report omits merged task" "$WORK/orch-omit.out"; then ok "omitted worker coverage refused"; else bad "omission not named" orch-omit; fi
set -- .loop/docs/run-archive/part-a-superseded-*/stale-marker.txt
if [ -f "$1" ]; then ok "stale same-id archive retired to a superseded dir"; else bad "stale archive not superseded" orch-omit; fi
if [ ! -e .loop/docs/run-archive/part-a/stale-marker.txt ]; then ok "fresh archive is pure (no hybrid)"; else bad "hybrid archive: stale marker inside the new archive" orch-omit; fi
if [ -s .loop/docs/run-archive/part-a/certification.json ]; then ok "fresh archive carries the worker certificate"; else bad "worker certificate missing from fresh archive" orch-omit; fi

section "orch: an archived worker certificate must semantically match its archive (gate refuses a forgery)"
# interrupt at the gate-review window (orch-gate-int's pattern), rewrite the
# archived certificate's final_state, then resume: the gate's deterministic
# archive verification must refuse BEFORE any reviewer/evidence agent reads it
make_orch_fixture orch-certswap 2
echo 3 > .loop/fake-sleep
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-certswap1.out" 2>&1 </dev/null &
ORCH=$!
n=0
while [ "$n" -lt $((600 * POLL_SCALE)) ]; do
  grep -q 'mode=gate' .loop/fake-review-prompts 2>/dev/null && break
  sleep 0.1; n=$((n + 1))
done
kill -TERM "$ORCH" 2>/dev/null || true
wait_sup "$ORCH" orch-certswap
rm -f .loop/fake-sleep
check "both workers merged before the interrupt" orch-certswap 2 "$(qcount "done")"
sed 's/"final_state":"SUCCESS"/"final_state":"NO_OP"/' .loop/docs/run-archive/part-a/certification.json > cert.tmp \
  && mv cert.tmp .loop/docs/run-archive/part-a/certification.json
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-certswap2.out" 2>&1 </dev/null || RC=$?
check "exit 4" orch-certswap 4 "$RC"
check "state BLOCKED" orch-certswap BLOCKED "$(cat .loop/state)"
if grep -q "archived certificate records final_state" "$WORK/orch-certswap2.out"; then
  ok "certificate/archive mismatch named deterministically"
else
  bad "forged certificate not refused: $(grep -o 'BLOCKED.*' "$WORK/orch-certswap2.out" | head -1)" orch-certswap
fi
if [ ! -s .loop/docs/certification.json ]; then ok "no integration certificate over a forged worker cert"; else bad "certified over a forged worker certificate" orch-certswap; fi

section "orch: chained decomposition serializes (dependent branches from the merge)"
make_orch_fixture orch-chain 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-chain.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-chain 0 "$RC"
check "state SUCCESS" orch-chain SUCCESS "$(cat .loop/state)"
base_b=$(grep -E '^BASE_REF=' ".loop/fleet/runs/part-b.env" | tail -1 | cut -d= -f2-)
merge_in_base=$(git log --format=%s "$base_b" 2>/dev/null | grep -c "^fleet: merge part-a" || true)
if [ "$merge_in_base" -ge 1 ]; then ok "part-b branched from part-a's merged result"; else bad "chain not serialized" orch-chain; fi
# part-a already satisfied the shared gate, so part-b legitimately finishes
# NO_OP — its determination must STILL reach the parent's evidence closure:
# archive + `fleet: no-op` commit + report coverage + the certificate bundle
if [ "$(git log --first-parent --no-merges --format=%s | grep -c '^fleet: no-op part-b' || true)" -ge 1 ]; then
  ok "NO_OP worker published its evidence on the parent line"
else
  bad "no 'fleet: no-op part-b' commit — NO_OP worker dropped from the evidence set" orch-chain
fi
if [ -s .loop/docs/run-archive/part-b/certification.json ]; then
  check "archived NO_OP certificate records its state" orch-chain NO_OP "$(json_scalar .loop/docs/run-archive/part-b/certification.json final_state)"
else
  bad "run-archive/part-b/certification.json missing" orch-chain
fi
if grep -q 'run-archive/part-b' .loop/docs/evidence-report.md; then
  ok "master evidence report covers the NO_OP worker's archive"
else
  bad "master report omits the NO_OP worker" orch-chain
fi
bundle=$(json_scalar .loop/docs/certification.json worker_evidence_sha256)
if printf '%s' "$bundle" | grep -qE '^[0-9a-f]{64}$'; then
  ok "integration certificate binds a bundle including the NO_OP archive"
else
  bad "worker_evidence_sha256 missing/malformed with a NO_OP worker: '$bundle'" orch-chain
fi
if grep -q '"event": "NOOP_ARCHIVED"' .loop/fleet/journal.jsonl; then ok "NO_OP publish journaled"; else bad "NOOP_ARCHIVED missing" orch-chain; fi

section "orch: phased chain sharing a REQ runs its phases serially to SUCCESS"
# CHAIN_SHARED: phase-a -> phase-b -> phase-c all own REQ-001 (the tail also
# owns REQ-002) — the chain-relaxed validator must accept it, and each phase
# must branch from its predecessor's MERGED result
make_orch_fixture orch-phased 2
RC=0
# READY_TOUCH: each phase adds a worktree-unique marker so all three phases
# produce a real diff and MERGE (with READY_NOW, later phases would NO_OP once
# phase-a fixed the shared gate — legitimate, but merge-order unobservable)
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN_SHARED LOOP_FAKE_SCENARIO=READY_TOUCH \
  ./loop.sh run >"$WORK/orch-phased.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-phased 0 "$RC"
check "state SUCCESS" orch-phased SUCCESS "$(cat .loop/state)"
check "all three phases done" orch-phased 3 "$(qcount "done")"
check "parent value fixed" orch-phased fixed "$(cat value.txt)"
base_pb=$(grep -E '^BASE_REF=' ".loop/fleet/runs/phase-b.env" | tail -1 | cut -d= -f2-)
if [ "$(git log --format=%s "$base_pb" 2>/dev/null | grep -c '^fleet: merge phase-a' || true)" -ge 1 ]; then
  ok "phase-b branched from phase-a's merged result"
else
  bad "phase-b did not branch from the merged phase-a" orch-phased
fi
base_pc=$(grep -E '^BASE_REF=' ".loop/fleet/runs/phase-c.env" | tail -1 | cut -d= -f2-)
if [ "$(git log --format=%s "$base_pc" 2>/dev/null | grep -c '^fleet: merge phase-b' || true)" -ge 1 ]; then
  ok "phase-c branched from phase-b's merged result"
else
  bad "phase-c did not branch from the merged phase-b" orch-phased
fi
if grep -q '"state": "INTEGRATION_GATE_SUCCESS"' .loop/journal.jsonl; then ok "integration gate certified the phased result"; else bad "INTEGRATION_GATE_SUCCESS missing" orch-phased; fi
wb=$(fleet_wt phase-b)
if [ -f "$wb/.loop/phase-context/phase-a/evidence-report.md" ] && [ -f "$wb/.loop/phase-context/phase-a/product-contract.md" ]; then
  ok "phase-b inherited phase-a's archived evidence (phase-context)"
else
  bad "phase-context missing in phase-b's worktree" orch-phased
fi
wa=$(fleet_wt phase-a)
if [ ! -d "$wa/.loop/phase-context" ]; then ok "no phase-context for the dep-less first phase"; else bad "phase-context injected without predecessors" orch-phased; fi
wc3=$(fleet_wt phase-c)
if [ -f "$wc3/.loop/phase-context/phase-b/evidence-report.md" ] && [ -f "$wc3/.loop/phase-context/phase-a/evidence-report.md" ]; then
  ok "phase-c inherited its TRANSITIVE predecessors' context (a and b)"
else
  bad "transitive phase-context missing in phase-c (a=$([ -f "$wc3/.loop/phase-context/phase-a/evidence-report.md" ] && echo yes || echo no) b=$([ -f "$wc3/.loop/phase-context/phase-b/evidence-report.md" ] && echo yes || echo no))" orch-phased
fi
if grep -q '"event": "PLAN_REVIEW_KEEP"' .loop/fleet/journal.jsonl; then ok "phase-boundary plan-review ran (KEEP)"; else bad "PLAN_REVIEW_KEEP missing" orch-phased; fi

section "orch: fork-join diamond sharing a REQ runs branches in parallel to SUCCESS"
# SHARED_FORKJOIN: part-a -> {part-b ∥ part-c} -> part-d; REQ-002 is shared by
# b/c/d — legal because the join part-d (the completing owner) depends on both
# branches. Both branches must fork off the merged prep; the join must branch
# from BOTH merged branches.
make_orch_fixture orch-forkjoin 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=SHARED_FORKJOIN LOOP_FAKE_SCENARIO=READY_TOUCH \
  ./loop.sh run >"$WORK/orch-forkjoin.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-forkjoin 0 "$RC"
check "state SUCCESS" orch-forkjoin SUCCESS "$(cat .loop/state)"
check "all four diamond tasks done" orch-forkjoin 4 "$(qcount "done")"
check "parent value fixed" orch-forkjoin fixed "$(cat value.txt)"
base_fb=$(grep -E '^BASE_REF=' ".loop/fleet/runs/part-b.env" | tail -1 | cut -d= -f2-)
base_fc=$(grep -E '^BASE_REF=' ".loop/fleet/runs/part-c.env" | tail -1 | cut -d= -f2-)
if [ "$(git log --format=%s "$base_fb" 2>/dev/null | grep -c '^fleet: merge part-a' || true)" -ge 1 ] \
   && [ "$(git log --format=%s "$base_fc" 2>/dev/null | grep -c '^fleet: merge part-a' || true)" -ge 1 ]; then
  ok "both branches forked off the merged prep phase"
else
  bad "branches did not fork off the merged part-a" orch-forkjoin
fi
base_fd=$(grep -E '^BASE_REF=' ".loop/fleet/runs/part-d.env" | tail -1 | cut -d= -f2-)
if [ "$(git log --format=%s "$base_fd" 2>/dev/null | grep -c '^fleet: merge part-b' || true)" -ge 1 ] \
   && [ "$(git log --format=%s "$base_fd" 2>/dev/null | grep -c '^fleet: merge part-c' || true)" -ge 1 ]; then
  ok "the join branched from BOTH merged branches"
else
  bad "join did not branch from both merged branches" orch-forkjoin
fi
wd=$(fleet_wt part-d)
if [ -f "$wd/.loop/phase-context/part-b/evidence-report.md" ] && [ -f "$wd/.loop/phase-context/part-c/evidence-report.md" ]; then
  ok "the join inherited both branches' phase-context"
else
  bad "join phase-context incomplete" orch-forkjoin
fi
# Fix E: the join must also inherit each branch's assumptions ledger (the substrate
# for cross-branch reconciliation)
if [ -f "$wd/.loop/phase-context/part-b/assumptions.md" ] && [ -f "$wd/.loop/phase-context/part-c/assumptions.md" ]; then
  ok "the join inherited both branches' assumption ledgers (reconciliation substrate)"
else
  bad "join did not inherit branch assumptions.md" orch-forkjoin
fi
if grep -q '"state": "INTEGRATION_GATE_SUCCESS"' .loop/journal.jsonl; then ok "integration gate certified the diamond"; else bad "INTEGRATION_GATE_SUCCESS missing" orch-forkjoin; fi

section "plan-review: REVISE reshapes the queued phases after a merge"
make_orch_fixture orch-planrev 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN_SHARED LOOP_FAKE_SCENARIO=READY_TOUCH \
  LOOP_FAKE_PLAN_REVIEW="REVISE,KEEP" \
  ./loop.sh run >"$WORK/orch-planrev.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-planrev 0 "$RC"
check "state SUCCESS" orch-planrev SUCCESS "$(cat .loop/state)"
check "queued phase-b superseded" orch-planrev REPLANNED "$(fleet_phase phase-b)"
check "queued phase-c superseded" orch-planrev REPLANNED "$(fleet_phase phase-c)"
if [ -f .loop/fleet/queue/done/phase-b2.md ] && [ -f .loop/fleet/queue/done/phase-c2.md ]; then
  ok "revised phases ran to completion"
else
  bad "revised phases missing (b2=$(fleet_phase phase-b2) c2=$(fleet_phase phase-c2))" orch-planrev
fi
if grep -q '"event": "PLAN_REVIEW_REVISED"' .loop/fleet/journal.jsonl; then ok "revision journaled"; else bad "PLAN_REVIEW_REVISED missing" orch-planrev; fi

section "plan-review REVISE: carryover seed lands on the SOURCE, not the SINK (Fix A)"
# A REVISE that replaces a queued chain still holding a pending carryover
# (SEED_BRANCH) must re-plant the seed on the block's SOURCE (first-executing)
# root — same rule as supervise_replan — so the chain builds forward on it. The
# buggy version planted it on the SINK (last phase). CHAIN_SHARED's REVISE emits
# phase-b2(source) -> phase-c2(sink); the seed must move to phase-b2.
make_orch_fixture orch-planseed 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN_SHARED LOOP_FAKE_SCENARIO=READY_TOUCH \
  LOOP_FAKE_PLAN_REVIEW="REVISE,KEEP" \
  ./loop.sh run >"$WORK/orch-planseed.out" 2>&1 </dev/null &
seed_pid=$!
# phase-b is enqueued at decompose, long before phase-a merges and fires the
# review — inject the pending seed onto the still-queued chain root in that window.
# Wait for ADDED_AT (enqueue's LAST renv_set) so no lock-guarded rewrite races the
# unlocked append below (phase-b then sits idle in new/ until phase-a merges).
for _ in $(seq 1 200); do
  grep -qE '^ADDED_AT=' .loop/fleet/runs/phase-b.env 2>/dev/null && break
  sleep 0.1
done
printf 'SEED_BRANCH=loop/phase-seed\n' >> ".loop/fleet/runs/phase-b.env"
wait_sup $seed_pid orch-planseed
check "exit 0" orch-planseed 0 "$RC"
check "state SUCCESS" orch-planseed SUCCESS "$(cat .loop/state)"
check "seed moved to the SOURCE phase-b2" orch-planseed "loop/phase-seed" \
  "$(grep -E '^SEED_BRANCH=' .loop/fleet/runs/phase-b2.env 2>/dev/null | tail -1 | cut -d= -f2-)"
if grep -qE '^SEED_BRANCH=' ".loop/fleet/runs/phase-c2.env" 2>/dev/null; then
  bad "seed wrongly landed on the SINK phase-c2" orch-planseed
else
  ok "SINK phase-c2 carries no seed"
fi
if grep -q '"event": "CARRYOVER_PLANNED"' .loop/fleet/journal.jsonl; then ok "carryover re-planted (CARRYOVER_PLANNED)"; else bad "CARRYOVER_PLANNED missing" orch-planseed; fi

section "plan-review: an INDEPENDENT phase's recorded drift fires the review (Fix D)"
# DRIFT_CHAIN = aa-drift (REQ-001, no dependents) beside a 3-phase chain
# ch-a->ch-b->ch-c (REQ-002). aa-drift is one fast phase, so it merges while the
# sequential chain is still early — ch-c is always still queued at that moment.
# NOTHING depends on aa-drift, so any plan-review it gets can ONLY be the drift
# trigger. The last chain phase ch-c merges with an empty queue and must NOT arm.
make_orch_fixture orch-drift 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=DRIFT_CHAIN LOOP_FAKE_SCENARIO=READY_DRIFT \
  LOOP_FAKE_PLAN_REVIEW=KEEP \
  ./loop.sh run >"$WORK/orch-drift.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-drift 0 "$RC"
check "state SUCCESS" orch-drift SUCCESS "$(cat .loop/state)"
check "drift armed+resolved a plan-review on the independent aa-drift" orch-drift DONE \
  "$(grep -E '^PLAN_REVIEW=' .loop/fleet/runs/aa-drift.env 2>/dev/null | tail -1 | cut -d= -f2-)"
if grep -q '"event": "PLAN_REVIEW_KEEP"' .loop/fleet/journal.jsonl; then ok "drift-triggered review ran"; else bad "no drift-triggered plan-review fired" orch-drift; fi
if grep -qE '^PLAN_REVIEW=' ".loop/fleet/runs/ch-c.env" 2>/dev/null; then
  bad "the last phase armed a review with an empty queue (guard failed)" orch-drift
else
  ok "empty-queue guard held (ch-c did not arm)"
fi
# D1: the worker's drift report + assumptions ledger are archived on merge (the
# substrate the drift trigger reads and the gate's cross-task check relies on)
if grep -qE '^- Drift detected:[[:space:]]*yes' ".loop/docs/run-archive/aa-drift/spec-drift-report.md" 2>/dev/null; then ok "worker drift report archived under run-archive/"; else bad "run-archive/aa-drift/spec-drift-report.md missing or wrong" orch-drift; fi
if [ -f ".loop/docs/run-archive/aa-drift/assumptions.md" ]; then ok "worker assumptions ledger archived under run-archive/"; else bad "run-archive/aa-drift/assumptions.md not archived" orch-drift; fi

section "plan-review: FLEET_PLAN_REVIEW_ON_DRIFT=0 keeps it dependency-triggered only (Fix D)"
make_orch_fixture orch-driftoff 2
printf 'FLEET_PLAN_REVIEW_ON_DRIFT=0\n' >> fleet.config.sh
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=DRIFT_CHAIN LOOP_FAKE_SCENARIO=READY_DRIFT \
  LOOP_FAKE_PLAN_REVIEW=KEEP \
  ./loop.sh run >"$WORK/orch-driftoff.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-driftoff 0 "$RC"
check "state SUCCESS" orch-driftoff SUCCESS "$(cat .loop/state)"
if grep -qE '^PLAN_REVIEW=' ".loop/fleet/runs/aa-drift.env" 2>/dev/null; then
  bad "drift fired a review with the knob off" orch-driftoff
else
  ok "knob off: no drift-triggered review on the independent task"
fi

section "plan-review ESCALATE freezes the whole queue, incl. INDEPENDENT tasks (Fix D hold)"
# deps_state only holds a merged phase's DEPENDENTS. A drift-triggered escalate can
# fire on a phase with none, so the tick must freeze ALL new claims while a
# plan-review is escalated — else an independent queued PLANNED task (no deps_state
# hold) is claimed in the same tick before the run finishes for the human.
# Synthesize the exact state (fleet-planpend idiom): a merged phase marked ESCALATED
# plus an independent PLANNED task queued with no dependency.
make_sup_fixture orch-escfreeze
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md --auto >/dev/null 2>&1
ida=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$ida.env"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain > "$WORK/escfreeze1.out" 2>&1 </dev/null &
wait_sup $! orch-escfreeze
check "the phase merged" orch-escfreeze 1 "$(qcount "done")"
# mark it escalated and add an INDEPENDENT PLANNED task (no DEPENDS_ON)
printf 'PLAN_REVIEW=ESCALATED\n' >> ".loop/fleet/runs/$ida.env"
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md --auto >/dev/null 2>&1
idb=$(fleet_task_id bravo)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$idb.env"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain > "$WORK/escfreeze2.out" 2>&1 </dev/null &
wait_sup $! orch-escfreeze
# the escalation must freeze task-b: it stays queued, never claimed (before the fix
# it was claim_task'd — worktree + contract-gen — in the same tick as the escalate)
if [ -f ".loop/fleet/queue/new/$idb.md" ]; then ok "independent task-b stayed queued (escalation froze the queue)"; else bad "task-b escaped the escalation hold (phase=$(fleet_phase "$idb"))" orch-escfreeze; fi
check "nothing new was claimed under the escalation" orch-escfreeze 0 "$(qcount claimed)"
check "escalation still stands until acked" orch-escfreeze ESCALATED "$(grep -E '^PLAN_REVIEW=' ".loop/fleet/runs/$ida.env" | tail -1 | cut -d= -f2-)"

section "plan-review: a REVISE of a forked REQ sweeps ALL queued owners"
# SHARED_FORKJOIN queue after part-a merges: part-b/part-c/part-d all own
# REQ-002 — a REVISE block covering REQ-002 must replace all three (the fork is
# re-emitted or collapsed as a whole, never half-replaced)
make_orch_fixture orch-plansweep 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=SHARED_FORKJOIN LOOP_FAKE_SCENARIO=READY_TOUCH \
  LOOP_FAKE_PLAN_REVIEW="REVISE_SWEEP,KEEP" \
  ./loop.sh run >"$WORK/orch-plansweep.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-plansweep 0 "$RC"
check "state SUCCESS" orch-plansweep SUCCESS "$(cat .loop/state)"
check "queued branch part-b swept" orch-plansweep REPLANNED "$(fleet_phase part-b)"
check "queued branch part-c swept" orch-plansweep REPLANNED "$(fleet_phase part-c)"
check "queued join part-d swept" orch-plansweep REPLANNED "$(fleet_phase part-d)"
if [ -f .loop/fleet/queue/done/redo-tail.md ]; then ok "collapsed tail ran to completion"; else bad "redo-tail missing ($(fleet_phase redo-tail))" orch-plansweep; fi
if grep -q '"event": "PLAN_REVIEW_REVISED"' .loop/fleet/journal.jsonl; then ok "sweep revision journaled"; else bad "PLAN_REVIEW_REVISED missing" orch-plansweep; fi

section "plan-review: a REVISE that drops a REQ is rejected — plan continues"
make_orch_fixture orch-planrevdrop 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN_SHARED LOOP_FAKE_SCENARIO=READY_TOUCH \
  LOOP_FAKE_PLAN_REVIEW=REVISE_DROP \
  ./loop.sh run >"$WORK/orch-planrevdrop.out" 2>&1 </dev/null || RC=$?
check "exit 0 (approved plan continued)" orch-planrevdrop 0 "$RC"
check "state SUCCESS" orch-planrevdrop SUCCESS "$(cat .loop/state)"
if grep -q '"event": "PLAN_REVIEW_INVALID"' .loop/fleet/journal.jsonl && grep -q 'conserve' .loop/fleet/journal.jsonl; then
  ok "REQ-dropping revision rejected with the conservation reason"
else
  bad "conservation rejection missing" orch-planrevdrop
fi
check "original phases still ran" orch-planrevdrop 3 "$(qcount "done")"

section "plan-review: ESCALATE holds dependents until an explicit fleet ack-plan"
make_orch_fixture orch-planesc 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN_SHARED LOOP_FAKE_SCENARIO=READY_TOUCH \
  LOOP_FAKE_PLAN_REVIEW="ESCALATE,KEEP" \
  ./loop.sh run >"$WORK/orch-planesc1.out" 2>&1 </dev/null || RC=$?
check "exit 3" orch-planesc 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-planesc NEEDS_SPEC_DECISION "$(cat .loop/state)"
if grep -q 'DR-FLEET-PLAN-phase-a' .loop/docs/decision-requests.md; then ok "decision request written"; else bad "DR-FLEET-PLAN missing" orch-planesc; fi
if grep -q 'ack-plan phase-a' .loop/docs/decision-requests.md; then ok "decision request names the ack command"; else bad "ack-plan hint missing from the DR" orch-planesc; fi
if [ -f .loop/fleet/queue/new/phase-b.md ]; then ok "dependent phase-b held in the queue"; else bad "dependent not held" orch-planesc; fi
# a habitual rerun WITHOUT the ack must stop at the same request — never a
# silent release of the held phases
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN_SHARED LOOP_FAKE_SCENARIO=READY_TOUCH \
  LOOP_FAKE_PLAN_REVIEW="ESCALATE,KEEP" \
  ./loop.sh run >"$WORK/orch-planesc2.out" 2>&1 </dev/null || RC=$?
check "unacked rerun exits 3 again" orch-planesc 3 "$RC"
check "state NEEDS_SPEC_DECISION after the unacked rerun" orch-planesc NEEDS_SPEC_DECISION "$(cat .loop/state)"
if [ -f .loop/fleet/queue/new/phase-b.md ]; then ok "dependent still held without the ack"; else bad "dependent released without an ack" orch-planesc; fi
if ! grep -q '"event": "PLAN_REVIEW_ACK"' .loop/fleet/journal.jsonl; then ok "no implicit ack journaled"; else bad "restart acked the escalation implicitly" orch-planesc; fi
# the explicit human ack releases the held phases; the next run completes
if LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet ack-plan phase-a >"$WORK/orch-planesc-ack.out" 2>&1 </dev/null; then
  ok "fleet ack-plan accepted the escalated phase"
else
  bad "fleet ack-plan failed: $(tail -2 "$WORK/orch-planesc-ack.out" | tr '\n' ' ')" orch-planesc
fi
if grep -q '"event": "PLAN_REVIEW_ACK"' .loop/fleet/journal.jsonl; then ok "human ack journaled"; else bad "PLAN_REVIEW_ACK missing after ack-plan" orch-planesc; fi
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN_SHARED LOOP_FAKE_SCENARIO=READY_TOUCH \
  LOOP_FAKE_PLAN_REVIEW="ESCALATE,KEEP" \
  ./loop.sh run >"$WORK/orch-planesc3.out" 2>&1 </dev/null || RC=$?
check "acked rerun exit 0" orch-planesc 0 "$RC"
check "state SUCCESS" orch-planesc SUCCESS "$(cat .loop/state)"
check "all phases completed after the release" orch-planesc 3 "$(qcount "done")"
# acking again must refuse cleanly (nothing escalated)
if ! LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet ack-plan phase-a >/dev/null 2>&1; then
  ok "double ack refused (no escalation left)"
else
  bad "double ack silently succeeded" orch-planesc
fi

section "plan-review: FLEET_PLAN_REVIEW=0 disables the boundary review"
make_orch_fixture orch-planoff 2
printf 'FLEET_PLAN_REVIEW=0\n' >> fleet.config.sh
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=CHAIN_SHARED LOOP_FAKE_SCENARIO=READY_TOUCH \
  ./loop.sh run >"$WORK/orch-planoff.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-planoff 0 "$RC"
if [ ! -f .loop/fake-planrev-i ]; then ok "no plan-review call with the knob off"; else bad "plan-review ran despite knob=0" orch-planoff; fi
if ! grep -qE '^PLAN_REVIEW=' .loop/fleet/runs/phase-a.env 2>/dev/null; then ok "no marker written with the knob off"; else bad "marker written despite knob=0" orch-planoff; fi

section "plan-review: a PENDING marker survives a crash — the restart re-enters the review"
make_sup_fixture fleet-planpend
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-a.md --auto >/dev/null 2>&1
ida=$(fleet_task_id alpha)
printf 'PLANNED=1\nREQS=REQ-001\n' >> ".loop/fleet/runs/$ida.env"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain > "$WORK/fleet-planpend1.out" 2>&1 </dev/null &
wait_sup $! fleet-planpend
check "first drain exit 0" fleet-planpend 0 "$RC"
check "task merged" fleet-planpend 1 "$(qcount "done")"
# simulate the crash window: merged with the marker set, review never ran
printf 'PLAN_REVIEW=PENDING\n' >> ".loop/fleet/runs/$ida.env"
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet add task-b.md --auto --after "$ida" >/dev/null 2>&1
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain > "$WORK/fleet-planpend2.out" 2>&1 </dev/null &
wait_sup $! fleet-planpend
check "second drain exit 0" fleet-planpend 0 "$RC"
if grep -q '"event": "PLAN_REVIEW_KEEP"' .loop/fleet/journal.jsonl; then ok "restart re-entered the pending review"; else bad "pending review not re-entered" fleet-planpend; fi
check "held dependent completed after the review" fleet-planpend 2 "$(qcount "done")"

