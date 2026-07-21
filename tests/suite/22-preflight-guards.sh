#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "missing .loop/approved-harness -> run refuses (fail closed)"
make_fixture no-harness-approval
rm .loop/approved-harness
run_loop "READY_NOW"
check "exit code 2" no-harness-approval 2 "$RC"
if grep -q 'approval record missing' "$WORK/last-run.out"; then ok "actionable error names the missing record"; else bad "unclear error: $(cat "$WORK/last-run.out")" no-harness-approval; fi

section "empty/unset VERIFY_COMMANDS never passes vacuously"
make_fixture vacuous-gate
# loop.config.sh is gitignored (a harness file): no commit needed, only re-approval
printf 'VERIFY_COMMANDS=()\nMAX_ITERATIONS=2\n' > loop.config.sh
./loop.sh approve >/dev/null
out=$(.loop/bin/evaluate.sh --pre-ref HEAD 2>&1) || true
check "standalone evaluator refuses empty gate" vacuous-gate NEEDS_SPEC_DECISION "${out%% *}"
run_loop "READY_NOW"
check "run refuses empty gate (exit 2)" vacuous-gate 2 "$RC"
printf 'MAX_ITERATIONS=2\n' > loop.config.sh
./loop.sh approve >/dev/null
out=$(.loop/bin/evaluate.sh --pre-ref HEAD 2>&1) || true
check "standalone evaluator refuses missing gate" vacuous-gate NEEDS_SPEC_DECISION "${out%% *}"
run_loop "READY_NOW"
check "run refuses missing gate (exit 2)" vacuous-gate 2 "$RC"

section "non-TTY guided flow does not dead-end (hints at auto mode, exit 0)"
make_fixture notty-hint noapprove
RC=0
out=$(LOOP_CLAUDE_CMD="$FAKE" ./loop.sh </dev/null 2>&1) || RC=$?
check "exit code 0" notty-hint 0 "$RC"
if echo "$out" | grep -q "loop.sh auto"; then ok "auto-mode hint shown"; else bad "no auto hint in: $out" notty-hint; fi

section "init records kit-source for later self-updates"
make_fixture kitsrc
if [ -f .loop/kit-source ] && grep -qF "$ROOT" .loop/kit-source; then ok "kit-source points at the kit repo"; else bad "kit-source not recorded: $(cat .loop/kit-source 2>/dev/null)" kitsrc; fi

