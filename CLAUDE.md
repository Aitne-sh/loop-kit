# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the **source of loop-kit**, not a deployed instance of it. loop-kit turns Claude Code,
Codex, or a role-by-role mix of both into a contract-driven agentic loop (implement → verify →
review → improve, fresh context each iteration, until every requirement is met or it stops for
a human). You are editing the harness and prompts here; end users get a *copy* via
`bin/loop.sh init <their-project>`.

The whole product is **shell + prompt files** — there is no build step, no package manager, no
compiled artifact. The deliverable is the scripts themselves.

## Commands

```bash
# Full test suite — the primary gate. Zero-token E2E: swaps fake agents in for `claude` /
# `codex` (LOOP_CLAUDE_CMD / LOOP_CODEX_CMD) and drives every terminal state,
# review/stop-eval, the fleet, the resume matrix, and tamper defenses. ~1000+ assertions,
# a few minutes. Ends with a shellcheck gate.
tests/run_tests.sh

# Fast syntax check while iterating on the harness (loop.sh targets bash, not POSIX sh —
# `sh -n` will report false errors on its process-substitution/arrays; use bash).
bash -n bin/loop.sh

# Lint (also run as the suite's final assertion)
shellcheck bin/loop.sh bin/evaluate.sh tests/fake_claude.sh tests/fake_codex.sh tests/run_tests.sh

# Deploy / manage the kit in a target project (run from THIS repo = "kit mode")
bin/loop.sh init <dir> [--template demo1-bugfix|demo2-feature]
bin/loop.sh update <dir> [--approve]
bin/loop.sh uninstall <dir> [--force]     # removes every deployed file + run state
```

There is **no single-test filter** — `run_tests.sh` is one linear script that runs the entire
suite. To iterate on one area, validate the change with `bash -n` first, then run the full suite.
Do not add `&` / background a second copy — see the concurrency rules below.

Inside a *deployed* project the same script drives the loop (`./loop.sh` auto, `./loop.sh start
"<instruction>"`, `./loop.sh run`, `./loop.sh status`/`report`). You rarely run these here; the
test fixtures exercise them against the fake agent instead.

## Architecture

Two layers, and the split is the point:

