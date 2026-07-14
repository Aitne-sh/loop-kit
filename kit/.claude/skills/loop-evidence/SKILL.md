---
name: loop-evidence
description: Generate .loop/docs/evidence-report.md for a completed loop run — the compressed artifact a human reviews instead of the full diff. Invoked by loop.sh when the loop reaches a reviewed success candidate; argument is baseline=<git ref> marking the task's fixed starting commit.
disable-model-invocation: true
---

# Generate the Evidence Report

The loop has a reviewed success candidate: verification passes, the success
gate was reached (the implementer declared ready, or the harness forced the
gate after consecutive MET stop evaluations), and, where review is enabled,
the independent reviewer approved. Produce the report that lets a human review
**evidence instead of diffs**. Report what the diff actually shows, not what
the goal hoped for.

The skill argument contains `baseline=<ref>` — the first commit for this task —,
`logs=<path>` — the only task/run log namespace you may inspect —,
`task=<task-id>`, and an `html=` token (`on`, `off`, or `auto`), which controls
whether you ALSO write the HTML view (see "Write the HTML view" below).

## Authority boundary

This report is a **non-authoritative view**, not a certification input and not
permission to declare `SUCCESS`. Do not alter the contract, ledgers, checklist,
requirement verdicts, verify logs, observations, manifest, approval records, or
any other gate/certificate input. After this skill returns, the harness validates
those inputs and observation files, binds their hashes in `certification.json`,
and appends the machine result to the report. Describe that result; never replace
it with a model-authored claim.

## Output language

