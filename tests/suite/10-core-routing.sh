#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "success path (implement -> review -> evidence -> SUCCESS)"
make_fixture success
mkdir -p .loop/logs/other-task/run-old
printf 'poison from another run\n' > .loop/logs/other-task/run-old/review.json
run_loop "READY_NOW"
check "exit code 0" success 0 "$RC"
check "state SUCCESS" success SUCCESS "$STATE"
check "value fixed" success fixed "$(cat value.txt)"
if grep -q "Evidence" .loop/docs/evidence-report.md; then ok "evidence report written"; else bad "evidence report missing" success; fi
if [ -n "$(git log --format=%s | grep "loop: iter 1" || true)" ]; then ok "iteration commit exists"; else bad "no iteration commit" success; fi
if grep -q '"state": "REVIEW_APPROVE"' .loop/journal.jsonl; then ok "review gate ran"; else bad "review gate missing" success; fi
if grep -q '"state": "SUCCESS"' .loop/journal.jsonl; then ok "journal has final SUCCESS"; else bad "journal missing SUCCESS" success; fi
CERT=.loop/docs/certification.json
if [ -s "$CERT" ]; then ok "machine certification written"; else bad "certification.json missing" success; fi
task_id=$(json_scalar "$CERT" task_id)
run_id=$(json_scalar "$CERT" run_id)
check "certificate final_state" success SUCCESS "$(json_scalar "$CERT" final_state)"
check "certificate review verdict" success APPROVE "$(json_scalar "$CERT" review_verdict)"
check "certificate records the actual single-task preflight" success PASS "$(json_scalar "$CERT" preflight)"
check "single-task certificate has no worker evidence bundle" success "" "$(json_scalar "$CERT" worker_evidence_sha256)"
check "certificate task id matches live task" success "$(cat .loop/task-id)" "$task_id"
if [ -d ".loop/logs/$task_id/$run_id" ] && [ -s ".loop/logs/$task_id/$run_id/iter-1-review-gate.json" ]; then
  ok "agent logs namespaced by task/run"
else
  bad "task/run log namespace missing" success
fi
if grep -q "logs=.loop/logs/$task_id/$run_id task=$task_id" .loop/fake-evidence-prompts \
   && ! grep -q 'other-task/run-old' .loop/fake-evidence-prompts; then
  ok "evidence prompt is confined to the active task/run logs"
else
  bad "evidence prompt leaked or omitted its log namespace" success
fi
check "certificate req-verdict hash" success "$(sha256 < .loop/req-verdicts)" "$(json_scalar "$CERT" requirements_verdict_sha256)"
check "certificate verify-log hash" success "$(sha256 < .loop/last-verify.log)" "$(json_scalar "$CERT" verify_log_sha256)"
if [ -f .loop/observations-manifest.jsonl ]; then manifest_actual=$(sha256 < .loop/observations-manifest.jsonl); else manifest_actual=$(printf '' | sha256); fi
check "certificate evidence-manifest hash" success "$manifest_actual" "$(json_scalar "$CERT" evidence_manifest_sha256)"
if grep -q 'machine record: .loop/docs/certification.json' .loop/docs/evidence-report.md; then ok "evidence report displays the machine certificate"; else bad "certificate view missing from evidence report" success; fi
# a completed run has no forward loop command — the only next move is a new task
if grep -q 'To start another task' "$WORK/last-run.out" && grep -q './loop.sh start' "$WORK/last-run.out"; then
  ok "SUCCESS points at ./loop.sh start for a new task"
else
  bad "SUCCESS missing the 'start another task' hint" nextcmd
fi

section "log namespace rejects relative-path task/run identifiers"
make_fixture log-id-boundary
printf '..\n' > .loop/task-id
run_loop "READY_NOW"
check "corrupt task id is replaced" log-id-boundary SUCCESS "$STATE"
log_tid=$(json_scalar .loop/docs/certification.json task_id)
log_rid=$(json_scalar .loop/docs/certification.json run_id)
if [ "$log_tid" != ".." ] && [ -s ".loop/logs/$log_tid/$log_rid/iter-1.json" ]; then
  ok "task logs stayed in a generated task/run namespace"
else
  bad "relative task id reached the log/certificate namespace" log-id-boundary
fi

make_fixture log-runid-boundary
run_loop "DECLARE_BLOCKED"
sed -E 's/^RUN_ID=.*/RUN_ID=../' .loop/run-checkpoint > .loop/run-checkpoint.tmp \
  && mv .loop/run-checkpoint.tmp .loop/run-checkpoint
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh resume >"$WORK/log-runid-boundary.out" 2>&1 </dev/null || RC=$?
check "resume with corrupt run id still verifies" log-runid-boundary 0 "$RC"
if [ "$(json_scalar .loop/docs/certification.json run_id)" != ".." ]; then ok "corrupt checkpoint run id was not used as a path segment"; else bad "relative run id reached certificate/log paths" log-runid-boundary; fi

