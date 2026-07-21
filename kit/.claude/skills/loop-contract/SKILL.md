---
name: loop-contract
description: Define a loop for this repository from a user instruction — explore the codebase, ask the minimum necessary questions, then write the fixed Product Contract (.loop/docs/product-contract.md) and its machine-readable stop conditions (loop.config.sh), and present the full loop definition for user approval. Use when the user wants to set up an autonomous implementation loop for a task, or to revise an existing loop definition.
---

# Create (or revise) a Product Contract for a loop

You are defining a **contract-based autonomous loop**. The skill argument is the
task instruction (or starts with `revise:` — see below). Your output is a complete
loop definition the human will approve: `.loop/docs/product-contract.md` (fixed
requirements) + `loop.config.sh` (stop conditions the external evaluator enforces).

Guiding principle: **implementation steps stay flexible; success conditions stay
explicit.** A good contract says WHAT must be true when the loop stops, never HOW
to build it. File layout, component split, naming, internal architecture are the
loop's freedom — do not pin them here.

If the argument starts with `revise:`: read the existing contract and config, ask
the user what should change, apply it, then jump to Step 5.

If the argument starts with `auto:`: you are running HEADLESSLY — there is no user
to ask. Skip Step 2 entirely: make conservative default decisions yourself, and
record every decision a human would normally be asked about in a section
`## Assumptions (auto mode)` inside the contract (scope boundaries chosen,
non-goals assumed, denied/escalate paths picked, budget defaults). Prefer
inferring verification commands from manifests/CI config over running them; if a
command was not actually executed, note it as unverified in the assumptions.
The acceptance-gate classification stays mandatory on this path: classify every
VERIFY_COMMAND red→green vs stays-green from what Step 1 actually observed, and
record any classification inferred without executing the command under
`## Assumptions (auto mode)`. The expectation-decomposition pass and
`.loop/docs/acceptance-checklist.md` stay mandatory too: write the checklist
with a verification method per row, record method assignments made without a
user under `## Assumptions (auto mode)`, and prefer `run` probes the loop can
execute headlessly over `human` rows — there is no human present to look.
A browser-rendered deliverable keeps its direct browser check on this path:
prefer a deterministic browser-test command the repository already supports;
otherwise bind the agent browser channel `run` row (see Step 2) with its
`unproven — agent-environment dependent` record and note the binding under
`## Assumptions (auto mode)` — never silently drop the check or demote it
to `human`.
Still run the Step 1 survey and the Step 1.5 diagnosis (skipping only the
questions): every question you would have asked becomes both an
`## Assumptions (auto mode)` entry and a "Deferred with defaults" entry in
`.loop/docs/unknowns.md`. Prefer inference over feasibility spikes; if you must
probe, stay inside `.loop/spike/` and delete it afterwards.
Then follow Steps 3-4 and stop after writing both files — do not wait for input.
Your definition will be judged by an independent contract reviewer before it is
approved. If `.loop/contract-review-feedback.md` exists, a previous definition
was REJECTED by that reviewer — read it and address every must-fix item in the
definition you write now. (Never `./loop.sh open` anything on this path — there
is no human present to view it. Author HTML only where the `ask=critical` flow
below explicitly calls for a decision page, per the "When to author (html=auto)"
rubric.)

If the `auto:` prompt also carries `ask=critical`, the run may stop for
CRITICAL unknowns instead of assuming through them. A CRITICAL unknown is one
where **no conservative default is safe** — every candidate default risks
irreversible, destructive, or scope-defining consequences the instruction does
not license. Everything below that bar remains an assumption, exactly as
above. On this path the LAST line of your reply must be exactly one of:

- `CONTRACT-GEN: READY <one-line summary>` — the contract is written; every
  open question had a safe conservative default, recorded under
  `## Assumptions (auto mode)`. Behavior otherwise unchanged.
- `CONTRACT-GEN: QUESTIONS <n> critical unknowns` — critical unknowns exist.
  STILL write the best-effort contract (non-critical unknowns as assumptions),
  write each critical question as a `## DR-CONTRACT-<n>` block in
  `.loop/docs/decision-requests.md` (the question, the concrete options, why
  no safe default exists), and author `.loop/reports/decision.html` only per
  the "When to author (html=auto)" rubric below (a critical direction choice
  typically satisfies R1/R4) — apply the rubric as `html=auto` unless the
  prompt carries an explicit `html=` token, and put the `HTML-DECISION:`
  marker line immediately above the final `CONTRACT-GEN:` line.