Write the evidence report and the HTML view in the **same language as
`.loop/docs/product-contract.md`** (it mirrors the user's original instruction) —
this is the human's routine review surface, so it must read in their language.
Keep in ASCII, untranslated: `REQ-xxx` identifiers, the VERIFY_COMMAND command
strings and their pass/fail results, file paths, and git refs.

## Gather

1. `.loop/docs/product-contract.md` — requirements and acceptance criteria
2. `git diff --stat <baseline>` and `git diff <baseline>` — the real change
   (read files directly where the diff is unclear)
3. `.loop/last-verify.log` — the evaluator's own verification output
3.5. `.loop/baseline-verify.log` — the harness's run-start snapshot of the same
   gate (per-command `[PASS]`/`[FAIL]` before any iteration ran). Absent on
   older runs and at the fleet integration gate — then the baseline is "n/a";
   never invent it
4. `.loop/docs/requirements-ledger.md` and `.loop/req-verdicts` — the loop's
   per-REQ status self-report and the gate reviewer's parsed per-REQ verdicts
   (the independent judgment; where the two disagree, say so)
4.7. `.loop/docs/acceptance-checklist.md` — the fine-grained expected
   behaviors (AC rows) with verification method, final status, and evidence;
   `run` rows cite observation artifacts under `.loop/observations/`
5. `.loop/docs/assumptions.md` — mid-run discoveries, the defaults chosen, and
   the gate reviewer's adjudication (in the gate review log)
5.5. `.loop/docs/unknowns.md` — the intake unknowns record (questions asked,
   deferred defaults, direction verdicts), if filled in
6. `.loop/docs/spec-drift-report.md` and `.loop/docs/progress.md`
7. The exact directory passed as `logs=<path>` for review verdicts if useful
   context. **Do not inspect or cite any sibling/parent log directory**: those
   belong to another task or run and are historical, not evidence for this one.
   This is a prompt/citation policy plus a harness integrity boundary, not an OS
   sandbox: with the same UID and full Bash those paths may be physically readable.
   Physical readability does not make them authorized evidence.

## Write .loop/docs/evidence-report.md

Replace the template (remove the `<!-- TEMPLATE -->` marker):

1. **Requirements addressed** — each REQ-xxx with one line of evidence
   (file/behavior/test proving it) and the gate reviewer's verdict for it
   (from `.loop/req-verdicts`). Flag any requirement NOT fully addressed and
   any disagreement between the ledger's claim and the reviewer's verdict.
2. **Changed files** — grouped, with one-line purpose each
3. **Verification executed** — table of each VERIFY_COMMAND with its baseline
   status (from `.loop/baseline-verify.log`; "n/a" when that log is absent)
   and its final result (from `.loop/last-verify.log`), so a red→green flip is
   visible per command — the runtime proof that the gate discriminates. Report
   what the logs show; do not re-claim. Then, when
   `.loop/docs/acceptance-checklist.md` is filled in, a second table: each
   AC row | its REQ | method (`cmd`/`run`/`human`) | final status | evidence
   — for `run` rows name the observation artifact
   (`.loop/observations/...`) that proves it; a row without one is reported
   as a gap, not smoothed over
4. **Starting unknowns & assumptions made** — first the unknowns the run
   STARTED with (from `.loop/docs/unknowns.md`: questions asked, deferred
   defaults, direction verdicts — so the reviewer begins where the definition
   did), then every AS-N entry from `.loop/docs/assumptions.md`: the gap
   discovered, the default chosen, and how the gate reviewer adjudicated it
   (sound/unsound/escalated). Or "None". These are decisions made without the
   human — they must never be invisible at review time.
5. **Spec diff** — the drift table, verified against the actual diff (not just
   copied from the drift report; correct it if the diff disagrees). A
   `Drift detected: yes` with `Human decision required: no` is a *locally-handled*
   drift (reality diverged, no contract change) — report it plainly, not as a
   failure; only an unresolved contract-touching drift is a problem.
6. **Risks** — anything a human should manually QA, hardcoded-looking values,
   suspicious test-shaped special cases, coverage gaps
7. **Points needing human judgment** — or "None"
8. **Lessons for future runs** — 3–7 bullets a FUTURE run should reuse:
   non-obvious design decisions and why, approaches tried and rejected,
   repository traps discovered (build quirks, flaky checks, hidden couplings).
   Written for a reader with zero context on this run — name files and
   commands, not "the issue above". Or "None". This report is archived to
   `.loop/docs/run-archive/` when the next task is defined, and later
   contract/plan sessions read this section as intake — it is the run's only
   channel to future runs.

Be honest and specific: this report is the human's routine review surface, but
it is not certification authority. A hedged, vague report is worse than none.

## Write the HTML view — `.loop/reports/evidence.html` (only if the `html=` token allows it)

If the argument contains `html=off`, skip this section entirely and emit no
marker. If it contains `html=auto`, first apply the "When to author (html=auto)"
rubric below (for this surface, R5 — Complex-run evidence — is the usual test);
when no rubric item applies, skip the page and emit the `skipped` marker.
Otherwise, after the markdown is finished, write the **same evidence** as a
single self-contained HTML page at `.loop/reports/evidence.html` — the review
surface a human opens with `./loop.sh report`. The evidence is table-heavy and
comparison-heavy, which is exactly where an HTML view reads far better than a
wall of markdown.

Rules for the page (non-negotiable):
- **Self-contained and fully offline.** Inline all CSS. Make **no external
  requests of any kind** — no CDN, web fonts, images, analytics, `fetch`/`XHR`.
  A viewer with no network must see the identical page. Prefer **no JavaScript**;
  if you add any it must be inert and offline (e.g. a light/dark toggle), never
  network-bound. This is both an offline guarantee and a safety boundary.

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

### Evidence Report — required sections (fixed order)

Badge `Evidence Report` (green — a verified success candidate: verification passed and
the reviewer approved). The same page also covers a **NO_OP** outcome (verify already
passed with no code change needed) — then *Changed files* is "None" and the Result
summary says plainly that nothing needed changing. Provenance mirrors
`evidence-report.md`; include the iteration number, total cost, the baseline ref, the
**reviewed HEAD sha** (`git rev-parse HEAD` at evidence time — the commit this report
attests to), and the **approved contract hash** (`.loop/approved` if present, else
`cat .loop/docs/product-contract.md loop.config.sh | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; }`). Compute these
yourself from the shell; write "n/a" only if a source is genuinely absent.
Sections, top to bottom (the names are structural identifiers — render every
on-page heading in the contract language):

1. **Framing header** (Explanation) — the six framing elements, as natural prose
   in the contract language. The why-now content: verification passed and the
   independent review approved, so the work is ready for the human to judge. In
   the banner show ONE **merge-readiness pill** — "verify PASS · review APPROVE"
   (every VERIFY_COMMAND passed in `.loop/last-verify.log` and the reviewer
   verdict was APPROVE) — followed by at most one short sentence noting that the
   final `SUCCESS` verdict is stamped by the external evaluator after this
   report. Never author `SUCCESS` as the pill, and never expand that caveat into
   a paragraph.
2. **Result summary** (Explanation) — 2–3 plain sentences: what the loop set out to
   do and that it is now verified-passing. A summary, not a wall.
3. **Requirements addressed** (Data) — table: `REQ-xxx` | one-line evidence (file /
   behaviour / test) | status | the gate reviewer's verdict (from
   `.loop/req-verdicts`). Flag any requirement not fully addressed and any
   ledger-vs-reviewer disagreement.
