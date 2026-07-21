#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "runaway-context nudge (TURNS_NUDGE_AT)"
make_fixture ctxnudge
printf 'TURNS_NUDGE_AT="50"\n' >> loop.models.sh
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="CONTINUE_FIX,READY_NOW" LOOP_FAKE_REVIEW=APPROVE \
  LOOP_FAKE_STOPEVAL=CONTINUE LOOP_FAKE_TURNS=75 \
  ./loop.sh run >"$WORK/ctxnudge.out" 2>&1 </dev/null || RC=$?
check "exit 0" ctxnudge 0 "$RC"
if grep -q '"state": "CONTEXT_NUDGE"' .loop/journal.jsonl; then ok "75 turns >= 50 journaled CONTEXT_NUDGE"; else bad "CONTEXT_NUDGE missing" ctxnudge; fi
if grep '"state": "CONTEXT_NUDGE"' .loop/journal.jsonl | grep -q '75 turns'; then ok "nudge reason carries the turn count"; else bad "nudge reason lacks turns" ctxnudge; fi

section "TURNS_NUDGE_AT off / zero turns -> no nudge"
make_fixture ctxnudge0
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="CONTINUE_FIX,READY_NOW" LOOP_FAKE_REVIEW=APPROVE \
  LOOP_FAKE_STOPEVAL=CONTINUE LOOP_FAKE_TURNS=75 \
  ./loop.sh run >"$WORK/ctxnudge0.out" 2>&1 </dev/null || RC=$?
check "exit 0 (knob unset)" ctxnudge0 0 "$RC"
if ! grep -q '"state": "CONTEXT_NUDGE"' .loop/journal.jsonl; then ok "no nudge without the knob (backcompat)"; else bad "nudge fired with the knob unset" ctxnudge0; fi
make_fixture ctxnudge1
printf 'TURNS_NUDGE_AT="50"\n' >> loop.models.sh
run_loop "CONTINUE_FIX,READY_NOW"
check "exit 0 (fake reports 0 turns)" ctxnudge1 0 "$RC"
if ! grep -q '"state": "CONTEXT_NUDGE"' .loop/journal.jsonl; then ok "no nudge below the threshold"; else bad "nudge fired at 0 turns" ctxnudge1; fi

section "tool restrictions really reach the model calls (recorded per role)"
# run_claude passes --tools "Read,Glob,Grep" to reader-mode sessions (reviewer,
# stop-eval: structurally read-only) and a broad --allowedTools to full sessions
# (acceptEdits mode). Tool denials are opt-in via DISALLOWED_TOOLS (--disallowedTools,
# asserted in its own fixture below); deny wins over allow. The fake records one
# "<model> <flag>=<value>" line per call in .loop/fake-tools.
if grep -q -- 'fake-rev --tools=Read,Glob,Grep' .loop/fake-tools 2>/dev/null; then
  ok "reviewer session structurally read-only (--tools Read,Glob,Grep)"
else
  bad "reviewer restriction flags missing: $(sort -u .loop/fake-tools 2>/dev/null | tr '\n' ' ')" tools-restrict
fi
# (stop-eval only runs on CONTINUE iterations — its restriction flag is
#  asserted in the two-iteration fixture below, where it actually fires)
if grep -q -- 'fake-imp .*--allowedTools=Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch' .loop/fake-tools 2>/dev/null \
   && ! grep -q -- 'fake-imp .*--disallowedTools=' .loop/fake-tools 2>/dev/null; then
  ok "worker session gets the broad allow-list (incl. network), no deny-list by default"
else
  bad "worker tool flags wrong: $(grep fake-imp .loop/fake-tools 2>/dev/null | tr '\n' ' ')" tools-restrict
fi

section "DISALLOWED_TOOLS from config reaches the worker deny-list (re-approve; spaces preserved)"
make_fixture denytools
printf 'DISALLOWED_TOOLS="WebFetch,Bash(git push *)"\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "CONTINUE_FIX,READY_NOW"
check "exit 0" denytools 0 "$RC"
if grep -q -- 'fake-imp .*--disallowedTools=WebFetch,Bash(git push ' .loop/fake-tools 2>/dev/null; then
  ok "configured DISALLOWED_TOOLS propagates to --disallowedTools as one arg"
else
  bad "DISALLOWED_TOOLS did not propagate: $(grep fake-imp .loop/fake-tools 2>/dev/null | tr '\n' ' ')" denytools
fi

section "assumption logged mid-loop keeps the loop running (no escalation)"
make_fixture assumption
if [ -f .loop/docs/unknowns.md ] && [ -f .loop/templates/unknowns.md ]; then
  ok "unknowns/assumptions templates deployed via the loop-docs glob"
else
  bad "unknowns template not deployed by init" assumption
