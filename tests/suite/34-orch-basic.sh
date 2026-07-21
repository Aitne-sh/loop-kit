#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- orchestration (single entry: decompose -> single or fleet) ----------

section "orch: decompose n=1 routes to the classic in-place loop"
make_orch_fixture orch-single
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=ONE LOOP_FAKE_SCENARIO=READY_NOW \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/orch-single.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-single 0 "$RC"
check "state SUCCESS" orch-single SUCCESS "$(cat .loop/state)"
if grep -q '"state": "DECOMPOSE_SINGLE"' .loop/journal.jsonl; then ok "single routing journaled"; else bad "DECOMPOSE_SINGLE missing" orch-single; fi
if grep -q '"state": "DECOMPOSE_REVIEW_APPROVE"' .loop/journal.jsonl; then ok "plan passed independent review"; else bad "DECOMPOSE_REVIEW_APPROVE missing" orch-single; fi
if grep -q -- 'fake-dec --tools=Read,Glob,Grep' .loop/fake-tools 2>/dev/null; then
  ok "decompose ran under the read-only planner profile (no Write/Edit/Bash)"
else
  bad "decompose tool restriction missing: $(sort -u .loop/fake-tools 2>/dev/null | tr '\n' ' ')" orch-single
fi
check "no worktrees created" orch-single 1 "$(git worktree list | wc -l | tr -d ' ')"
if [ -f .loop/docs/task-plan.md ] && grep -q '^TASK: solo$' .loop/docs/task-plan.md; then ok "task plan written"; else bad "task-plan.md missing/wrong" orch-single; fi
if grep -q 'fake-dec' .loop/fake-models; then ok "decompose model routed (MODEL_DECOMPOSE)"; else bad "MODEL_DECOMPOSE not routed: $(sort -u .loop/fake-models | tr '\n' ' ')" orch-single; fi
if grep '"state": "DECOMPOSE_SINGLE"' .loop/journal.jsonl | grep -q 'rationale: One task (fake decomposition).'; then ok "single-task choice journals the plan rationale"; else bad "DECOMPOSE_SINGLE has no rationale: $(grep DECOMPOSE_SINGLE .loop/journal.jsonl | head -1)" orch-single; fi

section "orch: approved plan reused on the next fresh run (no second decompose call)"
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=ONE LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run --fresh >"$WORK/orch-reuse.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-reuse 0 "$RC"
check "decompose model called exactly once across both runs" orch-reuse 1 "$(cat .loop/fake-decompose-i 2>/dev/null)"
if grep -q '"state": "DECOMPOSE_REUSE"' .loop/journal.jsonl; then ok "reuse journaled"; else bad "DECOMPOSE_REUSE missing" orch-reuse; fi

section "Codex DECOMPOSE tampering is caught before plan publication"
make_orch_fixture orch-codex-decompose-tamper
printf 'AGENT_DECOMPOSE="codex"\nMODEL_DECOMPOSE="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_FAKE_DECOMPOSE_TAMPER=MODELS LOOP_FAKE_DECOMPOSE=ONE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh decompose --force >"$WORK/orch-codex-decompose-tamper.out" 2>&1 </dev/null || RC=$?
check "tampering decompose exits 3" orch-codex-decompose-tamper 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" orch-codex-decompose-tamper RISK_REQUIRES_APPROVAL "$(cat .loop/state)"
if grep -q 'loop-decompose/SKILL.md' .loop/fake-codex-prompts \
   && grep -q 'loop.models.sh or fleet.config.sh changed during decomposition' "$WORK/orch-codex-decompose-tamper.out" \
   && [ ! -f .loop/decompose-approved ]; then
  ok "Codex decomposition was routed, then stopped before its plan became approved"
else
  bad "decompose integrity check did not stop publication" orch-codex-decompose-tamper
fi

section "manual decompose bookkeeping re-adopts the run's cumulative cost"
make_orch_fixture orch-codex-decompose-cost
printf 'AGENT_DECOMPOSE="codex"\nMODEL_DECOMPOSE="gpt-5.5"\n' >> loop.models.sh
echo 3.21 > .loop/cost-total
RC=0
LOOP_FAKE_DECOMPOSE=ONE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh decompose --force >"$WORK/orch-codex-decompose-cost.out" 2>&1 </dev/null || RC=$?
check "decompose exits 0" orch-codex-decompose-cost 0 "$RC"
warn_total=$(grep '"state": "CODEX_COST_UNTRACKED"' .loop/journal.jsonl | tail -1 \
  | sed -E 's/.*"total_usd": ([0-9.]+).*/\1/')
