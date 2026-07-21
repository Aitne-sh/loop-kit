[← loop-kit](../README.md) · **The iteration loop**

> How one pass through the loop works, and the three files that give the loop its
> memory. Read this if you want to know *why* a run stopped where it did.

# What happens each iteration

This is the heart of the system. Every pass through the loop is a **fresh `claude`
call** — the agent remembers nothing from the last iteration except what's written in
the `.loop/docs/*` files and git history. That "fresh context every time, memory on
disk" design is deliberate: it keeps each iteration focused and prevents context from
rotting over a long run.

Before iteration 1, the iteration-0 PLAN step runs **read-only** (Claude: Read/Glob/Grep
only; Codex: `--sandbox read-only` with automatic project-doc loading disabled) — the
same posture as fleet decomposition. The model returns the plan inside one versioned
envelope; the harness stages it under the ignored `.loop/plan-candidates/`, validates the
fixed section schema and exact contract-REQ coverage (an invalid reply gets one retry
against the validator's written feedback in `.loop/plan-feedback.md`, which ends with the
rejected attempt verbatim so the retry corrects only the named violations instead of
regenerating from scratch; prose before the envelope's opening marker is tolerated — the
extraction is marker-bounded), then has an
independent read-only reviewer (`MODEL_REVIEW`) judge the candidate semantically — do the
milestones really advance their REQs, is the riskiest work first, is anything invented
beyond the contract? A REVISE feeds one regeneration; set `LOOP_PLAN_REVIEW=0` to skip
this review (the decompose review has the matching `LOOP_DECOMPOSE_REVIEW=0`). After the
review the harness re-validates the exact staged bytes and publishes
`.loop/docs/implementation-plan.md` itself. Any planner-side project write or commit
stops the run as `RISK_REQUIRES_APPROVAL`. This is capability containment, not
whole-machine isolation: Claude project hooks/plugins/MCP are not structurally isolated
at launch, and Codex `read-only` bounds only the local filesystem — external services can
still have side effects.

```
1. IMPLEMENT   The agent reads the contract, the plan, the progress notes, the three
               ledgers (below), and any reviewer feedback; implements ONE milestone;
               self-checks it; and declares a state in .loop/agent-state.

2. EVALUATE    evaluate.sh runs — no model involved. It re-checks the contract hash,
               applies the path rules, RE-RUNS your VERIFY_COMMANDS itself, and refuses
               a "ready" claim unless the requirements ledger shows every requirement
               met AND the acceptance checklist shows every expected behavior verified.
               It prints exactly one line: a state and a reason.

3. REVIEW      A fresh, read-only reviewer session judges the work. It reads the
               requirements FIRST and the diff LAST, so the code can't frame its
               judgment. It checks for regressions (did this break something that
               already worked?), drift (does this serve a requirement, or wander?),
               and honest bookkeeping.

4. STOP-EVAL   A lightweight model gives a quick, advisory read: keep going, looks
               done, or looks futile. It cannot declare success on its own.

5. COMMIT      The iteration is snapshotted ("loop: iter N — <state>") and logged.
```

A few things make this rigorous rather than hopeful:

**The checker re-runs your tests; it never trusts the agent.** `evaluate.sh` has no
model in it. It runs your `VERIFY_COMMANDS` itself and reads the exit codes. That is
more reliable than a model's self-report, but only as discriminating as the commands
you configure.

**The checker also runs them *outside* the agent's session.** A Codex OS sandbox or a
restricted Claude tool set does not apply to the evaluator, so a probe the agent's own
shell cannot launch (a headless browser denied by the macOS seatbelt's Mach-port rules,
say) still runs and still counts at the gate. The agent's job is to make the command
pass and cite the evaluator's log and artifacts (`.loop/last-verify.log`,
`.loop/observations/`), never to launch such a probe from its own shell. If an agent
still stops with a decision request claiming a command cannot run in this environment
while the evaluator's own pass this run is all green, the stop display says so — the
limitation was the agent sandbox, not the verify gate.

