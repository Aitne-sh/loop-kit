#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "two-iteration success (review + stop-eval each iteration)"
make_fixture two-iter
run_loop "CONTINUE_FIX,READY_NOW"
check "exit code 0" two-iter 0 "$RC"
check "state SUCCESS" two-iter SUCCESS "$STATE"
n=$(grep -c '"state": "CONTINUE"' .loop/journal.jsonl || true)
check "one CONTINUE iteration" two-iter 1 "$n"
if grep -q '"state": "STOP_EVAL_CONTINUE"' .loop/journal.jsonl; then ok "stop-eval ran"; else bad "stop-eval missing" two-iter; fi
if grep -q 'fake-stop' .loop/fake-models; then ok "stop-eval model routed"; else bad "stop-eval model missing" two-iter; fi
if grep -q -- 'fake-stop --tools=Read,Glob,Grep' .loop/fake-tools 2>/dev/null; then
  ok "stop-eval session structurally read-only"
else
  bad "stop-eval restriction flags missing" tools-restrict
fi

section "reviewer REVISE feeds improvement, then APPROVE -> SUCCESS"
make_fixture revise-approve
run_loop "READY_NOW,READY_NOW" "REVISE,APPROVE"
check "exit code 0" revise-approve 0 "$RC"
check "state SUCCESS" revise-approve SUCCESS "$STATE"
if grep -q '"state": "REVIEW_REVISE"' .loop/journal.jsonl && grep -q '"state": "REVIEW_APPROVE"' .loop/journal.jsonl; then
  ok "revise then approve recorded"
else
  bad "review verdicts missing" revise-approve
fi
if [ ! -f .loop/review-feedback.md ]; then ok "feedback cleared after approve"; else bad "stale feedback left" revise-approve; fi

section "reviewer rejects repeatedly -> BLOCKED"
make_fixture review-block
run_loop "READY_NOW,READY_NOW,READY_NOW" "REVISE,REVISE,REVISE"
check "exit code 4" review-block 4 "$RC"
check "state BLOCKED" review-block BLOCKED "$STATE"
if [ -f .loop/review-feedback.md ]; then ok "feedback kept for human"; else bad "feedback missing" review-block; fi

section "stop-eval FUTILE twice -> STALLED"
make_fixture futile
run_loop "BAD_FIX,BAD_FIX" "APPROVE" "FUTILE,FUTILE"
check "exit code 4" futile 4 "$RC"
check "state STALLED" futile STALLED "$STATE"

section "a stop-evaluator outage breaks the FUTILE streak (crash is not a verdict)"
make_fixture futile-crash
# CONTINUE_GREEN keeps verify green with fresh progress each iteration: the
# repeat-failure/stagnation stops stay quiet, so all three stop-eval verdicts
# actually run (BAD_FIX would trip REPEAT_FAIL_N=3 before the third one)
run_loop "CONTINUE_GREEN,CONTINUE_GREEN,CONTINUE_GREEN" "APPROVE" "FUTILE,CRASH,FUTILE,CONTINUE"
if ! grep -q 'judged the loop futile' .loop/journal.jsonl "$WORK/last-run.out"; then
  ok "FUTILE -> crash -> FUTILE never counted as futile-twice"
else
  bad "futility STALLED fired across a stop-eval outage" futile-crash
fi
if grep -q '"state": "STOP_EVAL_ERROR"' .loop/journal.jsonl; then ok "outage journaled"; else bad "STOP_EVAL_ERROR missing" futile-crash; fi
n=$(grep -c '"state": "STOP_EVAL_FUTILE"' .loop/journal.jsonl || true)
check "both FUTILE verdicts still recorded" futile-crash 2 "$n"

section "no_op (already green, no changes needed)"
make_fixture noop
echo fixed > value.txt
git add -A && git commit -q -m "already fixed"
run_loop "NO_DIFF_READY"
check "exit code 0" noop 0 "$RC"
check "state NO_OP" noop NO_OP "$STATE"

section "false READY is not success (verify gate holds)"
make_fixture false-ready
run_loop "READY_BUT_BROKEN,READY_BUT_BROKEN"
if [ "$STATE" != "SUCCESS" ] && [ "$RC" -ne 0 ]; then ok "false claim rejected (state $STATE)"; else bad "false READY produced success" false-ready; fi

