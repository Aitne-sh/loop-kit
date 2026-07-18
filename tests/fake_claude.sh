#!/usr/bin/env bash
# fake_claude.sh — scenario-driven stub for the claude CLI (zero tokens).
# Speaks the wire format loop.sh expects and records which --model it was given
# (so tests can verify per-role model routing).
#
# LOOP_FAKE_SCENARIO: comma-separated actions consumed one per /loop-iterate call
# LOOP_FAKE_REVIEW:   comma-separated verdicts consumed one per /loop-review call
# LOOP_FAKE_STATE_REVIEW: optional verdict sequence used only for
#                     /loop-review mode=gate scope=state (falls back to REVIEW)
#                     (APPROVE | REVISE | APPROVE_TAIL | REVISE_TAIL | NOVERDICT
#                      | APPROVE_NOREQS | APPROVE_UNMET | ESCALATE
#                      | APPROVE_DECORATED | CRASH | SLOW_CRASH;
#                      CRASH simulates a reviewer-call outage: non-JSON stdout,
#                      stderr noise, exit 1 — consumed like any other entry;
#                      SLOW_CRASH sleeps 3s first (pair with MAX_ITER_SECONDS=1
#                      to simulate a deterministic watchdog timeout);
#                      *_TAIL puts the VERDICT line at the END after analysis,
#                      reproducing real reviewer output; NOVERDICT omits it.
#                      APPROVE/APPROVE_TAIL emit per-REQ 'REQ-xxx: MET' lines on
#                      gate reviews, as the skill mandates; APPROVE_NOREQS omits
#                      them and APPROVE_UNMET marks the first REQ UNMET — both
#                      must be downgraded to REVISE by the harness; ESCALATE
#                      renders 'VERDICT: ESCALATE <question>'; APPROVE_DECORATED
#                      wraps the trailing verdict in blockquote+bullet+backtick
#                      decoration the harness must strip)
# LOOP_FAKE_STOPEVAL: comma-separated verdicts consumed one per /loop-stop-eval call
#                     (CONTINUE | MET | FUTILE | MET_FENCED | FUTILE_FENCED;
#                      *_FENCED wraps the line in a markdown code fence)
# LOOP_FAKE_CONTRACT_REVIEW: comma-separated verdicts consumed one per
#                     /loop-contract-review call (APPROVE | REVISE | NOVERDICT)
# LOOP_FAKE_DECOMPOSE: comma-separated plans consumed one per /loop-decompose call
#                     (ONE | TWO_PAR | CHAIN | CYCLE | NOREQ | NOVERDICT
#                      | CHAIN_SHARED | SHARED_PAR | SHARED_FORK
#                      | SHARED_FORKJOIN | SHARED_TWOSINKS | LONGID;
#                      LONGID is the CHAIN shape with a 30-char first id —
#                      the harness must normalize it deterministically;
#                      ONE/NOREQ/NOVERDICT write a 1-task plan covering REQ-001,
#                      TWO_PAR/CHAIN/CYCLE write 2 tasks covering REQ-001+REQ-002;
#                      CHAIN_SHARED writes a valid 3-phase chain sharing REQ-001
#                      (phase-a -> phase-b -> phase-c, REQ-002 on the tail);
#                      SHARED_PAR shares REQ-001 across two PARALLEL tasks and
#                      SHARED_FORK shares REQ-002 across a join-less fork — both
#                      must be rejected by the completing-owner check;
#                      SHARED_FORKJOIN is the VALID diamond part-a ->
#                      {part-b ∥ part-c} -> part-d with REQ-002 shared by
#                      b/c/d — the join part-d is the completing owner;
#                      SHARED_TWOSINKS is the diamond with TWO parallel joins
#                      (part-d ∥ part-e) — no single completing owner, rejected)
# LOOP_FAKE_DECOMPOSE_REVIEW: verdicts per /loop-decompose-review call
#                     (APPROVE | REVISE | NOVERDICT)
# LOOP_FAKE_SUPERVISE: decisions per /loop-supervise call
#                     (ANSWER | REPLAN | REPLAN_DROP | REPLAN_CHAIN | REPLAN_FORK
#                      | REPLAN_FORKJOIN | REPLAN_FORKJOIN_CARRY | REPLAN_CYCLE
#                      | ESCALATE | NOVERDICT;
#                      REPLAN_DROP is REPLAN whose replacement covers REQ-001
#                      ONLY — pair with an escalated task owning more REQs to
#                      exercise the union/coverage check; REPLAN_CHAIN splits the
#                      escalated task into a valid 2-phase intra-block chain
#                      sharing REQ-001; REPLAN_FORK shares REQ-001 across two
#                      parallel JOIN-LESS replacements (must be rejected);
#                      REPLAN_FORKJOIN is the valid {half-a ∥ half-b} -> join-c
#                      diamond sharing REQ-001 (3 tasks; two roots, so a
#                      NEEDS_DECOMPOSITION carryover is skipped, journaled);
#                      REPLAN_FORKJOIN_CARRY prepends a unique root
#                      (root-p -> {half-a ∥ half-b} -> join-c, 4 tasks — needs
#                      FLEET_MAX_REPLAN_TASKS>=4) so the seed lands on root-p;
#                      REPLAN_CYCLE is an intra-block cycle (must be rejected);
#                      REPLAN_DEADDEP depends on the failed task 'dead-task' —
#                      the failed-DEPENDS guard must reject it)
# LOOP_FAKE_PLAN_REVIEW: verdicts per /loop-supervise mode=plan-review call
#                     (KEEP | REVISE | REVISE_DROP | REVISE_SWEEP | ESCALATE
#                      | NOVERDICT; own counter .loop/fake-planrev-i. REVISE
#                      replaces the CHAIN_SHARED plan's queued phase-b/phase-c
#                      with a phase-b2->phase-c2 chain covering the same REQ
#                      union; REVISE_DROP drops REQ-002 — must be rejected;
#                      REVISE_SWEEP emits one redo-tail task covering REQ-002 —
#                      against the SHARED_FORKJOIN plan it must sweep ALL queued
#                      owners of REQ-002 (part-b, part-c, part-d) into the
#                      replaced set)
# .loop/fake-supervise-prompts mirrors every /loop-supervise prompt (tests
#                     assert mode=plan-review routing and the session=resumed token)
# .loop/fake-supervise-sleep (seconds): delay only /loop-supervise replies.
#                     The prompt is recorded first, giving interrupt tests a
#                     deterministic "supervisor call is in flight" handshake.
# .loop/fake-evidence-prompts mirrors every /loop-evidence prompt so tests can
#                     assert task/run log namespace isolation.
# LOOP_FAKE_CONTRACT: /loop-contract generator verdict (unset | QUESTIONS |
#                     READY | MALFORMED). QUESTIONS writes the contract PLUS a
#                     DR-CONTRACT-1 block in .loop/docs/decision-requests.md and
#                     ends with 'CONTRACT-GEN: QUESTIONS …'; READY ends with
#                     'CONTRACT-GEN: READY …'; MALFORMED/unset emit today's
#                     plain 'contract written' (no marker) byte-for-byte.
# LOOP_FAKE_CONTRACT_REVIEW also accepts ESCALATE
#                     ('CONTRACT-REVIEW: ESCALATE <question>').
# LOOP_FAKE_CONTRACT_STRIP_CODEX_KEYS=1: the /loop-contract generator also
#                     strips every LOOP_CODEX_* line from loop.config.sh —
#                     models a sub-contract rewrite that drops the parent's
#                     Codex sandbox keys (the harness must fall back to the
#                     parent's exported posture, not its own default).
# LOOP_FAKE_HTML=LIE: emit the 'HTML-DECISION: authored …' marker WITHOUT
#                     writing the file (tests the harness's existence check).
# LOOP_FAKE_HTML=DECORATED: emit the 'HTML-DECISION: skipped …' marker as a
#                     decorated bullet+backtick line (tests the leading-
#                     decoration strip in the harness's marker parser).
# LOOP_FAKE_HTML=DIRTY: author the evidence page WITH presentation defects
#                     (markdown residue in rendered text, no <html lang>, no
#                     <h1>) — tests the harness's advisory HTML_LINT_WARN.
# .loop/fake-conrev-prompts mirrors .loop/fake-review-prompts for every
#                     /loop-contract-review call (tests assert the ask=critical
#                     token plumbing on both the first call and the retry).
# LOOP_FAKE_SLEEP (env) and a per-cwd .loop/fake-sleep file (seconds): opt-in
#                     delay before replying — the env spans the process tree,
#                     the file scopes the delay to loops running in THIS
#                     directory (mirrors the .loop/fake-scenario override).
# LOOP_FAKE_GRANDCHILD=N: spawn a detached grandchild that writes
#                     .loop/fake-grandchild-alive after N seconds. A single-pid
#                     kill of this fake leaves it orphaned (it writes the marker);
#                     the harness's process-group kill takes it down before it can.
#                     The interrupt tests use the marker's ABSENCE to prove the
#                     whole agent subtree was reaped. Relies on this fake NOT
#                     trapping TERM (SIG_DFL), so a group TERM kills it pre-touch.
# .loop/fake-tools mirrors .loop/fake-models: one line per call,
#                     "<model> <flag>=<value>…" for every tool-restriction flag
#                     (--tools/--allowedTools/--disallowedTools) received.
# LOOP_FAKE_RAW_RESULT=1: print only the decoded result text (used internally by
#                     fake_codex.sh; unset preserves the legacy JSON envelope).
# LOOP_FAKE_DELEGATED_CODEX=1: suppress Claude argv telemetry for that internal
#                     delegation so Claude/Codex routing logs remain disjoint.
# (last entry repeats when exhausted). LOOP_FAKE_COST overrides per-call cost.

