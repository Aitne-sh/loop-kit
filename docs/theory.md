[← loop-kit](../README.md) · **Theory → implementation**

> loop-kit draws on loop-engineering research, primary documentation, and established
> software-engineering practice. Each row below maps an idea to the concrete mechanism
> that implements it.

# How the theory maps to the implementation

loop-kit draws on loop-engineering research, primary documentation, and established
software-engineering practice. Each row maps an idea to the concrete harness mechanism.

| Idea | Source | Implementation |
|---|---|---|
| A loop is a work cycle that runs until a stop condition; four kinds (turn / goal / time / proactive) | [Anthropic: Getting started with loops](https://claude.com/blog/getting-started-with-loops) | The external shell loop covers long-running work; combined with `/goal`, `/loop`, and `/schedule`, all four kinds are covered |
| A loop spec is a bounded, reusable artifact with five parts: trigger, goal, verification, stopping rule, memory | [arXiv 2607.00038](https://arxiv.org/abs/2607.00038) (Macedo, *Stop Hand-Holding Your Coding Agent*) | Spec = contract + config; verification = `evaluate.sh`; stopping = named states with stable exit codes; memory = `.loop/docs` + git |
| "The verifier is the bottleneck" — deterministic checks first | same / [Firecrawl](https://www.firecrawl.dev/blog/loop-engineering) | The first gate re-runs the actual commands outside the model; AI review is second; humans see only the evidence |
| Three hard stops against runaways: iteration cap, budget, stagnation | 2026 practitioner write-ups | `MAX_ITERATIONS` + `MAX_ITER_SECONDS` by default, optional Claude-only `MAX_COST_USD`, plus stagnation / repeat-failure / futile detection |
| Fixed requirements contract, flexible plan, evidence review, escalation | Loop-engineering design theory | Contract locked by an approval hash / plan free to evolve / evidence reports / the `NEEDS_*` states |
| Maker–checker separation (no self-grading; a fresh-context verifier) | [Firecrawl](https://www.firecrawl.dev/blog/loop-engineering) / [Addy Osmani](https://addyosmani.com/blog/agent-harness-engineering/) | An independent read-only reviewer each iteration + the deterministic evaluator — applied to the *goalposts themselves* too (the auto-mode contract review) |
| The Ralph loop (fresh context each time; memory in the filesystem) | [Geoffrey Huntley](https://ghuntley.com/ralph/) / [ralph-wiggum plugin](https://github.com/anthropics/claude-code/blob/main/plugins/ralph-wiggum/README.md) | A fresh routed CLI call every iteration; memory in `.loop/docs` + git |
| Orchestrator–worker: decompose with explicit boundaries and dependencies; parallelize independent, serialize dependent; verify before merge | [Anthropic: multi-agent research system](https://www.anthropic.com/engineering/built-multi-agent-research-system) / [Claude Code worktrees](https://code.claude.com/docs/en/worktrees) | `/loop-decompose` + deterministic validation (Kahn cycle check, REQ coverage) + independent decompose review; dependency gating on merged work; worktree isolation + serial merges + the integration gate |
| Analytic rubrics beat holistic judgment: one verdict per criterion prevents halo effects | [Autorubric, arXiv 2603.00077](https://arxiv.org/abs/2603.00077) | The gate reviewer renders one machine-parsed verdict per `REQ`; the harness downgrades an APPROVE whose table is missing or non-`MET` (fail closed) |
| Agentic entropy: iterating agents degrade code; per-diff review is blind to cross-iteration damage | [Beyond the Diff, arXiv 2604.16323](https://arxiv.org/abs/2604.16323) / [SlopCodeBench, arXiv 2603.24755](https://arxiv.org/abs/2603.24755) | Requirement-first read order + a widened `scope=run` erosion audit every `HOLISTIC_EVERY_N` iterations or on a large diff; the requirements ledger gives reviews cross-iteration memory |
| Controlled spec evolution: mid-run discoveries become structured, reviewable records — not a full stop, not silent improvisation | [OpenSpec delta specs](https://openspec.dev/) | `assumptions.md`: non-contract-changing discoveries recorded with a conservative default; the gate adjudicates each; the evidence report shows them all |
| TDD's red-green rule: see the check fail before making it pass — an always-green gate proves nothing about new behavior | Beck, *Test-Driven Development: By Example* | The contract interview always confirms the acceptance gate with the user (a concrete proposal is always offered) and classifies each `VERIFY_COMMAND` red→green vs stays-green; the harness snapshots the run-start verify (`.loop/baseline-verify.log`) and the evidence report shows baseline→final per command |
| A safe way to reduce routine permission prompts in an interactive session | [Anthropic: Auto mode](https://claude.com/blog/auto-mode) | Interactive contract/refine sessions default to Claude Code permission mode `auto`; autonomous workers remain on the separately approved `PERMISSION_MODE="acceptEdits"` policy. `./loop.sh auto` is an unattended orchestration mode, and its approvals are audit-logged. |
| Must-be quality is unstated: users never ask for what they assume ("of course it still renders") | Kano model (Kano et al., 1984, "must-be quality" / atarimae hinshitsu) | The contract skill's expectation-decomposition pass — preservation invariants, domain baseline, premortem — lands as acceptance-checklist rows the evaluator enforces |
| Verification methods are not interchangeable: Inspection / Analysis / Demonstration / Test — analyzing the code never substitutes for demonstrating the behavior | NASA Systems Engineering Handbook §6.7 / INCOSE SE Handbook (verification methods) | Every checklist row carries `cmd` / `run` / `human`; a `run` row closes only with an observation artifact whose manifest stamp binds its bytes to the current AC and product tree, then the gate reviewer opens and judges it |
| The test-oracle problem: rendered/visual output often has no automatable oracle | Barr et al., *The Oracle Problem in Software Testing* (IEEE TSE 2015); VRT practice (screenshot testing) | Scriptable observations become self-terminating probe commands in the verify gate; the remainder becomes screenshot evidence a reviewer/human judges — never silently waived |
| Test the gate itself: would a broken implementation still pass it? | Mutation testing (DeMillo, Lipton & Sayward 1978); specification-gaming literature | The contract reviewer's falsifiability audit: describe one plausible broken-but-green implementation per REQ; if it exists and matters, the definition is rejected until the gate discriminates |
| Premortem: imagine the failure first, then work backwards to its causes | Klein, *Performing a Project Premortem* (HBR 2007) | The definition session names the 3 most plausible "gates green, user disappointed" outcomes and converts each into a checklist row, a Non-goal, or a recorded assumption |
| Evaluation criteria are generated dynamically but must execute as a frozen contract — post-hoc edits are goalpost-moving | Dynamic evaluator-generation design theory (evaluation-contract pattern; cf. Goodhart's law) | Obligations anchor to contract-named AC ids; the evaluator's run-scoped id ledger (`.loop/ac-seen`) refuses promotion when a recorded row vanishes, and a row's method cell may not weaken vs its contract anchor (`run` → `cmd`) |
| Audit coverage and traceability BEFORE locking the contract: every mandatory requirement maps to a criterion, every criterion traces back to a requirement | same (coverage = 1.0 rule; traceability audit) | The approve-time definition lint: contract-anchored AC ids need rows, rows must reference defined REQs, duplicate ids refused — all before the approval hash is written; the contract reviewer audits per-row provenance and atomicity |
| Never execute model-generated commands unaudited (allowlist-oracle principle) | same (shell-implementation principles) | Destructive-pattern lint over `VERIFY_COMMANDS` at approval — refused unattended, explicit human override interactively; the contract reviewer's Safe-gate rule judges intent, not just patterns |
| A repeating failure *set* — not just an identical failure — is a stop condition | same (stop-kernel conditions: cycling artifacts / repeated failure sets) | Oscillation window in the evaluator: ≤2 distinct failure fingerprints across `2×REPEAT_FAIL_N` consecutive failing iterations → `BLOCKED` |

---

*Review the contract before a run, then use the machine certification and evidence
report as the primary handoff. Inspect implementation diffs whenever the risk warrants it.*

---

## Using this alongside Claude Code's built-in primitives

loop-kit covers long-running autonomous work; for shorter jobs the built-ins are lighter:

- **Goal-based** — `claude "/goal <acceptance criteria>, stop after 8 turns"`.
- **Time-based** — `/loop 15m /loop-iterate` inside a session, or the kit's own
  `./loop.sh watch --interval 900`.
- **Proactive** — schedule a `/schedule` cloud routine with your approved contract.
- **An extra review pass** — after SUCCESS, layer the built-in `/code-review` on top.