fi
run_loop "CONTINUE_ASSUMPTION,READY_NOW"
check "exit code 0" assumption 0 "$RC"
check "state SUCCESS" assumption SUCCESS "$STATE"
if grep -q 'AS-1' .loop/docs/assumptions.md 2>/dev/null; then ok "AS-1 recorded in assumptions.md"; else bad "AS-1 missing from assumptions.md" assumption; fi
if grep -q 'NEEDS_SPEC_DECISION\|NEEDS_ARCHITECTURE_DECISION' .loop/journal.jsonl; then
  bad "assumption escalated instead of continuing" assumption
else
  ok "no escalation for the logged assumption"
fi
# capture first: piping loop.sh straight into grep -q would SIGPIPE it under pipefail
report_text=$(./loop.sh report --text 2>/dev/null || true)
if printf '%s\n' "$report_text" | grep -q 'AS-1'; then
  ok "report --text surfaces the assumption ledger"
else
  bad "report --text does not show assumptions" assumption
fi

section "assumption-log-only iterations still stall (.loop/docs writes are not progress)"
make_fixture assumption-only
run_loop "ASSUMPTION_ONLY,ASSUMPTION_ONLY,ASSUMPTION_ONLY"
check "state STALLED" assumption-only STALLED "$STATE"

section "assumptions flow: an in-scope unknown never stops a productive loop"
make_fixture assumptions-flow
run_loop "CONTINUE_ASSUME,READY_NOW"
check "exit code 0" assumptions-flow 0 "$RC"
check "state SUCCESS" assumptions-flow SUCCESS "$STATE"
if grep -q 'AS-1' .loop/docs/assumptions.md 2>/dev/null; then
  ok "AS-1 recorded while the loop continued to SUCCESS"
else
  bad "AS-1 missing from assumptions.md" assumptions-flow
fi
if [ -f .loop/docs/spec-drift-report.md ] && ! grep -q '<!-- TEMPLATE -->' .loop/docs/spec-drift-report.md; then
  ok "spec-drift report filled by the READY iteration (template marker gone)"
else
  bad "spec-drift report still template/missing" assumptions-flow
fi

section "HTML report view (LOOP_HTML=1 authors it; browser gated to interactive)"
make_fixture html-view
RC=0
LOOP_HTML=1 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/html-view.out" 2>&1 </dev/null || RC=$?
check "state SUCCESS" html-view SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
if [ -f .loop/reports/evidence.html ]; then ok "evidence.html authored with LOOP_HTML=1"; else bad "evidence.html missing" html-view; fi
if grep -q '"state": "HTML_AUTHORED"' .loop/journal.jsonl; then ok "authorship verified + journaled as HTML_AUTHORED"; else bad "HTML_AUTHORED missing" html-view; fi
# the fixture page is lint-clean AND carries markdown-looking text inside <pre>
# (raw-excerpt content) — no warning proves the lint skips raw blocks
if ! grep -q '"state": "HTML_LINT_WARN"' .loop/journal.jsonl; then ok "clean page (markdown only inside <pre>) trips no lint warning"; else bad "clean fixture page tripped the HTML lint" html-view; fi
# a browser must NEVER open without a human. Stub the opener to touch a sentinel
# (overriding the global no-op), drive report/open headlessly (stdin </dev/null ->
# [ -t 0 ] false), and assert the sentinel is untouched. The stub is an executable
# path so command -v finds it — the ONLY thing keeping it unused is the interactive gate.
SENT="$WORK/opened.sentinel"
BROWSER_STUB="$WORK/browser-stub.sh"
printf '#!/bin/sh\necho opened >> "%s"\n' "$SENT" > "$BROWSER_STUB"; chmod +x "$BROWSER_STUB"
rm -f "$SENT"
LOOP_BROWSER_CMD="$BROWSER_STUB" ./loop.sh report >"$WORK/report.out" 2>&1 </dev/null || true
if [ ! -f "$SENT" ]; then ok "report opens no browser headless"; else bad "report opened a browser headless" html-view; fi
if grep -q 'run summary' "$WORK/report.out"; then ok "report prints text surface headless"; else bad "report text surface missing" html-view; fi
if grep -q 'HTML view available' "$WORK/report.out"; then ok "report points at the HTML view"; else bad "report HTML pointer missing" html-view; fi
# ./loop.sh open is EXPLICIT: it must open even without a TTY (an agent's Bash tool
# calls have none), or the interactive mockup flow would silently do nothing. Only
# auto mode suppresses it.
rm -f "$SENT"
LOOP_BROWSER_CMD="$BROWSER_STUB" ./loop.sh open .loop/reports/evidence.html >/dev/null 2>&1 </dev/null || true
if [ -f "$SENT" ]; then ok "open launches the browser when invoked (no TTY needed)"; else bad "open did not launch when invoked" html-view; fi
rm -f "$SENT"
LOOP_AUTO=1 LOOP_BROWSER_CMD="$BROWSER_STUB" ./loop.sh open .loop/reports/evidence.html >/dev/null 2>&1 </dev/null || true
if [ ! -f "$SENT" ]; then ok "open suppressed in auto mode"; else bad "open launched in auto mode" html-view; fi
rm -f "$SENT"
LOOP_BROWSER_CMD="$BROWSER_STUB" ./loop.sh report --text >"$WORK/report-text.out" 2>&1 </dev/null || true
if [ ! -f "$SENT" ] && grep -q 'run summary' "$WORK/report-text.out"; then ok "report --text stays text, no browser"; else bad "report --text misbehaved" html-view; fi

