# loop-kit — contract-driven automation for Claude Code and Codex

**loop-kit** turns Claude Code, Codex, or a role-by-role mix of both into a bounded,
repeatable engineering workflow. You define and approve what "done" means once. From
there the harness cycles — implement, verify, review, improve — with a fresh context
every time, until the gate you approved passes or a human is genuinely required.

It is shell and prompt files. No server, no daemon, no database, no Python runtime.
`loop.sh` owns orchestration and every stop decision, the managed skills under
`.claude/skills/loop-*` and `.agents/skills/loop-*` define each agent phase, and
`evaluate.sh` re-runs your verification commands without ever asking the model whether
its own work passed.

### Design principle

> Lock the requirements, acceptance criteria, and verification gate — not the
> implementation design. Let the plan evolve while the approved definition of
> success stays fixed.

Two rules make the result auditable:

1. **A worker's self-report has no success authority.** The harness re-runs the
   configured checks and, by default, requires an independent reviewer in a separate
   read-only session.
2. **Failures stay failures.** An agent error, reviewer outage, timeout, stale
   evidence, or exhausted budget can never be promoted to `SUCCESS`.

Those guarantees are only as good as the contract and gate you approve. Codex-routed
calls can use Codex's process sandbox, but loop-kit does not sandbox the whole harness,
the evaluator, or your verification commands, and its zero-token regression suite
validates harness behavior rather than real-model output quality. The
[security model](docs/security.md) states the trust boundary plainly.

---

## Demo

https://github.com/user-attachments/assets/493626dd-8671-4abf-857b-24ede90cae65

82 seconds — the shift from reviewing diffs to authoring intent: the definition
interview that surfaces the missing requirement *before* implementation starts, and the
evidence report you read in place of a diff. Runs on Claude Code, Codex, or a
role-by-role mix of both.

---

## What you need

The harness itself needs only a normal Unix userland. **No Python, no `jq`.**

- `bash` 3.2+, `git`, `awk`, `sed`, `grep`, and the standard file/process tools that
  ship with macOS and Linux. JSON parsing and audit-log handling are portable `awk`.
- A **SHA-256 tool** — `shasum` *or* `sha256sum`. Every approval and tamper check hashes
  through it, so if neither exists the harness refuses to start rather than run without
  its safety checks.
- A current **`claude`** CLI for Claude-routed roles and the interactive `start` /
  `refine` sessions. The shipped config passes `--effort`; if your CLI predates that
  option, clear `LOOP_EFFORT` and its per-role overrides.
- A current **`codex`** CLI only if a role routes to Codex. A fully headless all-Codex
  run needs no Claude CLI at all — see [Running roles on Codex](docs/codex.md).

Your own project may use any language or toolchain; `VERIFY_COMMANDS` is what tells the
harness how to verify it. The bundled demos use Python with `uv`/`pytest`. The test
suite swaps in fake agents for both CLIs, so it costs zero tokens.

| Platform | Status |
| --- | --- |
| **macOS**, **Linux** | Supported for single runs and the parallel fleet; the full behavioral suite runs on both in CI. |
| **Windows (WSL)** | Supported through the Linux path, and the recommended way to use the fleet on Windows. |
| **Windows (native Git Bash / MSYS2)** | Best-effort for **single runs** (`start` / `run` / `auto`). CI enforces syntax and lint; the behavioral suite is informational. The **parallel fleet is not supported** — it depends on POSIX process groups, atomic hard links, and `ps`-based liveness. |

The harness uses fractional `sleep`, so a busybox-only environment isn't supported. On
macOS and Linux, `perl` enables process-group termination of an agent and its
descendants; without it, termination falls back to the top-level agent PID.

---

## Using it

The commands below follow the life of a deployment: install it, configure it, define
and run a task, then read the result — or cancel it.

### 1. Install, upgrade, remove — `init` / `update` / `uninstall`

loop-kit is deployed *into* your project as a copy. Clone the kit once, then point it
at each project you want to use it in:

```bash
git clone https://github.com/Aitne-sh/loop-kit.git ~/loop-kit
~/loop-kit/bin/loop.sh init /path/to/your-project
```

`init` writes a handful of visible files at your project root and hides the rest, adds
its own paths to your `.gitignore`, and records where it came from in
`.loop/kit-source`. If the target is not a Git repository it initializes one and makes
the deployment commit; in an existing repository it leaves the changes for you to
review.