section "HTML authoring is rubric-gated by default (trivial run -> skipped + journaled)"
# the success run above had no LOOP_HTML override -> html=auto -> the skill's
# rubric decides; a trivial one-REQ one-iteration run authors nothing, and the
# declaration is journaled so the decision is auditable.
if [ ! -f .loop/reports/evidence.html ]; then ok "no HTML authored for a trivial run (rubric)"; else bad "HTML authored for a trivial run" html; fi
if grep -q '"state": "HTML_SKIPPED"' .loop/journal.jsonl; then ok "skip decision journaled as HTML_SKIPPED"; else bad "HTML_SKIPPED missing from journal" html; fi

section "model routing per role"
if grep -q 'fake-imp' .loop/fake-models && grep -q 'fake-rev' .loop/fake-models \
   && grep -q 'fake-evi' .loop/fake-models; then
  ok "implement/review/evidence models routed from loop.models.sh"
else
  bad "model routing broken: $(sort -u .loop/fake-models | tr '\n' ' ')" models
fi

section "reasoning effort (LOOP_EFFORT) reaches every in-loop claude call"
# the fixture sets LOOP_EFFORT="xhigh"; the code default when unset is empty, so
# seeing xhigh on a call proves it was read from loop.models.sh and passed as
# --effort. Every recorded line must be xhigh (no call slipped through unset).
if [ -s .loop/fake-effort ] && [ "$(sort -u .loop/fake-effort)" = "xhigh" ]; then
  ok "--effort xhigh routed to all in-loop calls"
else
  bad "effort routing broken: $(sort -u .loop/fake-effort 2>/dev/null | tr '\n' ' ')" effort
fi

section "LOOP_EFFORT is read from the file and validated (not hardcoded)"
# append-and-check: get_model takes the LAST matching line, so appending a fresh
# value overrides. Proves the resolved effort tracks the file (a non-xhigh value
# routes) and that the whitelist drops a bogus value to the CLI default.
# (Capture status into a var + case-match: piping into `grep -q` would SIGPIPE
#  the status process and, under pipefail, mark the whole pipeline failed.)
printf 'LOOP_EFFORT="high"\n' >> loop.models.sh
eff_out=$(./loop.sh status 2>/dev/null || true)
case "$eff_out" in
  *"effort:"*high*) ok "a configured effort (high) is read from loop.models.sh" ;;
  *) bad "configured effort not reflected: $(printf '%s\n' "$eff_out" | grep -i effort)" effort ;;
esac
printf 'LOOP_EFFORT="bogus"\n' >> loop.models.sh
eff_out=$(./loop.sh status 2>/dev/null || true)
case "$eff_out" in
  *"effort:"*cli-default*) ok "an unrecognized effort is dropped (falls back to cli-default)" ;;
  *) bad "bogus effort not rejected: $(printf '%s\n' "$eff_out" | grep -i effort)" effort ;;
esac

section "interim review model tiering (MODEL_REVIEW_INTERIM)"
make_fixture revint
printf 'MODEL_REVIEW_INTERIM="fake-rev-int"\n' >> loop.models.sh
run_loop "CONTINUE_FIX,READY_NOW"
check "exit 0" revint 0 "$RC"
# iter 1 (CONTINUE) got an interim review on the tiered model; the success gate
# still ran on MODEL_REVIEW — grep -x separates 'fake-rev' from 'fake-rev-int'
if grep -qx 'fake-rev-int' .loop/fake-models; then ok "interim review routed to MODEL_REVIEW_INTERIM"; else bad "interim tier not used: $(sort -u .loop/fake-models | tr '\n' ' ')" revint; fi
if grep -qx 'fake-rev' .loop/fake-models; then ok "gate review stayed on MODEL_REVIEW"; else bad "gate review lost MODEL_REVIEW" revint; fi

section "MODEL_REVIEW_INTERIM unset -> interim reviews inherit MODEL_REVIEW"
make_fixture revint0
run_loop "CONTINUE_FIX,READY_NOW"
check "exit 0" revint0 0 "$RC"
if ! grep -q 'fake-rev-int' .loop/fake-models && grep -qx 'fake-rev' .loop/fake-models; then ok "no tiering without the knob (backcompat)"; else bad "unexpected interim model: $(sort -u .loop/fake-models | tr '\n' ' ')" revint0; fi

section "per-role effort overrides (EFFORT_* beats LOOP_EFFORT; empty inherits)"
make_fixture roleeff
printf 'EFFORT_STOP_EVAL="low"\nEFFORT_REVIEW="medium"\n' >> loop.models.sh
run_loop "CONTINUE_FIX,READY_NOW"
check "exit 0" roleeff 0 "$RC"
# correlate call order: fake-models and fake-effort are parallel per-call logs
paste -d' ' .loop/fake-models .loop/fake-effort > "$WORK/roleeff.calls" 2>/dev/null || true
if grep -q '^fake-stop low$' "$WORK/roleeff.calls"; then ok "EFFORT_STOP_EVAL=low reached the stop-eval call"; else bad "stop-eval effort wrong: $(grep fake-stop "$WORK/roleeff.calls")" roleeff; fi
if grep -q '^fake-rev medium$' "$WORK/roleeff.calls"; then ok "EFFORT_REVIEW=medium reached the review calls"; else bad "review effort wrong: $(grep fake-rev "$WORK/roleeff.calls")" roleeff; fi
if grep -q '^fake-imp xhigh$' "$WORK/roleeff.calls"; then ok "implement inherits the global LOOP_EFFORT"; else bad "implement effort wrong: $(grep fake-imp "$WORK/roleeff.calls")" roleeff; fi

