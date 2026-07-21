[← loop-kit](../README.md) · **Running roles on Codex**

> Any headless role can run on the Codex CLI instead of Claude Code — including a
> fully Claude-less deployment. This page covers routing keys, sandbox posture,
> and the honest residuals.

# Running roles on Codex

Claude Code is required only for the interactive surfaces: a TTY `./loop.sh start`
definition session and `./loop.sh refine` always launch Claude. Every headless surface can
route to Codex — including the headless definition pass (`auto`, no-TTY `start`, fleet
workers) via `AGENT_CONTRACT` — so a fully headless project can run with **no Claude CLI
installed at all**. Codex routing is optional and requires either a ChatGPT subscription
usable by Codex or an `OPENAI_API_KEY`. Install a current Codex CLI and authenticate it
with `codex login`; for API-key authentication, use
`printenv OPENAI_API_KEY | codex login --with-api-key`. A custom executable or test double
can be selected with `LOOP_CODEX_CMD=/path/to/codex`.

`init` and `update` install Codex-native repository skills under
`.agents/skills`. All thirteen projected skills can be invoked explicitly by their
`$loop-*` name; `$loop-contract` and `$loop-plan` also allow implicit matching,
while the eleven harness-internal skills disable implicit invocation. The harness
still points each headless Codex call at the approved `.agents/.../SKILL.md`
directly, so a user-global skill with the same name or a client discovery setting
cannot silently change the loop. `loop-refine` is not projected because that
surface always runs interactively in Claude Code.

| Surface | Claude-less operation |
|---|---|
| `./loop.sh run` / `resume` (single loop) | Yes — route every `AGENT_<ROLE>` to codex (a hand-written or pre-generated contract needs no model to `approve`) |
| `./loop.sh auto` / no-TTY `start` | Yes — additionally set `AGENT_CONTRACT="codex"` |
| Fleet orchestration | Yes — with `AGENT_CONTRACT="codex"` workers define their task contracts on Codex; otherwise the orchestration entry refuses and names `run --single` |
| Interactive `./loop.sh start` / `refine` | No — always launches Claude Code. Claude-less equivalents: define with `./loop.sh auto "<instruction>"`; instead of `refine`, mark the `human` acceptance rows `verified` in `.loop/docs/acceptance-checklist.md` and `./loop.sh resume` (both errors name these paths) |

Route implementation to Codex while leaving planning and review on Claude:

```sh
# loop.models.sh
AGENT_IMPLEMENT="codex"
MODEL_IMPLEMENT="gpt-5.5"
```

Or additionally hand the evidence report (and any HTML views it authors) to Codex,
keeping Claude for planning and review:

```sh
# loop.models.sh
AGENT_IMPLEMENT="codex"
MODEL_IMPLEMENT="gpt-5.5"
AGENT_EVIDENCE="codex"
MODEL_EVIDENCE="gpt-5.5"
```

The routable keys are `AGENT_IMPLEMENT`, `AGENT_PLAN`, `AGENT_REVIEW`,
`AGENT_REVIEW_INTERIM`, `AGENT_STOP_EVAL`, `AGENT_EVIDENCE`, `AGENT_DECOMPOSE`,
`AGENT_SUPERVISE`, `AGENT_ROLLBACK`, and `AGENT_CONTRACT` (headless definition only —
interactive sessions stay on Claude). Unset or unrecognized values safely fall back to
`claude`; `AGENT_REVIEW_INTERIM` inherits `AGENT_REVIEW` when empty. A Codex-routed
role must use a Codex model slug rather than `opus`, `sonnet`, `haiku`, `fable`, or a
`claude-*` model name.
Agent inheritance does not overwrite the independently tiered
`MODEL_REVIEW_INTERIM`: when routing `AGENT_REVIEW` to Codex, also set
`MODEL_REVIEW_INTERIM` to a Codex slug (or explicitly route interim review elsewhere).

| Role mode | Claude route | Codex route |
|---|---|---|
| Reader (review/checker roles) | `Read,Glob,Grep` only | Forced `--sandbox read-only` and `project_doc_max_bytes=0` |
| Full (implementation and authoring roles) | `PERMISSION_MODE` plus `ALLOWED_TOOLS` / `DISALLOWED_TOOLS` | `LOOP_CODEX_SANDBOX` (`workspace-write` by default) |

Disabling project-doc loading on Codex reader roles prevents a changed repository
`AGENTS.md` from becoming higher-priority checker instructions. A checker may
still read it explicitly as repository evidence, but its read-only role and
verdict contract remain authoritative. Full Codex roles retain normal project
guidance.

`LOOP_CODEX_NETWORK=1` enables network access only for commands inside Codex's
`workspace-write` shell sandbox; set it to 0 to retain that sandbox's
network-blocked default. It does not configure or disable MCP servers, connected
apps, or hosted search capabilities exposed by the Codex client. Control those
separately in the environment. On macOS the `workspace-write` seatbelt also denies
Mach port *registration*, so GUI/browser processes cannot start inside a
Codex-routed session even with network access on — Chromium, for example, aborts
at launch with `bootstrap_check_in … MachPortRendezvousServer: Permission denied
(1100)`. This is expected, not a misconfiguration: browser-driven verification
belongs in `VERIFY_COMMANDS`, which the deterministic evaluator re-runs *outside*
the agent session every iteration, so the probe still executes and its artifacts
still count at the gate (see `docs/iteration.md`). Do not reach for
`danger-full-access` just to let the agent launch a browser it never needed to
launch. `danger-full-access` removes the Codex OS sandbox
and should be used only inside an environment you already isolate. Under
`workspace-write`, Codex itself recursively protects `.agents/` and `.codex/`
from writes; loop-kit's approval hash and diff policy enforce the same control
plane across providers. Claude Code's `DISALLOWED_TOOLS` rules do **not**
constrain Codex-routed roles. `./loop.sh approve` warns when a Codex route and a
non-empty deny-list coexist.

In an orchestrated fleet the parent's approved `LOOP_CODEX_SANDBOX` / `LOOP_CODEX_NETWORK`
also travel to every worker as environment fallbacks: a worker whose regenerated
`loop.config.sh` omits the keys degrades to the parent's approved posture, not to the
harness default (a worker file that still defines a key keeps its own approved
value). The approved `.agents` skills and repository `.codex/**` control plane are
also copied byte-for-byte into each Fleet worktree.

Codex does not report a USD amount in the normalized result, so Codex calls are journaled
with cost 0. Reported USD totals and `MAX_COST_USD` therefore cover Claude calls only; the
harness warns when a USD cap is combined with Codex routing, but cannot enforce that cap
against Codex usage. The raw Codex JSONL remains available for usage auditing.

A useful maker–checker split is Codex for `IMPLEMENT` and Claude for `REVIEW`: independent
vendors reduce the chance that one model family's blind spot appears on both sides. This is
additional diversity, not a substitute for the deterministic evaluator re-running every
approved `VERIFY_COMMAND`.

The adapter normalizes Codex JSONL by event type regardless of key order, and a
`turn.failed` event fails the iteration even when the process exits 0. After a
major Codex CLI upgrade, re-run the regression suite because the external event
schema and authentication probes can still change. A Codex-routed `REVIEW`
judging screenshot observations (`run`-method acceptance rows) also depends on
the selected Codex model/client being able to inspect the cited image; verify
that capability for image-heavy contracts or keep `AGENT_REVIEW` on Claude.
