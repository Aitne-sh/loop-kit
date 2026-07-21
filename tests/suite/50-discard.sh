#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- whole-plan discard + conservative rollback ----------

section "discard: non-TTY needs a choice; keep cancels an unstarted plan but preserves manual new/"
make_fixture discard-unstarted
seed_unstarted_discard_plan discard-a
./loop.sh add "manual side task must survive" >/dev/null 2>&1
manual_id=$(fleet_task_id manual-side)
before=$(git rev-parse HEAD)
RC=0
./loop.sh discard >"$WORK/discard-unstarted-noflag.out" 2>&1 </dev/null || RC=$?
check "non-TTY discard without a choice exits 2" discard-unstarted 2 "$RC"
check "choice refusal leaves HEAD unchanged" discard-unstarted "$before" "$(git rev-parse HEAD)"
if [ -f .loop/fleet/queue/new/discard-a.md ] \
   && [ -f ".loop/fleet/queue/new/$manual_id.md" ] \
   && [ ! -e .loop/fleet/discard-request.env ] \
   && ! grep -q '^STOPPED_BY=' .loop/fleet/runs/discard-a.env; then
  ok "choice refusal stops/deletes nothing and publishes no request"
else
  bad "non-TTY choice refusal mutated the plan/manual queue" discard-unstarted
fi
if grep -q 'requires an explicit rollback choice' "$WORK/discard-unstarted-noflag.out"; then
  ok "choice refusal explains the required non-TTY flags"
else
  bad "non-TTY refusal did not explain --rollback/--keep-changes" discard-unstarted
fi
RC=0
./loop.sh discard --keep-changes >"$WORK/discard-unstarted-keep.out" 2>&1 </dev/null || RC=$?
check "unstarted keep discard exits 0" discard-unstarted 0 "$RC"
check "unstarted plan ends CANCELLED" discard-unstarted CANCELLED "$(cat .loop/state)"
archive=$(discard_archive_dir)
if [ -n "$archive" ] && [ -f "$archive/tasks/discard-a/task.md" ] \
   && grep -q '^DISPATCHED=0$' "$archive/discard.env" \
   && grep -q '^FINAL_STATUS=NOT_REQUESTED$' "$archive/result.env"; then
  ok "cancellation archive preserves the undispatched plan and keep result"
else
  bad "unstarted cancellation archive missing/incomplete ($archive)" discard-unstarted
fi
if [ ! -e .loop/docs/task-plan.md ] \
   && [ ! -e .loop/fleet/queue/new/discard-a.md ] \
   && [ ! -e .loop/fleet/runs/discard-a.env ] \
   && [ ! -e .loop/fleet/plan-authority.env ] \
   && [ ! -e .loop/fleet/discard-request.env ]; then
  ok "planned queue, task plan, authority, and request are removed as one unit"
else
  bad "planned discard execution state survived" discard-unstarted
fi
if [ -n "$manual_id" ] && [ -f ".loop/fleet/queue/new/$manual_id.md" ] \
   && [ -f ".loop/fleet/runs/$manual_id.env" ] \
   && [ "$(qcount new)" = 1 ]; then
  ok "manual new task is retained outside the cancelled plan"
else
  bad "manual new task was removed with the plan" discard-unstarted
fi

# Recreate the final-unlink crash window: the result commit and archive exist,
# request WAL remains, authority is already gone, and cleanup is incomplete.
discard_commit=$(git rev-parse HEAD)
cp "$archive/tasks/discard-a/task.md" .loop/fleet/queue/new/discard-a.md
cp "$archive/tasks/discard-a/run.env" .loop/fleet/runs/discard-a.env
cp "$archive/discard-request.env" .loop/fleet/discard-request.env
echo FLEET_RUNNING > .loop/state
RC=0
./loop.sh discard --keep-changes >"$WORK/discard-final-retry.out" 2>&1 </dev/null || RC=$?
check "authority-missing finalization retry exits 0" discard-final-retry 0 "$RC"
check "finalization retry creates no duplicate archive commit" discard-final-retry "$discard_commit" "$(git rev-parse HEAD)"
if [ ! -e .loop/fleet/queue/new/discard-a.md ] \
   && [ ! -e .loop/fleet/runs/discard-a.env ] \
   && [ ! -e .loop/fleet/plan-authority.env ] \
   && [ ! -e .loop/fleet/discard-request.env ] \
   && [ -f ".loop/fleet/queue/new/$manual_id.md" ]; then
  ok "request WAL reconstructs missing authority and completes idempotent cleanup"
else
  bad "authority-missing finalization retry did not converge" discard-final-retry
fi

section "discard: a live orchestration stops its supervisor and attributed worker before queue removal"
make_orch_fixture discard-live 2
printf 'WORKTREE_SETUP_CMD="echo 20 > .loop/fake-sleep"\n' >> fleet.config.sh
./loop.sh approve >/dev/null
RC=0
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_DECOMPOSE=TWO_PAR LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh run >"$WORK/discard-live-run.out" 2>&1 </dev/null &
ORCH=$!
live_id=""
live_pid=""
n=0
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  for candidate in part-a part-b; do
    case "$(fleet_phase "$candidate")" in
      CONTRACT_GEN|RUNNING)
        live_pid=$(grep -E '^PID=' ".loop/fleet/runs/$candidate.env" 2>/dev/null | tail -1 | cut -d= -f2)
        if [ -n "$live_pid" ] && kill -0 "$live_pid" 2>/dev/null; then
          live_id="$candidate"
          break 2
        fi ;;
    esac
  done
  sleep 0.2
  n=$((n + 1))