section "bogus role effort falls back to LOOP_EFFORT"
make_fixture roleeffbad
printf 'EFFORT_STOP_EVAL="bogus"\n' >> loop.models.sh
run_loop "CONTINUE_FIX,READY_NOW"
check "exit 0" roleeffbad 0 "$RC"
paste -d' ' .loop/fake-models .loop/fake-effort > "$WORK/roleeffbad.calls" 2>/dev/null || true
if grep -q '^fake-stop xhigh$' "$WORK/roleeffbad.calls"; then ok "invalid override degraded to the global effort"; else bad "bogus override leaked: $(grep fake-stop "$WORK/roleeffbad.calls")" roleeffbad; fi

section "Codex-only effort tiers down-map for Claude roles (ultra->max, minimal->low)"
make_fixture roleeffmap
printf 'EFFORT_IMPLEMENT="ultra"\nEFFORT_REVIEW="minimal"\n' >> loop.models.sh
run_loop "CONTINUE_FIX,READY_NOW"
check "exit 0" roleeffmap 0 "$RC"
paste -d' ' .loop/fake-models .loop/fake-effort > "$WORK/roleeffmap.calls" 2>/dev/null || true
if grep -q '^fake-imp max$' "$WORK/roleeffmap.calls"; then ok "ultra down-mapped to --effort max for the Claude implement call"; else bad "ultra not down-mapped: $(grep fake-imp "$WORK/roleeffmap.calls")" roleeffmap; fi
if grep -q '^fake-rev low$' "$WORK/roleeffmap.calls"; then ok "minimal down-mapped to --effort low for Claude review calls"; else bad "minimal not down-mapped: $(grep fake-rev "$WORK/roleeffmap.calls")" roleeffmap; fi

section "Codex routing is lazy: a pure-Claude run starts no Codex process"
if [ ! -e .loop/fake-codex-invocations ]; then
  ok "no Codex help/auth/exec process was started"
else
  bad "pure-Claude run invoked Codex: $(tr '\n' ' ' < .loop/fake-codex-invocations)" codex-lazy
fi

section "Codex IMPLEMENT routing: argv, envelope, logs, and cost accounting"
make_fixture codex-implement
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
run_loop "READY_NOW"
check "exit 0" codex-implement 0 "$RC"
check "state SUCCESS" codex-implement SUCCESS "$STATE"
if grep -q '^model=gpt-5.5 sandbox=workspace-write approval=never ' .loop/fake-codex-args \
   && grep -q 'sandbox_workspace_write.network_access=true' .loop/fake-codex-args \
   && grep -q 'model_reasoning_effort=xhigh' .loop/fake-codex-args \
   && ! grep -q 'project_doc_max_bytes=0' .loop/fake-codex-args; then
  ok "IMPLEMENT reached Codex with model, writable sandbox, network, and project instructions enabled"
else
  bad "Codex IMPLEMENT argv wrong: $(cat .loop/fake-codex-args 2>/dev/null | tr '\n' ' ')" codex-implement
fi
if grep -q '^--ask-for-approval never exec --json ' .loop/fake-codex-invocations; then
  ok "approval policy is a global option before exec"
else
  bad "Codex exec argv order wrong: $(cat .loop/fake-codex-invocations 2>/dev/null | tr '\n' ' ')" codex-implement
fi
if grep -q '\.agents/skills/loop-iterate/SKILL.md' .loop/fake-codex-prompts \
   && ! grep -q '\.claude/skills/loop-iterate/SKILL.md' .loop/fake-codex-prompts; then
  ok "skill shorthand was expanded to the Codex-native direct-file prompt"
else
  bad "Codex prompt wrapper missing: $(cat .loop/fake-codex-prompts 2>/dev/null)" codex-implement
fi
if grep -qx 'fake-rev' .loop/fake-models && grep -qx 'fake-evi' .loop/fake-models \
   && ! grep -q 'gpt-5.5' .loop/fake-models; then
  ok "Claude review/evidence routing stayed separate from Codex telemetry"
else
  bad "Claude/Codex routing logs crossed: $(sort -u .loop/fake-models 2>/dev/null | tr '\n' ' ')" codex-implement
fi
check "Codex exec capability probe ran once" codex-implement 1 "$(grep -xc 'exec --help' .loop/fake-codex-invocations || true)"
check "Codex global capability probe ran once" codex-implement 1 "$(grep -xc -- '--help' .loop/fake-codex-invocations || true)"
check "Codex login help probe ran once" codex-implement 1 "$(grep -xc 'login --help' .loop/fake-codex-invocations || true)"
check "Codex advisory auth probe ran once" codex-implement 1 "$(grep -xc 'login status' .loop/fake-codex-invocations || true)"
codex_tid=$(json_scalar .loop/docs/certification.json task_id)
codex_rid=$(json_scalar .loop/docs/certification.json run_id)
codex_logdir=".loop/logs/$codex_tid/$codex_rid"
if [ -s "$codex_logdir/iter-1.codex.jsonl" ] && [ -s "$codex_logdir/iter-1.msg" ]; then
  ok "raw Codex JSONL and last-message sidecars retained in the run namespace"
