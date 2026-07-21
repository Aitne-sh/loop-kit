#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

# ---------- uninstall (remove the whole deployment) ----------

section "uninstall removes the deployment, keeps user files + own gitignore entries"
make_fixture uninstall-basic
echo keep > user-file.txt
printf 'node_modules/\n' >> .gitignore
mkdir -p .claude/skills/my-skill
printf '# mine\n' > .claude/skills/my-skill/SKILL.md
mkdir -p .agents/skills/my-skill
printf '# my Codex skill\n' > .agents/skills/my-skill/SKILL.md
printf '# keep project instructions\n' > AGENTS.md
# An unmarked shipped-name directory is user-owned. Uninstall must remove only
# projections whose explicit ownership marker is still present.
rm -f .agents/skills/loop-review/.loop-kit-managed
printf '\n# user adopted this skill\n' >> .agents/skills/loop-review/SKILL.md
git add -A && git commit -q -m "user content"
RC=0
./loop.sh uninstall --force </dev/null >"$WORK/uninstall.out" 2>&1 || RC=$?
check "exit code 0" uninstall-basic 0 "$RC"
if grep -q '\.agents/skills/loop-' "$WORK/uninstall.out"; then
  ok "uninstall preview reports the managed Codex projection scope"
else
  bad "uninstall preview omitted managed Codex skills: $(cat "$WORK/uninstall.out")" uninstall-basic
fi
if [ ! -f loop.sh ] && [ ! -f fleet.sh ] && [ ! -f loop.config.sh ] \
   && [ ! -f loop.models.sh ] && [ ! -f fleet.config.sh ] && [ ! -d .loop ]; then
  ok "kit files and .loop removed"
else
  bad "kit files left behind" uninstall-basic
fi
if [ -z "$(ls -d .claude/skills/loop-* 2>/dev/null)" ]; then ok "loop-* skills removed"; else bad "loop-* skills left" uninstall-basic; fi
if [ -f .claude/skills/my-skill/SKILL.md ]; then ok "user skill kept"; else bad "user skill deleted" uninstall-basic; fi
managed_codex_left=0
for d in .agents/skills/loop-*/; do
  [ -f "$d/.loop-kit-managed" ] && managed_codex_left=$((managed_codex_left + 1))
done
check "managed Codex projections removed" uninstall-basic 0 "$managed_codex_left"
if [ -f .agents/skills/my-skill/SKILL.md ] \
   && grep -q 'user adopted this skill' .agents/skills/loop-review/SKILL.md \
   && [ -f AGENTS.md ]; then
  ok "user .agents skills, adopted shipped-name skill, and AGENTS.md are kept"
else
  bad "uninstall deleted user-owned Codex content" uninstall-basic
fi
if [ -f user-file.txt ] && [ -f value.txt ] && [ -d .git ]; then ok "project files + git kept"; else bad "project content deleted" uninstall-basic; fi
if grep -q 'node_modules/' .gitignore && ! grep -q 'loop-kit' .gitignore; then
  ok "gitignore: kit blocks stripped, user entries kept"
else
  bad "gitignore scrub wrong: $(cat .gitignore 2>/dev/null)" uninstall-basic
fi

section "uninstall sweeps stale projection staging leftovers so .agents/ itself goes away"
make_fixture uninstall-stale-stage
mkdir -p .agents/skills/.loop-plan.loop-kit-new.99999
printf 'orphaned stage\n' > .agents/skills/.loop-plan.loop-kit-new.99999/SKILL.md
RC=0
./loop.sh uninstall --force </dev/null >"$WORK/uninstall-stale-stage.out" 2>&1 || RC=$?
check "exit code 0" uninstall-stale-stage 0 "$RC"
if [ ! -e .agents ]; then
  ok "stale staging leftover removed and the emptied .agents/ pruned"
else
  bad ".agents left behind: $(find .agents | tr '\n' ' ')" uninstall-stale-stage
fi

section "uninstall without --force and no TTY refuses (nothing removed)"
make_fixture uninstall-guard
RC=0
./loop.sh uninstall </dev/null >/dev/null 2>&1 || RC=$?
check "exit code 2" uninstall-guard 2 "$RC"
if [ -f loop.sh ] && [ -d .loop ] && [ -f loop.config.sh ]; then ok "nothing removed"; else bad "files removed without confirmation" uninstall-guard; fi

section "uninstall removes fleet worktrees + branches; all-kit .gitignore removed"
make_fixture uninstall-fleet
wt="$WORK/uninstall-fleet-loops/20260101-000000-t1"
mkdir -p .loop/fleet/runs
git worktree add "$wt" -b loop/t1 >/dev/null 2>&1
printf 'WT=%s\nBRANCH=loop/t1\n' "$wt" > .loop/fleet/runs/t1.env
RC=0
./loop.sh uninstall --force </dev/null >/dev/null 2>&1 || RC=$?
check "exit code 0" uninstall-fleet 0 "$RC"
if [ ! -d "$wt" ] && ! git rev-parse -q --verify refs/heads/loop/t1 >/dev/null; then
  ok "worktree + branch removed"
else
  bad "fleet artifacts left" uninstall-fleet
fi
if [ ! -d "$WORK/uninstall-fleet-loops" ]; then ok "emptied worktree root removed"; else bad "worktree root left" uninstall-fleet; fi
if [ ! -f .gitignore ]; then ok "all-kit .gitignore removed"; else bad ".gitignore left: $(cat .gitignore)" uninstall-fleet; fi

section "uninstall from the kit repo (dir argument) + kit self-protection"
make_fixture uninstall-remote
cd "$WORK"
RC=0
"$ROOT/bin/loop.sh" uninstall "$WORK/uninstall-remote" --force </dev/null >/dev/null 2>&1 || RC=$?
check "exit code 0" uninstall-remote 0 "$RC"
if [ ! -f "$WORK/uninstall-remote/loop.sh" ] && [ ! -d "$WORK/uninstall-remote/.loop" ]; then ok "remote project uninstalled"; else bad "remote uninstall incomplete" uninstall-remote; fi
RC=0
"$ROOT/bin/loop.sh" uninstall "$ROOT" --force </dev/null >/dev/null 2>&1 || RC=$?
check "refuses to uninstall the kit repo itself (exit 2)" uninstall-remote 2 "$RC"
RC=0
"$ROOT/bin/loop.sh" uninstall </dev/null >/dev/null 2>&1 || RC=$?
check "kit repo without dir -> usage error (exit 2)" uninstall-remote 2 "$RC"

