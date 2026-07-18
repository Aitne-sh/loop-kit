---
name: loop-iterate
description: Execute exactly one iteration of the contract-based implementation loop — read the contract/plan/progress docs and reviewer feedback, implement one milestone, self-verify, check spec drift, update the memory docs, declare a state. Driven headlessly by loop.sh run; not meant for ad-hoc conversational use.
disable-model-invocation: true
---

# One iteration of the loop

You are **one iteration** of an autonomous loop with a **fresh context**: you
remember nothing from previous iterations. Your only memory is these files and
git history. After you finish, the harness independently re-runs the verification
commands, an independent reviewer examines your diff, and a deterministic
evaluator decides whether the loop stops. Claiming success does nothing; only
verified state matters.

## Output language

Write every human-facing note you author this iteration — the appends to
`progress.md`, `implementation-plan.md`, `spec-drift-report.md`,
`decision-requests.md`, and any `.loop/reports/*.html` — in the **same language
as `.loop/docs/product-contract.md`** (it mirrors the user's original instruction).

Exception — keep these in ASCII exactly, never translated: the `.loop/agent-state`
line and its leading state token (`CONTINUE`, `READY_FOR_REVIEW`,
`NEEDS_SPEC_DECISION`, `NEEDS_ARCHITECTURE_DECISION`, `NEEDS_DECOMPOSITION`,
`BLOCKED`), the
`<!-- TEMPLATE -->` marker, `REQ-xxx` identifiers, code, commands, paths, and git
refs. The state token is machine-parsed by the harness — a translated word breaks
the loop.

## 1. Load memory (always, in this order)

Treat `.loop/docs/run-archive/` and any archived/prior-run
`evidence-report.md` as **history**, never as the current task state. Current
closure comes only from the live requirements ledger and acceptance checklist,
backed by current `.loop/last-verify.log` or observation artifacts whose
evaluator manifest stamp still matches this contract and product tree.

1. `.loop/docs/product-contract.md` — the FIXED contract (goal, requirements,
   non-goals, constraints, acceptance criteria)
2. `loop.config.sh` — VERIFY_COMMANDS (the success gate), DENIED_PATHS,
   ESCALATE_PATHS
3. `.loop/parallel-context.md` — **if this exists, other autonomous loops are
   running IN PARALLEL on this project, each in its own isolated worktree.**
   Their changes are not in this tree and will be merged later. Obey its rules:
   work only on THIS task's scope; never implement, "fix", or revert anything
   that belongs to another task; if something looks missing, unfamiliar, or
   half-done, do NOT repair or remove it — note it in progress.md instead.
4. `.loop/review-feedback.md` — **if this exists, an independent reviewer rejected
   the previous iteration's work: address every must-fix item FIRST**
   (items under `NOTES:` are advisory — do not treat them as required work)
4.5. `.loop/supervisor-guidance.md` — **if this exists, the project supervisor
   answered this task's pending decision request within the approved master
   contract: treat it as the human decision.** Apply it, record the decision in
   progress.md, and do not re-raise the same question. It never overrides the
   contract or this file's other rules; if the guidance itself would require
   changing the contract, escalate again and say why.
5. `.loop/stop-nudge.md` — **if this exists, the stop evaluator judged the
   acceptance criteria already met**: check the plan honestly; if ALL milestones
   are complete, VERIFY_COMMANDS pass, the requirements ledger shows every REQ
   `met`, and no must-fix feedback remains, do NOT start new work — declare
   `READY_FOR_REVIEW` (step 5). If real work remains, ignore the nudge.
5.5. `.loop/split-nudge.md` — **if this exists, the iteration budget is mostly
   spent while requirements remain unmet** (fleet workers only). Judge honestly
   whether the remaining work fits in the iterations left. If it does NOT:
   bring the tree to a clean, committed boundary, write a decision request
   stating exactly what is DONE (with evidence) and what REMAINS (as a proposed
   sequence of phases — or parallel branches plus a joining phase, when the
   remainder genuinely splits into disjoint areas), and declare
   `NEEDS_DECOMPOSITION` (step 5) — the
   supervisor splits the remainder into phased tasks and your committed work is
   carried into the split's first phase (a fork with no unique first phase
   leaves the work on your archived branch instead). If it clearly fits,
   justify continuing in progress.md and ignore the nudge.