else
  bad "Codex sidecars missing from $codex_logdir" codex-envelope
fi
if grep -q '"total_cost_usd": 0' "$codex_logdir/iter-1.json" \
   && grep -q '"session_id": "fake-codex-' "$codex_logdir/iter-1.json" \
   && grep -q '"num_turns": 1' "$codex_logdir/iter-1.json" \
   && grep -q '"is_error": false' "$codex_logdir/iter-1.json"; then
  ok "Codex JSONL normalized into the existing Claude-compatible envelope"
else
  bad "normalized Codex envelope wrong: $(cat "$codex_logdir/iter-1.json" 2>/dev/null)" codex-envelope
fi
if grep '"iteration": "1"' .loop/journal.jsonl | grep -q '"cost_usd": 0'; then
  ok "Codex iteration journaled zero USD cost"
else
  bad "Codex iteration did not journal zero cost" codex-envelope
fi
if grep -q '"state": "CODEX_COST_UNTRACKED"' .loop/journal.jsonl; then
  ok "USD-cap degradation is explicitly journaled"
else
  bad "CODEX_COST_UNTRACKED audit row missing" codex-cost
fi

section "Codex JSONL normalization is independent of object key order"
make_fixture codex-envelope-reordered
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_FAKE_CODEX=REORDER LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-envelope-reordered.out" 2>&1 </dev/null || RC=$?
check "exit 0 with reordered event keys" codex-envelope-reordered 0 "$RC"
tid=$(json_scalar .loop/docs/certification.json task_id)
rid=$(json_scalar .loop/docs/certification.json run_id)
reordered_envelope=".loop/logs/$tid/$rid/iter-1.json"
if grep -q '"session_id": "fake-codex-' "$reordered_envelope" \
   && grep -q '"is_error": false' "$reordered_envelope"; then
  ok "reordered thread/item events normalized into the compatibility envelope"
else
  bad "reordered JSONL was not normalized: $(cat "$reordered_envelope" 2>/dev/null)" codex-envelope-reordered
fi

section "a Codex-routed CONTRACT alone still voids the USD cap's coverage claim"
make_fixture codex-contract-cost
printf 'AGENT_CONTRACT="codex"\nMODEL_CONTRACT="gpt-5.5"\n' >> loop.models.sh
run_loop "READY_NOW"
check "exit 0 (contract already defined; in-run roles stay Claude)" codex-contract-cost 0 "$RC"
if grep -q '"state": "CODEX_COST_UNTRACKED"' .loop/journal.jsonl \
   && grep -q 'MAX_COST_USD cannot bound Codex calls' "$WORK/last-run.out"; then
  ok "CONTRACT-only Codex routing triggers the cap warning"
else
  bad "CONTRACT-only routing did not warn" codex-contract-cost
fi

section "Codex reader routing forces read-only and suppresses network widening"
make_fixture codex-reader
printf 'AGENT_REVIEW="codex"\nMODEL_REVIEW="gpt-5.5-review"\n' >> loop.models.sh
run_loop "READY_NOW"
check "exit 0" codex-reader 0 "$RC"
if [ -s .loop/fake-codex-args ] \
   && [ "$(grep -c 'sandbox=read-only' .loop/fake-codex-args || true)" = "$(wc -l < .loop/fake-codex-args | tr -d ' ')" ] \
   && [ "$(grep -c 'project_doc_max_bytes=0' .loop/fake-codex-args || true)" = "$(wc -l < .loop/fake-codex-args | tr -d ' ')" ] \
   && ! grep -q 'sandbox_workspace_write.network_access=true' .loop/fake-codex-args; then
  ok "reviewer Codex calls are read-only, ignore project AGENTS instructions, and have no network override"
else
  bad "Codex reader mapping wrong: $(cat .loop/fake-codex-args 2>/dev/null | tr '\n' ' ')" codex-reader
fi
if grep -q 'loop-review/SKILL.md' .loop/fake-codex-prompts; then ok "review prompt routed to Codex"; else bad "review prompt did not route to Codex" codex-reader; fi

section "interim-review Codex override survives its format retry, then is consumed"
make_fixture codex-interim
printf 'AGENT_REVIEW_INTERIM="codex"\nMODEL_REVIEW_INTERIM="gpt-5.5-review"\n' >> loop.models.sh
run_loop "CONTINUE_FIX,READY_NOW" "NOVERDICT,APPROVE,APPROVE"
check "exit 0" codex-interim 0 "$RC"
check "both interim attempts used Codex" codex-interim 2 "$(wc -l < .loop/fake-codex-args | tr -d ' ')"
check "format-reminder retry stayed on Codex" codex-interim 1 "$(grep -c 'FORMAT REMINDER' .loop/fake-codex-prompts || true)"
if grep -qx 'fake-rev' .loop/fake-models; then ok "success-gate review returned to Claude"; else bad "one-shot Codex routing leaked into the success gate" codex-interim; fi