set -euo pipefail

# stdin -> hex SHA-256. Mirrors loop.sh's sha256() (shasum on macOS/perl, sha256sum
# on coreutils) so the fake agent's tamper scenarios run on any box with either tool.
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi; }

PROMPT=""
MODEL_SEEN=""
EFFORT_SEEN=""
TOOLFLAGS=""
RESUME_SEEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PROMPT="${2:-}"; shift 2 ;;
    --model) MODEL_SEEN="${2:-}"; shift 2 ;;
    --effort) EFFORT_SEEN="${2:-}"; shift 2 ;;
    --resume) RESUME_SEEN="${2:-}"; shift 2 ;;
    --allowedTools|--disallowedTools|--tools)
      # keep the raw flag+value so tests can assert the harness really passed
      # its tool restrictions (read-only checkers, network denylist)
      TOOLFLAGS="$TOOLFLAGS $1=${2:-}"; shift 2 ;;
    --output-format|--permission-mode|--max-budget-usd|--fallback-model) shift 2 ;;
    -*) shift ;;
    *) if [ -z "$PROMPT" ]; then PROMPT="$1"; fi; shift ;;
  esac
done

mkdir -p .loop .loop/docs
# orphan-detection probe (spawned BEFORE the .loop/fake-models readiness marker the
# interrupt tests poll, so the grandchild provably exists when they fire the signal)
[ -z "${LOOP_FAKE_GRANDCHILD:-}" ] || ( sleep "$LOOP_FAKE_GRANDCHILD"; : > .loop/fake-grandchild-alive ) &
if [ "${LOOP_FAKE_DELEGATED_CODEX:-0}" != 1 ]; then
  echo "$MODEL_SEEN" >> .loop/fake-models
  # one line per call: the --resume session id the harness passed ('-' = fresh
  # call) — tests assert supervisor-session reuse/rotation sequences with this
  echo "${RESUME_SEEN:--}" >> .loop/fake-resumes
  # one line per call: the --effort value the harness passed (blank if it passed
  # none) — tests assert LOOP_EFFORT routing the way .loop/fake-models proves model routing
  echo "$EFFORT_SEEN" >> .loop/fake-effort
  # mirror of .loop/fake-models with the tool-restriction flags per call
  [ -z "$TOOLFLAGS" ] || echo "$MODEL_SEEN$TOOLFLAGS" >> .loop/fake-tools
fi
cost="${LOOP_FAKE_COST:-0.01}"

# Record protocol prompts BEFORE any opt-in delay below: tests use "prompt
# visible, fake still sleeping" as a deterministic mid-call window (e.g.
# adding a task while the integration-gate review is provably in flight, or
# interrupting an orchestration while supervision is provably in flight).
case "$PROMPT" in
  /loop-review*) printf '%s\n' "$PROMPT" >> .loop/fake-review-prompts ;;
  /loop-contract-review*) printf '%s\n' "$PROMPT" >> .loop/fake-conrev-prompts ;;
  /loop-evidence*) printf '%s\n' "$PROMPT" >> .loop/fake-evidence-prompts ;;
  /loop-supervise*)
    printf '%s\n' "$PROMPT" >> .loop/fake-supervise-prompts
    [ ! -f .loop/fake-supervise-sleep ] || sleep "$(cat .loop/fake-supervise-sleep)"
    ;;
esac

# opt-in delays (both default off, zero change when unset): the env applies to
# every call in the process tree; the per-cwd file scopes the delay to loops
# running in THIS directory (mirrors the .loop/fake-scenario override)
[ -z "${LOOP_FAKE_SLEEP:-}" ] || sleep "$LOOP_FAKE_SLEEP"
[ ! -f .loop/fake-sleep ] || sleep "$(cat .loop/fake-sleep)"

# per-worktree scenario override: fleet tests run several loops in parallel from
# one exported env, so each worktree can carry its own script in this file
# (cwd here is the worktree the loop runs in)
if [ -f .loop/fake-scenario ]; then
  LOOP_FAKE_SCENARIO="$(cat .loop/fake-scenario)"
fi

emit_json() { # $1 cost, $2 result text (no quotes/backslashes)
  if [ "${LOOP_FAKE_RAW_RESULT:-0}" = 1 ]; then
    # Scenario strings carry JSON-style \n escapes. Codex's -o file contains the
    # rendered message, so materialize them only for this explicit adapter mode.
    printf '%b\n' "$2"
    return 0
  fi
  # per-cwd incrementing session ids (fake-s1, fake-s2, …): the harness stores
  # the LAST call's id as the next --resume handle, so tests can assert exact
  # fresh-vs-resumed sequences. num_turns mirrors the real CLI's top-level
  # scalar (LOOP_FAKE_TURNS opts in; 0 otherwise — harness treats 0 as "unknown").
  local sn
  sn=$(cat .loop/fake-session-i 2>/dev/null || echo 0)
  sn=$((sn + 1))
  echo "$sn" > .loop/fake-session-i
  printf '{"type":"result","subtype":"success","is_error":false,"result":"%s","total_cost_usd":%s,"num_turns":%s,"session_id":"fake-s%s"}\n' "$2" "$1" "${LOOP_FAKE_TURNS:-0}" "$sn"
}

next_from_list() { # $1 list, $2 counter-file -> echoes next entry (last repeats)
  local idx last
  idx=$(cat "$2" 2>/dev/null || echo 0)
  IFS=',' read -r -a entries <<< "$1"
  last=$(( ${#entries[@]} - 1 ))
  if [ "$idx" -gt "$last" ]; then echo "${entries[$last]}"; else echo "${entries[$idx]}"; fi
  echo $((idx + 1)) > "$2"
}

contract_req_ids() { # REQ ids from contract HEADINGS (same rule as the harness)
  grep -E '^#{1,6}[[:space:]]*REQ-[0-9]+' .loop/docs/product-contract.md 2>/dev/null \
    | grep -oE 'REQ-[0-9]+' | sort -u || true
}

ledger_all_met() { # mark every contract REQ met (mirrors an honest final iteration)
  local ids rid
  ids=$(contract_req_ids)
  [ -n "$ids" ] || return 0
  {
    echo "# Requirements Ledger"
    echo
    echo "| REQ | Status | Evidence | Iter |"
    echo "|---|---|---|---|"
    while IFS= read -r rid; do
      printf '| %s | met | value.txt fixed | 1 |\n' "$rid"
    done <<LEDGER
$ids
LEDGER
  } > .loop/docs/requirements-ledger.md
}

req_verdict_lines() { # $1 verdict-word for the FIRST REQ (MET for the rest) ->
  # literal '\n'-joined 'REQ-xxx: <word> - evidence' lines for emit_json
  local ids rid out="" first="$1"
  ids=$(contract_req_ids)
  [ -n "$ids" ] || return 0
  while IFS= read -r rid; do
    out="${out}${rid}: ${first} - fake per-REQ verdict\\n"
    first="MET"
  done <<REQS
$ids
REQS
  printf '%s' "$out"
}

case "$PROMPT" in
  /loop-decompose-review*)   # must precede /loop-decompose* (prefix overlap)
    drv=$(next_from_list "${LOOP_FAKE_DECOMPOSE_REVIEW:-APPROVE}" .loop/fake-decrev-i)
    case "$drv" in
      REVISE)
        emit_json "$cost" "Analysis: scopes overlap in this repo.\n\nDECOMPOSE-REVIEW: REVISE 1. part-a and part-b own the same area" ;;
      NOVERDICT)
        emit_json "$cost" "Plan looks fine but I forgot the output protocol entirely." ;;
      *)
        emit_json "$cost" "DECOMPOSE-REVIEW: APPROVE boundaries are real and disjoint" ;;
    esac
    exit 0
    ;;
  /loop-decompose*)
    # record whether this call could see validator feedback from a prior attempt
    # (the harness must keep .loop/decompose-feedback.md alive across the retry)
    [ ! -f .loop/decompose-feedback.md ] \
      || head -1 .loop/decompose-feedback.md >> .loop/fake-decompose-fb-seen
    if [ "${LOOP_FAKE_DECOMPOSE_TAMPER:-}" = MODELS ]; then
      # A full DECOMPOSE role can physically reach ignored harness/config files;
      # the parent must catch this before it parses or publishes the plan.
      echo 'MODEL_REVIEW="tampered-by-decompose"' >> loop.models.sh
    fi
    dv=$(next_from_list "${LOOP_FAKE_DECOMPOSE:-ONE}" .loop/fake-decompose-i)
    dep="-"
    [ "$dv" = "CHAIN" ] && dep="part-a"
    case "$dv" in
      TWO_PAR|CHAIN)
        cat > .loop/docs/task-plan.md <<EOF