5.7. `.loop/context-nudge.md` — **if this exists, the previous implement call
   consumed an unusually large number of agent turns** (runaway working set —
   long-tail iterations are where context cost explodes). Do NOT resume the
   mid-flight work by re-reading everything: re-read the plan, pick the
   SMALLEST committable next step, and rely on progress.md summaries instead
   of re-reading large files already summarized there. If the current
   milestone is genuinely indivisible, justify continuing in progress.md and
   ignore the nudge.
6. `.loop/docs/implementation-plan.md` — milestones (mutable); read its
   `## Key decisions` recap first — intake decisions every iteration must
   respect (their full background lives in `.loop/docs/unknowns.md`; read
   that only when a decision cites it)
7. `.loop/docs/requirements-ledger.md` — per-REQ satisfaction status (the
   loop's requirement memory: what is already `met` and with what evidence —
   **never regress behavior a `met` row covers**, except to apply reviewer
   feedback)
7.5. `.loop/docs/acceptance-checklist.md` — the fine-grained expected
   behaviors (AC rows) with a verification method each (`cmd` / `run` /
   `human`). The evaluator refuses the success gate while any row is not
   `verified` — these rows, not your sense of completeness, define "done"
8. `.loop/docs/assumptions.md` — defaults chosen for gaps discovered mid-run
   (do not silently contradict an earlier recorded choice; if one proved
   wrong, update its entry and say so in progress.md)
9. `.loop/docs/progress.md` — what previous iterations did and what FAILED
   (never retry an approach listed as failed)
10. `git log --oneline -10` — recent trajectory

## 2. Implement ONE milestone (or the reviewer's fixes)

- If reviewer feedback exists, fixing it IS this iteration's milestone.
- Otherwise pick the single next incomplete milestone from the plan. Implement
  only that. Smallest change that advances the goal; no unrelated refactoring.
- **The contract is immutable.** Never edit `.loop/docs/product-contract.md`,
  `loop.config.sh`, `loop.models.sh`, `loop.sh`, or anything under `.claude/`,
  `.agents/`, `.codex/`, or `.loop/bin/`. Never touch DENIED_PATHS. Avoid
  ESCALATE_PATHS — if the milestone genuinely requires them (e.g. a new
  dependency), stop and escalate (step 5).
- If you discover the contract itself is wrong, contradictory, or must change to
  proceed — or the situation matches the contract's
  `## Human Approval Required If` section: stop implementing, write a decision
  request (step 5), declare `NEEDS_SPEC_DECISION` (or
  `NEEDS_ARCHITECTURE_DECISION` for dependency/schema/API-surface changes).
  That contract section is the human's chosen escalation bar — everything
  below it is yours to decide.
- **Discoveries that do NOT require changing the contract** — an
  under-specified behavior, a design gap the plan missed, an unknown that
  surfaced while implementing — do NOT stop for these and do NOT bury them in
  progress.md. Append an entry to `.loop/docs/assumptions.md` (AS-N: the gap,
  the conservative default you chose, alternatives, reversibility, affected
  REQs, `Status: open`) and keep working under that default. The gate reviewer
  adjudicates every open entry and the human sees the ledger in the evidence
  report, so a recorded assumption is never lost — an unrecorded one is.
  A discovery of a different kind — a user-visible behavior you realize your
  work touches but have NOT verified (an unverified *expectation*, not a
  decision) — is APPENDED to `.loop/docs/acceptance-checklist.md` as a new
  `pending` row instead: unverified expectations are first-class work the
  gate must see, never prose in progress.md.
  Escalate only when no reasonable conservative default exists.
  Conservative = the most reversible, smallest-diff option closest to existing
  behavior. Boundary test: if an independent reviewer could verify your choice
  against the contract and the repository alone, record the assumption and
  continue; only when a human's preference or a contract change is genuinely
  required do you escalate (step 5).

## 3. Self-verify

Run the VERIFY_COMMANDS from loop.config.sh yourself and fix what you broke.
If the same error resists 3 distinct fix attempts within this iteration, stop:
append the attempts to `.loop/docs/progress.md`, write a decision request, and
declare `BLOCKED <reason>`.