4. **Verification executed** (Data) — table: command | baseline | final result,
   PASS/FAIL as distinct pills; the baseline column comes from
   `.loop/baseline-verify.log` (a neutral "n/a" pill when that log is absent),
   the final column verbatim from `.loop/last-verify.log` — a red→green row is
   the strongest evidence the gate discriminates. Caption it "run by the
   evaluator, not the agent." Include a representative excerpt of the actual
   command/test output from `.loop/last-verify.log` inside a `<details>` (the raw
   evidence behind the pills) — the table stays readable without expanding it.
   When `.loop/docs/acceptance-checklist.md` is filled in, follow with the
   acceptance-checklist table (AC | REQ | expectation | method | status |
   evidence, status as pills) and embed the observation artifacts `run` rows
   cite (screenshots per the Visual-evidence rule: `data:` URIs, or saved
   beside the page under `.loop/reports/` with a caption) — the human must be
   able to SEE what the loop observed, not just read that it observed.
5. **Changed files** (Data) — grouped by area, one-line purpose each. For the changes
   that carry the core behaviour, include a representative **diff hunk** (not the whole
   diff) inside a `<details>`, so the reviewer sees the actual edit as evidence, not
   only a summary. The grouped summary stays visible without expanding.
6. **Starting unknowns & assumptions made** (Data) — open with a caption line
   summarizing the intake unknowns (questions asked / deferred defaults /
   direction verdicts from `.loop/docs/unknowns.md`), then the table: `AS-N` |
   the gap | the chosen default | the gate reviewer's adjudication (sound /
   unsound / escalated). Or "None". Decisions taken without the human must be
   visible at review time.
7. **Spec diff** (Data) — the drift table (Product requirement / API contract / Data
   model / UX behaviour / Security boundary | Changed? | Notes), corrected against the
   actual diff.
8. **Risks** (Data) — manual-QA items, hardcoded-looking values, suspicious
   test-shaped special cases, coverage gaps. "None" only if genuinely none.
9. **Points needing human judgment** (Data) — or "None".
10. **Lessons for future runs** (Explanation) — mirror section 8 of
    `evidence-report.md`: the bullets a future run should reuse. Or "None".

Do not modify any other file besides `.loop/docs/evidence-report.md` and (when
the `html=` token allows authoring) `.loop/reports/evidence.html`. In particular,
do not touch `.loop/agent-state`, ledger/checklist files, `.loop/req-verdicts`,
verify logs, observations, their manifest, approval records, or code. Those are
authority inputs that the harness validates after this report is written.
