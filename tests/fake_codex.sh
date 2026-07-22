#!/usr/bin/env bash
# fake_codex.sh — zero-token Codex CLI stub backed by fake_claude scenarios.
#
# Records every process start in .loop/fake-codex-invocations. Successful exec
# argv are normalized into .loop/fake-codex-args, and raw wrapped prompts into
# .loop/fake-codex-prompts. This separation lets tests prove both exact routing
# and the stronger pure-Claude invariant that no help/auth probe ran at all.
#
# LOOP_FAKE_CODEX=FAIL:   emit turn.failed + error events and exit 1.
# LOOP_FAKE_CODEX=NOMSG: emit a successful JSONL turn but do not write -o.
# LOOP_FAKE_CODEX=TURNFAIL: write -o and exit 0, but emit turn.failed.
# LOOP_FAKE_CODEX=TURNFAIL_UTF8: TURNFAIL with a long multibyte -o message
#   (exercises UTF-8-safe failure diagnostics under a multibyte locale).
# LOOP_FAKE_CODEX=REORDER: emit valid JSONL with "type" after other keys.
# LOOP_FAKE_CODEX=NESTED_ERROR: successful turn whose item payloads contain
#   "type":"error" / "turn.failed" as DATA (nested objects and string text) —
#   the adapter must classify by top-level event type only.
# LOOP_FAKE_CODEX=OLD:   exec --help omits --json (capability-probe fixture).
# LOOP_FAKE_CODEX=NOAUTH: login status exits 1; actual exec still succeeds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAKE_CLAUDE="$SCRIPT_DIR/fake_claude.sh"

mkdir -p .loop
printf '%s\n' "$*" >> .loop/fake-codex-invocations

usage_error() {
  printf 'fake_codex: invalid argv: %s\n' "$*" >&2
  exit 2
}

print_top_help() {
  cat <<'EOF'
Codex CLI (fake)
Usage: codex [OPTIONS] <COMMAND> [ARGS]
  --ask-for-approval <POLICY>
EOF
}

print_exec_help() {
  if [ "${LOOP_FAKE_CODEX:-}" = OLD ]; then
    cat <<'EOF'
Usage: codex exec [OPTIONS] [PROMPT]
  -o, --output-last-message <FILE>
EOF
  else
    cat <<'EOF'
Usage: codex exec [OPTIONS] [PROMPT]
  --json
  -o, --output-last-message <FILE>
EOF
  fi
}

print_login_help() {
  cat <<'EOF'
Usage: codex login [COMMAND]
Commands:
  status  Show login status
EOF
}

next_thread_id() {
  local n
  n=$(cat .loop/fake-codex-i 2>/dev/null || echo 0)
  n=$((n + 1))
  printf '%s\n' "$n" > .loop/fake-codex-i
  printf 'fake-codex-%s' "$n"
}

emit_failure() { # $1 thread-id, $2 diagnostic
  printf '{"type":"thread.started","thread_id":"%s"}\n' "$1"
  printf '{"type":"turn.started"}\n'
  printf '{"type":"turn.failed","error":{"message":"%s"}}\n' "$2"
  # The adapter uses a top-level error event to populate AGENT_FAIL_DIAG when
  # the -o file is missing; keep it alongside turn.failed to exercise both paths.
  printf '{"type":"error","message":"%s"}\n' "$2"
}