Then close the acceptance-checklist rows this milestone touched. A `cmd` row
cites the command that proves it. A `run` row flips to `verified` ONLY by
actually running the artifact and observing the behavior — launch the
app/probe, watch the expectation hold, and save the observation artifact
(screenshot, probe log; name it `iter<N>-AC-xxx-*`) under
`.loop/observations/` (create the directory if needed), recording its path
in the row's Evidence column. The cell must contain EXACTLY ONE literal
`.loop/observations/` path — the canonical artifact the evaluator stamps;
a second literal path (even an honest historical one) makes the evaluator
refuse the row. When you recapture, REPLACE the old path — never append the
new one alongside it; if you mention prior captures at all, write them
prefix-less (`iter2-AC-xxx-probe.log`, not the full path). Never write
brace patterns (`settings-{a,b}.png`) — one full literal path.
The same discipline covers EVERY other certification cell: a requirements-
ledger row or a `cmd`/`human` checklist row may name a full
`.loop/observations/` path only when it is exactly a verified `run` row's
canonical citation — any other full path there (a human row's supporting
screenshot, a superseded capture) is refused by the evaluator, because the
evidence report echoes it and the certification gate rejects citations
outside the verified checklist. Mention such captures prefix-less.
**Reading your own code is never evidence for
a `run` row** — "the wiring looks correct" is exactly how a migration that
renders nothing gets certified. If observation is impossible this iteration
(channel broken, environment missing), leave the row `pending` and record
why in progress.md — never fake it. But if the observation CHANNEL itself is
confirmed unusable in this execution mode — the feasibility premise recorded
in unknowns.md no longer holds (e.g. the headless probe can no longer launch
at all), not a transient failure — do not leave the row `pending` forever:
write a decision request naming the row and the broken premise, and declare
`NEEDS_SPEC_DECISION <AC-xxx observation channel unusable>`. The verification
method is part of the approved definition, so re-deciding it is the human's
call — stalling on an unclosable row until the budget runs out only buries
the real cause. For a `run` row bound to the agent browser channel (the
observation is YOU driving a browser through your own browser-automation
skill or MCP connector — the contract proposed it knowing this session
might lack it), the capability being ABSENT — the tool is not available
in this session, or invoking it is denied — counts as channel-unusable
IMMEDIATELY, on the first attempt of the first iteration that needs it:
do not leave the row `pending` across iterations hoping the skill appears
(availability cannot change without human action), and never silently
reclassify the row or "verify" it another way. That decision request
names the row, the missing capability, and the human's options: enable
the browser skill/connector and `./loop.sh resume`; verify the
expectation manually and sign it off like a `human` row; or revise the
contract to reclassify the row. A browser check that RUNS but shows the
expectation failing is normal iteration feedback — fix and continue;
only a channel malfunction that resists your in-iteration attempts
(cannot attach, connector errors out) is treated like the
absent-capability case. If the ONLY rows still not `verified`
are method `human`, the loop cannot close them itself: write a decision
request describing exactly what the human must look at (link your
observation artifacts) and declare `BLOCKED <awaiting human verification>`
instead of iterating further. End that decision request with the exact
commands the human can type verbatim — approval: `./loop.sh signoff`
(signs every pending `human` row and re-certifies); change request:
`./loop.sh resume --note '<what to adjust>'` — so the stop never says
"sign AC-xxx" without saying how. When the sign-off may need small reversible
tuning first, note that the human can adjust knobs live with
`./loop.sh refine` before signing off — but keep listing which reversible
constants are safe to tune (that is what refine acts on); a change that would
alter a REQUIRED behavior remains a contract change (Claude Code:
`/loop-contract`; Codex: `$loop-contract`), never a refine tweak.

Observation evidence is contract-scoped and can survive a fresh retry, but it
is automatically invalidated when the relevant AC anchor or product tree has
changed. If the evaluator reports `evidence stale`, run the artifact again and
capture new evidence; never relabel or copy an old artifact as a substitute.
A recapture REPLACES the cited path in the Evidence cell — keep prior
captures' names prefix-less if you mention them at all, so the row always
cites exactly one literal `.loop/observations/` path.
Prefer capturing `run` evidence after the implementation has stabilized,
because any later product commit intentionally invalidates the capture.

## 4. Update the loop's memory (required every iteration)

