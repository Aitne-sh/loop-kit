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
# review/stop-eval, the fleet, the resume matrix, and tamper defenses. ~1000+ assertions.
# Ends with a shellcheck gate.
tests/run_tests.sh                       # parallel lane at -j<auto: cores-1, capped 4>, then serial
tests/run_tests.sh -j1                   # strict manifest order, one process (baseline mode)
tests/run_tests.sh --only 50-discard     # ONE suite file (substring match); repeatable
tests/run_tests.sh --list                # every suite file and its lane
LOOP_TEST_TIMING=1 tests/run_tests.sh    # + a slowest-sections table

# Fast syntax check while iterating on the harness (loop.sh targets bash, not POSIX sh —
# `sh -n` will report false errors on its process-substitution/arrays; use bash).
bash -n bin/loop.sh

# Lint (also run as the suite's final assertion, over the suite files too).
# Config lives in /.shellcheckrc and is the ONLY place to disable a check globally —
# it exists because CI's runner image ships shellcheck 0.9.0 while a current dev box
# has 0.11.0, and three checks upstream retired between them were red in CI and
# invisible locally. A clean local lint is therefore NOT proof CI is clean unless
# .shellcheckrc covers the delta; suppress anything else at the site, with a reason.
shellcheck bin/loop.sh bin/evaluate.sh tests/fake_claude.sh tests/fake_codex.sh \
           tests/run_tests.sh tests/lib.sh tests/suite/*.sh

# Deploy / manage the kit in a target project (run from THIS repo = "kit mode")
bin/loop.sh init <dir> [--template demo1-bugfix|demo2-feature]
bin/loop.sh update <dir> [--approve]
bin/loop.sh uninstall <dir> [--force]     # removes every deployed file + run state
```

The suite is a **driver plus one file per area**: `tests/run_tests.sh` decides what runs and
aggregates the counts; the assertions live in `tests/suite/NN-*.sh`, each of which sources
`tests/lib.sh` (every shared helper — `make_fixture`, `run_loop`, `wait_sup`, the fleet/orch/
discard/resume fixture builders) and is also runnable on its own. `tests/suite/manifest.txt`
fixes the order and classifies every file as `parallel` or `serial`; a file missing from it, or
carrying any other lane, is a hard error, so a new suite file cannot be silently skipped.

**Lanes.** The parallel lane runs at `-j` (default: cores − 1, capped at 4 — the suite shares
the machine with agent sessions; raise it explicitly on an idle box), then the serial lane runs
alone. The parallel stage is work-bound, not critical-path bound: measured wall time tracks
total work ÷ `-j`, so `-j` is the knob, not further file splitting. Put a test in `serial` only for one of the two reasons the driver
header documents: it SIGKILLs a real `loop.sh` and then asserts the recorded pid is dead
(`ps -p <pid> | grep loop.sh` is machine-global, so a pid recycled by a sibling lane reads as
alive), or it pins `MAX_ITER_SECONDS=1` / observes process topology, where CPU contention
changes what is measured. Everything else — including nearly all of the fleet — waits on
observable state through bounded polls and is lane-safe.

Bounded waits (`while [ "$n" -lt $((N * POLL_SCALE)) ]`, `SUP_WAIT_MAX`) are **hang backstops,
not assertions**; the driver raises them when lanes share the CPU so contention shows up as a
slower suite, never as a spurious timeout FAIL. Never express an assertion as one of these
ceilings. Do not add `&` / background a second copy of the driver — see the concurrency rules
below.

Inside a *deployed* project the same script drives the loop (`./loop.sh` auto, `./loop.sh start
"<instruction>"`, `./loop.sh run`, `./loop.sh discard [--rollback|--keep-changes]`,
`./loop.sh status`/`report`). You rarely run these here; the
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
  Whole-plan `discard` uses the same deterministic-authority posture: one durable request
  stops all future claims/merges for that plan authority before its queue state is removed.
  Optional rollback is a separate `ROLLBACK` reader role (`MODEL_ROLLBACK`,
  `AGENT_ROLLBACK`, `EFFORT_ROLLBACK`, and approval-gated `TIMEOUT_ROLLBACK`), never model
  authority by itself.
- **`bin/evaluate.sh`** — the evaluator. Re-runs the user's `VERIFY_COMMANDS` *outside* the
  model. This is the maker–checker boundary: deterministic checks gate first, AI review second,
  humans see only an evidence report. No model self-grades.
- **`kit/.claude/skills/loop-*/SKILL.md`** — the canonical *prompts*. Each phase of the spine
  is a skill: `loop-contract` (+`-review`), `loop-decompose` (+`-review`), `loop-plan`
  (+`-review`), `loop-iterate`, `loop-review`, `loop-stop-eval`, `loop-evidence`,
  `loop-supervise`, `loop-rollback-review`, plus `loop-setup` (interactive agent/model tuning,
  dual-projected) and Claude-only `loop-refine`: fourteen canonical Claude skills total.
  `init`/`update` project the thirteen headless-compatible skills into `.agents/skills` with
  Codex-valid frontmatter and invocation metadata; never maintain a second source tree or
  deploy `.codex/skills`.
- **`kit/loop-docs/*.md`** — pristine templates for the working docs (`product-contract.md`,
  `implementation-plan.md`, `progress.md`, `requirements-ledger.md`, `evidence-report.md`, …).
- **`kit/loop.config.sh` / `loop.models.sh` / `fleet.config.sh`** — user-tunable config templates
  (stop conditions/paths, per-phase agent/model routing, fleet knobs).

`init`/`update` copy `bin/*` + `kit/*` into a project as `loop.sh`,
`.loop/bin/evaluate.sh`, `.claude/skills/loop-*`, projected `.agents/skills/loop-*`,
`.loop/docs/*`, and the config files. They preserve user-owned `AGENTS.md`,
`AGENTS.override.md`, `.codex/**`, and non-managed skills. The user manual is `README.md`
(pitch, the `init`→`setup`→`start`→`discard` command lifecycle, architecture) plus one
`docs/*.md` page per subsystem — `contract`, `iteration`, `fleet`, `discard`,
`configuration`, `codex`, `states-and-recovery`, `security`, `html-views`, `deployment`,
`testing`, `theory`. A behavior change updates the owning page, not the README summary
alone; `docs/theory.md` cites the primary sources each mechanism implements, and
`docs/configuration.md` is the shipped-default mirror the suite pins.

**The spine:** contract → approve → decompose → loop → evidence. State is once-approved and
hash-locked, then the plan is free to evolve. Terminal states each map to an exit code
(`SUCCESS`/`NO_OP` 0, `CANCELLED` 0 or 4 when rollback is unavailable or cleanup
quarantines artifacts, `NEEDS_*` 3, `BLOCKED`/`STALLED` 4, `BUDGET_EXCEEDED` 5,
usage/unapproved 2).
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

**Whole-plan discard.** `./loop.sh discard [--rollback|--keep-changes]` permanently revokes one
planned queue authority as a unit; it does not delete manual side-tasks, which are retained or
parked for resume. A TTY may confirm the choice, while non-TTY use must name a flag. Rollback
requires both structural provenance checks and the independent read-only reviewer, and is
UNAVAILABLE on manual/parallel product commits, a dirty tracked parent/index, branch/source
mismatch, an unrelated Git operation, possible external side effects, or any uncertainty. A safe
rollback is one new inverse commit advanced by `--ff-only`, never a reset/rebase/history rewrite.
Rollback failure never resurrects the queue: product changes are retained, the cancellation
archive is committed under `.loop/docs/run-archive/`, and the root finishes `CANCELLED`; rerunning
the same choice after a crash resumes the durable transaction. The discard request is the WAL and
is removed last. Cleanup trusts committed archive metadata, pins worker commits under OID-specific
`refs/loop-kit/discard/` refs, deletes branches with compare-and-delete, and preserves post-stage
drift or user-owned ignored files in place or under `.loop/fleet/discard-quarantine/`.

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
  and never widen those call sites back to `full`. Candidate bytes belong only in
  ignored, contract-scoped channels: staging in `.loop/plan-candidates/`, plus the
  rejected attempt appended verbatim to the git-ignored `*-feedback.md` for the retry
  (`append_rejected_attempt` — guarded by `git check-ignore`, capped at the envelope's
  1 MiB; the retry fixes only the named violations instead of regenerating from
  scratch). The envelope tolerates prose before its opening marker (extraction is
  marker-bounded; a stray marker or duplicate verdict still rejects). Decompose and
  implementation-plan candidates are re-validated after their independent reviews
  (`loop-decompose-review` /
  `loop-plan-review`; opt-out `LOOP_DECOMPOSE_REVIEW=0` / `LOOP_PLAN_REVIEW=0` — the
  plan-review verdict token is `IMPL-PLAN-REVIEW:`, never `PLAN-REVIEW:`, which the fleet
  phase-boundary review owns), and only the harness publishes `.loop/docs/task-plan.md` /
  `implementation-plan.md`. The containment check is deliberately cheap (git porcelain +
  HEAD ref + `check_harness`) — per-call full-tree hashing, off-tree guard mirrors, and
  plan context-binding were evaluated and rejected as disproportionate; do not reintroduce
  them without a concrete threat that the cheap check misses. Claude planner sessions get only
  Read/Glob/Grep, but project hooks/plugins/MCP are NOT structurally isolated; Codex
  `read-only` is a local-filesystem boundary only.
- **`RISK_REQUIRES_APPROVAL` is a guard verdict, not a decision request.** finish() shows
  the dedicated risk box (`print_next_actions risk`) and never the decision-request file;
  agents must not author DRs or decision HTML for RISK. NEEDS_*/PENDING displays gate on
  `decision_requests_present()` (any real DR heading; the pristine `## DR-N:` template
  example is not actionable); BLOCKED/STALLED keep the deliberately narrower
  `^## DR-[0-9]` gate — answered DR-CONTRACT/DR-FLEET blocks persist in the file and must
  not reprint there as "from this run".

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

- **Never edit `bin/loop.sh`, `tests/**`, or `kit/**` while any test suite is running** —
  yours or a peer's. Suite files are read incrementally by bash (a live edit corrupts the
  running script), and the suite reads `kit/**` + `bin/**` as test *input*. The driver
  parallelizes *within* one suite (lanes), but two concurrent **drivers** are still forbidden:
  PID-liveness validation is machine-global, so the other run's recycled pids can be adopted as
  live tasks. Wait for the suite to finish, or run yours only once no peer suite is active.
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