section "init projects the 13 Codex-native skills with explicit invocation policy"
make_fixture codex-skill-projection
codex_skills="loop-contract loop-contract-review loop-decompose loop-decompose-review loop-evidence loop-iterate loop-plan loop-plan-review loop-review loop-rollback-review loop-setup loop-stop-eval loop-supervise"
projection_ok=1
projection_count=0
for name in $codex_skills; do
  d=".agents/skills/$name"
  if [ ! -f "$d/SKILL.md" ] || [ ! -f "$d/.loop-kit-managed" ] || [ ! -f "$d/agents/openai.yaml" ]; then
    projection_ok=0
    echo "  $name: missing SKILL.md, ownership marker, or agents/openai.yaml"
    continue
  fi
  projection_count=$((projection_count + 1))
  if grep -q '^disable-model-invocation:' "$d/SKILL.md"; then
    projection_ok=0
    echo "  $name: Claude-only disable-model-invocation leaked into Codex frontmatter"
  fi
  case "$name" in
    loop-contract|loop-plan) expected_policy=true ;;
    *) expected_policy=false ;;
  esac
  if ! grep -q "allow_implicit_invocation: $expected_policy" "$d/agents/openai.yaml"; then
    projection_ok=0
    echo "  $name: allow_implicit_invocation is not $expected_policy"
  fi
  # Codex frontmatter lint (the CLAUDE.md editing invariant): only name +
  # description survive the projection (a future Claude-only key must not
  # silently leak past the strip), the name matches the directory, and the
  # description is single-line, within Codex's 1024-char limit, and free of
  # angle brackets.
  front_lint=$(awk -v dir="$name" '
    NR == 1 && $0 == "---" { front = 1; next }
    front == 1 && $0 == "---" { front = 2; exit }
    front == 1 && $0 ~ /^[A-Za-z0-9_-]+:/ {
      key = $0; sub(/:.*$/, "", key)
      val = $0; sub(/^[A-Za-z0-9_-]+:[[:space:]]*/, "", val)
      if (key == "name") {
        names++
        if (val != dir) print "name is " val ", not " dir
        if (val !~ /^[a-z0-9-]+$/ || length(val) > 64) print "name violates [a-z0-9-]{1,64}"
      } else if (key == "description") {
        descs++
        if (val == "") print "description is empty or not single-line"
        if (length(val) > 1024) print "description exceeds 1024 characters"
        if (val ~ /[<>]/) print "description contains an angle bracket"
      } else {
        print "unexpected frontmatter key: " key
      }
    }
    END {
      if (front != 2) print "unterminated frontmatter"
      if (names != 1) print "expected exactly one name key"
      if (descs != 1) print "expected exactly one description key"
    }
  ' "$d/SKILL.md")
  if [ -n "$front_lint" ]; then
    projection_ok=0
    echo "  $name: $(printf '%s' "$front_lint" | tr '\n' ';')"
  fi
done
if [ "$projection_ok" -eq 1 ] && [ "$projection_count" -eq 13 ]; then
  ok "all 13 projected skills carry valid Codex frontmatter, ownership, and policy"
else
  bad "Codex skill projection incomplete or invalid" codex-skill-projection
fi
if [ ! -e .agents/skills/loop-refine ] && [ ! -e .codex/skills/loop-refine ]; then
  ok "Claude-only loop-refine is not projected into a Codex skill directory"
else
  bad "loop-refine was incorrectly projected for Codex" codex-skill-projection
fi
if [ -z "$(find .codex/skills -type f -name SKILL.md 2>/dev/null || true)" ]; then
  ok "init avoids the duplicate project-local .codex/skills compatibility path"
else
  bad "duplicate Codex skills were generated under .codex/skills" codex-skill-projection
fi

section "projection copies future skill resources recursively"
resource_kit="$WORK/codex-resource-kit"
resource_target="$WORK/codex-resource-target"
mkdir -p "$resource_kit"
cp -R "$ROOT/bin" "$resource_kit/bin"
cp -R "$ROOT/kit" "$resource_kit/kit"
mkdir -p "$resource_kit/kit/.claude/skills/loop-plan/references/nested"
printf 'future resource\n' > "$resource_kit/kit/.claude/skills/loop-plan/references/nested/example.md"
RC=0
"$resource_kit/bin/loop.sh" init "$resource_target" >"$WORK/codex-resource-init.out" 2>&1 || RC=$?
check "resource-kit init exits 0" codex-resource-projection 0 "$RC"
if cmp -s "$resource_kit/kit/.claude/skills/loop-plan/references/nested/example.md" \
          "$resource_target/.agents/skills/loop-plan/references/nested/example.md"; then
  ok "nested canonical skill resources are copied byte-for-byte"
else
  bad "nested skill resource was lost during Codex projection" codex-resource-projection
fi

section "init refuses to overwrite an unmanaged shipped-name Codex skill"
collision_target="$WORK/codex-init-collision"
mkdir -p "$collision_target/.agents/skills/loop-plan"
printf 'user-owned sentinel\n' > "$collision_target/.agents/skills/loop-plan/SKILL.md"
RC=0
"$ROOT/bin/loop.sh" init "$collision_target" >"$WORK/codex-init-collision.out" 2>&1 || RC=$?
check "collision exits 2" codex-init-collision 2 "$RC"
if grep -q 'user-owned sentinel' "$collision_target/.agents/skills/loop-plan/SKILL.md" \
   && [ ! -e "$collision_target/.agents/skills/loop-plan/.loop-kit-managed" ] \
   && grep -q '→ next:' "$WORK/codex-init-collision.out"; then
  ok "unmanaged skill is preserved and the collision names a recovery"
else
  bad "init overwrote or poorly reported the unmanaged skill collision" codex-init-collision
fi

section "update refreshes a diverged harness (kit -> project) + --approve re-approves -> runs green"
make_fixture upd-refresh
# the deployed harness diverged from the kit and was approved in that state;
# `update` pulls the kit version back, so the old approval no longer matches
echo "# LOCAL-DIVERGENCE" >> .claude/skills/loop-iterate/SKILL.md
echo "# CODEX-LOCAL-DIVERGENCE" >> .agents/skills/loop-iterate/SKILL.md
printf 'policy:\n  allow_implicit_invocation: true\n' > .agents/skills/loop-iterate/agents/openai.yaml
./loop.sh approve >/dev/null
sha_before=$(cat loop.sh .loop/bin/evaluate.sh .claude/skills/loop-*/SKILL.md .agents/skills/loop-*/SKILL.md .agents/skills/loop-*/agents/openai.yaml | sha256)
"$ROOT/bin/loop.sh" update "$WORK/upd-refresh" --approve >"$WORK/upd.out" 2>&1 || true
sha_after=$(cat loop.sh .loop/bin/evaluate.sh .claude/skills/loop-*/SKILL.md .agents/skills/loop-*/SKILL.md .agents/skills/loop-*/agents/openai.yaml | sha256)
if ! grep -q 'LOCAL-DIVERGENCE' .claude/skills/loop-iterate/SKILL.md; then ok "diverged skill reconciled to kit"; else bad "skill not refreshed" upd-refresh; fi
if ! grep -q 'CODEX-LOCAL-DIVERGENCE' .agents/skills/loop-iterate/SKILL.md \
   && grep -q 'allow_implicit_invocation: false' .agents/skills/loop-iterate/agents/openai.yaml; then
  ok "Codex projection and explicit policy were regenerated from the kit"
else
  bad "Codex projection was not refreshed" upd-refresh
fi
if [ "$sha_before" != "$sha_after" ]; then ok "harness hash changed by the refresh"; else bad "harness unchanged after refresh" upd-refresh; fi
if grep -qi 're-approved' "$WORK/upd.out"; then ok "stale approval triggered re-approval"; else bad "no re-approval note: $(cat "$WORK/upd.out")" upd-refresh; fi
run_loop "READY_NOW"
check "runs green after update --approve" upd-refresh 0 "$RC"
check "state SUCCESS" upd-refresh SUCCESS "$STATE"

section "update without --approve leaves a stale approval and warns (no silent run)"
make_fixture upd-warn
echo "# LOCAL-DIVERGENCE" >> .claude/skills/loop-iterate/SKILL.md
./loop.sh approve >/dev/null          # approval now matches the diverged harness
"$ROOT/bin/loop.sh" update "$WORK/upd-warn" >"$WORK/upd2.out" 2>&1 || true
if grep -qi 'stale' "$WORK/upd2.out"; then ok "stale-approval reminder shown"; else bad "no stale reminder: $(cat "$WORK/upd2.out")" upd-warn; fi
run_loop "READY_NOW"
check "refuses to run until re-approved" upd-warn 2 "$RC"
./loop.sh approve >/dev/null
run_loop "READY_NOW"
check "runs after manual re-approve" upd-warn 0 "$RC"

section "update from inside a project is a no-op when already current (records kit-source via --from)"
make_fixture upd-noop
rm -f .loop/kit-source
out=$(./loop.sh update --from "$ROOT" 2>&1) || true
if echo "$out" | grep -qi 'up to date'; then ok "self-update detects up-to-date harness"; else bad "expected up-to-date: $out" upd-noop; fi
if grep -qF "$ROOT" .loop/kit-source 2>/dev/null; then ok "kit-source (re)written via --from"; else bad "kit-source not written" upd-noop; fi
if echo "$out" | grep -q 'loop.models.sh has keys your file lacks.*AGENT_IMPLEMENT'; then
  ok "update surfaces new commented AGENT_* routing keys to existing deployments"
else
  bad "commented agent-routing keys were invisible to update drift detection: $out" upd-noop
fi

section "update preserves user .agents content and self-heals the Codex gitignore block"
make_fixture codex-update-preserve
mkdir -p .agents/skills/my-skill
printf '# user skill\n' > .agents/skills/my-skill/SKILL.md
printf '# user project instructions\n' > AGENTS.md
printf 'node_modules/\n' > .gitignore
RC=0
./loop.sh update --from "$ROOT" >"$WORK/codex-update-preserve.out" 2>&1 || RC=$?
check "update exits 0" codex-update-preserve 0 "$RC"
if grep -q '# user skill' .agents/skills/my-skill/SKILL.md \
   && grep -q '# user project instructions' AGENTS.md; then
  ok "update preserves user skills and root AGENTS.md"
else
  bad "update clobbered user-owned .agents content" codex-update-preserve
fi
check "Codex skill ignore rule restored exactly once" codex-update-preserve 1 \
  "$(grep -cFx '/.agents/skills/loop-*/' .gitignore || true)"
if grep -qFx 'node_modules/' .gitignore; then
  ok "gitignore self-heal preserves user entries"
else
  bad "gitignore self-heal dropped user content" codex-update-preserve
fi

section "update sweeps stale projection staging leftovers from an interrupted refresh"
make_fixture codex-update-stale-stage
mkdir -p .agents/skills/.loop-plan.loop-kit-new.99999 \
         .agents/skills/.loop-review.loop-kit-old.4242 \
         .agents/skills/my-skill
printf 'orphaned stage\n' > .agents/skills/.loop-plan.loop-kit-new.99999/SKILL.md
printf 'orphaned backup\n' > .agents/skills/.loop-review.loop-kit-old.4242/SKILL.md
printf '# user skill\n' > .agents/skills/my-skill/SKILL.md
RC=0
./loop.sh update --from "$ROOT" >"$WORK/codex-update-stale-stage.out" 2>&1 || RC=$?
check "update exits 0" codex-update-stale-stage 0 "$RC"
if [ ! -e .agents/skills/.loop-plan.loop-kit-new.99999 ] \
   && [ ! -e .agents/skills/.loop-review.loop-kit-old.4242 ]; then
  ok "stale staging/backup leftovers are swept (a run's git add -A can no longer commit them)"
else
  bad "stale staging leftovers survived update: $(find .agents/skills -mindepth 1 -maxdepth 1 | tr '\n' ' ')" codex-update-stale-stage
fi
if grep -q '# user skill' .agents/skills/my-skill/SKILL.md \
   && [ -f .agents/skills/loop-plan/.loop-kit-managed ] \
   && [ -f .agents/skills/loop-review/SKILL.md ]; then
  ok "sweep leaves user skills and managed projections intact"
else
  bad "sweep damaged neighboring skill content" codex-update-stale-stage
fi

section "update refuses an unmanaged shipped-name Codex skill collision"
make_fixture codex-update-collision
rm -f .agents/skills/loop-review/.loop-kit-managed
printf '\n# user-owned collision sentinel\n' >> .agents/skills/loop-review/SKILL.md
RC=0
./loop.sh update --from "$ROOT" >"$WORK/codex-update-collision.out" 2>&1 || RC=$?
check "collision exits 2" codex-update-collision 2 "$RC"
if grep -q 'user-owned collision sentinel' .agents/skills/loop-review/SKILL.md \
   && [ ! -e .agents/skills/loop-review/.loop-kit-managed ] \
   && grep -q '→ next:' "$WORK/codex-update-collision.out"; then
  ok "update preserves and reports the unmanaged collision"
else
  bad "update overwrote or poorly reported the unmanaged collision" codex-update-collision
fi

section "the full .codex control tree participates in approval and update hash parity"
make_fixture upd-codex-tree
mkdir -p .codex/hooks .codex/rules
printf 'model_reasoning_effort = "high"\n' > .codex/config.toml
printf '{"hooks":[]}\n' > .codex/hooks.json
printf '#!/bin/sh\nexit 0\n' > .codex/hooks/pre-tool.sh
printf 'prefix_rule(pattern=["git", "status"], decision="allow")\n' > .codex/rules/default.rules
./loop.sh approve >/dev/null
out=$(./loop.sh update --from "$ROOT" 2>&1) || true
if echo "$out" | grep -qi 'up to date' && ! echo "$out" | grep -qi 'approval.*stale'; then
  ok "update hash matches the approved harness when nested Codex controls are unchanged"
else
  bad "target_harness_sha drifted from harness_hash: $out" codex-tree-hash
fi
printf '# tampered\n' >> .codex/hooks/pre-tool.sh
run_loop "READY_NOW"
check "nested Codex control mutation refuses the run" codex-tree-hash 2 "$RC"
if grep -q '.codex' "$WORK/last-run.out"; then
  ok "approval failure names the changed Codex control tree"
else
  bad "Codex control tamper was not explained: $(cat "$WORK/last-run.out")" codex-tree-hash
fi

section "evaluator diff policy classifies .codex/config.toml as a harness path"
make_fixture codex-eval-diff
mkdir -p .codex
printf 'model_reasoning_effort = "high"\n' > .codex/config.toml
git add .codex/config.toml && git commit -q -m "track codex project config"
printf 'model_reasoning_effort = "low"\n' > .codex/config.toml
out=$(.loop/bin/evaluate.sh --pre-ref HEAD 2>&1) || true
check "verdict RISK_REQUIRES_APPROVAL" codex-eval-diff RISK_REQUIRES_APPROVAL "${out%% *}"
case "$out" in
  *"harness file(s) modified by the loop: .codex/config.toml"*) ok "diff policy names the Codex project config" ;;
  *) bad "evaluator did not classify .codex/config.toml as harness: $out" codex-eval-diff ;;