done
if [ -n "$live_id" ] && [ -s .loop/fleet/plan-dispatched.env ]; then
  ok "live discard fixture reached an attributed worker boundary"
else
  bad "live discard fixture never reached an attributed worker boundary" discard-live
fi
discard_rc=0
./loop.sh discard --keep-changes >"$WORK/discard-live.out" 2>&1 </dev/null || discard_rc=$?
wait_sup "$ORCH" discard-live
case "$discard_rc" in
  0|4) ok "live discard completes cancellation (exit $discard_rc)" ;;
  *) bad "live discard failed before cancellation (exit $discard_rc)" discard-live ;;
esac
check "live supervisor exits through TERM handling" discard-live 130 "$RC"
if [ -n "$live_pid" ] && ! kill -0 "$live_pid" 2>/dev/null \
   && [ "$(cat .loop/state)" = CANCELLED ] \
   && [ "$(qcount new)" = 0 ] && [ "$(qcount claimed)" = 0 ] \
   && [ ! -e .loop/fleet/plan-authority.env ] \
   && [ ! -e .loop/fleet/discard-request.env ]; then
  ok "discard stops the live worker and removes active plan authority"
else
  bad "live worker/supervisor or planned queue survived discard" discard-live
fi

section "discard rollback: SAFE reviewer produces one inverse commit without rewriting history"
make_discard_merged_fixture discard-rollback-safe
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_ROLLBACK_REVIEW=SAFE \
  ./loop.sh discard --rollback >"$WORK/discard-rollback-safe.out" 2>&1 </dev/null || RC=$?
check "safe rollback discard exits 0" discard-rollback-safe 0 "$RC"
check "safe rollback ends CANCELLED" discard-rollback-safe CANCELLED "$(cat .loop/state)"
check "rollback appends exactly one first-parent commit" discard-rollback-safe 1 "$(git rev-list --first-parent --count "$DISCARD_PRE..HEAD")"
if git diff --quiet "$DISCARD_SOURCE" HEAD -- . \
     ':(exclude).loop' ':(exclude).claude' ':(exclude).agents' ':(exclude).codex'; then
  ok "inverse commit restores the exact plan-source product tree"
else
  bad "safe rollback did not restore the source product tree" discard-rollback-safe
fi
if git merge-base --is-ancestor "$DISCARD_SOURCE" HEAD \
   && git merge-base --is-ancestor "$DISCARD_MERGE_COMMIT" HEAD; then
  ok "rollback keeps source and plan merge in history (no reset/rewrite)"
else
  bad "rollback rewrote or detached the existing history" discard-rollback-safe
fi
archive=$(discard_archive_dir)
if [ -n "$archive" ] && grep -q '^FINAL_STATUS=ROLLED_BACK$' "$archive/result.env" \
   && grep -q '^STATUS=SAFE$' "$archive/rollback-assessment.env" \
   && git show -s --format=%B HEAD | grep -q '^Loop-Discard-Status: APPLIED$'; then
  ok "archive and inverse-commit trailers record the reviewed rollback"
else
  bad "safe rollback receipts missing ($archive)" discard-rollback-safe
fi
if grep -q '/loop-rollback-review' .loop/fake-rollback-prompts 2>/dev/null; then
  ok "independent rollback reviewer ran"
else
  bad "SAFE rollback bypassed the reviewer" discard-rollback-safe
fi
check "safe rollback removes new queue" discard-rollback-safe 0 "$(qcount new)"
check "safe rollback removes done queue" discard-rollback-safe 0 "$(qcount "done")"

section "discard rollback: dispatched net-zero history still requires independent side-effect review"
make_discard_merged_fixture discard-rollback-netzero
netzero_pre=$(git rev-parse HEAD)
netzero_wt="$WORK/discard-rollback-netzero-loops/phase-b"
git worktree add -q -b loop/phase-b "$netzero_wt" "$netzero_pre"
printf 'broken\n' > "$netzero_wt/value.txt"
git -C "$netzero_wt" rm -q phase-marker-phase-a.txt
git -C "$netzero_wt" add value.txt
git -C "$netzero_wt" commit -q -m "worker: restore source product bytes"
netzero_tip=$(git -C "$netzero_wt" rev-parse HEAD)
git merge --no-ff --no-commit loop/phase-b >/dev/null
mkdir -p .loop/docs/run-archive/phase-b
cat > .loop/docs/run-archive/phase-b/integration.env <<EOF
VERSION=1
PLAN_AUTHORITY=$DISCARD_AUTHORITY
PLAN_SOURCE_REF=$DISCARD_SOURCE
PLAN_SOURCE_REFNAME=$DISCARD_REFNAME
TASK_ID=phase-b
PRE_MERGE_HEAD=$netzero_pre
BRANCH_TIP=$netzero_tip
BASE_REF=$netzero_pre
EOF
git add .loop/docs/run-archive/phase-b/integration.env
git commit -q \
  -m "fleet: merge phase-b" \
  -m "Loop-Plan-Authority: $DISCARD_AUTHORITY
Loop-Task: phase-b
Loop-Plan-Source: $DISCARD_SOURCE
Loop-Plan-Refname: $DISCARD_REFNAME
Loop-Pre-Merge-Head: $netzero_pre
Loop-Branch-Tip: $netzero_tip"
netzero_merge=$(git rev-parse HEAD)
mv .loop/fleet/queue/new/phase-b.md .loop/fleet/queue/done/phase-b.md
cat >> .loop/fleet/runs/phase-b.env <<EOF
WT=$netzero_wt
BRANCH=loop/phase-b
BASE_REF=$netzero_pre
MERGE_COMMIT=$netzero_merge
PHASE=DONE
EOF
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_ROLLBACK_REVIEW=SAFE \
  ./loop.sh discard --rollback >"$WORK/discard-rollback-netzero.out" 2>&1 </dev/null || RC=$?