```
your-project/
├── loop.sh              ← the entry point. Single and parallel runs both start here.
├── loop.config.sh       ← stop conditions (hash-protected once approved)
├── loop.models.sh       ← agent, model, and effort routing (edit between runs)
├── fleet.config.sh      ← parallel settings (edit between runs)
├── loop-instruction.md  ← (optional) where you write your instructions
├── .claude/skills/      ← 14 managed Claude Code skills
├── .agents/skills/      ← 13 managed Codex projections (loop-refine is Claude-only)
└── .loop/               ← everything else (hidden)
```

**Upgrading.** `./loop.sh update` refreshes the executable harness, both managed skill
trees, and the pristine document templates. It preserves your populated contract and
working documents, your config values, your model routing, your own skills, `AGENTS.md`,
and `.codex/**`. Because the harness hash changes, updating deliberately invalidates the
old approval:

```bash
cd your-project
./loop.sh update              # kit location resolved from .loop/kit-source
./loop.sh update --approve    # update and re-approve in one step
```

**Removing.** `./loop.sh uninstall` takes the project back to how it looked before —
every file `init` deployed, plus all run state. It keeps your own files,
`loop-instruction.md`, `AGENTS.md`, `.codex/**`, other skills, and the git history
(commits the loop made stay in history). It refuses while a loop is active, and warns
before discarding unmerged fleet branches.

```bash
./loop.sh uninstall           # lists what will go, asks to confirm [y/N]
./loop.sh uninstall --force   # skip the prompt (required without a terminal)
```

→ Full preservation and cleanup rules: **[Managing a deployment](docs/deployment.md)**

### 2. Configure it — `setup`

Right after `init` is the moment to decide which agent and model runs each phase.
`./loop.sh setup` opens a guided session for exactly that:

```bash
./loop.sh setup                 # guided tuning of loop.models.sh
./loop.sh setup --app codex     # run the tuning session on Codex instead
```

The session explains each knob, answers questions from a bundled reference, and edits
only a throwaway copy of `loop.models.sh` in a temporary directory. The harness then
validates that copy deterministically — rejecting, for example, a Codex-routed role
pointed at a Claude model — and reflects it into the real file only if it passes. It
runs on Claude by default and falls back to Codex when the Claude CLI is absent.

Routing lives outside the approval hash, so a successful `setup` takes effect
immediately with no re-approval. It does refuse to run while a loop is active in the
repo, because swapping models under a live iteration is exactly the kind of mid-run
change the harness treats as tampering.

The other two files you may want to touch:

| File | What it holds | Changing it |
|---|---|---|
| `loop.config.sh` | Verification commands, budgets, path policy, review mode | **Hash-protected** — a change stops the loop until you `approve` again |
| `loop.models.sh` | Which agent + model + effort runs each role | Free between runs; a mid-run edit stops the run |
| `fleet.config.sh` | Parallel-execution settings | Free between runs; a mid-run edit stops the run |

→ Every key and its default: **[Configuration reference](docs/configuration.md)** ·
**[Running roles on Codex](docs/codex.md)**

### 3. Define and run a task — `start`, `approve`, `run`

There are two ways in. They share the same spine and differ only in how much they pause
for you.

**Guided** (needs an interactive terminal):

```bash
cd your-project
vi loop-instruction.md            # write what you want built
./loop.sh                         # interview → you approve → it runs
#   — or, without editing a file —
./loop.sh start "<your instruction>"
```

The interview is not a questionnaire. The agent first surveys your repo — conventions,
test commands, risky areas, what earlier runs learned — sorts what is still unknown into
open questions, taste calls, and feasibility risks, probes the risky ones with throwaway
spikes, and only then asks you anything. It asks one question at a time, biggest impact
first. Everything it learns lands in `.loop/docs/unknowns.md`, and the contract's
`## Human Approval Required If` section becomes the run's escalation bar: below it the
loop decides on its own and records each choice; above it, it stops and asks you.

When the session ends the shell asks: `y` approve and start, `r` another revision round,
`n` quit. Approving records a SHA-256 hash of exactly what you approved, so nothing can
quietly move the goalposts later.

**Hands-off** — for a script, CI, or another agent, or when you just don't want to be
asked:

