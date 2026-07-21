---
name: loop-setup
description: Interactive first-run tuning of the per-phase agent and model routing (loop.models.sh) before a loop is run. Explain the loop and the settable knobs, answer the human's questions from a bundled reference (never by exploring code), converge on the values they want, and edit only the loop.models.sh copy in this working directory using plain key="value" lines. Invoked by ./loop.sh setup in an isolated throwaway directory; the harness deterministically validates the result before it reaches the real file.
disable-model-invocation: true
---

# Interactive setup: tune agent + model routing

The human wants to tune **which agent (Claude or Codex) and which model runs each
phase** of the loop, before they start running it. You are in a throwaway working
directory that holds a **copy** of their `loop.models.sh`. Your job is to explain
the choices, answer questions, and edit that copy to the values they want — nothing
else. After you exit, the harness re-reads the copy, validates it deterministically,
and only then reflects it into their real `loop.models.sh`.

The skill argument (if any) is the human's opening note.

## Hard boundaries (never cross these)

- **Edit only `loop.models.sh`** (the copy in this directory). Never edit anything
  else, never create files, never run shell/build/test commands. There is no wider
  codebase here on purpose.
- **Only plain `KEY="value"` lines.** Every non-comment line must be an uppercase
  key, `=`, and a double-quoted value — nothing else. **Never** use command
  substitution (`` ` ``, `$(...)`), variable expansion (`${...}`), or any shell
  metacharacter in a value. This file is parsed as data, never executed; the
  validator rejects anything that is not a plain key=value.
- **Only known keys and legal values** (see the reference). An unknown key, an
  illegal agent/model/effort value, or a Codex role pointed at a Claude model will
  be **rejected by the harness** and none of your changes will be applied. Keep the
  file loadable at all times.
- **Do not explore or search for code to answer a question.** Everything you need is
  in the bundled reference. Reading anything else wastes the human's money.

## What to do

1. **Read the reference first:** `.claude/skills/loop-setup/models-reference.md`
   (the same file ships under `.agents/skills/loop-setup/` for Codex). It is the
   dictionary of every role, key, and legal value. Do not read anything else.

2. **Open with a short orientation** (2-4 sentences), then a **settable-items table**
   the human can scan. Present it as a table with columns: **Key**, **Legal values**,
   **What it controls**. Cover the knob families: `AGENT_<ROLE>` (claude | codex),
   `MODEL_<ROLE>` (a Claude alias or a Codex slug), `EFFORT_<ROLE>` / `LOOP_EFFORT`
   (minimal..ultra), and `TURNS_NUDGE_AT`. List the phase roles (contract, plan, implement,
   review, review-interim, stop-eval, evidence, decompose, supervise, rollback) and show the
   current value from the copy alongside each, so they see what they have now.

3. **Answer questions from the reference.** When they ask what a setting means or
   which value to pick, quote/paraphrase the reference — its meaning, legal values,
   default, and any cost/quality trade-off. Keep answers short and concrete.

4. **Converge, then write.** Once the human states an intent, edit the copy:
   - Change only the values they asked for; **preserve the file's comments and
     structure**. To set a role that ships commented-out (e.g. `#AGENT_IMPLEMENT=""`),
     uncomment it and set the value.
   - **Enforce agent/model consistency as you go:** if you set `AGENT_<ROLE>="codex"`,
     `MODEL_<ROLE>` must be a **Codex slug** (e.g. `gpt-5.5`), never a Claude alias
     (`opus`/`sonnet`/`haiku`/`fable`). If a role stays on Claude, its model must be a Claude
     alias. Getting this wrong makes the harness reject the whole file.
   - Read the edited value back to the human and confirm it matches their intent.

5. **Do not over-reach.** No settings they did not ask about, no `loop.config.sh`
   changes (that is the contract's job, and it is not here), no commentary edits
   beyond uncommenting a key you are setting.

## Ending

When the human is done they exit the session (Ctrl-C / `/exit`). Remind them briefly:
their edits are validated by the harness on exit; if anything is illegal the real
`loop.models.sh` is left untouched and `./loop.sh setup` will report which line to
fix. On success the new routing takes effect immediately — no re-approval needed —
and they can define/run a loop with `./loop.sh start "<instruction>"`.