check "reviewed net-zero discard exits 0" discard-rollback-netzero 0 "$RC"
archive=$(discard_archive_dir)
if git diff --quiet "$DISCARD_SOURCE" HEAD -- . \
     ':(exclude).loop' ':(exclude).claude' ':(exclude).agents' ':(exclude).codex' \
   && [ -f .loop/fake-rollback-prompts ] \
   && [ "$(wc -l < "$archive/rollback-review/commit-task-set.txt" | tr -d ' ')" = 2 ] \
   && grep -q '^FINAL_STATUS=NOT_NEEDED$' "$archive/result.env" \
   && grep -q '^STATUS=NOT_NEEDED$' "$archive/rollback-assessment.env"; then
  ok "net-zero implementation history is provenance-checked and side-effect-reviewed"
else
  bad "net-zero implementation bypassed review or lost its commit/task evidence" discard-rollback-netzero
fi

section "discard rollback: a manual/parallel product commit makes rollback unavailable but still cancels"
make_discard_merged_fixture discard-rollback-parallel
printf 'parallel owner change\n' > parallel.txt
git add parallel.txt
git commit -q -m "manual: parallel product change"
parallel_commit=$(git rev-parse HEAD)
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_ROLLBACK_REVIEW=SAFE \
  ./loop.sh discard --rollback >"$WORK/discard-rollback-parallel.out" 2>&1 </dev/null || RC=$?
check "parallel-product rollback reports unavailable (exit 4)" discard-rollback-parallel 4 "$RC"
check "unavailable rollback still ends CANCELLED" discard-rollback-parallel CANCELLED "$(cat .loop/state)"
archive=$(discard_archive_dir)
if [ -f parallel.txt ] && grep -q 'parallel owner change' parallel.txt \
   && git merge-base --is-ancestor "$parallel_commit" HEAD \
   && [ "$(cat value.txt)" = fixed ]; then
  ok "manual and plan product changes are retained when rollback is unavailable"
else
  bad "unavailable rollback lost or rewrote product changes" discard-rollback-parallel
fi
if [ -n "$archive" ] && grep -q '^FINAL_STATUS=UNAVAILABLE$' "$archive/result.env" \
   && grep -q 'manual, parallel, or has invalid plan provenance' "$archive/result.env"; then
  ok "archive records deterministic provenance refusal"
else
  bad "parallel rollback refusal missing from archive ($archive)" discard-rollback-parallel
fi
if [ ! -e .loop/fake-rollback-prompts ]; then
  ok "deterministic provenance veto happens before the AI reviewer"
else
  bad "AI reviewer ran despite the deterministic parallel-commit veto" discard-rollback-parallel
fi
check "parallel refusal still removes new queue" discard-rollback-parallel 0 "$(qcount new)"
check "parallel refusal still removes done queue" discard-rollback-parallel 0 "$(qcount "done")"

section "discard rollback: a claimed manual dependent is parked and makes rollback unavailable"
make_discard_merged_fixture discard-rollback-manual-peer
./loop.sh add "manual claimed dependent" --after phase-a >/dev/null 2>&1
manual_peer=$(fleet_task_id manual-claimed)
manual_wt="$WORK/discard-rollback-manual-peer-loops/$manual_peer"
git worktree add -q -b "loop/$manual_peer" "$manual_wt" HEAD
mv ".loop/fleet/queue/new/$manual_peer.md" ".loop/fleet/queue/claimed/$manual_peer.md"
cat >> ".loop/fleet/runs/$manual_peer.env" <<EOF
WT=$manual_wt
BRANCH=loop/$manual_peer
BASE_REF=$(git rev-parse HEAD)
PHASE=INTERRUPTED
EOF
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_ROLLBACK_REVIEW=SAFE \
  ./loop.sh discard --rollback >"$WORK/discard-rollback-manual-peer.out" 2>&1 </dev/null || RC=$?
check "claimed manual dependency makes rollback unavailable (exit 4)" discard-rollback-manual-peer 4 "$RC"
archive=$(discard_archive_dir)
if [ -f ".loop/fleet/queue/failed/$manual_peer.md" ] \
   && [ -d "$manual_wt" ] \
   && [ "$(fleet_phase "$manual_peer")" = DISCARD_DEP_CANCELLED ] \
   && grep -q '^DISCARD_CANCELLED_DEPS=phase-a$' ".loop/fleet/runs/$manual_peer.env" \
   && grep -q '^DEPENDS_ON=$' ".loop/fleet/runs/$manual_peer.env" \
   && grep -q 'depends on cancelled planned task phase-a' "$archive/result.env"; then
  ok "claimed manual peer is preserved, detached from the cancelled dependency, and reviewable"
else
  bad "claimed manual peer was lost or kept a dangling planned dependency" discard-rollback-manual-peer
fi
if [ ! -e .loop/fake-rollback-prompts ] \
   && [ "$(qcount new)" = 0 ] && [ "$(qcount "done")" = 0 ]; then
  ok "manual dependency veto precedes AI review while planned queues are cancelled"
else
  bad "manual dependency was reviewed as SAFE or planned queue survived" discard-rollback-manual-peer
fi

