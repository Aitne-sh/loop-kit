#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- fleet (parallel supervisor: one dispatcher, worktree-isolated loops) ----------

section "fleet: Codex role selection propagates into the worker worktree"
make_fleet_fixture fleet-codex-route
printf 'AGENT_IMPLEMENT="codex"\nMODEL_IMPLEMENT="gpt-5.5"\n' >> loop.models.sh
mkdir -p .codex/hooks .codex/rules .agents/skills/loop-iterate/references
printf '\n.codex/\n' >> .gitignore
git add .gitignore && git commit -q -m "ignore local Codex project config"
printf 'model_reasoning_effort = "high"\n' > .codex/config.toml
printf '{"hooks":[]}\n' > .codex/hooks.json
printf '#!/bin/sh\nexit 0\n' > .codex/hooks/pre-tool.sh
printf 'prefix_rule(pattern=["git", "status"], decision="allow")\n' > .codex/rules/default.rules
printf 'approved managed resource\n' > .agents/skills/loop-iterate/references/fleet.md
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW=APPROVE \
  LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --auto --drain >"$WORK/fleet-codex-route.out" 2>&1 </dev/null &
wait_sup $! fleet-codex-route
check "supervisor exit 0" fleet-codex-route 0 "$RC"
check "task done" fleet-codex-route 1 "$(qcount "done")"
id=$(fleet_task_id alpha)
wt=$(fleet_wt "$id")
if [ -s "$wt/.loop/fake-codex-args" ] \
   && grep -q '^model=gpt-5.5 sandbox=workspace-write approval=never ' "$wt/.loop/fake-codex-args"; then
  ok "copied loop.models.sh routed worker IMPLEMENT to Codex"
else
  bad "Codex worker routing missing in $wt" fleet-codex-route
fi
if cmp -s .codex/config.toml "$wt/.codex/config.toml" \
   && cmp -s .codex/hooks.json "$wt/.codex/hooks.json" \
   && cmp -s .codex/hooks/pre-tool.sh "$wt/.codex/hooks/pre-tool.sh" \
   && cmp -s .codex/rules/default.rules "$wt/.codex/rules/default.rules"; then
  ok "the full approved .codex control tree propagated byte-for-byte to the worker"
else
  bad "Codex worker lost part of the parent control tree" fleet-codex-route
fi
if cmp -s .agents/skills/loop-iterate/references/fleet.md \
          "$wt/.agents/skills/loop-iterate/references/fleet.md" \
   && cmp -s .agents/skills/loop-iterate/agents/openai.yaml \
            "$wt/.agents/skills/loop-iterate/agents/openai.yaml" \
   && [ -f "$wt/.agents/skills/loop-iterate/.loop-kit-managed" ]; then
  ok "managed Codex skill resources, policy, and ownership propagated to the worker"
else
  bad "worker lost the managed Codex skill projection" fleet-codex-route
fi

section "fleet: an all-Codex fleet (CONTRACT included) runs Claude-less end to end"
make_fleet_fixture fleet-codex-only
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
RC=0
LOOP_CLAUDE_CMD="$WORK/no-such-claude" LOOP_FAKE_CONTRACT=READY LOOP_FAKE_SCENARIO="READY_NOW" \
  LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --auto --drain >"$WORK/fleet-codex-only.out" 2>&1 </dev/null &
wait_sup $! fleet-codex-only
check "supervisor exit 0" fleet-codex-only 0 "$RC"
check "task done" fleet-codex-only 1 "$(qcount "done")"
id=$(fleet_task_id alpha)
wt=$(fleet_wt "$id")
if grep -q 'loop-contract/SKILL.md' "$wt/.loop/fake-codex-prompts" 2>/dev/null \
   && [ ! -e "$wt/.loop/fake-models" ] && [ ! -e .loop/fake-models ]; then
  ok "the worker defined its contract on Codex; no Claude process in parent or worker"
else
  bad "Claude leaked into the Claude-less fleet (wt=$wt)" fleet-codex-only
fi

section "fleet: add is an atomic maildir enqueue (works without a supervisor)"
make_fleet_fixture fleet-add
out=$(./loop.sh fleet add task-a.md 2>&1)
check "queued into new/" fleet-add 1 "$(qcount new)"
check "tmp/ left empty" fleet-add 0 "$(find .loop/fleet/queue/tmp -type f 2>/dev/null | wc -l | tr -d ' ')"
if echo "$out" | grep -q "no supervisor running"; then ok "hints to start the supervisor"; else bad "no hint: $out" fleet-add; fi
./loop.sh fleet add "inline instruction: fix the thing" >/dev/null
check "inline text task queued" fleet-add 2 "$(qcount new)"
id=$(fleet_task_id alpha)
if grep -q '^SUMMARY=alpha task' ".loop/fleet/runs/$id.env"; then ok "summary recorded"; else bad "summary missing" fleet-add; fi