Keep the `CONTRACT-GEN:` keyword, the `READY`/`QUESTIONS` verdict word, and
the `<n>` count in ASCII exactly — the harness machine-parses this line.
Without `ask=critical` in the prompt, emit no `CONTRACT-GEN` marker at all.

## Presentation format — HTML vs plain text (whenever you show the user something)

This is an interactive session with a real human at a terminal, and this project
can open self-contained HTML in their browser (`./loop.sh open <file>`). Choose the
medium per interaction — this decision is yours to make each time:

- **Default to HTML** when what you show benefits from being *seen*, not just read:
  a UI/design direction or mockup, several options to compare side by side, a
  table/diagram, or the full loop-definition summary. Author ONE self-contained
  page under `.loop/reports/` and open it with
  `./loop.sh open .loop/reports/<name>.html`.
- **Downgrade to plain terminal text** for anything trivial: a single field (app
  name, a path), a yes/no, a one-line confirmation. Do not manufacture an HTML page
  to ask "what should I call this?".
- When unsure: mockups / options / the definition summary → HTML; quick
  confirmations → text.

Either way, the HTML only helps the user **understand** — it never collects
input. Collect the answer in the session through the client's structured-question
interaction when one is available (`AskUserQuestion` in Claude Code), or plain
chat otherwise. Ask one question at a time with 2–4 concrete options; permit a
free-form answer.

Any HTML you write MUST be self-contained and fully offline: inline all CSS, make
no external requests (no CDN, fonts, images, `fetch`), prefer no JavaScript, and use
realistic placeholder data. `./loop.sh open` is a silent no-op when no human is
present, so this section (ad-hoc `./loop.sh open` presentation during the
interactive session) applies to interactive definition only. The "When to
author (html=auto)" block below is different: it governs every surface,
including the `auto:` ask=critical decision page. In an interactive session,
present the final **Loop Definition** summary as the Loop Definition HTML page
by default (R1/R3 almost always apply to a full definition); downgrade to text
only for trivially small definitions.

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

### Contract-session pages — required sections (fixed order)

You author three kinds of page here; all use the framing header. None has an
iteration or cost yet (the loop has not run), so their provenance cites the source
instruction and the draft `.loop/docs/product-contract.md`, with iteration, cost,
reviewed HEAD, and approved contract hash all "n/a" (nothing has run or been approved yet).
Section names in the page definitions below are structural identifiers — render
every on-page heading in the contract language.

**Clarifying Question** (badge `Clarifying Question`, neutral) — when several questions
or side-by-side options genuinely read better seen than typed, or when confirming the
spec first requires **explaining a complex concept/mechanism**; a single trivial
question stays plain terminal text.

1. **Framing header** (Explanation) — CTA "Answer each numbered question in the terminal."
2. **What I already understand** (Explanation) — 2–4 bullets from Step 1, so the
   questions read as minimal, not lazy.
3. **Concept explanation** (Explanation, optional) — when the questions only make sense
   after a mechanism is understood, explain it here first with a small inline diagram or
   bullets (no external assets). Omit this block for simple questions.
4. **Spec to confirm** (Data, optional) — when you are validating an interpretation,
   state the implementation spec you inferred as a short captioned list, so a question
   can ask "is this the behaviour you want?" Omit when only gathering unknowns.
5. **Open questions** (Data) — numbered; each = the question + why it matters +, if
   it is a choice, the concrete options as a labelled list.
6. **What I'll do with your answers** (Explanation) — they fold into Requirements /
   Non-goals / Acceptance Criteria, then a contract is presented for approval.

**Direction** (badge `Direction`, neutral) — for choosing between alternatives, whether
**visual** (UI mockups) or **structural** (a processing flow / architecture approach,
e.g. top-down vs bottom-up). 1–3 directions.

1. **Framing header** (Explanation) — CTA "Pick a direction (1/2/3) or describe an adjustment."
2. **How to read this** (Explanation) — one line: visual → "directions with placeholder
   data, not the finished feature"; flow/architecture → "candidate approaches, not yet built."
3. **Direction 1..N** (Data) — 1–3 candidates. Visual: a mockup with a one-line idea,
   labelled "placeholder data." Flow/architecture: a small inline diagram (inline SVG or
   CSS/box drawing — no external assets) of the approach with a one-line idea.
4. **How they differ** (Data) — a dimension × direction comparison so the choice is
   legible, not just separate pages. For flow/architecture directions this MUST include,
   per approach, its **pros/cons** and where it sits on **top-down ↔ bottom-up**, plus
   the condition under which you'd pick it.
5. **Next step** (Explanation) — the chosen direction becomes an Acceptance
   Criterion; then the full definition is presented for approval.

