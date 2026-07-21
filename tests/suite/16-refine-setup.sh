#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- design-gate refine + unchanged-re-approval guard + NEXT ACTION logs ----------
section "NEXT ACTION box on BLOCKED, and refine declines without a TTY (Parts B+C)"
make_fixture blocked-refine
run_loop "DECLARE_BLOCKED"
check "state BLOCKED" blocked-refine BLOCKED "$STATE"
# finish() must always print the scannable NEXT ACTION box that keeps the two human
# channels distinct: the within-contract steer (refine / resume --note) AND the
# contract-change path (/loop-contract), plus the "rejected as drift" guard sentence
# that would have saved the my_homepage run.
if grep -q 'NEXT ACTION' "$WORK/last-run.out"; then ok "BLOCKED prints the NEXT ACTION box"; else bad "NEXT ACTION box missing on BLOCKED" nextaction; fi
if grep -q './loop.sh signoff' "$WORK/last-run.out"; then ok "NEXT ACTION names the verbatim signoff command"; else bad "signoff command missing from NEXT ACTION" nextaction; fi
if grep -q './loop.sh refine' "$WORK/last-run.out"; then ok "NEXT ACTION offers the interactive refine path"; else bad "refine path missing from NEXT ACTION" nextaction; fi
if grep -q '/loop-contract' "$WORK/last-run.out" && grep -q 'rejected as drift' "$WORK/last-run.out"; then
  ok "NEXT ACTION separates the contract-change path and warns resume --note won't take it"
else
  bad "contract-change channel / drift warning missing from NEXT ACTION" nextaction
fi
# refine is TTY-only (like the contract session); headless it must decline and point
# at the headless steer, never launch a session
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh refine 'slower swirl' >"$WORK/refine-notty.out" 2>&1 </dev/null || RC=$?
check "refine without a TTY exits 2" blocked-refine 2 "$RC"
if grep -q 'interactive terminal' "$WORK/refine-notty.out" && grep -q 'resume --note' "$WORK/refine-notty.out"; then
  ok "refine (no TTY) points at ./loop.sh resume --note"
else
  bad "refine no-TTY guidance missing" nextaction
fi
# pin the TTY-only interactive session + confirmed-finish source so it can't vanish
if grep -q '/loop-refine' "$ROOT/bin/loop.sh" && grep -q 'sign off + ./loop.sh resume' "$ROOT/bin/loop.sh"; then
  ok "refine interactive session + [y] sign-off-and-resume present in source"
else
  bad "refine interactive/confirm path missing from source" nextaction
fi

section "refine declines a non-BLOCKED state with guidance (Part B)"
make_fixture refine-guard
RC=0   # fresh fixture: no run yet, no .loop/state
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh refine 'less motion' >"$WORK/refine-guard.out" 2>&1 </dev/null || RC=$?
check "refine on a non-BLOCKED state exits 2" refine-guard 2 "$RC"
if grep -q 'human sign-off gate' "$WORK/refine-guard.out"; then ok "refine explains it is for a BLOCKED sign-off gate"; else bad "refine guard message missing" refine-guard; fi

# ---------- setup: isolated agent/model tuning of loop.models.sh ----------
section "setup edits loop.models.sh in an isolated session, deterministically validated before it reflects"
make_fixture setup-ok
mkdir -p "$WORK/setup-tmp"
# (a) a VALID edit reflects into the real file (exit 0), and the throwaway temp is cleaned
RC=0
TMPDIR="$WORK/setup-tmp" LOOP_CLAUDE_CMD="$FAKE" ./loop.sh setup >"$WORK/setup-ok.out" 2>&1 </dev/null || RC=$?
check "setup (valid) exits 0" setup-ok 0 "$RC"
if grep -q '^AGENT_IMPLEMENT="codex"' loop.models.sh && grep -q '^MODEL_IMPLEMENT="gpt-5.5"' loop.models.sh; then
  ok "valid setup reflected the new routing into the real loop.models.sh"
else
  bad "valid setup did not update loop.models.sh" setup-ok
fi
if grep -q 'no re-approval' "$WORK/setup-ok.out"; then ok "setup states the change takes effect without re-approval"; else bad "setup missing the no-re-approval note" setup-ok; fi
if grep -q './loop.sh start' "$WORK/setup-ok.out"; then ok "setup success names the next command"; else bad "setup success missing next-action" setup-ok; fi
if [ -z "$(find "$WORK/setup-tmp" -maxdepth 1 -name 'loop-setup.*' 2>/dev/null)" ]; then ok "setup cleaned its throwaway temp (success)"; else bad "setup leaked its temp on success" setup-ok; fi