**The reviewer runs in two modes.** During the run it does *interim* reviews of just the
latest change — "is this step correct?" — and incompleteness is expected, not a defect.
At the end it runs a *gate* review of the whole run against every requirement, and must
produce one verdict line per requirement:
`REQ-001: MET | PARTIAL | UNMET | REGRESSED — evidence`. The harness parses those lines,
and an "APPROVE" that's missing a line, or has any non-`MET` line, is automatically
downgraded to "needs revision." A single overall thumbs-up can hide an unmet requirement;
the required per-requirement table makes omissions explicit, and a missing row fails
closed. If the task diff is empty, the gate does not skip review: it switches to
`scope=state` and independently checks the current implementation, ledgers, verify log,
and observation manifest. The absence of a diff is never completion evidence.

**It periodically zooms out.** Reviewing one diff at a time is structurally blind to slow
decay across iterations — duplicated logic, dead code, two approaches fighting each other.
So every few iterations (`HOLISTIC_EVERY_N`), or whenever one change is large
(`HOLISTIC_TRIGGER_LINES`), the same review widens to look at the whole run so far.

**The loop does not depend on the worker volunteering completion.** If the stop
evaluator says "looks done" several times in a row (`MET_FORCE_N`) with all tests
green, the harness *forces* the success gate to run — but the gate review, evidence,
and final re-check still make the real call. The stop evaluator only forces the
question; it never answers it. Every `MET` must first pass a model-free preflight:
the latest verify log is green, every ledger REQ is `met`, every checklist row is
verified, and all cited runtime observations are current. A failed preflight resets
the streak, journals `FORCED_GATE_REFUSED`, and keeps looping in every review mode.

**Agent calls have watchdogs; project commands must bound themselves.**
`MAX_ITER_SECONDS` and `TIMEOUT_<ROLE>` terminate overlong Claude calls.
`VERIFY_COMMANDS` and `WORKTREE_SETUP_CMD` are executed as project shell commands and
are not wrapped in a per-command timeout by loop-kit. If one can hang, include the
appropriate timeout in that command or its test runner.

**"It compiles" is never "it works".** At definition time the contract session
decomposes every requirement into the fine-grained behaviors the user actually expects —
including the *implicit* ones nobody states ("after the GPU migration the particles are
still visible and still animate"; "a Mario-like game has stomp-kills, pit death, and a
game-over") — and assigns each a **verification method**: `cmd` (a deterministic command
proves it), `run` (only running the artifact and observing proves it — probe script or
browser observation with a screenshot saved under `.loop/observations/`), or `human`.
These live as rows in the **acceptance checklist** (below); `evaluate.sh` refuses success
while any row is unverified, the reviewer opens the cited observation artifacts, and the
contract reviewer rejects any gate a plausibly-broken implementation could pass unseen.