```bash
./loop.sh auto                    # generate, independently review, approve, run
./loop.sh auto "<instruction>"
```

In auto mode anything that would have been a question is recorded under
`## Assumptions (auto mode)` instead, so you can audit every judgment call. Because the
model is writing the very goalposts the checker will enforce, no contract is approved
unattended without an independent read-only review confirming it covers the whole ask
and that `VERIFY_COMMANDS` is a real, discriminating test. A rejection regenerates the
contract once; if it still fails, the run stops and asks you. `LOOP_ASK_CRITICAL=1` lets
the generator raise genuinely critical unknowns instead of assuming through them.

Once a contract is approved, `./loop.sh run` executes it. It decomposes the contract
first: one task runs the classic loop in place, several run in parallel worktrees as a
fleet. A crashed run auto-resumes from its checkpoint; `--fresh` restarts clean, and
`--single` skips decomposition.

**See the lock for yourself:** after a run, add a line to
`.loop/docs/product-contract.md` and run `./loop.sh run` again. It refuses — the
approval hash no longer matches. Only `./loop.sh approve` lets it continue.

Two ready-made demos let you watch all of this end to end before pointing it at real
code:

```bash
~/loop-kit/bin/loop.sh init /tmp/loop-demo1 --template demo1-bugfix   # fix failing tests
~/loop-kit/bin/loop.sh init /tmp/loop-demo2 --template demo2-feature  # build a small feature
cd /tmp/loop-demo1 && ./loop.sh
```

→ **[The contract](docs/contract.md)** · **[What happens each iteration](docs/iteration.md)**
· **[The parallel fleet](docs/fleet.md)**

### 4. Watch it, and close it out — `status`, `report`, `signoff`

```bash
./loop.sh status              # state, approval, models, timeouts, cost (this run + lifetime)
./loop.sh report              # evidence, spec drift, decisions, and cost
./loop.sh report --text       # plain text, broken down by role
```

You read an **evidence report**, not a diff. On `SUCCESS` the harness also writes
`.loop/docs/certification.json`, binding the approved inputs to the final evidence.

Some acceptance rows can only be closed by a human looking at the result. The run stops
at that gate and tells you exactly what to look at. Then:

| You want to | Command |
|---|---|
| Confirm everything and finish | `./loop.sh signoff` |
| Adjust a reversible knob and preview live | `./loop.sh refine '<what to change>'` |
| Hand findings to one more iteration | `./loop.sh resume --note '<what to adjust>'` |
| Change a REQUIRED behavior | revise the contract (Claude Code `/loop-contract`, Codex `$loop-contract`), then `./loop.sh approve` |

Picking the wrong one of the last two is the classic dead end: a contract change will
**not** go through `resume --note` — the loop rejects it as drift.

### 5. Stop, resume, cancel — `resume` and `discard`

Every stop prints a **NEXT ACTION** box naming the exact command to run, and every error
ends with a `→ next:` line, so no flow leaves you guessing.

Most stops are resumable. A crash or Ctrl-C auto-resumes on the next `./loop.sh run`;
a terminal state (`BLOCKED`, `STALLED`, `BUDGET_EXCEEDED`) resumes with
`./loop.sh resume` once you have fixed the cause, keeping the iteration count and cost
intact.

```bash
./loop.sh resume                       # continue the stopped root run
./loop.sh resume --note '<guidance>'   # ...and tell the next iteration what changed
./loop.sh resume --list                # every session, its phase, and how it resumes
./loop.sh resume <task-id>             # flip one stopped fleet task runnable and dispatch it
```

To **permanently cancel** the active decomposed plan as a unit — stopping its
supervisor and workers, archiving the state, and removing the queue — use `discard`:

```bash
./loop.sh discard                  # a TTY asks whether to roll back merged changes
./loop.sh discard --keep-changes   # cancel; keep what already merged (the safe default)
./loop.sh discard --rollback       # cancel and try to undo merged product changes
```

Without a terminal you must name one of the two flags — omitting it refuses to begin
the transaction. The choice is durable once published: after a crash, rerun `discard`
with the same flag and it finishes the cancellation it started.