check "warning row keeps the cumulative total" orch-codex-decompose-cost 3.21 "$warn_total"
if awk -v t="$(cat .loop/cost-total)" 'BEGIN{exit !(t >= 3.21)}'; then
  ok "manual decompose did not rewind the cost-total mirror"
else
  bad "manual decompose rewound .loop/cost-total to $(cat .loop/cost-total)" orch-codex-decompose-cost
fi
if grep -q 'sandbox=read-only' .loop/fake-codex-args \
   && grep -q 'project_doc_max_bytes=0' .loop/fake-codex-args; then
  ok "Codex decompose ran read-only with project instructions suppressed"
else
  bad "Codex decompose posture wrong: $(cat .loop/fake-codex-args 2>/dev/null | tr '\n' ' ')" orch-codex-decompose-cost
fi

section "a stray planner write fails closed to RISK with the risk box (not a DR)"
make_orch_fixture orch-decompose-stray
RC=0
LOOP_FAKE_DECOMPOSE_TAMPER=PROJECT LOOP_FAKE_DECOMPOSE=ONE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh decompose --force >"$WORK/orch-decompose-stray.out" 2>&1 </dev/null || RC=$?
check "stray project write exits 3" orch-decompose-stray 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" orch-decompose-stray RISK_REQUIRES_APPROVAL "$(cat .loop/state)"
if grep -q 'project files or Git state changed during decomposition' "$WORK/orch-decompose-stray.out" \
   && [ ! -f .loop/decompose-approved ] && [ ! -e .loop/plan-candidates ]; then
  ok "stray write stopped before publication and the staging area was discarded"
else
  bad "stray planner write was not contained" orch-decompose-stray
fi
if grep -q 'Risk review required' "$WORK/orch-decompose-stray.out" \
   && ! grep -q 'Human decision required' "$WORK/orch-decompose-stray.out" \
   && ! grep -q 'DR-N: <one-line title>' "$WORK/orch-decompose-stray.out" \
   && grep -q 'GUARD TRIP' "$WORK/orch-decompose-stray.out"; then
  ok "RISK stop shows the risk box, never an empty decision request"
else
  bad "RISK display leaked decision-request UI" orch-decompose-stray
fi

section "a planner that COMMITS its stray work is still caught (HEAD comparison)"
make_orch_fixture orch-decompose-stray-commit
RC=0
LOOP_FAKE_DECOMPOSE_TAMPER=PROJECT_COMMIT LOOP_FAKE_DECOMPOSE=ONE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh decompose --force >"$WORK/orch-decompose-stray-commit.out" 2>&1 </dev/null || RC=$?
check "committed stray exits 3" orch-decompose-stray-commit 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" orch-decompose-stray-commit RISK_REQUIRES_APPROVAL "$(cat .loop/state)"
if grep -q 'HEAD moved' "$WORK/orch-decompose-stray-commit.out"; then
  ok "clean-porcelain commit trick detected via HEAD comparison"
else
  bad "committed stray escaped detection" orch-decompose-stray-commit
fi

section "a malformed decompose envelope is rejected deterministically, then retried"
make_orch_fixture orch-decompose-envelope
RC=0
LOOP_FAKE_DECOMPOSE_SHAPE=DUP_ENVELOPE,NORMAL LOOP_FAKE_DECOMPOSE=ONE,ONE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh decompose --force >"$WORK/orch-decompose-envelope.out" 2>&1 </dev/null || RC=$?
check "second attempt publishes (exit 0)" orch-decompose-envelope 0 "$RC"
check "decompose called twice" orch-decompose-envelope 2 "$(cat .loop/fake-decompose-i 2>/dev/null)"
if grep '"state": "DECOMPOSE_INVALID"' .loop/journal.jsonl | grep -q 'one ordered' \
   && grep -q '^TASK: solo$' .loop/docs/task-plan.md \
   && [ ! -e .loop/plan-candidates ]; then
  ok "envelope violation reached the feedback loop; the harness published the retry"
else
  bad "envelope rejection/retry broken: $(grep DECOMPOSE_INVALID .loop/journal.jsonl | head -1)" orch-decompose-envelope
fi

