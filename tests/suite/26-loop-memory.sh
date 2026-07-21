#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- contract-scoped loop memory (lifecycle boundaries) ----------

section "new task definition archives + resets the previous task's loop memory"
make_fixture memreset
# simulate a finished/parked run of task A: filled memory on every surface
cat >> .loop/docs/decision-requests.md <<'EOF'

## DR-9: stale question from the previous task
- Question: should the old thing frob?
EOF
cat > .loop/docs/progress.md <<'EOF'
# Progress
## Iteration 1
- did old-task things
EOF
cat > .loop/docs/requirements-ledger.md <<'EOF'
# Requirements Ledger

| REQ | Status | Evidence | Iter |
|---|---|---|---|
| REQ-001 | met | old task evidence | 1 |
EOF
mkdir -p .loop/reports
echo '<html>stale</html>' > .loop/reports/old-view.html
echo 'stale guidance' > .loop/supervisor-guidance.md
echo '[PASS] stale baseline from task A' > .loop/baseline-verify.log
git add -A && git commit -q -m "old task residue"
RC=0
LOOP_FAKE_CONTRACT=READY LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh start "brand new unrelated task" >"$WORK/memreset.out" 2>&1 </dev/null || RC=$?
check "exit 0 (definition written, approval deferred)" memreset 0 "$RC"
if grep -q '<!-- TEMPLATE -->' .loop/docs/decision-requests.md && ! grep -q 'DR-9' .loop/docs/decision-requests.md; then
  ok "decision-requests reset to template (no stale DR)"
