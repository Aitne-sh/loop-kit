#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # Parallel: loop.sh alone is ~9s and dominates; a serial run stacks the other
  # files on top. shellcheck analyzes each file independently (each suite file
  # carries a `source=` directive for a developer running `shellcheck -x`), so
  # per-file concurrency is result-identical and collapses the gate to the slowest
  # single file. Output is replayed in list order so findings stay deterministic.
  # The suite files are checked too: they are the assertions, and a quoting bug
  # there is as damaging as one in the harness.
  #
  # `|| rc=$?` is load-bearing: under `set -e` a bare `shellcheck "$f"` that finds
  # something kills the subshell BEFORE it can record its status, and a status file
  # that is never written used to read as "clean" — the gate could not fail.
  sc_rc=0
  sc_tmp=$(mktemp -d "$WORK/shellcheck.XXXXXX")
  sc_files=("$ROOT/bin/loop.sh" "$ROOT/bin/evaluate.sh" "$ROOT/tests/fake_claude.sh"
            "$ROOT/tests/fake_codex.sh" "$ROOT/tests/run_tests.sh" "$ROOT/tests/lib.sh"
            "$ROOT"/tests/suite/*.sh)
  for f in "${sc_files[@]}"; do
    b=$(basename "$f")
    ( rc=0; shellcheck "$f" > "$sc_tmp/$b.out" 2>&1 || rc=$?; echo "$rc" > "$sc_tmp/$b.rc" ) &
  done
  wait
  for f in "${sc_files[@]}"; do
    b=$(basename "$f")
    if [ ! -f "$sc_tmp/$b.rc" ]; then
      echo "  shellcheck did not report on $b"; sc_rc=1; continue
    fi
    [ "$(cat "$sc_tmp/$b.rc")" = 0 ] || sc_rc=1
    if [ -s "$sc_tmp/$b.out" ]; then cat "$sc_tmp/$b.out"; fi
  done
  if [ "$sc_rc" = 0 ]; then
    ok "shellcheck clean"
  else
    bad "shellcheck findings" shellcheck
  fi
else
  echo "  skip: shellcheck not installed"
fi