section "decompose: harmless preamble prose before the envelope is tolerated (no retry burned)"
# a real $4.59 attempt was once rejected for one line of narration before the
# opening marker; the extraction is marker-bounded, so tolerance is lossless
make_orch_fixture orch-preamble
RC=0
LOOP_FAKE_DECOMPOSE_SHAPE=PRE_ENVELOPE_PROSE LOOP_FAKE_DECOMPOSE=ONE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh decompose --force >"$WORK/orch-preamble.out" 2>&1 </dev/null || RC=$?
check "first attempt publishes (exit 0)" orch-preamble 0 "$RC"
check "decompose called once" orch-preamble 1 "$(cat .loop/fake-decompose-i 2>/dev/null)"
if ! grep -q '"state": "DECOMPOSE_INVALID"' .loop/journal.jsonl \
   && grep -q '^TASK: solo$' .loop/docs/task-plan.md; then
  ok "preamble prose neither burned the attempt nor leaked into the published plan"
else
  bad "preamble tolerance broken: $(grep DECOMPOSE_INVALID .loop/journal.jsonl | head -1)" orch-preamble
fi

section "decompose: a stray envelope marker in the preamble still rejects (ambiguity is not prose)"
make_orch_fixture orch-preamble-dup
RC=0
LOOP_FAKE_DECOMPOSE_SHAPE=DUP_ENVELOPE,NORMAL LOOP_FAKE_DECOMPOSE=ONE,ONE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh decompose --force >"$WORK/orch-preamble-dup.out" 2>&1 </dev/null || RC=$?
check "duplicate envelope still rejected, retry publishes" orch-preamble-dup 0 "$RC"
check "decompose called twice" orch-preamble-dup 2 "$(cat .loop/fake-decompose-i 2>/dev/null)"

section "decompose: missing key is named precisely and the retry sees the rejected attempt"
# replays the auto_agent incident: DEPENDS dropped on attempt 1 — the feedback
# must name exactly DEPENDS, and attempt 2 must receive attempt 1's full bytes
make_orch_fixture orch-nodep
RC=0
LOOP_FAKE_DECOMPOSE=NODEPENDS,ONE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh decompose --force >"$WORK/orch-nodep.out" 2>&1 </dev/null || RC=$?
check "second attempt publishes (exit 0)" orch-nodep 0 "$RC"
if grep '"state": "DECOMPOSE_INVALID"' .loop/journal.jsonl | grep -q 'missing DEPENDS before BODY-BEGIN' \
   && ! grep '"state": "DECOMPOSE_INVALID"' .loop/journal.jsonl | grep -q 'missing SUMMARY'; then
  ok "validator named exactly the absent key"
else
  bad "missing key not named precisely: $(grep DECOMPOSE_INVALID .loop/journal.jsonl | head -1)" orch-nodep
fi
if grep -q -- '--- PREVIOUS REJECTED ATTEMPT (verbatim) ---' .loop/fake-decompose-fb-full 2>/dev/null \
   && grep -q '^TASK: nodeps$' .loop/fake-decompose-fb-full; then
  ok "retry saw the full rejected attempt below the error line"
else
  bad "rejected attempt not carried into the retry: $(head -4 .loop/fake-decompose-fb-full 2>/dev/null | tr '\n' ' ')" orch-nodep
fi
if [ ! -f .loop/decompose-feedback.md ]; then
  ok "enriched feedback still cleared after the successful attempt"
else
  bad "stale enriched feedback survived success" orch-nodep
fi

section "orch: decompose review REVISE regenerates once, then approves"
make_orch_fixture orch-drev
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE="ONE,ONE" LOOP_FAKE_DECOMPOSE_REVIEW="REVISE,APPROVE" \
  LOOP_FAKE_SCENARIO=READY_NOW ./loop.sh run >"$WORK/orch-drev.out" 2>&1 </dev/null || RC=$?
check "exit 0" orch-drev 0 "$RC"
if grep -q '"state": "DECOMPOSE_REVIEW_REVISE"' .loop/journal.jsonl && grep -q '"state": "DECOMPOSE_REVIEW_APPROVE"' .loop/journal.jsonl; then
  ok "review REVISE -> regen -> APPROVE journaled"
else
  bad "review chain missing" orch-drev
fi
check "decompose called twice (regen)" orch-drev 2 "$(cat .loop/fake-decompose-i 2>/dev/null)"

section "orch: decompose review rejects twice -> NEEDS_SPEC_DECISION (exit 3)"
make_orch_fixture orch-drev2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=ONE LOOP_FAKE_DECOMPOSE_REVIEW=REVISE \
  ./loop.sh run >"$WORK/orch-drev2.out" 2>&1 </dev/null || RC=$?