section "fleet: id collisions force the retry path; enqueue stays atomic and clean"
make_fleet_fixture add-collide
mkdir -p .loop/fleet/queue/new .loop/fleet/queue/tmp
# DANGLING symlinks at the candidate ids for the next 3 seconds: `test -f`
# (task_qdir/gen_task_id) is false through them, so the id looks free, but
# ln(2) still fails EEXIST on the name -> deterministically exercises the
# collision-retry loop. A directory would NOT work (ln INTO a dir succeeds).
for s in 0 1 2; do
  ln -s /nonexistent ".loop/fleet/queue/new/$(ts_plus "$s")-collide-me.md" 2>/dev/null || true
done
RC=0
./loop.sh fleet add "collide me" >"$WORK/add-collide.out" 2>&1 || RC=$?
check "add exits 0 despite the seeded collisions" add-collide 0 "$RC"
check "exactly one regular file enqueued" add-collide 1 "$(find .loop/fleet/queue/new -type f | wc -l | tr -d ' ')"
check "tmp/ left empty" add-collide 0 "$(find .loop/fleet/queue/tmp -type f 2>/dev/null | wc -l | tr -d ' ')"
check "exactly one ADDED journal event" add-collide 1 "$(grep -c '"event": "ADDED"' .loop/fleet/journal.jsonl || true)"
find .loop/fleet/queue/new -type l -delete
# outcome-deterministic concurrency probe: two same-text adds race the same id;
# ln's refuse-to-clobber makes the loser retry — both must land, distinctly
./loop.sh fleet add "same task text as its twin" >"$WORK/add-c1.out" 2>&1 &
A1=$!
./loop.sh fleet add "same task text as its twin" >"$WORK/add-c2.out" 2>&1 &
A2=$!
wait "$A1" "$A2" || true
check "both concurrent adds enqueued distinct ids" add-collide 2 "$(find .loop/fleet/queue/new -type f -name '*same-task-text*' | wc -l | tr -d ' ')"
n_sum=0
for e in .loop/fleet/runs/*same-task-text*.env; do
  [ -f "$e" ] || continue
  grep -q '^SUMMARY=' "$e" && n_sum=$((n_sum + 1))
done
check "both adds recorded SUMMARY metadata" add-collide 2 "$n_sum"
if ! grep -q 'could not enqueue' "$WORK/add-c1.out" "$WORK/add-c2.out"; then
  ok "no enqueue failure under contention"
else
  bad "enqueue failed under contention" add-collide
fi

section "fleet: FIFO dispatch — tasks claimed in add order under one slot"
make_fleet_fixture add-fifo
./loop.sh fleet add "aaa fix value.txt so the check passes" >/dev/null 2>&1
./loop.sh fleet add "bbb fix value.txt so the check passes" >/dev/null 2>&1
./loop.sh fleet add "ccc fix value.txt so the check passes" >/dev/null 2>&1
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run --auto --drain --max-parallel 1 > "$WORK/add-fifo.out" 2>&1 </dev/null &
wait_sup $! add-fifo
check "supervisor exit 0" add-fifo 0 "$RC"
check "all three done" add-fifo 3 "$(qcount "done")"
# each CLAIMED line carries the task id exactly once (detail is empty), so the
# concatenated slug matches give the claim order
seq=$(grep '"event": "CLAIMED"' .loop/fleet/journal.jsonl | grep -oE 'aaa|bbb|ccc' | tr -d '\n')
check "claimed strictly in add order" add-fifo aaabbbccc "$seq"

section "fleet: same-second adds dispatch in slug order (documented; --after for strict)"
# E10/G6: ids embed a second-resolution timestamp, so dispatch is id-lexical —
# add order EXCEPT same-second adds, which order by slug. Pin the documented
# behavior with a reverse-lexical pair landed in one second (bounded retries;
# skip honestly if the machine can't land two adds in the same second).
make_fleet_fixture add-order-doc
tries=0
same_sec=0
while [ "$tries" -lt 20 ]; do
  ./loop.sh fleet add "zzz fix value.txt so the check passes" >/dev/null 2>&1
  out=$(./loop.sh fleet add "aaa fix value.txt so the check passes" 2>&1)
  idz=$(fleet_task_id zzz); ida=$(fleet_task_id aaa)
  # ids are <YYYYmmdd-HHMMSS>-<slug>: the first 15 chars are the second-resolution
  # timestamp (slugs contain dashes, so suffix-stripping would be wrong)
  if [ -n "$idz" ] && [ "${idz:0:15}" = "${ida:0:15}" ]; then same_sec=1; break; fi
  rm -f .loop/fleet/queue/new/*.md .loop/fleet/runs/*.env
  tries=$((tries + 1))
done
case "$out" in
  *id-lexical*) ok "add output documents the id-lexical dispatch order" ;;
  *) bad "add output missing the order note: $out" add-order-doc ;;
esac
if [ "$same_sec" = 1 ]; then
  RC=0
  LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
    ./loop.sh fleet run --auto --drain --max-parallel 1 > "$WORK/add-order-doc.out" 2>&1 </dev/null &
  wait_sup $! add-order-doc
  check "supervisor exit 0" add-order-doc 0 "$RC"
  seq=$(grep '"event": "CLAIMED"' .loop/fleet/journal.jsonl | grep -oE 'aaa|zzz' | tr -d '\n')
  check "same-second pair claimed in slug order (aaa before zzz)" add-order-doc aaazzz "$seq"
else
  echo "  skip: could not land two adds in the same second (id ts prefixes differ)"
fi
# --after gives strict sequencing regardless of slugs/timestamps: xxx depends on
# yyy, so yyy (lexically later) must still be claimed first
./loop.sh fleet add "yyy fix value.txt so the check passes" >/dev/null 2>&1
idy=$(fleet_task_id yyy)
./loop.sh fleet add "xxx fix value.txt so the check passes" --after "$idy" >/dev/null 2>&1
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run --auto --drain --max-parallel 1 > "$WORK/add-order-doc2.out" 2>&1 </dev/null &
wait_sup $! add-order-doc
check "supervisor exit 0" add-order-doc 0 "$RC"
seq=$(grep '"event": "CLAIMED"' .loop/fleet/journal.jsonl | grep -oE 'yyy|xxx' | tr -d '\n')
check "--after forces strict order (yyy before xxx)" add-order-doc yyyxxx "$seq"

section "fleet: duplicate content warns (identical to <id>) but still queues"
make_fleet_fixture add-dup
./loop.sh fleet add task-a.md >/dev/null 2>&1
id1=$(fleet_task_id alpha)
RC=0
out=$(./loop.sh fleet add task-a.md 2>&1) || RC=$?
check "duplicate add still exits 0 (warn, never block)" add-dup 0 "$RC"
case "$out" in
  *"identical to '$id1'"*) ok "second add names the queued duplicate" ;;
  *) bad "no duplicate warning: $out" add-dup ;;
esac
check "both copies queued" add-dup 2 "$(qcount new)"
if grep -q '"event": "DUP_CONTENT"' .loop/fleet/journal.jsonl; then ok "duplicate journaled as DUP_CONTENT"; else bad "DUP_CONTENT missing" add-dup; fi
id2=""
for f in .loop/fleet/queue/new/*.md; do
  b=$(basename "$f" .md)
  [ "$b" = "$id1" ] || id2="$b"
done
sha1=$(grep -E '^SRC_SHA=' ".loop/fleet/runs/$id1.env" 2>/dev/null | tail -1 | cut -d= -f2)
sha2=$(grep -E '^SRC_SHA=' ".loop/fleet/runs/$id2.env" 2>/dev/null | tail -1 | cut -d= -f2)
if [ -n "$sha1" ] && [ "$sha1" = "$sha2" ]; then ok "SRC_SHA identical across the duplicates"; else bad "SRC_SHA mismatch ('$sha1' vs '$sha2')" add-dup; fi

section "fleet: two tasks in parallel -> both SUCCESS, serial-merged, parent isolated"
make_fleet_fixture fleet-par
printf 'WORKTREE_SETUP_CMD="touch .loop/setup-ran"\n' >> fleet.config.sh
# a dedicated store for this run isolates the E3 slot-layout assertions below
# (workers inherit LOOP_APPROVAL_HOME through the dispatcher's environment)
LOOP_APPROVAL_HOME="$WORK/approvals-par" \
  LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md task-b.md --auto --drain --max-parallel 2 \
  > "$WORK/fleet-par.out" 2>&1 </dev/null &
wait_sup $! fleet-par
check "supervisor exit 0" fleet-par 0 "$RC"
check "both tasks done" fleet-par 2 "$(qcount "done")"
check "parent value fixed (merged)" fleet-par fixed "$(cat value.txt)"
check "two serial merge commits" fleet-par 2 "$(git log --format=%s | grep -c '^fleet: merge' || true)"
ida=$(fleet_task_id alpha)
if [ -f "$(fleet_wt "$ida")/.loop/setup-ran" ]; then ok "WORKTREE_SETUP_CMD ran once in the worktree"; else bad "setup cmd did not run" fleet-par; fi
if [ -f ".loop/docs/run-archive/$ida/evidence-report.md" ]; then ok "evidence archived on merge"; else bad "no run-archive evidence" fleet-par; fi
if [ -f ".loop/docs/run-archive/$ida/acceptance-checklist.md" ]; then ok "acceptance checklist archived on merge (integration gate reads it)"; else bad "no run-archive acceptance-checklist" fleet-par; fi
if grep -q 'auto-generated' ".loop/docs/run-archive/$ida/product-contract.md" 2>/dev/null; then ok "task ran its OWN generated contract"; else bad "archived contract not task-generated" fleet-par; fi
if grep -q '<!-- TEMPLATE -->' .loop/docs/product-contract.md; then ok "parent docs untouched by worktree runs"; else bad "parent contract clobbered" fleet-par; fi
check "parent tracked tree clean" fleet-par "" "$(git status --porcelain -uno)"
if grep -q '"event": "AUTO_APPROVED"' .loop/fleet/journal.jsonl; then ok "auto-approval journaled"; else bad "AUTO_APPROVED missing" fleet-par; fi
if [ ! -d .loop/fleet/supervisor.lock.d ]; then ok "supervisor lock released on exit"; else bad "lock left behind" fleet-par; fi
if grep -q 'Sibling tasks' "$(fleet_wt "$ida")/.loop/parallel-context.md" 2>/dev/null; then
  ok "parallel-context landed in the worktree (atomic write path)"
else
  bad "parallel-context.md missing/incomplete" fleet-par
fi
if [ -z "$(find "$WORK/fleet-par-loops" -name '.parallel-context.md.tmp.*' 2>/dev/null)" ]; then
  ok "no parallel-context tmp leftovers under the worktree root"
else
  bad "write_parallel_context leaked tmp files" fleet-par
fi
# E3/G1: the two worker worktrees share one repo-id in the approval store but
# each writes its OWN slot — a single shared record would be clobbered by every
# worker approval (layout: <home>/<repo-id>/<slot-id>/{approved,approved-harness})
n_repo=$(find "$WORK/approvals-par" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
n_slot=$(find "$WORK/approvals-par" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')
check "store groups both worktrees under ONE repo-id" fleet-par 1 "$n_repo"
check "two distinct approval slots (one per worker worktree)" fleet-par 2 "$n_slot"
n_rec=$(find "$WORK/approvals-par" -mindepth 3 -maxdepth 3 -name approved 2>/dev/null | wc -l | tr -d ' ')
check "each slot carries its own approved record" fleet-par 2 "$n_rec"

section "fleet: clean --done removes worktrees + branches"
./loop.sh fleet clean --done >/dev/null 2>&1
check "done queue emptied" fleet-clean 0 "$(qcount "done")"
check "loop/* branches removed" fleet-clean "" "$(git branch --list 'loop/*' | tr -d ' ')"
check "worktrees pruned (only parent left)" fleet-clean 1 "$(git worktree list | wc -l | tr -d ' ')"

section "fleet: dynamic add while running + singleton supervisor lock"
make_fleet_fixture fleet-dyn
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/fleet-dyn.out" 2>&1 </dev/null &
SUP=$!
n=0   # add as soon as task-a is claimed: guaranteed mid-run, no fixed sleep
while [ "$n" -lt $((100 * POLL_SCALE)) ]; do
  [ "$(qcount claimed)" -ge 1 ] && break
  sleep 0.2; n=$((n + 1))
done
./loop.sh fleet add task-b.md >/dev/null 2>&1
RC2=0
# --auto --drain so the vanishingly-rare race (first supervisor drains between
# the add and this launch) shows up as a visible check failure (RC2=0, and the
# stolen task still completes) — never a hang: without --auto that accidental
# second supervisor would park task-b in PENDING_APPROVAL and drain would wait
# on it forever
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run --auto --drain >/dev/null 2>&1 </dev/null || RC2=$?
check "second supervisor refused (singleton)" fleet-dyn 2 "$RC2"
wait_sup "$SUP" fleet-dyn
check "supervisor exit 0" fleet-dyn 0 "$RC"
check "late-added task also completed" fleet-dyn 2 "$(qcount "done")"
check "parent value fixed" fleet-dyn fixed "$(cat value.txt)"

section "fleet: singleton survives a ps-identity false-negative (heartbeat fallback)"
# Reproduces the environment class where `ps -o command=` does not identify a
# LIVE supervisor: the lock's pid points at a live process that does not look
# like loop.sh. With a fresh heartbeat the lock must be honored; only a stale
# heartbeat may be stolen.
make_fleet_fixture fleet-hb
sleep 300 & HBPID=$!
mkdir -p .loop/fleet/supervisor.lock.d
echo "$HBPID" > .loop/fleet/supervisor.lock.d/pid
touch .loop/fleet/supervisor.lock.d/heartbeat
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain >/dev/null 2>&1 </dev/null || RC=$?
check "fresh heartbeat: lock honored despite foreign-looking pid" fleet-hb 2 "$RC"
touch -t 202001010000 .loop/fleet/supervisor.lock.d/heartbeat
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain > "$WORK/fleet-hb.out" 2>&1 </dev/null || RC=$?
check "stale heartbeat + foreign pid: lock stolen, supervisor runs" fleet-hb 0 "$RC"
if grep -q "removing stale supervisor lock" "$WORK/fleet-hb.out"; then ok "steal was explicit"; else bad "no stale-steal note" fleet-hb; fi
kill "$HBPID" 2>/dev/null || true

section "fleet: add landing in the drain grace window is still claimed (exit protocol)"
make_fleet_fixture fleet-grace
# widen the grace to 25 ticks (5s at the test tick) so the add deterministically
# lands while the supervisor is idling toward exit — the exact window the
# drain-exit protocol must cover
printf 'FLEET_DRAIN_GRACE_TICKS="25"\n' >> fleet.config.sh
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/fleet-grace.out" 2>&1 </dev/null &
SUP=$!
n=0   # wait until task-a is fully merged: from here the supervisor is idle-counting
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  [ "$(qcount "done")" -ge 1 ] && break
  sleep 0.2; n=$((n + 1))
done
check "task-a merged; supervisor idling in the grace window" fleet-grace 1 "$(qcount "done")"
./loop.sh fleet add task-b.md >/dev/null 2>&1
wait_sup "$SUP" fleet-grace
check "supervisor exit 0" fleet-grace 0 "$RC"
check "grace-window add was claimed and completed" fleet-grace 2 "$(qcount "done")"
check "parent value fixed" fleet-grace fixed "$(cat value.txt)"

section "fleet: --drain with a dirty parent escalates (exit 3), restart lands the merge"
make_fleet_fixture fleet-mblock
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/fleet-mblock.out" 2>&1 </dev/null &
SUP=$!
n=0   # dirty the parent only AFTER the pre-fleet snapshot (claim implies startup done)
while [ "$n" -lt $((100 * POLL_SCALE)) ]; do
  [ "$(qcount claimed)" -ge 1 ] && break
  sleep 0.2; n=$((n + 1))
done
echo "# human mid-edit" >> check.sh
wait_sup "$SUP" fleet-mblock
check "drain escalates with exit 3 instead of spinning" fleet-mblock 3 "$RC"
id=$(fleet_task_id alpha)
check "finished branch kept as MERGE_PENDING" fleet-mblock MERGE_PENDING "$(fleet_phase "$id")"
if grep -q '"event": "DRAIN_MERGE_BLOCKED"' .loop/fleet/journal.jsonl; then ok "escalation journaled"; else bad "DRAIN_MERGE_BLOCKED missing" fleet-mblock; fi
git add check.sh && git commit -qm "human finished editing"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain > "$WORK/fleet-mblock2.out" 2>&1 </dev/null || RC=$?
check "restarted supervisor exit 0" fleet-mblock 0 "$RC"
check "adopted MERGE_PENDING landed in done/" fleet-mblock 1 "$(qcount "done")"
check "parent value fixed by the restart merge" fleet-mblock fixed "$(cat value.txt)"
if grep -q '"event": "ADOPTED"' .loop/fleet/journal.jsonl; then ok "restart adoption journaled"; else bad "ADOPTED missing" fleet-mblock; fi

section "fleet: add during a merge-blocked drain is claimed first, THEN the drain escalates"
# G2: a claimable task in new/ makes fleet_merge_blocked false — the drain claims
# and runs it (progress is possible) and only once it too is MERGE_PENDING does
# the 15-tick escalation fire. Pin exactly that branch.
make_fleet_fixture add-mergeblocked
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/add-mblock.out" 2>&1 </dev/null &
SUP=$!
n=0   # dirty the parent only AFTER the pre-fleet snapshot (claim implies startup done)
while [ "$n" -lt $((100 * POLL_SCALE)) ]; do
  [ "$(qcount claimed)" -ge 1 ] && break
  sleep 0.2; n=$((n + 1))
done
echo "# human mid-edit" >> check.sh
ida=$(fleet_task_id alpha)
n=0   # add task-b inside the blocked window (15 ticks = 3s at the test tick)
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  [ "$(fleet_phase "$ida")" = "MERGE_PENDING" ] && break
  sleep 0.1; n=$((n + 1))
done
./loop.sh fleet add task-b.md --auto >/dev/null 2>&1
wait_sup "$SUP" add-mergeblocked
check "drain still escalates once b is also merge-pending (exit 3)" add-mergeblocked 3 "$RC"
idb=$(fleet_task_id bravo)
check "the queued add was claimed and ran before the block" add-mergeblocked MERGE_PENDING "$(fleet_phase "$idb")"
check "first task kept MERGE_PENDING" add-mergeblocked MERGE_PENDING "$(fleet_phase "$ida")"
if grep -q '"event": "DRAIN_MERGE_BLOCKED"' .loop/fleet/journal.jsonl; then ok "escalation journaled"; else bad "DRAIN_MERGE_BLOCKED missing" add-mergeblocked; fi
git add check.sh && git commit -qm "human finished editing"
RC=0
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet run --auto --drain > "$WORK/add-mblock2.out" 2>&1 </dev/null || RC=$?
check "restarted drain lands both branches (exit 0)" add-mergeblocked 0 "$RC"
check "both tasks done" add-mergeblocked 2 "$(qcount "done")"
check "parent value fixed" add-mergeblocked fixed "$(cat value.txt)"

section "fleet: standalone --drain approval watchdog exits 3 instead of hanging (FLEET_DRAIN_HUMAN_TICKS)"
# E6: nobody in-process may approve a demoted contract; a standalone drain used
# to spin forever on it. The watchdog escalates to the human WITHOUT committing
# the parent tree (a standalone drain must not `git add -A` a mid-edit tree).
make_fleet_fixture drain-penda
printf 'FLEET_DRAIN_HUMAN_TICKS=10\n' >> fleet.config.sh
RC=0
LOOP_FAKE_CONTRACT_REVIEW=REVISE LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/drain-penda.out" 2>&1 </dev/null &
wait_sup $! drain-penda
check "drain exits 3 on the approval deadlock" drain-penda 3 "$RC"
id=$(fleet_task_id alpha)
check "task still PENDING_APPROVAL (nothing auto-approved)" drain-penda PENDING_APPROVAL "$(fleet_phase "$id")"
if grep -q 'DRAIN_APPROVAL_BLOCKED' .loop/fleet/journal.jsonl; then ok "watchdog journaled as DRAIN_APPROVAL_BLOCKED"; else bad "DRAIN_APPROVAL_BLOCKED missing" drain-penda; fi
if grep -q '^## DR-FLEET-APPROVAL' .loop/docs/decision-requests.md; then ok "decision request written"; else bad "DR-FLEET-APPROVAL missing" drain-penda; fi
st_out=$(git status --porcelain)
case "$st_out" in
  *decision-requests.md*) ok "decision request left UNCOMMITTED (no git add -A over a human's tree)" ;;
  *) bad "drain committed the decision request (or wrote none): $st_out" drain-penda ;;
esac
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run --auto --drain > "$WORK/drain-penda2.out" 2>&1 </dev/null || RC=$?
check "approved re-drain completes (exit 0)" drain-penda 0 "$RC"
check "task done after approval" drain-penda 1 "$(qcount "done")"

section "fleet: standalone --drain zero-progress watchdog exits 4 (DRAIN_STALLED)"
# E6: a stuck shape no other guard covers — a claimed task wedged in a phase the
# dispatcher does not handle (renv corruption / version skew). Not an approval
# wait (that is the watchdog above) and not merge-blocked: without the
# fingerprint watchdog the drain would spin forever. Deterministic construction:
# park a non-auto task in PENDING_APPROVAL (stable hold point), then wedge it.
make_fleet_fixture drain-stall
printf 'FLEET_STALL_TICKS=5\n' >> fleet.config.sh
RC=0
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO=READY_NOW LOOP_FAKE_REVIEW=APPROVE LOOP_FAKE_STOPEVAL=CONTINUE \
  ./loop.sh fleet run task-a.md --drain > "$WORK/drain-stall.out" 2>&1 </dev/null &
SUP=$!
id=""
n=0
while [ "$n" -lt $((150 * POLL_SCALE)) ]; do
  id=$(fleet_task_id alpha)
  [ -n "$id" ] && [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
check "task parked PENDING_APPROVAL (hold point)" drain-stall PENDING_APPROVAL "$(fleet_phase "$id")"
printf 'PHASE=WEDGED\n' >> ".loop/fleet/runs/$id.env"   # renv reads the LAST entry
wait_sup "$SUP" drain-stall
check "stalled drain exits 4" drain-stall 4 "$RC"
if grep -q 'DRAIN_STALLED' .loop/fleet/journal.jsonl; then ok "stall journaled as DRAIN_STALLED"; else bad "DRAIN_STALLED missing" drain-stall; fi
if ! grep -q 'DRAIN_APPROVAL_BLOCKED' .loop/fleet/journal.jsonl; then ok "approval watchdog stayed out of it (needs-human false)"; else bad "wrong watchdog fired" drain-stall; fi
check "wedged task left in claimed/ for inspection" drain-stall 1 "$(qcount claimed)"

section "fleet: approval gate holds without --auto; approve works from another terminal"
make_fleet_fixture fleet-gate
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md --drain > "$WORK/fleet-gate.out" 2>&1 </dev/null &
SUP=$!
id=""
n=0
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  id=$(fleet_task_id alpha)
  [ -n "$id" ] && [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
check "task waits in PENDING_APPROVAL" fleet-gate PENDING_APPROVAL "$(fleet_phase "$id")"
check "parent value untouched while pending" fleet-gate broken "$(cat value.txt)"
LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1 || true
check "non-TTY approve WITHOUT auto never defaults to yes" fleet-gate PENDING_APPROVAL "$(fleet_phase "$id")"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-gate
check "supervisor exit 0" fleet-gate 0 "$RC"
check "approved task completed + merged" fleet-gate fixed "$(cat value.txt)"
if grep -q '"event": "PENDING_APPROVAL"' .loop/fleet/journal.jsonl && grep -q '"event": "AUTO_APPROVED"' .loop/fleet/journal.jsonl; then
  ok "approval flow journaled (LOOP_AUTO bypass audited as AUTO_APPROVED)"
else
  bad "approval events missing" fleet-gate
fi

section "fleet: contract review REVISE demotes --auto to PENDING_APPROVAL; human approve resumes"
make_fleet_fixture fleet-conrev
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" \
  LOOP_FAKE_STOPEVAL="CONTINUE" LOOP_FAKE_CONTRACT_REVIEW="REVISE" \
  ./loop.sh fleet run task-a.md --auto --drain > "$WORK/fleet-conrev.out" 2>&1 </dev/null &
SUP=$!
id=""
n=0
while [ "$n" -lt $((300 * POLL_SCALE)) ]; do
  id=$(fleet_task_id alpha)
  # PHASE is published immediately before the audit row. Require both so this
  # assertion cannot land in that tiny, valid transition window.
  [ -n "$id" ] && [ "$(fleet_phase "$id")" = "PENDING_APPROVAL" ] \
    && grep -q '"event": "CONTRACT_REVIEW_REFUSED"' .loop/fleet/journal.jsonl 2>/dev/null \
    && break
  sleep 0.2; n=$((n + 1))
done
check "REVISE demoted auto-approval to PENDING_APPROVAL" fleet-conrev PENDING_APPROVAL "$(fleet_phase "$id")"
if grep -q '"event": "CONTRACT_REVIEW_REFUSED"' .loop/fleet/journal.jsonl; then ok "refusal journaled"; else bad "CONTRACT_REVIEW_REFUSED missing" fleet-conrev; fi
if [ -f "$(fleet_wt "$id")/.loop/contract-review-feedback.md" ]; then ok "reviewer feedback left in the worktree"; else bad "feedback missing in worktree" fleet-conrev; fi
check "parent value untouched while demoted" fleet-conrev broken "$(cat value.txt)"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve "$id" </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-conrev
check "supervisor exit 0" fleet-conrev 0 "$RC"
check "human-approved task completed + merged" fleet-conrev fixed "$(cat value.txt)"

section "fleet: divergent outcomes isolated (A SUCCESS merges, B escalates and is kept)"
make_fleet_fixture fleet-div
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md task-b.md --drain > "$WORK/fleet-div.out" 2>&1 </dev/null &
SUP=$!
ida=""; idb=""
n=0
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  ida=$(fleet_task_id alpha); idb=$(fleet_task_id bravo)
  [ -n "$ida" ] && [ -n "$idb" ] \
    && [ "$(fleet_phase "$ida")" = "PENDING_APPROVAL" ] \
    && [ "$(fleet_phase "$idb")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "READY_NOW" > "$(fleet_wt "$ida")/.loop/fake-scenario"
echo "DECLARE_SPEC" > "$(fleet_wt "$idb")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve --all </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-div
if [ -f ".loop/fleet/queue/done/$ida.md" ]; then ok "A done"; else bad "A not in done/ ($(fleet_phase "$ida"))" fleet-div; fi
check "B failed with its escalation state" fleet-div NEEDS_SPEC_DECISION "$(fleet_phase "$idb")"
check "A's fix merged into parent" fleet-div fixed "$(cat value.txt)"
if git rev-parse -q --verify "loop/$idb" >/dev/null; then ok "B's branch kept for the human"; else bad "B's branch lost" fleet-div; fi
if [ -d "$(fleet_wt "$idb")" ]; then ok "B's worktree kept"; else bad "B's worktree lost" fleet-div; fi

section "fleet: agents are told about each other (parallel-context, layer 2)"
if grep -q "bravo" "$(fleet_wt "$ida")/.loop/parallel-context.md" 2>/dev/null; then
  ok "A's context lists the sibling task"
else
  bad "parallel-context missing or incomplete" fleet-ctx
fi

section "fleet: unmerged task refuses clean without --force"
./loop.sh fleet clean "$idb" >/dev/null 2>&1
if [ -f ".loop/fleet/queue/failed/$idb.md" ]; then ok "unmerged clean refused"; else bad "unmerged task was cleaned" fleet-div; fi
./loop.sh fleet clean "$idb" --force >/dev/null 2>&1
if [ ! -f ".loop/fleet/queue/failed/$idb.md" ] && ! git rev-parse -q --verify "loop/$idb" >/dev/null; then
  ok "forced clean removes branch + entry"
else
  bad "forced clean incomplete" fleet-div
fi

section "fleet: same-file conflict -> second merge aborts cleanly, branch kept"
make_fleet_fixture fleet-conf
LOOP_CLAUDE_CMD="$FAKE" LOOP_FAKE_SCENARIO="READY_NOW" LOOP_FAKE_REVIEW="APPROVE" LOOP_FAKE_STOPEVAL="CONTINUE" \
  ./loop.sh fleet run task-a.md task-b.md --drain > "$WORK/fleet-conf.out" 2>&1 </dev/null &
SUP=$!
ida=""; idb=""
n=0
while [ "$n" -lt $((450 * POLL_SCALE)) ]; do
  ida=$(fleet_task_id alpha); idb=$(fleet_task_id bravo)
  [ -n "$ida" ] && [ -n "$idb" ] \
    && [ "$(fleet_phase "$ida")" = "PENDING_APPROVAL" ] \
    && [ "$(fleet_phase "$idb")" = "PENDING_APPROVAL" ] && break
  sleep 0.2; n=$((n + 1))
done
echo "READY_NOW" > "$(fleet_wt "$ida")/.loop/fake-scenario"
echo "READY_ALT" > "$(fleet_wt "$idb")/.loop/fake-scenario"
LOOP_AUTO=1 LOOP_CLAUDE_CMD="$FAKE" ./loop.sh fleet approve --all </dev/null >/dev/null 2>&1
wait_sup "$SUP" fleet-conf
n_done=$(qcount "done")
n_conf=0
for f in .loop/fleet/queue/failed/*.md; do
  [ -f "$f" ] || continue
  [ "$(fleet_phase "$(basename "$f" .md)")" = "MERGE_CONFLICT" ] && n_conf=$((n_conf + 1))
done
check "exactly one task merged" fleet-conf 1 "$n_done"
check "exactly one MERGE_CONFLICT" fleet-conf 1 "$n_conf"
check "parent tree clean after abort" fleet-conf "" "$(git status --porcelain -uno)"
if grep -qE '^(fixed|fixed-alt)$' value.txt; then ok "winner's change landed intact"; else bad "parent value corrupted: $(cat value.txt)" fleet-conf; fi

