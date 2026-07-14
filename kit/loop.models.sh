# loop.models.sh — model roles for every in-loop process.
# Edit freely (no re-approval needed); parsed as plain key=value, never executed.
# Format: KEY="model-alias"  (opus / sonnet / haiku, or a full model name)
#
# Defaults: heavyweight model for the important work (implementation, review,
# planning, contract), lightweight model for stop evaluation.

MODEL_CONTRACT="opus"     # contract definition session (explore + questions + loop definition)
MODEL_PLAN="opus"         # implementation planning (iteration 0)
MODEL_IMPLEMENT="opus"    # implementation & improvement (every iteration)
MODEL_REVIEW="opus"       # gate/decompose/contract reviews (independent checker, certification)
MODEL_EVIDENCE="sonnet"   # evidence report generation
MODEL_STOP_EVAL="haiku"   # advisory stop evaluation (cheap, runs every iteration)
MODEL_DECOMPOSE="opus"    # supervisor: master contract -> task plan (fleet orchestration)
MODEL_SUPERVISE="opus"    # supervisor: mid-run decisions on escalated fleet tasks

# Interim reviews only (the steering feedback after every CONTINUE iteration —
# the highest-frequency review call). Empty or removed = inherit MODEL_REVIEW.
# The success-gate, decompose and contract reviews always use MODEL_REVIEW:
# this knob never weakens a certification check. A cheaper tier here saves the
# bulk of review cost AND adds cross-tier diversity on the interim path.
# Note: holistic (whole-run) interim audits also ride this tier — the gate
# re-runs the same audit on MODEL_REVIEW, so anything missed surfaces there
# (as later, pricier gate REVISEs, never as certified code). If erosion
# findings keep arriving only at your gates, set this back to opus.
MODEL_REVIEW_INTERIM="sonnet"

# Note: implement and gate review default to the SAME model. The maker-checker
# separation is procedural (fresh context, read-only process) — not statistical:
# a blind spot shared by one model can pass both roles. For diversity against
# that, point MODEL_REVIEW at a different model family/tier (the interim tier
# above already differs by default). The deterministic VERIFY_COMMANDS gate is
# unaffected either way.

# Reasoning effort for every in-loop `claude` call (passed as `claude --effort`).
# One of: low | medium | high | xhigh | max. Applies to all roles above
# (implement, review, plan, contract, evidence, stop-eval, decompose, supervise)
# and to the interactive contract sessions. Higher = more thinking per call.
#
# Requires a Claude Code CLI that supports --effort (>= ~2.1) and a model that
# honors effort levels (Opus 4.8 etc.); models that don't just ignore it.
# Blank or remove this line to pass no flag and fall back to the CLI's own
# default effort. An unrecognized value is dropped (no flag) rather than sent.
LOOP_EFFORT="xhigh"

# Per-role effort overrides: EFFORT_<ROLE> beats LOOP_EFFORT for that role only.
# Same accepted values as LOOP_EFFORT; empty/removed/unrecognized = inherit
# LOOP_EFFORT (a typo here can never break a running loop — it falls back).
# Clerical roles ship cheaper; the quality-bearing roles stay on the global.
EFFORT_STOP_EVAL="low"    # advisory MET/FUTILE/CONTINUE call — clerical
EFFORT_EVIDENCE="medium"  # report authoring — summarization, not judgment
#EFFORT_IMPLEMENT=""      # the big cost lever — measure quality before lowering
#EFFORT_REVIEW=""         # interim + gate reviews
#EFFORT_PLAN=""
#EFFORT_CONTRACT=""
#EFFORT_DECOMPOSE=""
#EFFORT_SUPERVISE=""

# Runaway-context signal: when one implement call consumes >= this many agent
# turns, the next iteration gets an advisory nudge (.loop/context-nudge.md) to
# re-plan/split instead of resuming mid-flight — long-tail iterations are where
# cache-read cost explodes. Digits only; empty or removed = off (no nudge).
# 70 ~ p90 of healthy production iterations (median ~42, observed outlier 75):
# it fires on true runaways, not on ordinary thorough iterations. If the
# CONTEXT_NUDGE journal row fires on more than ~1 in 4 iterations, the
# threshold is set too low for this project — raise it.
TURNS_NUDGE_AT="70"