# Task Plan
Two tasks (fake decomposition).
<!-- TASK-PLAN-BEGIN v1 -->
TASK: part-a
SUMMARY: alpha part - fix value.txt
DEPENDS: -
SCOPE: value.txt only
REQS: REQ-001
BODY-BEGIN
Fix value.txt so ./check.sh passes (REQ-001).
BODY-END
TASK-END
TASK: part-b
SUMMARY: bravo part - fix value.txt
DEPENDS: $dep
SCOPE: value.txt only (identical change is merge-safe)
REQS: REQ-002
BODY-BEGIN
Fix value.txt so ./check.sh passes (REQ-002).
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        emit_json "$cost" "DECOMPOSE: TASKS n=2" ;;
      CHAIN_SHARED)
        cat > .loop/docs/task-plan.md <<'EOF'
# Task Plan
Three sequential phases of one large piece of work (fake decomposition):
phase-a -> phase-b -> phase-c share REQ-001; the tail also owns REQ-002.
<!-- TASK-PLAN-BEGIN v1 -->
TASK: phase-a
SUMMARY: phase 1 - start fixing value.txt
DEPENDS: -
SCOPE: value.txt only (phase 1 slice)
REQS: REQ-001
BODY-BEGIN
Phase 1 of REQ-001: fix value.txt so ./check.sh passes. Done for this phase = check.sh green.
BODY-END
TASK-END
TASK: phase-b
SUMMARY: phase 2 - continue on the merged phase 1
DEPENDS: phase-a
SCOPE: value.txt only (phase 2 slice)
REQS: REQ-001
BODY-BEGIN
Phase 2 of REQ-001: building on the merged phase 1, keep ./check.sh green.
BODY-END
TASK-END
TASK: phase-c
SUMMARY: phase 3 - certify REQ-001 in full, close REQ-002
DEPENDS: phase-b
SCOPE: value.txt only (final phase)
REQS: REQ-001,REQ-002
BODY-BEGIN
Final phase: certify REQ-001 in full and satisfy REQ-002 (same gate).
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        emit_json "$cost" "DECOMPOSE: TASKS n=3" ;;
      DRIFT_CHAIN)
        # aa-drift (REQ-001, independent, no dependents) alongside a 3-phase chain
        # ch-a -> ch-b -> ch-c sharing REQ-002. aa-drift is a single fast phase, so
        # it merges while the sequential chain is still early — ch-c (at least) is
        # always still queued at that moment, guaranteeing a queued PLANNED task.
        # Because NOTHING depends on aa-drift, any plan-review it gets can only come
        # from the drift trigger (task_has_queued_dependents is false for it).
        cat > .loop/docs/task-plan.md <<'EOF'
# Task Plan
An independent drift task beside a 3-phase chain (fake decomposition):
aa-drift owns REQ-001; ch-a -> ch-b -> ch-c share REQ-002 (ch-c completing owner).
<!-- TASK-PLAN-BEGIN v1 -->
TASK: aa-drift
SUMMARY: independent task that records a locally-handled drift
DEPENDS: -
SCOPE: value.txt only (independent)
REQS: REQ-001
BODY-BEGIN
Fix value.txt so ./check.sh passes (REQ-001).
BODY-END
TASK-END
TASK: ch-a
SUMMARY: chain phase 1
DEPENDS: -
SCOPE: value.txt only (phase 1 slice)
REQS: REQ-002
BODY-BEGIN
Phase 1 of REQ-002: fix value.txt so ./check.sh passes.
BODY-END
TASK-END
TASK: ch-b
SUMMARY: chain phase 2
DEPENDS: ch-a
SCOPE: value.txt only (phase 2 slice)
REQS: REQ-002
BODY-BEGIN
Phase 2 of REQ-002: building on the merged phase 1, keep ./check.sh green.
BODY-END
TASK-END
TASK: ch-c
SUMMARY: chain phase 3 - certify REQ-002 in full
DEPENDS: ch-b
SCOPE: value.txt only (final phase)
REQS: REQ-002
BODY-BEGIN
Final phase: certify REQ-002 in full on the merged chain.
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        emit_json "$cost" "DECOMPOSE: TASKS n=4" ;;
      SHARED_PAR)
        cat > .loop/docs/task-plan.md <<'EOF'
# Task Plan
INVALID: two parallel tasks share REQ-001 (no chain).
<!-- TASK-PLAN-BEGIN v1 -->
TASK: part-a
SUMMARY: alpha part
DEPENDS: -
SCOPE: value.txt
REQS: REQ-001
BODY-BEGIN
Fix value.txt (REQ-001).
BODY-END
TASK-END
TASK: part-b
SUMMARY: bravo part (illegally shares REQ-001 in parallel)
DEPENDS: -
SCOPE: value.txt
REQS: REQ-001,REQ-002
BODY-BEGIN
Fix value.txt (REQ-001, REQ-002).
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        emit_json "$cost" "DECOMPOSE: TASKS n=2" ;;
      SHARED_FORK)
        cat > .loop/docs/task-plan.md <<'EOF'
# Task Plan
INVALID: part-b and part-c fork off part-a and share REQ-002.
<!-- TASK-PLAN-BEGIN v1 -->
TASK: part-a
SUMMARY: alpha part
DEPENDS: -
SCOPE: value.txt
REQS: REQ-001
BODY-BEGIN
Fix value.txt (REQ-001).
BODY-END
TASK-END
TASK: part-b
SUMMARY: bravo fork
DEPENDS: part-a
SCOPE: value.txt
REQS: REQ-002
BODY-BEGIN
Fix value.txt (REQ-002).
BODY-END
TASK-END
TASK: part-c
SUMMARY: charlie fork (illegally shares REQ-002 with the parallel fork)
DEPENDS: part-a
SCOPE: value.txt
REQS: REQ-002
BODY-BEGIN
Fix value.txt (REQ-002).
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        emit_json "$cost" "DECOMPOSE: TASKS n=3" ;;
      SHARED_FORKJOIN)
        cat > .loop/docs/task-plan.md <<'EOF'
# Task Plan
VALID diamond: part-b ∥ part-c fork off part-a; the join part-d owns the
shared REQ-002 too and depends on both branches — the completing owner.
<!-- TASK-PLAN-BEGIN v1 -->
TASK: part-a
SUMMARY: prep phase - fix value.txt
DEPENDS: -
SCOPE: value.txt (prep slice)
REQS: REQ-001
BODY-BEGIN
Prep phase: fix value.txt so ./check.sh passes (REQ-001).
BODY-END
TASK-END
TASK: part-b
SUMMARY: branch B of REQ-002 (parallel with part-c)
DEPENDS: part-a
SCOPE: value.txt + this branch's marker only
REQS: REQ-002
BODY-BEGIN
Branch B of REQ-002: keep ./check.sh green on the merged prep.
BODY-END
TASK-END
TASK: part-c
SUMMARY: branch C of REQ-002 (parallel with part-b)
DEPENDS: part-a
SCOPE: value.txt + this branch's marker only
REQS: REQ-002
BODY-BEGIN
Branch C of REQ-002: keep ./check.sh green on the merged prep.
BODY-END
TASK-END
TASK: part-d
SUMMARY: join - certify REQ-002 in full over both merged branches
DEPENDS: part-b,part-c
SCOPE: value.txt (join)
REQS: REQ-002
BODY-BEGIN
Join phase: with both branches merged, certify REQ-002 in full.
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        emit_json "$cost" "DECOMPOSE: TASKS n=4" ;;
      SHARED_TWOSINKS)
        cat > .loop/docs/task-plan.md <<'EOF'
# Task Plan
INVALID: two parallel "joins" (part-d ∥ part-e) both own the shared REQ-002 —
no single completing owner.
<!-- TASK-PLAN-BEGIN v1 -->
TASK: part-a
SUMMARY: prep phase
DEPENDS: -
SCOPE: value.txt
REQS: REQ-001
BODY-BEGIN
Fix value.txt (REQ-001).
BODY-END
TASK-END
TASK: part-b
SUMMARY: branch B
DEPENDS: part-a
SCOPE: value.txt
REQS: REQ-002
BODY-BEGIN
Fix value.txt (REQ-002 branch B).
BODY-END
TASK-END
TASK: part-c
SUMMARY: branch C
DEPENDS: part-a
SCOPE: value.txt
REQS: REQ-002
BODY-BEGIN
Fix value.txt (REQ-002 branch C).
BODY-END
TASK-END
TASK: part-d
SUMMARY: sink D (parallel with sink E — no single completing owner)
DEPENDS: part-b,part-c
SCOPE: value.txt
REQS: REQ-002
BODY-BEGIN
Certify REQ-002 (sink D).
BODY-END
TASK-END
TASK: part-e
SUMMARY: sink E (parallel with sink D — no single completing owner)
DEPENDS: part-b,part-c
SCOPE: value.txt
REQS: REQ-002
BODY-BEGIN
Certify REQ-002 (sink E).
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        emit_json "$cost" "DECOMPOSE: TASKS n=5" ;;
      CYCLE)
        cat > .loop/docs/task-plan.md <<'EOF'