**Loop Definition** (badge `Loop Definition`, neutral) — the full definition for approval.
Title the page's single `<h1>` with the loop's subject, never the words "Loop
Definition" (the badge carries the page type).
Mirror **every** section of `product-contract.md` (no-omission rule): Goal, Requirements,
Non-goals, Constraints, Quality baseline, Acceptance Criteria, Validation Commands, Human
Approval Required If — plus the config-derived policy/budgets below.

1. **Framing header** (Explanation) — CTA "Approve, or tell me what to change."
2. **Goal** (Explanation) — the Goal paragraph.
3. **Requirements** (Data) — table `REQ-xxx` | one-line observable behaviour.
4. **Non-goals** (Data) — explicit exclusions, or "None".
5. **Constraints & quality baseline** (Data) — invariants the loop must hold (existing
   checks stay green, security boundaries, dependency policy) and the contract's
   Quality baseline items, both from the contract; or "None".
6. **Acceptance Criteria** (Data) — the checkable statements the evidence report must
   later demonstrate. Distinct from the verify gate below (criteria are what must be
   true; the gate is the commands that prove it) — mirror the contract, do not drop.
   Include the acceptance-checklist view: each AC id | REQ | expectation |
   verification method (`cmd`/`run`/`human`), with any `human` rows and any
   unproven agent-browser-channel `run` rows called out (the latter carry the
   stop-on-missing-capability caveat) — the reader is approving these as the
   loop's closure obligations (the run cannot end until every row is `verified`).
7. **Verify gate & what it proves** (Data) — table: each `VERIFY_COMMAND` | what
   passing it demonstrates | expected baseline (red→green: fails now, must pass
   when done; stays-green: regression guard). This is the deterministic success
   gate — surface it prominently.
8. **Human Approval Required If** (Data) — the conditions that must stop the loop for a
   human, from the contract. The user is approving these — never omit them; or "None".
9. **Diff policy** (Data) — denied paths and escalate paths, or "None configured".
10. **Budgets & review** (Data) — `MAX_ITERATIONS`, `MAX_ITER_SECONDS`, review mode;
    for `MAX_COST_USD` show "no cap (subscription)" when empty — never invent a number.
11. **Model roles** (Data, optional) — implement / review / evidence / stop-eval.
12. **What happens on approval** (Explanation) — exit the session; `loop.sh` asks for
    final `y` and starts the loop; nothing runs until you approve.

## Output language (write in the user's language)

Detect the language of the user's instruction (this skill's argument) and write
**all human-facing prose in that language**: the contract body (the Goal,
Requirements / Non-goals / Constraints text, Acceptance Criteria), every question
you ask, and the loop-definition summary and any HTML you show. Japanese
instruction → Japanese contract; English → English. This choice propagates —
every downstream skill mirrors the contract's language — so set it correctly here.

Keep these in ASCII exactly, regardless of the prose language (they are code or
machine-referenced): `loop.config.sh` keys and their shell values
(`VERIFY_COMMANDS`, `DENIED_PATHS`, …), the `REQ-xxx` identifiers, the
`<!-- TEMPLATE -->` marker, commands, file paths, and git refs. Translate the
prose around them, never the tokens themselves.

## Step 1 — Explore before asking (blindspot survey)

Investigate the repository first so your questions are minimal:
- How is it built/tested? Find real verification commands (package.json scripts,
  pyproject/Makefile, CI config). Run the likely test/lint commands once to confirm
  they work and see their current status.
- What conventions exist (structure, framework, package manager)?
- What already exists related to the instruction? What would the change touch?
- What looks risky (auth, schema/migrations, secrets, prod config, dependency manifests)?
- What did previous runs learn? If earlier runs left a filled-in
  `.loop/docs/progress.md`, `decision-requests.md`, `assumptions.md`, or
  `.loop/docs/run-archive/`, read them — past escalations and recorded
  assumptions are the cheapest map of this repository's traps. In the archive,
  the "Lessons for future runs" section of each `evidence-report.md` is the
  distilled version — read those first.
- If the instruction points at reference code ("same as X", a vendored library,
  another repo), read it and extract its observable semantics (behaviors, edge
  cases, invariants) into Acceptance Criteria — the reference is a spec to
  satisfy, never code to transliterate.
- Record what you learn as you go in `.loop/docs/unknowns.md` (replace the
  template, remove its `<!-- TEMPLATE -->` marker): the territory map, and —
  the payload — "Things the user didn't know to ask", each with the concrete
  failure mode it would have caused.
