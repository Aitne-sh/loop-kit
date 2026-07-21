[← loop-kit](../README.md) · **Managing a deployment**

> What `update` refreshes and preserves, and what `uninstall` removes and keeps.

# Managing a deployment (init / update / uninstall)

## What `init` lays down

`init` adds the harness paths to the target project's `.gitignore`. If the target is
not already a Git repository, it initializes one and creates the deployment commit; in
an existing repository, it leaves the changes for you to review.

The Claude tree is the canonical managed prompt source. During `init` and `update`,
loop-kit projects the thirteen headless-compatible skills into Codex's repository skill
location, removes Claude-only frontmatter, and writes Codex invocation policy in each
skill's `agents/openai.yaml`. It intentionally does not create `.codex/skills`: Codex
discovers repository skills under `.agents/skills`, and a second copy would create
duplicate names. Existing `AGENTS.md`, `AGENTS.override.md`, `.codex/**`, and
non-managed user skills remain user-owned.

## `update` — upgrading in place

**`update`** refreshes the executable harness (`loop.sh`, `evaluate.sh`), the
canonical `.claude/skills/loop-*` tree, its managed `.agents/skills/loop-*`
projection, and pristine document templates. It preserves populated contracts
and working documents, existing config values, model routing, user-authored
skills, `AGENTS.md`, `AGENTS.override.md`, and `.codex/**`.

```bash
cd your-project
./loop.sh update             # kit location resolved from .loop/kit-source
./loop.sh update --approve   # update and re-approve in one step

# or from the kit repo, pointing at a project:
~/loop-kit/bin/loop.sh update /path/to/your-project [--approve]
```

Updating the harness changes its hash, so it invalidates the old approval on purpose —
re-approve with `--approve` or `./loop.sh approve`. When the executable harness
already matches, `update` reports it as current without invalidating the approval;
config/template drift handling still runs. New `loop.config.sh` / `loop.models.sh`
keys are reported for review; missing `fleet.config.sh` keys are appended with their
shipped comments while existing values remain authoritative. Removed canonical
`.claude/skills/loop-*` entries and marker-owned Codex projections are cleaned
up, while other skill names are left alone. For `.agents/skills` specifically,
update replaces or prunes only directories carrying loop-kit's management
marker; if a projected name already exists without that marker, it stops instead
of overwriting user content and prints the recovery command. If
`.loop/kit-source` is unavailable, provide the source once with
`./loop.sh update --from /path/to/loop-kit`.

## `uninstall` — taking it back out

**`uninstall`** removes loop-kit from a project entirely — every file `init` deployed plus all
run state — returning the project to how it looked before:

```bash
./loop.sh uninstall            # lists what will be removed, asks to confirm [y/N]
./loop.sh uninstall --force    # skip the prompt (required without a terminal)
```

It removes the canonical `.claude/skills/loop-*` names and only marker-owned
`.agents/skills/loop-*` projections. It keeps other skill names, your own files,
`loop-instruction.md`, `AGENTS.md`, `AGENTS.override.md`, `.codex/**`, and the
git history (commits the loop made stay in history). It refuses to run while a
supervisor or task loop is active, warns you before discarding unmerged fleet
branches, and refuses to run against the kit repository itself.
