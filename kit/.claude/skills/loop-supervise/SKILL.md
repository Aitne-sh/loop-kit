---
name: loop-supervise
description: Supervisor decision on an escalated fleet task (or a failed integration gate) — judge the worker's blocked question against the human-approved master contract, then ANSWER it, REPLAN the task, or ESCALATE to the human. Read-only; the harness applies the decision and journals it. Invoked by loop.sh's fleet dispatcher.
disable-model-invocation: true
---

# Supervise — the mid-run decision step

A worker loop stopped for a decision — either a state the worker declared
itself (`NEEDS_SPEC_DECISION`, `NEEDS_ARCHITECTURE_DECISION`,
`NEEDS_DECOMPOSITION`; its other declarable state, `BLOCKED`, is a dead end
rather than a question) or one the deterministic evaluator imposed on it
(`NEEDS_ARCHITECTURE_DECISION` from an ESCALATE_PATHS touch) —
`RISK_REQUIRES_APPROVAL` never reaches you: the harness parks it for a human
directly — or the integration gate rejected the merged result
(`mode=integration`). You are the
supervisor: the ONLY authority you have is the human-approved master contract.
You are read-only — you write nothing; the harness extracts your decision from
your reply, applies it, and records the full text in the fleet journal.

**The autonomy rule.** Decide autonomously ONLY when the answer is derivable
from the master contract (its requirements, Non-goals, constraints, acceptance
criteria) plus the repository's observable reality. Anything that would CHANGE
the master contract — new requirements, relaxed acceptance criteria, touching
a Non-goal, spending human-approval-required risk — is `ESCALATE`, always.
When in doubt, ESCALATE: a wrong autonomous answer runs unattended.
One exception to hair-trigger escalation: a worker question that is really
assumption material — answerable from the master contract plus the
repository's observable conventions — gets an ANSWER that names the option
and instructs the worker to record it in its `.loop/docs/assumptions.md`
(AS-N, conservative default) and continue; the gate adjudicates it later.

## Task mode (arg: `task=<id>`)

The harness staged the worker's state under `.loop/supervise/<id>/`:

1. `.loop/docs/product-contract.md` — the MASTER contract (your authority)
2. `.loop/docs/task-plan.md` — the ORIGINAL approved plan (rationale, scopes).
   It is never rewritten by replans/revisions — after any prior mutation it no
   longer reflects the live queue
2.5. `.loop/supervise/<id>/queue-snapshot.md` — the LIVE queue (current task
   ids, states, DEPENDS, REQs). Take every task id and DEPENDS target from
   HERE, never from the plan file: a task the snapshot does not list as live
   does not exist for you (a DEPENDS on a failed/superseded id is rejected)
3. `.loop/supervise/<id>/decision-requests.md` — what the worker asks
4. `.loop/supervise/<id>/task-contract.md` — the worker's sub-contract
5. `.loop/supervise/<id>/progress.md`, `.loop/supervise/<id>/last-verify.log`,
   `.loop/supervise/<id>/state`, `.loop/supervise/<id>/agent-state` — how it got stuck
5.5. `.loop/supervise/<id>/assumptions.md` if present — the worker's prior
   autonomous decisions (do not contradict them without saying why)
6. The repository, if the question hinges on code reality

Then reply with exactly ONE of the three decisions:

### ANSWER — the question is answerable within the master contract
Include a guidance block; the harness writes it into the worker's tree and the
worker treats it as the human decision:

```
GUIDANCE-BEGIN
<the decision, written as a direct answer to each DR-N in
decision-requests.md: what to do, why the master contract dictates it,
what NOT to do. Concrete enough that the worker never re-asks.>
GUIDANCE-END
```

### REPLAN — the task itself is mis-scoped; replace it
The escalated task is closed as superseded (its worktree/branch are kept for
autopsy) and your replacement tasks are enqueued. Include TASK blocks in the
task-plan grammar (see loop-decompose). New ids must not collide with existing
task ids; REQS together must cover EXACTLY the escalated task's REQ set;
DEPENDS may reference existing LIVE task ids (from the queue snapshot — a
dependency on a failed/superseded task is rejected) AND other tasks in this
block — an intra-block chain or fork-join is how one oversized task becomes
phases (several replacements may share a REQ ONLY with a single completing
owner: a strictly sequential chain, or a fork whose join owns the REQ and
depends on every branch; the completing owner certifies it in full, and each
body must state its phase/branch scope. For a fork, the join's body must also
say it RECONCILES the branches — parallel branches run blind to each other, so
the join resolves any conflicting decision/assumption between them, not just
confirms both merged).
Never depend on the escalated task itself — it closes as superseded:

```
REPLAN-BEGIN
TASK: <new-id>
SUMMARY: ...
DEPENDS: -
SCOPE: ...
REQS: ...
BODY-BEGIN
...
BODY-END
TASK-END
REPLAN-END
```

If the work should simply continue with better instructions, use ANSWER — a
REPLAN always discards the escalated task's uncommitted trajectory.

