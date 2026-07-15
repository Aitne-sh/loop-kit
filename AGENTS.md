# Repository Guidelines

## Project Context

This repository is the source distribution of **loop-kit**, not a project with
loop-kit already deployed. The product is a Bash harness plus prompt and document
templates; there is no package manager, build step, server, or compiled artifact.
`bin/loop.sh init <target>` copies the managed files into a target project.

Read `CLAUDE.md` before changing behavior. Use `README.md` as the user-facing
manual, but confirm implementation claims against the scripts and tests.

## Repository Map

- `bin/loop.sh`: deterministic state machine, approval hashing, worktrees,
  journaling, command dispatch, and Fleet supervisor.
- `bin/evaluate.sh`: maker-checker boundary; independently reruns the approved
  `VERIFY_COMMANDS` before model review.
- `kit/.claude/skills/loop-*/SKILL.md`: prompts for contract, planning,
  implementation, review, decomposition, supervision, and evidence phases.
- `kit/loop-docs/`: pristine templates copied into deployed projects.
- `kit/*.config.sh` and `kit/loop.models.sh`: shipped configuration defaults.
- `tests/run_tests.sh`: authoritative zero-token behavioral suite using
  `tests/fake_claude.sh` and `tests/fake_codex.sh`; it exercises the deployed layout.
- `tests/artifact-lifecycle.txt`: required ownership classification for every
  `.loop/` path literal introduced in `bin/loop.sh`.
- `examples/`: small deployment fixtures, not the harness implementation.

## Parallel-Session Safety

Assume Claude Code and Codex sessions may be implementing concurrently.

1. Before editing, run `git status --porcelain` and check for live
   `run_tests.sh`, `loop.sh`, `fake_claude.sh`, or `fake_codex.sh` processes.
2. Treat every pre-existing diff, untracked file, or unexpectedly fresh edit as
   peer-owned. Never drop, revert, restore, overwrite, or check out another
   agent's work.
3. Re-read the current file and its diff immediately before each patch. Make
   surgical edits with narrow context.
4. If another change touches the same code, preserve both requirements and
   integrate them coherently. Do not choose one implementation by discarding the
   other. If they genuinely conflict, stop and report the exact conflict.
5. Never edit `bin/loop.sh`, `tests/run_tests.sh`, or `kit/**` while any test
   suite is running. Never start a second suite, or a suite alongside a real
   Fleet run; PID-liveness checks are machine-global and concurrent runs become
   flaky.

## Implementation Invariants

- Target Bash 3.2 and macOS/Linux userlands. Use `bash -n`, never `sh -n`.
- Keep parsing portable across BSD awk, gawk, and mawk. Do not introduce Python
  or `jq` as harness dependencies.
- Every user-facing stop or error must include a canonical recovery command:
  use `print_next_actions`, `die_next`/`fdie_next`, or evaluator `enext` rather
  than ad hoc messages.
- Classify each new `.loop/` artifact as `run`, `contract`, `persistent`, or
  `liveness` in `tests/artifact-lifecycle.txt`.
- When adding a top-level deployed file, update the uninstall enumeration,
  `ensure_gitignore`, and `strip_gitignore_blocks` together.
- Do not “fix” unlinking the currently running `loop.sh`; update and uninstall
  intentionally rely on the live inode.
- Preserve the success boundary: deterministic verification, success-gate
  review, per-requirement approval, evidence generation, and final no-drift
  checks must all pass. Errors, timeouts, outages, or spent budgets never become
  `SUCCESS`.
- Keep shipped defaults synchronized across `kit` configuration, fallback logic
  in `bin/loop.sh`, `README.md`, and mirrored test assertions.

## Validation

During iteration, run `bash -n` on every changed shell script. Run:

```bash
shellcheck bin/loop.sh bin/evaluate.sh tests/fake_claude.sh tests/fake_codex.sh tests/run_tests.sh
```

The final behavioral gate is:

```bash
tests/run_tests.sh
```

It has no single-test filter and must run alone, in the foreground, after peer
suites and Fleet processes finish. A passing suite proves harness mechanics; it
does not by itself prove real-model output quality. For documentation-only
changes, also run `git diff --check` and verify every referenced command/path.

## Git Discipline

Keep staging limited to files changed for the current request. Do not clean or
rewrite unrelated working-tree state. Before any requested commit or push, check
`git status -sb` and compare `HEAD` with `origin/main`; do not assume remote
history is unchanged. If currently on `main`, create a branch before committing
unless the user explicitly requested a direct `main` commit. Commit or push only
when the user asks for it.