- **`bin/loop.sh`** — the deterministic harness (one large bash file; the fleet supervisor is
  folded into it, there is no separate `fleet.sh`). Orchestration, state machine, approval
  hashing, git/worktree management, journaling, and command dispatch all live here.
  `run_claude` retains its historical name but dispatches each routable role through
  `AGENT_<ROLE>`; its Codex adapter normalizes JSONL into the existing result envelope.
  Codex checker AND planner roles force `read-only` plus `project_doc_max_bytes=0`,
  preventing repository `AGENTS.md` from becoming role instructions; other authoring
  roles retain normal project guidance and write posture.
  `AGENT_CONTRACT` governs only the headless definition path — interactive `start`/`refine`
  launch the Claude TUI directly and never consult the resolver.
  DECOMPOSE and the iteration-0 PLAN are read-only planning roles (`planner` mode =
  reader's structural posture for both CLIs): the model returns the plan in a versioned
  response envelope, the harness stages it under the ignored, contract-scoped
  `.loop/plan-candidates/`, validates it deterministically, and alone publishes the
  authoritative documents. A cheap before/after Git-state check (porcelain + HEAD ref +
  `check_harness`) around each planner call turns any planner-side write or commit into
  `RISK_REQUIRES_APPROVAL`. Mechanical validation does not make semantic plan quality
  deterministic.
- **`bin/evaluate.sh`** — the evaluator. Re-runs the user's `VERIFY_COMMANDS` *outside* the
  model. This is the maker–checker boundary: deterministic checks gate first, AI review second,
  humans see only an evidence report. No model self-grades.
- **`kit/.claude/skills/loop-*/SKILL.md`** — the canonical *prompts*. Each phase of the spine
  is a skill: `loop-contract` (+`-review`), `loop-decompose` (+`-review`), `loop-plan`,
  `loop-iterate`, `loop-review`, `loop-stop-eval`, `loop-evidence`, `loop-supervise`, plus
  `loop-setup` (interactive agent/model tuning, dual-projected) and Claude-only `loop-refine`.
  `init`/`update` project the eleven headless-compatible skills into `.agents/skills` with
  Codex-valid frontmatter and invocation metadata; never maintain a second source tree or
  deploy `.codex/skills`.
- **`kit/loop-docs/*.md`** — pristine templates for the working docs (`product-contract.md`,
  `implementation-plan.md`, `progress.md`, `requirements-ledger.md`, `evidence-report.md`, …).
- **`kit/loop.config.sh` / `loop.models.sh` / `fleet.config.sh`** — user-tunable config templates
  (stop conditions/paths, per-phase agent/model routing, fleet knobs).

`init`/`update` copy `bin/*` + `kit/*` into a project as `loop.sh`,
`.loop/bin/evaluate.sh`, `.claude/skills/loop-*`, projected `.agents/skills/loop-*`,
`.loop/docs/*`, and the config files. They preserve user-owned `AGENTS.md`,
`AGENTS.override.md`, `.codex/**`, and non-managed skills. `README.md` (extensive) is the user
manual; its "How the theory maps to the implementation" table cites the primary sources each
mechanism implements.

**The spine:** contract → approve → decompose → loop → evidence. State is once-approved and
hash-locked, then the plan is free to evolve. Terminal states each map to an exit code
(`SUCCESS`/`NO_OP` 0, `NEEDS_*` 3, `BLOCKED`/`STALLED` 4, `BUDGET_EXCEEDED` 5, usage/unapproved 2).
The **only** path to `SUCCESS` is: every VERIFY_COMMAND passes on evaluator re-run, the success
gate ran, the independent reviewer said APPROVE with a clean per-REQ table, an evidence report
exists, and no unreviewed change follows it.

**Two run modes** are auto-detected by whether the script sits in the kit repo (`MODE=kit`:
`init`/`update`/`uninstall` require a target dir; self-protection refuses to operate on the kit
repo itself) or inside a deployed project (`MODE=deployed`: those commands act on the current
project with no dir argument).

**Approval hashing.** A run is gated by `contract_hash` (contract + `loop.config.sh`) and
`harness_hash` (`loop.sh` + evaluator + both managed skill trees +
`.claude/settings*.json` + `.mcp.json` + recursive `.codex/**`). Recursive inputs bind the
relative path and contents, so add/remove/rename is detected. In a *deployed* project, changing
the harness invalidates the recorded approval and `run` refuses until re-approval. Records live
off-tree at `~/.loop-kit/approvals/<repo-id>/<slot-id>` (one slot per worktree; `uninstall`
sweeps the whole repo group). This is why editing the harness in this source repo is free, but
the *test fixtures* must re-approve after harness changes — the suite handles that.

**Fleet (parallel).** The supervisor decomposes the contract into a queue, dispatches independent
tasks into isolated git worktrees (siblings under `<project>-loops/`), serializes merges, gates
the merged whole against the master contract (the integration gate ignores even `REVIEW_MODE=off`),
and handles dependency gating, replanning, and human escalation. Approved `.agents` skills and
the repository `.codex/**` control plane are copied byte-for-byte into each worker.

## Editing invariants (these will fail the suite if broken)

- **Every user-facing stop/error must name the next command, in one of two canonical forms.**
  Multi-option stops go through `print_next_actions <context>` (the boxed **NEXT ACTION**); a
  new terminal state adds a context there rather than inlining ad-hoc `Next:`/`resume:` lines.
  Single-step error paths use `die_next`/`fdie_next` (and `enext` in `evaluate.sh`), which print
  the problem then a trailing `  → next: <command>` line — never a bare `die`/`fdie` that leaves
  the user with no recovery. SUCCESS/NO_OP are the only exemption (they show the `./loop.sh start`
  hint). This keeps the "what do I run next?" surface uniform; the suite pins it.
- **Every `.loop/` path literal in `loop.sh` must be classified** in `tests/artifact-lifecycle.txt`
  with a scope (`run` / `contract` / `persistent` / `liveness`). Adding a new `.loop/` artifact
  without a lifecycle entry fails the suite — decide up front which boundary resets it. Unowned
  artifacts are how stale-state bugs (a prior run's decision brief, aliased `met` ledger rows) are
  born.
- **POSIX/BSD-awk portability.** The harness has no python/jq dependency; JSON and text munging is
  hand-rolled awk that must run on macOS/BSD awk *and* gawk/mawk. Notably `awk -v` rejects embedded
  newlines, and gsub backslash grammar differs across awks (see the `json_escape` char-by-char
  comment). Test any awk change mentally against BSD awk, and rely on the suite.
- **Keep `uninstall` / `ensure_gitignore` / `strip_gitignore_blocks` in sync.** `uninstall` removes
  all of `.loop/` via `rm -rf` (so `.loop/` additions are covered automatically) but the top-level
  files are a fixed enumeration (`loop.sh loop.config.sh loop.models.sh fleet.config.sh`). A new
  top-level deployed file must be added to all three of: the `rm -f` list, the gitignore block
  written by `ensure_gitignore`, and the `ours()` list in `strip_gitignore_blocks`.
- **Unlinking the running `loop.sh` is intentional** (the live process keeps its inode); `update`
  and `uninstall` rely on it. Don't "fix" it.
- **The Claude skill tree is canonical.** Codex deployment is a generated projection:
  strip Claude-only frontmatter, add `agents/openai.yaml`, exclude `loop-refine`, and preserve
  provider-neutral bodies. Keep frontmatter descriptions within Codex's 1024-character limit
  and free of `<` / `>`. Never hand-maintain a second source tree. A non-managed skill-name
  collision must stop with a recovery command instead of overwriting user content.
- **`LOOP_CODEX_NETWORK` controls only Codex shell-sandbox networking.** It does not disable
  MCP servers, connected apps, or hosted search exposed by the Codex client. Treat those as
  separate environment capabilities.
- **Planner publication is harness-owned.** DECOMPOSE and iteration-0 PLAN stay in the
  read-only `planner` envelope path; never let a model write their authoritative documents
  and never widen those call sites back to `full`. Candidate bytes belong only in the
  ignored, contract-scoped `.loop/plan-candidates/`; decompose candidates are re-validated
  after the independent review, and only the harness publishes `.loop/docs/task-plan.md` /
  `implementation-plan.md`. The containment check is deliberately cheap (git porcelain +
  HEAD ref + `check_harness`) — per-call full-tree hashing, off-tree guard mirrors, and
  plan context-binding were evaluated and rejected as disproportionate (heavier variants
  live on the parked `codex-hardening-wip` branch). Claude planner sessions get only
  Read/Glob/Grep, but project hooks/plugins/MCP are NOT structurally isolated; Codex
  `read-only` is a local-filesystem boundary only.
- **`RISK_REQUIRES_APPROVAL` is a guard verdict, not a decision request.** finish() shows
  the dedicated risk box (`print_next_actions risk`) and never the decision-request file;
  agents must not author DRs or decision HTML for RISK. `decision_requests_present()`
  gates every DR display on a real heading (the pristine `## DR-N:` template example is
  not actionable).

## Concurrent Claude Code and Codex sessions

Multiple Claude Code and Codex sessions may work in this repo at the same time. Assume a peer
session could be mid-implementation on the very files you are about to touch — do not destroy
its work.

**Detect before you edit** shared files (`bin/loop.sh`, `bin/evaluate.sh`, `tests/**`, `kit/**`):

```bash
ps aux | grep -E "run_tests.sh|loop.sh|fake_claude.sh|fake_codex.sh" | grep -v grep   # peer suite / fleet?
git status --porcelain                                                  # uncommitted work you didn't make?
```

Uncommitted changes you did not make, or a fresher mtime than your last edit, mean another session
is live. Also check whether the running process belongs to a *different* session (its `zsh -c`
wrapper path contains that session's id).

**Rules:**

- **Never edit `bin/loop.sh`, `tests/run_tests.sh`, or `kit/**` while any test suite is running** —
  yours or a peer's. `run_tests.sh` is read incrementally by bash (a live edit corrupts the running
  script) and its PID-liveness checks are machine-global, so a second concurrent suite makes fleet
  timing tests flaky (the `run_tests.sh` header documents this). Wait for the suite to finish, or
  run yours only once no peer suite is active.
- **Do not revert, overwrite, or `git checkout` changes you did not make.** Treat them as a peer's
  in-flight requirement to preserve.
- **Re-read immediately before each edit.** mtimes shift under you; use `Read` then `Edit` with
  minimal, uniquely-scoped `old_string`s so a mismatch fails loudly instead of silently clobbering a
  region you don't own. Never rewrite a whole function/file when a surgical edit suffices.
- **When both sessions must change the same code, satisfy both requirements — don't pick one.** Read
  the peer's change first, make yours additive/compatible with it, keep it local, and verify with
  `bash -n` (+ the suite when safe) before and after. If the two changes genuinely conflict, land
  one as a committed base (or isolate onto a branch/worktree) and rebuild the other on top — never
  silently drop either requirement.
- **Commit your own verified change promptly** so a peer rebases onto a stable base instead of racing
  your working tree. Small, frequent commits on `main` are the coordination mechanism; if you are on
  `main` and about to commit, branch first unless the user asked to commit to `main`.