# (b) an INVALID result is REJECTED deterministically: real file untouched, exit 2, recovery named
make_fixture setup-reject
setup_before=$(cat loop.models.sh)
RC=0
TMPDIR="$WORK/setup-tmp" LOOP_FAKE_SETUP=INVALID LOOP_CLAUDE_CMD="$FAKE" ./loop.sh setup >"$WORK/setup-bad.out" 2>&1 </dev/null || RC=$?
check "setup (invalid) exits 2" setup-reject 2 "$RC"
if [ "$setup_before" = "$(cat loop.models.sh)" ]; then ok "rejected setup left the real loop.models.sh untouched"; else bad "rejected setup mutated loop.models.sh" setup-reject; fi
if grep -q 'Claude alias' "$WORK/setup-bad.out" && grep -q './loop.sh setup' "$WORK/setup-bad.out"; then
  ok "reject explains the offending value and names the re-run"
else
  bad "reject message/next-action missing" setup-reject
fi
if [ -z "$(find "$WORK/setup-tmp" -maxdepth 1 -name 'loop-setup.*' 2>/dev/null)" ]; then ok "setup cleaned its throwaway temp (reject)"; else bad "setup leaked its temp on reject" setup-reject; fi

# (c) source + help pins so the isolated session, the validator, and the help entry can't silently vanish
if grep -q '/loop-setup' "$ROOT/bin/loop.sh" && grep -q '^validate_models()' "$ROOT/bin/loop.sh"; then
  ok "setup session + deterministic validator present in source"
else
  bad "setup session/validator missing from source" setup-reject
fi
if ./loop.sh help 2>&1 | grep -qF 'setup [--app claude|codex]'; then ok "help pins the setup command"; else bad "setup missing from help" setup-reject; fi

# (d) an unknown --app is rejected with guidance (net-new flag surface)
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh setup --app banana >"$WORK/setup-app.out" 2>&1 </dev/null || RC=$?
check "setup --app banana exits 2" setup-reject 2 "$RC"
if grep -q 'unknown --app' "$WORK/setup-app.out"; then ok "bad --app names the fix"; else bad "bad --app guidance missing" setup-reject; fi

# a Codex wrapper that leaves a DURABLE marker (absolute path) proving the Codex CLI
# actually ran, then execs the real fake (its $0 keeps fake_codex's FAKE_CLAUDE self-resolve)
cat > "$WORK/setup-codex-probe.sh" <<PROBE
#!/bin/sh
echo ran >> "$WORK/setup-codex-ran"
exec "$FAKE_CODEX" "\$@"
PROBE
chmod +x "$WORK/setup-codex-probe.sh"

# (e) --app codex runs the Codex CLI (headless exec here) and reflects the validated result
make_fixture setup-codex
rm -f "$WORK/setup-codex-ran"
RC=0
TMPDIR="$WORK/setup-tmp" LOOP_CODEX_CMD="$WORK/setup-codex-probe.sh" ./loop.sh setup --app codex >"$WORK/setup-codex.out" 2>&1 </dev/null || RC=$?
check "setup --app codex exits 0" setup-codex 0 "$RC"
if [ -f "$WORK/setup-codex-ran" ]; then ok "setup --app codex invoked the Codex CLI"; else bad "setup --app codex did not run Codex" setup-codex; fi
if grep -q '^AGENT_IMPLEMENT="codex"' loop.models.sh && grep -q '^MODEL_IMPLEMENT="gpt-5.5"' loop.models.sh; then
  ok "codex setup reflected the validated routing into loop.models.sh"
else
  bad "codex setup did not update loop.models.sh" setup-codex
fi

# (f) --app claude with the Claude CLI absent falls back to Codex (fires on pre-launch availability only)
make_fixture setup-fallback
rm -f "$WORK/setup-codex-ran"
RC=0
TMPDIR="$WORK/setup-tmp" LOOP_CLAUDE_CMD="$WORK/no-such-claude" LOOP_CODEX_CMD="$WORK/setup-codex-probe.sh" ./loop.sh setup >"$WORK/setup-fb.out" 2>&1 </dev/null || RC=$?
check "setup falls back to Codex when Claude is absent (exit 0)" setup-fallback 0 "$RC"
if [ -f "$WORK/setup-codex-ran" ] && grep -qi 'Codex instead' "$WORK/setup-fb.out"; then
  ok "claude-absent setup announces and runs the Codex fallback"