section "discard: resuming a discard-parked manual dependent never scraps kept work"
# still the discard-rollback-manual-peer fixture: the parked dependent's
# preserved worktree now gains real committed work; the DISCARD_DEP_CANCELLED
# requeue must refuse to scrap it (manual tasks have no recovery-ref pin).
printf 'manual dependent wip\n' > "$manual_wt/manual-wip.txt"
git -C "$manual_wt" add manual-wip.txt
git -C "$manual_wt" -c core.hooksPath=/dev/null commit -q -m "manual: dependent work kept through discard"
RC=0
./loop.sh fleet resume "$manual_peer" >"$WORK/discard-manual-peer-resume.out" 2>&1 </dev/null || RC=$?
check "resume refuses to scrap kept manual work (exit 2)" discard-manual-peer-resume 2 "$RC"
if [ -d "$manual_wt" ] && [ -f "$manual_wt/manual-wip.txt" ] \
   && git rev-parse -q --verify "refs/heads/loop/$manual_peer" >/dev/null \
   && [ -f ".loop/fleet/queue/failed/$manual_peer.md" ] \
   && grep -q 'still holds implementation work' "$WORK/discard-manual-peer-resume.out" \
   && grep -qF "git worktree remove --force $manual_wt" "$WORK/discard-manual-peer-resume.out"; then
  ok "kept worktree/branch survive and the refusal names the explicit scrap commands"
else
  bad "resume scrapped or failed to protect the discard-parked manual work" discard-manual-peer-resume
fi
git worktree remove --force "$manual_wt" >/dev/null 2>&1
git branch -D "loop/$manual_peer" >/dev/null 2>&1
RC=0
./loop.sh fleet resume "$manual_peer" >"$WORK/discard-manual-peer-resume2.out" 2>&1 </dev/null || RC=$?
if [ "$RC" = 0 ] && [ -f ".loop/fleet/queue/new/$manual_peer.md" ] \
   && [ "$(fleet_phase "$manual_peer")" = queued ]; then
  ok "explicit scrap then resume requeues the manual dependent"
else
  bad "post-scrap resume did not requeue (rc=$RC phase=$(fleet_phase "$manual_peer"))" discard-manual-peer-resume
fi

section "discard rollback: reviewer UNSAFE retains changes, returns 4, and removes the plan"
make_discard_merged_fixture discard-rollback-unsafe
advance_wt=$(fleet_wt phase-a)
advance_branch=$(sed -n 's/^BRANCH=//p' .loop/fleet/runs/phase-a.env | tail -1)
advance_before=$(git rev-parse "refs/heads/$advance_branch")
advance_parent=$PWD
cat > "$WORK/fake-discard-branch-advance.sh" <<EOF
#!/bin/sh
set -e
case " \$* " in
  *loop-rollback-review*)
    if [ ! -e "$WORK/discard-branch-advanced.once" ]; then
      printf 'late worker commit\n' > "$advance_wt/late-worker.txt"
      git -C "$advance_wt" add late-worker.txt
      git -C "$advance_wt" -c core.hooksPath=/dev/null commit -q -m "test: advance after discard staging"
      git -C "$advance_wt" rev-parse HEAD > "$WORK/discard-branch-advanced-tip"
      printf '\nLATE_PEER_METADATA=1\n' >> "$advance_parent/.loop/fleet/runs/phase-b.env"
      : > "$WORK/discard-branch-advanced.once"
    fi
    ;;
esac
exec "$FAKE" "\$@"
EOF
chmod +x "$WORK/fake-discard-branch-advance.sh"
RC=0
LOOP_CLAUDE_CMD="$WORK/fake-discard-branch-advance.sh" LOOP_FAKE_ROLLBACK_REVIEW=UNSAFE \
  ./loop.sh discard --rollback >"$WORK/discard-rollback-unsafe.out" 2>&1 </dev/null || RC=$?
check "UNSAFE reviewer makes rollback unavailable (exit 4)" discard-rollback-unsafe 4 "$RC"
check "UNSAFE rollback still ends CANCELLED" discard-rollback-unsafe CANCELLED "$(cat .loop/state)"
archive=$(discard_archive_dir)
late_tip=$(cat "$WORK/discard-branch-advanced-tip" 2>/dev/null || echo "")
recovery_ref=$(sed -n 's/^BRANCH_RECOVERY_REF=//p' "$archive/tasks/phase-a/recovery.env" 2>/dev/null)
if [ -n "$late_tip" ] && [ "$late_tip" != "$advance_before" ] \
   && [ "$(git rev-parse "refs/heads/$advance_branch")" = "$late_tip" ] \
   && [ -n "$recovery_ref" ] \
   && [ "$(git rev-parse "$recovery_ref")" = "$advance_before" ] \
   && [ -d "$advance_wt" ] && [ -f "$advance_wt/late-worker.txt" ] \
   && grep -q "branch-advanced:$advance_branch" "$WORK/discard-rollback-unsafe.out"; then
  ok "post-stage branch advance is CAS-quarantined while the staged OID stays pinned"
else
  bad "discard lost or failed to pin a post-stage worker commit" discard-rollback-unsafe
fi
quarantine=".loop/fleet/discard-quarantine/$DISCARD_AUTHORITY/phase-b"
if [ -f "$quarantine/run.env" ] && [ -f "$quarantine/queue-new.md" ] \
   && grep -q '^LATE_PEER_METADATA=1$' "$quarantine/run.env" \
   && grep -q 'queue-drift:phase-b' "$WORK/discard-rollback-unsafe.out"; then
  ok "post-stage queue metadata drift is removed from dispatch but preserved recoverably"
else
  bad "discard deleted or left active post-stage queue metadata drift" discard-rollback-unsafe
fi
if [ "$(cat value.txt)" = fixed ] \
   && git merge-base --is-ancestor "$DISCARD_MERGE_COMMIT" HEAD \
   && ! git diff --quiet "$DISCARD_SOURCE" HEAD -- . \
        ':(exclude).loop' ':(exclude).claude' ':(exclude).agents' ':(exclude).codex'; then
  ok "UNSAFE verdict leaves merged product changes intact"