run_exec() {
  local approval="$1"
  shift
  local json=0 output="" model="" sandbox="" configs="" prompt=""
  local skill="" args="" reconstructed="" result="" delegate_status=0 thread

  if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
    print_exec_help
    return 0
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -o|--output-last-message)
        [ "$#" -ge 2 ] || usage_error "$1 requires a value"
        output="$2"; shift 2 ;;
      -m|--model)
        [ "$#" -ge 2 ] || usage_error "$1 requires a value"
        model="$2"; shift 2 ;;
      -s|--sandbox)
        [ "$#" -ge 2 ] || usage_error "$1 requires a value"
        sandbox="$2"; shift 2 ;;
      -c|--config)
        [ "$#" -ge 2 ] || usage_error "$1 requires a value"
        if [ -n "$configs" ]; then configs="$configs,$2"; else configs="$2"; fi
        shift 2 ;;
      --ask-for-approval)
        usage_error "--ask-for-approval must precede exec" ;;
      --)
        shift
        [ "$#" -eq 1 ] || usage_error "expected one prompt after --"
        prompt="$1"; shift ;;
      -*) usage_error "unknown exec option $1" ;;
      *)
        [ -z "$prompt" ] || usage_error "multiple prompts"
        prompt="$1"; shift ;;
    esac
  done

  [ "$approval" = never ] || usage_error "missing global --ask-for-approval never"
  [ "$json" -eq 1 ] || usage_error "missing --json"
  [ -n "$output" ] || usage_error "missing -o/--output-last-message"
  [ -n "$model" ] || usage_error "missing -m/--model"
  case "$sandbox" in read-only|workspace-write|danger-full-access) ;; *) usage_error "invalid --sandbox '$sandbox'" ;; esac
  [ -n "$prompt" ] || usage_error "missing prompt"

  printf 'model=%s sandbox=%s approval=%s configs=%s output=%s\n' \
    "$model" "$sandbox" "$approval" "${configs:--}" "$output" >> .loop/fake-codex-args
  printf '%s\n' "$prompt" >> .loop/fake-codex-prompts

  thread=$(next_thread_id)
  if [ "${LOOP_FAKE_CODEX:-}" = FAIL ]; then
    emit_failure "$thread" "fake codex failure"
    return 1
  fi
  if [ "${LOOP_FAKE_CODEX:-}" = TURNFAIL ]; then
    printf '%s\n' "fake codex turn failed despite a final message" > "$output"
    printf '{"type":"thread.started","thread_id":"%s"}\n' "$thread"
    printf '{"type":"turn.failed","error":{"message":"fake codex turn failure"}}\n'
    return 0
  fi
  if [ "${LOOP_FAKE_CODEX:-}" = TURNFAIL_UTF8 ]; then
    # >200 bytes of 3-byte UTF-8 chars: the harness's 200-byte diagnostic
    # truncation is guaranteed to land mid-character.
    printf '%s\n' "偽のコーデックス障害:マルチバイト診断テキストが二百バイトを超えて続き、切断点が必ず文字の途中に来ることを保証します。さらに続く日本語テキストで長さを確保します。" > "$output"
    printf '{"type":"thread.started","thread_id":"%s"}\n' "$thread"
    printf '{"type":"turn.failed","error":{"message":"偽のマルチバイト障害"}}\n'
    return 0
  fi

  skill=$(printf '%s\n' "$prompt" \
    | sed -nE 's#.*\.(claude|agents)/skills/loop-([a-z-]+)/SKILL\.md.*#\2#p')
  if [ -n "$skill" ]; then
    reconstructed="/loop-$skill"
    case "$prompt" in
      *"skill arguments:"*)
        args=${prompt#*skill arguments:}
        while [ "${args# }" != "$args" ]; do args=${args# }; done
        [ -z "$args" ] || reconstructed="$reconstructed $args" ;;
    esac
  else
    reconstructed="$prompt"
  fi

  result=$(LOOP_FAKE_RAW_RESULT=1 LOOP_FAKE_DELEGATED_CODEX=1 \
    "$FAKE_CLAUDE" -p "$reconstructed" --output-format json --model "$model") \
    || delegate_status=$?
  if [ "$delegate_status" -ne 0 ]; then
    emit_failure "$thread" "fake codex delegated agent failed"
    return "$delegate_status"
  fi

  if [ "${LOOP_FAKE_CODEX:-}" != NOMSG ]; then
    printf '%s\n' "$result" > "$output"
  fi
  # Optional token injection for cost-estimation tests: LOOP_FAKE_CODEX_TOKENS
  # = "input,cached,output" (all 0 by default, matching a zero-token stub).
  fk_in=0; fk_cached=0; fk_out=0
  if [ -n "${LOOP_FAKE_CODEX_TOKENS:-}" ]; then
    fk_in=${LOOP_FAKE_CODEX_TOKENS%%,*}
    fk_rest=${LOOP_FAKE_CODEX_TOKENS#*,}
    fk_cached=${fk_rest%%,*}
    fk_out=${fk_rest#*,}
    case "$fk_in" in ''|*[!0-9]*) fk_in=0 ;; esac
    case "$fk_cached" in ''|*[!0-9]*) fk_cached=0 ;; esac
    case "$fk_out" in ''|*[!0-9]*) fk_out=0 ;; esac
  fi
  fk_usage=$(printf '{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s}' "$fk_in" "$fk_cached" "$fk_out")
  if [ "${LOOP_FAKE_CODEX:-}" = REORDER ]; then
    printf '{"thread_id":"%s","type":"thread.started"}\n' "$thread"
    printf '{"sequence":1,"type":"turn.started"}\n'
    printf '{"item":{"type":"agent_message","text":"fake"},"type":"item.completed"}\n'
    printf '{"usage":%s,"type":"turn.completed"}\n' "$fk_usage"
  elif [ "${LOOP_FAKE_CODEX:-}" = NESTED_ERROR ]; then
    # the delegated work already ran and -o holds its real result; only the
    # event stream is adversarial: fatal-looking markers as nested DATA
    printf '{"type":"thread.started","thread_id":"%s"}\n' "$thread"
    printf '{"type":"turn.started"}\n'
    # nested object whose FIRST key is a type:error, before the top-level type
    printf '{"item":{"type":"error","text":"lint said \\"type\\":\\"error\\" somewhere"},"type":"item.completed"}\n'
    # string data carrying the exact fatal markers the old line-regex matched
    printf '{"type":"item.completed","item":{"type":"agent_message","text":"transcript quotes \\"type\\": \\"turn.failed\\" as data"}}\n'
    printf '{"type":"turn.completed","usage":{"input_tokens":0,"output_tokens":0}}\n'
  else
    printf '{"type":"thread.started","thread_id":"%s"}\n' "$thread"
    printf '{"type":"turn.started"}\n'
    printf '{"type":"item.completed","item":{"type":"agent_message","text":"fake"}}\n'
    printf '{"type":"turn.completed","usage":%s}\n' "$fk_usage"
  fi
}

approval=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ask-for-approval)
      [ "$#" -ge 2 ] || usage_error "$1 requires a value"
      approval="$2"; shift 2 ;;
    --help|-h)
      print_top_help
      exit 0 ;;
    login)
      shift
      case "${1:-}" in
        --help|-h|help) print_login_help; exit 0 ;;
        status)
          [ "$#" -eq 1 ] || usage_error "unexpected login status args"
          [ "${LOOP_FAKE_CODEX:-}" != NOAUTH ] || exit 1
          printf 'Logged in (fake)\n'
          exit 0 ;;
        *) usage_error "unsupported login command '${1:-}'" ;;
      esac ;;
    exec)
      shift
      run_exec "$approval" "$@"
      exit $? ;;
    *) usage_error "expected a global option or command, got '$1'" ;;
  esac
done

usage_error "missing command"
