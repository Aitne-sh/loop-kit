<!-- TEMPLATE -->
# Product Contract

<!--
FIXED once approved (loop.sh approve). The loop stops with NEEDS_SPEC_DECISION
if this file changes. The agent may NOT edit it — if implementation reveals the
contract must change, the agent stops and files a decision request instead.
Granularity rule: implementation steps stay flexible; success conditions stay explicit.
-->

## Goal

<!-- One paragraph: what outcome this loop must achieve. -->

## Requirements

<!-- Verifiable, numbered. Example:
### REQ-001: <name>
<observable behavior>
-->

## Non-goals

<!-- What this loop must NOT build, even if tempting. -->

## Constraints

<!-- e.g. do not change auth boundaries; keep existing lint/typecheck/test/build green;
     stdlib only; no secrets stored. -->

## Quality baseline

<!-- Standing quality bars the loop must keep true while it works (existing
     lint/typecheck/tests/build stay green; no new warnings; no dead code left
     behind). Violations are reviewable defects even when VERIFY_COMMANDS pass. -->

## Acceptance Criteria

<!-- Checkable statements. The deterministic gate is VERIFY_COMMANDS in loop.config.sh;
     list here what those commands prove, plus anything the evidence report must show.
     State per criterion HOW it is verified — cmd (deterministic command),
     run (runtime observation: run the artifact and observe), or human — and
     mirror each as a row in .loop/docs/acceptance-checklist.md: the evaluator
     refuses the success gate while any row there is not `verified`. A
     criterion that is observable only at runtime must not be classified cmd. -->

## Validation Commands

<!-- Human-readable mirror of VERIFY_COMMANDS in loop.config.sh (keep in sync).
     Classify each command: red→green (expected to FAIL at baseline — passing
     proves the new behavior) or stays-green (regression guard). Feature work
     needs at least one red→green command. -->

## Human Approval Required If

<!-- Conditions that must stop the loop for a human decision. Example:
- DB schema changes
- new major dependency
- auth/permission changes
- anything touching DENIED_PATHS
-->
