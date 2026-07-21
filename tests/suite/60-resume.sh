#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- resume (durable checkpoint: continue a crashed/failed run) ----------

section "resume: explicit ./loop.sh resume continues a BLOCKED run to SUCCESS"
make_fixture resume-blocked
run_loop "DECLARE_BLOCKED,READY_NOW"
check "first run BLOCKED (exit 4)" resume-blocked 4 "$RC"
check "state BLOCKED" resume-blocked BLOCKED "$STATE"
if [ -f .loop/run-checkpoint ]; then ok "checkpoint kept after BLOCKED"; else bad "checkpoint missing after BLOCKED" resume-blocked; fi
check "checkpoint records iteration 1" resume-blocked 1 "$(ckpt_field ITERATION)"
echo 'sentinel-baseline-kept' >> .loop/baseline-verify.log
starts_before=$(run_starts)
c1=$(cat .loop/cost-total)                          # cost accumulated up to the BLOCKED stop
resume_run "DECLARE_BLOCKED,READY_NOW" resume       # fake-i persisted -> next action is READY_NOW
check "resume exit 0" resume-blocked 0 "$RC"
check "resume reaches SUCCESS" resume-blocked SUCCESS "$STATE"
check "value fixed after resume" resume-blocked fixed "$(cat value.txt)"
if grep -q '"state": "RUN_RESUME"' .loop/journal.jsonl; then ok "RUN_RESUME journaled"; else bad "RUN_RESUME missing" resume-blocked; fi
# the RUN_RESUME record's running total must equal the pre-crash cost — proving
# TOTAL_COST was restored (not reset to 0) so a cumulative MAX_COST_USD still holds
rt=$(grep '"state": "RUN_RESUME"' .loop/journal.jsonl | tail -1 | sed -E 's/.*"total_usd": ([0-9.]+).*/\1/')
if awk -v a="$c1" -v b="$rt" 'BEGIN{exit !(a > 0 && a == b)}'; then ok "resume restored the accumulated cost (\$$rt)"; else bad "cost not restored on resume (had $c1, resumed at $rt)" resume-blocked; fi
check "no second RUN_START (same run continued)" resume-blocked "$starts_before" "$(run_starts)"
if grep -q 'sentinel-baseline-kept' .loop/baseline-verify.log 2>/dev/null && grep -q '^\[FAIL\] ./check.sh' .loop/baseline-verify.log 2>/dev/null; then ok "baseline log survives resume (baseline never re-run mid-run)"; else bad "baseline log clobbered on resume" resume-blocked; fi
if [ ! -f .loop/run-checkpoint ]; then ok "checkpoint removed on SUCCESS"; else bad "checkpoint left after SUCCESS" resume-blocked; fi

section "resume: Codex cost-warning bookkeeping preserves the restored Claude total"
make_fixture codex-resume-cost
printf 'AGENT_REVIEW="codex"\nMODEL_REVIEW="gpt-5.5-review"\n' >> loop.models.sh
run_loop "DECLARE_BLOCKED,READY_NOW"
check "first run BLOCKED" codex-resume-cost 4 "$RC"
c1=$(cat .loop/cost-total)
resume_run "DECLARE_BLOCKED,READY_NOW" resume
check "resume exits 0" codex-resume-cost 0 "$RC"
warn_total=$(grep '"state": "CODEX_COST_UNTRACKED"' .loop/journal.jsonl | tail -1 \
  | sed -E 's/.*"total_usd": ([0-9.]+).*/\1/')
check "one cost warning per process" codex-resume-cost 2 "$(grep -c '"state": "CODEX_COST_UNTRACKED"' .loop/journal.jsonl || true)"
if awk -v before="$c1" -v warned="$warn_total" 'BEGIN{exit !(before > 0 && before == warned)}'; then
  ok "resume warning retained the restored cumulative total (\$$warn_total)"
else
  bad "Codex warning rewound total_usd on resume (had $c1, warning wrote $warn_total)" codex-resume-cost
fi