section "contract drift -> NEEDS_SPEC_DECISION"
make_fixture drift
run_loop "TOUCH_CONTRACT"
check "exit code 3" drift 3 "$RC"
check "state NEEDS_SPEC_DECISION" drift NEEDS_SPEC_DECISION "$STATE"

section "denied path -> RISK_REQUIRES_APPROVAL"
make_fixture denied
run_loop "TOUCH_DENIED"
check "exit code 3" denied 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" denied RISK_REQUIRES_APPROVAL "$STATE"
# E12a: the RISK epilogue must warn that approving keeps the flagged change
if grep -q 'approving without reverting accepts this change permanently' "$WORK/last-run.out"; then
  ok "RISK epilogue warns before approval (review the diff first)"
else
  bad "RISK finish epilogue missing" denied
fi

section "wildcard denied path (glob must not be filename-expanded)"
make_fixture denied-glob
run_loop "TOUCH_DENIED_GLOB"
check "exit code 3" denied-glob 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" denied-glob RISK_REQUIRES_APPROVAL "$STATE"

section "agent edits its own skills -> RISK_REQUIRES_APPROVAL"
make_fixture skill-tamper
run_loop "TOUCH_SKILL"
check "exit code 3" skill-tamper 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" skill-tamper RISK_REQUIRES_APPROVAL "$STATE"

section "gitignored loop.models.sh tampered mid-run -> RISK_REQUIRES_APPROVAL"
make_fixture models-tamper
run_loop "TAMPER_MODELS"
check "exit code 3" models-tamper 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" models-tamper RISK_REQUIRES_APPROVAL "$STATE"
if grep -q 'loop.models.sh or fleet.config.sh changed' "$WORK/last-run.out"; then
  ok "reason names the models/fleet config baseline"
else
  bad "wrong reason for models tamper" models-tamper
fi

section "agent writes .mcp.json (MCP server injection) -> RISK_REQUIRES_APPROVAL"
make_fixture mcp-tamper
run_loop "TOUCH_MCP"
check "exit code 3" mcp-tamper 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" mcp-tamper RISK_REQUIRES_APPROVAL "$STATE"

section "gitignored .claude/settings.local.json tamper caught by the in-memory baseline"
make_fixture settings-tamper
printf '.claude/settings.local.json\n' >> .gitignore
git add -A && git commit -q -m "project gitignores local settings"
run_loop "TOUCH_SETTINGS"
check "exit code 3" settings-tamper 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" settings-tamper RISK_REQUIRES_APPROVAL "$STATE"
if grep -q 'session config changed' "$WORK/last-run.out"; then
  ok "reason names the session config"
else
  bad "wrong reason for settings tamper" settings-tamper
fi

section "escalate path -> NEEDS_ARCHITECTURE_DECISION"
make_fixture escalate
run_loop "TOUCH_ESCALATE"
check "exit code 3" escalate 3 "$RC"
check "state NEEDS_ARCHITECTURE_DECISION" escalate NEEDS_ARCHITECTURE_DECISION "$STATE"

section "agent-declared spec decision"
make_fixture declare-spec
run_loop "DECLARE_SPEC"
check "exit code 3" declare-spec 3 "$RC"
check "state NEEDS_SPEC_DECISION" declare-spec NEEDS_SPEC_DECISION "$STATE"

section "agent-declared blocked"
make_fixture blocked
run_loop "DECLARE_BLOCKED"
check "exit code 4" blocked 4 "$RC"
check "state BLOCKED" blocked BLOCKED "$STATE"
# a BLOCKED dead-end that wrote a decision request must SHOW it — the human's
# "what should I look at" (e.g. a `human` row sign-off) must not stay buried
if grep -q 'Decision request(s) from this run' "$WORK/last-run.out" \
   && grep -q 'DR-1: missing credentials' "$WORK/last-run.out"; then
  ok "terminal output surfaces the decision request on BLOCKED"
else
  bad "decision request not shown on BLOCKED exit" blocked
fi

