#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# Codex reports token usage, not USD. When PRICE_* rates are set in the
# (contract-hashed) loop.config.sh, the harness estimates each Codex call's USD
# from its tokens, folds it into the reported total AND the MAX_COST_USD cap,
# and labels every total that contains it as an estimate. These tests pin that
# whole path against the fake Codex stub (LOOP_FAKE_CODEX_TOKENS injects usage).

section "Codex USD is ESTIMATED from tokens x price, folded into the total, labeled 推定"
make_fixture codex-est
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
# prices live in loop.config.sh (a hard-cap input) -> editing them re-hashes the
# contract, so this run must be re-approved before it will start.
cat >> loop.config.sh <<'EOF'
PRICE_GPT_5_5_IN="1"
PRICE_GPT_5_5_CACHED="0.1"
PRICE_GPT_5_5_OUT="2"
EOF
./loop.sh approve >/dev/null
RC=0
# uncached input 1,000,000 @ $1 + output 500,000 @ $2 = $1.00 + $1.00 = $2.00
LOOP_FAKE_CODEX_TOKENS="1000000,0,500000" LOOP_CLAUDE_CMD="$FAKE" LOOP_CODEX_CMD="$FAKE_CODEX" \
  LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-est.out" 2>&1 </dev/null || RC=$?
check "exit 0 (success)" codex-est 0 "$RC"
# the estimated PORTION lives in cost-total-est; cost-total also holds the real
# Claude-side cost (gate review + evidence @ $0.01 each), so it is slightly higher.
if awk -v t="$(cat .loop/cost-total-est 2>/dev/null || echo 0)" 'BEGIN{exit !(t > 1.99 && t < 2.01)}'; then
  ok "token estimate (~\$2.00) tracked in cost-total-est"
else
  bad "cost-total-est is not the expected estimate: $(cat .loop/cost-total-est 2>/dev/null)" codex-est
fi
if awk -v t="$(cat .loop/cost-total 2>/dev/null || echo 0)" 'BEGIN{exit !(t > 2.00)}'; then
  ok "the estimate folded into the reported cost-total (Claude cost on top)"
else
  bad "cost-total did not absorb the estimate: $(cat .loop/cost-total 2>/dev/null)" codex-est
fi
if grep -q '"state": "CODEX_COST_ESTIMATED"' .loop/journal.jsonl; then
  ok "journal records CODEX_COST_ESTIMATED (audit trail)"
else
  bad "no CODEX_COST_ESTIMATED preflight row" codex-est
fi
if grep -q 'ESTIMATED from token usage' "$WORK/codex-est.out"; then
  ok "preflight discloses that Codex cost is estimated"
else
  bad "estimation disclosure note missing" codex-est
fi
if grep -qF '推定値を含む' "$WORK/codex-est.out"; then
  ok "the RESULT total carries the 推定 / estimate label"
else
  bad "final total is not labeled as containing an estimate" codex-est
fi
# capture first: `./loop.sh status` may exit non-zero, and pipefail would mask a
# real grep match if piped directly.
STATUS_OUT=$(./loop.sh status 2>/dev/null || true)
if printf '%s' "$STATUS_OUT" | grep -qF '推定値を含む'; then
  ok "status also labels the estimated total"
else
  bad "status total missing the estimate label: $(printf '%s' "$STATUS_OUT" | grep -i cost)" codex-est
fi

section "estimated Codex cost counts against the hard MAX_COST_USD cap"
make_fixture codex-cap
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
# $10/call estimate against the fixture's MAX_COST_USD=5: the next iteration's
# boundary check must trip BUDGET_EXCEEDED on the estimate alone.
cat >> loop.config.sh <<'EOF'
PRICE_GPT_5_5_IN="10"
PRICE_GPT_5_5_OUT="0"
EOF
./loop.sh approve >/dev/null
RC=0
LOOP_FAKE_CODEX_TOKENS="1000000,0,0" LOOP_CLAUDE_CMD="$FAKE" LOOP_CODEX_CMD="$FAKE_CODEX" \
  LOOP_FAKE_SCENARIO="EXPENSIVE" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-cap.out" 2>&1 </dev/null || RC=$?
check "exit code 5 (budget)" codex-cap 5 "$RC"
check "state BUDGET_EXCEEDED" codex-cap BUDGET_EXCEEDED "$(cat .loop/state 2>/dev/null || echo none)"
if grep -qF 'estimated Codex spend' "$WORK/codex-cap.out"; then
  ok "the cap message discloses that the spend is estimated"
else
  bad "BUDGET_EXCEEDED reason not labeled as an estimate" codex-cap
fi

section "no PRICE_* configured: Codex cost stays 0 (backward compatible) + untracked warning"
make_fixture codex-noprice
# only loop.models.sh changes (not hashed) -> no re-approval; no PRICE_* rows.
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_FAKE_CODEX_TOKENS="1000000,0,1000000" LOOP_CLAUDE_CMD="$FAKE" LOOP_CODEX_CMD="$FAKE_CODEX" \
  LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-noprice.out" 2>&1 </dev/null || RC=$?
check "exit 0" codex-noprice 0 "$RC"
# the estimate is 0 with no price row; cost-total still carries the real Claude
# cost, so assert on the estimate mirror specifically.
if awk -v t="$(cat .loop/cost-total-est 2>/dev/null || echo 0)" 'BEGIN{exit !(t < 0.0001)}'; then
  ok "no price row -> Codex estimate stays 0 (unchanged behavior)"
else
  bad "unexpected non-zero estimate without prices: $(cat .loop/cost-total-est 2>/dev/null)" codex-noprice
fi
if grep -q '"state": "CODEX_COST_UNTRACKED"' .loop/journal.jsonl; then
  ok "the untracked warning still fires when a cap is set but no prices exist"
else
  bad "CODEX_COST_UNTRACKED row missing" codex-noprice
fi
if grep -qF '推定値を含む' "$WORK/codex-noprice.out"; then
  bad "estimate label wrongly shown when estimation is off" codex-noprice
else
  ok "no estimate label when estimation is off"
fi