section "resume: bare ./loop.sh run auto-resumes an interrupted run at iteration N (not 1)"
make_fixture resume-interrupt
run_loop "CONTINUE_FIX,DECLARE_BLOCKED,READY_NOW"   # iter1 CONTINUE, iter2 BLOCKED
check "stopped at iteration 2 (exit 4)" resume-interrupt 4 "$RC"
check "checkpoint records iteration 2" resume-interrupt 2 "$(ckpt_field ITERATION)"
echo INTERRUPTED > .loop/state                      # simulate a crash/interrupt
resume_run "CONTINUE_FIX,DECLARE_BLOCKED,READY_NOW" run
check "bare run auto-resumed exit 0" resume-interrupt 0 "$RC"
check "bare run auto-resumed to SUCCESS" resume-interrupt SUCCESS "$STATE"
if grep -q "resuming at iteration 2" .loop/journal.jsonl; then ok "resumed at iteration 2 (not restarted at 1)"; else bad "did not resume at iteration 2" resume-interrupt; fi

section "resume: run --fresh forces a clean restart, ignoring the checkpoint"
make_fixture resume-fresh
run_loop "DECLARE_BLOCKED,READY_NOW"
check "first run BLOCKED" resume-fresh BLOCKED "$STATE"
starts_before=$(run_starts)
rm -f .loop/fake-i                                  # let --fresh replay the scenario from the top
resume_run "READY_NOW" run --fresh
check "--fresh reaches SUCCESS" resume-fresh SUCCESS "$STATE"
check "--fresh emits a NEW RUN_START (restart)" resume-fresh "$((starts_before + 1))" "$(run_starts)"
if ! grep -q '"state": "RUN_RESUME"' .loop/journal.jsonl; then ok "--fresh did not resume"; else bad "--fresh unexpectedly resumed" resume-fresh; fi

section "resume: streak counters survive a resume (not wiped)"
make_fixture resume-counters
run_loop "DECLARE_BLOCKED"
check "run BLOCKED" resume-counters BLOCKED "$STATE"
echo 1 > .loop/stagnation-count                     # a stagnation streak in progress (1 of STAGNATION_N=2)
echo INTERRUPTED > .loop/state
resume_run "NO_DIFF" run
# one more NO_DIFF: preserved counter 1 -> 2 = STAGNATION_N -> STALLED. A wipe would
# reset to 0 -> one NO_DIFF only reaches 1 -> CONTINUE, never STALLED this fast.
check "resume STALLED after ONE NO_DIFF (counter preserved)" resume-counters STALLED "$STATE"

section "resume: explicit STALLED resume gets a fresh stagnation window + --note guidance"
make_fixture resume-stalled
run_loop "NO_DIFF,NO_DIFF"                          # stagnation x2 -> STALLED at iteration 2
check "run STALLED" resume-stalled STALLED "$STATE"
# fake-i is at 2: on resume, iteration 2 replays index 2 (NO_DIFF). A preserved
# stagnation counter (2) would instantly re-STALL on that one diff-less
# iteration; the reset window lets the run recover and finish.
resume_run "NO_DIFF,NO_DIFF,NO_DIFF,CONTINUE_FIX,READY_NOW" resume --note "try approach X"
check "resume exit 0" resume-stalled 0 "$RC"
check "resume recovered to SUCCESS (fresh window)" resume-stalled SUCCESS "$STATE"
if grep '"state": "RUN_NUDGE"' .loop/journal.jsonl | grep -q 'try approach X'; then ok "--note journaled as RUN_NUDGE"; else bad "RUN_NUDGE missing" resume-stalled; fi
if grep -q 'try approach X' .loop/supervisor-guidance.md 2>/dev/null; then ok "--note delivered via supervisor-guidance.md"; else bad "guidance file missing the note" resume-stalled; fi
if grep '"state": "RUN_RESUME"' .loop/journal.jsonl | tail -1 | grep -q 'previous state: STALLED; stop-heuristic windows reset'; then ok "RUN_RESUME names prev state + reset"; else bad "RUN_RESUME reason wrong: $(grep RUN_RESUME .loop/journal.jsonl | tail -1)" resume-stalled; fi

section "resume: explicit BLOCKED resume clears the repeat-fail fingerprint window"
make_fixture resume-fingerprint
run_loop "BAD_FIX,BAD_FIX,BAD_FIX"                  # identical verify failure x3 -> BLOCKED
check "run BLOCKED on repeat-fail" resume-fingerprint BLOCKED "$STATE"
# fake-i is at 3: the resume replays iteration 3 with index 3 (BAD_FIX again -> one
# identical failure), then fixes. Preserved fingerprints would re-BLOCK instantly
# on that first identical failure; the reset window lets the fix land.
resume_run "BAD_FIX,BAD_FIX,BAD_FIX,BAD_FIX,READY_NOW" resume
check "resume exit 0 (fingerprint window reset)" resume-fingerprint 0 "$RC"
check "resume recovered to SUCCESS" resume-fingerprint SUCCESS "$STATE"

