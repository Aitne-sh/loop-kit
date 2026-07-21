[← loop-kit](../README.md) · **The parallel fleet**

> Decomposition, phased workflows, worktree isolation, the task queue, and the guards
> that keep a supervisor from hanging or corrupting the queue.

# Running tasks in parallel (the fleet)

By default, you do not need to choose between a single run and parallel execution.
After approval, a **decomposition step** splits the contract into tasks and picks
the shape:

- **One task** → the classic loop runs in place (no overhead).
- **Several tasks** → they run as a **fleet**: one supervisor, each task in its own git
  worktree and branch, running the same loop engine, with results merged back one at a
  time and the merged whole reviewed against the original contract.

The decomposer itself runs **read-only** and only returns a plan payload; the harness
stages it as an untrusted candidate under the ignored `.loop/plan-candidates/`, runs a
deterministic validator over it — unique task ids, dependencies that resolve and don't
form a cycle, and every requirement covered: owned by exactly one task, or shared by
tasks with a single *completing owner*: a strictly sequential dependency chain, or a
fork-join whose final task depends on every other owner (a *phased workflow*, below) —
then has an independent read-only session review the candidate, re-validates the exact
staged bytes, and only then publishes `.loop/docs/task-plan.md` (git-tracked, so you can
audit it). A rejected candidate gets one retry: the validator's feedback
(`.loop/decompose-feedback.md`) names each violation precisely and ends with the rejected
attempt verbatim, so the retry fixes only what was named instead of re-deriving the plan
(and re-breaking what was already right). Prose before the envelope's opening marker is
tolerated — extraction is marker-bounded; a stray marker or duplicate verdict still
rejects. A decomposer that touches project files or Git state instead stops the run as
`RISK_REQUIRES_APPROVAL`. You can preview a plan without running (`./loop.sh decompose`),
force one in-place loop with `./loop.sh run --single`, or disable decomposition for the
project with `FLEET_DECOMPOSE=0`.

## Phased workflows — how long-running work is split

A task too large for one worker (as a guide: more than ~6–8 focused iterations, or a diff
no reviewer can hold in one gate review) is not emitted as one giant task. The decomposer
splits it into **phases**: separate tasks connected by `DEPENDS`, allowed to
share the same requirement id — the validator accepts a shared REQ *only* when it has a
single **completing owner**, the one task that depends (directly or transitively) on every
other owner and certifies the REQ in full. Two shapes qualify: a totally-ordered
sequential chain, and a **fork-join** — parallel branches whose join task also owns the
REQ and depends on all of them (join-less parallel sharing is rejected deterministically).
Phases mix freely with parallel tasks in one plan, e.g.:

```
phase 1: task1 ∥ task2 ∥ task3-a     (independent -> parallel)
phase 2:                 task3-b     (DEPENDS: task3-a)
phase 3:        task3-c ∥ task3-d    (both DEPEND on task3-b, disjoint branch scopes)
phase 4:                 task3-e     (DEPENDS: task3-c,task3-d — the completing owner)
```

Here `task3-c`, `task3-d` and `task3-e` may all share one REQ: the join `task3-e`
integrates both branches, *reconciles* any conflicting decision or assumption they made
in isolation (each branch runs blind to the other), and certifies the REQ (with distinct
REQs per branch the same shape works without any sharing).

There is no global phase barrier — each task starts the moment *its* dependencies have
merged, so a slow `task1` never holds up `task3-b`. Each phase is an ordinary fleet task:
own worktree branched from the merged predecessor, own sub-contract, own gate review, own
serial merge — which is the point: review and merge granularity stay bounded no matter how
big the overall change is, and every session works with a small context.

What connects the phases:

