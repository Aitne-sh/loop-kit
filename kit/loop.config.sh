# loop.config.sh — machine-readable half of the product contract.
# Generated/updated by the /loop-contract skill; hashed together with
# .loop/docs/product-contract.md at `./loop.sh approve` time. Any later change
# stops the loop with NEEDS_SPEC_DECISION until re-approved.
# (Model choices live in loop.models.sh and can change without re-approval.)

# Deterministic verification gate: ALL commands must exit 0 for success.
# These are the loop's success condition — keep them honest and fast.
VERIFY_COMMANDS=(
  # "npm test"
  # "npm run lint"
)

# Rerun ALL verify commands once (or twice) when they fail, to absorb known
# environmental flakes (sqlite I/O, fd exhaustion, ...). 0 = off (default:
# every red is trusted as-is). A red-then-green rerun is journaled as
# VERIFY_FLAKE with the failing log preserved (.loop/verify-flake.log) — the
# retry records the flake, it never hides a persistent failure. Set to 1 only
# for suites with KNOWN environmental flakiness; fixing the flake beats
# retrying it.
VERIFY_RETRIES=0

# Contract-scoped observation evidence is retained across fresh retries, then
# evaluator-stamped against the current AC anchor and product tree. Bound its
# footprint so a screenshot/video/log cannot turn the hidden evidence store into
# unbounded disk growth. The harness supplies these defaults for older configs;
# changing the shipped values here is approval-gated with the rest of this file.
LOOP_OBS_MAX_FILE_KB=2048
LOOP_OBS_MAX_TOTAL_MB=50

# 3-tier diff policy (space-separated globs; '**' allowed):
# touched denied path      -> RISK_REQUIRES_APPROVAL (human approval before anything else)
DENIED_PATHS=".env* secrets/** credentials/**"
# touched escalate path    -> NEEDS_ARCHITECTURE_DECISION (dependencies, schema, infra)
ESCALATE_PATHS=""
# (always protected regardless of this file: the contract + this file via the
#  approval hash; loop.sh / loop.models.sh / .claude/** via the harness policy)

# Anti-runaway budgets (per run). The primary guards are the iteration cap and
# the per-call wall-clock watchdog — both subscription-compatible.
MAX_ITERATIONS=10          # hard cap on loop iterations
MAX_ITER_SECONDS=900       # default wall-clock watchdog per agent call
                           # (per-role TIMEOUT_<ROLE> below overrides it)
# MAX_RUN_SECONDS=         # optional total wall-clock cap per process (empty/absent
                           # = no cap; a resume gets a fresh window)

# Per-role watchdog overrides: TIMEOUT_<ROLE> beats MAX_ITER_SECONDS for that
# role only (seconds; positive integer). Empty / removed / non-numeric = inherit
# MAX_ITER_SECONDS — a typo here can never widen or break a running loop.
# These live HERE (not loop.models.sh) on purpose: the watchdog is an anti-runaway
# SAFETY budget, so raising it is gated by re-approval (this file is hashed).
# Roles: IMPLEMENT REVIEW PLAN CONTRACT EVIDENCE STOP_EVAL DECOMPOSE SUPERVISE.
# The heavy lever is IMPLEMENT: a genuinely large, tool-heavy iteration (big
# refactor, slow builds/tests run as tool calls) can legitimately outlast the
# default. If iterations are being watchdog-killed while still making progress,
# raise TIMEOUT_IMPLEMENT rather than the global — the clerical roles keep the
# tighter default. (A recurring kill often also means the per-iteration scope is
# too large: see TURNS_NUDGE_AT in loop.models.sh, or decompose into fleet tasks.)
#TIMEOUT_IMPLEMENT=1800    # 30 min; bump to 2400+ for consistently heavy iterations
#TIMEOUT_REVIEW=           # whole-run gate reviews of a large diff can be slow too
#TIMEOUT_PLAN=
#TIMEOUT_CONTRACT=
#TIMEOUT_EVIDENCE=
#TIMEOUT_STOP_EVAL=
#TIMEOUT_DECOMPOSE=
#TIMEOUT_SUPERVISE=

# Total USD cap across all agent calls in one run. EMPTY = no cap (the default):
# Claude Code subscription (Pro/Max) usage has no per-token charge and the
# reported USD is notional — a cap here would stop healthy loops early.
# Set a number ONLY when the user explicitly asks for a hard cost cap
# (e.g. API-billed usage). When set, it is enforced from loop.sh's in-memory
# total and mirrored to each call via --max-budget-usd.
MAX_COST_USD=""

