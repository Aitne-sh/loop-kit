<!-- TEMPLATE -->
# Acceptance Checklist

<!--
Written ONCE by /loop-contract BEFORE approval — one row per fine-grained
observable behavior the user expects (including the implicit "of course it
must" must-be expectations: preservation invariants of a change task, the
domain/genre baseline of a 0->1 build). Maintained by /loop-iterate during the
run (statuses updated with evidence; NEWLY DISCOVERED unverified expectations
are APPENDED as new rows, never buried in prose). Audited by /loop-review at
the gate against the frozen contract. Summarized by /loop-evidence.

The external evaluator MACHINE-PARSES the AC rows: the success gate is refused
while any row's status is not `verified`. This file is how implicit
expectations stay CLOSABLE instead of silently waived — "the gate is green" is
never the same claim as "every expected behavior was observed to hold".

Row format (machine-parsed — keep the row on ONE line and never use the `|`
character inside a cell):

  | AC-001 | REQ-001 | <observable expected behavior, one line> | run | pending | - |

Columns:
- AC-NNN  — stable id; never renumber. A row that proves wrong or unachievable
            is a spec question (escalate via a decision request) — this file is
            not hash-frozen, so the HUMAN may edit rows; the loop may not
            delete or reword them. Ids the contract's Acceptance Criteria name
            as list items are ANCHORED: the evaluator requires a verified row
            per named id, so removing such an obligation requires a contract
            revision (re-approval), never a row deletion.
- REQ-xxx — the contract requirement this expectation belongs to.
- Expectation — one line, in the contract's language, stated as observable
            behavior ("particles visibly move across consecutive frames"),
            never as implementation ("positionNode is wired").
- Method (ASCII, exactly one of):
    cmd   — proven by a deterministic command (a VERIFY_COMMAND / test).
    run   — proven by RUNTIME OBSERVATION: run the artifact and observe the
            behavior (probe script, browser observation + screenshot). Reading
            the code is NEVER sufficient evidence for a `run` row. An
            observation scripted into the verify gate still classifies `run` —
            cite the probe's output (in .loop/last-verify.log) as the Evidence.
            A browser observation may ride the executing agent's own
            browser-automation skill/MCP connector (agent browser channel);
            if that capability is missing at runtime the loop STOPS with a
            decision request (enable it / verify manually / revise the
            contract) — it never silently reclassifies the row.
    human — only a human can judge it (final aesthetics). Use sparingly; the
            contract's "Human Approval Required If" must cover how the loop
            stops for it. Closure protocol: the loop stops (BLOCKED + a
            decision request naming exactly what to look at); the human looks,
            then runs `./loop.sh signoff` — it lists every pending human row,
            asks one confirm, marks them verified (the sign-off note lands in
            Evidence) and re-certifies. Editing the row to `verified` by hand
            (a note in Evidence is the sign-off) then `./loop.sh resume` is
            the manual equivalent. To request changes instead of signing off,
            `./loop.sh resume --note '<what to adjust>'` hands the findings
            to the next iteration.
- Status (ASCII, exactly one of): pending | verified | failed
    verified requires concrete evidence in the Evidence column; a regression
    flips a verified row back to pending/failed — hiding it only moves the
    discovery to the reviewer.
- Evidence — what proves it: the command and its result, a path under
            .loop/observations/ (screenshot, probe log), or `-` while pending.
            A verified `run` row must contain EXACTLY ONE literal
            `.loop/observations/` path — the canonical stamped artifact; the
            evaluator refuses a row citing two or more. Mention superseded or
            historical captures WITHOUT the `.loop/observations/` prefix
            (filename only), and never write brace patterns
            (`settings-{a,b}.png`) — always one full literal path.
            Observation paths are evaluator-stamped in
            .loop/observations-manifest.jsonl against this AC and the current
            product tree. A later product/AC change makes unchanged evidence
            stale; re-run and recapture it after the code stabilizes. Per-file
            and total size caps come from LOOP_OBS_MAX_FILE_KB / _TOTAL_MB.
            An archived task's manifest keeps these rows byte-identical
            (rewriting them would break the certificate hashes bound to them);
            resolve each .loop/observations/<file> to observations/<file>
            under that task's .loop/docs/run-archive/<id>/ root yourself,
            never against the live observation store.
-->

| AC | REQ | Expectation | Method | Status | Evidence |
|---|---|---|---|---|---|
