<!-- TEMPLATE -->
# Requirements Ledger

<!--
The loop's cross-iteration memory of REQUIREMENT SATISFACTION (the plan tracks
work; this tracks outcomes). Bootstrapped deterministically by the harness from
the contract's REQ ids; updated honestly by the agent every iteration; verified
by the independent reviewer on every review and REQ-by-REQ at the success gate.

Row format is MACHINE-PARSED (evaluate.sh greps `| REQ-xxx | met |`): keep the
table cells exactly `| <REQ-id> | <status> | <evidence> | <iter> |`, one row per
REQ id, ASCII status tokens only:

  unstarted   — no work aimed at this REQ yet
  in-progress — partially implemented; evidence says what exists so far
  met         — implemented AND verifiable (name the file/test/behavior proving it)
  at-risk     — previously in-progress/met but something now casts doubt
  regressed   — previously met, now broken (say what broke it)

Rules:
- A status may only move to `met` with concrete evidence (file, test, observable
  behavior) in the Evidence column — never on intention.
- Never delete a row; the harness re-adds missing REQ ids.
- READY_FOR_REVIEW requires every row `met` — the evaluator refuses the success
  gate otherwise.
-->

## Requirements

| REQ | Status | Evidence | Iter |
|---|---|---|---|