else
  bad "claude-absent Codex fallback missing" setup-fallback
fi
if grep -q '^AGENT_IMPLEMENT="codex"' loop.models.sh; then ok "fallback setup reflected the validated routing"; else bad "fallback setup did not update loop.models.sh" setup-fallback; fi

section "spec decision: NEXT ACTION warns 'approve WITHOUT editing = same stop', and headless re-approval audits (Parts A+C)"
make_fixture reapprove
run_loop "DECLARE_SPEC"
check "state NEEDS_SPEC_DECISION" reapprove NEEDS_SPEC_DECISION "$STATE"
if grep -q 'NEXT ACTION' "$WORK/last-run.out" && grep -q 'WITHOUT editing the contract' "$WORK/last-run.out"; then
  ok "spec decision spells out the edit-vs-not fork (the my_homepage trap)"
else
  bad "unchanged-approve warning missing from spec-decision NEXT ACTION" reapprove
fi
# headless (no TTY) re-approval of an UNCHANGED contract must keep today's behavior
# (fleet/auto answer within-contract decisions this way) but journal the choice, and
# still rebind the checkpoint so resume continues.
RC=0
./loop.sh approve >"$WORK/reapprove.out" 2>&1 </dev/null || RC=$?
check "unchanged re-approval exits 0 (headless)" reapprove 0 "$RC"
if grep -q '"state": "APPROVE_UNCHANGED"' .loop/journal.jsonl; then ok "unchanged re-approval journaled APPROVE_UNCHANGED (auditable)"; else bad "APPROVE_UNCHANGED not journaled" reapprove; fi
if grep -q '"state": "DECISION_REBIND"' .loop/journal.jsonl; then ok "decision checkpoint still rebound (no regression from the guard)"; else bad "decision rebind lost after the guard" reapprove; fi
# the interactive confirm branch is TTY-only (untestable headlessly, like the amendment
# prompt) — pin its source so the guard can't silently disappear
if grep -q 'approve the UNCHANGED contract anyway' "$ROOT/bin/loop.sh" && grep -q 'APPROVE_ABORTED' "$ROOT/bin/loop.sh"; then
  ok "interactive unchanged-re-approval confirm + abort path present in source"
else
  bad "interactive unchanged-re-approval guard missing from source" reapprove
fi

section "signoff_human_rows flips only pending human rows to verified (Part B awk)"
# exercise the REAL function from source (BSD/gawk-safe awk) with tiny stubs. The
# human is certifying via the [y] confirm; the closing resume still re-verifies the
# cmd/run rows and the independent reviewer, so this only signs the 'human' rows.
mkdir -p "$WORK/signoff/.loop/docs"
cat > "$WORK/signoff/.loop/docs/acceptance-checklist.md" <<'EOF'
| id | req | expectation | method | status | evidence |
| AC-001 | REQ-001 | tests pass | cmd | verified | ran ./check.sh |
| AC-011 | REQ-001 | motion feels organic | human | pending | numeric drift log |
| AC-012 | REQ-002 | BH looks realistic | human | pending | lensing+swirl logs |
EOF
sed -n '/^signoff_human_rows() {/,/^}/p' "$ROOT/bin/loop.sh" > "$WORK/signoff-fn.sh"
# the stubs ARE invoked — indirectly, by the sourced signoff_human_rows (SC2329); the
# sourced file is generated at runtime by the sed above (SC1091). Both are expected.
# shellcheck disable=SC2329,SC1091
( cd "$WORK/signoff"
  note() { :; }
  utcnow() { echo "2026-07-13T00:00:00Z"; }
  journal_append() { :; }
  . "$WORK/signoff-fn.sh"
  signoff_human_rows
) >"$WORK/signoff.out" 2>&1
SIGN="$WORK/signoff/.loop/docs/acceptance-checklist.md"
if grep -qE '\| AC-011 \|.*\| human \| verified \|' "$SIGN" && grep -qE '\| AC-012 \|.*\| human \| verified \|' "$SIGN"; then
  ok "both pending human rows flipped to verified"
else
  bad "human rows not flipped to verified" signoff