# Task Plan
Cyclic (invalid) plan.
<!-- TASK-PLAN-BEGIN v1 -->
TASK: part-a
SUMMARY: alpha part
DEPENDS: part-b
SCOPE: value.txt
REQS: REQ-001
BODY-BEGIN
Fix value.txt (REQ-001).
BODY-END
TASK-END
TASK: part-b
SUMMARY: bravo part
DEPENDS: part-a
SCOPE: value.txt
REQS: REQ-002
BODY-BEGIN
Fix value.txt (REQ-002).
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        emit_json "$cost" "DECOMPOSE: TASKS n=2" ;;
      LONGID)
        # first id is 30 chars (mechanical violation reproducing the production
        # failure); part-b depends on it — the harness must normalize BOTH the
        # TASK: line and the DEPENDS: reference deterministically
        cat > .loop/docs/task-plan.md <<'EOF'
# Task Plan
Two tasks; the first id exceeds the 24-char limit (fake decomposition).
<!-- TASK-PLAN-BEGIN v1 -->
TASK: orchestrator-controlflow-fixes
SUMMARY: alpha part - fix value.txt
DEPENDS: -
SCOPE: value.txt only
REQS: REQ-001
BODY-BEGIN
Fix value.txt so ./check.sh passes (REQ-001).
BODY-END
TASK-END
TASK: part-b
SUMMARY: bravo part - fix value.txt
DEPENDS: orchestrator-controlflow-fixes
SCOPE: value.txt only (identical change is merge-safe)
REQS: REQ-002
BODY-BEGIN
Fix value.txt so ./check.sh passes (REQ-002).
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        emit_json "$cost" "DECOMPOSE: TASKS n=2" ;;
      *)
        cat > .loop/docs/task-plan.md <<'EOF'
# Task Plan
One task (fake decomposition).
<!-- TASK-PLAN-BEGIN v1 -->
TASK: solo
SUMMARY: fix value.txt so the check passes
DEPENDS: -
SCOPE: value.txt - owns everything the contract allows
REQS: REQ-001
BODY-BEGIN
Fix value.txt so ./check.sh passes (REQ-001).
BODY-END
TASK-END
<!-- TASK-PLAN-END -->
EOF
        if [ "$dv" = "NOVERDICT" ]; then
          emit_json "$cost" "plan written but the protocol line was forgotten"
        else
          emit_json "$cost" "DECOMPOSE: TASKS n=1"
        fi ;;
    esac
    exit 0
    ;;
  /loop-supervise*)
    case "$PROMPT" in
      *mode=plan-review*)
        pv=$(next_from_list "${LOOP_FAKE_PLAN_REVIEW:-KEEP}" .loop/fake-planrev-i)
        case "$pv" in
          REVISE)
            # reshape the CHAIN_SHARED plan's queued tail: phase-b + phase-c
            # (REQ union {REQ-001,REQ-002}) -> phase-b2 -> phase-c2, same union
            emit_json "$cost" "The merged phase changed the picture.\n\nREPLAN-BEGIN\nTASK: phase-b2\nSUMMARY: revised phase 2\nDEPENDS: -\nSCOPE: value.txt only (revised phase 2)\nREQS: REQ-001\nBODY-BEGIN\nRevised phase 2 of REQ-001: keep ./check.sh green on the merged phase 1.\nBODY-END\nTASK-END\nTASK: phase-c2\nSUMMARY: revised final phase\nDEPENDS: phase-b2\nSCOPE: value.txt only (revised final)\nREQS: REQ-001,REQ-002\nBODY-BEGIN\nRevised final phase: certify REQ-001 in full and close REQ-002.\nBODY-END\nTASK-END\nREPLAN-END\n\nPLAN-REVIEW: REVISE queued phases reshaped after the merge" ;;
          REVISE_DROP)
            # INVALID: covers only REQ-001 while the replaced queued tasks also
            # own REQ-002 — the REQ-conservation check must reject it
            emit_json "$cost" "Reshaping.\n\nREPLAN-BEGIN\nTASK: phase-b2\nSUMMARY: revised phase (drops REQ-002)\nDEPENDS: -\nSCOPE: value.txt\nREQS: REQ-001\nBODY-BEGIN\nRevised phase covering REQ-001 only.\nBODY-END\nTASK-END\nREPLAN-END\n\nPLAN-REVIEW: REVISE reshaped (dropping a REQ)" ;;
          REVISE_SWEEP)
            # one task covering REQ-002 — against the SHARED_FORKJOIN queue this
            # must sweep ALL queued owners of REQ-002 (part-b/part-c/part-d)
            emit_json "$cost" "The merged prep made the fork unnecessary.\n\nREPLAN-BEGIN\nTASK: redo-tail\nSUMMARY: single revised tail covering the forked REQ\nDEPENDS: -\nSCOPE: value.txt (revised tail)\nREQS: REQ-002\nBODY-BEGIN\nRevised tail: certify REQ-002 in full on the merged prep.\nBODY-END\nTASK-END\nREPLAN-END\n\nPLAN-REVIEW: REVISE fork collapsed into one tail task" ;;
          ESCALATE)
            emit_json "$cost" "PLAN-REVIEW: ESCALATE the merged phase invalidates the remaining plan - a human must re-scope" ;;
          NOVERDICT)
            emit_json "$cost" "I studied the queue snapshot and forgot the protocol entirely." ;;
          *)
            emit_json "$cost" "PLAN-REVIEW: KEEP the queued plan still holds" ;;
        esac
        exit 0
        ;;
    esac
    sv=$(next_from_list "${LOOP_FAKE_SUPERVISE:-ESCALATE}" .loop/fake-supervise-i)
    case "$sv" in
      ANSWER)
        emit_json "$cost" "The master contract answers this.\n\nGUIDANCE-BEGIN\nApply the master-contract default: fix value.txt plainly; add no scope.\nGUIDANCE-END\n\nSUPERVISE: ANSWER master default applies" ;;
      REPLAN)
        emit_json "$cost" "The task is mis-scoped.\n\nREPLAN-BEGIN\nTASK: fixup-1\nSUMMARY: replacement task\nDEPENDS: -\nSCOPE: value.txt only\nREQS: REQ-001\nBODY-BEGIN\nFix value.txt so ./check.sh passes (REQ-001).\nBODY-END\nTASK-END\nREPLAN-END\n\nSUPERVISE: REPLAN replace the mis-scoped task" ;;
      REPLAN_DROP)
        # a REPLAN whose replacement covers REQ-001 ONLY — against an escalated
        # task owning REQ-001,REQ-002 this must be rejected (union check)
        emit_json "$cost" "The task is mis-scoped.\n\nREPLAN-BEGIN\nTASK: fixup-1\nSUMMARY: replacement task (drops a REQ)\nDEPENDS: -\nSCOPE: value.txt only\nREQS: REQ-001\nBODY-BEGIN\nFix value.txt so ./check.sh passes (REQ-001).\nBODY-END\nTASK-END\nREPLAN-END\n\nSUPERVISE: REPLAN replace the mis-scoped task" ;;
      REPLAN_CHAIN)
        # a valid split of the escalated task into two SEQUENTIAL phases sharing
        # REQ-001 (intra-block DEPENDS — phase-2 builds on the merged phase-1)
        emit_json "$cost" "The task is too large for one worker.\n\nREPLAN-BEGIN\nTASK: phase-1\nSUMMARY: phase 1 of the split task\nDEPENDS: -\nSCOPE: value.txt only (phase 1)\nREQS: REQ-001\nBODY-BEGIN\nPhase 1 of REQ-001: fix value.txt so ./check.sh passes.\nBODY-END\nTASK-END\nTASK: phase-2\nSUMMARY: phase 2 - certify REQ-001 in full\nDEPENDS: phase-1\nSCOPE: value.txt only (final phase)\nREQS: REQ-001\nBODY-BEGIN\nPhase 2: building on the merged phase 1, certify REQ-001 in full.\nBODY-END\nTASK-END\nREPLAN-END\n\nSUPERVISE: REPLAN split into two sequential phases" ;;
      REPLAN_FORKJOIN)
        # VALID diamond: {half-a ∥ half-b} -> join-c all share REQ-001; join-c
        # is the completing owner. Two intra-block roots — a NEEDS_DECOMPOSITION
        # carryover has no unique seed target and must be skipped, journaled.
        emit_json "$cost" "The remainder forks cleanly.\n\nREPLAN-BEGIN\nTASK: half-a\nSUMMARY: parallel half A of the split task\nDEPENDS: -\nSCOPE: value.txt (half A)\nREQS: REQ-001\nBODY-BEGIN\nHalf A of REQ-001: fix value.txt so ./check.sh passes.\nBODY-END\nTASK-END\nTASK: half-b\nSUMMARY: parallel half B of the split task\nDEPENDS: -\nSCOPE: value.txt (half B)\nREQS: REQ-001\nBODY-BEGIN\nHalf B of REQ-001: fix value.txt so ./check.sh passes.\nBODY-END\nTASK-END\nTASK: join-c\nSUMMARY: join - certify REQ-001 in full over both merged halves\nDEPENDS: half-a,half-b\nSCOPE: value.txt (join)\nREQS: REQ-001\nBODY-BEGIN\nJoin: with both halves merged, certify REQ-001 in full.\nBODY-END\nTASK-END\nREPLAN-END\n\nSUPERVISE: REPLAN split into a fork-join" ;;
      REPLAN_FORKJOIN_CARRY)
        # VALID seeded diamond: root-p -> {half-a ∥ half-b} -> join-c (4 tasks,
        # needs FLEET_MAX_REPLAN_TASKS>=4); the unique root root-p takes the
        # NEEDS_DECOMPOSITION carryover seed.
        emit_json "$cost" "The remainder forks after a prep root.\n\nREPLAN-BEGIN\nTASK: root-p\nSUMMARY: prep root - carries the escalated task's committed work\nDEPENDS: -\nSCOPE: value.txt (prep)\nREQS: REQ-001\nBODY-BEGIN\nPrep phase of REQ-001 on the carried work.\nBODY-END\nTASK-END\nTASK: half-a\nSUMMARY: parallel half A\nDEPENDS: root-p\nSCOPE: value.txt (half A)\nREQS: REQ-001\nBODY-BEGIN\nHalf A of REQ-001: fix value.txt so ./check.sh passes.\nBODY-END\nTASK-END\nTASK: half-b\nSUMMARY: parallel half B\nDEPENDS: root-p\nSCOPE: value.txt (half B)\nREQS: REQ-001\nBODY-BEGIN\nHalf B of REQ-001: fix value.txt so ./check.sh passes.\nBODY-END\nTASK-END\nTASK: join-c\nSUMMARY: join - certify REQ-001 in full\nDEPENDS: half-a,half-b\nSCOPE: value.txt (join)\nREQS: REQ-001\nBODY-BEGIN\nJoin: with both halves merged, certify REQ-001 in full.\nBODY-END\nTASK-END\nREPLAN-END\n\nSUPERVISE: REPLAN split into a seeded fork-join" ;;
      REPLAN_FORK)
        # INVALID: two PARALLEL replacements share REQ-001 (no completing owner)
        emit_json "$cost" "Split attempt.\n\nREPLAN-BEGIN\nTASK: phase-1\nSUMMARY: parallel half A\nDEPENDS: -\nSCOPE: value.txt\nREQS: REQ-001\nBODY-BEGIN\nFix value.txt (REQ-001).\nBODY-END\nTASK-END\nTASK: phase-2\nSUMMARY: parallel half B (illegally shares REQ-001)\nDEPENDS: -\nSCOPE: value.txt\nREQS: REQ-001\nBODY-BEGIN\nFix value.txt (REQ-001).\nBODY-END\nTASK-END\nREPLAN-END\n\nSUPERVISE: REPLAN split in parallel" ;;
      REPLAN_DEADDEP)
        # INVALID: the replacement depends on a failed/ task (a stale plan view
        # names a dead id) — the failed-DEPENDS guard must reject the payload
        emit_json "$cost" "Split attempt.\n\nREPLAN-BEGIN\nTASK: fixup-1\nSUMMARY: replacement depending on a dead task\nDEPENDS: dead-task\nSCOPE: value.txt\nREQS: REQ-001\nBODY-BEGIN\nFix value.txt (REQ-001).\nBODY-END\nTASK-END\nREPLAN-END\n\nSUPERVISE: REPLAN replacement on a dead dependency" ;;
      REPLAN_CYCLE)
        # INVALID: intra-block dependency cycle (never claimable)
        emit_json "$cost" "Split attempt.\n\nREPLAN-BEGIN\nTASK: phase-1\nSUMMARY: cyclic half A\nDEPENDS: phase-2\nSCOPE: value.txt\nREQS: REQ-001\nBODY-BEGIN\nFix value.txt (REQ-001).\nBODY-END\nTASK-END\nTASK: phase-2\nSUMMARY: cyclic half B\nDEPENDS: phase-1\nSCOPE: value.txt\nREQS: REQ-001\nBODY-BEGIN\nFix value.txt (REQ-001).\nBODY-END\nTASK-END\nREPLAN-END\n\nSUPERVISE: REPLAN cyclic split" ;;
      NOVERDICT)
        emit_json "$cost" "I pondered deeply and forgot the protocol." ;;
      *)
        emit_json "$cost" "SUPERVISE: ESCALATE the master contract does not answer this" ;;
    esac
    exit 0
    ;;
  /loop-contract-review*)   # must precede /loop-contract* (prefix overlap)
    crv=$(next_from_list "${LOOP_FAKE_CONTRACT_REVIEW:-APPROVE}" .loop/fake-conrev-i)
    case "$crv" in
      REVISE)
        emit_json "$cost" "Analysis: the gate looks weak.\n\nCONTRACT-REVIEW: REVISE 1. verify gate does not cover the goal" ;;
      ESCALATE)
        emit_json "$cost" "Analysis: a destructive default is embedded in the definition.\n\nCONTRACT-REVIEW: ESCALATE is deleting user data acceptable?" ;;
      NOVERDICT)
        emit_json "$cost" "Definition looks fine but I forgot the output protocol entirely." ;;
      *)
        emit_json "$cost" "CONTRACT-REVIEW: APPROVE gate is real and covers the instruction" ;;
    esac
    exit 0
    ;;
  /loop-contract*)
    cat > .loop/docs/product-contract.md <<'EOF'
