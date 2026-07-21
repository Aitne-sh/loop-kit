---
name: loop-plan
description: Read-only implementation planning from the approved product contract — return a complete implementation-plan payload for the harness to publish. Invoked by loop.sh at iteration 0; manual invocation drafts a replacement but does not publish it.
---

# Create the Implementation Plan

**STOP — you are a planner, not an implementer. This session is read-only.**
Do not create, edit, delete, or rename any repository or `.loop/` file. Do not
run tests, checks, builds, formatters, generators, or other side-effecting
commands. Explore with read-only evidence and return the complete future
contents of `.loop/docs/implementation-plan.md`; when this role is invoked by
`loop.sh`, the harness alone validates and publishes it.

Explore before you plan — a plan written blind schedules the wrong work. In order:

1. Read `.loop/docs/product-contract.md` (the fixed contract) and its REQ list.
2. Read `.loop/plan-feedback.md` if it exists — the deterministic validator
   rejected your previous plan; fix EVERY listed violation. When the file ends
   with a `--- PREVIOUS REJECTED ATTEMPT (verbatim) ---` block, that is your
   own prior plan: resubmit it with ONLY the listed violations corrected and
   every other line unchanged — do NOT re-derive the plan from scratch.
3. Read `.loop/plan-review-feedback.md` if it exists — the independent reviewer
   rejected your previous plan; address every must-fix item. It also ends with
   the rejected plan verbatim: revise that plan against the feedback, keeping
   the parts the reviewer did not challenge.
4. Locate the files/modules each REQ touches (search the codebase; never guess).
5. Find the real verification commands (`VERIFY_COMMANDS` in `loop.config.sh`,
   manifests/CI config). Identify which checks are cheap from their definitions,
   existing logs, and repository evidence, but do NOT execute them in this
   read-only planning step and do not invent a current PASS/FAIL result.
6. Note the conventions the work must follow (structure, framework, idioms of
   the surrounding code).
7. Note the risky areas (auth, schema/migrations, secrets, prod config,
   dependency manifests) — feed them into the risk-first ordering below.
8. If `.loop/docs/run-archive/` exists, skim the "Lessons for future runs"
   section of the **most recent 3** archived `evidence-report.md` files (just
   that section — do not re-read whole archives): past runs' design decisions,
   rejected approaches, and repository traps. Fold anything that applies into
   `## Key decisions` or the milestone hints below.
9. If `.loop/docs/implementation-plan.md` already contains a non-template plan,
   use it as mutable historical context, not as authority over the contract —
   a re-plan was requested because that plan is missing, template-only, or
   being deliberately replaced; never preserve a stale milestone merely
   because its REQ id still exists. Only then return a complete replacement
   payload with no `<!-- TEMPLATE -->` marker.

Rules:
- **Write the plan payload's prose in the same language as `.loop/docs/product-contract.md`**
  (it mirrors the user's original instruction). Keep the checkbox syntax, file
  paths, commands, and identifiers in ASCII.
- If `.loop/parallel-context.md` exists, read it first: other loops are running
  in parallel in separate worktrees. Keep every milestone inside THIS task's
  scope — never plan work that another listed task owns, and never plan to
  "fix" things that look missing here (they may live in another worktree).
- If `.loop/phase-context/` exists, read it before planning: this task is a
  later phase of a chained workflow and each `<predecessor-id>/` holds a
  completed phase's sub-contract + evidence. Plan ONLY this phase's increment
  on top of the merged predecessor work — never a milestone that re-does or
  re-verifies a predecessor's scope, and never treat a predecessor's
  phase-scoped "met" as the shared master REQ being finished.
- If `.loop/docs/unknowns.md` is filled in, read it before planning: the
  interview decisions, direction verdicts, and deferred defaults recorded at
  intake constrain the plan.
- Open the plan with a short `## Key decisions` section (3–7 one-liners, each
  citing the contract section or unknowns.md entry it comes from) —
  fresh-context iterations re-read this recap, not the full intake record.
- **Risk-first ordering**: among orderings where every milestone leaves the
  repo in a passing state (the rule below still wins), schedule the milestones
  that exercise the riskiest decisions and feasibility unknowns EARLIEST — if
  the run is going to need a human decision, fail fast while iteration budget
  remains. An acceptance-checklist `run` row recorded in unknowns.md as
  `unproven — agent-environment dependent` (an agent browser channel: the
  executing agent's own browser skill/MCP connector) is exactly such a
  feasibility unknown — schedule its FIRST observation attempt in an early
  milestone so a missing capability stops the loop for the human while
  budget remains. The plan carries such checks as proposals: never silently
  reclassify, weaken, or drop them because the channel might be unavailable.
- The plan is **mutable**: later iterations may and should revise it as they learn.
  The contract is **immutable**: never edit it here.
- Break the work into **small milestones**, each independently verifiable and
  completable in a single iteration by an agent with fresh context. Order them so
  every milestone leaves the repo in a passing state for existing checks.
- For each milestone: a checkbox, what "done" observably means, **which REQ-xxx
  ids it advances**, and the files or areas likely involved (as hints, not
  mandates). Every contract REQ must be covered by at least one milestone —
  requirement satisfaction is tracked per REQ in
  `.loop/docs/requirements-ledger.md`, and a REQ no milestone advances will
  simply never be met. Keep completed milestones as checked history. Later
  revisions may reshape pending work, but the checkbox rows under `## Milestones`
  must contain the exact set of contract REQ ids: every contract id at least once
  and no unknown id. A REQ may appear in several milestones; ids mentioned in
  another section do not count. Every milestone checkbox row must name at least
  one exact REQ token. Never delete a completed REQ's last row.
- Include a testing milestone if the contract's acceptance criteria require new
  tests (VERIFY_COMMANDS in loop.config.sh must be able to prove the new behavior).
- Keep it short — a working checklist, not a design document.

## Output — implementation-plan payload

Return exactly one ordered envelope containing the complete future file, in
this shape:

```
<!-- IMPLEMENTATION-PLAN-BEGIN v1 -->
# Implementation Plan

## Key decisions

- <3-7 contract/unknowns-backed decisions>

## Milestones

- [ ] M1: <small milestone> — advances <REQ ids>; done when <observable check>; likely areas: <paths/areas>

## Current blockers

- <current blocker, or None>

## Notes / learnings

- <read-only planning evidence that later iterations need>
<!-- IMPLEMENTATION-PLAN-END -->
```

The file schema is fixed: exactly one `# Implementation Plan` heading, followed
by exactly one each of `## Key decisions`, `## Milestones`,
`## Current blockers`, and `## Notes / learnings` in that order. Do not add,
rename, duplicate, or omit a level-two section, and do not add any other
heading. `## Key decisions` contains 3–7 plain bullet rows; `## Milestones`
contains at least one checkbox row; `## Current blockers` and
`## Notes / learnings` each contain at least one plain bullet row (use `None`
when there is no current blocker).

The payload must cover every contract REQ, contain no envelope marker inside
the plan body, and contain no `<!-- TEMPLATE -->` marker. Before the opening
marker, emit nothing (empty lines only); do not wrap the actual envelope in a
code fence and do not claim that you wrote the file. After the closing marker,
the final non-empty line of your reply must be exactly:

`PLAN: READY`

Emit exactly one envelope and one verdict line. Write nothing after the verdict
and invoke no further tool. Do not implement anything in this step.
