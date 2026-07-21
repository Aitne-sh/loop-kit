[← loop-kit](../README.md) · **States, recovery, and artifact lifecycle**

> What every stop state means, how to resume from each one, and which artifacts
> survive which boundary.

# States, recovery, and artifact lifecycle

## Resuming after a crash, stop, or escalation

Every run keeps a durable checkpoint (`.loop/run-checkpoint`, rewritten at the top of each
iteration) recording the iteration number, the streak counters, the running cost, and the
run review baseline. A separate, off-tree `task-start-ref` records the fixed commit at which
the task first began — not the start of each run — and survives `--fresh`, so retries still
review the whole task and cannot relabel already-committed task work as `NO_OP`.
So a run that dies partway **continues where it left off** instead of restarting from
iteration 1 and re-spending your whole budget.

| Situation | State | How to resume |
|---|---|---|
| Crash / Ctrl-C / machine died | `RUNNING` / `INTERRUPTED` | Just `./loop.sh run` — it **auto-resumes** (counters, cost, and any uncommitted work restored). `./loop.sh run --fresh` forces a clean restart. |
| Terminal failure | `BLOCKED` / `STALLED` | Fix the cause, then `./loop.sh resume` (iteration and cost intact; the stop-heuristic streaks — stagnation, futility, repeat-fail fingerprints, review rejections — get a **fresh window** so one repeat can't instantly re-block a legitimately fixed run). Pass what changed with `./loop.sh resume --note '<guidance>'` — the note reaches the next iteration as the human decision and is journaled as `RUN_NUDGE`. A bare `run` starts fresh. |
| Ran out of iterations | `BUDGET_EXCEEDED` | Raise `MAX_ITERATIONS`, `./loop.sh approve`, then `./loop.sh resume`. A budget-only re-approval is recognized and continues under the bigger cap. |
| Rate / usage limit (transient) | `BLOCKED` (api-stall guidance) | Nothing is wrong with your loop — **wait for the limit to reset, then `./loop.sh resume`** (checkpoint and counters intact). The stop shows this wait-and-retry guidance instead of the sign-off box; if it keeps failing, check `.loop/logs/failed/` and the routed Claude/Codex CLI's authentication. |
| An escalation (`NEEDS_*` / `RISK_*`) | needs your answer | **Never auto-resumes.** Make the call (edit the contract if needed), then `./loop.sh approve` re-binds the checkpoint to the new approval, and the next `./loop.sh run` resumes with counters and cost intact. |
| A plan-review escalation (phase boundary) | `NEEDS_SPEC_DECISION`, queued phases held | Decide the `DR-FLEET-PLAN-*` question (edit/clean the queue if needed), acknowledge with `./loop.sh fleet ack-plan <merged-id>`, then `./loop.sh run`. A rerun **without** the ack stops at the same request — restarts never release the held phases silently. |

Runs and fleet tasks are also resumable by id:

```bash
./loop.sh resume --list        # every session, its phase, and whether/how it resumes
./loop.sh resume <task-id>     # flip a stopped task runnable AND dispatch it
./loop.sh fleet clean --orphans   # garbage-collect worktrees/branches that lost their queue entry
                                  # (--force also deletes an orphan's kept untracked/ignored content)
```

`resume <id>` exits with the relaunched task's real outcome (`0` done, `3` needs a human,
`4` failed again, `5` out of budget), so scripts can branch on it.

<details>
<summary>Why resuming can't be used to fake success</summary>

The checkpoint lives under `.loop/`, which the agent can write, so it deliberately carries
**no success authority**: it's parsed as data (never executed). Resume metadata such as
`RUN_ID` and counters may be read, but ids are labels for log/certificate correlation only;
they cannot supply a contract, preflight, review, or evidence verdict. The path to SUCCESS
stays gated by in-memory/off-tree approval data and fresh harness validation. A forged run
review baseline is validated as an ancestor of HEAD or replaced with a conservative fallback;
the fixed task baseline comes from the off-tree task record. A `MAX_RESUMES`
process guard (default 10 consecutive resumes without a completed iteration) stops
an endless crash loop; it is not a shipped, approval-gated project setting.
</details>