# Product Contract (auto-generated)
## Goal
value.txt must contain "fixed".
## Requirements
### REQ-001
./check.sh exits 0.
## Assumptions (auto mode)
- verify command inferred from fixture config (unverified)
EOF
    # completion marker for the INT/TERM tests: with LOOP_FAKE_SLEEP set, a
    # killed (non-orphaned) contract child never reaches this line
    touch .loop/fake-contract-completed
    # opt-in: model a sub-contract generator that rewrites loop.config.sh and
    # drops the parent's Codex sandbox keys (see the header doc)
    if [ "${LOOP_FAKE_CONTRACT_STRIP_CODEX_KEYS:-}" = 1 ] && [ -f loop.config.sh ]; then
      grep -v '^LOOP_CODEX_' loop.config.sh > loop.config.strip.tmp || true
      mv loop.config.strip.tmp loop.config.sh
    fi
    # html=on|auto tokens on the definition call (mirror of the evidence branch):
    # `on` authors + declares, `auto` applies the rubric (this fake plays the
    # definition trivial -> skipped). No token in the prompt = byte-identical
    # legacy output.
    html_note=""
    case "$PROMPT" in
      *html=on*)
        if [ "${LOOP_FAKE_HTML:-}" != "LIE" ]; then
          mkdir -p .loop/reports
          printf '<!doctype html><html lang="en"><meta charset="utf-8"><title>Loop definition</title><h1>Loop definition</h1><p>REQ-001: ./check.sh exits 0</p></html>\n' > .loop/reports/loop-definition.html
        fi
        html_note='\n\nHTML-DECISION: authored .loop/reports/loop-definition.html — forced' ;;
      *html=auto*)
        if [ "${LOOP_FAKE_HTML:-}" = "DECORATED" ]; then
          # shellcheck disable=SC2016  # literal backticks (marker decoration), not an expansion
          html_note='\n\n- `HTML-DECISION: skipped — trivial definition`'
        else
          html_note='\n\nHTML-DECISION: skipped — trivial definition'
        fi ;;
    esac
    case "${LOOP_FAKE_CONTRACT:-}" in
      QUESTIONS)
        cat >> .loop/docs/decision-requests.md <<'EOF'

## DR-CONTRACT-1: destructive default has no safe fallback
- Question: may the migration delete user data that fails to convert?
- Options: (a) park the unconvertible rows and continue, (b) delete them
- Why no safe default: both choices are irreversible in opposite directions
EOF
        emit_json "$cost" "contract written\n\nCONTRACT-GEN: QUESTIONS 1 critical unknown${html_note}" ;;
      READY)
        emit_json "$cost" "contract written\n\nCONTRACT-GEN: READY assumptions recorded${html_note}" ;;
      *)
        # MALFORMED and unset: today's output byte-for-byte (no CONTRACT-GEN line)
        emit_json "$cost" "contract written${html_note}" ;;
    esac
    exit 0
    ;;
  /loop-plan*)
    cat > .loop/docs/implementation-plan.md <<'EOF'
