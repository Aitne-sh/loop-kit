# loop.models.sh reference (setup dictionary)

This is the dictionary the setup session reads to explain settings. It is the
authoritative source for what each knob means and which values are legal — answer
the human from here, do not go looking through code.

## What the loop is (one paragraph)

The loop turns an agent into a contract-driven cycle: **implement → verify → review
→ improve**, with fresh context each iteration, until every requirement is met or it
stops for a human. Each phase is a distinct role. `loop.models.sh` chooses **which
agent CLI (Claude Code or Codex) and which model** runs each role. It is parsed as
plain `key="value"` data — never executed — and lives **outside** the approval hash,
so changing it takes effect immediately and needs no re-approval. (The contract and
its stop conditions live in `loop.config.sh`, which setup does **not** touch.)

## The phase roles

| Role | Key stem | When it runs | Frequency / cost |
|---|---|---|---|
| Contract | `CONTRACT` | Headless contract definition (auto / no-TTY start, fleet workers). Interactive `start`/`refine` always use Claude regardless. | Once per definition |
| Plan | `PLAN` | Implementation planning at iteration 0 | Once per run |
| Implement | `IMPLEMENT` | Implementation & improvement, every iteration | Highest — the big cost lever |
| Review | `REVIEW` | Gate + decompose + contract reviews (the independent checker / certification) | Every gate |
| Review (interim) | `REVIEW_INTERIM` | Interim steering reviews after each CONTINUE iteration only. Empty = inherit `REVIEW`. Never weakens a certification check. | Highest-frequency review |
| Stop-eval | `STOP_EVAL` | Advisory MET/FUTILE/CONTINUE call, every iteration | Every iteration — clerical, keep cheap |
| Evidence | `EVIDENCE` | Evidence-report authoring | Once near the end |
| Decompose | `DECOMPOSE` | Fleet supervisor: master contract → task plan | Fleet only |
| Supervise | `SUPERVISE` | Fleet supervisor: mid-run decisions on escalated tasks. Codex here disables supervisor session reuse (fresh calls). | Fleet only |

## The knobs

### `AGENT_<ROLE>` — which CLI runs the role
- Legal values: `"claude"` (default) or `"codex"`. Empty or removed = claude.
- A typo or unknown value **degrades to claude** — it can never kill a running loop.
- Roles: `AGENT_IMPLEMENT`, `AGENT_PLAN`, `AGENT_REVIEW`, `AGENT_REVIEW_INTERIM`
  (empty = inherit `AGENT_REVIEW`), `AGENT_STOP_EVAL`, `AGENT_EVIDENCE`,
  `AGENT_DECOMPOSE`, `AGENT_SUPERVISE`, `AGENT_CONTRACT`.
- Note: `AGENT_CONTRACT` governs the **headless** definition path only; interactive
  `./loop.sh start` and `./loop.sh refine` always launch Claude Code.

### `MODEL_<ROLE>` — which model runs the role
- A **Claude alias/name** (`opus`, `sonnet`, `haiku`, or a full `claude-*` name) when
  the role is on Claude, **or** a **Codex model slug** (e.g. `gpt-5.5`, `gpt-5.6-sol`)
  when the role is on Codex.
- **Agent/model consistency is enforced.** If `AGENT_<ROLE>="codex"`, its
  `MODEL_<ROLE>` must be a Codex slug — a Claude alias is rejected at setup/preflight.
  Conversely a Claude role must use a Claude alias, not a `gpt-*` slug.
- Defaults: `CONTRACT`/`PLAN`/`IMPLEMENT`/`REVIEW`/`DECOMPOSE`/`SUPERVISE` → `opus`;
  `EVIDENCE`/`REVIEW_INTERIM` → `sonnet`; `STOP_EVAL` → `haiku`.
- Maker-checker note: implement and gate-review default to the same model. The
  separation is procedural (fresh context, read-only), not statistical. For diversity
  against a shared blind spot, point `MODEL_REVIEW` at a different family/tier.

### `LOOP_EFFORT` and `EFFORT_<ROLE>` — reasoning effort
- Legal values: `low | medium | high | xhigh | max` (`max` maps to Codex `xhigh`).
- `LOOP_EFFORT` is the global default for every role and the interactive sessions.
- `EFFORT_<ROLE>` overrides `LOOP_EFFORT` for one role. Empty/removed/unrecognized =
  inherit `LOOP_EFFORT` (a typo here can never break a running loop — it falls back).
- Claude receives `--effort`; Codex receives `model_reasoning_effort`. Higher = more
  thinking per call = more cost. Ship clerical roles (`STOP_EVAL`, `EVIDENCE`) cheaper;
  `EFFORT_IMPLEMENT` is the biggest lever — measure quality before lowering it.

### `TURNS_NUDGE_AT` — runaway-context signal
- Digits only; empty or removed = off. When one implement call consumes at least this
  many agent turns, the next iteration gets an advisory nudge to re-plan/split rather
  than resume mid-flight. Default `70` (~p90 of healthy iterations). If the nudge fires
  on more than ~1 in 4 iterations, it is set too low — raise it.

## Common recipes
- **Plan/review on Claude, implementation on Codex:** `AGENT_IMPLEMENT="codex"` +
  `MODEL_IMPLEMENT="gpt-5.5"`, leave the rest on Claude.
- **Cheaper interim reviews with cross-tier diversity:** `MODEL_REVIEW_INTERIM="sonnet"`
  (the default) while `MODEL_REVIEW` stays `opus`.
- **All-Codex:** set every `AGENT_<ROLE>="codex"` and every `MODEL_<ROLE>` to a Codex
  slug. (Interactive `start`/`refine` still need Claude; headless `auto` does not.)

## What the harness rejects (so you keep the file legal)
1. Any non-comment line that is not exactly `KEY="value"` (uppercase key, double quotes).
2. A value containing `` ` ``, `$(`, or `${` (command substitution / expansion).
3. An unknown key (not one of the roles/knobs above).
4. `AGENT_<ROLE>` that is not `claude`, `codex`, or empty.
5. A Codex role (`AGENT_<ROLE>="codex"`) whose `MODEL_<ROLE>` is a Claude alias — or a
   Claude role whose model is a `gpt-*` slug.
6. An effort value outside `low|medium|high|xhigh|max`, or a non-numeric `TURNS_NUDGE_AT`.