esac

section "evaluator diff policy classifies .agents managed skills as harness paths"
make_fixture codex-agents-eval-diff
git add -f .agents/skills/loop-iterate/SKILL.md
git commit -q -m "track projected Codex skill"
printf '\n# changed by agent\n' >> .agents/skills/loop-iterate/SKILL.md
out=$(.loop/bin/evaluate.sh --pre-ref HEAD 2>&1) || true
check "verdict RISK_REQUIRES_APPROVAL" codex-agents-eval-diff RISK_REQUIRES_APPROVAL "${out%% *}"
case "$out" in
  *"harness file(s) modified by the loop:"*".agents/skills/loop-iterate/SKILL.md"*) ok "diff policy names the projected Codex skill" ;;
  *) bad "evaluator did not classify .agents as harness: $out" codex-agents-eval-diff ;;
esac

section "update refuses an unknown kit source (deployed, no recorded source, no --from)"
make_fixture upd-nosrc
rm -f .loop/kit-source
RC=0
out=$(./loop.sh update 2>&1) || RC=$?
check "exit code 2 (usage error)" upd-nosrc 2 "$RC"
if echo "$out" | grep -qi 'where the kit is'; then ok "clear guidance to pass --from"; else bad "no guidance: $out" upd-nosrc; fi

section "verdict at END of review output parsed as APPROVE (real-run regression)"
make_fixture tail-verdict
run_loop "READY_NOW" "APPROVE_TAIL"
check "exit code 0" tail-verdict 0 "$RC"
check "state SUCCESS" tail-verdict SUCCESS "$STATE"
if grep -q '"state": "REVIEW_APPROVE"' .loop/journal.jsonl; then ok "trailing verdict parsed as APPROVE"; else bad "trailing verdict misread" tail-verdict; fi
if grep -q 'VERDICT: APPROVE' .loop/journal.jsonl; then ok "journal records the verdict line"; else bad "journal lost the verdict line" tail-verdict; fi