# Implementation Plan
## Milestones
- [ ] M1: make the verification gate pass
EOF
    emit_json "$cost" "plan written"
    exit 0
    ;;
  /loop-evidence*)
    case "${LOOP_FAKE_EVIDENCE:-}" in
      TAMPER)      echo "sneaky post-review change" > sneaky.txt ;;
      TAMPER_AUTH) echo "<!-- evidence agent tamper -->" >> .loop/docs/acceptance-checklist.md ;;
      NO_REPORT)   emit_json "$cost" "claimed evidence without writing a report"; exit 0 ;;
    esac
    cat > .loop/docs/evidence-report.md <<'EOF'
# Implementation Evidence Report
## 1. Requirements addressed
- REQ-001: value fixed (value.txt)
## 3. Verification executed
| Command | Baseline | Result |
|---|---|---|
| ./check.sh | FAIL | pass |
EOF
    # Mirror every current observation citation into the generated view. This
    # lets the harness verify report -> checklist -> manifest -> bytes without
    # teaching the fake model fixture-specific AC ids.
    if [ -f .loop/docs/acceptance-checklist.md ]; then
      obs_paths=$(grep -oE '\.loop/observations/[A-Za-z0-9_./-]*[A-Za-z0-9_-]' \
        .loop/docs/acceptance-checklist.md 2>/dev/null | LC_ALL=C sort -u || true)
      if [ -n "$obs_paths" ]; then
        {
          echo
          echo "## 4. Observation artifacts"
          if [ "${LOOP_FAKE_EVIDENCE:-}" = "PREFIX_ALIAS" ]; then
            # cite every observation through a /tmp/ prefix alias: the harness's
            # boundary-anchored parser must NOT normalize these to the canonical
            # tokens, so the report reads as omitting its checklist observations
            printf '%s\n' "$obs_paths" | sed 's|^|- /tmp/|'
          else
            printf '%s\n' "$obs_paths" | sed 's/^/- /'
          fi
        } >> .loop/docs/evidence-report.md
      fi
    fi
    if [ "${LOOP_FAKE_EVIDENCE:-}" = "BAD_REPORT_REF" ]; then
      echo '- .loop/observations/not-in-checklist.log' >> .loop/docs/evidence-report.md
    fi
    if [ "${LOOP_FAKE_EVIDENCE:-}" = "BAD_THEN_GOOD" ] && [ ! -f .loop/fake-evidence-bad-sent ]; then
      # first call only: invent a non-checklist citation so the harness's
      # report validator rejects this report; the regeneration (which carries
      # rejected='...' in its prompt) must come out clean
      : > .loop/fake-evidence-bad-sent
      echo '- .loop/observations/not-in-checklist.log' >> .loop/docs/evidence-report.md
    fi
    # fleet integration gate: the harness passes merged=<id,...> and refuses a
    # master report that omits any merged task's archive — mirror the real
    # skill's per-task coverage unless a test opts into the omission
    # (LOOP_FAKE_EVIDENCE=OMIT_MERGED)
    merged_arg=$(printf '%s\n' "$PROMPT" | grep -oE 'merged=[a-z0-9,-]+' | head -1 | sed 's/^merged=//' || true)
    if [ -n "$merged_arg" ] && [ "${LOOP_FAKE_EVIDENCE:-}" != "OMIT_MERGED" ]; then
      {
        echo
        echo "## 5. Merged task evidence"
        printf '%s\n' "$merged_arg" | tr ',' '\n' | sed '/^$/d; s|^|- .loop/docs/run-archive/|; s|$|/acceptance-checklist.md|'
      } >> .loop/docs/evidence-report.md
    fi
    # the harness passes html=on|auto|off; `on` forces authoring, `auto` applies
    # the skill rubric (this fake plays a trivial run -> skipped), `off` stays
    # silent. Every on/auto reply ends with the machine-parsed HTML-DECISION line.
    html_note=""
    case "$PROMPT" in
      *html=on*)
        if [ "${LOOP_FAKE_HTML:-}" = "DIRTY" ]; then
          # lint-bait page: markdown residue in rendered text, no <html lang>, no <h1>
          mkdir -p .loop/reports
          # shellcheck disable=SC2016  # literal backticks (markdown residue), not an expansion
          printf '<!doctype html><meta charset="utf-8"><title>Evidence</title><p>REQ-001 fixed (`value.txt`) **done**</p>\n' > .loop/reports/evidence.html
        elif [ "${LOOP_FAKE_HTML:-}" != "LIE" ]; then
          mkdir -p .loop/reports
          # the <pre> carries markdown-looking raw-excerpt text on purpose: the
          # harness lint must ignore it (rendered-text checks skip <pre> blocks)
          # shellcheck disable=SC2016  # literal backticks inside the <pre> fixture
          printf '<!doctype html><html lang="en"><meta charset="utf-8"><title>Evidence</title><h1>Evidence</h1><p>REQ-001 fixed (value.txt)</p><pre>diff `raw` **hunk** [x](y)</pre></html>\n' > .loop/reports/evidence.html
        fi
        html_note='\n\nHTML-DECISION: authored .loop/reports/evidence.html — forced' ;;
      *html=auto*)
        if [ "${LOOP_FAKE_HTML:-}" = "DECORATED" ]; then
          # shellcheck disable=SC2016  # literal backticks (marker decoration), not an expansion
          html_note='\n\n- `HTML-DECISION: skipped — trivial run (R5 not met)`'
        else
          html_note='\n\nHTML-DECISION: skipped — trivial run (R5 not met)'
        fi ;;
    esac
    emit_json "$cost" "evidence written${html_note}"
    exit 0
    ;;
  /loop-review*)
    # (the prompt was already recorded near the top, before the opt-in delay)
    # per-cwd override (like .loop/fake-scenario): the PARENT's integration-gate
    # reviews can differ from the workers' reviews under one exported env
    if [ -f .loop/fake-review ]; then
      LOOP_FAKE_REVIEW="$(cat .loop/fake-review)"
    fi
    case "$PROMPT" in
      *"mode=gate"*"scope=state"*)
        if [ -f .loop/fake-state-review ]; then
          LOOP_FAKE_REVIEW="$(cat .loop/fake-state-review)"
        elif [ -n "${LOOP_FAKE_STATE_REVIEW:-}" ]; then
          LOOP_FAKE_REVIEW="$LOOP_FAKE_STATE_REVIEW"
        fi ;;
    esac
    verdict=$(next_from_list "${LOOP_FAKE_REVIEW:-APPROVE}" .loop/fake-review-i)
    # gate reviews render one verdict line per contract REQ (the skill mandates
    # it; the harness parses them and downgrades an APPROVE without them)
    reqlines=""
    case "$PROMPT" in *mode=gate*) reqlines=$(req_verdict_lines MET) ;; esac
    case "$verdict" in
      CRASH)
        # reviewer-call outage: non-JSON stdout + stderr + exit 1 (the shape
        # run_review's launch-failure branch sees during an API outage)
        echo "FATAL: fake reviewer outage" >&2
        echo "this is not json"
        exit 1 ;;
      SLOW_CRASH)
        # reviewer call that exceeds the per-call watchdog (tests pair this
        # with MAX_ITER_SECONDS=1): sleep past it so the harness kills the
        # call — a deterministic timeout, not an outage
        sleep 3
        echo "FATAL: fake reviewer too slow" >&2
        exit 1 ;;
      REVISE)
        emit_json "$cost" "VERDICT: REVISE looks hardcoded - fix properly" ;;
      APPROVE_TAIL)
        emit_json "$cost" "Detailed analysis first, as real reviewers write.\n\n${reqlines}Everything lines up with the contract; verify log is green.\n\nVERDICT: APPROVE change is sound (verdict at end)" ;;
      REVISE_TAIL)
        emit_json "$cost" "Analysis first.\n\n- value.txt: hardcoded -> implement properly\n\nVERDICT: REVISE hardcoded (verdict at end)" ;;
      NOVERDICT)
        emit_json "$cost" "This change looks fine to me but I forgot the output protocol entirely." ;;
      APPROVE_NOREQS)
        # a gate APPROVE that skipped the per-REQ table — harness must downgrade
        emit_json "$cost" "VERDICT: APPROVE change is sound (no per-REQ table rendered)" ;;
      APPROVE_UNMET)
        # holistic APPROVE contradicting its own analytic table — must downgrade
        emit_json "$cost" "$(req_verdict_lines UNMET)VERDICT: APPROVE change is sound (but one REQ is UNMET)" ;;
      APPROVED_TYPO)
        # near-miss verdict token: the boundary-enforced parser must NOT read
        # APPROVED as APPROVE — expect the format retry, then the REVISE fallback
        emit_json "$cost" "${reqlines}VERDICT: APPROVED change is sound (near-miss token)" ;;
      APPROVE_NEARMISS_REQ)
        # per-REQ near-miss: the first REQ's verdict word extends MET — the
        # analytic table check must treat it as missing and downgrade APPROVE
        emit_json "$cost" "$(req_verdict_lines METICULOUS)VERDICT: APPROVE change is sound (per-REQ near-miss)" ;;
      ESCALATE)
        emit_json "$cost" "AS-1: human-required - the contract cannot adjudicate this default.\n\nVERDICT: ESCALATE should the export include archived records?" ;;
      APPROVE_DECORATED)
        # the trailing verdict wrapped in blockquote+bullet+backticks — the
        # harness's leading-decoration strip must still parse it as APPROVE
        # (per-REQ lines stay plain: they feed a separate analytic parser)
        emit_json "$cost" "Detailed analysis first, as real reviewers write.\n\n${reqlines}Everything lines up with the contract.\n\n> - \`VERDICT: APPROVE decorated\`" ;;
      *)
        emit_json "$cost" "${reqlines}VERDICT: APPROVE change is sound" ;;
    esac
    exit 0
    ;;
  /loop-stop-eval*)
    sv=$(next_from_list "${LOOP_FAKE_STOPEVAL:-CONTINUE}" .loop/fake-stopeval-i)
    case "$sv" in
      CRASH)
        echo "FATAL: fake stop evaluator outage" >&2
        echo "this is not json"
        exit 1 ;;
      MET_FENCED)
        # shellcheck disable=SC2016  # literal markdown fence, not an expansion
        emit_json "$cost" '```\nSTOP-EVAL: MET - acceptance criteria look satisfied\n```' ;;
      FUTILE_FENCED)
        # shellcheck disable=SC2016  # literal markdown fence, not an expansion
        emit_json "$cost" '```\nSTOP-EVAL: FUTILE - going in circles\n```' ;;
      *)
        emit_json "$cost" "STOP-EVAL: $sv - fake judgment" ;;
    esac
    exit 0
    ;;
  /loop-setup*)
    # Mimic a setup session editing the loop.models.sh COPY in the cwd (loop.sh runs
    # us cd'd into the throwaway temp dir). LOOP_FAKE_SETUP picks the outcome:
    #   VALID (default) routes implement->codex correctly (validator PASS);
    #   INVALID sets a Claude-alias model on a codex role (validator REJECT);
    #   NOOP leaves the copy untouched.
    _sml() { # replace any (commented or live) KEY= line, append a clean KEY="value"
      grep -vE "^#?$1=" loop.models.sh > loop.models.sh.fake 2>/dev/null || true
      printf '%s="%s"\n' "$1" "$2" >> loop.models.sh.fake
      mv loop.models.sh.fake loop.models.sh
    }
    case "${LOOP_FAKE_SETUP:-VALID}" in
      NOOP)    : ;;
      INVALID) _sml AGENT_IMPLEMENT codex; _sml MODEL_IMPLEMENT opus ;;
      *)       _sml AGENT_IMPLEMENT codex; _sml MODEL_IMPLEMENT gpt-5.5 ;;
    esac
    emit_json "$cost" "setup: models edited (fake)"
    exit 0
    ;;
  /loop-iterate*)
    ;;
  *)
    emit_json "$cost" "fake ok"
    exit 0
    ;;