section "resume: refuses beside a LIVE run (no false RUN_ABEND)"
make_fixture resume-live
run_loop "DECLARE_BLOCKED,READY_NOW"
check "run BLOCKED" resume-live BLOCKED "$STATE"
echo RUNNING > .loop/state                          # a live loop would look like this...
echo $$ > .loop/run.pid                             # ...with a live pid (this test shell)
: > .loop/run.heartbeat                             # ...and a fresh heartbeat
resume_run "READY_NOW" run
check "second run refused (exit 2)" resume-live 2 "$RC"
if ! grep -q '"state": "RUN_ABEND"' .loop/journal.jsonl; then ok "no false RUN_ABEND beside a live run"; else bad "false RUN_ABEND journaled" resume-live; fi
rm -f .loop/run.pid .loop/run.heartbeat
echo BLOCKED > .loop/state                          # restore a sane terminal state for the fixture

section "resume: a silent death (state RUNNING, no trap ran) journals RUN_ABEND"
make_fixture resume-abend
run_loop "DECLARE_BLOCKED,READY_NOW"
check "run BLOCKED" resume-abend BLOCKED "$STATE"
echo RUNNING > .loop/state                          # simulate SIGKILL/crash: not even the trap ran
resume_run "DECLARE_BLOCKED,READY_NOW" run
check "resume exit 0" resume-abend 0 "$RC"
if grep -q '"state": "RUN_ABEND"' .loop/journal.jsonl; then ok "silent death visible as RUN_ABEND at the next resume"; else bad "RUN_ABEND missing" resume-abend; fi
if grep '"state": "RUN_RESUME"' .loop/journal.jsonl | grep -q 'previous state: RUNNING'; then ok "RUN_RESUME names the previous state"; else bad "previous state missing in RUN_RESUME" resume-abend; fi

section "resume: run --fresh WIPES streak counters (recounts from zero)"
make_fixture resume-counters-fresh
run_loop "DECLARE_BLOCKED"
echo 1 > .loop/stagnation-count
rm -f .loop/fake-i
resume_run "NO_DIFF" run --fresh
# --fresh wiped stagnation-count -> iteration 1 NO_DIFF reaches only 1 -> CONTINUE
# (it stalls only at iteration 2), proving the seeded counter was discarded.
if grep -q '"iteration": "1", "state": "CONTINUE"' .loop/journal.jsonl; then ok "--fresh recounted (iter 1 CONTINUE, not STALLED)"; else bad "--fresh did not wipe the counter" resume-counters-fresh; fi

section "resume: recovers uncommitted work from the interrupted iteration"
make_fixture resume-recover
run_loop "DECLARE_BLOCKED,READY_NOW"                 # BLOCKED at iter1; tree left clean, checkpoint kept
check "run BLOCKED" resume-recover BLOCKED "$STATE"
echo "half-done" > partial-work.txt                  # uncommitted work the killed iteration left behind
echo INTERRUPTED > .loop/state
resume_run "DECLARE_BLOCKED,READY_NOW" run           # auto-resume: commit the recovered work, then continue
check "resume reached SUCCESS" resume-recover SUCCESS "$STATE"
# NOTE: use `grep -c` (reads all input), not `git log | grep -q` — under `set -o
# pipefail`, grep -q exits early on a match, git log then gets SIGPIPE (141), and
# pipefail propagates that to the `if`, spuriously failing even on a real match.
if [ "$(git log --format=%s | grep -c 'recovered uncommitted work on resume')" -ge 1 ]; then ok "uncommitted work committed on resume"; else bad "no recovery commit" resume-recover; fi
if git ls-files --error-unmatch partial-work.txt >/dev/null 2>&1; then ok "recovered file is tracked (reviewer can see it)"; else bad "recovered file not committed" resume-recover; fi

