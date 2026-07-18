---
name: loop-refine
description: Interactive design-gate refinement session for a loop that is paused (BLOCKED) at a human aesthetic/visual sign-off. Help the human adjust the REVERSIBLE, within-contract knobs (tunable constants) and preview the result live, keeping the frozen contract, the representation, and every cmd/run acceptance check untouched. Invoked by ./loop.sh refine; not for headless loop iterations.
---

# Interactive refinement at a human sign-off gate

The loop has stopped **BLOCKED** because the only acceptance rows left are `human`
method — a real-browser aesthetic / visual sign-off the loop cannot certify itself.
The human is now in the room with you. Your job is to help them **converge on the
look/feel by adjusting reversible, within-contract knobs and previewing**, so they
can sign off — NOT to do a fresh loop iteration and NOT to certify anything.

The skill argument (if any) is the human's opening note about what to change.

## Hard boundaries (never cross these)

- **The contract is immutable.** Never edit `.loop/docs/product-contract.md`,
  `loop.config.sh`, `loop.models.sh`, `loop.sh`, anything under `.claude/`,
  `.agents/`, `.codex/`, or `.loop/bin/`, or any `DENIED_PATHS`.
- **Touch only reversible, within-contract knobs** — the tunable constants the
  decision request calls out (e.g. drift/rate/amplitude/exponent parameters), and
  only those. Keep every change small and trivially reversible.
- **Never change representation or contracted structure**: colours, sizes, shapes,
  materials, the required elements a REQ or a **verified** acceptance row locks in.
  These are what the contract froze.
- **Never mark a `human` acceptance row `verified` yourself, never write
  `.loop/agent-state`, never declare a loop state, never run the success gate.**
  The human signs off (via `./loop.sh refine`'s confirm, `./loop.sh signoff`, or
  by editing the row); the closing `./loop.sh resume` re-runs the evaluator and
  the independent reviewer.

If the human asks for something that would **remove or change a REQUIRED behavior**
(a verified AC, a REQ, or a Non-goal) — for example deleting an element the contract
mandates — **stop and say so plainly**: that is a *contract change*, not a tweak.
Tell them to end this session (Ctrl-C / `/exit`) and run the contract skill
(Claude Code: `/loop-contract`; Codex: `$loop-contract`) to revise and re-approve
the contract; the loop will then implement it. Do not do it here, and do not
re-litigate a decision the contract already settled.

## What to do

1. **Read the ask first.** Read `.loop/docs/decision-requests.md` (what the human
   must look at, and the exact knobs it lists as reversible),
   `.loop/docs/acceptance-checklist.md` (which rows are `human` and still `pending`),
   and `.loop/docs/product-contract.md` (so you know what is frozen). Skim the code
   that owns the knobs so you change the right constant.
2. **Converge in a tight loop with the human:**
   - Make the smallest constant change that moves toward what they describe.
   - **Keep the objective checks green:** run the project's `VERIFY_COMMANDS` after a
     change; if a `cmd`/`run` acceptance test goes red, the tweak left the contracted
     envelope — revert or adjust, and tell the human why. Never leave tests red.
   - **Tell them exactly how to see it**: the command to launch/refresh the app and
     the precise place to look (which section, what to scroll to, what to compare).
   - Iterate on their reaction ("more/less", "slower/faster"). Stay on the knobs.
3. **Do not over-reach.** No refactoring, no new features, no "while I'm here"
   changes. One aesthetic axis at a time, reversible, tests green.

## Ending

When the human is satisfied they will end the session (Ctrl-C / `/exit`). Before
that, briefly remind them of the two exits:

- **Happy** → `./loop.sh refine` will offer to sign off the `human` row(s) and run
  `./loop.sh resume` to re-certify (or they mark the rows `verified` and resume).
- **Needs a contracted behavior changed** → use the contract skill (Claude Code:
  `/loop-contract`; Codex: `$loop-contract`), then `./loop.sh approve` — not a
  resume note.

Leave the working tree with your reversible tweaks in place and tests green; the
closing resume verifies and certifies. Do not commit, and do not run the gate.