- If `.loop/parallel-context.md` exists, read it: other loops are running in
  parallel on sibling tasks. Where this task's scope could overlap theirs, draw
  the boundary explicitly in **Non-goals** so neither loop implements (or
  reverts) the other's work.
- If `.loop/master-contract.md` exists, read it: this loop is a fleet sub-task
  of a MASTER contract a human already approved. Your contract must stay INSIDE
  the master's scope — cover exactly the REQ ids your task instruction assigns,
  add nothing the master does not contain, and mirror the master's Non-goals
  and constraints where they touch this task. An independent reviewer rejects
  sub-contracts that drift from the master. Never edit the master copy. On this
  path also skip Step 1.5's unknowns pass — the master run already did it;
  leave `.loop/docs/unknowns.md` as the template and record task-local
  assumptions in the sub-contract instead.
- If `.loop/phase-context/` exists, this task is a LATER PHASE of a chained
  workflow: each `<predecessor-id>/` inside holds a completed predecessor
  phase's sub-contract and evidence report (direct and transitive — every
  merged ancestor). The merged code in this tree
  already contains their work — read these files for the WHY (decisions taken,
  known gaps, recorded assumptions) when scoping this phase. Two hard rules:
  a predecessor's or sibling branch's "met" claims are **phase-scoped**, never
  proof that the shared master REQ is done (only the completing owner — the
  chain's last phase or the fork's join — certifies it in full, and
  the master integration gate decides); and never re-verify, re-implement, or
  revert a predecessor's scope — this contract covers only THIS phase's
  increment, stated as observable "done for this phase" criteria.

## Step 1.5 — Diagnose the remaining unknowns, then scale the interview

Classify what Step 1 could NOT settle, before asking anything:

- **Known unknowns** — listable open questions → ask them in Step 2.
- **Unknown knowns** — the user will know it when they see it (visual/UX
  taste, "which approach?") → build 1–3 Direction pages (Step 2) and record
  the verdict + WHY under "Direction verdicts" in unknowns.md.
- **Unknown unknowns** — the survey's "things the user didn't know to ask":
  raise the load-bearing ones as questions; convert the rest into Non-goals
  or explicit assumptions.
- **Feasibility unknowns** — "can this even work here?" → run a time-boxed
  spike (≤ ~15 min) BEFORE locking acceptance criteria on it. Spikes live
  under `.loop/spike/` (gitignored — never in the project tree); delete the
  directory afterwards and record only the result under "Feasibility probes".

**Expectation decomposition (mandatory, scaled to the task).** A requirement
is met when the fine-grained behaviors the user EXPECTS actually hold — not
when something merely runs. Derive the implicit must-be expectations the
instruction never states (they are "obvious" to the user), record them under
"Must-be baseline" in unknowns.md, and carry each into the contract as an
Acceptance Criterion plus a row in `.loop/docs/acceptance-checklist.md`
(Step 3):

- **Change / migration / refactor tasks — preservation invariants.**
  Inventory what observably works TODAY in the blast radius: what would the
  user notice if it broke? Each becomes a "still works after" criterion. A
  migration's primary implicit requirement is that the migrated behavior
  remains visible and functional — e.g. moving particle computation from CPU
  to GPU implies "particles are still visible and still animate", whether or
  not the instruction says so.
- **0→1 builds — domain baseline.** Enumerate the genre's taken-for-granted
  mechanics: "a Mario-like game" implies responsive controls, stomping kills
  enemies, contact/pit death, lives and game-over. Ask the user only about
  the load-bearing ambiguous items (batched, with concrete options); adopt
  recommended defaults for the rest and record them under "Deferred with
  defaults".
- **Premortem** — only for tasks with real product surface; for a trivial or
  purely mechanical change, skip it and write "Premortem: none (trivial)"
  under Must-be baseline instead of manufacturing concerns. When it applies:
  name the 3 most plausible reasons the user would be disappointed even with
  every VERIFY_COMMAND green. Each reason becomes an Acceptance Criterion
  (with a verification method), a Non-goal, or an explicit recorded
  assumption — never left unwritten.

Proportionality: a trivial task gets a handful of checklist rows, not
thirty; a 0→1 build or a behavior-preserving migration gets the full pass.

Scale the interview to the instruction: a small task in well-trodden territory
keeps the 2–4 question ethos and a one-line territory map; a 0→1 build,
unfamiliar territory, or several plausible architectures gets the full pass.
Fill every section of `.loop/docs/unknowns.md` — write "None" explicitly
rather than dropping a section.

## Step 2 — Ask ONLY what exploration cannot answer

