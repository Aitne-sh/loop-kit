#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "baseline verify snapshot: red at run start -> green at final (red-green proof)"
make_fixture baseverify
run_loop "READY_NOW"
check "exit 0" baseverify 0 "$RC"
if grep -q '^\[FAIL\] ./check.sh' .loop/baseline-verify.log 2>/dev/null; then ok "baseline log records the gate red before the fix"; else bad "baseline FAIL line missing ($(cat .loop/baseline-verify.log 2>/dev/null || echo 'file absent'))" baseverify; fi
if grep -q '^\[PASS\] ./check.sh' .loop/last-verify.log 2>/dev/null; then ok "final verify green — red->green flip visible across baseline/final logs"; else bad "final verify not green" baseverify; fi
if grep '"state": "BASELINE_VERIFY"' .loop/journal.jsonl | grep -q 'red=1 green=0'; then ok "BASELINE_VERIFY journaled with red/green counts"; else bad "BASELINE_VERIFY journal row missing or wrong" baseverify; fi

section "budget -> BUDGET_EXCEEDED (cap explicitly configured)"
make_fixture budget
run_loop "EXPENSIVE"
check "exit code 5" budget 5 "$RC"
check "state BUDGET_EXCEEDED" budget BUDGET_EXCEEDED "$STATE"
# BUDGET_EXCEEDED now uses the same boxed NEXT ACTION treatment as the other stops
if grep -q 'NEXT ACTION' "$WORK/last-run.out" && grep -q 'raise MAX_ITERATIONS' "$WORK/last-run.out" \
   && grep -q './loop.sh approve && ./loop.sh resume' "$WORK/last-run.out"; then
  ok "BUDGET_EXCEEDED shows the boxed NEXT ACTION with raise-and-resume guidance"
else
  bad "BUDGET_EXCEEDED missing the boxed NEXT ACTION" nextcmd
fi

section "no USD cap by default (subscription): expensive call does not stop the loop"
make_fixture nocap
# loop.config.sh is gitignored (a harness file); edit it in place — approve hashes the working tree
grep -v '^MAX_COST_USD=' loop.config.sh > loop.config.sh.tmp && mv loop.config.sh.tmp loop.config.sh
./loop.sh approve >/dev/null
run_loop "EXPENSIVE,READY_NOW"
check "exit code 0" nocap 0 "$RC"
check "state SUCCESS" nocap SUCCESS "$STATE"
tot=$(cat .loop/cost-total 2>/dev/null || echo 0)
if awk -v t="$tot" 'BEGIN{exit !(t >= 99)}'; then ok "cost still tracked (\$$tot)"; else bad "cost not tracked: $tot" nocap; fi

section "MAX_RUN_SECONDS: global wall-clock cap stops the run as BUDGET_EXCEEDED"
make_fixture wallcap
printf 'MAX_RUN_SECONDS=1\n' >> loop.config.sh
./loop.sh approve >/dev/null
RC=0
# LOOP_FAKE_SLEEP pads every agent call so iteration 1 alone crosses the 1s cap;
# the check fires before iteration 2 starts (checkpoint kept for a resume)
LOOP_FAKE_SLEEP=0.4 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="CONTINUE_FIX,READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/wallcap.out" 2>&1 </dev/null || RC=$?
check "exit code 5" wallcap 5 "$RC"
check "state BUDGET_EXCEEDED" wallcap BUDGET_EXCEEDED "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q 'MAX_RUN_SECONDS' "$WORK/wallcap.out"; then ok "stop reason names MAX_RUN_SECONDS"; else bad "no MAX_RUN_SECONDS in the reason" wallcap; fi
if [ -f .loop/run-checkpoint ]; then ok "checkpoint kept (a resume gets a fresh window)"; else bad "checkpoint missing after the cap" wallcap; fi