fi
if grep -q 'human sign-off (refine)' "$SIGN"; then ok "sign-off note recorded in the evidence column"; else bad "sign-off note missing" signoff; fi
if grep -qE '\| AC-001 \|.*\| cmd \| verified \| ran ./check.sh \|' "$SIGN"; then ok "cmd row left untouched (only human rows signed)"; else bad "cmd row modified by sign-off" signoff; fi

section "human sign-off followed by resume still requires preflight + explicit review"
make_fixture signoff-resume
cat >> .loop/docs/product-contract.md <<'EOF'

## Acceptance Criteria
- AC-001 (human): the result is acceptable to the human
EOF
cat > .loop/docs/acceptance-checklist.md <<'EOF'
# Acceptance Checklist
| AC | REQ | Expectation | Method | Status | Evidence |
|---|---|---|---|---|---|
| AC-001 | REQ-001 | the result is acceptable to the human | human | pending | - |
EOF
git add -A && git commit -q -m "human signoff fixture"
./loop.sh approve >/dev/null
run_loop "DECLARE_BLOCKED"
sed 's/| human | pending | - |/| human | verified | human sign-off (fixture) |/' \
  .loop/docs/acceptance-checklist.md > .loop/docs/acceptance-checklist.md.tmp \
  && mv .loop/docs/acceptance-checklist.md.tmp .loop/docs/acceptance-checklist.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh resume >"$WORK/signoff-resume.out" 2>&1 </dev/null || RC=$?
check "signed-off resume succeeds" signoff-resume 0 "$RC"
check "signed-off resume has preflight PASS" signoff-resume PASS "$(json_scalar .loop/docs/certification.json preflight)"
if grep -q 'mode=gate' .loop/fake-review-prompts \
   && grep -q '"state": "REVIEW_APPROVE"' .loop/journal.jsonl; then
  ok "resume path still ran the independent gate review"
else
  bad "human sign-off bypassed the gate review" signoff-resume
fi

section "signoff command: complete approval — confirm gate, refusal paths, auto re-certify"
make_fixture signoff-cmd
cat >> .loop/docs/product-contract.md <<'EOF'

## Acceptance Criteria
- AC-001 (human): the result is acceptable to the human
EOF
cat > .loop/docs/acceptance-checklist.md <<'EOF'
# Acceptance Checklist
| AC | REQ | Expectation | Method | Status | Evidence |
|---|---|---|---|---|---|
| AC-001 | REQ-001 | the result is acceptable to the human | human | pending | - |
EOF
git add -A && git commit -q -m "signoff cmd fixture"
./loop.sh approve >/dev/null
run_loop "DECLARE_BLOCKED"
check "state BLOCKED" signoff-cmd BLOCKED "$STATE"
# (a) no TTY and no --yes: refuse with the two-channel recovery, checklist untouched
RC=0
./loop.sh signoff >"$WORK/signoff-notty.out" 2>&1 </dev/null || RC=$?
check "signoff without a TTY/--yes exits 2" signoff-cmd 2 "$RC"
if grep -q '→ next:' "$WORK/signoff-notty.out" && grep -q 'signoff --yes' "$WORK/signoff-notty.out" \
   && grep -q "resume --note" "$WORK/signoff-notty.out"; then
  ok "no-TTY signoff names both channels (--yes / resume --note)"
else
  bad "no-TTY signoff recovery missing" signoff-cmd
fi
if grep -q 'AC-001' "$WORK/signoff-notty.out"; then ok "signoff shows the row(s) it would sign"; else bad "pending rows not shown before the confirm" signoff-cmd; fi
if grep -q '| human | pending | - |' .loop/docs/acceptance-checklist.md; then
  ok "refused signoff left the checklist untouched"
else
  bad "no-TTY signoff mutated the checklist" signoff-cmd
fi
# (b) per-row signing is refused (all-or-nothing), with the sign-vs-note fork named
RC=0
./loop.sh signoff AC-001 >"$WORK/signoff-partial.out" 2>&1 </dev/null || RC=$?
check "signoff <AC-id> exits 2" signoff-cmd 2 "$RC"
if grep -q 'all-or-nothing' "$WORK/signoff-partial.out" && grep -q "resume --note" "$WORK/signoff-partial.out"; then
  ok "per-row signoff refused with the sign-vs-note fork"
else
  bad "per-row refusal guidance missing" signoff-cmd