Rollback is optional and deliberately fail-closed. It needs **both** a deterministic
structural assessor (every product-changing commit is an ordinary fleet merge with
matching trailers, receipt, and archive, and an isolated inverse restores the pinned
tree) **and** an independent read-only `ROLLBACK` reviewer that can veto but never
widen the set. When both agree, the harness creates exactly one new inverse commit and
advances with `--ff-only` — never a reset, rebase, or history rewrite. If rollback is
unavailable, cancellation still completes: the changes are kept, the archive records
`UNAVAILABLE`, and the run finishes `CANCELLED` with exit 4 so automation notices.

Tasks you added manually are outside the plan's authority and survive the cancellation.

→ Full transaction, gate list, and recovery: **[Cancelling a plan](docs/discard.md)**

---

## Architecture

You state a requirement once and approve it once. From there the harness runs one
spine, whether the work turns out to be one task or many:

```
your instruction
      │
      ▼
 ┌──────────────┐   an interview that asks only what it can't figure out itself,
 │  1. CONTRACT │   then writes the fixed requirements + stop conditions
 └──────┬───────┘
        ▼
 ┌──────────────┐   you say yes; the harness records a hash of exactly what you
 │  2. APPROVE  │   approved, so nothing can quietly change the goalposts later
 └──────┬───────┘
        ▼
 ┌──────────────┐   the harness splits the contract into tasks: one task runs the
 │ 3. DECOMPOSE │   classic loop in place; several run in parallel worktrees
 └──────┬───────┘
        ▼
 ┌──────────────┐   implement → verify → review → improve, in a fresh context each
 │  4. LOOP     │   time, until every requirement is met (or it stops for you)
 └──────┬───────┘
        ▼
 ┌──────────────┐   you read an evidence report, not a diff. Parallel runs are also
 │ 5. EVIDENCE  │   re-reviewed as a merged whole against the original contract
 └──────────────┘
```

### Two layers, and the split is the point

- **`loop.sh` — the deterministic harness.** Orchestration, the state machine, approval
  hashing, git and worktree management, journaling, and the fleet supervisor. It makes
  every stop decision. No model is in this layer.
- **`evaluate.sh` — the external checker.** It re-runs your `VERIFY_COMMANDS` *outside*
  the model and reads the exit codes itself. This is the maker–checker boundary:
  deterministic checks gate first, AI review second, humans see only an evidence report.
- **`.claude/skills/loop-*` — the prompts.** Each phase of the spine is a skill
  (`loop-contract`, `loop-plan`, `loop-iterate`, `loop-review`, `loop-stop-eval`,
  `loop-evidence`, `loop-decompose`, `loop-supervise`, and their independent reviewers).
  The Claude tree is canonical; the Codex `.agents/skills` tree is a generated
  projection of it, never a second source.

### Who is allowed to say what

| Artifact | Role | Authority |
|---|---|---|
| `.loop/docs/product-contract.md` | Approved requirements and escalation boundary | Yours; workers cannot change it during a run |
| `loop.config.sh` | Verification commands, budgets, path policy | Yours; hash-protected after approval |
| `.loop/docs/acceptance-checklist.md` | Fine-grained behaviors and their `cmd` / `run` / `human` evidence | Seeded at definition; enforced by the evaluator and reviewer |
| `.loop/docs/evidence-report.md` | Human-readable result, drift, and evidence summary | Model-authored and explicitly **non-authoritative** |
| `.loop/docs/certification.json` | Machine record binding approved inputs to final evidence | Harness-generated, only after the final gate |

The implementation plan, progress notes, requirements ledger, and code all evolve as the
agent learns. The evaluator and reviewer check that they still satisfy the fixed
contract.

### The only path to SUCCESS

Every `VERIFY_COMMAND` passes when the *evaluator* re-runs it, **and** the deterministic
preflight accepts every ledger and checklist obligation, **and** the success gate ran,
**and** — when review is enabled — the independent reviewer said APPROVE with a clean
per-requirement table, **and** an evidence report exists, **and** no unreviewed change
follows it, **and** the harness wrote the certificate. No error, timeout, stale
observation, skipped review, or spent budget can produce it. Every other outcome is a
named state with its own exit code — see
[States, recovery, and artifact lifecycle](docs/states-and-recovery.md).

---

## Command reference

