#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "fleet clean --orphans: never removes a worktree with a LIVE loop inside"
# E11: orphans have no runs/<id>.env, so liveness comes from the worktree's own
# .loop/run.pid (E5's pidfile) — a live loop.sh identity must veto the gc.
make_fixture orphan-live
git worktree add "$WORK/orphan-live-loops/ghost-2" -b loop/ghost-2 >/dev/null 2>&1
mkdir -p "$WORK/orphan-live-loops/ghost-2/.loop"
mkdir -p "$WORK/orphan-decoy"
printf '#!/bin/sh\nsleep 300\n' > "$WORK/orphan-decoy/loop.sh"
chmod +x "$WORK/orphan-decoy/loop.sh"
"$WORK/orphan-decoy/loop.sh" &
DECOY=$!
echo "$DECOY" > "$WORK/orphan-live-loops/ghost-2/.loop/run.pid"
out=$(./loop.sh fleet clean --orphans 2>&1) || true
if [ -d "$WORK/orphan-live-loops/ghost-2" ] && git rev-parse -q --verify refs/heads/loop/ghost-2 >/dev/null; then
  ok "live-pid orphan left in place"
else
  bad "gc removed a worktree with a live loop" orphan-live
fi
case "$out" in
  *"not cleaning"*) ok "skip is explicit (not cleaning; stop it first)" ;;
  *) bad "no live-skip note: $out" orphan-live ;;
esac
kill "$DECOY" 2>/dev/null || true
wait "$DECOY" 2>/dev/null || true
./loop.sh fleet clean --orphans >/dev/null 2>&1 || true
if [ ! -d "$WORK/orphan-live-loops/ghost-2" ] && ! git rev-parse -q --verify refs/heads/loop/ghost-2 >/dev/null; then
  ok "dead orphan removed once the loop is gone"
else
  bad "dead orphan not cleaned" orphan-live
fi

