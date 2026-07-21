#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- decision rebind (answer a NEEDS_* stop, then truly RESUME) ----------

section "decision rebind: approve after answering re-binds the checkpoint; run RESUMES"
make_fixture decision-resume
run_loop "DECLARE_SPEC,READY_NOW"
check "stopped for the decision (exit 3)" decision-resume 3 "$RC"
check "state NEEDS_SPEC_DECISION" decision-resume NEEDS_SPEC_DECISION "$STATE"
check "checkpoint records iteration 1" decision-resume 1 "$(ckpt_field ITERATION)"
starts_before=$(run_starts)
c1=$(cat .loop/cost-total)
printf '\n## Decision\n- REQ-002 wins; REQ-001 narrowed accordingly\n' >> .loop/docs/product-contract.md
./loop.sh approve >/dev/null
check "checkpoint re-bound (DECISION_REBOUND=1)" decision-resume 1 "$(ckpt_field DECISION_REBOUND)"
if [ -f .loop/supervisor-guidance.md ]; then ok "answer channel written for the next iteration"; else bad "supervisor-guidance.md missing" decision-resume; fi
if grep -q '"state": "DECISION_REBIND"' .loop/journal.jsonl; then ok "rebind journaled"; else bad "DECISION_REBIND missing" decision-resume; fi
resume_run "DECLARE_SPEC,READY_NOW" run
check "run after the decision exits 0" decision-resume 0 "$RC"
check "state SUCCESS" decision-resume SUCCESS "$STATE"
check "no second RUN_START (a true resume, not a restart)" decision-resume "$starts_before" "$(run_starts)"
if grep -q '"state": "RUN_RESUME"' .loop/journal.jsonl; then ok "RUN_RESUME journaled"; else bad "RUN_RESUME missing" decision-resume; fi
if awk -v a="$c1" -v b="$(cat .loop/cost-total)" 'BEGIN{exit !(b > a && a > 0)}'; then
  ok "cost kept accumulating across the decision (never reset)"
else
  bad "cost not preserved across the rebind ($c1 -> $(cat .loop/cost-total))" decision-resume
fi

section "decision stop without re-approval: resume refuses; edited contract refuses run"
make_fixture decision-refuse
run_loop "DECLARE_SPEC,READY_NOW"
check "stopped for the decision (exit 3)" decision-refuse 3 "$RC"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh resume >"$WORK/decision-refuse.out" 2>&1 </dev/null || RC=$?
check "resume without answering refused (exit 2)" decision-refuse 2 "$RC"
if grep -q 'human decision' "$WORK/decision-refuse.out"; then ok "refusal explains the pending decision"; else bad "unclear decision refusal" decision-refuse; fi
echo "unapproved edit" >> .loop/docs/product-contract.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/decision-refuse2.out" 2>&1 </dev/null || RC=$?
check "edited contract without approve refused (exit 2)" decision-refuse 2 "$RC"

section "decision rebind cannot be forged (DECISION_REBOUND without re-approval)"
make_fixture decision-forge
run_loop "DECLARE_SPEC,READY_NOW"
check "stopped for the decision (exit 3)" decision-forge 3 "$RC"
echo "forged goalpost edit" >> .loop/docs/product-contract.md
printf 'DECISION_REBOUND=1\n' >> .loop/run-checkpoint
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/decision-forge.out" 2>&1 </dev/null || RC=$?
check "forged rebind refused before running (exit 2)" decision-forge 2 "$RC"
check "state unchanged" decision-forge NEEDS_SPEC_DECISION "$(cat .loop/state)"

