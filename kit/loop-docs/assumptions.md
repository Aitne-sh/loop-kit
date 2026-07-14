<!-- TEMPLATE -->
# Assumption & Discovery Ledger

<!--
The CONTROLLED channel for mid-implementation discoveries that do NOT require
changing the contract: under-specified behavior, design gaps found while
implementing, unknowns the plan did not anticipate. Instead of stopping the
loop (that is for contract-changing discoveries -> NEEDS_SPEC_DECISION) or
burying the finding in progress.md, the agent records the gap here, picks the
conservative default, and KEEPS GOING.

Every open entry is adjudicated by the independent reviewer at the success
gate: SOUND (consistent with the contract's intent), UNSOUND (must-fix), or
escalated to the human (the gate reviewer's VERDICT: ESCALATE). The evidence
report shows this ledger to the human — an assumption recorded here is never
silently lost.

Append-only; number entries AS-1, AS-2, ... Status tokens (ASCII, machine-read
by reviewers): open | sound | unsound | escalated
-->

<!-- Entry format:
## AS-N: <one-line title> — iteration N, <date>
- Discovered gap: <what the contract/plan under-specifies, or what unknown surfaced>
- Chosen default: <the conservative choice made, and why it is conservative>
- Alternatives: <other options considered>
- Reversibility: <how hard this is to change later>
- Affected REQs: <REQ-xxx ids, or "none">
- Status: open
-->
