[← loop-kit](../README.md) · **Safety and the security model**

> What the harness protects against, how it does it, and — just as importantly —
> what it does *not* provide and must come from your environment instead.

# Safety and the security model

## Safety and tamper defenses

The harness assumes the agent's own output is untrusted, and that repository content can try
to steer a session. So the pieces that decide success are protected from the pieces that do
the work. The short version:

- **You approve a hash, not a promise.** `approve` records SHA-256 hashes of the
  contract + config and of the harness (`loop.sh` / `evaluate.sh` / both managed
  skill trees) plus session control-plane files (`.claude/settings*.json`,
  `.mcp.json`, and every file under `.codex/`). Recursive inputs include each
  relative path as well as its contents, so adding, removing, renaming, or
  changing a control-plane file changes the hash. These baselines are loaded
  into the running script's memory and re-checked every iteration. Model and
  Fleet settings are intentionally editable without re-approval between runs;
  they are separately snapshotted at run start and protected from mid-run
  changes. The contract hash is checked before `loop.config.sh` is sourced, so
  tampered config code is not executed.
- **Approvals are anchored outside the repo.** Because everything under the repo is
  agent-writable, `approve` also records the hashes in a store outside the repository
  (`~/.loop-kit/approvals/…`, relocatable via `LOOP_APPROVAL_HOME`). A run refuses to start
  unless that off-tree store matches — repo-local files alone are no longer trusted.
- **The checkers are structurally read-only.** The reviewer, stop evaluator, contract review,
  and supervisor get only `Read,Glob,Grep` on Claude routes or Codex's OS-level `read-only`
  sandbox on Codex routes. Codex readers also disable automatic repository
  `AGENTS.md` loading, so candidate-authored project guidance cannot replace the
  checker role. The supervisor never writes anything itself: its decisions
  travel back as text and the *harness* performs every write, logging each one.
- **Nothing gets into SUCCESS unreviewed.** The evidence report is generated *after* the
  reviewer approves, and the harness's success gate then confirms there's zero code change
  (outside `.loop`) since the HEAD the reviewer actually looked at. Any later change is BLOCKED.
- **Certification is harness-generated.** On `SUCCESS`/`NO_OP`,
  `.loop/docs/certification.json` binds the task/run ids, contract and harness hashes,
  task/run baselines, reviewed HEAD, review verdict/scope, verify log, requirement verdicts,
  and observation manifest. A single-task certificate records `preflight: "PASS"` only
  after its deterministic preflight; the Fleet parent/integration certificate records
  `preflight: "NOT_APPLICABLE"` because that parent has no per-task checklist and instead
  relies on its integration review and final verify gate. The model-authored evidence report
  is a non-authoritative human-readable view. Certification authority comes from the
  harness's deterministic validation of those inputs and the hashes that bind the manifest,
  each cited observation's bytes, its AC anchor, and the product tree.

<details>
<summary>The full tamper-defense table</summary>

