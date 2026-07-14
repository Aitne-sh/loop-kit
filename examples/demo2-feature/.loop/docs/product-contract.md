# Product Contract — demo2: add a `stats` CLI subcommand

## Goal

mathkit gains a command-line interface: `python -m mathkit stats <numbers...>`
prints summary statistics for the given numbers, with input validation. Existing
library behavior is unchanged.

## Requirements

### REQ-001: module entry point
`uv run python -m mathkit stats 1 2 3` works (a `__main__` entry exists).

### REQ-002: stats output
The `stats` subcommand prints, one per line, in this order:
`count: N`, `mean: X`, `median: X`, `min: X`, `max: X` for the given numbers.

### REQ-003: input validation
No numbers given, or any argument that is not a number, prints a clear error
message to stderr and exits with code 2. An unknown subcommand also exits 2.

### REQ-004: tests
New tests cover the CLI: the success path and both invalid-input cases. They run
under `uv run pytest -q` together with the existing tests.

## Non-goals

- Other subcommands, plotting, reading numbers from files or stdin
- Changing the existing `mean`/`median`/`clamp` APIs
- External dependencies (argparse etc. from the stdlib only)

## Constraints

- Python stdlib only — adding a dependency requires human approval
  (pyproject.toml is an escalate path)
- `tests/test_stats.py` (the existing suite) must not be modified; add new test files
- Existing tests keep passing

## Acceptance Criteria

- `uv run pytest -q` exits 0, including the new CLI tests
- The evidence report shows each REQ satisfied with a pointer to the code/test

## Validation Commands

- `uv run pytest -q`

## Human Approval Required If

- A dependency must be added
- The existing test suite must change
- The CLI surface should differ from REQ-002 (e.g. different output format)