else
  bad "UNSAFE verdict unexpectedly changed product history/tree" discard-rollback-unsafe
fi
if [ -n "$archive" ] && grep -q '^FINAL_STATUS=UNAVAILABLE$' "$archive/result.env" \
   && grep -q 'ROLLBACK-REVIEW: UNSAFE' "$archive/rollback-review.txt" \
   && grep -q '^STATUS=UNAVAILABLE$' "$archive/rollback-assessment.env"; then
  ok "UNSAFE verdict and unavailable result are archived"
else
  bad "UNSAFE reviewer receipts missing ($archive)" discard-rollback-unsafe
fi
check "UNSAFE refusal removes new queue" discard-rollback-unsafe 0 "$(qcount new)"
check "UNSAFE refusal removes done queue" discard-rollback-unsafe 0 "$(qcount "done")"

section "discard: a pending request blocks run/add/resume/stop; unlock remains the recovery boundary"
make_fixture discard-pending
seed_unstarted_discard_plan pending-plan
printf 'resume me later\n' > .loop/fleet/queue/failed/resume-me.md
cat > .loop/fleet/runs/resume-me.env <<'EOF'
SUMMARY=manual interrupted peer
PLANNED=0
PHASE=INTERRUPTED
RESULT=INTERRUPTED
EOF
cat > .loop/fleet/discard-request.env <<EOF
VERSION=1
AUTHORITY=$DISCARD_AUTHORITY
CHOICE=pending
REQUESTED_AT=test
REQUESTED_BY_PID=999999
EOF
pending_head=$(git rev-parse HEAD)
pending_request_hash=$(sha256 < .loop/fleet/discard-request.env)
RC=0
./loop.sh add "must not enqueue" >"$WORK/discard-pending-add.out" 2>&1 </dev/null || RC=$?
check "pending request blocks add (exit 2)" discard-pending 2 "$RC"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh resume resume-me >"$WORK/discard-pending-resume.out" 2>&1 </dev/null || RC=$?
check "pending request blocks task resume (exit 2)" discard-pending 2 "$RC"
RC=0
./loop.sh fleet stop pending-plan >"$WORK/discard-pending-stop.out" 2>&1 </dev/null || RC=$?
check "pending request blocks fleet stop (exit 2)" discard-pending 2 "$RC"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh run >"$WORK/discard-pending-run.out" 2>&1 </dev/null || RC=$?
check "pending request blocks run (exit 2)" discard-pending 2 "$RC"
mkdir -p .loop/fleet/supervisor.lock.d
printf '999999\n' > .loop/fleet/supervisor.lock.d/pid
printf '999999\n' > .loop/fleet/plan-mutation.lock
RC=0
./loop.sh fleet unlock >"$WORK/discard-pending-unlock.out" 2>&1 </dev/null || RC=$?
check "pending request permits fleet unlock recovery" discard-pending 0 "$RC"
pending_msgs=0
for f in "$WORK"/discard-pending-{add,resume,stop,run}.out; do
  grep -q 'whole-plan discard transaction is pending' "$f" && pending_msgs=$((pending_msgs + 1))
done
check "all pending-request refusals name the discard transaction" discard-pending 4 "$pending_msgs"
if [ "$(git rev-parse HEAD)" = "$pending_head" ] \
   && [ "$(sha256 < .loop/fleet/discard-request.env)" = "$pending_request_hash" ] \
   && [ -f .loop/fleet/queue/new/pending-plan.md ] \
   && [ -f .loop/fleet/queue/failed/resume-me.md ] \
   && [ ! -e .loop/fleet/queue/claimed/resume-me.md ] \
   && [ ! -e .loop/fleet/supervisor.lock.d ] \
   && [ ! -e .loop/fleet/plan-mutation.lock ]; then
  ok "blocked commands preserve plan state while unlock clears stale recovery locks"
else
  bad "pending-request commands or unlock violated protected-state boundaries" discard-pending
fi

section "discard: a fixed durable choice cannot be reversed on retry"
make_fixture discard-choice-fixed
seed_unstarted_discard_plan choice-plan
cat > .loop/fleet/discard-request.env <<EOF
VERSION=1
AUTHORITY=$DISCARD_AUTHORITY
CHOICE=keep
REQUESTED_AT=test
REQUESTED_BY_PID=999999
EOF
before=$(git rev-parse HEAD)
RC=0
./loop.sh discard --rollback >"$WORK/discard-choice-fixed.out" 2>&1 </dev/null || RC=$?
check "fixed keep choice rejects rollback retry (exit 2)" discard-choice-fixed 2 "$RC"
if grep -q 'already fixed CHOICE=keep; it cannot be changed' "$WORK/discard-choice-fixed.out" \
   && grep -q '^VERSION=2$' .loop/fleet/discard-request.env \
   && grep -q '^CHOICE=keep$' .loop/fleet/discard-request.env \
   && grep -q "^AUTHORITY=$DISCARD_AUTHORITY$" .loop/fleet/discard-request.env \
   && [ "$(git rev-parse HEAD)" = "$before" ] \
   && [ -f .loop/fleet/queue/new/choice-plan.md ]; then
  ok "choice reversal is refused after a self-contained WAL upgrade, without changing history or queue"
else
  bad "choice reversal mutated the durable transaction" discard-choice-fixed