| Target | Defense |
|---|---|
| Contract + config | Approval hash held **in `loop.sh`'s memory**, passed to the evaluator each iteration (`--approved-hash`); forging `.loop/approved` has no effect. The hash check runs *before* the config is sourced, so tampered config code never executes. |
| Approval provenance | Also recorded in an **off-tree store** (`~/.loop-kit/approvals/<repo-id>/<slot-id>/`, where the ids are hashes of the repo's and the worktree's git paths — so fleet worktrees group under one repo but keep distinct slots); a run refuses to start (exit 2) unless the store matches. `LOOP_APPROVAL_HOME` relocates it; the literal value `repo` opts back into repo-local-only records for containers with no `$HOME`. Honest residual: this moves the trust boundary out of the repo, not out of your account — a `VERIFY_COMMANDS` entry still runs with your privileges. |
| The harness (loop.sh / evaluate.sh / managed skills) | A start-of-run hash kept in memory is re-checked every iteration, right after implementation (before the evaluator runs), and after evidence. A change → `RISK_REQUIRES_APPROVAL`; a tampered evaluator can never actually run. Skill edits are also caught by the diff policy on `.claude/**` and `.agents/**`. |
| Session control plane (`.claude/settings*.json` / `.mcp.json` / `.codex/**`) | Every relative path and file is folded into the harness hash and checked in memory each iteration, so an agent cannot add a hook, rule, permission allowlist, MCP server, or Codex project override that would take effect in a future session. Gitignored local copies are propagated byte-for-byte into Fleet worktrees. |
| Model config (`loop.models.sh`, `fleet.config.sh`) | Parsed as safe `key=value`, never sourced. Gitignored, so the diff policy alone wouldn't see edits — its hash is taken into memory at run start, and any change during a run → `RISK_REQUIRES_APPROVAL`. Editing between runs is free. |
| Observation manifest + certificate inputs | The evaluator-owned manifest is pinned in memory and may change only through a trusted preflight/canonicalization step. Before evidence generation, the contract, ledgers, reviewer verdicts, manifest, and cited observation bytes are snapshotted; any evidence-agent mutation is BLOCKED. Report citations are then resolved back through checklist + manifest + bytes. |
| Budget | The running Claude cost total lives in memory, so a file edit can't bypass it. With `MAX_COST_USD` set, each Claude call also gets `--max-budget-usd`. Codex exposes no equivalent USD amount/cap; its calls record 0 and trigger an explicit warning. |
| Master contract in worktrees | Each task gets a read-only copy whose expected sha256 the parent pins outside that task worktree; a mismatch is restored and journaled `MASTER_TAMPER`. This prevents a local-copy edit from passing the harness check, but the pin is not OS-inaccessible to a same-UID process with full Bash. |
| Decompose containment | The decomposition step may write only its plan file; any project-file change after it → `RISK_REQUIRES_APPROVAL`. Hash-protected harness, model, Fleet, and session settings are re-checked immediately before the plan can be parsed or published. |
| Post-review changes | The harness confirms at the success gate that there is zero non-`.loop` diff from the reviewed HEAD; any diff → BLOCKED. No change that skipped review can reach SUCCESS. |
| Resume checkpoint | Agent-writable, so it carries no success authority: parsed as data; resume ids/counters may be read but ids are labels only. A forged run review base is validated as an ancestor of HEAD or replaced conservatively; the task-wide base is the fixed off-tree task record. |

</details>
## Security model — what the harness does and does not provide

**Provided by the harness:**

- **Deterministic gates outside the model** — the evaluator re-runs `VERIFY_COMMANDS` itself
  and never trusts the agent's self-report; the diff policy (denied/escalate paths); and
  hash-locked contract, harness, dual-provider skills, and session control plane
  with in-memory baselines that a forged on-disk file cannot defeat, anchored in
  an off-tree approval store.
- **Structurally read-only checkers** — Claude-routed reviewer / stop-eval /
  contract-review sessions get `Read,Glob,Grep` only; Codex-routed checkers run under its
  OS-level `read-only` sandbox with automatic project `AGENTS.md` loading
  disabled.
- **Opt-in Claude tool deny-list** — Claude-routed workers get a broad tool allow-list;
  block specific tools (web access, `Bash(...)` commands, MCP servers) via
  `DISALLOWED_TOOLS` in `loop.config.sh`. Deny wins over allow under the default
  `acceptEdits` mode. Codex-routed roles use `LOOP_CODEX_SANDBOX` / `LOOP_CODEX_NETWORK` instead.

**Not provided — bring your own environment.** Following Simon Willison's writing on prompt
injection and the recent agent-security literature, these belong at the OS/container boundary,
not in a shell harness:

- **Whole-loop process/filesystem/network sandboxing.** The harness, evaluator,
  `VERIFY_COMMANDS`, and Claude-routed roles run with your user's privileges. Codex-routed
  roles receive the configured Codex sandbox, but that does not contain the rest of the loop.
  For untrusted repos or instructions, run the whole loop inside a container or VM with only
  the project mounted. Same-UID sessions with broad filesystem read access may still read
  off-tree approval files and sibling task/run logs; their normal isolation is a harness
  integrity check plus prompt/citation policy, not a whole-loop OS access-control boundary.
  User-global agent configuration (`~/.claude*`, `~/.codex/**`) is likewise
  outside the harness hash and writable by any same-UID process — including a
  Claude-routed worker's Bash — so treat it as part of the environment you
  isolate, not something the hash protects.
- **Scoped credentials.** Nothing stops a command in `VERIFY_COMMANDS` (or a hook in the
  project's own build) from reading `~/.aws` and friends. Give the loop least-privilege,
  short-lived tokens.
- **Prompt-injection immunity.** Repository content is untrusted input to every session. The
  diff policy, deterministic gates, and read-only reviewers *contain* what an injected
  instruction can achieve (it can't change the goalposts, the harness, or certify its own
  success), but they don't prevent the injection itself.

**Honest gap list:** the zero-token test suite covers the harness's control flow and tamper
defenses, not model behavior. Not yet covered: regression evals over real agent traces,
adversarial fuzzing (a fake agent that actively tries to defeat the gates), and a
prompt-injection regression corpus for the skills.