section "Codex network-off, max-effort mapping, and advisory auth probe"
make_fixture codex-network-off
printf 'LOOP_CODEX_NETWORK=0\n' >> loop.config.sh
./loop.sh approve >/dev/null
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\nLOOP_EFFORT="max"\n' >> loop.models.sh
RC=0
LOOP_FAKE_CODEX=NOAUTH LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-network-off.out" 2>&1 </dev/null || RC=$?
check "exit 0 despite advisory login-status failure" codex-network-off 0 "$RC"
if grep -q 'model_reasoning_effort=xhigh' .loop/fake-codex-args \
   && ! grep -q 'sandbox_workspace_write.network_access=true' .loop/fake-codex-args; then
  ok "max effort mapped to xhigh and LOOP_CODEX_NETWORK=0 emitted no network config"
else
  bad "Codex network/effort mapping wrong: $(cat .loop/fake-codex-args 2>/dev/null | tr '\n' ' ')" codex-network-off
fi
if grep -q 'codex login status failed' "$WORK/codex-network-off.out"; then
  ok "failed login-status probe warns but defers authority to exec"
else
  bad "advisory Codex auth warning missing" codex-network-off
fi

section "Codex ultra effort passes through on gpt-5.6-sol, clamps to xhigh elsewhere"
make_fixture codex-ultra-effort
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.6-sol"\nLOOP_EFFORT="ultra"\n' >> loop.models.sh
run_loop "READY_NOW"
check "exit 0" codex-ultra-effort 0 "$RC"
if grep -q '^model=gpt-5.6-sol ' .loop/fake-codex-args \
   && grep -q 'model_reasoning_effort=ultra' .loop/fake-codex-args \
   && ! grep -q 'model_reasoning_effort=xhigh' .loop/fake-codex-args; then
  ok "ultra effort passed through verbatim to a gpt-5.6-sol Codex call"
else
  bad "Codex ultra pass-through wrong: $(cat .loop/fake-codex-args 2>/dev/null | tr '\n' ' ')" codex-ultra-effort
fi

make_fixture codex-ultra-clamp
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\nLOOP_EFFORT="ultra"\n' >> loop.models.sh
run_loop "READY_NOW"
check "exit 0" codex-ultra-clamp 0 "$RC"
if grep -q 'model_reasoning_effort=xhigh' .loop/fake-codex-args \
   && ! grep -q 'model_reasoning_effort=ultra' .loop/fake-codex-args; then
  ok "ultra effort clamped to xhigh on a Codex model that caps below it (gpt-5.5)"
else
  bad "Codex ultra clamp wrong: $(cat .loop/fake-codex-args 2>/dev/null | tr '\n' ' ')" codex-ultra-clamp
fi

section "Codex danger-full-access is accepted without workspace network widening"
make_fixture codex-danger
printf 'LOOP_CODEX_SANDBOX="danger-full-access"\n' >> loop.config.sh
./loop.sh approve >/dev/null
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
run_loop "READY_NOW"
check "exit 0" codex-danger 0 "$RC"
if grep -q '^model=gpt-5.5 sandbox=danger-full-access approval=never ' .loop/fake-codex-args \
   && ! grep -q 'sandbox_workspace_write.network_access=true' .loop/fake-codex-args; then
  ok "danger-full-access maps directly and never receives the workspace-only network knob"
else
  bad "Codex danger-full-access mapping wrong: $(cat .loop/fake-codex-args 2>/dev/null | tr '\n' ' ')" codex-danger
fi

section "per-role Codex effort reaches STOP_EVAL as a reader"
make_fixture codex-stop-effort
printf 'AGENT_STOP_EVAL="codex"\nMODEL_STOP_EVAL="gpt-5.5-mini"\nEFFORT_STOP_EVAL="low"\n' >> loop.models.sh
run_loop "CONTINUE_FIX,READY_NOW"
check "exit 0" codex-stop-effort 0 "$RC"
if grep -q '^model=gpt-5.5-mini sandbox=read-only approval=never ' .loop/fake-codex-args \
   && grep -q 'model_reasoning_effort=low' .loop/fake-codex-args \
   && grep -q 'project_doc_max_bytes=0' .loop/fake-codex-args \
   && grep -q 'loop-stop-eval/SKILL.md' .loop/fake-codex-prompts; then
  ok "STOP_EVAL used low effort in a read-only Codex call with project instructions disabled"
else
  bad "Codex STOP_EVAL argv wrong: $(cat .loop/fake-codex-args 2>/dev/null | tr '\n' ' ')" codex-stop-effort
fi

section "Codex guards fail closed with canonical recovery commands"
make_fixture codex-missing
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_CODEX_CMD="$WORK/no-such-codex" LOOP_CLAUDE_CMD="$FAKE" \
  ./loop.sh run >"$WORK/codex-missing.out" 2>&1 </dev/null || RC=$?
check "missing Codex exits 2" codex-missing 2 "$RC"
if grep -q 'codex CLI not found' "$WORK/codex-missing.out" && grep -q '→ next:' "$WORK/codex-missing.out"; then ok "missing CLI names its recovery"; else bad "missing-CLI recovery absent" codex-missing; fi

make_fixture codex-old
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_FAKE_CODEX=OLD LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/codex-old.out" 2>&1 </dev/null || RC=$?
check "old Codex exits 2" codex-old 2 "$RC"
if grep -q 'codex CLI too old' "$WORK/codex-old.out" && grep -q '→ next:' "$WORK/codex-old.out" \
   && [ ! -e .loop/fake-codex-args ]; then ok "capability probe failed before exec with recovery"; else bad "old-CLI guard did not fail pre-exec" codex-old; fi