check "exit 3" orch-drev2 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-drev2 NEEDS_SPEC_DECISION "$(cat .loop/state)"
if [ -f .loop/decompose-review-feedback.md ]; then ok "review feedback kept for the human"; else bad "feedback missing" orch-drev2; fi
if grep -q -- '--- PREVIOUS REJECTED ATTEMPT (verbatim) ---' .loop/decompose-review-feedback.md 2>/dev/null \
   && grep -q '^TASK: solo$' .loop/decompose-review-feedback.md; then
  ok "review feedback carries the rejected plan verbatim for the human"
else
  bad "rejected plan missing from review feedback" orch-drev2
fi

section "orch: invalid plan (cycle) burns no review call; valid retry succeeds"
make_orch_fixture orch-dinv
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE="CYCLE,ONE" LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-dinv.out" 2>&1 </dev/null || RC=$?
check "exit 0 (cycle caught, retry ran the loop)" orch-dinv 0 "$RC"
check "state SUCCESS" orch-dinv SUCCESS "$(cat .loop/state)"
if grep -q '"state": "DECOMPOSE_INVALID"' .loop/journal.jsonl; then ok "invalid attempt journaled"; else bad "DECOMPOSE_INVALID missing" orch-dinv; fi
check "review ran once (only after the valid plan)" orch-dinv 1 "$(cat .loop/fake-decrev-i 2>/dev/null)"
# the retry (call 2) must see attempt 1's validator feedback — exactly one
# sighting: attempt 1 starts clean, attempt 2 reads the cycle error
check "retry saw the validator feedback (one sighting)" orch-dinv 1 "$(wc -l < .loop/fake-decompose-fb-seen 2>/dev/null | tr -d ' ')"
if grep -q 'cycle' .loop/fake-decompose-fb-seen; then ok "feedback content reached the retry"; else bad "retry feedback content wrong: $(cat .loop/fake-decompose-fb-seen 2>/dev/null)" orch-dinv; fi
if [ ! -f .loop/decompose-feedback.md ]; then ok "feedback cleared after the successful attempt"; else bad "stale decompose-feedback.md survived success" orch-dinv; fi

section "orch: mechanical task-id violation normalized deterministically (no model round-trip)"
make_orch_fixture orch-longid 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=LONGID LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/orch-longid.out" 2>&1 </dev/null || RC=$?
check "exit 0 (plan repaired in place, fleet ran)" orch-longid 0 "$RC"
check "decompose model called exactly once (no retry burned)" orch-longid 1 "$(cat .loop/fake-decompose-i 2>/dev/null)"
if grep '"state": "DECOMPOSE_NORMALIZED"' .loop/journal.jsonl | grep -q "task id 'orchestrator-controlflow-fixes' -> 'orchestrator-controlflow'"; then ok "rename journaled with old -> new"; else bad "DECOMPOSE_NORMALIZED missing/wrong: $(grep DECOMPOSE_NORMALIZED .loop/journal.jsonl)" orch-longid; fi
if [ -f .loop/fleet/runs/orchestrator-controlflow.env ]; then ok "queue/runs use the normalized id"; else bad "normalized id missing from runs/: $(ls .loop/fleet/runs/ 2>/dev/null)" orch-longid; fi
if grep -q 'orchestrator-controlflow' "$(ls .loop/fleet/runs/part-b.env 2>/dev/null || echo /dev/null)" \
   && ! grep -q 'controlflow-fixes' "$(ls .loop/fleet/runs/part-b.env 2>/dev/null || echo /dev/null)"; then
  ok "DEPENDS rewired to the normalized id"
else
  bad "DEPENDS not rewired: $(grep -i depends .loop/fleet/runs/part-b.env 2>/dev/null)" orch-longid
fi

section "orch: REQ coverage mismatch caught deterministically (exit 3 after two tries)"
make_orch_fixture orch-noreq 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=NOREQ \
  ./loop.sh run >"$WORK/orch-noreq.out" 2>&1 </dev/null || RC=$?
check "exit 3" orch-noreq 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-noreq NEEDS_SPEC_DECISION "$(cat .loop/state)"
if grep -q 'REQ' .loop/decompose-feedback.md; then ok "feedback names the coverage gap"; else bad "feedback missing REQ detail" orch-noreq; fi
if [ ! -f .loop/fake-decrev-i ]; then ok "no review calls burned on invalid plans"; else bad "review ran on an invalid plan" orch-noreq; fi