**Mandatory acceptance-gate question (always ask on the interactive path).**
However much Step 1 settled, ask the user exactly ONE acceptance-gate question
through the client's structured-question interaction when available
(`AskUserQuestion` in Claude Code), otherwise in plain chat, before writing the
contract: what commands the loop must stop on (the future VERIFY_COMMANDS),
what a pass proves, and which test tool runs them. The options MUST lead with
a concrete proposal you authored from the Step 1 exploration — the exact
commands, what passing each proves, the test tool — marked "(Recommended)", so
a user with no opinion accepts it unchanged. If the instruction already
specified acceptance criteria, the question confirms them and offers your
supplement (e.g. an extra regression guard) as an option. Record the outcome
in the "Interview decision log" of unknowns.md like any other question.
(`auto:` mode has no user — it records assumptions instead, per its rules
above.)

The same question assigns every acceptance criterion its **verification
method** — `cmd` (a deterministic command proves it), `run` (only runtime
observation proves it: run the artifact and observe, via a probe script or
browser observation with screenshots), or `human` (a judgment only a human
can make; connect each such item to "Human Approval Required If" so the
loop stops for it instead of waiving it). If any requirement is observable
only at runtime (rendering, animation, interaction), the recommended
proposal MUST include at least one `run` criterion: a static gate
(build/lint/unit tests) cannot discriminate a broken runtime, and "the code
reads correct" is analysis, never a substitute for demonstration.

A `run` row's observation travels one of two channels, with different
intake duties:

- **Scripted probe channel** — the project's own tooling proves it (a
  probe script, a Playwright/driver test installed in the repository,
  typically wired into the verify gate). Before making such a binding,
  prove the channel works in the loop's own execution mode (headless,
  non-interactive) with a Step 1.5 feasibility spike — a probe must
  launch, observe, and exit by itself. Record the spike result under
  "Feasibility probes" in unknowns.md.
- **Agent browser channel** — the executing agent drives a browser
  directly through its own browser-automation skill or MCP connector (a
  Playwright skill, a browser extension) and saves screenshots under
  `.loop/observations/`. Do NOT feasibility-probe this channel at
  definition time, and never demote such an item to `human` merely
  because THIS session cannot drive a browser: the defining agent's
  environment is not the executing agent's environment (different
  session, possibly a different agent entirely), so a definition-time
  probe proves nothing about the run — and the skill may simply not be
  enabled here. Bind the row as a PROPOSAL: record it under "Feasibility
  probes" in unknowns.md as `unproven — agent-environment dependent`,
  together with the declared runtime consequence: if the executing agent
  lacks the capability, the loop stops at the first attempt with a
  decision request for the human — it never silently reclassifies or
  skips the check.

**Browser-rendered deliverables demand a direct browser check.** When a
requirement's output renders in a browser or must be judged visually (web
UI, layout/CSS, canvas/visual output), the recommended proposal MUST
include at least one direct browser check, preferring in order: (1) a
deterministic browser-test command (`cmd` — e.g. Playwright already in
the repository, or added as an in-scope red→green deliverable the
contract explicitly licenses, dev-dependency included); (2) a `run` row
on the agent browser channel; (3) a `human` row — only when the user
declines browser automation. Present the channel caveat with the
proposal, in the user's language: if the executing agent has no browser
skill or connector enabled, the check cannot run and the loop will stop
at that point to ask how to proceed. By approving, the user is choosing
that stop behavior as part of the gate.

Beyond that, ask the minimum set of questions (typically 2-4), such as:
- Scope boundaries: what is explicitly OUT (Non-goals)?
- Acceptance criteria that aren't derivable from code (UX expectations, edge cases)
- Areas that must not be touched (DENIED_PATHS) or need human sign-off (ESCALATE_PATHS)
- Iteration budget (MAX_ITERATIONS) if the task looks large. Do NOT ask about or
  propose a USD cost cap on your own — the kit assumes subscription usage (no
  per-token charge). Only discuss MAX_COST_USD if the user brings up cost.

Do not ask about things you can decide from the codebase (file layout,
naming). Propose defaults and let the user correct. The acceptance gate is
the one exception — it is always confirmed with the user (above), with your
codebase-derived proposal as the recommended option.

Interview discipline:
- Order questions by architectural blast radius — data model > interfaces >
  user-visible behavior > style — and state with each question why the answer
  matters (what it changes).
- Ask structured questions through the client's available question interaction
  (`AskUserQuestion` in Claude Code), or plain chat when none is exposed, one
  at a time. After each answer, re-rank what is still worth asking — answers
  kill and spawn questions; stop when the remainder no longer changes the
  contract.