fi
# (c) --yes signs every pending human row and auto-resumes through the full gate
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh signoff --yes >"$WORK/signoff-yes.out" 2>&1 </dev/null || RC=$?
check "signoff --yes exits 0 (signed + re-certified)" signoff-cmd 0 "$RC"
if grep -qE '\| human \| verified \|' .loop/docs/acceptance-checklist.md \
   && grep -q 'human sign-off (signoff)' .loop/docs/acceptance-checklist.md; then
  ok "human row verified with the signoff-sourced evidence note"
else
  bad "signoff --yes did not sign the human row" signoff-cmd
fi
check "signoff resume has preflight PASS" signoff-cmd PASS "$(json_scalar .loop/docs/certification.json preflight)"
if grep -q 'mode=gate' .loop/fake-review-prompts && grep -q '"state": "REVIEW_APPROVE"' .loop/journal.jsonl; then
  ok "signoff still went through the independent gate review (no shortcut to SUCCESS)"
else
  bad "signoff bypassed the gate review" signoff-cmd
fi
if grep -q '"state": "HUMAN_SIGNOFF"' .loop/journal.jsonl && grep -q 'via signoff: AC-001' .loop/journal.jsonl; then
  ok "sign-off journaled with its source and the signed AC id"
else
  bad "HUMAN_SIGNOFF journal row missing/unsourced" signoff-cmd
fi
# (d) idempotent: nothing pending -> no-op notice, exit 0, next named
RC=0
./loop.sh signoff --yes >"$WORK/signoff-noop.out" 2>&1 </dev/null || RC=$?
check "signoff with nothing pending exits 0" signoff-cmd 0 "$RC"
if grep -q 'nothing to sign off' "$WORK/signoff-noop.out" && grep -q '→ next:' "$WORK/signoff-noop.out"; then
  ok "no-op signoff says so and names the next command"
else
  bad "no-op signoff guidance missing" signoff-cmd
fi
# (e) help pins the command
if ./loop.sh help 2>&1 | grep -qF 'signoff [--yes]'; then ok "help pins the signoff command"; else bad "signoff missing from help" signoff-cmd; fi

section "stagnation -> STALLED"
make_fixture stalled
run_loop "NO_DIFF,NO_DIFF"
check "exit code 4" stalled 4 "$RC"
check "state STALLED" stalled STALLED "$STATE"
# STALLED is a futility stop, NOT a sign-off gate: it must show the futility box
# (resume --note guidance), not the BLOCKED sign-off wording that reused it before.
if grep -q 'NEXT ACTION' "$WORK/last-run.out" && grep -q 'resume --note' "$WORK/last-run.out" \
   && grep -qi 'without making progress' "$WORK/last-run.out"; then
  ok "STALLED shows the futility NEXT ACTION box (steer with resume --note)"
else
  bad "STALLED missing the futility box" nextcmd
fi
if ! grep -q "mark the 'human' row" "$WORK/last-run.out"; then
  ok "STALLED does not misuse the human-sign-off wording"
else
  bad "STALLED wrongly shows the sign-off box" nextcmd
fi
# status alone must tell the user how to proceed from a paused state
./loop.sh status >"$WORK/stalled-status.out" 2>&1 </dev/null || true
if grep -qE '^next:' "$WORK/stalled-status.out" && grep -q 'resume --note' "$WORK/stalled-status.out"; then
  ok "status prints a next: pointer for a STALLED run"
else
  bad "status missing the next: pointer on STALLED" nextcmd
fi

section "identical failure repeated -> BLOCKED"
make_fixture repeat-fail
run_loop "BAD_FIX,BAD_FIX,BAD_FIX"
check "exit code 4" repeat-fail 4 "$RC"
check "state BLOCKED" repeat-fail BLOCKED "$STATE"

section "alternating A/B verification failures -> BLOCKED (oscillation)"
# fix-A-breaks-B ping-pong: fingerprints alternate, so the identical-repeat
# rule (3 in a row of ONE fingerprint) never fires — the 2xREPEAT_FAIL_N
# oscillation window must catch it instead of burning the whole budget.
make_fixture oscillate
cat > check.sh <<'EOF'
#!/bin/sh
cat value.txt
grep -q fixed value.txt
EOF
chmod +x check.sh
printf 'MAX_ITERATIONS=8\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "FLIP_FIX,FLIP_FIX,FLIP_FIX,FLIP_FIX,FLIP_FIX,FLIP_FIX"
check "exit code 4" oscillate 4 "$RC"
check "state BLOCKED" oscillate BLOCKED "$STATE"
if grep -q 'cycling between 2 states' .loop/journal.jsonl; then
  ok "oscillation named in the terminal reason"
