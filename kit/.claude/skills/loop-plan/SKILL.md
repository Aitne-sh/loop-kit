---
name: loop-plan
description: Create or refresh .loop/docs/implementation-plan.md from the approved product contract — milestone breakdown for the iteration loop. Invoked by loop.sh at iteration 0; can also be run manually to re-plan.
---

# Create the Implementation Plan

Explore before you plan — a plan written blind schedules the wrong work. In order:

1. Read `.loop/docs/product-contract.md` (the fixed contract) and its REQ list.
2. Locate the files/modules each REQ touches (search the codebase; never guess).
3. Find the real verification commands (`VERIFY_COMMANDS` in `loop.config.sh`,
   manifests/CI config) and run the cheap ones once to see their current status.
4. Note the conventions the work must follow (structure, framework, idioms of
   the surrounding code).
5. Note the risky areas (auth, schema/migrations, secrets, prod config,
   dependency manifests) — feed them into the risk-first ordering below.
6. If `.loop/docs/run-archive/` exists, skim the "Lessons for future runs"
   section of the **most recent 3** archived `evidence-report.md` files (just
   that section — do not re-read whole archives): past runs' design decisions,
   rejected approaches, and repository traps. Fold anything that applies into
   `## Key decisions` or the milestone hints below.
7. Only then write `.loop/docs/implementation-plan.md` (replace the template
   content, remove the `<!-- TEMPLATE -->` marker).

Rules:
- **Write the plan's prose in the same language as `.loop/docs/product-contract.md`**
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
  remains.
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
  simply never be met. (Later revisions may reshape milestones freely but must
  keep every not-yet-met REQ covered.)
- Include a testing milestone if the contract's acceptance criteria require new
  tests (VERIFY_COMMANDS in loop.config.sh must be able to prove the new behavior).
- Keep it short — a working checklist, not a design document.

Do not implement anything in this step. Write the plan file and stop.