section "trailing REVISE verdict still parsed as REVISE"
make_fixture tail-revise
run_loop "READY_NOW,READY_NOW" "REVISE_TAIL,APPROVE_TAIL"
check "exit code 0" tail-revise 0 "$RC"
check "state SUCCESS" tail-revise SUCCESS "$STATE"
if grep -q '"state": "REVIEW_REVISE"' .loop/journal.jsonl; then ok "trailing REVISE parsed"; else bad "trailing REVISE missed" tail-revise; fi

section "decorated VERDICT line (blockquote+bullet+backticks) still parsed as APPROVE"
# E13: real reviewers decorate — the harness's iterated leading-decoration strip
# must recover the verdict instead of failing safe to REVISE on a sound gate
make_fixture decorated-verdict
run_loop "READY_NOW" "APPROVE_DECORATED"
check "exit code 0" decorated-verdict 0 "$RC"
check "state SUCCESS" decorated-verdict SUCCESS "$STATE"
if grep -q '"state": "REVIEW_APPROVE"' .loop/journal.jsonl; then ok "decorated verdict parsed as APPROVE"; else bad "decorated verdict misread" decorated-verdict; fi

section "decorated HTML-DECISION marker still journaled as HTML_SKIPPED"
make_fixture decorated-marker
export LOOP_FAKE_HTML=DECORATED
run_loop "READY_NOW"
unset LOOP_FAKE_HTML
check "exit code 0" decorated-marker 0 "$RC"
check "state SUCCESS" decorated-marker SUCCESS "$STATE"
if grep -q '"state": "HTML_SKIPPED"' .loop/journal.jsonl; then ok "decorated marker parsed (HTML_SKIPPED)"; else bad "HTML_SKIPPED missing" decorated-marker; fi
if ! grep -q '"state": "HTML_UNDECLARED"' .loop/journal.jsonl; then ok "decoration did not degrade to HTML_UNDECLARED"; else bad "decorated marker read as undeclared" decorated-marker; fi

section "code-fenced stop-eval verdicts parsed (FUTILE x2 -> STALLED)"
make_fixture fenced-futile
run_loop "BAD_FIX,BAD_FIX" "APPROVE" "FUTILE_FENCED,FUTILE_FENCED"
check "exit code 4" fenced-futile 4 "$RC"
check "state STALLED" fenced-futile STALLED "$STATE"

section "reviewer output without any verdict: retried once, then safe REVISE"
make_fixture noverdict
run_loop "READY_NOW,READY_NOW,READY_NOW" "NOVERDICT"
check "exit code 4" noverdict 4 "$RC"
check "state BLOCKED" noverdict BLOCKED "$STATE"
if grep -q 'unparseable' .loop/journal.jsonl; then ok "journal says unparseable (honest telemetry)"; else bad "unparseable not recorded" noverdict; fi
check "reviewer retried with a format reminder (2 attempts per gate)" noverdict 6 "$(cat .loop/fake-review-i 2>/dev/null || echo 0)"

section "interim REVISEs do not burn the success-gate MAX_REVISIONS budget"
make_fixture counter-split
run_loop "CONTINUE_FIX,BAD_FIX,READY_NOW,READY_NOW" "REVISE,REVISE,REVISE,APPROVE"
check "exit code 0" counter-split 0 "$RC"
check "state SUCCESS (old shared counter would have BLOCKED)" counter-split SUCCESS "$STATE"
if grep -q 'mode=interim' .loop/fake-review-prompts && grep -q 'mode=gate' .loop/fake-review-prompts; then
  ok "review modes passed to the skill (interim + gate)"
else
  bad "review mode arguments missing: $(sort -u .loop/fake-review-prompts | tr '\n' ' ')" counter-split
fi

section "interim review churn (REVISE x3 in a row) -> BLOCKED"
make_fixture interim-churn
run_loop "CONTINUE_FIX,BAD_FIX,BAD_FIX" "REVISE"
check "exit code 4" interim-churn 4 "$RC"
check "state BLOCKED" interim-churn BLOCKED "$STATE"
if grep -q 'consecutive iterations' "$WORK/last-run.out"; then ok "churn reason names consecutive iterations"; else bad "wrong churn reason" interim-churn; fi

section "MET with verify-red fails deterministic preflight and resets the streak"
make_fixture met-nudge
run_loop "BAD_FIX,BAD_FIX" "APPROVE" "MET"
check "exit code 4 (identical failures, never forced)" met-nudge 4 "$RC"
if [ ! -f .loop/stop-nudge.md ]; then ok "no READY nudge survives a failed preflight"; else bad "preflight-refused MET left a stop nudge" met-nudge; fi
check "failed preflight resets MET streak" met-nudge 0 "$(cat .loop/met-count 2>/dev/null || echo missing)"
if grep -q 'FORCED_GATE_REFUSED' .loop/journal.jsonl; then ok "failed MET preflight journaled"; else bad "preflight refusal missing" met-nudge; fi
if ! grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "forced gate blocked while verify red"; else bad "forced gate fired on red verify" met-nudge; fi