else
  bad "cycling reason missing from the journal" oscillate
fi
if ! grep -q 'identical verification failure repeated' .loop/journal.jsonl; then
  ok "identical-repeat rule correctly never fired on alternating failures"
else
  bad "identical-repeat rule misfired on alternating fingerprints" oscillate
fi

section "identical failure, per-iteration duration varies -> BLOCKED (portable fingerprint)"
# Regression for the BSD/GNU sed word-boundary bug in evaluate.sh: the failure line
# is identical every iteration EXCEPT a per-iteration duration ("in 0.1s", "0.2s"...).
# The fingerprint must strip the duration so the three failures dedup to one and BLOCK.
# Pre-fix the normalization used GNU-only `\b`, a no-op on BSD/macOS sed, so the
# durations survived -> three distinct fingerprints -> the run never BLOCKED. The
# counter lives outside the repo so the baseline verify and diff scan never see it.
make_fixture fpdur
rm -f "$WORK/fpdur-counter"
cat > check.sh <<EOF
#!/bin/sh
n=\$(cat "$WORK/fpdur-counter" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$WORK/fpdur-counter"
echo "FAILED tests/test_widget.py::test_add in 0.\${n}s"
exit 1
EOF
chmod +x check.sh
./loop.sh approve >/dev/null
run_loop "BAD_FIX,BAD_FIX,BAD_FIX"
check "exit code 4" fpdur 4 "$RC"
check "state BLOCKED (duration normalized out of the fingerprint)" fpdur BLOCKED "$STATE"

section "verify flake: retried once, journaled, never hidden (VERIFY_RETRIES=1)"
make_fixture vflake
# fail exactly once AFTER the fix lands (the marker lives outside the repo so
# the baseline-verify run and the diff scan never see it)
rm -f "$WORK/vflake-marker"
cat > check.sh <<EOF
#!/bin/sh
grep -q fixed value.txt || exit 1
if [ ! -f "$WORK/vflake-marker" ]; then touch "$WORK/vflake-marker"; exit 1; fi
exit 0
EOF
chmod +x check.sh
printf 'VERIFY_RETRIES=1\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "READY_NOW"
check "exit 0 (flake absorbed by the rerun)" vflake 0 "$RC"
check "state SUCCESS" vflake SUCCESS "$STATE"
if grep -q '"state": "VERIFY_FLAKE"' .loop/journal.jsonl; then ok "flake journaled as VERIFY_FLAKE"; else bad "VERIFY_FLAKE missing" vflake; fi
if grep '"state": "VERIFY_FLAKE"' .loop/journal.jsonl | grep -q 'check.sh'; then ok "flake reason names the failing command"; else bad "flake reason lacks the command" vflake; fi

section "verify flake: persistent failure is NOT absorbed (repeat-fail intact)"
make_fixture vflake-persist
printf 'VERIFY_RETRIES=1\n' >> loop.config.sh
./loop.sh approve >/dev/null
run_loop "BAD_FIX,BAD_FIX,BAD_FIX"
check "exit code 4" vflake-persist 4 "$RC"
check "state BLOCKED (identical-failure fingerprint unchanged)" vflake-persist BLOCKED "$STATE"
if ! grep -q '"state": "VERIFY_FLAKE"' .loop/journal.jsonl; then ok "persistent failure never journaled as a flake"; else bad "persistent failure miscounted as flake" vflake-persist; fi
if [ ! -f .loop/verify-flake.log ]; then ok "no flake log left behind"; else bad "stale verify-flake.log" vflake-persist; fi

section "VERIFY_RETRIES unset -> no rerun ever (byte-compatible default)"
make_fixture vflake-off
rm -f "$WORK/vflake-marker"
cat > check.sh <<EOF
#!/bin/sh
grep -q fixed value.txt || exit 1
if [ ! -f "$WORK/vflake-marker" ]; then touch "$WORK/vflake-marker"; exit 1; fi
exit 0
EOF
chmod +x check.sh
./loop.sh approve >/dev/null
run_loop "READY_NOW,READY_NOW"
if ! grep -q '\[RETRY\]\|\[FLAKE\]' .loop/last-verify.log 2>/dev/null && ! grep -q '"state": "VERIFY_FLAKE"' .loop/journal.jsonl; then ok "no retry machinery without the knob"; else bad "retry ran with VERIFY_RETRIES unset" vflake-off; fi