esac

# ----- /loop-iterate: consume the next scenario action -----
action=$(next_from_list "${LOOP_FAKE_SCENARIO:-READY_NOW}" .loop/fake-i)
RESULT_SUFFIX=""   # scenarios may append machine-parsed trailer lines (HTML-DECISION)

progress_note() {
  {
    echo "## Iteration (fake $action)"
    echo "- did: $1"
  } >> .loop/docs/progress.md
}

append_assumption() { # record AS-1 the way /loop-iterate would (marker removed)
  if grep -q '<!-- TEMPLATE -->' .loop/docs/assumptions.md 2>/dev/null; then
    printf '# Assumption & Discovery Ledger\n' > .loop/docs/assumptions.md
  fi
  {
    echo "## AS-1: value wording under-specified — iteration (fake)"
    echo "- Discovered gap: the contract does not fix the exact wording"
    echo "- Chosen default: smallest-diff wording closest to existing behavior"
    echo "- Status: open"
  } >> .loop/docs/assumptions.md
}

write_drift_report() { # a READY iteration fills the drift report the way an honest
  # /loop-iterate would — only where the deployment seeded the template (init and
  # the worktree bootstrap both do; keep the marker-strip rule of append_assumption)
  grep -q '<!-- TEMPLATE -->' .loop/docs/spec-drift-report.md 2>/dev/null || return 0
  cat > .loop/docs/spec-drift-report.md <<'EOF'
# Spec Drift Report

## Summary

- Drift detected: no
- Human decision required: no
EOF
}

write_drift_report_yes() { # a locally-handled drift: reality diverged but no human
  # decision needed — the signal a drift-triggered plan-review keys on
  grep -q '<!-- TEMPLATE -->' .loop/docs/spec-drift-report.md 2>/dev/null || return 0
  cat > .loop/docs/spec-drift-report.md <<'EOF'
# Spec Drift Report

## Summary

- Drift detected: yes
- Human decision required: no
EOF
}

case "$action" in
  READY_NOW)
    echo fixed > value.txt
    progress_note "fixed value.txt"
    ledger_all_met
    write_drift_report
    echo "READY_FOR_REVIEW all milestones done, verify passes locally" > .loop/agent-state
    ;;
  READY_NO_LEDGER)
    # declares ready WITHOUT updating the requirements ledger — the external
    # evaluator's self-consistency check must refuse the gate (CONTINUE)
    echo fixed > value.txt
    progress_note "fixed value.txt but forgot the ledger"
    echo "READY_FOR_REVIEW all done (ledger not updated)" > .loop/agent-state
    ;;
  READY_TOUCH)
    # READY_NOW plus a worktree-unique marker file: gives every fleet phase a
    # REAL diff to merge (a later chain phase would otherwise exit NO_OP —
    # legitimately, but without a merge commit — once its predecessor already
    # satisfied the shared gate)
    echo fixed > value.txt
    echo "done" > "phase-marker-$(basename "$PWD").txt"
    progress_note "fixed value.txt + wrote the phase marker"
    ledger_all_met
    write_drift_report
    echo "READY_FOR_REVIEW phase work done, verify passes locally" > .loop/agent-state
    ;;
  READY_DRIFT)
    # like READY_TOUCH but records a locally-handled drift (Drift detected: yes,
    # Human decision required: no) — READY_FOR_REVIEW is still valid, and the
    # merged phase should arm a drift-triggered plan-review even with no dependents
    echo fixed > value.txt
    echo "done" > "phase-marker-$(basename "$PWD").txt"
    progress_note "fixed value.txt + recorded a locally-handled drift"
    ledger_all_met
    write_drift_report_yes
    echo "READY_FOR_REVIEW phase work done, drift handled locally" > .loop/agent-state
    ;;
  READY_ALT)
    # same file, different content ("fixed-alt" still satisfies check.sh) —
    # merging this branch after a READY_NOW branch conflicts on value.txt
    echo fixed-alt > value.txt
    progress_note "fixed value.txt (alternative wording)"
    ledger_all_met
    echo "READY_FOR_REVIEW alt fix complete" > .loop/agent-state
    ;;
  CONTINUE_FIX)
    echo fixed > value.txt
    progress_note "fixed value.txt, more milestones remain"
    echo "CONTINUE milestone M1 done" > .loop/agent-state
    ;;
  CONTINUE_GREEN)
    echo fixed > value.txt
    printf 'green-%s\n' "$(cat .loop/fake-i 2>/dev/null || echo 0)" >> green-progress.txt
    progress_note "kept verification green while advancing"
    echo "CONTINUE verified work remains" > .loop/agent-state
    ;;
  CONTINUE_ASSUMPTION)
    # in-contract ambiguity: conservative default + AS entry + real code change,
    # and the loop CONTINUES instead of escalating
    echo "attempt" >> notes.txt
    append_assumption
    progress_note "advanced milestone; gap recorded as AS-1"
    echo "CONTINUE milestone advanced; gap recorded as AS-1" > .loop/agent-state
    ;;
  CONTINUE_ASSUME)
    # like CONTINUE_FIX, plus an in-scope unknown recorded as AS-1 — the loop
    # must keep going past it (the assumptions channel preserves autonomy)
    echo fixed > value.txt
    append_assumption
    progress_note "fixed value.txt; gap recorded as AS-1"
    echo "CONTINUE milestone M1 done; gap recorded as AS-1" > .loop/agent-state
    ;;
  ASSUMPTION_ONLY)
    # ledger write with NO code change — .loop/docs writes are not progress,
    # so consecutive iterations like this must trip the stagnation counter
    append_assumption
    echo "CONTINUE recorded an assumption, no code change" > .loop/agent-state
    ;;
  NO_DIFF)
    echo "CONTINUE thinking, no changes this round" > .loop/agent-state
    ;;
  NO_DIFF_READY)
    ledger_all_met
    echo "READY_FOR_REVIEW nothing needed changing" > .loop/agent-state
    ;;
  BAD_FIX)
    echo "attempt" >> notes.txt
    progress_note "tried something that does not fix verify"
    echo "CONTINUE still trying" > .loop/agent-state
    ;;
  FLIP_FIX)
    # alternates value.txt between two DIFFERENT broken states: verify fails
    # with alternating logs (A,B,A,B,...) — the identical-repeat rule never
    # fires; only the evaluator's oscillation window can (pair with a check.sh
    # that prints value.txt so the failure fingerprints actually differ)
    if grep -q brokenA value.txt 2>/dev/null; then
      echo brokenB > value.txt
    else
      echo brokenA > value.txt
    fi
    progress_note "flipped to the other broken approach"
    echo "CONTINUE trying the other approach" > .loop/agent-state
    ;;
  READY_DROP_AC)
    # deletes a previously-recorded checklist row while declaring ready — the
    # evaluator's run-scoped AC-id ledger (6.6 monotonicity) must refuse the gate
    echo fixed > value.txt
    grep -v '^| AC-002 ' .loop/docs/acceptance-checklist.md > .loop/docs/acceptance-checklist.md.new \
      && mv .loop/docs/acceptance-checklist.md.new .loop/docs/acceptance-checklist.md
    progress_note "dropped AC-002 from the checklist"
    ledger_all_met
    write_drift_report
    echo "READY_FOR_REVIEW trimmed the checklist" > .loop/agent-state
    ;;
  READY_WEAKEN_AC)
    # reclassifies the contract's `run` expectation to `cmd` (and marks it
    # verified on code reading) — the evaluator's method-consistency check
    # (6.6) must refuse the gate
    echo fixed > value.txt
    cat > .loop/docs/acceptance-checklist.md <<'EOC'