make_fixture codex-model-alias
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="opus"\n' >> loop.models.sh
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/codex-model-alias.out" 2>&1 </dev/null || RC=$?
check "Claude alias on Codex exits 2" codex-model-alias 2 "$RC"
if grep -q "MODEL_IMPLEMENT='opus' is a Claude alias" "$WORK/codex-model-alias.out" \
   && grep -q '→ next:' "$WORK/codex-model-alias.out" && [ ! -e .loop/fake-codex-args ]; then
  ok "model/agent mismatch failed before exec with recovery"
else
  bad "Codex model-alias guard missing" codex-model-alias
fi

make_fixture codex-config-sandbox
printf 'LOOP_CODEX_SANDBOX=invalid\n' >> loop.config.sh
./loop.sh approve >/dev/null
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/codex-config-sandbox.out" 2>&1 </dev/null || RC=$?
check "invalid LOOP_CODEX_SANDBOX exits 2" codex-config-sandbox 2 "$RC"
if grep -q 'LOOP_CODEX_SANDBOX must be' "$WORK/codex-config-sandbox.out" && grep -q '→ next:' "$WORK/codex-config-sandbox.out"; then ok "sandbox enum fails closed"; else bad "sandbox enum guard missing" codex-config-sandbox; fi

make_fixture codex-config-network
printf 'LOOP_CODEX_NETWORK=2\n' >> loop.config.sh
./loop.sh approve >/dev/null
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/codex-config-network.out" 2>&1 </dev/null || RC=$?
check "invalid LOOP_CODEX_NETWORK exits 2" codex-config-network 2 "$RC"
if grep -q 'LOOP_CODEX_NETWORK must be 0 or 1' "$WORK/codex-config-network.out" && grep -q '→ next:' "$WORK/codex-config-network.out"; then ok "network enum fails closed"; else bad "network enum guard missing" codex-config-network; fi

make_fixture codex-skill-missing
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
rm -f .agents/skills/loop-iterate/SKILL.md
./loop.sh approve >/dev/null
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/codex-skill-missing.out" 2>&1 </dev/null || RC=$?
check "missing projected Codex skill exits 2" codex-skill-missing 2 "$RC"
if grep -q '\.agents/skills/loop-iterate/SKILL.md' "$WORK/codex-skill-missing.out" \
   && grep -q '→ next:' "$WORK/codex-skill-missing.out" \
   && [ ! -e .loop/fake-codex-args ]; then
  ok "missing Codex skill fails before exec and names a recovery"
else
  bad "missing-skill guard absent or late: $(tail -4 "$WORK/codex-skill-missing.out")" codex-skill-missing
fi

section "unknown AGENT value degrades to Claude"
make_fixture codex-agent-typo
printf 'AGENT_IMPLEMENT="codexx"\n' >> loop.models.sh
run_loop "READY_NOW"
check "agent typo still completes" codex-agent-typo 0 "$RC"
if grep -qx 'fake-imp' .loop/fake-models && [ ! -e .loop/fake-codex-invocations ]; then ok "unknown agent value degraded to Claude"; else bad "agent typo did not degrade safely" codex-agent-typo; fi
if grep -q "AGENT_IMPLEMENT='codexx' is not recognized — routing to claude" "$WORK/last-run.out"; then
  ok "typo degrade is announced at preflight"
else
  bad "silent AGENT typo degrade (no preflight note)" codex-agent-typo
fi
check "typo note printed once per process" codex-agent-typo 1 "$(grep -c "is not recognized — routing to claude" "$WORK/last-run.out" || true)"

section "refine without the Claude CLI names the manual sign-off path"
make_fixture refine-noclaude
RC=0
LOOP_CLAUDE_CMD="$WORK/no-such-claude" ./loop.sh refine >"$WORK/refine-noclaude.out" 2>&1 </dev/null || RC=$?
check "exit 2" refine-noclaude 2 "$RC"
if grep -q "acceptance-checklist.md" "$WORK/refine-noclaude.out" \
   && grep -q './loop.sh signoff' "$WORK/refine-noclaude.out" \
   && grep -q './loop.sh resume' "$WORK/refine-noclaude.out" \
   && grep -q '→ next:' "$WORK/refine-noclaude.out"; then
  ok "claude-less refine recovery names ./loop.sh signoff and the manual sign-off path"
else
  bad "refine recovery missing: $(cat "$WORK/refine-noclaude.out")" refine-noclaude
fi

section "AGENT_CONTRACT routes the HEADLESS definition to Codex (interactive stays Claude)"
make_fixture codex-contract-route nocontract
printf 'AGENT_CONTRACT="codex"\nMODEL_CONTRACT="gpt-5.5"\n' >> loop.models.sh
RC=0
LOOP_FAKE_CONTRACT=READY LOOP_CLAUDE_CMD="$WORK/no-such-claude" \
  ./loop.sh start "fix value.txt so the check passes" >"$WORK/codex-contract-route.out" 2>&1 </dev/null || RC=$?
check "headless Codex contract generation exits 0" codex-contract-route 0 "$RC"
if grep -q 'loop-contract/SKILL.md' .loop/fake-codex-prompts && [ ! -e .loop/fake-models ]; then
  ok "the definition was authored on Codex with no Claude process at all"
