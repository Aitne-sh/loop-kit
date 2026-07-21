[← loop-kit](../README.md) · **Writing the contract**

> The contract is the one artifact you are really responsible for. This page covers
> its sections, the right level of granularity, and a worked example.

# The contract — what you lock down

The contract is the one thing you're really responsible for getting right. The trick is
**granularity**: pin the *what*, leave the *how* free.

```
✗ too vague:      "make a nice agent-creation feature"
✗ too rigid:      "build AgentCreateForm.tsx with Zustand and fields x, y, z"
✓ just right:     "Users can create, edit, delete, and list agents. An agent has a
                   name, a prompt, and skills. An invalid MCP config can't be saved.
                   Running agents is out of scope. Existing lint/typecheck/test/build
                   stay green."
```

A contract has a small, fixed set of sections (there's a template at
`.loop/docs/product-contract.md`): **Goal**, **Requirements** (numbered `REQ-001`,
`REQ-002`, …), **Non-goals**, **Constraints**, a **Quality baseline** (bars that must
stay true, like "no new lint warnings"), **Acceptance Criteria**, **Validation Commands**
(the human-readable mirror of `VERIFY_COMMANDS`), and **Human Approval Required If** (the
escalation bar).

The definition session also digs *below* the stated requirements before anything is
locked. It inventories what already works in the blast radius (a migration must not lose
behavior users can see), expands the taken-for-granted expectations of a 0→1 build
("Mario-like" implies stomp-kills, pit death, game-over), and runs a premortem — "every
gate is green and the user is still disappointed: why?" Each resulting expectation
becomes a row of `.loop/docs/acceptance-checklist.md` with a verification method
(`cmd` / `run` / `human`). If a behavior is observable only at runtime, the gate must
include a runtime observation, proven to work headlessly (a contract-time spike) before
it becomes binding — a lesson learned the hard way from gates that were all green while
the page rendered nothing.

> **`REQ-` ids are also the unit of parallelism.** When the harness splits a contract into
> parallel tasks, each requirement is normally owned by exactly one task. The one exception
> is a REQ *shared across phases of one piece of work* with a single **completing owner** — a
> strictly sequential chain, or a fork-join whose join owns the REQ and depends on every
> branch (see [Phased workflows](fleet.md#phased-workflows--how-long-running-work-is-split)). Outside
> that case a REQ cannot be shared or split, so give independently-deliverable pieces of work
> their own `REQ` ids.

<details>
<summary>Example: the demo1 bug-fix contract</summary>

```markdown
# Product Contract — demo1: fix the failing tests

## Goal
All tests in `tests/` pass. The tests are correct as written; the bugs are in
`src/mathkit/`. Fix the implementation, not the tests.

## Requirements
### REQ-001: mean
`mean(xs)` returns the arithmetic mean of a non-empty sequence and raises
`ValueError` on empty input.
### REQ-002: median … ### REQ-003: clamp …

## Non-goals
- New features, API changes, performance work / any change to the tests /
  refactoring beyond what the fixes require

## Constraints
- `tests/**` must not be modified (a denied path)
- No new dependencies (`pyproject.toml` is an escalate path)

## Acceptance Criteria
- `uv run pytest -q` exits 0 with all tests passing

## Human Approval Required If
- Any test appears wrong and would need changing / a dependency must be added
```

The matching `loop.config.sh` sets `VERIFY_COMMANDS=("uv run pytest -q")`, lists the
tests under `DENIED_PATHS`, and puts `pyproject.toml` under `ESCALATE_PATHS`. Notice the
contract fixes only *what* ("the tests pass") and never *how* to fix it — that is the
whole idea in one file.
</details>