section "agent crash twice -> BLOCKED"
make_fixture crash
run_loop "CRASH,CRASH"
check "exit code 4" crash 4 "$RC"
check "state BLOCKED" crash BLOCKED "$STATE"
# the failure must be diagnosable from the journal (stderr excerpt) and the
# evidence must survive future runs (preserved sidecars, not just fixed-name logs)
if grep '"state": "AGENT_ERROR"' .loop/journal.jsonl | grep -q 'FATAL: fake agent crash'; then ok "journal carries the stderr excerpt"; else bad "AGENT_ERROR reason has no stderr detail: $(grep AGENT_ERROR .loop/journal.jsonl | head -1)" crash; fi
if ls .loop/logs/failed/*.err >/dev/null 2>&1; then ok "failed-call sidecars preserved (.loop/logs/failed/)"; else bad "no preserved failure evidence" crash; fi
if grep -q 'last error:' "$WORK/last-run.out"; then ok "BLOCKED message carries the diagnostics"; else bad "BLOCKED message undiagnosed" crash; fi

section "Codex CLI failure normalizes diagnostics and preserves raw JSONL"
make_fixture codex-fail
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_FAKE_CODEX=FAIL LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-fail.out" 2>&1 </dev/null || RC=$?
check "exit code 4" codex-fail 4 "$RC"
check "state BLOCKED" codex-fail BLOCKED "$(cat .loop/state 2>/dev/null || echo none)"
if grep '"state": "AGENT_ERROR"' .loop/journal.jsonl | grep -q 'fake codex failure' \
   && grep -q 'last error:.*fake codex failure' "$WORK/codex-fail.out"; then
  ok "Codex error event reached AGENT_FAIL_DIAG and the terminal stop"
else
  bad "Codex failure diagnostics missing: $(grep AGENT_ERROR .loop/journal.jsonl | head -1)" codex-fail
fi
if ls .loop/logs/failed/*.codex.jsonl >/dev/null 2>&1 \
   && grep -q '"is_error": true' .loop/logs/failed/*.json \
   && grep -q '"type":"turn.failed"' .loop/logs/failed/*.codex.jsonl; then
  ok "failed Codex envelope and raw event stream were preserved"
else
  bad "Codex failure sidecars missing or not normalized" codex-fail
fi

section "Codex turn.failed fails closed even with exit 0 and a non-empty message"
make_fixture codex-turnfail
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_FAKE_CODEX=TURNFAIL LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-turnfail.out" 2>&1 </dev/null || RC=$?
check "exit code 4" codex-turnfail 4 "$RC"
if grep '"state": "AGENT_ERROR"' .loop/journal.jsonl | grep -q 'exit=0 is_error=true' \
   && grep -q '"type":"turn.failed"' .loop/logs/failed/*.codex.jsonl \
   && grep -q '"is_error": true' .loop/logs/failed/*.json; then
  ok "turn.failed event alone marked the normalized envelope as an error"
else
  bad "turn.failed was not authoritative when exit/message looked successful" codex-turnfail
fi

section "Codex success JSONL without -o message fails closed (no stale reuse)"
make_fixture codex-nomsg
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_FAKE_CODEX=NOMSG LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-nomsg.out" 2>&1 </dev/null || RC=$?
check "exit code 4" codex-nomsg 4 "$RC"
check "state BLOCKED" codex-nomsg BLOCKED "$(cat .loop/state 2>/dev/null || echo none)"
if grep '"state": "AGENT_ERROR"' .loop/journal.jsonl | grep -q 'exit=0 is_error=true' \
   && grep -q '"is_error": true' .loop/logs/failed/*.json \
   && ls .loop/logs/failed/*.codex.jsonl >/dev/null 2>&1 \
   && [ -z "$(find .loop/logs/failed -name '*.msg' -type f -print -quit)" ]; then
  ok "missing last-message was normalized as an error without a stale .msg"
else
  bad "NOMSG did not fail closed with preserved JSONL" codex-nomsg
fi

section "nested \"type\":\"error\" item data stays diagnostic (top-level classification)"
make_fixture codex-nested-error
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_FAKE_CODEX=NESTED_ERROR LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-nested-error.out" 2>&1 </dev/null || RC=$?
check "exit 0 despite nested error/turn.failed strings in item payloads" codex-nested-error 0 "$RC"
if [ "$RC" = 0 ]; then
  tid=$(json_scalar .loop/docs/certification.json task_id)
  rid=$(json_scalar .loop/docs/certification.json run_id)
  nested_envelope=".loop/logs/$tid/$rid/iter-1.json"
  if grep -q '"is_error": false' "$nested_envelope" \
     && grep -q '"num_turns": 2' "$nested_envelope"; then
    ok "only top-level events counted: success envelope, both items as turns"
  else
    bad "nested item data leaked into classification: $(cat "$nested_envelope" 2>/dev/null)" codex-nested-error
  fi
else
  bad "nested-error fixture run failed; envelope left unchecked" codex-nested-error
fi

section "Codex failure diagnostics survive a multibyte locale (no tr crash)"
make_fixture codex-utf8-diag
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
utf8_locale=$(locale -a 2>/dev/null | grep -iEm1 '^(en_US\.utf-?8|C\.utf-?8)$' || true)
RC=0
LC_ALL="${utf8_locale:-C}" LOOP_FAKE_CODEX=TURNFAIL_UTF8 LOOP_CLAUDE_CMD="$FAKE" \
  LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-utf8-diag.out" 2>&1 </dev/null || RC=$?
check "exit code 4 (turn.failed stays authoritative)" codex-utf8-diag 4 "$RC"
if ! grep -q 'Illegal byte sequence' "$WORK/codex-utf8-diag.out"; then
  ok "no tr locale crash while truncating a multibyte failure preview"
else
  bad "diagnostic truncation still crashes on split UTF-8" codex-utf8-diag
fi
if grep '"state": "AGENT_ERROR"' .loop/journal.jsonl | grep -q 'cause: turn.failed event'; then
  ok "failure cause names the fatal event"
else
  bad "cause tag missing: $(grep AGENT_ERROR .loop/journal.jsonl | head -1)" codex-utf8-diag
fi

section "API-level failure (is_error JSON, exit 0): diagnosed + cost still tracked"
make_fixture errjson
run_loop "ERRJSON,ERRJSON"
check "exit code 4" errjson 4 "$RC"
check "state BLOCKED" errjson BLOCKED "$STATE"
if grep '"state": "AGENT_ERROR"' .loop/journal.jsonl | grep -q 'API error: rate limited'; then ok "journal carries the stdout-JSON error message"; else bad "AGENT_ERROR reason missing the API error: $(grep AGENT_ERROR .loop/journal.jsonl | head -1)" errjson; fi
tot=$(cat .loop/cost-total 2>/dev/null || echo 0)
if awk -v t="$tot" 'BEGIN{exit !(t >= 1)}'; then ok "failed-call cost accumulated (\$$tot)"; else bad "failure cost dropped: $tot" errjson; fi
if grep -l 'rate limited' .loop/logs/failed/*.json >/dev/null 2>&1; then ok "failure JSON preserved with the error text"; else bad "failure JSON not preserved" errjson; fi
# a rate/usage limit is transient: the stop must steer to wait-and-retry (api-stall
# box), NOT the sign-off/contract box a generic BLOCKED would show
if grep -qi 'rate / usage limit' "$WORK/last-run.out" && grep -qi 'Wait for the limit to reset' "$WORK/last-run.out"; then
  ok "rate-limit failure shows the wait-and-retry (api-stall) guidance"
else
  bad "api-stall guidance missing on a rate-limit failure" nextcmd
fi
if ! grep -q "mark the 'human' row" "$WORK/last-run.out"; then
  ok "rate-limit stop does not misuse the human-sign-off box"
else
  bad "rate-limit stop wrongly shows the sign-off box" nextcmd
fi
# and the recovery command must be `resume`, not a bare `run`: for a BLOCKED state
# decide_run_mode maps bare `run` to FRESH (re-decompose from iteration 1), the
# opposite of the box's "continue where it left off / counters intact" promise
if grep -q './loop.sh resume' "$WORK/last-run.out"; then
  ok "api-stall steers to ./loop.sh resume (counters/cost preserved)"
else
  bad "api-stall box must present ./loop.sh resume, not a bare ./loop.sh run" nextcmd
fi

section "error paths end with a canonical '→ next:' recovery line (die_next)"
make_fixture nonext nocontract
rm -f .loop/docs/product-contract.md   # nocontract keeps init's template; drop it to hit the gap site
RC=0
./loop.sh approve >"$WORK/nonext.out" 2>&1 </dev/null || RC=$?
check "approve with no contract exits 2" nonext 2 "$RC"
if grep -q '→ next:' "$WORK/nonext.out" && grep -q './loop.sh start' "$WORK/nonext.out"; then
  ok "die_next prints the '→ next:' recovery line with the command"
else
  bad "die_next recovery line missing on a gap error site" nextcmd
fi


section "watch: escalations stop; only a rate/usage limit is waited out"
# `watch` used to print "rc=4 — retrying in <interval>s" for EVERY non-zero exit.
# For a BLOCKED/STALLED/BUDGET_EXCEEDED run that retry is a bare `run`, which
# decide_run_mode maps to FRESH — so the message hid a full restart from
# iteration 1 that re-spends the whole budget, up to --max-runs times, on a run
# that already needs a human. README documents watch as "until success or
# escalation"; these pin that.
make_fixture watch-stop
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="DECLARE_BLOCKED" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh watch --max-runs 3 --interval 1 >"$WORK/watch-stop.out" 2>&1 </dev/null || RC=$?
check "watch stops on a BLOCKED escalation (exit 4)" watch-stop 4 "$RC"
n=$(grep -c '^loop: watch: run ' "$WORK/watch-stop.out" || true)
if [ "$n" = 1 ]; then ok "watch made exactly one attempt (no silent fresh restart)"; else bad "watch retried an escalation ($n attempts)" watchstop; fi
if grep -q 'needs a human' "$WORK/watch-stop.out" && grep -q 'restart from iteration 1' "$WORK/watch-stop.out"; then
  ok "watch names the state and why it is not retrying"
else
  bad "watch stop message missing the state / no-retry reason" watchstop
fi
if grep -q 'NEXT ACTION' "$WORK/watch-stop.out"; then ok "watch prints the run's NEXT ACTION box"; else bad "watch stop printed no NEXT ACTION box" watchstop; fi

# the ONE stop worth waiting out: a rate/usage limit. It must keep going AND
# continue with `resume`, so the checkpoint and counters survive the wait.
make_fixture watch-stall
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="ERRJSON,ERRJSON" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh watch --max-runs 2 --interval 1 >"$WORK/watch-stall.out" 2>&1 </dev/null || RC=$?
check "watch exhausts --max-runs on a rate limit (exit 5)" watch-stall 5 "$RC"
n=$(grep -c '^loop: watch: run ' "$WORK/watch-stall.out" || true)
if [ "$n" = 2 ]; then ok "watch waited out the rate limit and retried"; else bad "watch did not retry a rate-limit stall ($n attempts)" watchstall; fi
if grep -q 'rate/usage limit' "$WORK/watch-stall.out"; then ok "watch names the rate/usage limit as the reason it waits"; else bad "watch wait reason missing" watchstall; fi
if grep -q '^loop: watch: run 2/2 (resume)' "$WORK/watch-stall.out"; then
  ok "watch continues with resume (counters + cost preserved), not a fresh run"
else
  bad "watch retried with a fresh run instead of resume" watchstall
fi
if grep -q 'reached --max-runs' "$WORK/watch-stall.out" && grep -q 'last state:' "$WORK/watch-stall.out"; then
  ok "watch's max-runs exit names the last state instead of just 'max runs reached'"
else
  bad "watch max-runs message missing the state" watchstall
fi