# Stop heuristics
STAGNATION_N=2             # consecutive no-diff iterations -> STALLED
REPEAT_FAIL_N=3            # identical verify failure N times -> BLOCKED. Also
                           # derives the oscillation window: failures cycling
                           # between <=2 distinct states over the last 2xN
                           # failing iterations -> BLOCKED (catches the
                           # A->B->A->B ping-pong the identical rule misses;
                           # off when N=1 — that already blocks on any repeat)
FUTILE_N=2                 # consecutive FUTILE stop-eval verdicts -> STALLED
MET_FORCE_N=2              # consecutive MET stop-eval verdicts + verify green ->
                           # force the success gate even without READY_FOR_REVIEW
                           # (gate review + evidence + final re-check still decide;
                           #  a forced-gate rejection does not count toward
                           #  MAX_REVISIONS). 0 = never force.

# Review process (implementation is reviewed and improved every iteration)
REVIEW_MODE="always"       # always | candidate (only at success gate) | off
HOLISTIC_EVERY_N=3         # every Nth interim review widens its diff to the WHOLE
                           # run (erosion/coherence audit: duplicated logic, dead
                           # code, contradictory approaches across iterations).
                           # 0 = never widen on a schedule.
HOLISTIC_TRIGGER_LINES=400 # additionally widen when a single iteration changes
                           # at least this many lines (big diffs shift global
                           # coherence the most). 0 = no size trigger.
MAX_REVISIONS=3            # consecutive reviewer rejections -> BLOCKED (human review).
                           # Counted per review type: success-gate rejections and
                           # interim (per-iteration) rejections have separate counters,
                           # so interim churn never consumes the gate budget.
GATE_RETRY_N=2             # when the GATE reviewer call itself fails (outage, not
                           # a verdict), retry up to N times with backoff before the
                           # fail-closed BLOCKED. 0 = block immediately (old behavior).
GATE_RETRY_WAITS="60 300"  # seconds before retry 1, 2, ... (last entry repeats)
STOP_EVAL="true"           # lightweight advisory stop evaluator each iteration
SPLIT_NUDGE_AT=70          # fleet workers only: past this % of MAX_ITERATIONS with
                           # unmet ledger REQs, the harness nudges the agent to
                           # either declare NEEDS_DECOMPOSITION at a clean commit
                           # boundary (the supervisor splits the remainder into
                           # phased tasks) or justify continuing. 0 = off.

# Agent execution — the worker runs in a deny-enforcing permission mode with a BROAD
# tool allow-list; the deny-list (DISALLOWED_TOOLS) is the primary control you tune, and
# it wins over the allow-list. Containment otherwise comes from the checker layer
# (deterministic evaluator, independent reviewer, approval-hash, and the
# DENIED_PATHS/ESCALATE_PATHS diff policy), not from clipping the agent's tools.
#   acceptEdits (default): edits + reads auto-approved; ALLOWED_TOOLS grants the rest;
#     DISALLOWED_TOOLS is ENFORCED (deny wins). The deny-list only works in this kind of
#     mode — keep it unless you have a specific reason not to.
#   bypassPermissions: literally every tool runs, INCLUDING all MCP servers — but it
#     skips the whole permission system, so DISALLOWED_TOOLS is IGNORED. Use only if you
#     want zero tool restrictions and do not rely on the deny-list.
PERMISSION_MODE="acceptEdits"

# Tool allow-list — broad by default ("basically everything", network included). The
# worker may use any tool listed here. It is explicit because acceptEdits enforces the
# deny-list, and a deny-enforcing mode cannot wildcard-grant tools. MCP servers are NOT
# wildcard-grantable — add a server by id to use it in the loop, e.g.
# ALLOWED_TOOLS="Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,mcp__github".
# (claude-in-chrome needs an interactive session and won't attach to a headless loop.)
ALLOWED_TOOLS="Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit"

# Tool deny-list — the PRIMARY tool-level control. Comma-separated Claude Code tool
# rules; deny wins over the allow-list. Empty = deny nothing. Changing it re-triggers
# approval (it's in the contract hash). Examples:
#   DISALLOWED_TOOLS="WebSearch,WebFetch"              # no web access
#   DISALLOWED_TOOLS="Bash(sudo *),Bash(git push *)"   # no privilege-escalation / no push
#   DISALLOWED_TOOLS="Bash(rm -rf *)"                  # no recursive-force rm
# Bash rules are prefix-globs matched per sub-command across the &&, ||, |, ; separators.
# NB: enforced only under a deny-enforcing PERMISSION_MODE (acceptEdits); IGNORED under
# bypassPermissions.
DISALLOWED_TOOLS=""