fi
printf 'CHOICE=keep\n' >> .loop/fleet/discard-request.env
malformed_hash=$(sha256 < .loop/fleet/discard-request.env)
RC=0
./loop.sh discard --keep-changes >"$WORK/discard-choice-malformed.out" 2>&1 </dev/null || RC=$?
check "duplicate request key fails closed (exit 2)" discard-choice-malformed 2 "$RC"
if [ "$(sha256 < .loop/fleet/discard-request.env)" = "$malformed_hash" ] \
   && [ "$(git rev-parse HEAD)" = "$before" ] \
   && [ -f .loop/fleet/queue/new/choice-plan.md ]; then
  ok "malformed WAL is preserved without stopping or deleting its queue"
else
  bad "malformed request handling mutated durable state" discard-choice-malformed
fi
rm -f .loop/fleet/discard-request.env
ln -s missing-discard-request .loop/fleet/discard-request.env
RC=0
./loop.sh add "must not bypass dangling WAL" >"$WORK/discard-dangling-wal.out" 2>&1 </dev/null || RC=$?
check "dangling request symlink still freezes mutations (exit 2)" discard-dangling-wal 2 "$RC"
if [ -L .loop/fleet/discard-request.env ] \
   && [ "$(qcount new)" = 1 ]; then
  ok "dangling WAL is treated as present and preserved for diagnosis"
else
  bad "dangling WAL guard allowed queue mutation" discard-dangling-wal
fi

section "discard: manual tasks with a cancelled planned dependency are parked explicitly"
make_fixture discard-manual-dependency
seed_unstarted_discard_plan planned-dep
./loop.sh add "manual prerequisite survives" >/dev/null 2>&1
manual_root=$(fleet_task_id manual-prerequisite)
./loop.sh add "manual dependent survives" --after "planned-dep,$manual_root" >/dev/null 2>&1
manual_child=$(fleet_task_id manual-dependent)
RC=0
./loop.sh discard --keep-changes >"$WORK/discard-manual-dependency.out" 2>&1 </dev/null || RC=$?
check "manual dependency cancellation exits 0" discard-manual-dependency 0 "$RC"
if [ -f ".loop/fleet/queue/new/$manual_root.md" ] \
   && [ -f ".loop/fleet/queue/failed/$manual_child.md" ] \
   && [ "$(fleet_phase "$manual_child")" = DISCARD_DEP_CANCELLED ] \
   && grep -q '^DISCARD_CANCELLED_DEPS=planned-dep$' ".loop/fleet/runs/$manual_child.env" \
   && grep -q "^DEPENDS_ON=$manual_root$" ".loop/fleet/runs/$manual_child.env"; then
  ok "only the cancelled planned edge is removed and the manual dependent is reviewable"
else
  bad "manual dependent kept a dangling planned edge or was deleted" discard-manual-dependency
fi
RC=0
./loop.sh fleet resume "$manual_child" >"$WORK/discard-manual-dependency-resume.out" 2>&1 </dev/null || RC=$?
if [ "$RC" = 0 ] && [ -f ".loop/fleet/queue/new/$manual_child.md" ] \
   && [ "$(fleet_phase "$manual_child")" = queued ]; then
  ok "explicit resume releases the parked manual dependent"
else
  bad "DISCARD_DEP_CANCELLED was not resumable" discard-manual-dependency
fi

section "discard: a partially stamped legacy authority converges without overwriting conflicts"
make_fixture discard-legacy-partial
seed_unstarted_discard_plan legacy-a
legacy_authority=legacy-discard-partial
cat > .loop/fleet/plan-authority.env <<EOF
VERSION=0
LEGACY=1
AUTHORITY=$legacy_authority
PLAN_HASH=legacy
SOURCE_REF=$DISCARD_SOURCE
SOURCE_REFNAME=$DISCARD_REFNAME
CREATED_AT=test
EOF
legacy_tmp=.loop/fleet/runs/legacy-a.tmp
grep -Ev '^(PLAN_AUTHORITY|PLAN_SOURCE_REF|PLAN_SOURCE_REFNAME)=' \
  .loop/fleet/runs/legacy-a.env > "$legacy_tmp"
cat >> "$legacy_tmp" <<EOF
PLAN_AUTHORITY=$legacy_authority
PLAN_SOURCE_REF=$DISCARD_SOURCE
PLAN_SOURCE_REFNAME=$DISCARD_REFNAME
EOF
mv "$legacy_tmp" .loop/fleet/runs/legacy-a.env
printf 'legacy b\n' > .loop/fleet/queue/new/legacy-b.md
cat > .loop/fleet/runs/legacy-b.env <<'EOF'
SUMMARY=legacy b
PLANNED=1
PHASE=queued
EOF
RC=0
./loop.sh discard --keep-changes >"$WORK/discard-legacy-partial.out" 2>&1 </dev/null || RC=$?
check "partial legacy adoption exits 0" discard-legacy-partial 0 "$RC"
archive=$(discard_archive_dir)
if [ -f "$archive/tasks/legacy-a/run.env" ] \
   && [ -f "$archive/tasks/legacy-b/run.env" ] \
   && grep -q "^PLAN_AUTHORITY=$legacy_authority$" "$archive/tasks/legacy-a/run.env" \
   && grep -q "^PLAN_AUTHORITY=$legacy_authority$" "$archive/tasks/legacy-b/run.env" \
   && [ "$(qcount new)" = 0 ]; then
  ok "legacy retry completes every blank binding before cancelling both tasks"
else
  bad "legacy partial adoption left mixed authority or queue residue" discard-legacy-partial
fi