else bad "stale DR-9 survived the new definition" memreset; fi
if grep -q '<!-- TEMPLATE -->' .loop/docs/requirements-ledger.md; then ok "ledger reset (no aliased met rows)"; else bad "old met ledger rows survived" memreset; fi
if grep -q '<!-- TEMPLATE -->' .loop/docs/progress.md; then ok "progress reset"; else bad "old progress survived" memreset; fi
if [ ! -f .loop/reports/old-view.html ]; then ok "stale HTML views wiped"; else bad "stale HTML view survived" memreset; fi
if [ ! -f .loop/supervisor-guidance.md ]; then ok "stale supervisor guidance wiped"; else bad "stale guidance survived" memreset; fi
if [ ! -f .loop/baseline-verify.log ]; then ok "stale baseline verify log wiped at new-task definition"; else bad "stale baseline-verify.log survived" memreset; fi
arch=""
for d in .loop/docs/run-archive/*-root; do [ -d "$d" ] && arch="$d" && break; done
if [ -n "$arch" ] && grep -q 'DR-9' "$arch/decision-requests.md" 2>/dev/null; then ok "old memory archived in run-archive/"; else bad "archive missing or incomplete" memreset; fi
# grep -c, not grep -q: -q exits at first match and git log then dies of SIGPIPE
# (141) under pipefail — the suite's documented trap (see the resume-recover note)
if [ "$(git log --format=%s | grep -c 'archive previous loop memory')" -ge 1 ]; then ok "archive committed (git trail)"; else bad "archive commit missing" memreset; fi
if grep -q '"state": "MEMORY_RESET"' .loop/journal.jsonl; then ok "reset journaled"; else bad "MEMORY_RESET missing" memreset; fi
if grep -q 'auto-generated' .loop/docs/product-contract.md; then ok "new definition written after the reset"; else bad "new contract missing" memreset; fi
if grep -q 'verify gate (every command must exit 0 for SUCCESS):' "$WORK/memreset.out"; then ok "approval summary surfaces the verify gate"; else bad "verify gate missing from the approval summary" memreset; fi
if grep -qF 'VERIFY_COMMANDS=("./check.sh")' "$WORK/memreset.out"; then ok "approval summary prints the VERIFY_COMMANDS block"; else bad "VERIFY_COMMANDS block missing from approval summary" memreset; fi

section "reset ledger blocks premature READY under the new contract (REQ-alias regression)"
# without the reset, task A's 'REQ-001 met' row would alias the NEW contract's
# REQ-001 and let iteration 1's dishonest READY straight through the gate
./loop.sh approve >/dev/null 2>&1 </dev/null
run_loop "READY_NO_LEDGER,READY_NOW"
check "exit 0" memreset-ledger 0 "$RC"
check "state SUCCESS" memreset-ledger SUCCESS "$STATE"
if grep -q 'requirements ledger does not show met' .loop/journal.jsonl; then
  ok "premature READY refused — stale met rows are gone"
else
  bad "premature READY passed the gate: the REQ-alias bug is back" memreset-ledger
fi

section "hand-edit + approve = amendment: loop memory kept (headless default)"
make_fixture amend
cat > .loop/docs/progress.md <<'EOF'
# Progress
## Iteration 1
- real memory from this task
EOF
printf '\n### Clarification\n- answered decision: use option (a)\n' >> .loop/docs/product-contract.md
git add -A && git commit -q -m "human amends the contract"
RC=0
./loop.sh approve >"$WORK/amend.out" 2>&1 </dev/null || RC=$?
check "exit 0" amend 0 "$RC"
if grep -q 'real memory from this task' .loop/docs/progress.md; then ok "memory kept on amendment"; else bad "amendment wiped memory" amend; fi
if grep -q 'KEEPING the loop memory' "$WORK/amend.out"; then ok "headless keep is loud"; else bad "keep warning missing" amend; fi
if grep -q '"state": "MEMORY_CARRIED"' .loop/journal.jsonl; then ok "carry journaled"; else bad "MEMORY_CARRIED missing" amend; fi

section "auto mode: contract REPLACED outside a definition session fails closed (exit 3)"
make_fixture auto-replace
printf '# Product Contract\n## Goal\ntotally different task\n## Requirements\n### REQ-001\nsomething else entirely.\n' > .loop/docs/product-contract.md
git add -A && git commit -q -m "wholesale replacement"
RC=0
LOOP_AUTO=1 ./loop.sh approve >"$WORK/auto-replace.out" 2>&1 </dev/null || RC=$?
check "exit 3 (intent unknown, fail closed)" auto-replace 3 "$RC"
if grep -q '"state": "APPROVE_REFUSED"' .loop/journal.jsonl; then ok "refusal journaled"; else bad "APPROVE_REFUSED missing" auto-replace; fi
if grep -q 'M1: fix value.txt' .loop/docs/implementation-plan.md; then ok "memory untouched by the refusal"; else bad "refusal mutated memory" auto-replace; fi
# ...but the documented decision-answer flow (a decision state is pending) amends freely
echo NEEDS_SPEC_DECISION > .loop/state
RC=0
LOOP_AUTO=1 ./loop.sh approve >"$WORK/auto-amend.out" 2>&1 </dev/null || RC=$?
check "exit 0 (decision-answer amendment in auto mode)" auto-replace 0 "$RC"
if grep -q 'keeping loop memory' "$WORK/auto-amend.out"; then ok "auto amendment keeps memory"; else bad "auto amendment note missing" auto-replace; fi

section "fresh run clears stale run-scoped signals (guidance / verify log / req-verdicts)"
make_fixture runscope
echo 'stale answer to a question nobody asked' > .loop/supervisor-guidance.md
echo '[PASS] stale green light' > .loop/last-verify.log
echo '[PASS] stale baseline green' > .loop/baseline-verify.log
echo 'REQ-001: MET - stale verdict' > .loop/req-verdicts
printf '# OLD EVIDENCE VIEW\nprior run only\n' > .loop/docs/evidence-report.md
printf '{"final_state":"OLD","preflight":"STALE"}\n' > .loop/docs/certification.json
run_loop "READY_NOW"
check "exit 0" runscope 0 "$RC"
if ! grep -q 'nobody asked' .loop/supervisor-guidance.md 2>/dev/null; then ok "stale guidance cleared at fresh-run start"; else bad "stale guidance survived" runscope; fi
if ! grep -q 'stale green light' .loop/last-verify.log 2>/dev/null; then ok "stale verify log cleared"; else bad "stale verify log survived" runscope; fi
if ! grep -q 'stale verdict' .loop/req-verdicts 2>/dev/null; then ok "stale req-verdicts cleared"; else bad "stale req-verdicts survived" runscope; fi
if ! grep -q 'stale baseline green' .loop/baseline-verify.log 2>/dev/null && grep -q '^\[FAIL\] ./check.sh' .loop/baseline-verify.log 2>/dev/null; then ok "stale baseline log replaced by this run's real red baseline"; else bad "stale baseline log survived or real baseline missing" runscope; fi
if find .loop/docs/run-archive -path '*-prevrun/evidence-report.md' -type f -exec grep -q 'OLD EVIDENCE VIEW' {} \; -print | grep -q .; then
  ok "prior evidence report archived before fresh iteration 1"
else
  bad "prior evidence report was not retired as history" runscope
fi
if ! grep -q 'OLD EVIDENCE VIEW' .loop/docs/evidence-report.md; then ok "current report no longer exposes stale prior-run content"; else bad "stale evidence report survived fresh run" runscope; fi
if find .loop/docs/run-archive -path '*-prevrun/certification.json' -type f -exec grep -q '"final_state":"OLD"' {} \; -print | grep -q .; then
  ok "prior certificate archived with its evidence view"
else
  bad "prior certificate was not retired as history" runscope
fi
check "live certificate belongs to the current run" runscope SUCCESS "$(json_scalar .loop/docs/certification.json final_state)"

section "gate APPROVE without per-REQ verdicts downgraded to REVISE (fail closed)"
make_fixture gate-noreqs
run_loop "READY_NOW,READY_NOW" "APPROVE_NOREQS,APPROVE"
check "exit code 0" gate-noreqs 0 "$RC"
check "state SUCCESS (second, complete gate passed)" gate-noreqs SUCCESS "$STATE"
if grep -q 'harness downgrade' .loop/journal.jsonl; then ok "downgrade journaled honestly"; else bad "downgrade not journaled" gate-noreqs; fi
if grep -q '"state": "REVIEW_REVISE"' .loop/journal.jsonl; then ok "first gate recorded as REVISE"; else bad "no gate rejection recorded" gate-noreqs; fi
check "final req-verdicts all MET" gate-noreqs "REQ-001: MET - fake per-REQ verdict" "$(cat .loop/req-verdicts 2>/dev/null || echo missing)"

section "gate APPROVE contradicting its own UNMET line downgraded (halo guard)"
make_fixture gate-unmet
run_loop "READY_NOW,READY_NOW" "APPROVE_UNMET,APPROVE"
check "exit code 0" gate-unmet 0 "$RC"
check "state SUCCESS" gate-unmet SUCCESS "$STATE"
if grep -q 'harness downgrade' .loop/journal.jsonl; then ok "UNMET-vs-APPROVE contradiction downgraded"; else bad "contradiction not downgraded" gate-unmet; fi
if grep -q 'REQ-001: UNMET' .loop/review-feedback.md 2>/dev/null || grep -q '"state": "REVIEW_REVISE"' .loop/journal.jsonl; then
  ok "rejection carried the analytic finding"
else
  bad "analytic finding lost" gate-unmet
fi

section "empty task diff runs state-review; missing per-REQ table is still downgraded"
make_fixture gate-state
echo fixed > value.txt
seed_ledger_met
git add -A && git commit -q -m "task already satisfied"
./loop.sh approve >/dev/null
export LOOP_FAKE_STATE_REVIEW="APPROVE_NOREQS,APPROVE"
run_loop "READY_NOW,READY_NOW"
unset LOOP_FAKE_STATE_REVIEW
check "empty-diff task exits 0 after an explicit state approval" gate-state 0 "$RC"
check "genuine task-wide no-op is certified NO_OP" gate-state NO_OP "$STATE"
if grep -q 'mode=gate scope=state' .loop/fake-review-prompts; then ok "empty diff invoked gate scope=state"; else bad "state-review prompt missing" gate-state; fi
if grep -q 'harness downgrade' .loop/journal.jsonl; then ok "state-review per-REQ omission downgraded"; else bad "state review bypassed per-REQ guard" gate-state; fi
if ! grep -q 'REVIEW_SKIPPED' .loop/journal.jsonl; then ok "empty gate was never treated as SKIPPED success"; else bad "SKIPPED reached the gate" gate-state; fi

section "empty task diff cannot succeed without an explicit reviewer APPROVE"
make_fixture gate-state-noapprove
echo fixed > value.txt
seed_ledger_met
git add -A && git commit -q -m "task already satisfied"
./loop.sh approve >/dev/null
export LOOP_FAKE_STATE_REVIEW="CRASH"
run_loop "READY_NOW"
unset LOOP_FAKE_STATE_REVIEW
check "review outage blocks the empty-diff gate" gate-state-noapprove 4 "$RC"
check "state is BLOCKED, never NO_OP" gate-state-noapprove BLOCKED "$STATE"
if grep -q 'cannot certify success' "$WORK/last-run.out"; then ok "explicit APPROVE backstop explains the block"; else bad "missing explicit-approval failure" gate-state-noapprove; fi

section "task-start-ref survives --fresh, so committed task work is not mislabeled NO_OP"
make_fixture task-base-fresh
run_loop "CONTINUE_FIX,DECLARE_BLOCKED"
check "first run parks after committing task work" task-base-fresh BLOCKED "$STATE"
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh run --fresh >"$WORK/task-base-fresh.out" 2>&1 </dev/null || RC=$?
STATE=$(cat .loop/state 2>/dev/null || echo none)
check "fresh retry succeeds" task-base-fresh 0 "$RC"
check "task-wide change is SUCCESS, not current-run NO_OP" task-base-fresh SUCCESS "$STATE"
if grep 'mode=gate' .loop/fake-review-prompts | tail -1 | grep -qv 'scope=state'; then ok "fresh retry reviewed the original task diff"; else bad "fresh retry lost the task baseline" task-base-fresh; fi

section "invalid task-start-ref falls back safely and disables NO_OP"
make_fixture task-base-invalid
run_loop "CONTINUE_FIX,DECLARE_BLOCKED"
common=$(git rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
gitdir=$(git rev-parse --absolute-git-dir)
repo_id=$(printf '%s' "$common" | sha256)
slot_id=$(printf '%s' "$gitdir" | sha256)
tref="$LOOP_APPROVAL_HOME/$repo_id/$slot_id/task-start-ref"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$tref"
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh run --fresh >"$WORK/task-base-invalid.out" 2>&1 </dev/null || RC=$?
STATE=$(cat .loop/state 2>/dev/null || echo none)
check "fallback run succeeds" task-base-invalid 0 "$RC"
check "invalid baseline cannot produce NO_OP" task-base-invalid SUCCESS "$STATE"
if grep -q 'TASK_BASE_FALLBACK' .loop/journal.jsonl; then ok "invalid baseline warning journaled"; else bad "task baseline fallback not journaled" task-base-invalid; fi

section "task-start-ref is pinned as a full object id and live replacement is RISK"
make_fixture task-base-tamper
run_loop "TAMPER_TASK_REF"
check "task baseline replacement exits 3" task-base-tamper 3 "$RC"
check "task baseline replacement is RISK" task-base-tamper RISK_REQUIRES_APPROVAL "$STATE"
if grep -q 'task-start-ref changed or disappeared' "$WORK/last-run.out"; then ok "baseline integrity failure named"; else bad "baseline replacement reason missing" task-base-tamper; fi

section "symbolic task-start-ref is never resolved as a moving gate baseline"
make_fixture task-base-symbolic
# Seed a legacy/forged symbolic value before the process pins the task anchor.
common=$(git rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
gitdir=$(git rev-parse --absolute-git-dir)
repo_id=$(printf '%s' "$common" | sha256)
slot_id=$(printf '%s' "$gitdir" | sha256)
mkdir -p "$LOOP_APPROVAL_HOME/$repo_id/$slot_id"
printf 'HEAD\n' > "$LOOP_APPROVAL_HOME/$repo_id/$slot_id/task-start-ref"
run_loop "READY_NOW"
check "symbolic baseline run still verifies" task-base-symbolic 0 "$RC"
check "symbolic baseline disables NO_OP" task-base-symbolic SUCCESS "$STATE"
if grep -q 'TASK_BASE_FALLBACK' .loop/journal.jsonl; then ok "symbolic baseline fell back explicitly"; else bad "symbolic baseline was accepted" task-base-symbolic; fi

section "gate ESCALATE -> NEEDS_SPEC_DECISION with a decision request"
make_fixture gate-escalate
run_loop "READY_NOW" "ESCALATE"
check "exit code 3" gate-escalate 3 "$RC"
check "state NEEDS_SPEC_DECISION" gate-escalate NEEDS_SPEC_DECISION "$STATE"
if grep -q 'DR-GATE-' .loop/docs/decision-requests.md; then ok "decision request appended"; else bad "DR-GATE entry missing" gate-escalate; fi
if grep -q 'archived records' .loop/docs/decision-requests.md; then ok "reviewer's question preserved verbatim"; else bad "question lost" gate-escalate; fi
if grep -q '"state": "REVIEW_ESCALATE"' .loop/journal.jsonl; then ok "escalation journaled"; else bad "REVIEW_ESCALATE missing" gate-escalate; fi
if grep -q 'gate reviewer escalated' "$WORK/last-run.out"; then ok "finish reason names the escalation"; else bad "finish reason missing" gate-escalate; fi

section "holistic cadence: every Nth interim review widens to the whole run"
make_fixture holistic-cadence
printf 'HOLISTIC_EVERY_N=2\nHOLISTIC_TRIGGER_LINES=0\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "CONTINUE_FIX,BAD_FIX,READY_NOW"
check "exit code 0" holistic-cadence 0 "$RC"
check "state SUCCESS" holistic-cadence SUCCESS "$STATE"
n=$(grep -c 'scope=run' .loop/fake-review-prompts || true)
check "exactly the 2nd interim review ran at run scope" holistic-cadence 1 "$n"
if grep -q 'widened to the whole run' "$WORK/last-run.out"; then ok "widening announced"; else bad "widening note missing" holistic-cadence; fi

section "holistic size trigger: a big iteration diff widens the review immediately"
make_fixture holistic-size
printf 'HOLISTIC_EVERY_N=0\nHOLISTIC_TRIGGER_LINES=1\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "CONTINUE_FIX,READY_NOW"
check "exit code 0" holistic-size 0 "$RC"
n=$(grep -c 'scope=run' .loop/fake-review-prompts || true)
check "iteration-1 interim review widened by diff size" holistic-size 1 "$n"

section "holistic off (both knobs 0): reviews stay iteration-scoped"
make_fixture holistic-off
printf 'HOLISTIC_EVERY_N=0\nHOLISTIC_TRIGGER_LINES=0\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "CONTINUE_FIX,BAD_FIX,READY_NOW"
n=$(grep -c 'scope=run' .loop/fake-review-prompts || true)
check "no review widened" holistic-off 0 "$n"