Every way a run stops is journaled: Ctrl-C/SIGTERM writes a `RUN_INTERRUPTED` row from the
trap itself, and a death that never reached the trap (SIGKILL, crash, power loss) is
reported as `RUN_ABEND` by the next resume — a silent death is visible in
`.loop/journal.jsonl` either way, and every `RUN_RESUME` row names the state it resumed
from. Failed agent calls keep their evidence: the exact error (exit code, API error
message, stderr, watchdog-kill marker) rides the `AGENT_ERROR`/`REVIEW_ERROR` journal rows,
and the failing call's raw JSON/stderr sidecars are preserved under `.loop/logs/failed/`
(newest 20) where the next run's identically-named logs can't overwrite them.
Successful calls are namespaced under `.loop/logs/<task-id>/<run-id>/`; the evidence agent
is given exactly that directory and must neither inspect nor cite sibling task/run logs.
This is a prompt/citation policy backed by harness namespace and integrity checks, not an OS
filesystem sandbox: a process running as the same UID with full Bash may still be physically
able to read sibling logs or off-tree files. Use a separate UID/container boundary when that
physical isolation is required.
## State model and exit codes

Every handled completion or stop writes a named state with a matching exit code.
A hard crash or `SIGKILL` may leave `RUNNING` on disk; the next invocation detects
that as an abnormal end (`RUN_ABEND`) and resumes from the checkpoint.

| State | Meaning | Exit |
|---|---|---|
| `SUCCESS` | Acceptance criteria verified and review-approved | 0 |
| `NO_OP` | Verified — no change was needed | 0 |
| `NEEDS_SPEC_DECISION` | The contract needs to change (your call) | 3 |
| `NEEDS_ARCHITECTURE_DECISION` | A judgment call (new dependency, schema change, …) | 3 |
| `NEEDS_DECOMPOSITION` | The remaining work exceeds one worker's iteration budget and should be split into phases (in a fleet the supervisor usually handles it; single loops stop for you) | 3 |
| `RISK_REQUIRES_APPROVAL` | Touched a denied path or the harness itself | 3 |
| `PENDING_APPROVAL` | A generated contract or Fleet task is waiting for explicit human approval | 3 |
| `BLOCKED` | Can't make progress (same error repeating, review rejected repeatedly), **or** the loop is waiting on a human sign-off row | 4 |
| `STALLED` | No progress (no diff for N iterations / repeated "futile" verdicts) | 4 |
| `BUDGET_EXCEEDED` | Hit the iteration cap, configured USD cap, or `MAX_RUN_SECONDS` boundary | 5 |
| `INTERRUPTED` | `SIGINT` / `SIGTERM` was handled and the checkpoint was preserved | 130 |
| `CANCELLED` | The active planned Fleet authority was permanently cancelled and its retryable audit archive committed; product changes may have been retained | 0; 4 when a requested rollback was unavailable or cleanup left quarantined artifacts |
| (usage error) | Something's misconfigured or unapproved | 2 |

Because `BLOCKED` covers both of those, its **NEXT ACTION box splits on which one it is**.
The harness checks whether `.loop/docs/acceptance-checklist.md` still holds a pending
`human` row — the same rows `./loop.sh signoff` would sign. If it does, the stop is a
sign-off gate and the box leads with `signoff` / `refine`. If it does not, nothing is
signable, so the box says so outright and points at the cause (`.loop/last-verify.log`,
`.loop/review-feedback.md`, `.loop/logs/failed/`) and at `./loop.sh resume --note`.
`./loop.sh status` and `./loop.sh report` reproduce whichever box the stop showed, so all
three surfaces agree instead of forwarding you to each other.

`NEEDS_SPEC_DECISION` / `NEEDS_ARCHITECTURE_DECISION` stops carry one extra
deterministic cross-check: when the iteration's own evaluator pass re-ran every
`VERIFY_COMMAND` (outside the agent session) and all of them passed, the decision
display notes it. A decision request claiming "command X cannot run in this
environment" can be true inside the agent's sandbox (a Codex seatbelt denying a
browser launch) yet false for the gate — the note tells you which environment the
claim holds in before you act on it.