section "nudge cleared when stop-eval stops saying MET"
make_fixture met-clear
run_loop "BAD_FIX,BAD_FIX" "APPROVE" "MET,CONTINUE"
if [ ! -f .loop/stop-nudge.md ]; then ok "nudge removed on non-MET"; else bad "stale nudge left" met-clear; fi
check "met streak reset" met-clear 0 "$(cat .loop/met-count 2>/dev/null || echo missing)"

section "near-miss verdict tokens are not verdicts (boundary-enforced parser)"
# STOP-EVAL: METHOD must read as CONTINUE (a prefix match would count it as MET
# and force the gate after two of them)
make_fixture verdict-nearmiss-stopeval
seed_ledger_met
run_loop "CONTINUE_FIX,NO_DIFF,NO_DIFF" "APPROVE" "METHOD,METHOD,METHOD"
check "exit code 4 (stalls, never forced)" verdict-nearmiss-stopeval 4 "$RC"
check "state STALLED" verdict-nearmiss-stopeval STALLED "$STATE"
if ! grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "METHOD never counted as MET"; else bad "forced gate fired on STOP-EVAL: METHOD" verdict-nearmiss-stopeval; fi
if grep -q '"state": "STOP_EVAL_CONTINUE"' .loop/journal.jsonl; then ok "near-miss stop verdict journaled as CONTINUE"; else bad "STOP_EVAL_CONTINUE missing" verdict-nearmiss-stopeval; fi

section "gate reviewer saying VERDICT: APPROVED is not an APPROVE"
make_fixture verdict-nearmiss-gate
run_loop "READY_NOW,READY_NOW,READY_NOW" "APPROVED_TYPO"
check "exit code 4" verdict-nearmiss-gate 4 "$RC"
check "state BLOCKED (never certified)" verdict-nearmiss-gate BLOCKED "$STATE"
if ! grep -q '"state": "SUCCESS"' .loop/journal.jsonl; then ok "APPROVED never certified success"; else bad "near-miss APPROVED reached SUCCESS" verdict-nearmiss-gate; fi
if grep -q 'unparseable' .loop/journal.jsonl; then ok "near-miss verdict recorded as unparseable"; else bad "unparseable telemetry missing" verdict-nearmiss-gate; fi

section "gate per-REQ verdict REQ-001: METICULOUS is not MET (downgrade)"
make_fixture verdict-nearmiss-req
run_loop "READY_NOW,READY_NOW" "APPROVE_NEARMISS_REQ,APPROVE"
check "exit code 0 (clean table on retry passes)" verdict-nearmiss-req 0 "$RC"
if grep -q 'harness downgrade' .loop/journal.jsonl; then ok "near-miss per-REQ verdict downgraded the APPROVE"; else bad "no downgrade on METICULOUS" verdict-nearmiss-req; fi

section "forged .loop/met-count cannot force the gate after a single MET"
# the file is a display mirror; the authoritative streak lives in process
# memory. A verify command forges 999999 into the file every evaluator pass.
make_fixture met-forge
seed_ledger_met
printf '#!/bin/sh\necho 999999 > .loop/met-count\ngrep -q fixed value.txt\n' > check.sh
git add -A && git commit -q -m "forging verify"
run_loop "CONTINUE_FIX,NO_DIFF,NO_DIFF" "APPROVE" "MET,CONTINUE,CONTINUE"
check "exit code 4 (stalls, not forced)" met-forge 4 "$RC"
check "state STALLED" met-forge STALLED "$STATE"
if ! grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "one MET + forged count never forced the gate"; else bad "forged met-count forced the gate" met-forge; fi

section "garbage .loop/met-count neither crashes the run nor blocks a real streak"
make_fixture met-garbage
seed_ledger_met
printf '#!/bin/sh\necho abc > .loop/met-count\ngrep -q fixed value.txt\n' > check.sh
git add -A && git commit -q -m "garbage-writing verify"
run_loop "CONTINUE_FIX,NO_DIFF" "APPROVE" "MET,MET"
check "exit code 0 (in-memory streak still forces at 2)" met-garbage 0 "$RC"
check "state SUCCESS" met-garbage SUCCESS "$STATE"
if grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "real MET x2 forced the gate despite file garbage"; else bad "FORCED_GATE missing with garbage mirror" met-garbage; fi

section "duplicate ledger rows (met + regressed) are a contradiction, not met"
for order in met-first regressed-first; do
  make_fixture "ledger-dup-$order"
  printf 'REVIEW_MODE="off"\n' >> loop.config.sh
  if [ "$order" = met-first ]; then
    cat > .loop/docs/requirements-ledger.md <<'EOF'
# Requirements Ledger

| REQ | Status | Evidence | Iter |
|---|---|---|---|
| REQ-001 | met | value.txt fixed | 1 |
| REQ-001 | regressed | broke again | 2 |
EOF
  else
    cat > .loop/docs/requirements-ledger.md <<'EOF'
# Requirements Ledger

| REQ | Status | Evidence | Iter |
|---|---|---|---|
| REQ-001 | regressed | broke again | 2 |
| REQ-001 | met | value.txt fixed | 1 |
EOF
  fi
  git add -A && git commit -q -m "contradictory ledger ($order)"
  ./loop.sh approve >/dev/null
  run_loop "CONTINUE_GREEN,NO_DIFF,NO_DIFF" "APPROVE" "MET"
  if [ "$RC" -ne 0 ] && ! grep -q '"state": "SUCCESS"' .loop/journal.jsonl; then
    ok "contradictory ledger never reached SUCCESS ($order)"
  else
    bad "duplicate REQ rows promoted to SUCCESS ($order)" "ledger-dup-$order"
  fi
  if grep -q 'duplicate rows' .loop/journal.jsonl; then ok "refusal names the duplicate rows ($order)"; else bad "duplicate-row reason missing ($order)" "ledger-dup-$order"; fi
done