- A question you decide NOT to ask becomes a "Deferred with defaults" entry in
  unknowns.md: the conservative default you adopted and what would make it wrong.
- Record every answer in the "Interview decision log" of unknowns.md before
  folding it into the contract.

If the task is visual — "improve the UI", "redesign X", a new screen/component — or the
real question is "which approach?" (including a processing-flow or architecture choice
such as top-down vs bottom-up), do not describe the options in prose. Build 1–3
self-contained HTML directions (mockups for visual tasks, small inline diagrams for
flow/architecture — realistic placeholder data), open them with `./loop.sh open`, and
ask the user to pick or adjust. Fold their choice into the Acceptance Criteria so the
loop stays verifiable. (Build it per the **Direction** skeleton under "Contract-session
pages" above; for flow/architecture include the pros/cons + top-down↔bottom-up matrix.
Trivial questions still stay plain text.) Record the chosen direction and WHY —
plus each rejected direction in one line — under "Direction verdicts" in
unknowns.md; the "why" is the criterion the user could not articulate before
seeing it.

## Step 3 — Write the contract

Fill `.loop/docs/product-contract.md` (replace the template, remove the
`<!-- TEMPLATE -->` marker):
- **Goal**: one paragraph, outcome-focused
- **Requirements**: numbered REQ-xxx, each observable/verifiable. Write each
  one as a HEADING — `### REQ-001: <name>` with the behavior below it — never
  as a bullet or prose: the harness machine-parses heading lines to build the
  per-REQ gates (ledger check, reviewer verdict table), and the approval lint
  refuses a contract with no REQ headings
- **Non-goals**: explicit exclusions (prevents scope creep by the loop)
- **Constraints**: keep existing checks green, security boundaries, dependency policy
- **Quality baseline**: include this section by default, with these items —
  adherence to the repository's conventions (naming, structure, idioms of the
  surrounding code); no dead or duplicated code introduced; existing
  lint/typecheck/test commands stay green; no TODO-stubs for required
  behavior. You may trim items that genuinely do not apply to this task, but
  keep the section: gate reviewers treat every listed item as a contract
  constraint (they already enforce contract-encoded constraints — this makes
  the quality bar a first-class default instead of an unstated expectation).
- **Acceptance Criteria**: checkable statements the evidence report must
  demonstrate. State per REQ **how it is verified** (which command, test, or
  observable behavior proves it) and its verification method (`cmd` / `run` /
  `human`, from Step 2), not just what must be true — a criterion nobody can
  check is a criterion the loop will game, and a runtime-observable criterion
  classified `cmd` is one the loop will "prove" by reading its own code.
  Write each criterion as a list item carrying its checklist id —
  `- AC-001 (run): <expectation>` — matching its row in
  `.loop/docs/acceptance-checklist.md`: the evaluator anchors obligations to
  the AC ids named in the approved contract, so a deleted checklist row can
  never shrink what the loop owes.
  **One numbering scheme, everywhere.** AC ids are zero-padded (`AC-001`,
  not `AC-01`/`AC-1`) and sequential with no gaps, and EVERY `AC-nnn` token
  anywhere in the definition — the Acceptance Criteria list, the Validation
  Commands prose, `loop.config.sh` comments, the checklist — must name an id
  the Acceptance Criteria list defines. Before presenting the definition,
  self-check this closure: a contract whose prose cites an id its own AC list
  never defines, or whose config comments count the same expectations under a
  parallel numbering, seeds a mid-run repair spiral (the approve lint refuses
  these, but a definition that needs the override was authored wrong).
  AC ids are also **run-scoped**: they must never be baked into product files
  (docs, code, probe sources, output strings, filenames) — the next contract
  renumbers from AC-001 and permanent copies collide. Product-side artifacts
  use descriptive names; the checklist maps name → AC.
  A criterion of the "document X is in sync" kind is verified by asserting
  the presence of the identifiers the implementation uses — never by
  asserting prose sentences or diagram-label literals (those tests break on
  harmless rewording and prove nothing about truth); reviewer audits, not
  greppy tests, own stale-claim detection.
- **Validation Commands**: mirror of VERIFY_COMMANDS, each classified as
  **red→green** (expected to FAIL on the current baseline; passing proves the
  new behavior — e.g. tests the loop is required to add) or **stays-green**
  (already passes; regression guard)
- **Human Approval Required If**: conditions that must stop the loop. This
  section is the loop's mid-run escalation bar: the implementer decides
  everything below it autonomously (conservative default + an
  `assumptions.md` entry) and stops only for matches of this section,
  contract-invalidating discoveries, and denied/escalate paths. Populate it
  deliberately from the Step 1.5 diagnosis — exactly the risks where the user
  would say "stop and ask me", nothing routine.

