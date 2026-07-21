[← loop-kit](../README.md) · **Tests**

> The zero-token regression suite: how to run it, what it covers, and what it
> deliberately does not.

# Tests

```bash
tests/run_tests.sh                      # everything (parallel lane, then the serial lane)
tests/run_tests.sh -j1                  # strict manifest order, one process (baseline mode)
tests/run_tests.sh --list               # every suite file and its lane
tests/run_tests.sh --only 50-discard    # just one area, while iterating
LOOP_TEST_TIMING=1 tests/run_tests.sh   # + a slowest-sections table
```

The parallel lane runs at `-j` (default: cores − 1, capped at 4, because the suite shares
the machine with agent sessions — raise it explicitly on an idle box), and the run ends
with a `shellcheck` gate over the harness, the evaluator, and the suite files themselves.

The assertions live in `tests/suite/NN-*.sh`, one file per area, each sourcing the shared
`tests/lib.sh`; `tests/run_tests.sh` is the driver that runs them and aggregates the counts.
Files listed as `parallel` in `tests/suite/manifest.txt` run concurrently, then the small
`serial` lane — the tests whose subject is process identity or wall-clock timing — runs alone.

The suite runs fake Claude and Codex agents (`LOOP_CLAUDE_CMD` and `LOOP_CODEX_CMD`) to
drive every terminal state end to end — more than 1,800 assertions at zero token cost.
It covers review and stop-eval, the pre-approval contract review, verdict parsing,
counter separation, forced and fail-closed gates, agent/model routing, Codex sandbox mapping
and envelope normalization, the tamper defenses, the
off-tree approval store, the full resume matrix (auto-resume, resume-by-id, budget-raise
continuation, the decision rebind, the `MAX_RESUMES` backstop), and the whole fleet:
queue atomicity, dynamic add + drain grace, the approval gate, isolation, serialized
merges, conflict aborts, the singleton lock, crash/interrupt recovery, decomposition and
its validator, master-contract injection and tamper restore, dependency gating,
supervision (answer / replan / escalate), the integration gate, the stall/approval
watchdogs, and the `MAX_RUN_SECONDS` cap.

Tests shorten the harness's real-time sleeps via `LOOP_WATCHDOG_POLL` / `LOOP_FLEET_TICK`,
and every wait on the supervisor is bounded — a hang shows up as a FAIL, not a silent block.