section "verify command replacing the observations manifest is caught immediately"
make_fixture manifest-verify-tamper
printf '{"ac_id":"AC-OLD","artifact_path":".loop/observations/old.log","artifact_sha256":"deadbeef"}\n' > .loop/observations-manifest.jsonl
# tamper only once the agent fixed value.txt: the baseline pass must stay clean
# so the run pins the seeded manifest, and the FIRST post-fix evaluator pass
# (which runs this file) swaps it — the old code laundered that swap through
# the stop-eval/gate re-pin
printf '#!/bin/sh\nif grep -q fixed value.txt; then echo evil > .loop/observations-manifest.jsonl; fi\ngrep -q fixed value.txt\n' > check.sh
git add -A && git commit -q -m "manifest-replacing verify"
run_loop "READY_NOW"
check "exit code 3" manifest-verify-tamper 3 "$RC"
check "state RISK_REQUIRES_APPROVAL" manifest-verify-tamper RISK_REQUIRES_APPROVAL "$STATE"
if grep -q "verification commands" "$WORK/last-run.out"; then ok "reason names the verification commands"; else bad "tamper reason missing" manifest-verify-tamper; fi
if ! grep -q '"state": "SUCCESS"' .loop/journal.jsonl; then ok "manifest swap never certified"; else bad "manifest swap reached SUCCESS" manifest-verify-tamper; fi

section "report citing observations only through a /tmp alias is invalid"
make_fixture report-alias
mkdir -p .loop/observations
printf 'screenshot bytes\n' > .loop/observations/shot.png
cat > .loop/docs/acceptance-checklist.md <<'EOF'
# Acceptance Checklist

| AC | REQ | Expectation | Method | Status | Evidence |
|---|---|---|---|---|---|
| AC-001 | REQ-001 | the page visibly renders | run | verified | .loop/observations/shot.png |
EOF
git add -A && git commit -q -m "verified run row with real observation"
./loop.sh approve >/dev/null
export LOOP_FAKE_EVIDENCE=PREFIX_ALIAS
run_loop "READY_NOW"
unset LOOP_FAKE_EVIDENCE
check "exit code 4" report-alias 4 "$RC"
check "state BLOCKED" report-alias BLOCKED "$STATE"
if grep -q "report omits checklist observation" "$WORK/last-run.out"; then ok "prefix-aliased citation rejected as an omission"; else bad "alias citation accepted" report-alias; fi

section "an invalid evidence report is regenerated with the rejection reason"
# EVIDENCE_RETRY_N (code fallback 2): a CONTENT-invalid report is deleted and
# /loop-evidence re-invoked with rejected='<deterministic reason>'; the fake's
# first call invents a non-checklist citation, its second comes out clean.
make_fixture evidence-retry
mkdir -p .loop/observations
printf 'screenshot bytes\n' > .loop/observations/shot.png
cat > .loop/docs/acceptance-checklist.md <<'EOF'
# Acceptance Checklist

| AC | REQ | Expectation | Method | Status | Evidence |
|---|---|---|---|---|---|
| AC-001 | REQ-001 | the page visibly renders | run | verified | .loop/observations/shot.png |
EOF
git add -A && git commit -q -m "verified run row with real observation"
./loop.sh approve >/dev/null
export LOOP_FAKE_EVIDENCE=BAD_THEN_GOOD
run_loop "READY_NOW"
unset LOOP_FAKE_EVIDENCE
check "exit code 0" evidence-retry 0 "$RC"
check "state SUCCESS" evidence-retry SUCCESS "$STATE"
if grep -q '"state": "EVIDENCE_RETRY"' .loop/journal.jsonl; then ok "regeneration journaled"; else bad "EVIDENCE_RETRY missing from journal" evidence-retry; fi
if grep -q "outside the verified checklist" .loop/journal.jsonl; then ok "retry carried the deterministic rejection reason"; else bad "rejection reason missing from journal" evidence-retry; fi
if grep -q "rejected='" .loop/fake-evidence-prompts; then ok "regeneration prompt received rejected='...'"; else bad "rejected= not passed to the regeneration" evidence-retry; fi
check "exactly one regeneration (two evidence calls)" evidence-retry 2 "$(grep -c '/loop-evidence' .loop/fake-evidence-prompts)"

section "the historical-path deadlock shape now fails EARLY at iteration time"
# Regression for the shape that deadlocked a real run: canonical path in
# backticks + CJK punctuation glued on + a second historical literal path in
# the same cell. Preflight used to pass (first token only) and the run died
# terminally at the evidence gate; now 6.6(e) refuses at iteration time with
# the fix in the reason, and the terminal gate is never reached.
make_fixture gate-deadlock
mkdir -p .loop/observations
printf 'probe ok\n' > .loop/observations/iter15-AC-001-probe.log
printf 'old probe\n' > .loop/observations/iter2-AC-001-probe.log
cat > .loop/docs/acceptance-checklist.md <<'EOF'
# Acceptance Checklist

| AC | REQ | Expectation | Method | Status | Evidence |
|---|---|---|---|---|---|
| AC-001 | REQ-001 | the probe answers | run | verified | `.loop/observations/iter15-AC-001-probe.log`。（履歴: .loop/observations/iter2-AC-001-probe.log） |
EOF
git add -A && git commit -q -m "deadlock-shape evidence cell"
./loop.sh approve >/dev/null
run_loop "READY_NOW,NO_DIFF,NO_DIFF"
check "exit code 4 (stalls; the gate is never reached)" gate-deadlock 4 "$RC"
check "state STALLED" gate-deadlock STALLED "$STATE"
if grep -q "cites 2 observation paths" .loop/journal.jsonl; then ok "deadlock shape refused at iteration time"; else bad "singleton refusal missing from journal" gate-deadlock; fi
if ! grep -q "current evidence report is invalid" "$WORK/last-run.out" \
   && ! grep -q '"state": "SUCCESS"' .loop/journal.jsonl; then
  ok "failure moved off the terminal evidence gate"
else
  bad "deadlock still reaches the terminal gate or SUCCESS" gate-deadlock
fi

section "same-second fresh restarts get distinct run ids and prevrun archives"
make_fixture same-second
mkdir -p fakebin
cat > fakebin/date <<'EOF'
#!/bin/sh
# frozen clock: every format renders the same instant (BSD -r / GNU -d @)
if /bin/date -u -r 1700000000 +%s >/dev/null 2>&1; then
  exec /bin/date -u -r 1700000000 "$@"