Also fill `.loop/docs/acceptance-checklist.md` (replace the template, remove
its `<!-- TEMPLATE -->` marker): one row
`| AC-NNN | REQ-xxx | <expectation> | <cmd|run|human> | pending | - |`
per fine-grained expected behavior from the Acceptance Criteria and the
"Must-be baseline" pass — preservation invariants and domain-baseline items
included. Keep each row on one line, never use `|` inside a cell, start
every status at `pending`. The evaluator refuses the success gate while any
row is not `verified`, so a row written here is a promise the loop must
close — and an expectation omitted here is one nobody will check. For a
trivial task, 1–3 `cmd` rows that simply mirror the verify gate are the
CORRECT checklist — do not manufacture depth the task does not carry (every
row is a gate obligation that costs budget to close). Fleet
sub-task path (`.loop/master-contract.md` present): still write the
checklist, scoped to exactly this task's assigned REQ ids, deriving its
rows from the master contract's acceptance criteria.

Three per-row disciplines (the contract reviewer audits all three):
- **Provenance.** Every row traces to (a) an explicit Acceptance Criterion,
  (b) a "Must-be baseline" entry in unknowns.md, or (c) a Quality-baseline
  item of the contract. A nice-to-have PREFERENCE never becomes a row — the
  gate makes every row blocking, so writing one promotes your taste to a
  requirement the user never asked for. Keep preferences in Quality-baseline
  prose, ask the user (interactive), or record an assumption (auto).
- **Atomicity.** One observable proposition per row: a row joining two
  behaviors with "and" that could hold half-and-half gives an ambiguous
  verdict and an unactionable failure — split it.
- **REQ linkage.** The REQ cell names a REQ id the contract actually defines
  (the approve-time lint refuses dangling references and duplicate AC ids).

Bad granularity: "make a nice agent creation feature" (too vague) or "create
AgentCreateForm.tsx using Zustand with fields x,y,z" (over-specified design).
Good granularity: "users can create/edit/delete/list agents; an agent has
name/prompt/skills; invalid MCP config cannot be saved; execution is out of scope;
existing lint/typecheck/test/build stay green."

**REQ ids are also the unit of parallel decomposition.** After approval, the
harness may split the contract into parallel tasks, and each REQ id normally
belongs to exactly ONE task — several tasks may share a REQ only as phases of
one piece of work (a sequential chain, or a fork-join whose joining task owns
the REQ and certifies it in full). So give independently deliverable outcomes
their own REQ ids (e.g. "the API endpoint" and "the UI that calls it" as two
REQs, not one), and never bundle unrelated deliverables into a single REQ:
one giant REQ still constrains how freely the work can parallelize.

NEVER write requirements or acceptance criteria that constrain WHICH files may
change (e.g. "the diff touches only src/foo/"). File-level restrictions belong in
DENIED_PATHS / ESCALATE_PATHS (loop.config.sh) — the deterministic evaluator
enforces them. The loop also updates its own bookkeeping (`.loop/docs/**`,
progress/plan/drift reports) every iteration BY DESIGN; a contract that forbids
this contradicts the harness and deadlocks the loop.

## Step 4 — Sync loop.config.sh (the stop conditions)

Update `loop.config.sh` consistently with the contract:
- `VERIFY_COMMANDS`: the deterministic success gate — commands you confirmed work
  in Step 1. All must exit 0 for the loop to succeed. If the task adds features,
  ensure the gate covers them (e.g. tests the loop is required to add must run here).
  Classify every command red→green vs stays-green (mirrored in the contract's
  Validation Commands): the harness snapshots each command's baseline status at
  run start (`.loop/baseline-verify.log`) and the evidence report shows the
  flip. A feature-adding contract whose gate is ALL stays-green does not
  discriminate — include at least one red→green command (typically the new
  tests the loop must write).