section "discard: untracked worker files quarantine the worktree instead of deleting it"
make_fixture discard-untracked
seed_unstarted_discard_plan untracked-plan
wt="$WORK/discard-untracked-loops/untracked-plan"
git worktree add -q -b loop/untracked-plan "$wt" "$DISCARD_SOURCE"
printf 'save me\n' > "$wt/rescue.txt"
mv .loop/fleet/queue/new/untracked-plan.md .loop/fleet/queue/claimed/untracked-plan.md
cat >> .loop/fleet/runs/untracked-plan.env <<EOF
WT=$wt
BRANCH=loop/untracked-plan
BASE_REF=$DISCARD_SOURCE
PHASE=INTERRUPTED
EOF
cat > .loop/fleet/plan-dispatched.env <<EOF
AUTHORITY=$DISCARD_AUTHORITY
FIRST_TASK=untracked-plan
DISPATCHED_AT=test
EOF
RC=0
./loop.sh discard --keep-changes >"$WORK/discard-untracked.out" 2>&1 </dev/null || RC=$?
check "untracked quarantine reports partial cleanup (exit 4)" discard-untracked 4 "$RC"
check "quarantined plan still ends CANCELLED" discard-untracked CANCELLED "$(cat .loop/state)"
archive=$(discard_archive_dir)
if [ -d "$wt" ] && [ -f "$wt/rescue.txt" ] \
   && git rev-parse -q --verify refs/heads/loop/untracked-plan >/dev/null; then
  ok "untracked worktree, file, and branch are preserved for recovery"
else
  bad "discard deleted the untracked worker quarantine" discard-untracked
fi
if [ -n "$archive" ] \
   && grep -q '^rescue.txt$' "$archive/tasks/untracked-plan/untracked-files.txt" \
   && grep -q 'untracked-or-ignored:' "$WORK/discard-untracked.out"; then
  ok "archive/output identify the quarantined untracked file and worktree"
else
  bad "untracked quarantine evidence missing ($archive)" discard-untracked
fi
if [ ! -e .loop/fleet/queue/claimed/untracked-plan.md ] \
   && [ ! -e .loop/fleet/runs/untracked-plan.env ] \
   && [ ! -e .loop/fleet/plan-authority.env ] \
   && [ ! -e .loop/fleet/discard-request.env ]; then
  ok "queue authority is cancelled even though recovery artifacts are quarantined"
else
  bad "quarantine left the cancelled queue authority active" discard-untracked
fi

section "fleet clean --orphans: a quarantined discard worktree needs --force, and names it"
# still the discard-untracked fixture: queue/env are gone, so the kept worktree
# is an orphan — the finish_discard hint chains here, and the refusal must name
# the explicit escalation instead of the former dead-end "clean it explicitly".
RC=0
./loop.sh fleet clean --orphans >"$WORK/discard-untracked-orphans.out" 2>&1 </dev/null || RC=$?
check "plain --orphans keeps the quarantined worktree (exit 0)" discard-untracked-orphans 0 "$RC"
if [ -d "$wt" ] && [ -f "$wt/rescue.txt" ] \
   && git rev-parse -q --verify refs/heads/loop/untracked-plan >/dev/null \
   && grep -q 'fleet clean --orphans --force' "$WORK/discard-untracked-orphans.out"; then
  ok "refusal preserves the worktree and names the explicit force command"
else
  bad "plain --orphans deleted the quarantine or failed to name --force" discard-untracked-orphans
fi
RC=0
./loop.sh fleet clean --orphans --force >"$WORK/discard-untracked-orphans-force.out" 2>&1 </dev/null || RC=$?
check "forced orphan clean exits 0" discard-untracked-orphans-force 0 "$RC"
if [ ! -d "$wt" ] && ! git rev-parse -q --verify refs/heads/loop/untracked-plan >/dev/null; then
  ok "explicit --force removes the quarantined worktree and branch"
else
  bad "forced orphan clean left the worktree/branch behind" discard-untracked-orphans-force
fi

section "discard: a parked discard-peer recovers with an executable resume hint"
# recover_claimed can only ever see STOPPED_BY=discard(-peer) AFTER the discard
# transaction completed (guard_no_discard_pending bars run/fleet run while the
# WAL is pending), so the park detail must point at resume, never at completing
# the already-finished discard.
printf 'peer task parked by the completed discard\n' > .loop/fleet/queue/claimed/peer-after.md
cat > .loop/fleet/runs/peer-after.env <<'EOF'
SUMMARY=manual peer parked by discard
PLANNED=0
PHASE=INTERRUPTED
STOPPED_BY=discard-peer
EOF
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --drain >"$WORK/discard-peer-recover.out" 2>&1 </dev/null || RC=$?
if [ -f .loop/fleet/queue/failed/peer-after.md ] \
   && grep -qF 'resume explicitly: ./loop.sh resume peer-after' "$WORK/discard-peer-recover.out"; then
  ok "post-discard recovery parks the peer with an executable resume hint"
else
  bad "discard-peer recovery hint missing or stale (rc=$RC)" discard-peer-recover
fi

section "discard: corrupted task metadata cannot delete another clean worktree"
make_fixture discard-worktree-target
seed_unstarted_discard_plan target-plan
foreign_wt="$WORK/discard-worktree-target-loops/foreign"
git worktree add -q -b loop/foreign "$foreign_wt" "$DISCARD_SOURCE"
mv .loop/fleet/queue/new/target-plan.md .loop/fleet/queue/claimed/target-plan.md
cat >> .loop/fleet/runs/target-plan.env <<EOF
WT=$foreign_wt
BRANCH=loop/foreign
BASE_REF=$DISCARD_SOURCE
PHASE=INTERRUPTED
EOF
RC=0
./loop.sh discard --keep-changes >"$WORK/discard-worktree-target.out" 2>&1 </dev/null || RC=$?
check "foreign worktree target reports partial cleanup (exit 4)" discard-worktree-target 4 "$RC"
if [ -d "$foreign_wt" ] \
   && git rev-parse -q --verify refs/heads/loop/foreign >/dev/null \
   && grep -q 'branch-target:loop/foreign' "$WORK/discard-worktree-target.out" \
   && grep -q "worktree-target:$foreign_wt" "$WORK/discard-worktree-target.out" \
   && [ ! -e .loop/fleet/queue/claimed/target-plan.md ] \
   && [ ! -e .loop/fleet/runs/target-plan.env ]; then
  ok "external path/branch anchors preserve the foreign worktree while cancelling queue authority"
