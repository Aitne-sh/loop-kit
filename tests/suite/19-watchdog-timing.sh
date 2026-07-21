#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "watchdog kill is labeled in the failure diagnostics"
make_fixture wdiag
printf 'MAX_ITER_SECONDS=1\n' >> loop.config.sh
./loop.sh approve >/dev/null
echo 3 > .loop/fake-sleep
run_loop "READY_NOW"
rm -f .loop/fake-sleep
check "exit code 4 (both calls killed)" wdiag 4 "$RC"
if grep '"state": "AGENT_ERROR"' .loop/journal.jsonl | grep -q 'watchdog kill'; then ok "timeout distinguishable from a crash"; else bad "watchdog kill not labeled: $(grep AGENT_ERROR .loop/journal.jsonl | head -1)" wdiag; fi

section "success gate: reviewer outage retried with backoff (GATE_RETRY_N)"
make_fixture gateretry
printf 'REVIEW_MODE="candidate"\nGATE_RETRY_N=2\nGATE_RETRY_WAITS="0 0"\n' >> loop.config.sh
./loop.sh approve >/dev/null
RC=0
# run_review consumes 2 entries per ERROR round (internal retry-twice), so
# CRASH,CRASH = round 1 unavailable; the GATE_RETRY round then reads APPROVE
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_STOPEVAL=CONTINUE \
  LOOP_FAKE_REVIEW="CRASH,CRASH,APPROVE" \
  ./loop.sh run >"$WORK/gateretry.out" 2>&1 </dev/null || RC=$?
check "exit 0 (outage ridden out)" gateretry 0 "$RC"
check "state SUCCESS" gateretry SUCCESS "$(cat .loop/state)"
check "exactly one GATE_RETRY journaled" gateretry 1 "$(grep -c '"state": "GATE_RETRY"' .loop/journal.jsonl || true)"
if grep '"state": "REVIEW_APPROVE"' .loop/journal.jsonl | grep -q '\[gate\]'; then ok "gate verdict landed after the retry"; else bad "no gate APPROVE after retry" gateretry; fi

section "success gate: retries exhausted -> fail-closed BLOCKED unchanged"
make_fixture gateretry2
printf 'REVIEW_MODE="candidate"\nGATE_RETRY_N=1\nGATE_RETRY_WAITS="0"\n' >> loop.config.sh
./loop.sh approve >/dev/null
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_STOPEVAL=CONTINUE \
  LOOP_FAKE_REVIEW="CRASH" \
  ./loop.sh run >"$WORK/gateretry2.out" 2>&1 </dev/null || RC=$?
check "exit 4" gateretry2 4 "$RC"
check "state BLOCKED" gateretry2 BLOCKED "$(cat .loop/state)"
check "exactly one GATE_RETRY before blocking" gateretry2 1 "$(grep -c '"state": "GATE_RETRY"' .loop/journal.jsonl || true)"
if grep -q 'reviewer unavailable at success gate' "$WORK/gateretry2.out"; then ok "fail-closed message preserved"; else bad "BLOCKED message changed" gateretry2; fi

section "success gate: watchdog-killed reviewer is NOT retried (deterministic timeout)"
make_fixture gateretrywd
printf 'REVIEW_MODE="candidate"\nGATE_RETRY_N=2\nGATE_RETRY_WAITS="0 0"\nMAX_ITER_SECONDS=1\n' >> loop.config.sh
./loop.sh approve >/dev/null
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_STOPEVAL=CONTINUE \
  LOOP_FAKE_REVIEW="SLOW_CRASH" \
  ./loop.sh run >"$WORK/gateretrywd.out" 2>&1 </dev/null || RC=$?
check "exit 4 (timeout fails closed, no retry burn)" gateretrywd 4 "$RC"
check "state BLOCKED" gateretrywd BLOCKED "$(cat .loop/state)"
if ! grep -q '"state": "GATE_RETRY"' .loop/journal.jsonl; then ok "no doomed retries against a watchdog timeout"; else bad "retried a deterministic timeout" gateretrywd; fi
if grep '"state": "REVIEW_ERROR"' .loop/journal.jsonl | grep -q 'watchdog kill'; then ok "timeout named in REVIEW_ERROR"; else bad "timeout not named: $(grep REVIEW_ERROR .loop/journal.jsonl | tail -1)" gateretrywd; fi

section "per-role TIMEOUT_<ROLE> lifts the watchdog above MAX_ITER_SECONDS for that role only"
make_fixture pertimeout
# Global watchdog 1s, but IMPLEMENT gets 60s. fake-sleep=2 makes EVERY call take
# ~2s: the IMPLEMENT call (60s ceiling) survives and produces SUCCESS_CANDIDATE,
# while the gate reviewer (no override -> the 1s global) is still watchdog-killed.
# One fixture proves both halves: the override lifts IMPLEMENT, and it does NOT
# leak to REVIEW (per-role, not a global bump).
printf 'MAX_ITER_SECONDS=1\nTIMEOUT_IMPLEMENT=60\n' >> loop.config.sh
./loop.sh approve >/dev/null
echo 2 > .loop/fake-sleep
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  ./loop.sh run >"$WORK/pertimeout.out" 2>&1 </dev/null || RC=$?
rm -f .loop/fake-sleep
if grep -q '"state": "SUCCESS_CANDIDATE"' .loop/journal.jsonl; then ok "IMPLEMENT survived its ~2s call under TIMEOUT_IMPLEMENT=60 (not killed at the 1s global)"; else bad "IMPLEMENT killed despite TIMEOUT_IMPLEMENT=60: $(grep -m1 AGENT_ERROR .loop/journal.jsonl | head -c 160)" pertimeout; fi
if grep '"state": "REVIEW_ERROR"' .loop/journal.jsonl | grep -q 'watchdog kill'; then ok "REVIEW without an override still bound by the 1s global (override is per-role, not global)"; else bad "reviewer not killed at the global — TIMEOUT_IMPLEMENT leaked to all roles? $(grep -m1 REVIEW_ERROR .loop/journal.jsonl | head -c 160)" pertimeout; fi
if grep -q "exceeded 60s" "$WORK/pertimeout.out"; then bad "IMPLEMENT should never reach its 60s ceiling here" pertimeout; else ok "no spurious 60s IMPLEMENT timeout"; fi

section "success gate: GATE_RETRY_N unset -> immediate BLOCKED (byte-compatible)"
make_fixture gateretry0
printf 'REVIEW_MODE="candidate"\n' >> loop.config.sh
./loop.sh approve >/dev/null
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_STOPEVAL=CONTINUE \
  LOOP_FAKE_REVIEW="CRASH" \
  ./loop.sh run >"$WORK/gateretry0.out" 2>&1 </dev/null || RC=$?
check "exit 4 (no retry by default)" gateretry0 4 "$RC"
if ! grep -q '"state": "GATE_RETRY"' .loop/journal.jsonl; then ok "no GATE_RETRY without the knob"; else bad "unexpected GATE_RETRY" gateretry0; fi

