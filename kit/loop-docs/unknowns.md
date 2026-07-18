<!-- TEMPLATE -->
# Unknowns Record

<!--
Written ONCE by /loop-contract during intake (interactive or auto), then read
by /loop-contract-review, /loop-plan and /loop-evidence. INFORMATIVE, not
normative: the binding mid-run escalation bar is the contract's
"Human Approval Required If" section (hash-frozen at approval); this file
records how the intake unknowns were found and resolved so every
fresh-context session starts from the same place the human did.
Unknowns that surface DURING the run belong in .loop/docs/assumptions.md
(the AS-N ledger), not here.
Fleet sub-tasks: when .loop/master-contract.md exists, leave this as the
template — the master run's record is authoritative.
-->

## Territory map (blindspot survey)

<!-- What the instruction actually touches: modules, invariants, conventions,
     risky areas — one line per finding from exploration. -->

## Things the user didn't know to ask

<!-- Unknown unknowns surfaced by the survey: each with a concrete failure
     mode if ignored, and how it was handled (asked / assumed / made a
     Non-goal / covered by a REQ). -->

## Must-be baseline (implicit expectations)

<!-- The expectation-decomposition pass: expectations the user would never
     state because they are "obvious" (Kano must-be quality). For a
     change/migration task: the observable behaviors in the blast radius that
     work TODAY and must still work after (preservation invariants). For a
     0->1 build: the domain/genre baseline (a "Mario-like game" implies
     controls, stomp-kills, pit/contact death, lives/game-over). One line per
     expectation + where it landed (AC-NNN in acceptance-checklist.md / REQ /
     Non-goal / deferred). Include the premortem: the 3 most plausible reasons
     the user would be disappointed even with every gate green. -->

## Interview decision log (known unknowns)

<!-- One entry per question actually asked, ordered by blast radius
     (data model > interfaces > user-visible behavior > style).
     The mandatory acceptance-gate question (the VERIFY_COMMANDS proposal and
     the user's verdict on it) is logged here like any other Q-N.
## Q-N: <question> — why it mattered
- Answer:
- Folded into: REQ-xxx / Non-goal / Acceptance Criterion / config key
-->

## Direction verdicts (unknown knowns)

<!-- Only when Direction pages were shown: the chosen direction + WHY,
     and each rejected direction with one line. "None shown" otherwise. -->

## Feasibility probes

<!-- Time-boxed spikes run under .loop/spike/ (removed afterwards): what was
     probed, the observed result, what it changed in the contract. An
     acceptance row bound to the executing agent's own browser skill/MCP
     connector (agent browser channel) is recorded here WITHOUT a spike:
     "AC-NNN: unproven — agent-environment dependent; the loop stops with a
     decision request if the capability is missing at runtime". "None". -->

## Deferred with defaults

<!-- Questions deliberately NOT asked: the conservative default adopted and
     what would make it wrong. In auto mode these mirror the contract's
     "## Assumptions (auto mode)" section. -->
