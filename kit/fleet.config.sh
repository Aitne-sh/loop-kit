# fleet.config.sh — parallel supervisor settings. Safe-parsed key=value (never
# sourced as code; like loop.models.sh, editable any time without re-approval).

# Maximum concurrent task loops (each live loop is one claude session at a time,
# and contract generation for a new task also occupies a slot). Subscription
# rate windows are shared across ALL runs — keep this modest.
FLEET_MAX_PARALLEL="2"

# --drain exits only after the fleet has been idle for this many CONSECUTIVE
# dispatch ticks (a tick is ~2s in production). The grace window is what makes
# dynamic `./fleet.sh add` safe near the end of a drain: a task added while the
# supervisor is still up is guaranteed to be claimed if it lands within it.
FLEET_DRAIN_GRACE_TICKS="3"

# Drain-mode approval watchdog: a standalone --drain exits (code 3) after tasks
# have sat waiting on human approval this many consecutive ticks (0 disables).
FLEET_DRAIN_HUMAN_TICKS="150"

# Command run once inside each fresh worktree BEFORE contract generation.
# Dependencies are usually gitignored, so a new worktree starts without them
# (e.g. "npm ci", "uv sync"). This is executed code: the supervisor prints the
# value and asks for one confirmation at start whenever it is non-empty
# (skipped and journaled under LOOP_AUTO=1 / --auto).
WORKTREE_SETUP_CMD=""

# ---- orchestration (single entry point: ./loop.sh run decomposes the approved
# ---- master contract into tasks; all knobs are iteration/count guards) ----

# 0 disables decomposition: ./loop.sh run always runs the classic single loop
# (a fleet worktree, and `run --single`, never decompose regardless).
FLEET_DECOMPOSE="1"

# Upper bound on tasks a decomposition may emit (guards a runaway task plan).
# Phased chains (one large piece of work split into sequential DEPENDS-chained
# tasks) consume slots too — raise this if plans legitimately need more phases.
FLEET_MAX_TASKS="12"

# Supervisor interventions (ANSWER/REPLAN) per escalated task before it goes to
# a human — each ANSWER restarts the task loop, so this bounds total restarts.
FLEET_MAX_SUPERVISE_PER_TASK="2"

# Replacement tasks the supervisor may enqueue per run via REPLAN (cumulative
# across every replan in the run — a runaway-replan guard, not a per-event
# size limit). A NEEDS_DECOMPOSITION split into N phases spends N of these, and
# a seeded fork-join needs a prep root (root -> {branches} -> join = 4): keep
# this comfortably above your largest expected split. Long phased workflows
# may need more.
FLEET_MAX_REPLAN_TASKS="6"

# Fix-up rounds after a failed integration gate (one task per round).
FLEET_MAX_INTEGRATION_FIXUPS="1"

# 0 disables mid-run supervision: escalated tasks fail straight to a human
# (orchestrated tasks default to supervised; manual tasks are never supervised).
FLEET_SUPERVISE="1"

# Carryover on NEEDS_DECOMPOSITION splits: seed the replacement chain's first
# phase with the escalated task's committed work (merge of its branch tip; a
# conflict skips the carryover and the work stays on the archived branch).
# 0 = replacements always start clean from the merged HEAD.
FLEET_SPLIT_CARRYOVER="1"

# Phase-boundary plan-review: after a task with queued dependents merges, a
# read-only supervisor call re-judges the QUEUED remainder of the plan against
# the merged reality (KEEP / REVISE unclaimed tasks / ESCALATE to the human).
# Dependents stay held until the review resolves. 0 disables (dependents
# dispatch as soon as their dependency merges, as before).
FLEET_PLAN_REVIEW="1"

# Drift-triggered plan-review: also fire the plan-review after ANY merged phase
# that recorded drift ("- Drift detected: yes" in its spec-drift-report) while
# queued PLANNED work remains — so an INDEPENDENT phase's drift can re-plan the
# remainder, not only a dependency merge. A contract-touching drift already
# escalates and never merges, so this marker is the rare "reality shifted, handled
# locally, proceeding" handoff. 0 = plan-review is dependency-triggered only.
# Requires FLEET_PLAN_REVIEW=1. Counts against FLEET_MAX_PLAN_REVISIONS only when
# it applies a REVISE (a KEEP costs a supervisor call but no revision budget).
FLEET_PLAN_REVIEW_ON_DRIFT="1"

# Plan revisions the plan-review may apply per run (REVISE verdicts beyond the
# cap are skipped deterministically — the approved plan continues). The cap is
# cumulative across ALL phase boundaries: a long chain (say 6 phases) crosses
# 5 boundaries — raise this for long phased workflows or the later boundaries
# can only KEEP/ESCALATE.
FLEET_MAX_PLAN_REVISIONS="4"

# Supervisor session continuity: supervisor calls (task decisions +
# plan-reviews) resume ONE conversational session (`claude -p --resume`) so
# repeat calls skip re-reading skills and unchanged docs. Files stay the single
# source of truth — the session is dropped on any call failure, unparseable
# verdict, supervisor restart, the call cap below, and after every applied
# plan mutation. 0 = every supervisor call starts a fresh session.
FLEET_SUPERVISOR_SESSION="1"

# Supervisor calls per session before a forced rotation (context-growth bound).
FLEET_SUPERVISOR_SESSION_MAX="20"

# Stall watchdog: orchestration finishes BLOCKED after this many consecutive
# ticks with no live workers and no phase change (0 disables).
FLEET_STALL_TICKS="30"