section "BLOCKED without any decision request stays quiet"
make_fixture blocked-quiet
run_loop "BAD_FIX,BAD_FIX,BAD_FIX"   # repeat-fail BLOCKED; fake writes no DR
check "exit code 4" blocked-quiet 4 "$RC"
check "state BLOCKED" blocked-quiet BLOCKED "$STATE"
if ! grep -q 'Decision request(s) from this run' "$WORK/last-run.out"; then
  ok "no decision-request banner when none was written"
else
  bad "banner printed with no DR entry (template leak)" blocked-quiet
fi


section "split gate: over GATE_SPLIT_LINES the gate runs core + erosion calls"
make_fixture gate-split
printf 'GATE_SPLIT_LINES=1\n' >> loop.config.sh
./loop.sh approve >/dev/null   # loop.config.sh is hash-governed — re-approve the edit
run_loop "READY_NOW" "APPROVE,APPROVE"
check "exit code 0" gate-split 0 "$RC"
check "state SUCCESS" gate-split SUCCESS "$STATE"
if grep -q 'mode=gate split=core' .loop/fake-review-prompts \
   && grep -q 'mode=gate scope=run split=erosion' .loop/fake-review-prompts; then
  ok "gate split into split=core and split=erosion review calls"
else
  bad "split tokens missing from review prompts: $(tr '\n' ';' < .loop/fake-review-prompts)" gate-split
fi
if grep -q '"state": "REVIEW_EROSION_APPROVE"' .loop/journal.jsonl; then
  ok "erosion approval journaled"
else
  bad "REVIEW_EROSION_APPROVE missing from journal" gate-split
fi

section "split gate: an erosion REVISE rejects the candidate and feeds back"
make_fixture gate-split-revise
printf 'GATE_SPLIT_LINES=1\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "READY_NOW,READY_NOW" "APPROVE,REVISE,APPROVE,APPROVE"
check "exit code 0" gate-split-revise 0 "$RC"
check "state SUCCESS" gate-split-revise SUCCESS "$STATE"
if grep -q '"state": "REVIEW_EROSION_REVISE"' .loop/journal.jsonl \
   && grep -q '"state": "REVIEW_EROSION_APPROVE"' .loop/journal.jsonl; then
  ok "erosion rejection then approval journaled"
else
  bad "erosion verdicts missing from journal" gate-split-revise
fi
if grep -q 'gate erosion review' "$WORK/last-run.out" \
   || grep -q '"state": "REVIEW_EROSION_REVISE"' .loop/journal.jsonl; then
  ok "erosion rejection surfaced"
else
  bad "erosion rejection invisible" gate-split-revise
fi

section "split gate: under the threshold the gate stays a single call"
make_fixture gate-nosplit
printf 'GATE_SPLIT_LINES=100000\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "READY_NOW" "APPROVE"
check "exit code 0" gate-nosplit 0 "$RC"
check "state SUCCESS" gate-nosplit SUCCESS "$STATE"
if ! grep -q 'split=' .loop/fake-review-prompts; then
  ok "no split tokens under the threshold"
else
  bad "split activated under the threshold" gate-nosplit
fi

section "review advisory: loop AC ids leaking into the product diff are journaled"
make_fixture ac-leak-warn
run_loop "CONTINUE_AC_LEAK,READY_NOW"
check "exit code 0 (advisory never blocks)" ac-leak-warn 0 "$RC"
check "state SUCCESS" ac-leak-warn SUCCESS "$STATE"
if grep -q '"state": "AC_ID_IN_PRODUCT_WARN"' .loop/journal.jsonl \
   && grep -q 'AC-001' .loop/journal.jsonl; then
  ok "product-diff AC id journaled as advisory WARN"
else
  bad "AC_ID_IN_PRODUCT_WARN missing from journal" ac-leak-warn
fi

section "review advisory: a clean product diff journals no AC-id warning"
make_fixture ac-leak-clean
run_loop "CONTINUE_FIX,READY_NOW"
check "exit code 0" ac-leak-clean 0 "$RC"
if ! grep -q '"state": "AC_ID_IN_PRODUCT_WARN"' .loop/journal.jsonl; then
  ok "no advisory on a clean diff"
else
  bad "spurious AC_ID_IN_PRODUCT_WARN" ac-leak-clean
fi