**Browser and visual checks: proposed at definition time, enforced at run time.** When a
deliverable renders in a browser, the contract session proposes a direct browser check —
a deterministic browser-test command (e.g. Playwright) when the project has one, otherwise
a `run` row the executing agent closes by driving a browser through its own
browser-automation skill or MCP connector (the *agent browser channel*). That binding is a
proposal, not a proven capability: the defining session never probes it (its environment
is not the executing agent's), and the definition tells you so up front. If the executing
agent turns out to lack the capability — the skill is not enabled, or you have not
permitted it — the loop stops at the first attempt with a decision request instead of
silently downgrading the check: enable the skill and `./loop.sh resume`, verify the
behavior manually and sign the row off like a `human` row, or revise the contract.

**A fleet worker can't quietly outgrow its budget either.** Once `SPLIT_NUDGE_AT`% of
`MAX_ITERATIONS` is spent with requirements still unmet, the harness injects a *split
nudge*: either justify continuing, or bring the tree to a clean committed boundary and
declare `NEEDS_DECOMPOSITION` so the supervisor can split the remainder into phased tasks
(see [the fleet](fleet.md)). The nudge is advisory — the declaration is the only stop path.

## The three ledgers the agent keeps

Alongside the free-form plan and progress notes, three structured files give the loop a
reliable memory and give you an honest paper trail.

- **`requirements-ledger.md`** tracks *outcomes*: one row per requirement, with a status
  (`unstarted / in-progress / met / at-risk / regressed`) and the evidence for it. The
  harness seeds it automatically from your contract's `REQ-` headings, the agent updates
  it every iteration, and the reviewer verifies it. A requirement can only be marked
  `met` with concrete evidence — a file, a test, an observable behavior — and
  `evaluate.sh` refuses to let a run succeed while any row is not `met`.

- **`acceptance-checklist.md`** tracks *expectations*: one row per fine-grained behavior
  the user expects (`AC-001 | REQ-001 | expectation | method | status | evidence`),
  written by the contract session before approval — implicit must-be expectations
  included — and each assigned a verification method (`cmd` / `run` / `human`). A `run`
  row can only become `verified` by actually running the artifact and saving what was
  observed (screenshot, probe log) under `.loop/observations/`; reading the code never
  counts. The deterministic evaluator stamps each cited artifact in
  `.loop/observations-manifest.jsonl` with its content hash, AC hash, and product-tree hash.
  A code or AC change makes unchanged evidence stale until it is recaptured; a fresh retry
  within the same task preserves evidence whose hashes still match. Mid-run, newly noticed
  but unverified behaviors are *appended* as new rows, so
  "I saw it but didn't check it" can't evaporate. `evaluate.sh` refuses success while any
  row is not `verified`; the gate reviewer audits the rows (and opens the artifacts)
  against the frozen contract. You may edit this file by hand — the loop may not weaken
  it (obligations anchor to the `AC-` ids named in the approved contract, so deleting
  rows can't shrink them). If a run stops for a `human` row (BLOCKED, with a decision
  request naming exactly what to look at), you close it yourself: look, then run
  `./loop.sh signoff` — it lists every pending `human` row, asks one confirm, marks
  them `verified` and re-certifies. (Editing the row's status to `verified` by hand,
  with a short note in Evidence as your sign-off, then `./loop.sh resume`, is the
  manual equivalent.) It is all-or-nothing on purpose: the closing call is binary —
  everything looks right, or something needs to change first. If you have changes to
  request instead, there are **two distinct channels,
  and picking the wrong one is the classic dead-end**:
    - *Within the contract* (tune a reversible knob — how much motion, how fast a swirl):
      `./loop.sh refine '<what to change>'` opens an interactive session to adjust and
      preview live, then offers to sign off and re-certify; or `./loop.sh resume --note
      '<what to adjust>'` hands your findings to one headless iteration.
    - *Change the contract* (remove or alter a REQUIRED behavior — a verified `AC-` row
      or a `REQ`): revise it with the contract skill (Claude Code:
      `/loop-contract`; Codex: `$loop-contract`), then `./loop.sh approve`. This
      will **not** go through `resume --note` (the loop rejects it as drift), and
      re-running `approve` on an *unchanged* contract just re-locks it and stops at
      the same gate — so the harness warns you when you approve a byte-identical
      contract at a decision stop. Every stop — BLOCKED, STALLED,
      BUDGET_EXCEEDED, or a decision — prints a **NEXT ACTION** box spelling out
      the exact next command, and every error ends with a `→ next:` recovery line,
      so no flow ever leaves you wondering what to run next.

- **`assumptions.md`** is the controlled middle ground between "stop everything" and
  "bury it in a note." When the agent hits a gap that *doesn't* require changing the
  contract — an under-specified detail, a small design choice — it records the gap, picks
  the most conservative option (smallest, most reversible, closest to existing behavior),
  and keeps going. Every open assumption is judged at the gate (sound / must-fix /
  ask-the-human) and shown to you in the evidence report. A recorded assumption is never
  silently lost; an *un*recorded one would be.

Discoveries that *do* require changing the contract still stop the run and ask you.