section "approval store: forging EVERY repo-local record still cannot resume a decision stop"
# E3/G1: the agent can write everything under the repo — the contract, both
# .loop/approved* mirrors (with correctly recomputed hashes) and the checkpoint's
# CONTRACT_HASH + DECISION_REBOUND. The off-tree store is the trust anchor that
# still refuses the run.
make_fixture forge-rebind
run_loop "DECLARE_SPEC,READY_NOW"
check "stopped for the decision (exit 3)" forge-rebind 3 "$RC"
check "state NEEDS_SPEC_DECISION" forge-rebind NEEDS_SPEC_DECISION "$STATE"
starts_before=$(run_starts)
echo "forged goalpost edit" >> .loop/docs/product-contract.md
cat .loop/docs/product-contract.md loop.config.sh | sha256 > .loop/approved
newh=$(cat .loop/approved)
{ grep -v '^CONTRACT_HASH=' .loop/run-checkpoint; echo "CONTRACT_HASH=$newh"; echo "DECISION_REBOUND=1"; } > .loop/run-checkpoint.t \
  && mv .loop/run-checkpoint.t .loop/run-checkpoint
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/forge-rebind.out" 2>&1 </dev/null || RC=$?
check "fully-forged run refused (exit 2)" forge-rebind 2 "$RC"
if grep -q 'approval store' "$WORK/forge-rebind.out"; then ok "refusal names the approval store"; else bad "refusal does not name the store: $(cat "$WORK/forge-rebind.out")" forge-rebind; fi
check "state unchanged" forge-rebind NEEDS_SPEC_DECISION "$(cat .loop/state)"
if ! grep -q '"state": "RUN_RESUME"' .loop/journal.jsonl; then ok "no resume happened"; else bad "forged run resumed" forge-rebind; fi
check "no new RUN_START either" forge-rebind "$starts_before" "$(run_starts)"
# a GENUINE re-approve (the human blessing the edited contract) populates the
# store and the same run then resumes normally
./loop.sh approve >/dev/null
resume_run "DECLARE_SPEC,READY_NOW" run
check "genuinely re-approved run resumes to SUCCESS" forge-rebind SUCCESS "$STATE"

section "approval store: LOOP_APPROVAL_HOME=repo pins the legacy repo-local-only behavior"
# The documented escape hatch for no-HOME/container environments — and the
# documented residual: with the store off, the same full forgery RESUMES.
make_fixture forge-rebind-repo
RC=0
LOOP_APPROVAL_HOME=repo LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/forge-repo1.out" 2>&1 </dev/null || RC=$?
check "stopped for the decision (exit 3)" forge-rebind-repo 3 "$RC"
echo "forged goalpost edit" >> .loop/docs/product-contract.md
cat .loop/docs/product-contract.md loop.config.sh | sha256 > .loop/approved
newh=$(cat .loop/approved)
{ grep -v '^CONTRACT_HASH=' .loop/run-checkpoint; echo "CONTRACT_HASH=$newh"; echo "DECISION_REBOUND=1"; } > .loop/run-checkpoint.t \
  && mv .loop/run-checkpoint.t .loop/run-checkpoint
RC=0
LOOP_APPROVAL_HOME=repo LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="DECLARE_SPEC,READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/forge-repo2.out" 2>&1 </dev/null || RC=$?
check "repo mode: the forged run resumes (pinned known limitation)" forge-rebind-repo 0 "$RC"
check "state SUCCESS" forge-rebind-repo SUCCESS "$(cat .loop/state)"
if grep -q '"state": "RUN_RESUME"' .loop/journal.jsonl; then
  ok "repo-local-only forgery resumed — exactly the residual the store closes"
else
  bad "repo mode did not resume (legacy behavior changed?)" forge-rebind-repo
fi

section "decision stop vs green gate: the display names the agent sandbox, not the gate"
# The incident shape: the agent finishes the work (evaluator gate all green)
# but still declares NEEDS_SPEC_DECISION claiming a command cannot run in its
# environment (e.g. a browser launch denied by the Codex seatbelt). The
# evaluator just re-ran every VERIFY_COMMAND outside that sandbox, so the stop
# display must say which environment the claim holds in.
make_fixture decision-green-note
run_loop "FIX_THEN_SPEC"
check "stopped for the decision (exit 3)" decision-green-note 3 "$RC"
check "state NEEDS_SPEC_DECISION" decision-green-note NEEDS_SPEC_DECISION "$STATE"
if grep -q 'not the verify gate' "$WORK/last-run.out"; then
  ok "green gate + decision stop prints the sandbox-vs-gate note"
else
  bad "sandbox-vs-gate note missing despite an all-green evaluator pass" decision-green-note
fi
# and the note NEVER prints while the gate itself is red — a red gate means
# the environment claim is untested there, so pointing the human away from
# the agent's report would mislead
make_fixture decision-red-note
run_loop "DECLARE_SPEC"
check "stopped for the decision (exit 3)" decision-red-note 3 "$RC"
if grep -q 'not the verify gate' "$WORK/last-run.out"; then
  bad "sandbox-vs-gate note printed although the evaluator gate is red" decision-red-note
else
  ok "no note while the evaluator gate is red"
fi

