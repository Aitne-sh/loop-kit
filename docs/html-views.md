[← loop-kit](../README.md) · **HTML views**

> At the three moments a human is actually looking, the harness can show a
> self-contained page in your browser. Markdown stays canonical.

# HTML views (reports, questions, mockups)

Loop-engineering theory is thorough about verifiers and stop conditions but nearly silent
on **how an agent should present results, evidence, and decisions to a human** — which is
exactly where loop-kit puts you. So at the three moments a human is actually looking, the
harness can show a self-contained HTML page in your browser:

- **Result reports** — the evidence agent can write `.loop/reports/evidence.html` alongside
  the Markdown; a successful interactive run opens it, and `./loop.sh report` reopens it any
  time (`--text` forces plain text).
- **Contract questions and directions** — during the interactive contract session the agent
  can build a page to explain a complex mechanism before you confirm it, or to show 2–3
  directions to choose between (UI mockups, or competing flow/architecture sketches).
- **Escalations** — a decision that's visual or architectural can be shown as
  `.loop/reports/decision.html`.

Whether a page gets authored is decided **by a rubric, not by a mode.** The model authors a
page only when at least one pre-declared rubric item applies — a genuine choice between
alternatives, an inherently visual subject, a structure that needs a diagram, an
architectural decision, or a genuinely complex run's evidence. A single color tweak never
qualifies; when in doubt, it's skipped. (`LOOP_HTML=1` forces pages on, `LOOP_HTML=0` off.)

<details>
<summary>Design and safety boundaries</summary>

- **The model authors the HTML; the shell only opens it.** There's no Markdown→HTML
  converter — Claude writes the page directly, in a session that's already open, so the
  common path costs no extra model call.
- **Markdown stays canonical; HTML is only a view.** The `.loop/docs/*.md` files (plus git
  history) are the tracked record; the HTML is a disposable view. If they ever disagree, the
  Markdown wins.
- **Written in your language.** The model detects the language of your instruction and writes
  the human-facing prose (contract, plan, evidence, decisions) in that language. The
  machine-parsed control lines (state tokens, config keys, `REQ-` ids) always stay ASCII, so
  localization never breaks the harness.
- **Answers always come back in the terminal.** There's no local server and no form round-trip.
- **Never unattended.** Automatic opens fire only in an interactive terminal with auto mode
  off — fleet and `auto` runs never pop a browser.
- Every page follows a fixed content contract (kept byte-identical across the authoring
  skills): an explanation zone (what this is, why you're seeing it, what you're asked) and a
  data zone (the evidence/options/definition), with a provenance footer pinning the exact
  commit and contract it's evidence for. It may show nothing that isn't already in the
  canonical Markdown, and it may not silently drop a section.
- **Reads like a report, not like a spec.** The contract's item names ("why now", section
  names) are instructions to the model, never on-page labels — the page is natural prose and
  headings in your language, internal jargon glossed on first use, and every page starts from
  one canonical inline style block so all pages of all runs share a single visual identity.
  `.loop/reports/` holds only user-facing pages and their assets — never scratch tooling.
- **Advisory lint.** After a page is authored the harness runs a small deterministic check
  (markdown residue in rendered text, missing `<html lang>`, missing/duplicate `<h1>`,
  placeholder text) and journals any findings as `HTML_LINT_WARN`. Like the authorship check,
  it never fails the run — a scruffy page is a presentation defect, not a contract breach.
- `./loop.sh open <file>` opens any page under the same rules; `LOOP_BROWSER_CMD` overrides
  the opener.

</details>