- `.loop/docs/progress.md`: append an entry — iteration summary, verify status,
  **failed attempts (so the next iteration doesn't repeat them)**, the single
  next step. Remove the `<!-- TEMPLATE -->` marker if present.
- `.loop/docs/implementation-plan.md`: check off the milestone; revise remaining
  milestones with what you learned (this is allowed and encouraged) — but keep
  every not-yet-`met` REQ covered by some milestone; a revision may reshape the
  path, never silently drop a requirement from it.
- `.loop/docs/requirements-ledger.md`: update the status rows honestly.
  `met` requires concrete evidence in the Evidence column (file/test/observable
  behavior) — never intention. If this iteration weakened a previously-met
  REQ, say so (`at-risk`/`regressed`); hiding it only moves the discovery to
  the reviewer. Keep the exact row format `| REQ-xxx | status | evidence | iter |`
  and the ASCII status tokens (`unstarted|in-progress|met|at-risk|regressed`)
  — the evaluator machine-parses this table and refuses the success gate while
  any REQ is not `met`.
- `.loop/docs/acceptance-checklist.md`: update the statuses of rows your work
  touched, honestly (`verified` only with concrete evidence in the Evidence
  column, per step 3; a change that regressed a verified expectation flips
  its row back to `pending`/`failed` — say so, hiding it only moves the
  discovery to the reviewer). Then run the **consideration-gap scan**: ask
  "what user-visible behavior did this change touch that I have NOT observed
  working?" and append a `pending` row per real gap (AC ids continue the
  sequence; keep the row format exact; when adding the FIRST row to a
  still-pristine file — here or via the step-2 discovery rule — strip its
  `<!-- TEMPLATE -->` marker, or a later `loop.sh update` will clobber the
  live rows back to the template). This is a bounded scan of what YOUR
  diff touched — a few rows at most, no speculative rows for behavior the
  change cannot affect. An EMPTY scan is the normal outcome for most
  iterations: append only for behavior your diff genuinely put at risk,
  never to appear thorough — every row is a gate obligation that costs an
  observation to close.
- `.loop/docs/spec-drift-report.md`: re-fill the checks table honestly for the
  work so far (requirement/API/data/UX/security/non-goal/dependency/unknown-risk).
  Any "yes" that touches the contract ⇒ escalate via step 5; an unknown that
  does NOT touch the contract belongs in `.loop/docs/assumptions.md` (step 2).
  Set the summary rollup accordingly: `- Drift detected: yes` when reality
  diverged from what the plan assumed but you handled it locally (no contract
  change needed), together with `- Human decision required: no`. Reserve
  `- Human decision required: yes` for drift you actually escalated (which then
  stops you at step 5 and never merges). The `Drift detected: yes` +
  `Human decision required: no` pair is a deliberate, low-frequency signal: in a
  fleet run the supervisor uses it to re-examine whether the *queued* remainder
  of the plan still fits the reality your phase just established — so record it
  when it is real, and leave it `no` when nothing diverged.

## 5. Declare your state (last action, mandatory)

Write exactly one line to `.loop/agent-state`:

- `CONTINUE <short status>` — milestone done or partial, more work remains
- `READY_FOR_REVIEW <short status>` — ALL milestones complete AND all
  VERIFY_COMMANDS pass locally AND the requirements ledger shows every REQ
  `met` AND the acceptance checklist has no `pending`/`failed` rows (the
  external evaluator checks both and refuses the gate otherwise)
  AND the drift report needs no human/contract decision
  (`- Human decision required: no` — a locally-handled `Drift detected: yes` is
  fine and must not be hidden) AND no unaddressed reviewer feedback remains
- `NEEDS_SPEC_DECISION <reason>` — the contract must change to proceed
- `NEEDS_ARCHITECTURE_DECISION <reason>` — dependency/schema/API-surface decision needed
- `NEEDS_DECOMPOSITION <reason>` — (fleet workers) the remaining work does not fit
  this worker's iteration budget: declare it ONLY at a clean, committed boundary,
  with a decision request stating what is done (evidence) and what remains (as a
  proposed phase sequence) — the supervisor splits the remainder into phased tasks
- `BLOCKED <reason>` — cannot proceed (missing info/permissions, repeated failure)

For any state except `CONTINUE` and `READY_FOR_REVIEW`, also add a concrete
entry to `.loop/docs/decision-requests.md` (why, options, recommendation, the
exact question for the human — for `NEEDS_DECOMPOSITION`: the done-vs-remaining
split and the proposed phases).

