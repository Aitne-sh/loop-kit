#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "journal carries per-call turns; evidence gets its own cost row"
make_fixture turnsj
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW=APPROVE \
  LOOP_FAKE_STOPEVAL=CONTINUE LOOP_FAKE_TURNS=42 \
  ./loop.sh run >"$WORK/turnsj.out" 2>&1 </dev/null || RC=$?
check "exit 0" turnsj 0 "$RC"
if grep -q '"turns": 42' .loop/journal.jsonl; then ok "journal rows carry num_turns"; else bad "no turns field in the journal" turnsj; fi
if grep -q '"state": "EVIDENCE"' .loop/journal.jsonl; then ok "evidence role has a cost-bearing journal row"; else bad "EVIDENCE row missing" turnsj; fi

section "status/report surface lifetime + per-role cost"
make_fixture lifecost
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW=APPROVE \
  LOOP_FAKE_STOPEVAL=CONTINUE LOOP_FAKE_COST=0.5 \
  ./loop.sh run >"$WORK/lifecost1.out" 2>&1 </dev/null || RC=$?
check "run 1 exits 0" lifecost 0 "$RC"
# re-break the fixture so run 2 does real work (an empty diff would skip the
# gate review, collapsing the per-role expectations below)
echo broken > value.txt
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW=APPROVE \
  LOOP_FAKE_STOPEVAL=CONTINUE LOOP_FAKE_COST=0.25 \
  ./loop.sh run >"$WORK/lifecost2.out" 2>&1 </dev/null || RC=$?
check "run 2 exits 0" lifecost 0 "$RC"
# run 1: implement + gate review + evidence at $0.5 = $1.5; run 2 same shape at
# $0.25 = $0.75 — lifetime $2.25 over 2 runs, deterministic
STATUS_OUT=$(./loop.sh status 2>/dev/null)
if echo "$STATUS_OUT" | grep -q 'lifetime, 2 runs'; then ok "status counts runs"; else bad "status lifetime missing: $(echo "$STATUS_OUT" | grep cost:)" lifecost; fi
if echo "$STATUS_OUT" | grep -qF "\$2.2500 lifetime"; then ok "status sums lifetime cost across runs"; else bad "status lifetime sum wrong: $(echo "$STATUS_OUT" | grep cost:)" lifecost; fi
REPORT_OUT=$(./loop.sh report --text 2>/dev/null || true)
if echo "$REPORT_OUT" | grep -qF "lifetime cost: \$2.2500 across 2 runs"; then ok "report shows the lifetime total"; else bad "report lifetime wrong: $(echo "$REPORT_OUT" | grep lifetime)" lifecost; fi
if echo "$REPORT_OUT" | grep -qF "implement \$0.2500 | review interim \$0.0000 / gate \$0.2500 | plan \$0.0000 | evidence \$0.2500 | stop-eval \$0.0000"; then ok "per-role cost table (last run)"; else bad "role table wrong: $(echo "$REPORT_OUT" | grep 'cost by role')" lifecost; fi

section "lifetime cost: decompose rows between runs must not clobber a run's total"
# synthetic journal reproducing the default-config shape: the NEXT process
# journals a decompose row (with its own small, reset total) BEFORE its
# RUN_START — the previous run's $9.75 must still be counted (segment max).
make_fixture lifeseg
cat > .loop/journal.jsonl <<'EOF'
{"ts": "t", "iteration": "run", "state": "RUN_START", "reason": "baseline a", "cost_usd": 0, "total_usd": 0, "turns": 0}
{"ts": "t", "iteration": "final", "state": "SUCCESS", "reason": "done", "cost_usd": 0, "total_usd": 9.75, "turns": 0}
{"ts": "t", "iteration": "decompose", "state": "DECOMPOSE_SINGLE", "reason": "plan yields one task", "cost_usd": 1.2, "total_usd": 1.2, "turns": 0}
{"ts": "t", "iteration": "run", "state": "RUN_START", "reason": "baseline b", "cost_usd": 0, "total_usd": 0, "turns": 0}
{"ts": "t", "iteration": "final", "state": "SUCCESS", "reason": "done", "cost_usd": 0, "total_usd": 5.5, "turns": 0}
EOF
STATUS_OUT=$(./loop.sh status 2>/dev/null)
if echo "$STATUS_OUT" | grep -qF "\$15.2500 lifetime, 2 runs"; then ok "status lifetime sums real run totals (9.75 + 5.5)"; else bad "status clobbered by the decompose row: $(echo "$STATUS_OUT" | grep cost:)" lifeseg; fi
REPORT_OUT=$(./loop.sh report --text 2>/dev/null || true)
if echo "$REPORT_OUT" | grep -qF "lifetime cost: \$15.2500 across 2 runs"; then ok "report lifetime agrees"; else bad "report lifetime wrong: $(echo "$REPORT_OUT" | grep lifetime)" lifeseg; fi