else
  bad "corrupted run metadata deleted another worktree or kept cancelled queue authority" discard-worktree-target
fi

section "discard: ignored user files also quarantine a worker (managed ignored files do not)"
make_fixture discard-ignored-worker
printf '\n/ignored-rescue.txt\n' >> .gitignore
git add .gitignore
git commit -q -m "test: ignore a worker recovery file"
seed_unstarted_discard_plan ignored-plan
wt="$WORK/discard-ignored-worker-loops/ignored-plan"
git worktree add -q -b loop/ignored-plan "$wt" "$DISCARD_SOURCE"
printf 'ignored but user-owned\n' > "$wt/ignored-rescue.txt"
git -C "$wt" check-ignore -q ignored-rescue.txt
mv .loop/fleet/queue/new/ignored-plan.md .loop/fleet/queue/claimed/ignored-plan.md
cat >> .loop/fleet/runs/ignored-plan.env <<EOF
WT=$wt
BRANCH=loop/ignored-plan
BASE_REF=$DISCARD_SOURCE
PHASE=INTERRUPTED
EOF
RC=0
./loop.sh discard --keep-changes >"$WORK/discard-ignored-worker.out" 2>&1 </dev/null || RC=$?
check "ignored user file quarantine exits 4" discard-ignored-worker 4 "$RC"
archive=$(discard_archive_dir)
if [ -d "$wt" ] && [ -f "$wt/ignored-rescue.txt" ] \
   && grep -q '^ignored-rescue.txt$' "$archive/tasks/ignored-plan/untracked-files.txt" \
   && grep -q 'untracked-or-ignored:' "$WORK/discard-ignored-worker.out"; then
  ok "ignored user data survives and is named in the committed archive"
else
  bad "ignored user data was treated as disposable harness state" discard-ignored-worker
fi

section "discard rollback: parent ignored data blocks an overlapping inverse before review"
make_fixture discard-parent-ignored
printf 'source bytes\n' > collision.txt
git add collision.txt
git commit -q -m "test: seed a rollback-restored path"
seed_unstarted_discard_plan collision-plan
wt="$WORK/discard-parent-ignored-loops/collision-plan"
git worktree add -q -b loop/collision-plan "$wt" "$DISCARD_SOURCE"
git -C "$wt" rm -q collision.txt
git -C "$wt" commit -q -m "worker: delete collision path"
collision_tip=$(git -C "$wt" rev-parse HEAD)
collision_pre=$(git rev-parse HEAD)
git merge --no-ff --no-commit loop/collision-plan >/dev/null
mkdir -p .loop/docs/run-archive/collision-plan
cat > .loop/docs/run-archive/collision-plan/integration.env <<EOF
VERSION=1
PLAN_AUTHORITY=$DISCARD_AUTHORITY
PLAN_SOURCE_REF=$DISCARD_SOURCE
PLAN_SOURCE_REFNAME=$DISCARD_REFNAME
TASK_ID=collision-plan
PRE_MERGE_HEAD=$collision_pre
BRANCH_TIP=$collision_tip
BASE_REF=$DISCARD_SOURCE
EOF
git add .loop/docs/run-archive/collision-plan/integration.env
git commit -q \
  -m "fleet: merge collision-plan" \
  -m "Loop-Plan-Authority: $DISCARD_AUTHORITY
Loop-Task: collision-plan
Loop-Plan-Source: $DISCARD_SOURCE
Loop-Plan-Refname: $DISCARD_REFNAME
Loop-Pre-Merge-Head: $collision_pre
Loop-Branch-Tip: $collision_tip"
collision_merge=$(git rev-parse HEAD)
mv .loop/fleet/queue/new/collision-plan.md .loop/fleet/queue/done/collision-plan.md
cat >> .loop/fleet/runs/collision-plan.env <<EOF
WT=$wt
BRANCH=loop/collision-plan
BASE_REF=$DISCARD_SOURCE
MERGE_COMMIT=$collision_merge
PHASE=DONE
EOF
exclude_file=$(git rev-parse --git-path info/exclude)
printf '\n/collision.txt\n' >> "$exclude_file"
printf 'ignored user bytes\n' > collision.txt
git check-ignore -q collision.txt
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_ROLLBACK_REVIEW=SAFE \
  ./loop.sh discard --rollback >"$WORK/discard-parent-ignored.out" 2>&1 </dev/null || RC=$?
check "parent ignored overlap makes rollback unavailable (exit 4)" discard-parent-ignored 4 "$RC"
archive=$(discard_archive_dir)
if [ "$(cat collision.txt)" = "ignored user bytes" ] \
   && grep -q 'parent untracked/ignored path overlaps.*collision.txt' "$archive/result.env" \
   && [ ! -e .loop/fake-rollback-prompts ]; then
  ok "parent ignored data survives and deterministic overlap veto precedes review"
else
  bad "rollback overwrote ignored parent data or invoked review after the veto" discard-parent-ignored
fi