- A `run`-method criterion whose observation can be scripted becomes a probe
  command here (start the app, drive it headlessly, assert the observable
  behavior — a non-blank canvas, frames that differ over time, zero console
  errors — then exit). A probe the loop must write is a red→green command
  AND an in-scope deliverable of the contract (a gate that needs
  out-of-contract work makes the run unwinnable — the loop reverts such work
  as drift). Probes must be self-contained and self-terminating (start
  server → wait → observe → kill), and their feasibility in headless mode
  was proven by the Step 1.5 spike before being made binding.
  The harness exports `LOOP_ITERATION` and `LOOP_OBSERVATIONS_DIR` to every
  VERIFY_COMMAND — a probe that names its artifacts per iteration composes
  paths from those, and never parses `.loop/run-checkpoint` or any other
  harness-private file (not a stable interface; a probe hardwired to one
  misbehaves whenever it runs outside the loop). Artifact names are
  descriptive slugs — the checklist row citing the path carries the AC
  binding, so the run-scoped AC id stays out of the probe's source.
  VERIFY_COMMANDS are re-run via /bin/sh by the external evaluator — an
  agent skill or MCP connector can never appear here, so an
  agent-browser-channel check exists only as a `run` checklist row, never
  as a VERIFY_COMMAND. A browser-test command (e.g. Playwright) belongs
  here only as project tooling; when adding it needs a new dev-dependency,
  the contract must explicitly license that addition (otherwise the loop
  hits ESCALATE_PATHS mid-run on the manifest).
- `DENIED_PATHS`: secrets, prod config, anything requiring approval before touching
- `ESCALATE_PATHS`: dependency manifests, migrations, public API surface. Also
  consider agent-instruction files the task does not explicitly target (e.g.
  `CLAUDE.md`, `AGENTS.md`) — an autonomous loop should not silently rewrite
  the instructions future sessions will read
- `MAX_ITERATIONS`, `MAX_ITER_SECONDS`: scale to task size with this rubric —
  deviations are fine, but state the reason in the contract prose so the
  contract reviewer can audit the number instead of guessing:
  - `MAX_ITERATIONS` ≈ max(6, 2 × REQ count + red→green command count); add
    ~50% for a 0→1 build or unfamiliar territory. If the estimate exceeds
    ~20, do not inflate the budget — the task is telling you it should be
    decomposed (fleet), so propose that instead.
  - `TIMEOUT_IMPLEMENT` (in loop.config.sh): if the verify suite you actually
    ran in Step 1 takes minutes (heavy build/tests), set 1800–2400 so a
    legitimate heavy iteration is not watchdog-killed; otherwise keep the
    default `MAX_ITER_SECONDS`.
  - Stop heuristics (`STAGNATION_N` / `REPEAT_FAIL_N` / `FUTILE_N` /
    `MET_FORCE_N`): keep the defaults unless the task gives a concrete
    reason; record any change and its reason in the contract prose.
- `MAX_COST_USD`: leave EMPTY (no cap — subscription usage has no per-token
  charge). Set a number only if the user explicitly asked for a hard USD cap
  (API-billed usage). In auto mode never invent a cap; leave it empty and note
  the choice under `## Assumptions (auto mode)`.
- Leave `REVIEW_MODE`/`STOP_EVAL` at their defaults unless the user asked otherwise

If the task is small/mechanical, suggest cheaper models in `loop.models.sh`
(MODEL_IMPLEMENT / MODEL_REVIEW) — but only mention it; the default is a
heavyweight model for implementation and review, lightweight for stop evaluation.

## Step 5 — Present the loop definition and iterate until the user is satisfied

Show the COMPLETE loop definition in the conversation:
- Goal + each REQ (one line each) + Non-goals
- The verify gate (VERIFY_COMMANDS), what it proves, and each command's
  expected baseline (red→green / stays-green)
- Diff policy (denied / escalate paths)
- Budgets (iterations / USD / per-call timeout) and review settings
- Model roles in effect (from loop.models.sh)
- The unknowns summary: questions asked, what was deferred on defaults, any
  spike results (details: `.loop/docs/unknowns.md`)
- The acceptance checklist: row count per REQ and the verification-method
  split (cmd / run / human), with any `human` rows AND any unproven
  agent-browser-channel `run` rows called out explicitly — the latter with
  their runtime consequence: if the executing agent has no browser
  skill/connector, the loop stops there and asks
  (details: `.loop/docs/acceptance-checklist.md`)

If the definition is large or the user is visual, also render it as one
self-contained HTML summary under `.loop/reports/` and `./loop.sh open` it (per the
**Loop Definition** skeleton under "Contract-session pages"); for a short definition
the conversation alone is enough.

Then ask: "Do you approve this loop definition? Tell me anything you would like changed."
(Phrase it in the user's language — see "Output language" above.)
Apply any corrections the user gives and re-present, repeating until they are
satisfied. When they say it looks good, tell them to **exit this session** — the
`loop.sh` wrapper will then ask for final approval (`y`) and start the loop.
(Manual fallback: `./loop.sh approve && ./loop.sh run`.)

Do NOT start implementing. Do NOT run `loop.sh approve` yourself — approval is the
human's act, performed outside this session.
