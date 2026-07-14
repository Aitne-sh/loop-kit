# Product Contract — demo1: fix the failing tests

## Goal

All tests in `tests/` pass. The tests are correct as written; the bugs are in
`src/mathkit/`. Fix the implementation, not the tests.

## Requirements

### REQ-001: mean
`mean(xs)` returns the arithmetic mean of a non-empty sequence and raises
`ValueError` on empty input.

### REQ-002: median
`median(xs)` returns the median for sorted or unsorted input (average of the two
middle values for even length) and raises `ValueError` on empty input.

### REQ-003: clamp
`clamp(x, lo, hi)` returns x limited to the inclusive range [lo, hi].

## Non-goals

- New features, API changes, performance work
- Any change to the tests
- Refactoring beyond what the fixes require

## Constraints

- `tests/**` must not be modified (denied path)
- No new dependencies (pyproject.toml is an escalate path)
- Smallest change that makes the tests pass

## Acceptance Criteria

- `uv run pytest -q` exits 0 with all tests passing

## Validation Commands

- `uv run pytest -q`

## Human Approval Required If

- Any test appears wrong and would need changing
- A dependency must be added