else
  bad "Codex-routed contract generation failed: $(tail -3 "$WORK/codex-contract-route.out")" codex-contract-route
fi
./loop.sh approve >"$WORK/codex-contract-route-approve.out" 2>&1
if grep -q 'CONTRACT -> codex/gpt-5.5' "$WORK/codex-contract-route-approve.out" \
   && grep -q 'interactive ./loop.sh start and refine still launch Claude' "$WORK/codex-contract-route-approve.out"; then
  ok "approval shows the Codex CONTRACT route and the interactive-Claude note"
else
  bad "CONTRACT routing display wrong: $(grep -i 'contract' "$WORK/codex-contract-route-approve.out" | head -3)" codex-contract-route
fi

make_fixture codex-contract-alias nocontract
printf 'AGENT_CONTRACT="codex"\nMODEL_CONTRACT="opus"\n' >> loop.models.sh
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh start "fix value.txt so the check passes" >"$WORK/codex-contract-alias.out" 2>&1 </dev/null || RC=$?
check "Claude alias on Codex CONTRACT exits 2" codex-contract-alias 2 "$RC"
if grep -q "MODEL_CONTRACT='opus' is a Claude alias" "$WORK/codex-contract-alias.out" \
   && grep -q '→ next:' "$WORK/codex-contract-alias.out" && [ ! -e .loop/fake-codex-prompts ]; then
  ok "contract model/agent mismatch failed before generation with recovery"
else
  bad "CONTRACT alias guard missing" codex-contract-alias
fi

section "inherited/unset alias diagnostics name the key the user actually wrote"
make_fixture codex-alias-inherit
printf 'AGENT_REVIEW="codex"\nMODEL_REVIEW="gpt-5.5-review"\nMODEL_REVIEW_INTERIM="sonnet"\n' >> loop.models.sh
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/codex-alias-inherit.out" 2>&1 </dev/null || RC=$?
check "inherited interim alias exits 2" codex-alias-inherit 2 "$RC"
if grep -q "AGENT_REVIEW=codex (inherited by REVIEW_INTERIM) but MODEL_REVIEW_INTERIM='sonnet' is a Claude alias" "$WORK/codex-alias-inherit.out" \
   && grep -q '→ next:' "$WORK/codex-alias-inherit.out"; then
  ok "diagnostic blames AGENT_REVIEW inheritance, not a key the user never set"
else
  bad "inherited-alias diagnostic wrong: $(grep -i alias "$WORK/codex-alias-inherit.out" | head -2)" codex-alias-inherit
fi

make_fixture codex-alias-unset
printf 'AGENT_DECOMPOSE="codex"\n' >> loop.models.sh
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/codex-alias-unset.out" 2>&1 </dev/null || RC=$?
check "unset model on a Codex role exits 2" codex-alias-unset 2 "$RC"
if grep -q "MODEL_DECOMPOSE is unset (defaults to 'opus', a Claude alias)" "$WORK/codex-alias-unset.out" \
   && grep -q '→ next:' "$WORK/codex-alias-unset.out"; then
  ok "diagnostic explains the aliased default instead of quoting a phantom line"
else
  bad "unset-model diagnostic wrong: $(grep -i alias "$WORK/codex-alias-unset.out" | head -2)" codex-alias-unset
fi

section "approve warns on a read-only sandbox with Codex authoring roles; status shows routing"
make_fixture codex-readonly-warn
printf 'LOOP_CODEX_SANDBOX="read-only"\n' >> loop.config.sh
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
./loop.sh approve >"$WORK/codex-readonly-warn.out" 2>&1
if grep -q 'LOOP_CODEX_SANDBOX=read-only — Codex-routed authoring roles (IMPLEMENT) cannot write' "$WORK/codex-readonly-warn.out"; then
  ok "approval flags the write-less authoring configuration"
else
  bad "read-only sandbox warning missing" codex-readonly-warn
fi
out=$(./loop.sh status 2>&1) || true
if printf '%s\n' "$out" | grep -q 'agents:   codex -> implement (all other roles claude)'; then
  ok "status names the Codex-routed roles"
else
  bad "status agents line wrong: $(printf '%s\n' "$out" | grep agents || echo missing)" codex-readonly-warn
fi

section "DISALLOWED_TOOLS warning distinguishes Claude and Codex controls"
make_fixture codex-disallowed
printf 'DISALLOWED_TOOLS="Bash"\n' >> loop.config.sh
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
./loop.sh approve >"$WORK/codex-disallowed.out" 2>&1
if grep -q 'DISALLOWED_TOOLS constrains Claude only' "$WORK/codex-disallowed.out" \
   && grep -q 'IMPLEMENT -> codex/gpt-5.5' "$WORK/codex-disallowed.out"; then
  ok "approval prints the Codex control-surface warning and routing table"
else
  bad "Codex DISALLOWED_TOOLS warning/routing missing" codex-disallowed
fi