- **Phase context.** A later phase's worktree receives each merged predecessor's archived
  sub-contract, evidence report, and assumptions ledger — direct *and* transitive ancestors —
  under `.loop/phase-context/<id>/`: the *why* behind
  the code it inherits (decisions, known gaps, recorded assumptions). A fork's join reads its
  branches' assumption ledgers to *reconcile* any conflicting decision they made in isolation.
  Advisory only: a
  predecessor's "met" claims are phase-scoped, and the master integration gate remains the
  sole authority on master requirements.
- **Phase-boundary plan review** (`FLEET_PLAN_REVIEW`). When a task with queued dependents
  merges — or (`FLEET_PLAN_REVIEW_ON_DRIFT`) any merged phase that recorded drift while
  queued work remains, so an independent phase's drift can re-plan the remainder too — a
  read-only supervisor call re-judges the *queued* remainder of the plan against
  the merged reality: **KEEP** (default), **REVISE** (replace still-unclaimed tasks —
  REQ-conserving, deterministically validated, capped by `FLEET_MAX_PLAN_REVISIONS`; a
  REVISE naming a forked REQ replaces all of its queued owners as a unit), or
  **ESCALATE** (a human must re-decide; all queued phases stay held until you decide and run
  `./loop.sh fleet ack-plan <merged-id>` — rerunning without the ack stops at the same
  decision request, never a silent release). Claimed or merged work is never touched.
- **Mid-run splitting.** A worker that discovers its remaining work exceeds its iteration
  budget declares `NEEDS_DECOMPOSITION` at a clean commit boundary (a deterministic
  *split nudge* prompts it to consider this once `SPLIT_NUDGE_AT`% of the budget is spent
  with requirements still unmet). The supervisor then REPLANs it into phases — a chain,
  or a fork-join when the remainder genuinely parallelizes — and
  with `FLEET_SPLIT_CARRYOVER=1` the block's unique first phase is *seeded* with the
  escalated task's committed work (merged in at bootstrap; a conflict — or a fork with
  two roots — skips the carryover, journaled, and the work stays on the archived branch —
  never lost, never merged ungated).

## How parallel work is isolated

Coordinating parallel agents is where naive setups corrupt each other's work. loop-kit
uses two layers to reduce accidental cross-task interference:

1. **Working-tree isolation.** Each task runs in its own Git worktree, so ordinary
   file edits stay out of sibling working trees. This is an orchestration boundary,
   not an OS security boundary: a same-user process with unrestricted Bash can still
   reach sibling paths.
2. **Explicit awareness.** On every tick the supervisor rewrites a
   `.loop/parallel-context.md` file inside each worktree listing the sibling tasks (running
   / waiting / merged / stopped) and a reminder to stay in its own lane. The loop's prompts
   read that file early — before doing task work — and obey its scope rules, so even a
   merged or stopped sibling's work won't get silently reimplemented or rolled back.

Merges follow the **Refinery pattern**: finished branches land in `main` one at a time with
`git merge --no-ff`, and only when the parent tree is clean. Because every run also edits
`.loop/docs/**`, the parent's copy always wins there and the run's own contract + evidence
are archived under `.loop/docs/run-archive/<id>/`. A real conflict in *your* code aborts
the merge and hands it to you — the branch is kept, nothing is lost.

## Driving the queue by hand

The queue is also usable directly. There is always **exactly one supervisor per
repository** (enforced with a lock — a second `fleet run` just tells you to use `add`),
because running two dispatchers against one repo is a well-known way to corrupt a queue.

```bash
cd your-project
./loop.sh fleet run task-a.md task-b.md   # queue two tasks and start the supervisor
                                          # (foreground; Ctrl-C stops every loop safely)

# From another terminal, while it runs:
./loop.sh add task-c.md                   # add a task any time (picked up next tick)
./loop.sh add "fix the typo in the README"   # a plain instruction works too, not just a file
./loop.sh add task-d.md --after task-a    # run only after task-a has merged
```

