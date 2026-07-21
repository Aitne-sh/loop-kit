[← loop-kit](../README.md) · **Cancelling a plan (`discard`)**

> `discard` permanently cancels one planned queue as a unit, optionally rolling back
> product changes that already merged. This page documents the transaction, the
> fail-closed rollback gates, and how to recover from a crash mid-cancellation.

# Cancelling a whole planned queue — `discard`

`fleet stop <id>` is a resumable pause for one task. To permanently cancel the
currently active *decomposed plan* as one unit, use:

```bash
./loop.sh discard [--rollback|--keep-changes]
```

With a TTY, omitting the flag asks whether already-merged product changes should
also be rolled back; the safe default is to keep them. Without a TTY, exactly one
of `--rollback` or `--keep-changes` is required, and omission refuses to begin the
cancellation transaction. Once published, the choice is durable and cannot change
mid-transaction; after a crash, rerun `discard` with the same flag to resume it.

Discard first publishes a request bound to the plan's immutable queue authority.
That prevents any new claim or merge, stops the supervisor and plan-owned workers,
archives the complete plan/task state, then removes every queue entry and run record
bearing that authority together. Tasks added manually are outside that authority:
they are retained, and any claimed manual peer is parked in its current resumable
phase rather than deleted or rolled back. A queued, claimed, or already-failed
manual task that depended on a cancelled planned task is moved to `failed/` as
`DISCARD_DEP_CANCELLED`; its other dependencies are preserved, and
`fleet resume <id>` explicitly releases it after you review the missing dependency
(a re-queue scraps the task's worktree, so resume refuses while that worktree still
holds implementation work — the refusal names the exact scrap commands).

`--rollback` is deliberately fail-closed and needs **both** gates:

1. A deterministic structural assessor proves every product-changing commit is an
   ordinary Fleet merge with the exact plan/source/branch trailers, task receipt,
   and integration archive, and proves an isolated inverse restores the pinned
   source tree.
2. The independent `ROLLBACK` reviewer inspects the exact patch and archive in a
   read-only session. It may veto the deterministic set; it can never widen it.

Rollback is unavailable if product history contains a manual or parallel commit,
a retained manual task depends on a candidate plan merge, the source branch or
ancestry no longer matches, the parent tracked tree/index is dirty, another
merge/rebase/cherry-pick/revert/bisect operation is active, the inverse does not
apply exactly, external side effects may exist, or any provenance or ownership is
uncertain. A dispatched implementation whose final product diff is empty still
passes the independent side-effect review; net-zero never bypasses that gate. When
both gates say safe, the harness creates exactly one new inverse commit in an
isolated worktree and advances the parent with `--ff-only`; it never resets,
rebases, or rewrites history. If the reviewed product tree already matches the
source, it records `NOT_NEEDED` instead of creating an empty inverse commit.

Cancellation does not depend on rollback succeeding. If rollback is unavailable,
the harness commits a cancellation archive with status `UNAVAILABLE`, keeps the
product changes, removes the planned queue authority, and finishes in `CANCELLED`
(exit 4 so automation notices the unmet rollback request). A successful rollback or
`--keep-changes` also finishes in `CANCELLED` (exit 0). The committed
`.loop/docs/run-archive/<timestamp>-discard/` records the authority, queue/task
metadata, available worktree patches, rollback inputs/verdict, and final receipt;
it is the audit and crash-retry record for the cancelled plan. Before deleting a
worker branch, discard pins its staged branch/worktree commits under
`refs/loop-kit/discard/<authority>/<task>/<commit>` and uses compare-and-delete;
a branch or worktree that advances after staging is kept. Untracked or ignored
user files likewise keep the worktree and produce exit 4; once inspected/saved,
`./loop.sh fleet clean --orphans` removes clean leftovers and its refusal names
`--force` for a worktree whose kept content should be deleted too. A retained
manual dependent (`DISCARD_DEP_CANCELLED`) that still holds implementation work
also refuses `resume`'s re-queue until you scrap that work explicitly — the
refusal names the exact commands. If live queue metadata
changes after staging, it is moved recoverably under
`.loop/fleet/discard-quarantine/<authority>/<task>/` instead of being overwritten.
The request file is the transaction journal and is removed last, so rerunning the
same command can finish cleanup even after plan authority was already retired.
Recovery refs are intentionally retained after cancellation so a deleted worker
branch cannot make its last commit unreachable. After you have inspected the
archive/quarantine and no longer need recovery, list the exact authority with
`git for-each-ref refs/loop-kit/discard/<authority>/`; retire only a reviewed leaf
with `git update-ref -d <exact-ref> <expected-commit>`.
