#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "static skill invariants: shared HTML-contract block byte-identical + badge rename"
# The loop-html-contract block is triplicated across the three authoring skills and
# MUST stay byte-identical (the skills say so in a comment). Enforce it here so an edit
# to one copy that forgets the others fails the suite instead of drifting silently.
h_contract=$(html_block_sha "$SK/loop-contract/SKILL.md")
h_evidence=$(html_block_sha "$SK/loop-evidence/SKILL.md")
h_iterate=$(html_block_sha "$SK/loop-iterate/SKILL.md")
if [ -n "$h_contract" ] && [ "$h_contract" = "$h_evidence" ] && [ "$h_contract" = "$h_iterate" ]; then
  ok "loop-html-contract block is byte-identical across the 3 authoring skills"
else
  bad "loop-html-contract block drifted (contract=$h_contract evidence=$h_evidence iterate=$h_iterate)" html-sync
fi
if grep -rq 'UI Direction' "$SK"; then
  bad "stale 'UI Direction' still present in skills (renamed to 'Direction')" html-sync
else
  ok "badge/skeleton renamed: no stale 'UI Direction' remains"
fi
if grep -qF '**Direction** (badge' "$SK/loop-contract/SKILL.md"; then
  ok "'Direction' badge present in the contract skill"
else
  bad "'Direction' badge missing from the contract skill" html-sync
fi

section "static: shipped kit defaults max reasoning effort"
# the kit template ships LOOP_EFFORT="xhigh" so a fresh `init` runs every in-loop
# call at max effort by default; guard it against a silent regression.
if grep -qE '^[[:space:]]*LOOP_EFFORT="xhigh"' "$ROOT/kit/loop.models.sh"; then
  ok "kit/loop.models.sh ships LOOP_EFFORT=\"xhigh\""
else
  bad "kit/loop.models.sh no longer defaults LOOP_EFFORT to xhigh" effort
fi
if grep -qE '^[[:space:]]*MODEL_REVIEW_INTERIM="sonnet"' "$ROOT/kit/loop.models.sh"; then
  ok "kit ships MODEL_REVIEW_INTERIM=\"sonnet\" (interim review tiering)"
else
  bad "kit no longer ships MODEL_REVIEW_INTERIM=sonnet" effort
fi
if grep -qE '^[[:space:]]*EFFORT_STOP_EVAL="low"' "$ROOT/kit/loop.models.sh" \
   && grep -qE '^[[:space:]]*EFFORT_EVIDENCE="medium"' "$ROOT/kit/loop.models.sh"; then
  ok "kit ships per-role effort defaults (stop-eval=low, evidence=medium)"
else
  bad "kit per-role effort defaults missing" effort
fi
if grep -qE '^[[:space:]]*TURNS_NUDGE_AT="70"' "$ROOT/kit/loop.models.sh"; then
  ok "kit ships TURNS_NUDGE_AT=\"70\" (runaway-context nudge, ~p90 of healthy iterations)"
else
  bad "kit TURNS_NUDGE_AT default missing/wrong" effort
fi

section "static: unknowns intake + assumption protocol invariants"
for t in unknowns assumptions requirements-ledger; do
  if [ -f "$ROOT/kit/loop-docs/$t.md" ] && grep -q '<!-- TEMPLATE -->' "$ROOT/kit/loop-docs/$t.md"; then
    ok "template kit/loop-docs/$t.md exists with TEMPLATE marker"
  else
    bad "template kit/loop-docs/$t.md missing or lacks TEMPLATE marker" unknowns-static
  fi
done
if grep -q 'unknowns.md' "$SK/loop-contract/SKILL.md" && grep -q 'AskUserQuestion' "$SK/loop-contract/SKILL.md"; then
  ok "contract skill carries the unknowns intake (unknowns.md + AskUserQuestion)"
else
  bad "contract skill lost the unknowns intake" unknowns-static
fi
if grep -q 'Human Approval Required If' "$SK/loop-iterate/SKILL.md"; then
  ok "iterate skill ties escalation to the Human Approval Required If bar"
else
  bad "iterate skill missing the Human Approval Required If escalation bar" unknowns-static
fi
if grep -q 'context-nudge.md' "$SK/loop-iterate/SKILL.md"; then
  ok "iterate skill documents the runaway-context nudge"
else
  bad "iterate skill missing context-nudge.md" unknowns-static
fi
if grep -q 'Key decisions' "$SK/loop-plan/SKILL.md"; then
  ok "plan skill carries the Key decisions recap"
else
  bad "plan skill missing the Key decisions recap" unknowns-static
fi
if grep -q 'acceptance-gate question' "$SK/loop-contract/SKILL.md" && grep -qF 'red→green' "$SK/loop-contract/SKILL.md"; then
  ok "contract skill carries the mandatory acceptance-gate question + red→green classification"
