#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "contract generation INT/TERM: model child killed with the parent (exit 130)"
make_fixture contract-int nocontract
rm -f .loop/fake-models .loop/fake-contract-completed
RC=0
LOOP_FAKE_SLEEP=3 LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh start "fix value.txt so the check passes" </dev/null >"$WORK/contract-int.out" 2>&1 &
SPID=$!
n=0   # the fake writes .loop/fake-models BEFORE its sleep -> "model child live" marker
while [ "$n" -lt $((100 * POLL_SCALE)) ]; do
  [ -f .loop/fake-models ] && break
  sleep 0.1; n=$((n + 1))
done
kill -TERM "$SPID" 2>/dev/null || true
wait "$SPID" || RC=$?
check "start exits 130 on TERM" contract-int 130 "$RC"
sleep 4   # longer than the fake's remaining sleep: an ORPHANED child would finish by now
if [ ! -f .loop/fake-contract-completed ]; then
  ok "model child was killed with the parent (no orphan completed the contract)"
else
  bad "orphaned contract child completed after TERM" contract-int
fi
# ...and the human must not be left staring at a killed session with NO output at
# all: on_contract_int used to kill and exit 130 silently, so there was no way to
# tell whether a contract had been written or what to type next.
if grep -q 'interrupted while defining the loop' "$WORK/contract-int.out"; then
  ok "contract interrupt says what it was doing"
else
  bad "contract interrupt printed nothing about its state" contract-int
fi
if grep -q 'no contract was written' "$WORK/contract-int.out" \
   && grep -q '→ next:' "$WORK/contract-int.out" && grep -q './loop.sh start' "$WORK/contract-int.out"; then
  ok "contract interrupt reports nothing was written and names the next command"
else
  bad "contract interrupt missing the 'nothing written' status / '→ next:' recovery" contract-int
fi

section "run interrupt: the WHOLE agent subtree is reaped (no orphaned grandchild)"
# The agent (claude) spawns its own subprocesses (MCP servers, tool children,
# sub-agents). A single-pid kill of the agent leaves those orphaned; the harness
# launches each agent as its own process-group leader and group-kills the subtree
# on interrupt. LOOP_FAKE_GRANDCHILD makes the fake spawn a detached grandchild
# that writes a marker after 3s — its ABSENCE proves the subtree was reaped.
# Needs perl (the pgroup mechanism); without it the harness degrades to a
# single-pid kill BY DESIGN, so the grandchild would orphan — skip rather than
# assert a guarantee the platform cannot provide.
if command -v perl >/dev/null 2>&1; then
  make_fixture run-orphan
  rm -f .loop/fake-grandchild-alive
  RC=0
  LOOP_FAKE_GRANDCHILD=3 LOOP_FAKE_SLEEP=6 LOOP_CLAUDE_CMD="$FAKE" \
    LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
    ./loop.sh run </dev/null >"$WORK/run-orphan.out" 2>&1 &
  SPID=$!
  n=0   # the fake spawns the grandchild BEFORE writing .loop/fake-models -> once
  while [ "$n" -lt $((100 * POLL_SCALE)) ]; do          # that marker exists, the grandchild is live
    [ -f .loop/fake-models ] && break
    sleep 0.1; n=$((n + 1))
  done
  sleep 0.3   # let the agent call settle into its sleep (provably in flight)
  kill -TERM "$SPID" 2>/dev/null || true
  wait "$SPID" || RC=$?
  check "run interrupt exits 130" run-orphan 130 "$RC"
  if grep -q '"state": "RUN_INTERRUPTED"' .loop/journal.jsonl; then ok "interrupt journaled as RUN_INTERRUPTED"; else bad "RUN_INTERRUPTED missing from journal" run-orphan; fi
  sleep 4   # longer than the grandchild's 3s life: an orphan would have written by now
  if [ ! -f .loop/fake-grandchild-alive ]; then
    ok "agent subtree group-killed — no orphaned grandchild survived the interrupt"
  else
    bad "orphaned grandchild survived the interrupt (subtree not group-killed)" run-orphan
  fi
else
  ok "SKIP subtree-reap test (perl unavailable — pgroup kill degrades to single-pid by design)"
fi