`add` works in every phase: **before the first run** the task is parked in the queue
and dispatched alongside the decomposed plan when `./loop.sh run` starts (decomposition
is not suppressed; with `--single`, `FLEET_DECOMPOSE=0`, or a plan that decomposes to a
single in-place task, parked tasks stay queued for a later `./loop.sh fleet run`).
**During a single-loop run** the task is queued but not picked up mid-run — dispatch it
after the run finishes: `./loop.sh fleet run`.

This is also why `start` never resets a run that is already in flight. If one is,
`./loop.sh start "<instruction>"` (and `auto "<instruction>"`) routes the instruction to
the task queue instead — exactly what `./loop.sh add` does. A running supervisor picks it
up on its next tick; beside a single-loop run, dispatch the queue once that run finishes
with `./loop.sh fleet run` (a bare `./loop.sh run` dispatches it only when the contract
decomposes into parallel tasks). Defining a genuinely *new* task requires the current run
to stop first.

```bash
./loop.sh fleet approve <id>              # review + approve a task's contract
./loop.sh fleet status --overlap          # every task's state, plus files touched by 2+ branches
./loop.sh fleet report <id>               # evidence and cost for one task
./loop.sh fleet clean --done              # remove worktrees/branches for merged runs
```

A task's state is simply which queue directory it sits in, and every transition is an
atomic rename (the classic maildir trick — no locking needed):

```
add → queue/new/ → claimed/ (worktree → contract → await approval → running → merged)
                              → done/ (merged)  |  failed/ (blocked / escalated / conflict)
```

## Cancelling the queue

`./loop.sh fleet stop <id>` is a resumable pause for one task. To permanently cancel the
whole active plan — and optionally roll back what it already merged — see
**[Cancelling a plan (`discard`)](discard.md)**.

<details>
<summary>Fleet details: approvals, escalations, dependencies, and the guards that keep it from hanging</summary>

- **The approval gate still applies in parallel.** Each task's contract is generated and
  then waits in `PENDING_APPROVAL`; only what you approve with `./loop.sh fleet approve
  <id>` runs. `--auto` (or `LOOP_AUTO=1`) approves automatically — but even then each
  contract must first pass the independent contract review, and a rejection demotes that
  task back to `PENDING_APPROVAL` with feedback instead of running an unvetted contract.

- **Dependencies serialize.** A task added `--after <id>` (or given `DEPENDS_ON` by the
  decomposer) is only claimed once its dependency has *merged*, so its worktree contains
  that code. Adding `--after` a task that has already failed is refused (it would just
  park) unless you force it with `--force-after`.

- **Mid-run escalations go to the supervisor first.** When an orchestrated task hits a
  decision, a read-only supervisor call decides: **ANSWER** (the harness writes
  guidance into the worktree and the task relaunches), **REPLAN** (swap the task for
  better-scoped replacements — possibly a phased chain or fork-join — keeping the old
  one for autopsy), or **ESCALATE** (park it for you). This is capped per task
  (`FLEET_MAX_SUPERVISE_PER_TASK`). Tamper-class stops (`RISK_REQUIRES_APPROVAL`) are
  *never* supervised — always a human.

- **The supervisor keeps one conversation, files stay the truth.** Supervisor calls
  (task decisions and phase-boundary plan reviews) resume one conversational session
  (`FLEET_SUPERVISOR_SESSION`) so repeat calls don't re-read everything from scratch.
  The session is a cache, never authority: it is dropped and restarted on any call
  failure, unparseable verdict, orchestration restart, the `FLEET_SUPERVISOR_SESSION_MAX`
  cap — and after every applied plan mutation, so a stale conversational view of the
  plan can never outlive the files. Every payload it produces still passes the same
  deterministic validators either way.

- **The integration gate is the real finish line.** Individual task success isn't enough:
  the *merged whole* is reviewed against the original (master) contract — a gate review, a
  master evidence report, and `evaluate.sh` over the full combined diff. A "needs revision"
  here buys a bounded number of supervisor fix-up rounds
  (`FLEET_MAX_INTEGRATION_FIXUPS`), then SUCCESS or BLOCKED. (The gate always reviews, even
  if `REVIEW_MODE=off` — that setting only governs the per-iteration loop.)