section "orch: parallel REQ sharing rejected deterministically (completing-owner rule)"
# a REQ shared by tasks with no single completing owner must never enqueue
make_orch_fixture orch-sharepar 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=SHARED_PAR \
  ./loop.sh run >"$WORK/orch-sharepar.out" 2>&1 </dev/null || RC=$?
check "exit 3" orch-sharepar 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-sharepar NEEDS_SPEC_DECISION "$(cat .loop/state)"
if grep -q 'single completing owner' .loop/decompose-feedback.md; then ok "feedback names the completing-owner violation"; else bad "shape violation not named: $(cat .loop/decompose-feedback.md 2>/dev/null | head -3 | tr '\n' ' ')" orch-sharepar; fi
if [ ! -f .loop/fake-decrev-i ]; then ok "no review calls burned on the invalid plan"; else bad "review ran on an invalid plan" orch-sharepar; fi

section "orch: join-less forked REQ sharing rejected (no completing owner)"
make_orch_fixture orch-sharefork 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=SHARED_FORK \
  ./loop.sh run >"$WORK/orch-sharefork.out" 2>&1 </dev/null || RC=$?
check "exit 3" orch-sharefork 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-sharefork NEEDS_SPEC_DECISION "$(cat .loop/state)"
if grep -q 'single completing owner' .loop/decompose-feedback.md; then ok "join-less fork rejected with the completing-owner reason"; else bad "fork not rejected for owner shape" orch-sharefork; fi

section "orch: a diamond with TWO parallel joins is rejected (no single completing owner)"
make_orch_fixture orch-twosinks 2
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=SHARED_TWOSINKS \
  ./loop.sh run >"$WORK/orch-twosinks.out" 2>&1 </dev/null || RC=$?
check "exit 3" orch-twosinks 3 "$RC"
check "state NEEDS_SPEC_DECISION" orch-twosinks NEEDS_SPEC_DECISION "$(cat .loop/state)"
if grep -q 'single completing owner' .loop/decompose-feedback.md; then ok "two-sink diamond rejected with the completing-owner reason"; else bad "two-sink diamond not rejected: $(cat .loop/decompose-feedback.md 2>/dev/null | head -3 | tr '\n' ' ')" orch-twosinks; fi

section "fleet: queued PLANNED tasks refuse to resume under a changed contract"
# an interrupted orchestration leaves queue + FLEET_RUNNING; if the human then
# approves a DIFFERENT contract, resuming would dispatch/merge/gate contract A's
# tasks against contract B — the fleet analogue of the single-loop checkpoint
# CONTRACT_HASH guard. decompose-approved is the contract<->plan binding.
make_orch_fixture bind-swap
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=ONE \
  ./loop.sh decompose >/dev/null 2>&1 </dev/null || true   # writes task-plan + decompose-approved for contract A
if [ -f .loop/decompose-approved ]; then ok "plan bound to contract A (decompose-approved)"; else bad "decompose preview did not write the binding" bind-swap; fi
# synthesize the interrupted-orchestration residue: a PLANNED task still queued
mkdir -p .loop/fleet/queue/new .loop/fleet/runs
printf 'fix value.txt (planned under contract A)\n' > .loop/fleet/queue/new/t1.md
printf 'PLANNED=1\n' > .loop/fleet/runs/t1.env
echo FLEET_RUNNING > .loop/state
# the contract changes hands mid-flight
printf '\n### REQ-002\nnewly invented requirement.\n' >> .loop/docs/product-contract.md
git add -A && git commit -q -m "contract swapped mid-orchestration"
./loop.sh approve >/dev/null 2>&1 </dev/null
RC=0
./loop.sh run >"$WORK/bind-swap.out" 2>&1 </dev/null || RC=$?
check "run refuses to resume (exit 2)" bind-swap 2 "$RC"
if grep -q 'DIFFERENT contract' "$WORK/bind-swap.out"; then ok "refusal names the cause"; else bad "wrong refusal: $(tail -2 "$WORK/bind-swap.out" | tr '\n' ' ')" bind-swap; fi
RC=0
./loop.sh fleet run --drain >"$WORK/bind-swap2.out" 2>&1 </dev/null || RC=$?
check "fleet run --drain also refuses (exit 2)" bind-swap 2 "$RC"
if grep -q 'DIFFERENT contract' "$WORK/bind-swap2.out"; then ok "manual fleet adoption blocked too"; else bad "fleet run adopted a swapped-contract queue" bind-swap; fi