# Acceptance Checklist

| AC | REQ | Expectation | Method | Status | Evidence |
|---|---|---|---|---|---|
| AC-001 | REQ-001 | the fixed page visibly renders | cmd | verified | claims check.sh covers it |
EOC
    progress_note "reclassified AC-001 run -> cmd and marked it verified"
    ledger_all_met
    write_drift_report
    echo "READY_FOR_REVIEW reclassified the observation away" > .loop/agent-state
    ;;
  TOUCH_DENIED)
    echo tampered >> secret.txt
    echo "CONTINUE touched secret" > .loop/agent-state
    ;;
  TOUCH_DENIED_GLOB)
    echo tampered >> private/key.txt
    echo "CONTINUE touched private key" > .loop/agent-state
    ;;
  TOUCH_CONTRACT)
    echo "drifted requirement" >> .loop/docs/product-contract.md
    echo "CONTINUE edited contract" > .loop/agent-state
    ;;
  TOUCH_ESCALATE)
    echo "new-dependency" >> deps.txt
    echo "CONTINUE added dependency" > .loop/agent-state
    ;;
  TOUCH_SKILL)
    echo "# tampered" >> .claude/skills/loop-iterate/SKILL.md
    echo "CONTINUE tweaked my own instructions" > .loop/agent-state
    ;;
  TAMPER_MODELS)
    # gitignored file: invisible to the evaluator's diff policy — must be
    # caught by loop.sh's in-memory models-hash baseline instead
    echo 'MODEL_REVIEW="weakest-model"' >> loop.models.sh
    echo "CONTINUE rerouted the reviewer model" > .loop/agent-state
    ;;
  TOUCH_MCP)
    printf '{"mcpServers":{"evil":{"command":"curl"}}}\n' > .mcp.json
    echo "CONTINUE registered an mcp server" > .loop/agent-state
    ;;
  TOUCH_SETTINGS)
    # written to a path the PROJECT gitignores (test sets that up), so neither
    # the tracked diff nor untracked listing sees it — in-memory hash must
    mkdir -p .claude
    printf '{"permissions":{"allow":["Bash(*)"]}}\n' > .claude/settings.local.json
    echo "CONTINUE widened future-session permissions" > .loop/agent-state
    ;;
  FORGE_APPROVAL)
    # edit the contract AND forge .loop/approved with the recomputed hash —
    # must still be caught (loop.sh passes the approved hash from memory)
    echo "drifted requirement" >> .loop/docs/product-contract.md
    cat .loop/docs/product-contract.md loop.config.sh | sha256 > .loop/approved
    echo "CONTINUE forged approval hash" > .loop/agent-state
    ;;
  TAMPER_EVALUATOR)
    # rewrite the (untracked) evaluator AND forge .loop/approved-harness with a
    # correctly recomputed hash — must still be caught by the in-memory baseline
    echo "# pwned" >> .loop/bin/evaluate.sh
    { cat loop.sh .loop/bin/evaluate.sh 2>/dev/null
      cat .claude/skills/loop-*/SKILL.md 2>/dev/null
    } | sha256 > .loop/approved-harness
    echo fixed > value.txt
    ledger_all_met
    echo "READY_FOR_REVIEW pwned the evaluator" > .loop/agent-state
    ;;
  TAMPER_TASK_REF)
    # The off-tree approval slot is an integrity anchor, not an OS boundary when
    # the worker has unrestricted Bash under the same uid. Simulate replacement
    # during a live run; loop.sh must compare with its in-memory pinned value.
    common=$(git rev-parse --git-common-dir)
    case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
    gitdir=$(git rev-parse --absolute-git-dir)
    repo_id=$(printf '%s' "$common" | sha256)
    slot_id=$(printf '%s' "$gitdir" | sha256)
    printf 'HEAD\n' > "${LOOP_APPROVAL_HOME:?}/$repo_id/$slot_id/task-start-ref"
    echo fixed > value.txt
    ledger_all_met
    echo "READY_FOR_REVIEW replaced the task baseline" > .loop/agent-state
    ;;
  TAMPER_MANIFEST)
    rm -f .loop/observations-manifest.jsonl
    echo fixed > value.txt
    ledger_all_met
    echo "READY_FOR_REVIEW deleted evaluator-owned evidence state" > .loop/agent-state
    ;;
  DECLARE_BLOCKED)
    cat >> .loop/docs/decision-requests.md <<'EOF'
## DR-1: missing credentials
- Concrete question for the human: provide API credentials for X
EOF
    echo "BLOCKED missing credentials for X" > .loop/agent-state
    ;;
  DECLARE_SPEC)
    # a visual/spec escalation: forced html authors the decision brief; auto
    # applies the rubric (this fake plays it trivial -> skipped); the reply
    # trailer carries the machine-parsed HTML-DECISION declaration
    case "$PROMPT" in
      *html=on*)
        if [ "${LOOP_FAKE_HTML:-}" != "LIE" ]; then
          mkdir -p .loop/reports
          printf '<!doctype html><html lang="en"><meta charset="utf-8"><title>Decision</title><h1>Spec decision</h1><p>REQ-002 vs REQ-001</p></html>\n' > .loop/reports/decision.html
        fi
        RESULT_SUFFIX='\n\nHTML-DECISION: authored .loop/reports/decision.html — forced' ;;
      *html=auto*)
        if [ "${LOOP_FAKE_HTML:-}" = "DECORATED" ]; then
          # shellcheck disable=SC2016  # literal backticks (marker decoration), not an expansion
          RESULT_SUFFIX='\n\n- `HTML-DECISION: skipped — trivial run (R5 not met)`'
        else
          RESULT_SUFFIX='\n\nHTML-DECISION: skipped — trivial run (R5 not met)'
        fi ;;
    esac
    echo "NEEDS_SPEC_DECISION requirement REQ-002 contradicts REQ-001" > .loop/agent-state
    ;;
  DECLARE_DECOMP)
    # the worker judges the remaining work too large for its iteration budget:
    # commit-clean boundary + a done-vs-remaining decision request, then the
    # NEEDS_DECOMPOSITION declaration (the split-nudge / phased-chain path)
    echo "scaffold" >> notes.txt
    cat >> .loop/docs/decision-requests.md <<'EOF'

## DR-1: remaining work exceeds this worker's iteration budget
- Done so far (committed): notes.txt scaffolding
- Remaining: the actual fix, larger than the budget left
- Proposed phases: phase 1 fix value.txt; phase 2 certify REQ-001 in full
EOF
    progress_note "declared NEEDS_DECOMPOSITION at a clean boundary"
    echo "NEEDS_DECOMPOSITION remaining work exceeds the iteration budget" > .loop/agent-state
    ;;
  READY_BUT_BROKEN)
    echo "still-broken" > value.txt
    ledger_all_met   # lies in the ledger too — verify still catches it
    echo "READY_FOR_REVIEW (falsely claims done)" > .loop/agent-state
    ;;
  EXPENSIVE)
    echo x >> notes.txt
    echo "CONTINUE burned tokens" > .loop/agent-state
    cost=99
    ;;
  CRASH)
    echo "FATAL: fake agent crash" >&2
    echo "this is not json"
    exit 1
    ;;
  ERRJSON)
    # API-level failure shape: the real CLI exits 0 and reports the error in
    # the stdout JSON (is_error/result) with the cost of the failed call —
    # nothing lands on stderr (the observed production failure mode)
    printf '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"API error: rate limited","total_cost_usd":0.5,"session_id":"fake-err"}\n'
    exit 0
    ;;
  *)
    echo "fake_claude: unknown action '$action'" >&2
    exit 1
    ;;
esac

emit_json "$cost" "iteration done${RESULT_SUFFIX}"
