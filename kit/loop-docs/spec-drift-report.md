<!-- TEMPLATE -->
# Spec Drift Report

<!-- Updated by the agent every iteration. Deterministic drift (contract/denied/escalate
     paths) is enforced by evaluate.sh regardless of what this says; this report covers
     the semantic checks only the implementer can see. -->

## Summary

<!-- "Drift detected: yes" + "Human decision required: no" = reality diverged but was
     handled locally (no contract change). In a fleet run the supervisor keys on this pair
     to re-examine the queued remainder of the plan. "Human decision required: yes" means
     you escalated (and stopped) — it never reaches a merge. Keep both lines exact (ASCII,
     lower-case yes/no); they are machine-read. -->
- Drift detected: no
- Human decision required: no

## Checks

| Check | Result | Evidence |
|---|---|---|
| Product requirement changed? | no | |
| API behavior changed? | no | |
| Data model changed? | no | |
| UX behavior changed? | no | |
| Security boundary changed? | no | |
| Non-goal violated? | no | |
| New dependency added? | no | |
| Unknown risk? | no | |

## Required Human Decisions

- None
