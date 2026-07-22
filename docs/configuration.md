[← loop-kit](../README.md) · **Configuration reference**

> Every key in the three config files, what it defaults to, and which ones require
> re-approval. See [Running roles on Codex](codex.md) for agent routing.

# Configuration reference

## `loop.config.sh` — the stop conditions (hash-protected)

This file is part of the contract: it's hashed at approval time, and any change stops the
loop until you re-approve. The key settings:

| Setting | Default | Meaning |
|---|---|---|
| `VERIFY_COMMANDS` | (you set) | The success gate. Every command must exit 0. This is what the checker re-runs; keep it honest and fast. |
| `VERIFY_RETRIES` | 0 | Rerun ALL verify commands up to N more times when they fail, absorbing environmental flakes (sqlite I/O, fd exhaustion). A red-then-green rerun is journaled as `VERIFY_FLAKE` with the failing log preserved (`.loop/verify-flake.log`) — never silently hidden. 0 = every red is trusted as-is. |
| `DENIED_PATHS` | `.env* secrets/** …` | Touching these stops the run for approval (`RISK_REQUIRES_APPROVAL`). |
| `ESCALATE_PATHS` | (empty) | Touching these asks for a decision (`NEEDS_ARCHITECTURE_DECISION`) — e.g. dependency or schema files. |
| `MAX_ITERATIONS` | 10 | Hard cap on loop iterations per run. |
| `MAX_ITER_SECONDS` | 900 | Default wall-clock watchdog on each individual agent call. |
| `TIMEOUT_<ROLE>` | (empty → inherits `MAX_ITER_SECONDS`) | Per-role watchdog override (seconds), e.g. `TIMEOUT_IMPLEMENT=1800` so a heavy implement iteration outlasts the clerical `STOP_EVAL`/`EVIDENCE` calls. Roles: `IMPLEMENT REVIEW PLAN CONTRACT EVIDENCE STOP_EVAL DECOMPOSE SUPERVISE ROLLBACK`. `TIMEOUT_ROLLBACK` bounds the independent discard safety review. Lives here (not `loop.models.sh`) because the watchdog is a safety budget — raising it is gated by re-approval. A blank/non-numeric value silently inherits the global. |
| `MAX_RUN_SECONDS` | (empty) | Optional wall-clock budget checked at iteration/orchestration boundaries. A later resume gets a fresh window; it does not interrupt an individual `VERIFY_COMMAND`. |
| `MAX_COST_USD` | (empty = no cap) | A hard cap on reported USD. Claude reports real USD; Codex reports none, so it counts only if you set the `PRICE_*` table (then it is **estimated** and bounded by this cap). See [Running roles on Codex](codex.md).  |
| `PRICE_<MODEL>_IN` / `_CACHED` / `_OUT` | (empty = Codex cost 0) | Optional per-1M-token USD rates that turn on **approximate** Codex costing (model slug uppercased, non-alphanumerics → `_`). Hashed with the contract. See [Running roles on Codex](codex.md).  |
| `STAGNATION_N` | 2 | Consecutive no-diff iterations → STALLED. |
| `REPEAT_FAIL_N` | 3 | Identical verify failure this many times → BLOCKED. Also derives the oscillation window: ≤2 distinct failure fingerprints across `2×N` consecutive failing iterations → BLOCKED (catches the fix-A-breaks-B ping-pong the identical rule misses). The same threshold caps identical deterministic *promotion refusals* (the agent declares ready, the evaluator's ledger/checklist checks refuse with a byte-identical reason each lap) → BLOCKED instead of iterating to the budget. |
| `FUTILE_N` | 2 | Consecutive "futile" stop-eval verdicts → STALLED. |
| `MET_FORCE_N` | 2 | Consecutive "looks done" verdicts (with tests green) force the success gate. 0 disables. |
| `REVIEW_MODE` | `always` | `always` / `candidate` (gate only) / `off`. |
| `STOP_EVAL` | `true` | Run the lightweight advisory stop evaluator each iteration. Any other value skips it — `MET_FORCE_N` then never fires, so completion depends on the agent declaring ready. |
| `SPLIT_NUDGE_AT` | 70 | Fleet workers: past this % of `MAX_ITERATIONS` with requirements unmet, nudge the agent to declare `NEEDS_DECOMPOSITION` at a clean boundary. 0 disables. |
| `HOLISTIC_EVERY_N` | 3 | Every Nth interim review widens to the whole run (erosion audit). |
| `HOLISTIC_TRIGGER_LINES` | 400 | Also widen when one iteration changes at least this many lines. |
| `MAX_REVISIONS` | 3 | Consecutive reviewer rejections → BLOCKED. Interim and gate rejections are counted *separately*, so interim churn never eats the gate's budget. |
| `GATE_RETRY_N` | 2 | Additional retries when the *gate reviewer call itself* is unavailable (an outage, not a verdict). Retries use backoff before the fail-closed `BLOCKED` state; certification still requires an explicit `APPROVE`. 0 = block immediately. Older deployments that omit this key retain the compatibility fallback of 0 until `update` adds it. |
| `GATE_RETRY_WAITS` | `"60 300"` | Seconds to wait before gate retry 1, 2, … (the last entry repeats). The run heartbeat stays fresh throughout the wait. |
| `EVIDENCE_RETRY_N` | 2 | Regenerations of an *invalid evidence report* at the gate — a content failure: the deterministic rejection reason is fed back to the evidence agent as `rejected='…'`. Tamper, authority-drift, and post-review-diff failures never retry. No backoff (the failure is deterministic content, not an outage). 0 = one-shot. Deployments that omit this key use the code fallback of 2, so they self-heal by default. |
| `LOOP_OBS_MAX_FILE_KB` | 2048 | Maximum size of one runtime observation the evaluator may stamp into the manifest. Oversize evidence remains unverified. |
| `LOOP_OBS_MAX_TOTAL_MB` | 50 | Maximum combined size of `.loop/observations/` eligible for certification. |
| `LOOP_CODEX_SANDBOX` | `workspace-write` | OS sandbox for Codex-routed full roles. Reader roles are always forced to `read-only`. |
| `LOOP_CODEX_NETWORK` | 1 | Allow network for commands inside Codex's `workspace-write` shell sandbox; 0 leaves that sandbox network-blocked. Does not configure MCP, apps, or hosted search. |
| `PERMISSION_MODE` | `acceptEdits` | How Claude-routed workers handle tool permissions (see below). |
| `ALLOWED_TOOLS` | broad built-in set | Claude-routed workers' tool allow-list (`Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit` as shipped). Add an MCP server by name to make it usable in the loop. |
| `DISALLOWED_TOOLS` | (empty) | Opt-in deny-list; deny wins over allow. This is the primary Claude-side control you tune (see below). |

## `loop.models.sh` — which agent and model run each step (tune between runs)

Each routable in-loop role can use Claude (the default) or Codex, and every role can
use a different model. Interactive contract definition and refinement always run on
Claude; the headless definition pass follows `AGENT_CONTRACT`.
This file is parsed as plain `key=value` pairs — never executed — and changes between
runs do not need re-approval. The harness snapshots it at run start; a mid-run edit
stops as `RISK_REQUIRES_APPROVAL`.

Edit it directly, or run **`./loop.sh setup`** for a guided, isolated session that explains
each knob, answers questions from a bundled reference, and edits only a throwaway copy —
the harness then validates the result deterministically (rejecting, for example, a Codex
role pointed at a Claude model) before reflecting it into the real file. It runs on Claude
by default and falls back to Codex when the Claude CLI is absent; `--app codex` forces Codex.

| Role | Used for | Default |
|---|---|---|
| `MODEL_CONTRACT` | The contract-definition session | **opus** |
| `MODEL_PLAN` | The implementation plan (iteration 0) | **opus** |
| `MODEL_IMPLEMENT` | Implementation and revisions, every iteration | **opus** |
| `MODEL_REVIEW` | The gate/decompose/contract reviews (certification) | **opus** |
| `MODEL_REVIEW_INTERIM` | Interim (per-iteration) reviews only; empty = inherit `MODEL_REVIEW` | sonnet |
| `MODEL_EVIDENCE` | Generating the evidence report | sonnet |
| `MODEL_STOP_EVAL` | The advisory stop check, every iteration | **haiku** (lightweight) |
| `MODEL_DECOMPOSE` | Supervisor: contract → task plan | **opus** |
| `MODEL_SUPERVISE` | Supervisor: mid-run decisions on tasks | **opus** |
| `MODEL_ROLLBACK` | Independent read-only safety review for `discard --rollback` | **opus** |

Each `MODEL_<ROLE>` takes a Claude alias — `opus` (Opus 4.8), `sonnet` (Sonnet 5),
`haiku` (Haiku 4.5), or `fable` (Fable 5, the most capable) — or a full `claude-*`
name; a Codex-routed role takes a Codex slug instead (`gpt-5.5`, `gpt-5.6-sol`,
`gpt-5.6-terra`, `gpt-5.6-luna`, …).

The same file also sets reasoning effort
(`minimal | low | medium | high | xhigh | max | ultra`): `LOOP_EFFORT` (default `xhigh`)
is the global value, and `EFFORT_<ROLE>` (for example, `EFFORT_STOP_EVAL`,
`EFFORT_IMPLEMENT`, or `EFFORT_ROLLBACK`) overrides it per role. The value is translated
to what each role's CLI accepts, so one global is safe across a mixed fleet: Claude `--effort`
takes `low|medium|high|xhigh|max` (the Codex-only tiers down-map — `ultra`→`max`,
`minimal`→`low`),
while Codex `model_reasoning_effort` takes `minimal|low|medium|high|xhigh` on every model
and additionally `max|ultra` **only on `gpt-5.6-sol` / `gpt-5.6-terra`** (on any other Codex
model a `max`/`ultra` request is clamped to `xhigh`, so it degrades rather than errors).
`ultra` also spawns parallel Codex subagents and is preview-only — expect much higher token
use.
The kit ships `EFFORT_STOP_EVAL="low"` and `EFFORT_EVIDENCE="medium"` so clerical roles
do not use maximum reasoning by default. An empty or unrecognized override falls back
to `LOOP_EFFORT` (a typo can never break a running loop). Model support still decides
whether a given effort level changes behavior.

`TURNS_NUDGE_AT` (kit ships 70, ≈ p90 of healthy production iterations) is the
runaway-context signal: when one implement call consumes at least that many agent turns,
the next iteration gets an advisory `.loop/context-nudge.md` telling it to re-plan into a
smaller committed step instead of resuming mid-flight — long-tail iterations are where
cache-read cost explodes. Journaled as `CONTEXT_NUDGE`; empty = off. If it fires on more
than ~1 in 4 iterations, raise the threshold for that project. For a Codex-routed
IMPLEMENT call, the harness approximates turns by counting `item.completed` events; this
usually runs higher than Claude's turn count, so raise `TURNS_NUDGE_AT` if it nudges healthy
Codex iterations.

> **Implement and gate review default to the same model.** The maker–checker separation here
> is *procedural* (a fresh context, a read-only process) — not statistical. A blind spot one
> model shares can pass both roles. The shipped `MODEL_REVIEW_INTERIM="sonnet"` already adds
> cross-tier diversity on the highest-frequency review path; for the gate too, point
> `MODEL_REVIEW` at a different family or tier. The deterministic `VERIFY_COMMANDS` gate is
> unaffected either way, and **the primary stop decision is never a model's** — it's the
> checker re-running your commands.

## `fleet.config.sh` — parallel-execution settings (tune between runs)

Like the model file, this is safe-parsed data rather than sourced shell. Changes
between runs are free; a mid-run change triggers `RISK_REQUIRES_APPROVAL`.

| Key | Default | Meaning |
|---|---|---|
| `FLEET_MAX_PARALLEL` | 3 | Concurrent task slots. All runs share your rate limit — keep it modest. |
| `WORKTREE_SETUP_CMD` | (empty) | Runs once in each new worktree (e.g. `npm ci`). It's arbitrary code, so the supervisor confirms it at start. |
| `FLEET_DECOMPOSE` | 1 | 0 = always run the classic single loop, never decompose. |
| `FLEET_MAX_TASKS` | 12 | Upper bound on tasks one decomposition may emit. Phased chains consume slots too. |
| `FLEET_MAX_SUPERVISE_PER_TASK` | 2 | Supervisor interventions per escalated task before it goes to a human. |
| `FLEET_MAX_REPLAN_TASKS` | 6 | Replacement tasks the supervisor may add per run (cumulative). An N-phase split spends N; a seeded fork-join needs a prep root (4). Raise for long phased workflows. |
| `FLEET_MAX_INTEGRATION_FIXUPS` | 1 | Fix-up rounds after a failed integration gate. |
| `FLEET_SUPERVISE` | 1 | 0 sends escalated tasks straight to a human. |
| `FLEET_SPLIT_CARRYOVER` | 1 | Seed a `NEEDS_DECOMPOSITION` split's first phase with the escalated task's committed work (0 = replacements start clean). |
| `FLEET_PLAN_REVIEW` | 1 | Phase-boundary plan review: re-judge queued tasks after a phase with dependents merges (0 disables). |
| `FLEET_PLAN_REVIEW_ON_DRIFT` | 1 | Also fire the plan review after *any* merged phase that recorded drift (`Drift detected: yes`) while queued tasks remain — so an independent phase's drift can re-plan the remainder, not only a dependency merge (0 = dependency-triggered only). |
| `FLEET_MAX_PLAN_REVISIONS` | 4 | Plan revisions the phase-boundary review may apply per run, cumulative across all boundaries — a 6-phase chain crosses 5. Raise for long phased workflows. |
| `FLEET_SUPERVISOR_SESSION` | 1 | Resume one conversational session across supervisor calls (rotated on failure/mutation; 0 = every call fresh). |
| `FLEET_SUPERVISOR_SESSION_MAX` | 20 | Supervisor calls per session before a forced rotation. |
| `FLEET_STALL_TICKS` | 30 | No-progress watchdog (0 disables). |
| `FLEET_DRAIN_GRACE_TICKS` | 3 | How long `--drain` idles before exiting, so late `add`s are still caught. |
| `FLEET_DRAIN_HUMAN_TICKS` | 150 | Standalone-drain watchdog when everything waits on human approval (0 disables). |

## Cost and budgets (built for subscription usage)

On a Pro/Max subscription there's no per-token charge and the reported USD figure is
notional, so the **default runaway guards are iterations and time, not dollars** —
`MAX_ITERATIONS`, `MAX_ITER_SECONDS`, and optional `MAX_RUN_SECONDS`. `MAX_COST_USD` is
**unset by default**; set it only if you're on API billing and want a hard ceiling on
Claude-reported cost (it then enforces an in-memory running total and adds
`--max-budget-usd` to every Claude call).
The contract session never suggests or sets a USD cap unless you bring up cost yourself.
Claude-reported cost is tracked and logged; Codex calls are recorded as 0 because its result
does not expose USD — unless you fill the per-model `PRICE_*` table in `loop.config.sh`, in
which case Codex cost is **estimated** from token usage, folded into the reported total and
`MAX_COST_USD`, and labeled `推定値 / estimated` everywhere it appears (an estimate, never a
bill; the prices are hashed with the contract — see [Running roles on Codex](codex.md)).
`./loop.sh status` shows the last run **and** the lifetime total across
all runs (derived from the append-only journal), and
`./loop.sh report --text` breaks the last run down by role (implement / interim vs gate
review / plan / evidence / stop-eval) plus the largest implement call by agent turns, so a
runaway iteration is visible instead of buried in one total. Every journal row also carries
the call's `turns` count, and each iteration prints its cost and turns live.

<details>
<summary>Permission mode &amp; the tool allow/deny lists</summary>

A Claude-routed worker runs in `acceptEdits` mode with a **broad allow-list**
(`ALLOWED_TOOLS` — all common built-in tools plus web access by default) and an **opt-in
deny-list** (`DISALLOWED_TOOLS`) that is the primary Claude-side control you tune. Deny wins
over allow; nothing is denied by default. Containment otherwise lives in the checker layer
(evaluator, independent reviewer, approval hash, `DENIED_PATHS`/`ESCALATE_PATHS`), not in
clipping tools. Codex-routed roles use the sandbox controls in [Running roles on Codex](codex.md) instead.

Do not confuse the worker setting with the two uses of "auto." Interactive contract
and refine sessions default to Claude Code's `--permission-mode auto` (overridable
with `LOOP_CONTRACT_PERMISSION_MODE` / `LOOP_REFINE_PERMISSION_MODE`), while
`./loop.sh auto` is loop-kit's unattended definition-and-approval workflow. Neither
changes the approved worker default, `PERMISSION_MODE="acceptEdits"`.

Set `DISALLOWED_TOOLS` in `loop.config.sh` to block specific Claude Code tools (it
re-triggers approval):
`"WebSearch,WebFetch"` (no web), `"Bash(sudo *),Bash(git push *)"` (no privilege-escalation / no
push). Bash rules are prefix-globs matched per sub-command across `&&`/`||`/`|`/`;`.

MCP servers can't be wildcard-granted in a deny-enforcing mode — list a server explicitly in
`ALLOWED_TOOLS` (e.g. `mcp__github`) to use it in the loop. Two caveats: `claude-in-chrome` needs an
interactive browser session and won't attach to a headless loop regardless; and
`PERMISSION_MODE="bypassPermissions"` grants literally everything (including all MCP) but then
**ignores `DISALLOWED_TOOLS`** — it skips the whole permission system.
</details>
