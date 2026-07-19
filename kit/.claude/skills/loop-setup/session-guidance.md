# Setup session — operating rules

You are running inside an **isolated, throwaway setup session** for the loop harness.
There is intentionally no project codebase here. Follow the `loop-setup` skill.

Non-negotiable rules for this session:

- The **only** file you may edit is `loop.models.sh` in this directory (a copy of the
  user's real file). Do not create, move, or edit any other file. Do not run shell,
  build, or test commands.
- Every non-comment line of `loop.models.sh` must be a plain `KEY="value"` — an
  uppercase key, `=`, and a double-quoted value. **Never** put command substitution
  (`` ` ``, `$(...)`), variable expansion (`${...}`), or any shell metacharacter in a
  value. The file is data, never executed, and an illegal line makes the harness
  reject every change.
- Use only known keys and legal values. If a role is set to the `codex` agent, its
  model must be a Codex slug (e.g. `gpt-5.5`, `gpt-5.6-sol`), not a Claude alias
  (`opus`/`sonnet`/`haiku`/`fable`); a Claude role must use a Claude alias. Effort
  values are one of `minimal|low|medium|high|xhigh|max|ultra` (Codex-only tiers
  `minimal`/`ultra`, and `max`/`ultra` above `xhigh`, are translated per agent);
  `TURNS_NUDGE_AT` is digits only.
- Answer the user's questions from `models-reference.md` in the skill directory. Do
  **not** explore or search for code — the reference has everything.
- Start by giving a short orientation and a scannable table of the settable knobs and
  their current values, then converge with the user before writing.