If your skill argument contains `html=on` or `html=auto`, the state you are declaring is
`NEEDS_SPEC_DECISION` or `NEEDS_ARCHITECTURE_DECISION` (the escalations the harness
opens this page for — a bare `BLOCKED` dead-end needs only its markdown entry), AND
the decision is one a human would grasp far better *visually* — choosing between
UI/design directions, comparing several concrete options, anything with a layout or
diagram — also write a single
self-contained brief at `.loop/reports/decision.html` (the harness shows it when a
human is present; they still answer in their terminal). Under `html=auto`, a
plainly textual decision is skipped per the rubric — the markdown entry is
enough; under `html=on` always author. Under `html=auto` the
"When to author (html=auto)" rubric below decides (a decision page typically
rides on R1, R3, or R4); either way end with the `HTML-DECISION:` marker it
requires. Never write HTML when the argument contains `html=off`. The page MUST
be self-contained and offline: inline
all CSS, no external requests (no CDN/fonts/images/`fetch`), prefer no JavaScript,
realistic placeholder data. Writing under `.loop/reports/` is allowed (it is
outside the diff the evaluator sees); touch nothing else the constraints forbid.

<!-- BEGIN loop-html-contract (keep this block byte-identical across loop-contract, loop-evidence, loop-iterate) -->
### When to author (html=auto)

The `html=` token in your skill argument decides whether a page is authored at
all; the content contract below governs what any authored page must contain.

- `html=on` — always author.
- `html=off` — never author, and emit no marker.
- `html=auto` — author ONLY if at least one of these rubric items applies to
  THIS deliverable:
  - **R1 — Direction choice.** A choice among ≥2 viable alternatives where
    seeing them side by side materially changes the human's decision (UI
    mockups, or competing flow/architecture sketches).
  - **R2 — Inherently visual work.** The work IS UI/layout/visual design
    beyond a single trivial property change (one color/text/flag tweak never
    qualifies).
  - **R3 — Structure needs a diagram.** The explanation needs a
    multi-component pipeline, state-machine, or schema-change diagram to be
    understood correctly — prose alone would force the reader to reconstruct
    the graph.
  - **R4 — Structural decision request.** A decision request of the
    `NEEDS_ARCHITECTURE_DECISION` class (options differ in system shape, data
    model, or irreversibility).
  - **R5 — Complex-run evidence.** Evidence reports only for complex runs:
    >1 REQ, or >1 iteration, or open assumptions recorded, or the deliverable
    itself is visual — a trivial one-REQ one-iteration run stays text-only.

**Never author when:** the change is a single trivial property/text edit; the
markdown already says everything in ≤1 screen; the page would only restate a
table; the deliverable is pure refactoring with identical behavior; or you are
uncertain — default to skipped (text is always sufficient; HTML is an
enhancement).

**Declaration marker — mandatory whenever `html=` is `on` or `auto`.** The
last lines of your reply include exactly one of:

- `HTML-DECISION: authored .loop/reports/<name>.html — <which rubric item>`
- `HTML-DECISION: skipped — <short reason>`

Write the marker as a plain-text line — no code fence, no leading list dash or
quote (mirror of every other machine-parsed marker line).

The path is one token (no spaces) under `.loop/reports/`. Keep the
`HTML-DECISION:` keyword, the `authored`/`skipped` verdict word, and the path
in ASCII exactly — the harness machine-parses this line, journals your
decision, and verifies that a declared file exists and is non-empty. Never
declare `authored` without having written the file; when `html=off`, emit no
marker at all.

**Stop-reading gate.** If your decision is `skipped` — or the token is
`html=off` — emit the marker (when required) and stop reading this block
here: everything below governs only pages you actually author.

### HTML page content contract (what every page you author must contain)

Any HTML page you show the user is a **view over already-written sources** — the
canonical markdown under `.loop/docs/`, `.loop/last-verify.log`, and the git diff.
Follow this contract so the page is legible and never vague.

**Language.** Author every heading, badge, caption, and sentence in the **same
language as the contract** (each skill's Output-language rule already requires this
for `.loop/reports/*.html`). The section and item names this spec uses (e.g.
"Requirements addressed") are structural identifiers addressed to YOU — never
headings to copy onto the page: render every on-page heading in the contract
language (translate each such identifier into that language — never emit it
verbatim; e.g. a French report renders "Requirements addressed" in French). Shipping an
English heading in a non-English report is a defect. Keep only the machine
tokens ASCII: `REQ-xxx`, `VERIFY_COMMAND` strings, state/verdict words, file
paths, git refs.

**Two zones, always in this order, visibly separated** (distinct heading /
background / border; never interleaved):