section "all-Codex routing runs a single loop with NO claude CLI at all"
make_fixture codex-only
cat >> loop.models.sh <<'EOF'
AGENT_IMPLEMENT="codex"
AGENT_PLAN="codex"
AGENT_REVIEW="codex"
AGENT_STOP_EVAL="codex"
AGENT_EVIDENCE="codex"
AGENT_DECOMPOSE="codex"
AGENT_SUPERVISE="codex"
MODEL_IMPLEMENT="gpt-5.5"
MODEL_PLAN="gpt-5.5"
MODEL_REVIEW="gpt-5.5-review"
MODEL_REVIEW_INTERIM="gpt-5.5-review"
MODEL_STOP_EVAL="gpt-5.5-mini"
MODEL_EVIDENCE="gpt-5.5"
MODEL_DECOMPOSE="gpt-5.5"
MODEL_SUPERVISE="gpt-5.5"
EOF
RC=0
LOOP_CLAUDE_CMD="$WORK/no-such-claude" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/codex-only.out" 2>&1 </dev/null || RC=$?
check "exit 0 without any claude CLI" codex-only 0 "$RC"
check "state SUCCESS" codex-only SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
if [ ! -e .loop/fake-models ] && [ -s .loop/fake-codex-args ]; then
  ok "every routable role ran on Codex; no Claude process was ever started"
else
  bad "claude was invoked in an all-Codex run: $(cat .loop/fake-models 2>/dev/null | tr '\n' ' ')" codex-only
fi

section "all-Codex orchestration still fails closed on the Claude-routed CONTRACT"
make_fixture codex-only-orch
cat >> loop.models.sh <<'EOF'
AGENT_IMPLEMENT="codex"
AGENT_PLAN="codex"
AGENT_REVIEW="codex"
AGENT_STOP_EVAL="codex"
AGENT_EVIDENCE="codex"
AGENT_DECOMPOSE="codex"
AGENT_SUPERVISE="codex"
MODEL_IMPLEMENT="gpt-5.5"
MODEL_PLAN="gpt-5.5"
MODEL_REVIEW="gpt-5.5-review"
MODEL_REVIEW_INTERIM="gpt-5.5-review"
MODEL_STOP_EVAL="gpt-5.5-mini"
MODEL_EVIDENCE="gpt-5.5"
MODEL_DECOMPOSE="gpt-5.5"
MODEL_SUPERVISE="gpt-5.5"
EOF
printf 'FLEET_DECOMPOSE=1\n' >> fleet.config.sh
RC=0
LOOP_CLAUDE_CMD="$WORK/no-such-claude" ./loop.sh run >"$WORK/codex-only-orch.out" 2>&1 </dev/null || RC=$?
check "orchestration without claude exits 2" codex-only-orch 2 "$RC"
if grep -q 'fleet orchestration requires the Claude CLI' "$WORK/codex-only-orch.out" \
   && grep -q 'run --single' "$WORK/codex-only-orch.out" \
   && grep -q '→ next:' "$WORK/codex-only-orch.out" \
   && [ ! -e .loop/fake-codex-prompts ]; then
  ok "guard fired before any decompose call was spent, naming the recovery"
else
  bad "orchestration Claude guard missing or late: $(tail -3 "$WORK/codex-only-orch.out")" codex-only-orch
fi

section "fully-Codex pipeline: auto -> contract -> review -> approve -> run, Claude-less"
make_fixture codex-only-auto nocontract
cat >> loop.models.sh <<'EOF'
AGENT_CONTRACT="codex"
AGENT_IMPLEMENT="codex"
AGENT_PLAN="codex"
AGENT_REVIEW="codex"
AGENT_STOP_EVAL="codex"
AGENT_EVIDENCE="codex"
AGENT_DECOMPOSE="codex"
AGENT_SUPERVISE="codex"
MODEL_CONTRACT="gpt-5.5"
MODEL_IMPLEMENT="gpt-5.5"
MODEL_PLAN="gpt-5.5"
MODEL_REVIEW="gpt-5.5-review"
MODEL_REVIEW_INTERIM="gpt-5.5-review"
MODEL_STOP_EVAL="gpt-5.5-mini"
MODEL_EVIDENCE="gpt-5.5"
MODEL_DECOMPOSE="gpt-5.5"
MODEL_SUPERVISE="gpt-5.5"
EOF
echo "fix value.txt so the check passes" > loop-instruction.md
RC=0
LOOP_CLAUDE_CMD="$WORK/no-such-claude" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh auto >"$WORK/codex-only-auto.out" 2>&1 </dev/null || RC=$?
STATE=$(cat .loop/state 2>/dev/null || echo none)
check "exit 0" codex-only-auto 0 "$RC"
check "state SUCCESS" codex-only-auto SUCCESS "$STATE"
if [ ! -e .loop/fake-models ] \
   && grep -q 'loop-contract/SKILL.md' .loop/fake-codex-prompts \
   && grep -q 'loop-contract-review/SKILL.md' .loop/fake-codex-prompts \
   && grep -q 'loop-iterate/SKILL.md' .loop/fake-codex-prompts \
   && grep -q 'loop-evidence/SKILL.md' .loop/fake-codex-prompts; then
  ok "contract, contract review, implement and evidence all ran on Codex; zero Claude processes"
else
  bad "Claude leaked into the Claude-less pipeline: $(cat .loop/fake-models 2>/dev/null | tr '\n' ' ')" codex-only-auto
fi