section "resume: falls back to HEAD when the recorded review base is not an ancestor"
make_fixture resume-base
run_loop "DECLARE_BLOCKED,READY_NOW"
check "run BLOCKED" resume-base BLOCKED "$STATE"
# corrupt the recorded base to a non-existent sha (contract/harness hashes untouched)
{ grep -v '^RUN_START_REF=' .loop/run-checkpoint; echo "RUN_START_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; } > .loop/run-checkpoint.t \
  && mv .loop/run-checkpoint.t .loop/run-checkpoint
echo INTERRUPTED > .loop/state
resume_run "DECLARE_BLOCKED,READY_NOW" run
check "resume still reaches SUCCESS with a bad base" resume-base SUCCESS "$STATE"
if grep -q "not an ancestor of HEAD" "$WORK/resume-last.out"; then ok "fell back to HEAD as the review base"; else bad "no ancestor-fallback note" resume-base; fi

section "resume: refuses when the contract changed since the checkpoint"
make_fixture resume-contract
run_loop "DECLARE_BLOCKED,READY_NOW"
check "run BLOCKED" resume-contract BLOCKED "$STATE"
printf '\n### REQ-002\nan added requirement\n' >> .loop/docs/product-contract.md
./loop.sh approve >/dev/null                         # new approved hash != checkpoint hash
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh resume >"$WORK/resume-contract.out" 2>&1 </dev/null || RC=$?
check "explicit resume refused (exit 2)" resume-contract 2 "$RC"
if grep -q "contract changed" "$WORK/resume-contract.out"; then ok "refusal explains the contract changed"; else bad "no contract-changed message" resume-contract; fi
starts_before=$(run_starts)
resume_run "READY_NOW" run                            # bare run must go FRESH after a contract change
if [ "$(run_starts)" -gt "$starts_before" ]; then ok "bare run went fresh after contract change"; else bad "bare run did not restart fresh" resume-contract; fi

section "resume: escalations are never auto-resumed (stay on approve && run)"
make_fixture resume-escalation
run_loop "DECLARE_SPEC"
check "run escalated (exit 3)" resume-escalation 3 "$RC"
check "state NEEDS_SPEC_DECISION" resume-escalation NEEDS_SPEC_DECISION "$STATE"
if [ -f .loop/run-checkpoint ]; then ok "checkpoint kept after escalation"; else bad "checkpoint missing after escalation" resume-escalation; fi
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh resume >"$WORK/resume-escalation.out" 2>&1 </dev/null || RC=$?
check "explicit resume refused (exit 2)" resume-escalation 2 "$RC"
if grep -q "human decision" "$WORK/resume-escalation.out"; then ok "refusal points at the human-decision path"; else bad "no human-decision message" resume-escalation; fi
starts_before=$(run_starts)
resume_run "READY_NOW" run                            # bare run must NOT auto-resume an escalation
if [ "$(run_starts)" -gt "$starts_before" ]; then ok "bare run went fresh (escalation not auto-resumed)"; else bad "bare run auto-resumed an escalation" resume-escalation; fi

section "resume: BUDGET_EXCEEDED continues after raising MAX_ITERATIONS + re-approving"
make_fixture resume-budget
# tighten to a 1-iteration budget so a single non-ready iteration exhausts it
awk '{ if ($0 ~ /^MAX_ITERATIONS=/) print "MAX_ITERATIONS=1"; else print }' loop.config.sh > loop.config.sh.t && mv loop.config.sh.t loop.config.sh
./loop.sh approve >/dev/null
run_loop "CONTINUE_FIX"
check "run hit the iteration cap (exit 5)" resume-budget 5 "$RC"
check "state BUDGET_EXCEEDED" resume-budget BUDGET_EXCEEDED "$STATE"
check "checkpoint points past the cap (iteration 2)" resume-budget 2 "$(ckpt_field ITERATION)"
# resuming WITHOUT raising the cap would just re-exceed -> refuse with guidance
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh resume >"$WORK/resume-budget0.out" 2>&1 </dev/null || RC=$?
check "resume without raising the cap refuses (exit 2)" resume-budget 2 "$RC"
if grep -q "budget exhausted" "$WORK/resume-budget0.out"; then ok "refusal explains the exhausted budget"; else bad "no exhausted-budget message" resume-budget; fi
# raise the cap + re-approve (a budget-only change) -> resume continues the SAME run
awk '{ if ($0 ~ /^MAX_ITERATIONS=/) print "MAX_ITERATIONS=3"; else print }' loop.config.sh > loop.config.sh.t && mv loop.config.sh.t loop.config.sh
./loop.sh approve >/dev/null
starts_before=$(run_starts)
resume_run "CONTINUE_FIX,READY_NOW" resume
check "resume under the raised cap reaches SUCCESS" resume-budget SUCCESS "$STATE"
if grep -q '"state": "RUN_RESUME"' .loop/journal.jsonl; then ok "budget-raise resume continued via RUN_RESUME"; else bad "budget-raise did not resume" resume-budget; fi
check "no new RUN_START (same run continued under the bigger cap)" resume-budget "$starts_before" "$(run_starts)"

section "resume: MAX_RESUMES backstop stops an endless crash-loop"
make_fixture resume-backstop
run_loop "DECLARE_BLOCKED"
{ grep -v '^RESUME_COUNT=' .loop/run-checkpoint; echo "RESUME_COUNT=10"; } > .loop/run-checkpoint.t \
  && mv .loop/run-checkpoint.t .loop/run-checkpoint      # push the resume count to the cap
echo INTERRUPTED > .loop/state
resume_run "READY_NOW" run
check "backstop -> BLOCKED (exit 4)" resume-backstop 4 "$RC"
check "backstop state BLOCKED" resume-backstop BLOCKED "$STATE"
if grep -q "resumed" "$WORK/resume-last.out"; then ok "backstop message explains repeated resumes"; else bad "no backstop message" resume-backstop; fi

section "resume: explicit BLOCKED resume clears the agent-failure streak"
make_fixture resume-agentfail
run_loop "CRASH,CRASH"                              # two agent failures in a row -> BLOCKED
check "run BLOCKED on agent failures (exit 4)" resume-agentfail 4 "$RC"
check "state BLOCKED" resume-agentfail BLOCKED "$STATE"
check "checkpoint carries the failure streak" resume-agentfail 1 "$(ckpt_field AGENT_FAILURES)"
# fake-i is at 2: the resume replays iteration 2 with index 2 (CRASH again -> ONE
# new failure), then fixes. A preserved streak (1) would hit 2 on that single
# failure and re-BLOCK instantly; the reset grants the fresh 2-failure window.
resume_run "CRASH,CRASH,CRASH,READY_NOW" resume
check "resume exit 0 (agent-failure window reset)" resume-agentfail 0 "$RC"
check "resume recovered to SUCCESS" resume-agentfail SUCCESS "$STATE"

section "resume: completing an iteration persists the cleared crash-loop counter"
make_fixture resume-persist
run_loop "DECLARE_BLOCKED"
check "run BLOCKED" resume-persist BLOCKED "$STATE"
# push the resume count near the cap; the resume below increments it to 9 (< 10)
{ grep -v '^RESUME_COUNT=' .loop/run-checkpoint; echo "RESUME_COUNT=8"; } > .loop/run-checkpoint.t \
  && mv .loop/run-checkpoint.t .loop/run-checkpoint
echo INTERRUPTED > .loop/state
# tighten the cost cap so the run stops right AFTER the resumed iteration is
# evaluated (0.01 already spent + implement/review/stop-eval = 0.04 >= 0.03) —
# i.e. INSIDE the window between the progress reset and the next iteration's
# start checkpoint. Budget-only config change: the sans-budget tolerance resumes.
awk '{ if ($0 ~ /^MAX_COST_USD=/) print "MAX_COST_USD=0.03"; else print }' loop.config.sh > loop.config.sh.t && mv loop.config.sh.t loop.config.sh
./loop.sh approve >/dev/null
resume_run "CONTINUE_FIX" run
check "resumed run stopped on the cost cap (exit 5)" resume-persist 5 "$RC"
check "state BUDGET_EXCEEDED" resume-persist BUDGET_EXCEEDED "$STATE"
if grep '"state": "RUN_RESUME"' .loop/journal.jsonl | grep -q 'resume #9'; then ok "resumed as resume #9 under the cost-cap-only re-approval"; else bad "resume #9 missing: $(grep RUN_RESUME .loop/journal.jsonl | tail -1)" resume-persist; fi
# the completed iteration must have persisted the cleared counter to DISK: an
# in-memory-only reset would still read 9 here, and a healthy run's benign
# interrupts during review/stop-eval would falsely accumulate to MAX_RESUMES.
check "RESUME_COUNT persisted as 0 after the completed iteration" resume-persist 0 "$(ckpt_field RESUME_COUNT)"

section "resume: MAX_RESUMES boundary — count 9 fires the backstop exactly at 10"
# (the =8 -> runs-one-more side is proven by resume-persist above: its resume #9
#  executed a full iteration). Pins the >= comparison and the increment order: a
#  drift to > would allow an 11th resume; incrementing after the check would block at 9.
make_fixture resume-boundary
run_loop "DECLARE_BLOCKED"
{ grep -v '^RESUME_COUNT=' .loop/run-checkpoint; echo "RESUME_COUNT=9"; } > .loop/run-checkpoint.t \
  && mv .loop/run-checkpoint.t .loop/run-checkpoint
echo INTERRUPTED > .loop/state
resume_run "READY_NOW" run
check "10th resume fires the backstop (exit 4)" resume-boundary 4 "$RC"
check "backstop state BLOCKED" resume-boundary BLOCKED "$STATE"
if grep -q 'resumed 10 times' "$WORK/resume-last.out"; then ok "backstop names the exact resume count"; else bad "no resume-count message: $(tail -5 "$WORK/resume-last.out")" resume-boundary; fi

section "NEEDS_DECOMPOSITION stop advises a fresh re-plan (never 'counters preserved')"
# NEEDS_DECOMPOSITION is not decision-rebound (cmd_approve deliberately omits it):
# the re-run re-plans from fresh, so the guidance must not promise preserved
# counters — the other three decision states rebind and keep the old wording.
make_fixture decomp-msg
run_loop "DECLARE_DECOMP"
check "run stopped for decomposition (exit 3)" decomp-msg 3 "$RC"
check "state NEEDS_DECOMPOSITION" decomp-msg NEEDS_DECOMPOSITION "$STATE"
if grep -q 'counters and cost are preserved' "$WORK/last-run.out"; then bad "NEEDS_DECOMPOSITION promises preserved counters" decomp-msg; else ok "no preserved-counters promise"; fi
if grep -q 're-plans' "$WORK/last-run.out"; then ok "advice names the fresh re-plan"; else bad "no re-plan advice: $(grep -A2 'Next:' "$WORK/last-run.out" | head -5)" decomp-msg; fi

section "resume: --prefer-resume continues if a checkpoint exists, else fresh (fleet relaunch mode)"
# This is exactly how the fleet dispatcher (loop.sh fleet) relaunches every task
# loop, so it stands in for the
# fleet counter-preserving resume (the live fleet crash/TERM tests above now relaunch
# through this same --prefer-resume path).
make_fixture resume-prefer
resume_run "DECLARE_BLOCKED,READY_NOW" run --prefer-resume     # no checkpoint yet -> fresh
check "prefer-resume with no checkpoint -> fresh, BLOCKED at iter1" resume-prefer BLOCKED "$STATE"
if grep -q '"state": "RUN_START"' .loop/journal.jsonl && ! grep -q '"state": "RUN_RESUME"' .loop/journal.jsonl; then
  ok "first --prefer-resume launch was fresh"; else bad "first --prefer-resume launch not fresh" resume-prefer; fi
resume_run "DECLARE_BLOCKED,READY_NOW" run --prefer-resume     # checkpoint exists -> resume BLOCKED
check "prefer-resume with a BLOCKED checkpoint -> resumes to SUCCESS" resume-prefer SUCCESS "$STATE"
if grep -q '"state": "RUN_RESUME"' .loop/journal.jsonl; then ok "prefer-resume continued via RUN_RESUME (counters preserved)"; else bad "prefer-resume did not resume a BLOCKED run" resume-prefer; fi

section "resume --auto without a task id is a usage error, not a run flag"
# E12c: `resume --auto` used to fall through to `run --require-resume --auto`
# and die with an unrelated "unknown option" — name the real fix instead
make_fixture resume-auto-usage
RC=0
out=$(./loop.sh resume --auto 2>&1) || RC=$?
check "exit code 2" resume-auto-usage 2 "$RC"
case "$out" in
  *"resume --auto needs a task id"*) ok "usage error names the missing task id" ;;
  *) bad "wrong usage error: $out" resume-auto-usage ;;
esac