- **Explanation zone** — framing prose only: what this page is, why the user
  is seeing it now, what you are asking, and what happens next. No result tables here.
- **Data zone** — the evidence, options, mockups, or definition. Every data
  block carries a one-line caption saying what it is and how to read it.

**Fixed framing header.** Items 1–5 form one compact top banner the reader can take in
at a glance; item 6 (provenance) sits as a small footer at the very bottom of the page.
The items are **content requirements, not visible labels**: never render an item's
spec name (e.g. "Why you're seeing this now") as an on-page label or heading — the
banner reads as natural report prose in the contract language, the way a
human-written executive summary would.

1. **Title + page-type badge** — exactly one `<h1>`, naming the deliverable's
   subject (the loop goal's topic; no unexplained abbreviations) — never the
   page type: the badge already carries the page type, so title and badge must
   not repeat each other. The badge is one of exactly five types — `Loop
   Definition`, `Clarifying Question`, `Direction`, `Evidence Report`,
   `Decision Required` — rendered in the contract language (the English names
   are this spec's identifiers).
2. **Loop goal, one line** — the contract Goal compressed to a single sentence.
3. **Why you're seeing this now** — one sentence mapping the current loop state to
   plain language.
4. **Call to action, one line** — exactly what to do (approve / pick 1–3 / choose an
   option / review).
5. **Read-only notice** — one short natural sentence in the contract language,
   a faithful translation of "This page is read-only — reply in the terminal
   that opened it." The page has no forms, no buttons, nothing to submit.
6. **Provenance footer** — which canonical markdown this page mirrors, the
   authoring timestamp (run `date` when authoring), the run's iteration number,
   the total cost labelled as a reference API-cost equivalent (subscription runs
   bill nothing per token), and the refs that pin what the page attests to: the
   **baseline ref** (run start), the **reviewed HEAD sha** (`git rev-parse HEAD` — the
   exact commit this page describes), and the **approved contract hash** (`.loop/approved`
   if present, else the sha256 of `product-contract.md` + `loop.config.sh`). Together
   these close the chain of custody — a reader can name the commit and contract the page
   is evidence for. Set refs and paths in `<code>`; show each value only where it
   exists; if a value genuinely does not exist yet (e.g. the loop has not run),
   write "n/a" — never a stale or previous-run value, and never fabricate one.

**No-invention rule.** The page is a view, not a new source of truth. Every claim,
number, file, option, and risk on it must already exist in the canonical markdown /
`.loop/last-verify.log` / the diff. If the HTML and the markdown ever disagree, the
markdown wins. If a source you need is missing or partial, say so in that section
instead of guessing. Prefer an explicit **"None"** over omitting a required section — a
missing section is indistinguishable from a forgotten one.

**No-omission rule.** The mirror runs both ways. The page must **represent every
section of its canonical source** (each surface's skeleton below lists them). A section
you deliberately do not render in full still appears as a one-line pointer — e.g.
"→ full text in `<file>` §<section>" — it is never dropped silently. Omitting material
that exists in the source is a defect equal to inventing material that does not. Empty
source section → "None"; content shown elsewhere → a pointer; both are explicit, so a
gap is always distinguishable from a forgotten section.

**Required skeleton, with room to add.** Each surface defines a required set of
sections in a fixed order (below). Include them all, in that order; render an empty
one as "None" rather than dropping it; never reorder or replace them. You MAY append
additional, clearly-labelled sections after the required set when they genuinely help
the reader.

**Cross-cutting rules:**

- **Altitude.** Framing elements are one sentence each; summaries 2–3 sentences; the
  Data zone favours one-line-per-row tables over paragraphs. No section restates another.
- **Label every data block.** Each table / mockup / option list gets a one-line
  caption on what it is and how to read it. Column headers use human words; keep
  `REQ-xxx` ids, command strings, file paths, and git refs in ASCII, untranslated.
- **Terminology.** Loop-internal vocabulary (gate reviewer, ledger, success
  candidate, sound/unsound, spec drift, state names) never appears bare in prose:
  on first use give the plain contract-language term first, the machine token
  after it in parentheses or `<code>`. Never inflect an internal English noun as
  a word of a non-English sentence. Machine state words (`PASS`, `APPROVE`,
  `met`, `sound`) stay ASCII but sit inside that glossed context.
- **No markdown syntax.** The page is HTML, not markdown: rendered text never
  contains backticks, `**` emphasis, or `[text](url)` leftovers — set code,
  commands, paths, and refs in `<code>` instead.
- **Honesty.** The result state must match the data on the same page (a success
  framing only when `.loop/last-verify.log` shows every command PASS; any unmet
  requirement is flagged, not hidden). The Risks section is honest, not decoration. A
  recommendation is not a decision — the human decides. The word `SUCCESS` is the
  external evaluator's verdict; never author it as your own claim.
- **Scannable and self-contained.** Laptop-first, degrades gracefully on mobile,
  respects the viewer's light/dark preference; any JavaScript is inert and offline (a
  light/dark toggle at most). Wide tables scroll inside their own container — the page
  body never scrolls sideways. Include a small `@media print` rule so the page archives
  cleanly to PDF (evidence is often filed that way): reveal content collapsed inside
  `<details>`, avoid clipping wide tables, and keep PASS/FAIL/state legible without
  depending on background colour alone. A long raw block (full command output, a large diff) may
  sit inside a native `<details>` element so the page stays skimmable, but nothing
  essential may require expanding it or running JS to read.
- **Semantics & accessibility.** `<html lang>` matches the contract language;
  exactly one `<h1>`; table header cells carry `scope="col"`; state is never
  conveyed by colour alone — a pill always carries its state word.
- **Visual evidence.** When the contract's acceptance criteria call for
  screenshots or other images, embed them as `data:` URIs (keep the whole page
  ≲ 2 MB); above that, save the image beside the page under `.loop/reports/` and
  reference it relatively, with a caption. "Not attached" is a last resort and
  must then appear under Risks.
- **Reports directory hygiene.** `.loop/reports/` holds only user-facing pages
  and their assets. Build scripts, probes, caches, and browser profiles never
  live under it.
- **Shared visual grammar** (inline it per page — no shared stylesheet, the
  self-contained rule still holds): state → colour (verified / PASS → green;
  needs-you, i.e. any `NEEDS_*` or risk approval → amber; FAIL / drift / risk → red;
  interactive question, mockup, or definition → neutral). The badge and the "why now"
  line share that colour. Render PASS/FAIL and Changed? as coloured pills, not bare
  text. Keep the Explanation zone quiet and the Data zone bordered with zebra rows.

**Canonical style block + skeleton.** Start every page from this exact `<style>`
block, copied verbatim (it satisfies the self-contained rule inline). You MAY
append page-specific rules after it, but never alter these base rules and never
invent new state colours — every page of every run shares one visual identity.
Then fill the skeleton with the surface's real sections (defined per page type
below); never ship a page with placeholder text still in it:

```html
<style>
  :root{ --ok:#1a7f37; --need:#9a6700; --bad:#cf222e; --neutral:#57606a;
         --ink:#1f2328; --bg:#ffffff; --zebra:#f6f8fa; --line:#d0d7de; }
  @media (prefers-color-scheme:dark){ :root{
         --ink:#e6edf3; --bg:#0d1117; --zebra:#161b22; --line:#30363d; } }
  *{ box-sizing:border-box; }
  body{ color:var(--ink); background:var(--bg); max-width:60rem; margin:0 auto;
        padding:1.5rem 1.25rem 3rem;
        font:15px/1.6 system-ui,-apple-system,"Segoe UI","Hiragino Sans",Meiryo,
             "Noto Sans CJK JP","Noto Sans",Helvetica,Arial,sans-serif; }
  h1{ font-size:1.5rem; margin:.2em 0 .5em; } h2{ font-size:1.1rem; margin:1.6em 0 .5em; }
  code,pre{ font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  code{ background:var(--zebra); padding:.05em .35em; border-radius:.3em; font-size:.9em; }
  pre{ background:var(--zebra); border:1px solid var(--line); border-radius:.4em;
       padding:.7em .9em; overflow-x:auto; font-size:.82em; line-height:1.45; }
  .pill{ display:inline-block; padding:.1em .6em; border-radius:1em; color:#fff;
         font-size:.85em; font-weight:600; white-space:nowrap; }
  .pill.ok{ background:var(--ok);} .pill.bad{ background:var(--bad);}
  .pill.need{ background:var(--need);} .pill.neutral{ background:var(--neutral);}
  table{ border-collapse:collapse; width:100%; font-size:.93em; }
  td,th{ border:1px solid var(--line); padding:.45em .6em; text-align:left; vertical-align:top; }
  th{ background:var(--zebra); } tbody tr:nth-child(even){ background:var(--zebra); }
  .table-wrap{ overflow-x:auto; }
  .caption{ font-size:.88em; color:var(--neutral); margin:.7em 0 .4em; }
  header.banner{ border:1px solid var(--line); border-radius:.6em; padding:1em 1.2em;
                 margin-bottom:1.2em; background:var(--zebra); }
  header.banner p{ margin:.35em 0; }
  .zone-data{ border:1px solid var(--line); border-radius:.6em; padding:.2em 1em 1em;
              margin:.6em 0 1.2em; }
  .zone-exp{ opacity:.96; }
  details{ margin:.5em 0; } details summary{ cursor:pointer; color:var(--neutral); }
  footer.provenance{ border-top:1px solid var(--line); margin-top:2em; padding-top:.8em;
                     font-size:.82em; color:var(--neutral); }
  ul{ margin:.3em 0; padding-left:1.4em; } li{ margin:.15em 0; }
  @media print{ body{ max-width:100%; } details>*{ display:revert; }
    .table-wrap,.zone-data{ overflow-x:visible; }
    .pill{ -webkit-print-color-adjust:exact; print-color-adjust:exact; } }
</style>
<header class="banner zone-exp"><!-- h1 title (the subject, not the page type)
  + <span class="pill neutral">badge</span> + goal (1 line) + why-now (1 line)
  + CTA (1 line) + read-only notice --></header>
<section class="zone-exp"><!-- Explanation: framing prose only, no result tables --></section>
<section class="zone-data"><!-- Data -->
  <p class="caption"><!-- what this block is and how to read it --></p>
  <div class="table-wrap"><table><!-- one row per item; PASS/FAIL as <span class="pill ok|bad"> --></table></div>
  <details><summary><!-- raw evidence --></summary><!-- full log / diff hunk --></details>
</section>
<footer class="provenance zone-exp"><!-- provenance: mirrors <file> · authored <date>
  · iter N · cost (API-equivalent reference) · baseline · HEAD sha · contract-hash --></footer>
```
<!-- END loop-html-contract -->

### Decision Required — required sections (fixed order)

Badge `Decision Required` (amber — the loop is paused for a human). Provenance
mirrors the triggering `DR-N` entry in `.loop/docs/decision-requests.md`; include the
iteration number, total cost, the current **HEAD sha** (`git rev-parse HEAD`), and the
**approved contract hash** (`.loop/approved` if present, else the sha256 of
`.loop/docs/product-contract.md` + `loop.config.sh`), so the decision is pinned to a
known commit and contract. Map the why-now line to the exact state:
`NEEDS_SPEC_DECISION` → a requirement is ambiguous or contradictory;
`NEEDS_ARCHITECTURE_DECISION` → a dependency / schema / API-surface choice is needed;
`NEEDS_DECOMPOSITION` → the remaining work exceeds this worker's iteration budget
and should be split into phases (fleet workers; usually handled by the supervisor,
not a human);
`RISK_REQUIRES_APPROVAL` → the harness found harness files, DENIED_PATHS, or
gitignored session/models config touched (in-memory baselines or the diff
policy) and imposed sign-off — an evaluator/harness verdict,
never a state you declare (an ESCALATE_PATHS touch maps to
`NEEDS_ARCHITECTURE_DECISION` instead). Sections, top to bottom (the names are
structural identifiers — render every on-page heading in the contract language):

1. **Framing header** (Explanation) — the six framing elements.
2. **The situation** (Explanation) — plain-language restatement of why a decision is
   needed: what the loop hit that it cannot decide alone.
3. **What's blocked** (Explanation) — one line: the loop is paused and will not
   proceed until answered.
4. **Options** (Data) — numbered cards, one per option: label + what it does +
   trade-off. Number them to match the terminal answer.
5. **Recommendation** (Data) — the recommended option, clearly marked, with a
   one-line rationale (or "options are balanced — no recommendation").
6. **Impact & risk if left undecided** (Data) — two short blocks.
7. **Relevant drift** (Data, optional) — for drift-driven spec/architecture
   decisions, the relevant rows of the drift checks table; omit for pure risk approvals.
8. **The exact question** (Explanation) — the verbatim "Concrete question for the
   human" as the closing line, so there is no ambiguity about what to answer.

Never write SUCCESS anywhere — that word belongs to the external evaluator.
Do not commit; the harness commits after evaluation.