fi
exec /bin/date -u -d @1700000000 "$@"
EOF
chmod +x fakebin/date
for i in 1 2 3; do
  RC=0
  PATH="$PWD/fakebin:$PATH" LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
    LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
    ./loop.sh run >"$WORK/same-second-$i.out" 2>&1 </dev/null || RC=$?
  check "frozen-clock run $i completes" same-second 0 "$RC"
done
tid=$(cat .loop/task-id)
n_runs=$(find ".loop/logs/$tid" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
check "three distinct run log dirs under one frozen second" same-second 3 "$n_runs"
n_prev=$(find .loop/docs/run-archive -mindepth 1 -maxdepth 1 -type d -name '*-prevrun*' | wc -l | tr -d ' ')
check "two distinct prevrun archives (no hybrid dir)" same-second 2 "$n_prev"
for d in .loop/docs/run-archive/*-prevrun*; do
  if [ -f "$d/evidence-report.md" ]; then ok "prevrun archive intact: $(basename "$d")"; else bad "prevrun archive missing report: $(basename "$d")" same-second; fi
done
if [ -z "$(ls -d .loop/docs/run-archive/.tmp-* 2>/dev/null)" ]; then ok "no archive staging residue after repeated resets"; else bad "staging residue left under run-archive: $(ls -d .loop/docs/run-archive/.tmp-*)" same-second; fi

section "a second run cannot enter the cold-start window (atomic claim)"
make_fixture coldstart-claim
# 3s window: THREE probes (run/start/fleet run) must all land inside A's
# deliberately-slowed baseline verify
printf '#!/bin/sh\nsleep 3\ngrep -q fixed value.txt\n' > check.sh
git add -A && git commit -q -m "slow verify"
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh run >"$WORK/coldstart-a.out" 2>&1 </dev/null &
CS=$!
# deterministic entry into the window: wait for A's claim, then race B while
# A is still inside its (deliberately slowed) baseline verify
n=0
while [ "$n" -lt $((100 * POLL_SCALE)) ] && [ ! -f .loop/run-claim.pid ]; do sleep 0.05; n=$((n + 1)); done
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh run >"$WORK/coldstart-b.out" 2>&1 </dev/null || RC=$?
check "second run refused during the cold-start window" coldstart-claim 2 "$RC"
if grep -q "already starting" "$WORK/coldstart-b.out"; then ok "claim refusal names the starting run"; else bad "no claim refusal message: $(head -2 "$WORK/coldstart-b.out")" coldstart-claim; fi
# the published claim record is never observable without its owner pid: the
# ln-publish closes the mkdir-then-write init window two acquirers could split
if [ -s .loop/run-claim.pid ] && grep -qE '^[0-9]+$' .loop/run-claim.pid; then
  ok "claim record is complete the instant it exists (atomic ln publish)"
else
  bad "claim record observable without a complete owner pid" coldstart-claim
fi
# a NEW-task definition and a manual fleet run must also refuse the window:
# neither sees .loop/run.pid yet, and both would mutate docs/HEAD under the
# booting run's baseline verify
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh start "another task" >"$WORK/coldstart-start.out" 2>&1 </dev/null || RC=$?
check "start refused during the cold-start window" coldstart-claim 2 "$RC"
if grep -q "run is starting" "$WORK/coldstart-start.out"; then ok "start refusal names the booting run"; else bad "start refusal message missing: $(head -3 "$WORK/coldstart-start.out")" coldstart-claim; fi
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --drain >"$WORK/coldstart-fleet.out" 2>&1 </dev/null || RC=$?
check "manual fleet run refused during the cold-start window" coldstart-claim 2 "$RC"
if grep -q "must not run together" "$WORK/coldstart-fleet.out"; then ok "fleet refusal names the split-brain rule"; else bad "fleet refusal message missing: $(head -3 "$WORK/coldstart-fleet.out")" coldstart-claim; fi
wait_sup "$CS" coldstart-claim
check "first run still completes" coldstart-claim 0 "$RC"
check "state SUCCESS" coldstart-claim SUCCESS "$(cat .loop/state)"
if [ ! -e .loop/run-claim.pid ]; then ok "cold-start claim released"; else bad "claim record left behind" coldstart-claim; fi
printf '#!/bin/sh\ngrep -q fixed value.txt\n' > check.sh   # fast verify again for the claim-record probes
git add -A && git commit -q -m "fast verify restored"
# fail-closed on an unattributable record: garbage must block, never be reclaimed
echo garbage > .loop/run-claim.pid
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh run --fresh >"$WORK/coldstart-garbage.out" 2>&1 </dev/null || RC=$?
check "garbage claim record refuses the run (fail closed)" coldstart-claim 2 "$RC"
if grep -q "already starting" "$WORK/coldstart-garbage.out"; then ok "garbage record refusal reported"; else bad "garbage record not refused: $(head -2 "$WORK/coldstart-garbage.out")" coldstart-claim; fi
rm -f .loop/run-claim.pid
# a DEAD holder is reclaimed automatically (the claim can never brick a repo)
sh -c 'echo $$ > .loop/run-claim.pid'
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh run --fresh >"$WORK/coldstart-dead.out" 2>&1 </dev/null || RC=$?
check "dead claim holder reclaimed" coldstart-claim 0 "$RC"
check "state SUCCESS after reclaim" coldstart-claim SUCCESS "$(cat .loop/state)"

section "a stop-evaluator outage breaks the qualified MET streak"
make_fixture met-error-reset
seed_ledger_met
run_loop "CONTINUE_FIX,NO_DIFF,NO_DIFF" "APPROVE" "MET,CRASH,CONTINUE"
check "stop-eval error resets MET streak" met-error-reset 0 "$(cat .loop/met-count 2>/dev/null || echo missing)"
if [ ! -f .loop/stop-nudge.md ]; then ok "stop-eval error removes the stale READY nudge"; else bad "stop-eval error left a READY nudge" met-error-reset; fi
if grep -q '"state": "STOP_EVAL_ERROR"' .loop/journal.jsonl; then ok "stop-eval outage journaled"; else bad "STOP_EVAL_ERROR missing" met-error-reset; fi

section "MET x2 + verify green forces the success gate -> SUCCESS without READY"
make_fixture met-force
seed_ledger_met
run_loop "CONTINUE_FIX,NO_DIFF" "APPROVE" "MET,MET"
check "exit code 0" met-force 0 "$RC"
check "state SUCCESS" met-force SUCCESS "$STATE"
if grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "forced gate journaled"; else bad "FORCED_GATE missing" met-force; fi
if grep -q 'gate forced after MET' "$WORK/last-run.out"; then ok "final evaluator reports the forced gate honestly"; else bad "forced-gate reason missing" met-force; fi

section "forced-gate rejections never count toward MAX_REVISIONS"
make_fixture met-force-revise
seed_ledger_met
run_loop "CONTINUE_GREEN,CONTINUE_GREEN,CONTINUE_GREEN,CONTINUE_GREEN" "APPROVE,APPROVE,REVISE,APPROVE,APPROVE,REVISE" "MET"
check "exit code 5 (max iterations, NOT blocked)" met-force-revise 5 "$RC"
check "state BUDGET_EXCEEDED (forced REVISEs did not accumulate)" met-force-revise BUDGET_EXCEEDED "$STATE"
n=$(grep -c '"state": "FORCED_GATE"' .loop/journal.jsonl || true)
check "forced gate fired twice" met-force-revise 2 "$n"

section "forced gate suppressed while this iteration's interim review rejected"
make_fixture met-suppress
run_loop "CONTINUE_FIX,BAD_FIX,BAD_FIX" "REVISE" "MET"
check "exit code 4" met-suppress 4 "$RC"
check "state BLOCKED (interim churn, not a forced gate)" met-suppress BLOCKED "$STATE"
if ! grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "no forced gate while must-fix items outstanding"; else bad "forced gate fired despite interim REVISE" met-suppress; fi

section "MET_FORCE_N=0 disables the forced gate"
make_fixture met-force-off
printf 'MET_FORCE_N=0\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "CONTINUE_FIX,NO_DIFF,NO_DIFF" "APPROVE" "MET"
check "exit code 4 (stalls instead of forcing)" met-force-off 4 "$RC"
check "state STALLED" met-force-off STALLED "$STATE"
if ! grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "no forced gate with MET_FORCE_N=0"; else bad "forced gate fired while disabled" met-force-off; fi

section "REVIEW_MODE=off: forced gate refused while self-reports show open work"
# The hole this closes: with review off no gate reviewer audits the ledger or
# the acceptance checklist, and the forced final (--assume-ready) skips the
# evaluator's 6.5/6.6 tiers by design — two premature MET verdicts from the
# advisory stop evaluator must not reach SUCCESS over an open checklist row.
make_fixture met-force-noreview
printf 'REVIEW_MODE="off"\n' >> loop.config.sh
seed_ledger_met
cat > .loop/docs/acceptance-checklist.md <<'EOF'
# Acceptance Checklist

| AC | REQ | Expectation | Method | Status | Evidence |
|---|---|---|---|---|---|
| AC-001 | REQ-001 | the page visibly renders | run | pending | - |
EOF
git add -A && git commit -q -m "review off + open checklist row"
./loop.sh approve >/dev/null
run_loop "CONTINUE_FIX,NO_DIFF,NO_DIFF" "APPROVE" "MET"
check "exit code 4 (never forced to SUCCESS)" met-force-noreview 4 "$RC"
check "state STALLED" met-force-noreview STALLED "$STATE"
if grep -q '"state": "FORCED_GATE_REFUSED"' .loop/journal.jsonl; then ok "refusal journaled as FORCED_GATE_REFUSED"; else bad "FORCED_GATE_REFUSED missing" met-force-noreview; fi
if ! grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "gate never forced over open self-reports"; else bad "forced gate fired with review off + open rows" met-force-noreview; fi
if grep -q 'acceptance checklist has unverified rows' .loop/journal.jsonl; then
  ok "refusal names the open checklist in review-off mode"
else
  bad "refusal reason missing the checklist detail" met-force-noreview
fi

section "postmortem: review-on + empty diff + missing observation + repeated MET never gates"
make_fixture met-force-review-missing-observation
seed_ledger_met
cat > .loop/docs/acceptance-checklist.md <<'EOF'
# Acceptance Checklist

| AC | REQ | Expectation | Method | Status | Evidence |
|---|---|---|---|---|---|
| AC-001 | REQ-001 | the page visibly renders | run | verified | .loop/observations/missing.png |
EOF
git add -A && git commit -q -m "review-on missing observation postmortem"
./loop.sh approve >/dev/null
run_loop "CONTINUE_FIX,NO_DIFF,NO_DIFF" "APPROVE" "MET"
check "postmortem stays non-success" met-force-review-missing-observation 4 "$RC"
if grep -q 'FORCED_GATE_REFUSED' .loop/journal.jsonl \
   && grep -q 'missing:.loop/observations/missing.png' .loop/journal.jsonl; then
  ok "review-on preflight refused the missing observation"
else
  bad "review-on postmortem refusal missing" met-force-review-missing-observation
fi
if ! grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "no forced gate over missing evidence"; else bad "forced gate fired over missing evidence" met-force-review-missing-observation; fi

section "REVIEW_MODE=off: forced gate fires once the self-reports are clean"
make_fixture met-force-noreview-ok
printf 'REVIEW_MODE="off"\n' >> loop.config.sh
./loop.sh approve >/dev/null
# an agent that maintained its self-reports honestly but never wrote
# READY_FOR_REVIEW — exactly the case the forced gate exists for
cat > .loop/docs/requirements-ledger.md <<'EOF'
# Requirements Ledger

| REQ | Status | Evidence | Iter |
|---|---|---|---|
| REQ-001 | met | value.txt fixed | 1 |
EOF
run_loop "CONTINUE_FIX,NO_DIFF" "APPROVE" "MET"
check "exit code 0" met-force-noreview-ok 0 "$RC"
check "state SUCCESS" met-force-noreview-ok SUCCESS "$STATE"
if grep -q '"state": "FORCED_GATE"' .loop/journal.jsonl; then ok "forced gate fired with clean self-reports"; else bad "FORCED_GATE missing" met-force-noreview-ok; fi
if ! grep -q '"state": "FORCED_GATE_REFUSED"' .loop/journal.jsonl; then ok "no spurious refusal"; else bad "refusal fired despite clean self-reports" met-force-noreview-ok; fi