section "approval gate: contract edited after approve -> refuse to run"
make_fixture approve-gate
echo "human edit" >> .loop/docs/product-contract.md
run_loop "READY_NOW"
check "exit code 2" approve-gate 2 "$RC"
./loop.sh approve >/dev/null
run_loop "READY_NOW"
check "runs after re-approve" approve-gate 0 "$RC"

section "tampered config is NOT executed before hash verification"
make_fixture config-exec
printf '\ntouch pwned\n' >> loop.config.sh
run_loop "READY_NOW"
check "exit code 2" config-exec 2 "$RC"
if [ ! -f pwned ]; then ok "config code not executed"; else bad "SECURITY: tampered config executed" config-exec; fi

section "SHA-256 tool guard: digest parity + fail-fast when no tool exists"
make_fixture nosha
# parity: loop.sh's sha256() must produce byte-identical digests to an independent
# inline recipe, or every existing approval on this machine would go stale. Compute
# the baseline inline (NOT via the test's sha256() helper) so it stays an independent
# cross-check, and portably (shasum on macOS/perl, sha256sum on coreutils-only Linux).
expected=$(cat .loop/docs/product-contract.md loop.config.sh \
  | if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | awk '{print $1}')
check "approved digest matches an independent sha256 recipe (sha256() parity)" nosha "$expected" "$(cat .loop/approved)"
# PATH sandbox: symlink everything loop.sh plausibly needs EXCEPT a SHA-256 tool.
# If the environment still resolves one inside the sandbox (exotic setups), skip
# the sandbox half honestly rather than flake — the parity check above always runs.
SHABOX="$WORK/nosha-bin"
mkdir -p "$SHABOX"
for t in bash sh git awk sed grep cat mkdir mv rm cp ln ls dirname basename tr \
         sort uniq head tail wc date env printf echo uname find cut touch chmod \
         ps sleep mktemp od hostname readlink stat id expr diff cmp true false xargs; do
  p=$(command -v "$t" 2>/dev/null) || continue
  case "$p" in /*) ln -s "$p" "$SHABOX/$t" 2>/dev/null || true ;; esac
done
if env PATH="$SHABOX" "$SHABOX/sh" -c 'command -v shasum || command -v sha256sum' >/dev/null 2>&1; then
  echo "  skip: sandbox PATH still resolves a SHA-256 tool"
else
  RC=0
  out=$(env PATH="$SHABOX" ./loop.sh approve 2>&1) || RC=$?
  check "approve refuses without a SHA-256 tool (exit 2)" nosha 2 "$RC"
  case "$out" in
    *SHA-256*) ok "error names the missing SHA-256 tool" ;;
    *) bad "unclear no-sha error: $out" nosha ;;
  esac
fi

section "harness tamper (skill edited between runs) -> refuse to run"
make_fixture harness-tamper
echo "# tampered" >> .claude/skills/loop-iterate/SKILL.md
run_loop "READY_NOW"
check "exit code 2" harness-tamper 2 "$RC"

section "recursive Codex skill resource tamper -> refuse to run"
make_fixture codex-resource-tamper
mkdir -p .agents/skills/loop-iterate/references
printf 'approved resource\n' > .agents/skills/loop-iterate/references/runtime-notes.md
./loop.sh approve >/dev/null
printf 'tampered resource\n' >> .agents/skills/loop-iterate/references/runtime-notes.md
run_loop "READY_NOW"
check "nested managed skill resource exits 2" codex-resource-tamper 2 "$RC"
if grep -Eq '\.agents|provider skills' "$WORK/last-run.out"; then
  ok "recursive Codex skill tamper is explained as harness drift"
else
  bad "nested Codex skill drift was not explained: $(cat "$WORK/last-run.out")" codex-resource-tamper
fi

section "forged .loop/approved cannot defeat contract immutability"
make_fixture forge-approval
run_loop "FORGE_APPROVAL"
check "exit code 3" forge-approval 3 "$RC"
check "state NEEDS_SPEC_DECISION" forge-approval NEEDS_SPEC_DECISION "$STATE"

section "evaluator tampered mid-run + forged harness hash -> RISK_REQUIRES_APPROVAL"
make_fixture eval-tamper
run_loop "TAMPER_EVALUATOR"
check "exit code 3" eval-tamper 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" eval-tamper RISK_REQUIRES_APPROVAL "$STATE"
if grep -q '"state": "SUCCESS"' .loop/journal.jsonl; then
  bad "tampered evaluator reached SUCCESS" eval-tamper
else
  ok "tampered evaluator never certified success"
fi

section "implementer cannot delete the evaluator-owned observation manifest"
make_fixture manifest-tamper
printf '{"ac_id":"AC-OLD","artifact_path":".loop/observations/old.log","artifact_sha256":"deadbeef"}\n' > .loop/observations-manifest.jsonl
run_loop "TAMPER_MANIFEST"
check "manifest deletion exits 3" manifest-tamper 3 "$RC"
check "manifest deletion is RISK" manifest-tamper RISK_REQUIRES_APPROVAL "$STATE"
if grep -q 'observations-manifest changed or disappeared' "$WORK/last-run.out"; then ok "manifest integrity failure named"; else bad "manifest deletion reason missing" manifest-tamper; fi

section "evidence agent editing code after review -> BLOCKED"
make_fixture evidence-tamper
export LOOP_FAKE_EVIDENCE=TAMPER
run_loop "READY_NOW"
unset LOOP_FAKE_EVIDENCE
check "exit code 4" evidence-tamper 4 "$RC"
check "state BLOCKED" evidence-tamper BLOCKED "$STATE"
if grep -q "changed code after review" "$WORK/last-run.out"; then ok "unreviewed evidence diff detected"; else bad "wrong block reason" evidence-tamper; fi

section "evidence agent changing certification inputs after review -> BLOCKED"
make_fixture evidence-auth-tamper
export LOOP_FAKE_EVIDENCE=TAMPER_AUTH
run_loop "READY_NOW"
unset LOOP_FAKE_EVIDENCE
check "exit code 4" evidence-auth-tamper 4 "$RC"
check "state BLOCKED" evidence-auth-tamper BLOCKED "$STATE"
if grep -q "changed certification inputs after review" "$WORK/last-run.out"; then ok "post-review authority mutation detected"; else bad "authority tamper reason missing" evidence-auth-tamper; fi
if [ ! -f .loop/docs/certification.json ]; then ok "authority tamper was never certified"; else bad "tampered authority received a certificate" evidence-auth-tamper; fi

section "evidence generation must create a fresh non-template report"
make_fixture evidence-no-report
export LOOP_FAKE_EVIDENCE=NO_REPORT
run_loop "READY_NOW"
unset LOOP_FAKE_EVIDENCE
check "missing current report blocks" evidence-no-report 4 "$RC"
if grep -q "current evidence report is invalid" "$WORK/last-run.out"; then ok "missing current report named"; else bad "missing-report reason absent" evidence-no-report; fi

section "evidence report cannot cite an artifact outside the verified checklist"
make_fixture evidence-bad-ref
mkdir -p .loop/observations
printf 'invented\n' > .loop/observations/not-in-checklist.log
export LOOP_FAKE_EVIDENCE=BAD_REPORT_REF
run_loop "READY_NOW"
unset LOOP_FAKE_EVIDENCE
check "invented report artifact blocks" evidence-bad-ref 4 "$RC"
if grep -q "outside the verified checklist" "$WORK/last-run.out"; then ok "invented report reference rejected"; else bad "invented reference reason absent" evidence-bad-ref; fi

section "certification commit cannot run repository hooks after final review"
make_fixture cert-hook
cat > .git/hooks/pre-commit <<'EOF'
#!/bin/sh
if git diff --cached --name-only | grep -q '^.loop/docs/certification.json$'; then
  echo "post-review hook mutation" > cert-hook-pwned.txt
fi
EOF
chmod +x .git/hooks/pre-commit
run_loop "READY_NOW"
check "certificate with hostile hook still succeeds safely" cert-hook 0 "$RC"
if [ ! -e cert-hook-pwned.txt ]; then ok "certification bypassed repository hooks"; else bad "certification hook mutated the product tree" cert-hook; fi

section "iteration 0 generates plan from template"
make_fixture plan-gen
printf '<!-- TEMPLATE -->\n# Implementation Plan\n' > .loop/docs/implementation-plan.md
git add -A && git commit -q -m "template plan"
./loop.sh approve >/dev/null
run_loop "READY_NOW"
check "exit code 0" plan-gen 0 "$RC"
if ! grep -q 'TEMPLATE' .loop/docs/implementation-plan.md; then ok "plan generated"; else bad "plan still template" plan-gen; fi
if grep -q 'fake-plan' .loop/fake-models; then ok "plan model routed"; else bad "plan model missing" plan-gen; fi
if grep -q '## Key decisions' .loop/docs/implementation-plan.md \
   && grep -q 'REQ-001' .loop/docs/implementation-plan.md \
   && [ ! -e .loop/plan-candidates ]; then
  ok "harness published a schema-valid plan and cleared the staging area"
else
  bad "published plan not schema-shaped or staging residue left" plan-gen
fi
if grep -q -- 'fake-plan --tools=Read,Glob,Grep' .loop/fake-tools 2>/dev/null; then
  ok "iteration-0 plan ran under the read-only planner profile"
else
  bad "plan tool restriction missing: $(sort -u .loop/fake-tools 2>/dev/null | tr '\n' ' ')" plan-gen
fi

section "an implementation-plan with wrong REQ coverage is refused twice (no publication)"
make_fixture plan-req-mismatch
printf '<!-- TEMPLATE -->\n# Implementation Plan\n' > .loop/docs/implementation-plan.md
git add -A && git commit -q -m "template plan"
./loop.sh approve >/dev/null
RC=0
LOOP_FAKE_PLAN=REQ_MISMATCH LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/plan-req-mismatch.out" 2>&1 </dev/null || RC=$?
if [ "$RC" -ne 0 ] \
   && grep -q 'retrying once against the validator feedback' "$WORK/plan-req-mismatch.out" \
   && grep -q 'implementation planning failed twice' "$WORK/plan-req-mismatch.out" \
   && grep -q '→ next:' "$WORK/plan-req-mismatch.out" \
   && grep -q 'TEMPLATE' .loop/docs/implementation-plan.md \
   && [ ! -e .loop/plan-candidates ]; then
  ok "invalid candidate refused on both attempts; the template plan stayed unpublished"
else
  bad "invalid plan candidate escaped (rc=$RC)" plan-req-mismatch
fi

section "plan validator retry: invalid attempt 1, valid attempt 2 publishes"
make_fixture plan-retry-ok
printf '<!-- TEMPLATE -->\n# Implementation Plan\n' > .loop/docs/implementation-plan.md
git add -A && git commit -q -m "template plan"
./loop.sh approve >/dev/null
RC=0
LOOP_FAKE_PLAN="REQ_MISMATCH,READY" LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/plan-retry-ok.out" 2>&1 </dev/null || RC=$?
check "exit 0" plan-retry-ok 0 "$RC"
check "state SUCCESS" plan-retry-ok SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q 'retrying once against the validator feedback' "$WORK/plan-retry-ok.out" \
   && [ -s .loop/fake-plan-fb-seen ] \
   && [ -s .loop/fake-implplanrev-i ] \
   && ! grep -q 'TEMPLATE' .loop/docs/implementation-plan.md \
   && [ ! -f .loop/plan-feedback.md ]; then
  ok "validator feedback survived into the retry; review ran; attempt 2 published"
else
  bad "plan validator retry path broken (rc=$RC)" plan-retry-ok
fi

section "plan review REVISE regenerates once, then approves and publishes"
make_fixture plan-review-revise
printf '<!-- TEMPLATE -->\n# Implementation Plan\n' > .loop/docs/implementation-plan.md
git add -A && git commit -q -m "template plan"
./loop.sh approve >/dev/null
RC=0
LOOP_FAKE_IMPL_PLAN_REVIEW="REVISE,APPROVE" LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/plan-review-revise.out" 2>&1 </dev/null || RC=$?
check "exit 0" plan-review-revise 0 "$RC"
check "state SUCCESS" plan-review-revise SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q 'plan review -> REVISE' "$WORK/plan-review-revise.out" \
   && grep -q 'plan review -> APPROVE' "$WORK/plan-review-revise.out" \
   && grep -q '"state": "IMPL_PLAN_REVIEW_REGEN"' .loop/journal.jsonl \
   && [ "$(cat .loop/fake-plan-i)" = "2" ] \
   && [ ! -f .loop/plan-review-feedback.md ]; then
  ok "REVISE fed one regeneration; the re-review approved and the harness published"
else
  bad "plan review regen path broken (rc=$RC)" plan-review-revise
fi

section "plan review rejects twice -> stop naming the feedback path"
make_fixture plan-review-reject
printf '<!-- TEMPLATE -->\n# Implementation Plan\n' > .loop/docs/implementation-plan.md
git add -A && git commit -q -m "template plan"
./loop.sh approve >/dev/null
RC=0
LOOP_FAKE_IMPL_PLAN_REVIEW=REVISE LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/plan-review-reject.out" 2>&1 </dev/null || RC=$?
if [ "$RC" -ne 0 ] \
   && grep -q 'failed the independent plan review' "$WORK/plan-review-reject.out" \
   && grep -q '→ next:' "$WORK/plan-review-reject.out" \
   && grep -q 'TEMPLATE' .loop/docs/implementation-plan.md \
   && [ ! -e .loop/plan-candidates ] \
   && [ -f .loop/plan-review-feedback.md ]; then
  ok "double REVISE stopped the run; feedback file kept for the human"
else
  bad "plan review double-REVISE path broken (rc=$RC)" plan-review-reject
fi

section "LOOP_PLAN_REVIEW=0 skips the plan review entirely"
make_fixture plan-review-off
printf '<!-- TEMPLATE -->\n# Implementation Plan\n' > .loop/docs/implementation-plan.md
git add -A && git commit -q -m "template plan"
./loop.sh approve >/dev/null
RC=0
LOOP_PLAN_REVIEW=0 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/plan-review-off.out" 2>&1 </dev/null || RC=$?
check "exit 0" plan-review-off 0 "$RC"
check "state SUCCESS" plan-review-off SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
if [ ! -e .loop/fake-implplanrev-i ] && ! grep -q 'plan review ->' "$WORK/plan-review-off.out"; then
  ok "no plan-review call was made"
else
  bad "plan review ran despite LOOP_PLAN_REVIEW=0" plan-review-off
fi

section "plan review rides AGENT_REVIEW=codex under the read-only sandbox"
make_fixture plan-review-codex
printf 'AGENT_REVIEW="codex"\nMODEL_REVIEW="gpt-5.5-review"\n' >> loop.models.sh
printf '<!-- TEMPLATE -->\n# Implementation Plan\n' > .loop/docs/implementation-plan.md
git add -A && git commit -q -m "template plan"
./loop.sh approve >/dev/null
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/plan-review-codex.out" 2>&1 </dev/null || RC=$?
check "exit 0" plan-review-codex 0 "$RC"
prv_line=$(grep -n 'loop-plan-review' .loop/fake-codex-prompts 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$prv_line" ] && sed -n "${prv_line}p" .loop/fake-codex-args | grep -q 'read-only'; then
  ok "the plan-review call ran on Codex with --sandbox read-only"
else
  bad "plan-review Codex posture wrong (prompt line: ${prv_line:-none})" plan-review-codex
fi

section "a non-template implementation plan is reused: no planner call, no plan review"
make_fixture plan-reuse
cat > .loop/docs/implementation-plan.md <<'EOF'
# Implementation Plan

## Key decisions

- Existing hand-written plan, kept.
- Deterministic verification stays authoritative.
- Scope stays inside the approved contract.

## Milestones

- [ ] M1: implement and verify REQ-001

## Current blockers

- None.

## Notes / learnings

- Hand-written plan for the reuse test.
EOF
git add -A && git commit -q -m "hand-written plan"
./loop.sh approve >/dev/null
run_loop "READY_NOW"
check "exit 0" plan-reuse 0 "$RC"
check "state SUCCESS" plan-reuse SUCCESS "$STATE"
if [ ! -e .loop/fake-plan-i ] && [ ! -e .loop/fake-implplanrev-i ]; then
  ok "reused plan skipped both the planner and the plan review"
else
  bad "reuse path spent planner/review calls" plan-reuse
fi

section "an iteration-0 planner stray write fails closed to RISK"
make_fixture plan-stray
printf '<!-- TEMPLATE -->\n# Implementation Plan\n' > .loop/docs/implementation-plan.md
git add -A && git commit -q -m "template plan"
./loop.sh approve >/dev/null
RC=0
LOOP_FAKE_PLAN_TAMPER=PROJECT LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/plan-stray.out" 2>&1 </dev/null || RC=$?
check "exit 3" plan-stray 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" plan-stray RISK_REQUIRES_APPROVAL "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q 'project files or Git state changed during iteration-0 planning' "$WORK/plan-stray.out" \
   && grep -q 'Risk review required' "$WORK/plan-stray.out"; then
  ok "planning-step containment names the phase and shows the risk box"
else
  bad "plan stray containment message wrong" plan-stray
fi

section "max iterations exhausted"
make_fixture max-iter
# verify output varies per iteration so the repeated-failure fingerprint never fires
printf '#!/bin/sh\ncat notes.txt 2>/dev/null\ngrep -q fixed value.txt\n' > check.sh
git add -A && git commit -q -m "varying verify output"
run_loop "BAD_FIX,BAD_FIX,BAD_FIX,BAD_FIX"
check "exit code 5" max-iter 5 "$RC"
check "state BUDGET_EXCEEDED" max-iter BUDGET_EXCEEDED "$STATE"

section "auto mode: instruction file -> headless contract -> auto-approve -> SUCCESS"
make_fixture auto-full nocontract
# loop-instruction.md is gitignored (a harness file); cmd_auto reads it from the working tree
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh auto >"$WORK/last-run.out" 2>&1 </dev/null || RC=$?
STATE=$(cat .loop/state 2>/dev/null || echo none)
check "exit code 0" auto-full 0 "$RC"
check "state SUCCESS" auto-full SUCCESS "$STATE"
if grep -q '"state": "CONTRACT_AUTO"' .loop/journal.jsonl; then ok "headless contract journaled"; else bad "CONTRACT_AUTO missing" auto-full; fi
if grep -q '"state": "CONTRACT_REVIEW_APPROVE"' .loop/journal.jsonl; then ok "independent contract review gated the auto-approval"; else bad "CONTRACT_REVIEW_APPROVE missing" auto-full; fi
if grep -q '"state": "AUTO_APPROVED"' .loop/journal.jsonl; then ok "auto-approval audited"; else bad "AUTO_APPROVED missing" auto-full; fi
# E8c: the headless definition call now carries html=auto, so its skip decision
# is journaled (HTML_SKIPPED) — HTML_UNDECLARED for the contract step is gone
if grep -q '"iteration": "contract", "state": "HTML_SKIPPED"' .loop/journal.jsonl; then
  ok "contract step declares its HTML decision (HTML_SKIPPED)"
else
  bad "contract HTML_SKIPPED missing" auto-full
fi
if ! grep -q '"state": "HTML_UNDECLARED"' .loop/journal.jsonl; then
  ok "no HTML_UNDECLARED anywhere in the auto run"
else
  bad "HTML_UNDECLARED still journaled" auto-full
fi
n=$(grep -c '"iteration": "contract", "state": "HTML_' .loop/journal.jsonl || true)
check "exactly one HTML decision for the contract step (no double record)" auto-full 1 "$n"
# E8b: without LOOP_ASK_CRITICAL the contract-review prompt carries no ask token
if grep -q '/loop-contract-review' .loop/fake-conrev-prompts 2>/dev/null \
   && ! grep -q 'ask=critical' .loop/fake-conrev-prompts; then
  ok "contract-review prompt carries no ask token outside ask mode"
else
  bad "ask token leaked into a non-ask contract review: $(cat .loop/fake-conrev-prompts 2>/dev/null | tr '\n' ' ')" auto-full
fi

section "auto mode: existing unapproved contract -> approve + run"
make_fixture auto-approve noapprove
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh auto >"$WORK/last-run.out" 2>&1 </dev/null || RC=$?
STATE=$(cat .loop/state 2>/dev/null || echo none)
check "exit code 0" auto-approve 0 "$RC"
check "state SUCCESS" auto-approve SUCCESS "$STATE"

section "auto mode: contract review REVISE -> regenerate once -> APPROVE -> SUCCESS"
make_fixture auto-conrev nocontract
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_CONTRACT_REVIEW="REVISE,APPROVE" \
  ./loop.sh auto >"$WORK/last-run.out" 2>&1 </dev/null || RC=$?
STATE=$(cat .loop/state 2>/dev/null || echo none)
check "exit code 0" auto-conrev 0 "$RC"
check "state SUCCESS" auto-conrev SUCCESS "$STATE"
if grep -q '"state": "CONTRACT_REVIEW_REVISE"' .loop/journal.jsonl \
   && grep -q '"state": "CONTRACT_REGEN"' .loop/journal.jsonl \
   && grep -q '"state": "CONTRACT_REVIEW_APPROVE"' .loop/journal.jsonl; then
  ok "revise -> regenerate -> approve journaled in order-independent form"
else
  bad "contract-review regen flow missing from journal" auto-conrev
fi
if [ ! -f .loop/contract-review-feedback.md ]; then ok "feedback cleared after approve"; else bad "stale contract feedback left" auto-conrev; fi

section "auto mode: contract review rejects twice -> NEEDS_SPEC_DECISION, never approved"
make_fixture auto-conrev-block nocontract
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_CONTRACT_REVIEW="REVISE" \
  ./loop.sh auto >"$WORK/last-run.out" 2>&1 </dev/null || RC=$?
STATE=$(cat .loop/state 2>/dev/null || echo none)
check "exit code 3 (human decision)" auto-conrev-block 3 "$RC"
check "state NEEDS_SPEC_DECISION" auto-conrev-block NEEDS_SPEC_DECISION "$STATE"
if [ ! -f .loop/approved ]; then ok "rejected definition was never approved"; else bad "rejected contract was approved" auto-conrev-block; fi
if [ -f .loop/contract-review-feedback.md ]; then ok "feedback kept for the human"; else bad "feedback missing" auto-conrev-block; fi

section "auto mode: unparseable contract-review verdict fails safe to REVISE"
make_fixture auto-conrev-noverdict nocontract
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_CONTRACT_REVIEW="NOVERDICT" \
  ./loop.sh auto >"$WORK/last-run.out" 2>&1 </dev/null || RC=$?
STATE=$(cat .loop/state 2>/dev/null || echo none)
check "exit code 3" auto-conrev-noverdict 3 "$RC"
check "state NEEDS_SPEC_DECISION" auto-conrev-noverdict NEEDS_SPEC_DECISION "$STATE"

section "auto mode: LOOP_CONTRACT_REVIEW=0 opts out of the gate"
make_fixture auto-conrev-off nocontract
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_CONTRACT_REVIEW="REVISE" LOOP_CONTRACT_REVIEW=0 \
  ./loop.sh auto >"$WORK/last-run.out" 2>&1 </dev/null || RC=$?
STATE=$(cat .loop/state 2>/dev/null || echo none)
check "exit code 0 (gate disabled)" auto-conrev-off 0 "$RC"
check "state SUCCESS" auto-conrev-off SUCCESS "$STATE"
if ! grep -q 'CONTRACT_REVIEW' .loop/journal.jsonl; then ok "no contract review ran"; else bad "review ran despite opt-out" auto-conrev-off; fi

section "ask-first auto: critical unknowns park the run instead of assuming through them"
make_fixture ask-park nocontract
echo "migrate the data store" > loop-instruction.md
RC=0
LOOP_ASK_CRITICAL=1 LOOP_FAKE_CONTRACT=QUESTIONS LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  ./loop.sh auto >"$WORK/ask-park.out" 2>&1 </dev/null || RC=$?
check "exit code 3" ask-park 3 "$RC"
check "state PENDING_APPROVAL" ask-park PENDING_APPROVAL "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q '^## DR-CONTRACT' .loop/docs/decision-requests.md; then ok "critical question recorded as a DR-CONTRACT block"; else bad "DR-CONTRACT block missing" ask-park; fi
if grep -q 'Human decision required' "$WORK/ask-park.out" \
   && grep -q '## DR-CONTRACT' "$WORK/ask-park.out" \
   && ! grep -q 'DR-N: <one-line title>' "$WORK/ask-park.out"; then
  ok "PENDING shows the real DR block without the pristine template example"
else
  bad "PENDING display lost the DR block or leaked the template" ask-park
fi
if grep -q '"state": "CONTRACT_QUESTIONS"' .loop/journal.jsonl; then ok "park journaled as CONTRACT_QUESTIONS"; else bad "CONTRACT_QUESTIONS missing" ask-park; fi
if [ ! -f .loop/approved ]; then ok "parked definition was never approved"; else bad "parked contract was auto-approved" ask-park; fi
# the human answers, approves, runs — the loop proceeds normally from there
printf '\n## Decision\n- park unconvertible rows, never delete\n' >> .loop/docs/product-contract.md
git add -A && git commit -q -m "human answered the critical unknown"
./loop.sh approve >/dev/null
run_loop "READY_NOW"
check "answered + approved contract runs to SUCCESS (exit 0)" ask-park 0 "$RC"
check "state SUCCESS" ask-park SUCCESS "$STATE"

section "ask-first auto: READY verdict (safe defaults) proceeds to auto-approval"
make_fixture ask-ready nocontract
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_ASK_CRITICAL=1 LOOP_FAKE_CONTRACT=READY LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  ./loop.sh auto >"$WORK/ask-ready.out" 2>&1 </dev/null || RC=$?
check "exit code 0" ask-ready 0 "$RC"
check "state SUCCESS" ask-ready SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q '"state": "AUTO_APPROVED"' .loop/journal.jsonl; then ok "auto-approval proceeded (no park)"; else bad "AUTO_APPROVED missing" ask-ready; fi

section "ask-first auto: unparseable generator verdict fails closed to a human"
make_fixture ask-malformed nocontract
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_ASK_CRITICAL=1 LOOP_FAKE_CONTRACT=MALFORMED LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh auto >"$WORK/ask-malformed.out" 2>&1 </dev/null || RC=$?
check "exit code 3" ask-malformed 3 "$RC"
check "state PENDING_APPROVAL" ask-malformed PENDING_APPROVAL "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q '"state": "CONTRACT_QUESTIONS_MALFORMED"' .loop/journal.jsonl; then ok "malformed verdict journaled honestly"; else bad "CONTRACT_QUESTIONS_MALFORMED missing" ask-malformed; fi

section "ask-first auto: contract reviewer ESCALATE parks with the question preserved"
make_fixture ask-review-escalate nocontract
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_ASK_CRITICAL=1 LOOP_FAKE_CONTRACT=READY LOOP_FAKE_CONTRACT_REVIEW=ESCALATE LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh auto >"$WORK/ask-review-escalate.out" 2>&1 </dev/null || RC=$?
check "exit code 3" ask-review-escalate 3 "$RC"
check "state PENDING_APPROVAL" ask-review-escalate PENDING_APPROVAL "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q 'is deleting user data acceptable' .loop/docs/decision-requests.md; then ok "reviewer's question preserved in the decision request"; else bad "reviewer's question lost" ask-review-escalate; fi
if grep -q '"state": "CONTRACT_REVIEW_ESCALATE"' .loop/journal.jsonl; then ok "escalation journaled"; else bad "CONTRACT_REVIEW_ESCALATE missing" ask-review-escalate; fi
# E8e: the review-ESCALATE park path used to journal the contract HTML decision
# twice (generate + park) — every path must record it exactly once
n=$(grep -c '"iteration": "contract", "state": "HTML_' .loop/journal.jsonl || true)
check "exactly one HTML decision on the escalate-park path" ask-review-escalate 1 "$n"

section "ask-first auto: the reviewer prompt carries ask=critical (initial call AND retry)"
# E8b: the harness honors a reviewer ESCALATE only when the prompt carries the
# ask token — so the token must be observable in the reviewer's own prompt, on
# the first call and on the unparseable-verdict retry alike.
make_fixture ask-esc-token nocontract
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_ASK_CRITICAL=1 LOOP_FAKE_CONTRACT=READY LOOP_FAKE_CONTRACT_REVIEW="NOVERDICT,APPROVE" \
  LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  ./loop.sh auto >"$WORK/ask-esc-token.out" 2>&1 </dev/null || RC=$?
check "exit code 0 (retry parsed the second verdict)" ask-esc-token 0 "$RC"
check "state SUCCESS" ask-esc-token SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
check "reviewer called twice (unparseable verdict retried)" ask-esc-token 2 \
  "$(grep -c '/loop-contract-review' .loop/fake-conrev-prompts 2>/dev/null || true)"
check "both reviewer prompts carry ask=critical" ask-esc-token 2 \
  "$(grep -c 'ask=critical' .loop/fake-conrev-prompts 2>/dev/null || true)"
if grep -q 'ESCALATE' .loop/fake-conrev-prompts; then
  ok "the format-reminder retry names the ESCALATE option in ask mode"
else
  bad "retry prompt does not mention ESCALATE" ask-esc-token
fi