else
  bad "contract skill lost the acceptance-gate question / red→green classification" unknowns-static
fi
if grep -qF 'stays-green' "$SK/loop-contract-review/SKILL.md"; then
  ok "contract reviewer enforces the red→green/stays-green classification"
else
  bad "contract reviewer lost the red→green/stays-green classification check" unknowns-static
fi
if grep -qF 'baseline-verify.log' "$SK/loop-evidence/SKILL.md"; then
  ok "evidence skill reads the baseline verify snapshot"
else
  bad "evidence skill lost baseline-verify.log" unknowns-static
fi
if grep -qF 'red→green' "$ROOT/kit/loop-docs/product-contract.md"; then
  ok "contract template carries the red→green classification comment"
else
  bad "contract template lost the red→green classification comment" unknowns-static
fi
# Browser/visual verification posture: browser checks are PROPOSED at
# definition time (the defining agent's environment is not the executing
# agent's — no intake feasibility proof for agent-browser-channel rows) and
# enforced at runtime by an immediate stop-and-ask when the capability is
# missing. The term "agent browser channel" anchors the posture in all four
# skills.
if grep -q 'agent browser channel' "$SK/loop-contract/SKILL.md" \
   && grep -q 'stops at the first attempt' "$SK/loop-contract/SKILL.md"; then
  ok "contract skill proposes agent-browser-channel checks with the runtime-stop caveat"
else
  bad "contract skill lost the agent-browser-channel proposal posture" browser-posture
fi
if grep -q 'agent browser channel' "$SK/loop-contract-review/SKILL.md"; then
  ok "contract reviewer accepts unproven agent-browser-channel bindings (recorded, not silent)"
else
  bad "contract reviewer lost the agent-browser-channel rule" browser-posture
fi
if grep -q 'agent browser channel' "$SK/loop-iterate/SKILL.md"; then
  ok "iterate skill stops immediately on a missing agent-browser capability"
else
  bad "iterate skill lost the agent-browser-channel stop rule" browser-posture
fi
if grep -q 'agent browser channel' "$SK/loop-plan/SKILL.md"; then
  ok "plan skill schedules unproven browser observations early"
else
  bad "plan skill lost the agent-browser-channel scheduling rule" browser-posture
fi

section "static: E-series skill/engine contract invariants"
# E2b: the gate reviewer must know sanctioned manual side-work when the prompt
# carries a manual-tasks manifest (fleet gate mode)
if grep -q 'manual-tasks' "$SK/loop-review/SKILL.md"; then
  ok "loop-review documents the manual-tasks manifest (sanctioned side-work)"
else
  bad "loop-review lost the manual-tasks manifest section" e-static
fi
# E9: Quality-baseline enforcement chain (template section + reviewer bar)
if grep -q '## Quality baseline' "$ROOT/kit/loop-docs/product-contract.md"; then
  ok "contract template carries the Quality baseline section"
else
  bad "Quality baseline section missing from the contract template" e-static
fi
if grep -q 'Quality-baseline' "$SK/loop-review/SKILL.md"; then
  ok "loop-review judges Quality-baseline violations"
else
  bad "loop-review missing the Quality-baseline bar" e-static
fi
# E14: shared-block stop-reading gate (identity across the 3 copies is enforced
# by the html_block_sha check above; this pins the paragraph's existence)
if grep -q 'Stop-reading gate' "$SK/loop-iterate/SKILL.md"; then
  ok "shared HTML block carries the Stop-reading gate"
else
  bad "Stop-reading gate missing from the shared HTML block" e-static
fi
# E8a: corrected RISK trigger wording — RISK is an evaluator/harness verdict,
# never worker-declared, and never a supervised arrival
if grep -q 'never a state you declare' "$SK/loop-iterate/SKILL.md"; then
  ok "loop-iterate describes RISK as a harness verdict, never self-declared"
else
  bad "loop-iterate RISK wording not corrected" e-static
fi
if grep -q 'never reaches you' "$SK/loop-supervise/SKILL.md"; then
  ok "loop-supervise states RISK never reaches the supervisor"
else
  bad "loop-supervise missing the RISK disclaimer" e-static
fi
if sed -n '1,20p' "$SK/loop-supervise/SKILL.md" | grep 'RISK_REQUIRES_APPROVAL' | grep -qv 'never reaches you'; then
  bad "loop-supervise intro still lists RISK_REQUIRES_APPROVAL as a supervised arrival" e-static
else
  ok "loop-supervise intro no longer names RISK as a supervised arrival"
fi
# E1: the decompose leftover die names the real risk (no fixture reaches this
# message anymore — the state-preserving resume routes around it — so pin the
# source text itself)
if grep -q 'skips the mandatory integration gate' "$ROOT/bin/loop.sh"; then
  ok "leftover-queue die warns that clean --done skips the integration gate"
else
  bad "leftover-queue die reword missing from loop.sh" e-static
fi