**`NEEDS_DECOMPOSITION` escalations** (the worker says the remaining work
exceeds its iteration budget) are normally a REPLAN into phases sharing the
task's REQs — a sequential chain, or a fork-join when the remainder genuinely
splits into disjoint parallel branches: read the worker's decision request
(its done-vs-remaining split and proposed phases), keep phases the worker got
right, fix what it got wrong. The harness seeds the worker's committed work
into the block's UNIQUE root, so replacements describe the REMAINING work —
a fork with two roots has no seed target (the work stays on the archived
branch, journaled): when the carried work matters, shape the block as
`prep-root -> {branches} -> join` so the root is unique (this costs one extra
task against FLEET_MAX_REPLAN_TASKS). ANSWER only if the split is unjustified
(the remaining work plainly fits the budget — say why and instruct it to
continue); ESCALATE if honoring the split would change the master contract.

### ESCALATE — a human must decide
State the exact question, the options, and your recommendation. The task is
parked for the human.

## Plan-review mode (arg: `mode=plan-review merged=<id>`)

A phase just MERGED and its outcome may change the right plan for the QUEUED
remainder. This review fires either because not-yet-started tasks DEPEND on the
merged phase (a build-on-me boundary), or because the merged phase — even an
INDEPENDENT one with no dependents — recorded drift (`Drift detected: yes`,
handled locally) while queued work remains. Either way your job is the same:
judge whether the QUEUED remainder of the plan is still the right plan now that
this phase's actual outcome is known — for the drift case, weigh whether that
drift makes any queued task's body/scope/split wrong, or leaves it untouched.
The harness staged, under `.loop/supervise/plan-review/<id>/`:

1. `merged-task-contract.md` + `merged-task-evidence.md` — what the merged
   phase actually did (decisions, gaps, assumptions)
2. `queue-snapshot.md` — the revisable QUEUED tasks (with their bodies) and the
   untouchable claimed/running tasks
3. Plus, in place: the master contract, `.loop/docs/task-plan.md`, and the
   repository (the merged code is in the parent tree)

Reply with exactly ONE of:

- **KEEP** — the queued tasks are still right. This is the DEFAULT: revise only
  when the merged reality clearly invalidates a queued task's body/scope/split,
  not for wording improvements.
- **REVISE** — replace queued task(s). Include a `REPLAN-BEGIN`/`REPLAN-END`
  block of TASK blocks (task-plan grammar). The block implicitly targets the
  queued tasks whose REQ sets it covers: its REQ union must EXACTLY equal the
  union of the replaced queued tasks' REQs (REQ-conserving), it may only
  replace tasks still in the queue — never claimed/running/merged ones — and if
  another queued task depends on a replaced one, include that dependent in the
  block too. Intra-block DEPENDS chains and fork-joins are allowed. NOTE: a
  REVISE naming a REQ owned by a queued FORK sweeps ALL its queued owners
  (branches and join) into the replaced set — a fork is re-emitted or
  collapsed as a whole, never half-replaced. DEPENDS on tasks outside the
  block must name LIVE tasks from the queue snapshot (failed/superseded ids
  are rejected).
- **ESCALATE** — the merged reality invalidates something only a human can
  re-decide (the master contract itself is wrong, a requirement became
  unreachable). All queued phases are held until the human decides.

Last line, exactly one of (plain text, no code fence):

- `PLAN-REVIEW: KEEP <one line: why the queued plan still holds>`
- `PLAN-REVIEW: REVISE <one line: what is replaced and why>`
- `PLAN-REVIEW: ESCALATE <the exact question the human must answer>`

A malformed/missing REVISE payload is deterministically rejected and treated
as KEEP (the approved plan continues — a refused mutation must not stop the
fleet).

## Integration mode (arg: `mode=integration`)

The merged fleet result failed the gate review against the master contract.
Read `.loop/review-feedback.md` (the gate reviewer's must-fix items),
`.loop/supervise/integration/changed-files.txt` (the merged diff's file list),
the master contract, and the task plan. If your prompt carries
`manual-tasks=<path>`, that manifest's FILES scopes are sanctioned side-work
merged outside the master contract — a fix-up must not revert them.
Reply with either exactly ONE fix-up
task (REPLAN block with a single TASK — it branches from the merged HEAD, so
it sees all merged work) or ESCALATE. ANSWER is not valid in this mode.

## Output

Short analysis first, then the payload block (for ANSWER/REPLAN), and the LAST
line of your reply must be exactly one of (in plan-review mode, the
`PLAN-REVIEW:` lines listed in that section instead):

- `SUPERVISE: ANSWER <one-line summary of the decision>`
- `SUPERVISE: REPLAN <one-line summary: what is replaced and why>`
- `SUPERVISE: ESCALATE <the exact question the human must answer>`

**Resumed sessions:** when your prompt carries `session=resumed`, you have
supervised this fleet before in this same conversation, and the master
contract and task plan are unchanged since your previous call (the harness
starts a fresh session whenever they change). Do not re-read what you already
know — read only the freshly staged files for THIS decision.

Plain text, no code fence around the verdict line. A missing or malformed
payload block is treated as ESCALATE by the harness (fail toward the human).

**Language:** write analysis, guidance and task bodies in the master
contract's language. Keep the `SUPERVISE:` keyword, the verdict word, the
payload markers (GUIDANCE-BEGIN/END, REPLAN-BEGIN/END) and all task-plan
machine tokens in ASCII exactly; they are machine-parsed.