| Command | What it does |
|---|---|
| `bin/loop.sh init <dir> [--template t]` | Deploy the kit into a project (records its source in `.loop/kit-source`). |
| `./loop.sh setup [--app claude\|codex]` | Guided, isolated, validated tuning of `loop.models.sh`. Takes effect immediately — no re-approval. |
| `./loop.sh` | Guided run: interview → approve → loop. |
| `./loop.sh start <instruction\|file>` | Run the guided definition interview on an instruction directly. |
| `./loop.sh auto [instruction\|file]` | Hands-off: generate, independently review, auto-approve, and run until success or escalation. |
| `./loop.sh approve` | Approve contract + config + harness (records the hashes). Runs a deterministic definition lint first — contract-anchored AC ids need checklist rows, rows must reference defined REQs, no duplicate ids, no destructive `VERIFY_COMMANDS` patterns, no contract without `### REQ-xxx` headings. |
| `./loop.sh contract-review` | Independent read-only review of the loop definition itself. |
| `./loop.sh run [--fresh] [--single]` | Run the approved contract (auto-resumes after a crash; `--fresh` restarts; `--single` skips decomposition). |
| `./loop.sh decompose [--force]` | Preview or regenerate the task split without running. |
| `./loop.sh resume [<id>\|--list] [--note '<text>']` | Continue a stopped root run or task; `--note` guides the next iteration. |
| `./loop.sh discard [--rollback\|--keep-changes]` | Permanently cancel the active planned fleet queue as one authority. Manual side-tasks survive; rollback is optional and fail-closed. |
| `./loop.sh signoff [--yes]` | At a human sign-off gate: list every pending `human` acceptance row, confirm once, mark them verified and re-certify. |
| `./loop.sh refine ['<note>']` | At a human sign-off gate: interactive session to adjust reversible within-contract knobs and preview live, then sign off. |
| `./loop.sh add <task> [--auto] [--after <id,id>]` | Queue a fleet task any time (alias for `fleet add`). |
| `./loop.sh fleet <cmd>` | Fleet control: `run`, `add`, `approve`, `status`, `report`, `logs`, `discard`, `stop`, `resume`, `ack-plan`, `merge`, `clean`, `unlock`. |
| `./loop.sh watch [--interval s] [--max-runs n]` | Re-run `run` on an interval until success or escalation. An escalation (`NEEDS_*`, `BLOCKED`, `STALLED`, `BUDGET_EXCEEDED`) stops the watch and prints that stop's guidance — retrying those would restart from iteration 1 and re-spend the budget. The one exception is a rate/usage-limit stall, which it waits out and continues with `resume`. |
| `./loop.sh status` | Show state, approval status, models, timeouts, and cost. |
| `./loop.sh report [--text\|--html] [--open\|--no-open]` | Show evidence, drift, decisions, and cost. |
| `./loop.sh open <file>` | Open an HTML report or mockup in the browser. |
| `./loop.sh update [--from <kit>] [--approve]` | Upgrade the deployed harness, preserving populated docs and config values. |
| `./loop.sh uninstall [--force]` | Remove the deployed kit and its run state (your project stays). |

---

## Documentation

| Page | What's in it |
|---|---|
| [The contract](docs/contract.md) | What you lock down, at what granularity, with a worked example |
| [What happens each iteration](docs/iteration.md) | The five steps of one pass, and the three ledgers that give the loop memory |
| [The parallel fleet](docs/fleet.md) | Decomposition, phased workflows, isolation, the queue, and the supervisor's guards |
| [Cancelling a plan (`discard`)](docs/discard.md) | The cancellation transaction and the fail-closed rollback gates |
| [Configuration reference](docs/configuration.md) | Every key in all three config files, plus cost and permission modes |
| [Running roles on Codex](docs/codex.md) | Per-role routing, sandbox posture, and Claude-less operation |
| [States, recovery, and artifact lifecycle](docs/states-and-recovery.md) | Every stop state and exit code, how to resume it, what survives which boundary |
| [Safety and the security model](docs/security.md) | Tamper defenses, and an honest list of what the harness does *not* provide |
| [HTML views](docs/html-views.md) | When the harness renders a page for you, and why Markdown stays canonical |
| [Managing a deployment](docs/deployment.md) | Exactly what `update` and `uninstall` touch and preserve |
| [Tests](docs/testing.md) | The zero-token regression suite |
| [Theory → implementation](docs/theory.md) | Which research and practice each mechanism implements |

---

*Review the contract before a run, then use the machine certification and evidence
report as the primary handoff. Inspect implementation diffs whenever the risk warrants
it.*