section "escalation authors decision.html and still never opens a browser headless"
make_fixture html-escalate
SENT2="$WORK/opened2.sentinel"
BROWSER_STUB2="$WORK/browser-stub2.sh"
printf '#!/bin/sh\necho opened >> "%s"\n' "$SENT2" > "$BROWSER_STUB2"; chmod +x "$BROWSER_STUB2"
rm -f "$SENT2"
RC=0
LOOP_HTML=1 LOOP_BROWSER_CMD="$BROWSER_STUB2" LOOP_CLAUDE_CMD="$FAKE" \
  LOOP_FAKE_SCENARIO="DECLARE_SPEC" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/html-esc.out" 2>&1 </dev/null || RC=$?
check "exit code 3 (escalation)" html-escalate 3 "$RC"
if [ -f .loop/reports/decision.html ]; then ok "decision.html authored on escalation"; else bad "decision.html missing" html-escalate; fi
if [ ! -f "$SENT2" ]; then ok "escalation opens no browser headless"; else bad "escalation opened a browser headless" html-escalate; fi

section "a fresh run never surfaces a PRIOR run's decision.html (stale-view leak)"
# reproduce the reported bug: a leftover decision.html from an earlier, unrelated
# run must be cleared at fresh-run start so finish() cannot open it. Escalate to a
# decision state with HTML off so THIS run authors no decision.html of its own.
make_fixture stale-view
mkdir -p .loop/reports
printf '<!doctype html><title>STALE PRIOR RUN</title><h1>unrelated</h1>\n' > .loop/reports/decision.html
RC=0
LOOP_HTML=0 LOOP_CLAUDE_CMD="$FAKE" \
  LOOP_FAKE_SCENARIO="DECLARE_SPEC" LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/stale-view.out" 2>&1 </dev/null || RC=$?
check "exit code 3 (escalation)" stale-view 3 "$RC"
if [ ! -f .loop/reports/decision.html ]; then ok "fresh run cleared the prior run's stale decision.html"; else bad "stale decision.html survived a fresh run (would open on escalation)" stale-view; fi

section "LOOP_HTML=0 forces authoring off even when a human is present"
make_fixture html-off
RC=0
LOOP_HTML=0 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/html-off.out" 2>&1 </dev/null || RC=$?
check "state SUCCESS" html-off SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
if [ ! -f .loop/reports/evidence.html ]; then ok "no evidence.html when LOOP_HTML=0"; else bad "evidence.html authored despite LOOP_HTML=0" html-off; fi
if ! grep -q '"state": "HTML_' .loop/journal.jsonl; then ok "html=off journals no HTML_ decision events at all"; else bad "HTML_ events despite LOOP_HTML=0" html-off; fi

section "HTML authorship claims are verified (LIE -> HTML_MISSING, run still succeeds)"
make_fixture html-lie
RC=0
LOOP_HTML=1 LOOP_FAKE_HTML=LIE LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/html-lie.out" 2>&1 </dev/null || RC=$?
check "exit code 0 (advisory: a broken view never fails the run)" html-lie 0 "$RC"
check "state SUCCESS" html-lie SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q '"state": "HTML_MISSING"' .loop/journal.jsonl; then ok "false authorship claim journaled as HTML_MISSING"; else bad "HTML_MISSING not journaled" html-lie; fi
if [ ! -f .loop/reports/evidence.html ]; then ok "no file exists behind the false claim"; else bad "file exists despite LIE mode" html-lie; fi

section "HTML lint: presentation defects journaled as HTML_LINT_WARN (advisory, run still succeeds)"
make_fixture html-lint
RC=0
LOOP_HTML=1 LOOP_FAKE_HTML=DIRTY LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh run >"$WORK/html-lint.out" 2>&1 </dev/null || RC=$?
check "exit code 0 (lint is advisory, never a gate)" html-lint 0 "$RC"
check "state SUCCESS" html-lint SUCCESS "$(cat .loop/state 2>/dev/null || echo none)"
if grep -q '"state": "HTML_LINT_WARN"' .loop/journal.jsonl; then ok "dirty page journaled as HTML_LINT_WARN"; else bad "HTML_LINT_WARN missing for dirty page" html-lint; fi
if grep -q '"state": "HTML_AUTHORED"' .loop/journal.jsonl; then ok "dirty page still journaled as HTML_AUTHORED"; else bad "HTML_AUTHORED missing alongside lint warning" html-lint; fi
if grep -q 'markdown backticks' .loop/journal.jsonl && grep -q 'missing <html lang' .loop/journal.jsonl && grep -q 'expected exactly one <h1>' .loop/journal.jsonl; then
  ok "lint names each defect (backticks, missing lang, missing h1)"
else
  bad "lint findings incomplete in journal" html-lint
fi