**The only path to SUCCESS**, stated in full: every `VERIFY_COMMAND` passes when the
evaluator re-runs it, **and** (at a single-task gate) the deterministic preflight accepts
every ledger/checklist obligation and observation stamp, **and** the success gate ran,
**and** (when review is enabled) the independent reviewer explicitly said APPROVE with a
clean per-requirement table — using a state review if the task diff is empty — **and** an
evidence report was generated, **and** there is no unreviewed code change after that report,
**and** the harness wrote `certification.json`. No error, timeout, stale observation, skipped
review, or spent budget can produce SUCCESS. (`REVIEW_MODE="off"` remains the explicit
user-approved single-loop exception; its deterministic preflight still applies. The Fleet
parent has no per-task checklist, so its integration gate uses the merged-tree final verify
plus mandatory integration review.) The certificate records preflight `PASS` for a
single-task gate and `NOT_APPLICABLE` for that Fleet parent/integration gate.

During a parallel run the parent's state is `FLEET_RUNNING` while the fleet dispatches, then
ends in one of the states above. Individual tasks also carry a per-task result — `NEEDS_HUMAN`
(the supervisor escalated to you), `REPLANNED` (superseded by a replacement — not a failure),
or `DEP_FAILED` (a dependency failed; fix it, then resume the task).
## Artifact lifecycle — what survives which boundary

Every `.loop/` artifact has a declared scope, and each scope has exactly one boundary
that resets it. This is enforced: the test suite fails if `loop.sh` touches a `.loop/`
path that is not classified in `tests/artifact-lifecycle.txt`. The rule exists because
an artifact nobody resets is how stale-state bugs are born — a prior run's decision
brief once opened in the browser mid-way through an unrelated task, and a prior
contract's `met` ledger rows can alias a new contract's REQ ids.

| Scope | Reset at | Examples |
|---|---|---|
| **run-scoped** | every fresh run (a resume keeps them — same logical run) | `agent-state`, counters, review feedback, `supervisor-guidance.md`, `stop-nudge.md` / `split-nudge.md`, `last-verify.log` / `baseline-verify.log`, `decision.html` / `evidence.html`; a filled `evidence-report.md` and its `certification.json` are retired to `run-archive/<ts>-prevrun/` before the new run |
| **contract-scoped** | a **new task definition** (`./loop.sh start`, or the first definition in `auto`) — archived to `.loop/docs/run-archive/<ts>-root/` **and** committed, then reset from templates | working docs and reports, `.loop/task-id`, `.loop/observations/` + its manifest, the decompose plan/feedback, `phase-context/`, the fleet queue, and the supervisor session record |
| **persistent** | never | namespaced `.loop/logs/<task>/<run>/`, `journal.jsonl`, `docs/run-archive/`, approval records, git history |
| **liveness** | owned by the running process; removed on exit or reaped by the liveness probes | `run.pid`, `run.heartbeat`, the fleet supervisor lock |

When observations are archived, the manifest's bytes are preserved verbatim
(rewriting rows would break the certificate hashes bound to them), so its rows still
name `.loop/observations/<file>`. Archive consumers resolve that path to
`observations/<file>` relative to the containing `.loop/docs/run-archive/<id>/` directory;
they never fall back to the live `.loop/observations/` tree or another task's archive.

**Amendment vs. new task.** A hash can't tell "I answered a decision by editing the
contract" (memory must carry forward) from "this is a different task" (memory must
reset) — only you know the intent, so the **entry point** is the signal:

- `./loop.sh start "<instruction>"` — **new task**: the previous task's loop memory is
  archived and reset before the definition session begins.
- Hand-edit `product-contract.md` + `./loop.sh approve` — **amendment**: memory carries
  forward. This is exactly the flow the decision-stop message tells you to use.
  Approving interactively after a contract change asks you which of the two you meant;
  headless approve keeps memory and says so loudly; `auto` mode refuses a contract that
  was replaced outside both a definition session and a pending decision (exit 3),
  because unattended code must not guess.
- `r` (revise) at the approval prompt — **same task**: memory kept.

The fleet has the same boundary: queued *planned* tasks are bound to the contract they
were decomposed from (`.loop/decompose-approved`). If the contract changes while an
orchestration is interrupted, `run` / `fleet run` refuse to resume the stale queue
instead of merging and gating old work against the new contract.
