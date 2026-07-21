#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "$0")/../lib.sh"

section "artifact lifecycle: every .loop/ path in loop.sh is classified"
# The stale-artifact bug class (a prior run's decision.html opening mid-task, old
# 'met' ledger rows aliasing a new contract's REQ ids) exists exactly when an
# artifact has NO declared reset boundary. Force the declaration: every .loop/
# literal in loop.sh must be prefix-matched by tests/artifact-lifecycle.txt.
LIFEFILE="$ROOT/tests/artifact-lifecycle.txt"
unclassified=$(grep -oE '\.loop/[A-Za-z0-9._/-]+' "$ROOT/bin/loop.sh" | sort -u | awk -v lf="$LIFEFILE" '
  BEGIN {
    while ((getline line < lf) > 0) {
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*(#|$)/) continue
      split(line, a, /[[:space:]]+/)
      prefixes[++n] = a[1]
    }
  }
  {
    hit = 0
    for (i = 1; i <= n; i++) if (index($0, prefixes[i]) == 1) { hit = 1; break }
    if (!hit) print
  }
')
if [ -z "$unclassified" ]; then
  ok "every .loop/ artifact is lifecycle-classified"
else
  bad "unclassified .loop/ artifacts — add each to tests/artifact-lifecycle.txt with a scope (run|contract|persistent|liveness): $(echo "$unclassified" | tr '\n' ' ')" lifecycle-lint
fi

section "observation tokenizer is byte-identical in loop.sh and evaluate.sh"
# loop.sh observation_tokens() and evaluate.sh 6.6(e) parse the same evidence
# cells; if their extraction ever drifts (char class, boundary set, or token
# count semantics), a citation can pass preflight and still deadlock the
# terminal evidence gate — the exact bug class this pins. Comments alone did
# not hold the invariant; this grep does.
TOK_RE='(^|[[:space:]([`])\.loop/observations/[A-Za-z0-9_./-]*[A-Za-z0-9_-]'
n_tok_loop=$(grep -cF "$TOK_RE" "$ROOT/bin/loop.sh" || true)
n_tok_eval=$(grep -cF "$TOK_RE" "$ROOT/bin/evaluate.sh" || true)
if [ "$n_tok_loop" -ge 1 ] && [ "$n_tok_eval" -ge 1 ]; then
  ok "shared tokenizer regex literal present in both parsers"
else
  bad "tokenizer regex drifted (loop.sh: $n_tok_loop, evaluate.sh: $n_tok_eval) — observation_tokens() and 6.6(e) must stay byte-identical" parser-sync
fi
STRIP_RE='s/^[[:space:]([`]//'
if grep -qF "$STRIP_RE" "$ROOT/bin/loop.sh" && grep -qF "$STRIP_RE" "$ROOT/bin/evaluate.sh"; then
  ok "shared boundary-strip sed present in both parsers"
else
  bad "boundary-strip sed drifted between loop.sh and evaluate.sh" parser-sync
fi