- **The autonomy boundary is yours, enforced by the machine.** *Within* the approved
  master contract the supervisor decides on its own and logs everything. Anything that
  would *change* the master contract always stops for you.

- **Fleet liveness is monitored.** A stall watchdog (`FLEET_STALL_TICKS`) stops a
  supervisor that makes no progress; a task waiting on approval surfaces as a
  decision request; and a `--drain` that can only merge into a dirty parent exits
  after about 30 seconds with a recovery command. Project verification and worktree
  setup commands still need their own timeout if they can hang.

- **A task added mid-run is picked up in that run** — even during the integration gate,
  which re-scans the queue. But a mid-run `add` runs as a *manual* task outside the master
  contract (it warns you), and if it fails, the planned work still completes and merges;
  the failure surfaces at the end as a decision request rather than aborting everything.

The full manual surface is `./loop.sh fleet <run | add | approve | status | report | logs
| discard | stop | resume | ack-plan | merge | clean | unlock>`; run `./loop.sh fleet help`
for the details.
</details>

<details>
<summary>Operational notes for parallel runs</summary>

- Worktrees are created *outside* the repo, in `../<project-name>-loops/<task-id>/`, so
  the parent's test runner and `grep` don't pick up N copies of everything (override with
  `LOOP_WORKTREE_ROOT`). **`git clean -dfx` in the parent won't remove them** — always use
  `./loop.sh fleet clean`, which calls `git worktree remove` correctly.
- Worktrees isolate files, **not** ports, databases, or global caches. Each run gets a
  `LOOP_FLEET_INDEX` (1, 2, 3, …) you can use to offset those in your verify commands.
- **All parallel runs share your subscription's rate limit**, so keep `FLEET_MAX_PARALLEL`
  modest. If the rate window runs out, several runs may go BLOCKED together; once it resets,
  `./loop.sh fleet resume <id>` continues each from its checkpoint rather than restarting.
- The first line of each task's instructions is copied into every sibling's
  `.loop/parallel-context.md`. If you paste task text from an untrusted source, be aware
  that's a channel for information to flow between worktrees.

</details>

<details>
<summary>Design rationale (primary-source research)</summary>

- What a supervisor needs to be — a race-safe queue plus serialized merge integration:
  [Gas Town](https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04) (the Refinery
  pattern lands changes one at a time) / [MultiDevin](https://cognition.com/blog/devin-can-now-manage-devins)
  (1 manager + N workers) / [Claude Code agent teams](https://code.claude.com/docs/en/agent-teams).
- Parallelizing *independent* tasks doesn't need an LLM decomposer:
  [Anthropic's multi-agent research system](https://www.anthropic.com/engineering/built-multi-agent-research-system)
  ("coding parallelizes far less cleanly than research does") /
  [Cognition: Don't Build Multi-Agents](https://cognition.com/blog/dont-build-multi-agents).
- One long-lived dispatcher + an appendable queue is the pattern everyone converges on:
  [GNU parallel jobqueue](https://www.gnu.org/software/parallel/parallel_examples.html) /
  [claude-task-master](https://github.com/eyaltoledano/claude-task-master) /
  [beads](https://github.com/steveyegge/beads). Multiple concurrent dispatchers have real
  reported split-brain failures.
- File-based queues via atomic rename ("no locking required at all"):
  [D. J. Bernstein: maildir](https://cr.yp.to/proto/maildir.html).
- Worktree isolation is Claude Code's own recommendation for parallel sessions:
  [worktrees](https://code.claude.com/docs/en/worktrees); `git worktree add` and merges
  still need to be serialized through one place
  ([reported lock contention](https://github.com/anthropics/claude-code/issues/55724)).

</details>
