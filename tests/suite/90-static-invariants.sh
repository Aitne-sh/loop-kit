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

section "every stop state resolves to a NEXT ACTION context that actually exists"
# The "what do I run next?" surface is only uniform if the two halves stay in
# sync: next_action_ctx_for_state() decides WHICH box a stop shows, and
# print_next_actions() implements the boxes. A context named by one and missing
# from the other is a stop that prints an empty box (or silently prints none) —
# the dead-end this whole surface exists to prevent. Both directions are checked,
# because an orphaned box is just as much a bug as a missing one.
ctx_impl=$(awk '/^print_next_actions\(\)/,/^}/' "$ROOT/bin/loop.sh" \
  | grep -oE '^    [a-z-]+\)' | tr -d ' )' | sort -u)
# comment lines are dropped first: the prose around these call sites names them
# ("print_next_actions spells out ...") and would otherwise be read as contexts
code_only() { grep -vE '^[[:space:]]*#'; }
ctx_used=$({ awk '/^next_action_ctx_for_state\(\)/,/^}/' "$ROOT/bin/loop.sh" | code_only \
              | grep -oE 'echo [a-z-]+' | awk '{print $2}'
            # a caller may pin a box directly (e.g. the api-stall classifier)
            code_only < "$ROOT/bin/loop.sh" | grep -oE 'NEXT_ACTION_CTX=[a-z-]+' | cut -d= -f2
            # ...and finish()/refine call a few by literal name
            code_only < "$ROOT/bin/loop.sh" | grep -oE 'print_next_actions [a-z-]+' | awk '{print $2}'
          } | grep -v '^$' | sort -u)
missing=$(comm -23 <(printf '%s\n' "$ctx_used") <(printf '%s\n' "$ctx_impl"))
orphan=$(comm -13 <(printf '%s\n' "$ctx_used") <(printf '%s\n' "$ctx_impl"))
if [ -z "$missing" ]; then
  ok "every NEXT ACTION context a stop can select is implemented in print_next_actions"
else
  bad "stop states select context(s) print_next_actions does not implement: $(echo "$missing" | tr '\n' ' ')" nextaction-sync
fi
if [ -z "$orphan" ]; then
  ok "print_next_actions has no unreachable context"
else
  bad "print_next_actions implements context(s) nothing selects: $(echo "$orphan" | tr '\n' ' ')" nextaction-sync
fi
# and the two BLOCKED branches must both remain selectable — collapsing them is
# what put `./loop.sh signoff` in front of every failing loop in the first place
if printf '%s\n' "$ctx_used" | grep -qx blocked && printf '%s\n' "$ctx_used" | grep -qx blocked-stuck; then
  ok "BLOCKED still splits into the sign-off box and the stuck box"
else
  bad "BLOCKED lost one of its two boxes (blocked / blocked-stuck)" nextaction-sync
fi
