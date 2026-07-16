#!/usr/bin/env bash
# evaluate.sh — the external evaluator. Deterministic, model-free, never trusts
# the agent's self-report. Prints exactly one line: "<STATE> <reason>".
#
# Decision order (highest-trust checks first):
#   1. contract immutability (hash vs --approved-hash from loop.sh's MEMORY,
#      checked BEFORE sourcing config; .loop/approved is only a fallback for
#      standalone runs — the agent can forge that file) -> NEEDS_SPEC_DECISION
#   2. harness paths touched (loop.sh / loop.models.sh / .claude/**)            -> RISK_REQUIRES_APPROVAL
#   3. denied paths touched                                                     -> RISK_REQUIRES_APPROVAL
#   4. escalate paths touched                                                   -> NEEDS_ARCHITECTURE_DECISION
#   5. verification commands re-run by the evaluator itself (or, with
#      --preflight, require the immediately preceding verify log to be green)
#   6. agent's declared state (.loop/agent-state) — escalations honored
#   6.5 ledger self-consistency: an agent claiming READY_FOR_REVIEW whose own
#       requirements ledger does not show every contract REQ as met is refused
#       the gate (-> CONTINUE). Self-report vs self-report, still deterministic.
#   6.6 acceptance-checklist self-consistency: same shape, finer grain — any
#       AC row in .loop/docs/acceptance-checklist.md whose status is not
#       `verified` refuses the gate (-> CONTINUE), and every AC id the
#       contract's Acceptance Criteria name as a list item must HAVE a
#       verified row (obligations anchor to the approved contract, so
#       deleting rows can never shrink them). Absent file/rows/ids = not in use.
#       Two more guards in the same tier: an AC id ever seen this run must
#       still exist as a row (.loop/ac-seen — a row APPENDED mid-run is an
#       admitted obligation; deleting it later must not shrink the set), and
#       a row's method cell may not differ from the contract anchor's
#       "(cmd|run|human)" token (no silent weakening of run -> cmd).
#   7. verify green + agent READY_FOR_REVIEW -> SUCCESS_CANDIDATE (SUCCESS with --final)
#   8. stagnation (no non-harness diff) / identical failure repeated -> STALLED / BLOCKED
#   else -> CONTINUE
# (Budget is enforced by loop.sh from its in-memory total — a file-based total
#  would be tamperable by the agent.)
#
# Run from the target repo root. --pre-ref <sha> scopes the diff of this iteration.
# --final skips bookkeeping (8) and maps the success gate directly to SUCCESS.
# --preflight performs only the deterministic promotion checks (1-4, green
# last-verify.log, 6.5/6.6) and never re-runs VERIFY_COMMANDS or consults the
# agent readiness claim. It is the prerequisite for counting a MET stop verdict.
# --assume-ready treats any non-escalated agent state as READY_FOR_REVIEW at the
# success gate (used by loop.sh's forced gate after consecutive MET stop-evals;
# escalation states declared by the agent are still honored first).

set -euo pipefail

# enext <problem> <recovery> — evaluator error with a trailing "→ next:" line,
# mirroring loop.sh's die_next so every surface points the user somewhere.
enext() { echo "evaluate: $1" >&2; [ -n "${2:-}" ] && echo "  → next: $2" >&2; exit 2; }

PRE_REF=""
FINAL=0
APPROVED_OVERRIDE=""
ASSUME_READY=0
PREFLIGHT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pre-ref)       PRE_REF="${2:?}"; shift 2 ;;
    --final)         FINAL=1; shift ;;
    --approved-hash) APPROVED_OVERRIDE="${2:?}"; shift 2 ;;
    --assume-ready)  ASSUME_READY=1; shift ;;
    --preflight)     PREFLIGHT=1; shift ;;
    *) enext "unknown arg: $1" "drive the evaluator via ./loop.sh, not directly" ;;
  esac
done

emit() { echo "$1 $2"; exit 0; }

# strictly per-evaluation evidence: clear BEFORE any early emit (sections 1-4,
# config errors), or a previous evaluation's flake log would survive an early
# exit and be journaled by loop.sh against an iteration that never re-verified
rm -f .loop/verify-flake.log

sha256() { # stdin -> hex digest. shasum ships with macOS/perl; sha256sum with
  # coreutils — the guard below guarantees one of them exists.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# JSON string body, without surrounding quotes. Keep the character-by-character
# form: BSD awk and gawk disagree on backslashes in gsub replacement strings.
json_escape() {
  awk '
    {
      line = $0; esc = ""; m = length(line)
      for (k = 1; k <= m; k++) {
        ch = substr(line, k, 1)
        if      (ch == "\\") esc = esc "\\\\"
        else if (ch == "\"") esc = esc "\\\""
        else if (ch == "\t") esc = esc "\\t"
        else if (ch == "\r") esc = esc "\\r"
        else                   esc = esc ch
      }
      out = (NR == 1 ? esc : out "\\n" esc)
    }
    END { printf "%s", out }
  '
}

manifest_field() { # $1 JSON line, $2 simple scalar field -> value or empty
  printf '%s\n' "$1" | sed -nE "s/.*\"$2\":\"([^\"]*)\".*/\\1/p"
}

manifest_last() { # $1 AC id, $2 normalized artifact path -> last matching JSONL row
  [ ! -L .loop/observations-manifest.jsonl ] || return 1
  [ -e .loop/observations-manifest.jsonl ] || return 0
  [ -f .loop/observations-manifest.jsonl ] \
    && [ -r .loop/observations-manifest.jsonl ] || return 1
  awk -v acid="$1" -v path="$2" '
    index($0, "\"ac_id\":\"" acid "\"") &&
    index($0, "\"artifact_path\":\"" path "\"") { row=$0 }
    END { if (row != "") print row }
  ' .loop/observations-manifest.jsonl
}

file_bytes() { # $1 regular readable file -> decimal byte count
  local bytes
  if ! bytes=$(wc -c < "$1" 2>/dev/null); then
    return 1
  fi
  if ! bytes=$(printf '%s' "$bytes" | tr -d '[:space:]'); then
    return 1
  fi
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$bytes"
}

observation_total_bytes() {
  local list path bytes total=0 ok=1
  [ -d .loop/observations ] || { echo 0; return 0; }
  [ ! -L .loop/observations ] || return 1
  if ! list=$(mktemp "${TMPDIR:-/tmp}/loop-observations.XXXXXX"); then
    return 1
  fi
  if ! find .loop/observations -type f -print0 > "$list" 2>/dev/null; then
    rm -f "$list" 2>/dev/null || true
    return 1
  fi
  while IFS= read -r -d '' path; do
    if ! bytes=$(file_bytes "$path"); then
      ok=0
      break
    fi
    total=$((total + bytes))
  done < "$list"
  if ! rm -f "$list"; then
    return 1
  fi
  [ "$ok" -eq 1 ] || return 1
  printf '%s\n' "$total"
}

contract_ac_hash() { # $1 AC id, $2 checklist expectation fallback
  local anchor
  if ! anchor=$(awk -v want="$1" '
    $0 ~ "^[[:space:]]*[-*][[:space:]]*" want "([^0-9]|$)" { print; exit }
  ' .loop/docs/product-contract.md 2>/dev/null); then
    return 1
  fi
  if [ -n "$anchor" ]; then printf '%s' "$anchor" | sha256
  else printf '%s' "$2" | sha256
  fi
}

product_tree_hash() { # committed product state, excluding tracked loop memory
  git ls-tree -r HEAD 2>/dev/null \
    | awk -F '\t' '$2 !~ /^\.loop\// && $2 !~ /^\.claude\//' \
    | sha256
}

stamp_observation() { # $1 AC id, $2 path, $3 artifact sha, $4 AC hash, $5 tree hash
  local iter captured aid path manifest tmp
  iter=$(grep -E '^ITERATION=' .loop/run-checkpoint 2>/dev/null | tail -1 | cut -d= -f2- || true)
  case "$iter" in ''|*[!0-9]*) iter=0 ;; esac
  captured=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '')
  if ! aid=$(printf '%s' "$1" | json_escape) || [ -z "$aid" ]; then
    return 1
  fi
  if ! path=$(printf '%s' "$2" | json_escape) || [ -z "$path" ]; then
    return 1
  fi

  manifest=.loop/observations-manifest.jsonl
  [ ! -L "$manifest" ] || return 1
  if [ -e "$manifest" ] && { [ ! -f "$manifest" ] || [ ! -r "$manifest" ]; }; then
    return 1
  fi
  if ! tmp=$(mktemp .loop/.observations-manifest.tmp.XXXXXX); then
    return 1
  fi
  if [ -f "$manifest" ] && ! cat "$manifest" >> "$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! printf '{"ac_id":"%s","artifact_path":"%s","artifact_sha256":"%s","contract_ac_hash":"%s","product_tree_hash":"%s","iteration":"%s","captured_at":"%s"}\n' \
      "$aid" "$path" "$3" "$4" "$5" "$iter" "$captured" >> "$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$tmp" "$manifest"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

validate_observation() { # $1 AC id, $2 artifact path, $3 checklist expectation
  # Sets OBS_REASON on refusal. Normal evaluation checks the artifact boundary
  # and bytes only; preflight runs after the iteration commit and is the sole
  # writer that stamps new/changed evidence against the committed HEAD.
  local aid="$1" obs="$2" expectation="$3" rel rest component current
  local bytes total max_file max_total artifact_sha ac_hash tree_hash
  local row old_sha old_ac old_tree
  OBS_REASON=""

  case "$obs" in
    .loop/observations/*) rel=${obs#.loop/observations/} ;;
    *) OBS_REASON="invalid observation path:${obs:-unparseable path}"; return 1 ;;
  esac
  case "$rel" in
    ''|/*|*/|*//*|*[!A-Za-z0-9_./-]*)
      OBS_REASON="invalid observation path:$obs"
      return 1
      ;;
  esac
  [ ! -L .loop ] && [ ! -L .loop/observations ] \
    || { OBS_REASON="invalid observation path (symlink component):$obs"; return 1; }
  rest="$rel"
  current=.loop/observations
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) component=${rest%%/*}; rest=${rest#*/} ;;
      *) component=$rest; rest="" ;;
    esac
    case "$component" in
      .|..) OBS_REASON="invalid observation path:$obs"; return 1 ;;
    esac
    current="$current/$component"
    [ ! -L "$current" ] \
      || { OBS_REASON="invalid observation path (symlink component):$obs"; return 1; }
  done
  [ -e "$obs" ] || { OBS_REASON="missing:$obs"; return 1; }
  [ -f "$obs" ] \
    || { OBS_REASON="invalid observation type (regular file required):$obs"; return 1; }
  [ -r "$obs" ] || { OBS_REASON="unreadable observation:$obs"; return 1; }
  [ -s "$obs" ] || { OBS_REASON="missing:$obs"; return 1; }

  max_file="$LOOP_OBS_MAX_FILE_KB"
  max_total="$LOOP_OBS_MAX_TOTAL_MB"
  case "$max_file" in ''|*[!0-9]*) max_file=2048 ;; esac
  case "$max_total" in ''|*[!0-9]*) max_total=50 ;; esac
  if ! bytes=$(file_bytes "$obs"); then
    OBS_REASON="cannot read observation bytes:$obs"
    return 1
  fi
  if ! total=$(observation_total_bytes); then
    OBS_REASON="cannot measure .loop/observations"
    return 1
  fi
  if [ "$bytes" -gt $((max_file * 1024)) ]; then
    OBS_REASON="oversize:$obs exceeds ${max_file}KB"
    return 1
  fi
  if [ "$total" -gt $((max_total * 1024 * 1024)) ]; then
    OBS_REASON="oversize:.loop/observations exceeds ${max_total}MB"
    return 1
  fi

  if ! artifact_sha=$(sha256 < "$obs") || [ -z "$artifact_sha" ]; then
    OBS_REASON="cannot hash observation:$obs"
    return 1
  fi
  if ! row=$(manifest_last "$aid" "$obs"); then
    OBS_REASON="cannot read observation manifest"
    return 1
  fi
  old_sha=""
  if [ -n "$row" ]; then
    if ! old_sha=$(manifest_field "$row" artifact_sha256) || [ -z "$old_sha" ]; then
      OBS_REASON="invalid observation manifest entry:$obs"
      return 1
    fi
  fi

  # The normal evaluator runs before loop.sh commits the iteration. It validates
  # the artifact itself but deliberately leaves new/changed bytes unstamped;
  # run_success_gate/stop-eval preflight runs after that commit and binds them to
  # the resulting HEAD instead of the previous one.
  if [ -z "$row" ] || [ "$old_sha" != "$artifact_sha" ]; then
    [ "$PREFLIGHT" -eq 1 ] || return 0
  fi

  if ! ac_hash=$(contract_ac_hash "$aid" "$expectation") || [ -z "$ac_hash" ]; then
    OBS_REASON="cannot hash acceptance criterion:$aid"
    return 1
  fi
  if ! tree_hash=$(product_tree_hash) || [ -z "$tree_hash" ]; then
    OBS_REASON="cannot resolve current product tree"
    return 1
  fi
  if [ -z "$row" ] || [ "$old_sha" != "$artifact_sha" ]; then
    if ! stamp_observation "$aid" "$obs" "$artifact_sha" "$ac_hash" "$tree_hash"; then
      OBS_REASON="cannot stamp observation manifest:$obs"
      return 1
    fi
    return 0
  fi
  if ! old_ac=$(manifest_field "$row" contract_ac_hash) || [ -z "$old_ac" ] \
     || ! old_tree=$(manifest_field "$row" product_tree_hash) || [ -z "$old_tree" ]; then
    OBS_REASON="invalid observation manifest entry:$obs"
    return 1
  fi
  if [ "$old_ac" != "$ac_hash" ]; then
    OBS_REASON="evidence stale (acceptance criterion changed since capture):$obs"
    return 1
  fi
  if [ "$old_tree" != "$tree_hash" ]; then
    OBS_REASON="evidence stale (code changed since capture):$obs"
    return 1
  fi
  return 0
}

# a missing SHA-256 tool would yield an empty hash and an undiagnosable permanent
# "changed since approval" — die up front instead (mirrors loop.sh's need_sha)
command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
  || enext "no SHA-256 tool found (shasum or sha256sum) — required for the contract-immutability check" "install coreutils (sha256sum) or perl (shasum)"

[ -f loop.config.sh ] || emit BLOCKED "evaluator: no loop.config.sh in $(pwd)"

# ---------- 1. contract immutability (BEFORE sourcing any shell config) ----------
# loop.sh passes --approved-hash from its own memory, so an agent that edits the
# contract AND forges .loop/approved still fails here. The on-disk file is only
# consulted when this script is run standalone (manual debugging).
current_hash=$(cat .loop/docs/product-contract.md loop.config.sh 2>/dev/null | sha256)
approved_hash="$APPROVED_OVERRIDE"
[ -n "$approved_hash" ] || approved_hash=$(cat .loop/approved 2>/dev/null || echo "")
if [ "$current_hash" != "$approved_hash" ]; then
  emit NEEDS_SPEC_DECISION "product contract or loop config changed since approval"
fi

# safe to source now: this exact content was human-approved
# shellcheck disable=SC1091
. ./loop.config.sh
: "${STAGNATION_N:=2}"
: "${REPEAT_FAIL_N:=3}"
: "${DENIED_PATHS:=}"
: "${ESCALATE_PATHS:=}"
: "${LOOP_OBS_MAX_FILE_KB:=2048}"
: "${LOOP_OBS_MAX_TOTAL_MB:=50}"
mkdir -p .loop

# acceptance-checklist id ledger (record-only here; enforced at 6.6): every AC
# id observed in the checklist accumulates in .loop/ac-seen. Contract-anchored
# ids are already deletion-proof via 6.6's anchor rule; this ledger extends
# that to rows APPENDED during the run (consideration-gap scan) — an appended
# row is an admitted obligation, and deleting it later must not shrink the
# set. Run-scoped: loop.sh seeds it at fresh-run start and resets it per run
# (tests/artifact-lifecycle.txt).
current_ac_ids=$(awk -F'|' '
  /^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
    id=$2
    gsub(/^[ \t]+/,"",id); gsub(/[ \t]+$/,"",id)
    print id
  }' .loop/docs/acceptance-checklist.md 2>/dev/null | sort -u || true)
if [ -n "$current_ac_ids" ]; then
  { cat .loop/ac-seen 2>/dev/null || true; printf '%s\n' "$current_ac_ids"; } \
    | grep -E '^AC-[0-9]+$' | sort -u > .loop/ac-seen.tmp \
    && mv .loop/ac-seen.tmp .loop/ac-seen
fi

# harness files the agent must never touch (tracked in git, so the diff sees them;
# the untracked .loop/bin half and any gitignored session config are covered by
# loop.sh's in-memory hash baselines)
HARNESS_PATHS="loop.sh loop.models.sh fleet.sh fleet.config.sh .mcp.json .claude/** .codex/**"

# ---------- changed paths in this iteration (tracked diff + untracked, minus .loop) ----------
changed=""
if [ -n "$PRE_REF" ]; then
  changed=$(
    {
      git diff --name-only "$PRE_REF" -- . ':(exclude).loop' 2>/dev/null || true
      git ls-files --others --exclude-standard | grep -v '^\.loop/' || true
    } | sort -u
  )
fi

match_globs() { # $1 newline-separated paths, $2 space-separated globs -> prints matches
  local paths="$1" globs="$2" path glob g
  [ -n "$globs" ] || return 0
  set -f   # word-split the glob list WITHOUT pathname expansion (else 'a/**' becomes real filenames)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    for glob in $globs; do
      g=${glob//\*\*/\*}   # bash patterns: '*' crosses '/', so 'a/**' == 'a/*'
      # shellcheck disable=SC2254  # $g is intentionally a glob pattern here, not a literal
      case "$path" in
        $g) echo "$path"; break ;;
      esac
    done
  done <<EOF
$paths
EOF
  set +f
}

# ---------- 2. harness paths ----------
viol=$(match_globs "$changed" "$HARNESS_PATHS")
if [ -n "$viol" ]; then
  emit RISK_REQUIRES_APPROVAL "harness file(s) modified by the loop: $(echo "$viol" | tr '\n' ' ')"
fi

# ---------- 3. denied paths ----------
viol=$(match_globs "$changed" "$DENIED_PATHS")
if [ -n "$viol" ]; then
  emit RISK_REQUIRES_APPROVAL "denied path(s) modified: $(echo "$viol" | tr '\n' ' ')"
fi

# ---------- 4. escalate paths ----------
esc=$(match_globs "$changed" "$ESCALATE_PATHS")
if [ -n "$esc" ]; then
  emit NEEDS_ARCHITECTURE_DECISION "architecture-sensitive path(s) modified: $(echo "$esc" | tr '\n' ' ')"
fi

# ---------- 5. verification (the deterministic gate — run by the evaluator itself) ----------
# fail closed: a config with no gate must never pass vacuously. loop.sh refuses
# to start such a run; this covers standalone/manual invocations of the evaluator.
# (declare -p guard first — a missing declaration would crash bash <4.4 under set -u)
if ! declare -p VERIFY_COMMANDS >/dev/null 2>&1 || [ "${#VERIFY_COMMANDS[@]}" -eq 0 ]; then
  emit NEEDS_SPEC_DECISION "loop.config.sh defines no VERIFY_COMMANDS — a loop needs a verifiable goal"
fi

# opt-in flake absorption: rerun ALL commands up to VERIFY_RETRIES more times on
# failure. 0 (default) = every red is trusted as-is. Honesty rules: a red-then-
# green rerun KEEPS the failing log (.loop/verify-flake.log — loop.sh journals it
# as VERIFY_FLAKE), and a rerun that stays red behaves exactly like today (the
# final failing log feeds the repeat-failure fingerprint unchanged).
: "${VERIFY_RETRIES:=0}"
case "$VERIFY_RETRIES" in *[!0-9]*|"") VERIFY_RETRIES=0 ;; esac
[ "$VERIFY_RETRIES" -le 2 ] || VERIFY_RETRIES=2

run_verify_pass() { # $1 log-file -> 0 when every command passed
  local vp_ok=1 vp_rc vp_cmd
  : > "$1"
  for vp_cmd in "${VERIFY_COMMANDS[@]}"; do
    echo "\$ $vp_cmd" >> "$1"
    if /bin/sh -c "$vp_cmd" >> "$1" 2>&1; then
      echo "[PASS] $vp_cmd" >> "$1"
    else
      vp_rc=$?
      echo "[FAIL] $vp_cmd (exit $vp_rc)" >> "$1"
      vp_ok=0
    fi
  done
  [ "$vp_ok" -eq 1 ]
}

verify_ok=1
if [ "$PREFLIGHT" -eq 1 ]; then
  # The normal evaluator ran immediately before stop-eval and already paid for
  # VERIFY_COMMANDS. Preflight is deliberately cheap and model-free: consume
  # only that iteration's non-empty, failure-free log.
  if [ ! -s .loop/last-verify.log ] || grep -q '^\[FAIL\]' .loop/last-verify.log; then
    verify_ok=0
  fi
else
  run_verify_pass .loop/last-verify.log || verify_ok=0
  attempt=1
  while [ "$verify_ok" -eq 0 ] && [ "$attempt" -le "$VERIFY_RETRIES" ]; do
    attempt=$((attempt + 1))
    # preserve the failing log BEFORE rerunning — if the rerun passes, this is the
    # honest record of the suspected flake; if it fails too, it is discarded so
    # last-verify.log stays fingerprint-comparable across iterations
    mv -f .loop/last-verify.log .loop/verify-flake.log
    if run_verify_pass .loop/last-verify.log; then
      verify_ok=1
      { echo "[FLAKE] verification failed, then passed on a full rerun (attempt $attempt of $((VERIFY_RETRIES + 1))) — the failing log is preserved in .loop/verify-flake.log"
        cat .loop/last-verify.log
      } > .loop/last-verify.log.tmp && mv .loop/last-verify.log.tmp .loop/last-verify.log
    else
      { echo "[RETRY] rerun $((attempt - 1))/$VERIFY_RETRIES still failing"
        cat .loop/last-verify.log
      } > .loop/last-verify.log.tmp && mv .loop/last-verify.log.tmp .loop/last-verify.log
      rm -f .loop/verify-flake.log   # persistent failure, not a flake
    fi
  done
fi

# ---------- 6. agent's declared state ----------
agent_state="CONTINUE"
agent_reason=""
if [ -f .loop/agent-state ]; then
  line=$(head -1 .loop/agent-state)
  agent_state=${line%% *}
  agent_reason=${line#* }
  if [ "$agent_reason" = "$line" ]; then agent_reason=""; fi
fi
case "$agent_state" in
  NEEDS_SPEC_DECISION|NEEDS_ARCHITECTURE_DECISION|NEEDS_DECOMPOSITION|BLOCKED)
    emit "$agent_state" "agent declared: ${agent_reason:-no reason given}"
    ;;
esac

if [ "$PREFLIGHT" -eq 1 ] && [ "$verify_ok" -ne 1 ]; then
  emit CONTINUE "deterministic preflight requires a non-empty, green .loop/last-verify.log"
fi

promotion_subject="agent declared ready but"
[ "$PREFLIGHT" -ne 1 ] || promotion_subject="deterministic preflight failed:"

# ---------- 6.5 requirements-ledger self-consistency (candidate promotion only) ----------
# The agent may not claim READY_FOR_REVIEW while its own requirements ledger
# says work remains: every REQ id defined by a contract heading must have a
# ledger row with status `met`. Deterministic (grep on two self-reports), so it
# runs before any model review is paid for. Not applied with --final: by then
# the gate reviewer has already judged every REQ analytically (stronger
# evidence), and a forced gate (--assume-ready) never had an agent claim to
# hold consistent. REQ ids come from HEADING lines only (### REQ-001: ...) —
# prose mentions (e.g. a sibling task's REQ in Non-goals) must not create
# obligations. Keep this extraction in sync with req_ids_from_contract() in
# loop.sh.
if { [ "$PREFLIGHT" -eq 1 ] \
     || { [ "$FINAL" -eq 0 ] && [ "$ASSUME_READY" -eq 0 ] \
          && [ "$agent_state" = "READY_FOR_REVIEW" ]; }; } \
   && [ "$verify_ok" -eq 1 ]; then
  req_ids=$(grep -E '^#{1,6}[[:space:]]*REQ-[0-9]+' .loop/docs/product-contract.md 2>/dev/null \
            | grep -oE 'REQ-[0-9]+' | sort -u || true)
  if [ -n "$req_ids" ]; then
    # One awk pass over the ledger: per REQ, its row COUNT and last status.
    # A REQ is satisfied only by EXACTLY ONE row whose status is exactly
    # `met` — a duplicate row pair (e.g. `met` + `regressed`, either order)
    # is a contradiction, not evidence, and a bare met-row grep would accept
    # it. Row grammar: `| REQ-nnn | status | evidence | iter |` (cells never
    # contain `|`, field 3 is the status; same trim style as 6.6).
    ledger_rows=$(awk -F'|' '
      /^\|[[:space:]]*REQ-[0-9]+[[:space:]]*\|/ {
        id=$2; st=$3
        gsub(/^[ \t]+/,"",id); gsub(/[ \t]+$/,"",id)
        gsub(/^[ \t]+/,"",st); gsub(/[ \t]+$/,"",st)
        n[id]++; s[id]=st
      }
      END { for (id in n) print id "\t" n[id] "\t" s[id] }
    ' .loop/docs/requirements-ledger.md 2>/dev/null || true)
    unmet=""
    while IFS= read -r rid; do
      row=$(printf '%s\n' "$ledger_rows" | awk -F'\t' -v want="$rid" '$1 == want { print; exit }')
      if [ -z "$row" ]; then
        unmet="$unmet $rid(no row)"
      elif [ "$(printf '%s' "$row" | awk -F'\t' '{print $2}')" != "1" ]; then
        unmet="$unmet $rid(duplicate rows)"
      elif [ "$(printf '%s' "$row" | awk -F'\t' '{print $3}')" != "met" ]; then
        unmet="$unmet $rid($(printf '%s' "$row" | awk -F'\t' '{print ($3 == "" ? "?" : $3)}'))"
      fi
    done <<EOF
$req_ids
EOF
    if [ -n "$unmet" ]; then
      emit CONTINUE "$promotion_subject requirements ledger does not show met:$unmet"
    fi
  fi
fi

# ---------- 6.6 acceptance-checklist self-consistency (candidate promotion only) ----------
# Same trust model as 6.5, finer grain: the acceptance checklist records the
# fine-grained expected behaviors (AC rows) and their verification status —
# including the implicit must-be expectations and the `run` rows that require
# actually OBSERVING the artifact. "The gate is green" is not the same claim
# as "every expected behavior was observed to hold" (a rendering migration can
# pass build/lint/tests and still draw nothing), so an agent may not claim
# READY_FOR_REVIEW while its own checklist says an expectation is unverified.
# Absent file or no AC rows = checklist not in use (older contracts): no
# obligation. Row grammar comes from kit/loop-docs/acceptance-checklist.md
# (`| AC-N | REQ | expectation | method | status | evidence |`); cells never
# contain `|`, so field 6 is the status. Trim per-cell whitespace only —
# BSD awk and gawk both accept this program.
if { [ "$PREFLIGHT" -eq 1 ] \
     || { [ "$FINAL" -eq 0 ] && [ "$ASSUME_READY" -eq 0 ] \
          && [ "$agent_state" = "READY_FOR_REVIEW" ]; }; } \
   && [ "$verify_ok" -eq 1 ]; then
  if [ -f .loop/docs/acceptance-checklist.md ]; then
    unverified=$(awk -F'|' '
      /^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
        id=$2; st=$6
        gsub(/^[ \t]+/,"",id); gsub(/[ \t]+$/,"",id)
        gsub(/^[ \t]+/,"",st); gsub(/[ \t]+$/,"",st)
        if (st != "verified") printf " %s(%s)", id, (st == "" ? "?" : st)
      }' .loop/docs/acceptance-checklist.md 2>/dev/null || true)
    if [ -n "$unverified" ]; then
      emit CONTINUE "$promotion_subject acceptance checklist has unverified rows:$unverified"
    fi
  fi
  # Obligations anchor to the HASH-FROZEN contract, not to the (agent-writable)
  # checklist file: every AC id the contract's Acceptance Criteria name as a
  # list item ("- AC-001 (run): ...") must have a checklist row with status
  # `verified`. Deleting or losing rows can therefore never shrink the
  # obligation set (mirror of 6.5's REQ-heading rule; removing an obligation
  # requires a contract revision + re-approval). List-item extraction only —
  # a prose mention of an AC id must not create an obligation.
  # leading id only — a criterion's text mentioning ANOTHER id must not
  # create an obligation for it
  ac_ids=$(sed -nE 's/^[[:space:]]*[-*][[:space:]]*(AC-[0-9]+).*/\1/p' \
           .loop/docs/product-contract.md 2>/dev/null | sort -u || true)
  if [ -n "$ac_ids" ]; then
    missing=""
    while IFS= read -r aid; do
      awk -F'|' -v want="$aid" '
        /^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
          id=$2; st=$6
          gsub(/^[ \t]+/,"",id); gsub(/[ \t]+$/,"",id)
          gsub(/^[ \t]+/,"",st); gsub(/[ \t]+$/,"",st)
          if (id == want && st == "verified") found=1
        }
        END { exit found ? 0 : 1 }' .loop/docs/acceptance-checklist.md 2>/dev/null \
        || missing="$missing $aid"
    done <<EOF
$ac_ids
EOF
    if [ -n "$missing" ]; then
      emit CONTINUE "$promotion_subject contract acceptance criteria lack a verified checklist row:$missing"
    fi
  fi
  # 6.6(c) — run-scoped id monotonicity: an id ever seen this run (including
  # rows APPENDED mid-run) must still exist as a row. The unverified-rows
  # check above already demands every EXISTING row be verified, so a vanished
  # id is the only way an admitted obligation escapes it. Like every check in
  # this tier it compares the agent's own artifacts (.loop/ac-seen is
  # agent-writable — deliberate tampering stays the gate reviewer's
  # territory; this catches the sloppy/forgetful path deterministically).
  if [ -s .loop/ac-seen ]; then
    vanished=""
    while IFS= read -r aid; do
      [ -n "$aid" ] || continue
      printf '%s\n' "$current_ac_ids" | grep -qx "$aid" || vanished="$vanished $aid"
    done < .loop/ac-seen
    if [ -n "$vanished" ]; then
      emit CONTINUE "$promotion_subject previously-recorded acceptance-checklist rows disappeared:$vanished — restore them or escalate a decision request"
    fi
  fi
  # 6.6(d) — method consistency: where a contract anchor names a method
  # ("- AC-001 (run): ..."), the row's method cell (field 5) must match. A
  # row silently reclassified run -> cmd would let "the code reads correct"
  # close an observation obligation — the exact failure mode the method
  # column exists to prevent. Anchors without a method token impose no
  # constraint (backcompat); a missing row was already refused above.
  ac_pairs=$(sed -nE 's/^[[:space:]]*[-*][[:space:]]*(AC-[0-9]+)[[:space:]]*\((cmd|run|human)\).*/\1 \2/p' \
             .loop/docs/product-contract.md 2>/dev/null | sort -u || true)
  if [ -n "$ac_pairs" ]; then
    weakened=""
    while read -r aid want_m; do
      [ -n "$aid" ] || continue
      row_m=$(awk -F'|' -v want="$aid" '
        /^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
          id=$2; m=$5
          gsub(/^[ \t]+/,"",id); gsub(/[ \t]+$/,"",id)
          gsub(/^[ \t]+/,"",m); gsub(/[ \t]+$/,"",m)
          if (id == want) { print m; exit }
        }' .loop/docs/acceptance-checklist.md 2>/dev/null || true)
      if [ -n "$row_m" ] && [ "$row_m" != "$want_m" ]; then
        weakened="$weakened $aid(contract:$want_m,row:$row_m)"
      fi
    done <<EOF
$ac_pairs
EOF
    if [ -n "$weakened" ]; then
      emit CONTINUE "$promotion_subject checklist methods differ from the contract's anchors:$weakened"
    fi
  fi
  # 6.6(e) — run-row evidence validity: a verified `run` row must cite either
  # the current evaluator log or an observation artifact. Normal evaluation
  # validates new/changed bytes without stamping the pre-commit HEAD; preflight
  # alone stamps them, while unchanged rows must remain current in both modes.
  run_rows=$(awk -F'|' '
    /^\|[[:space:]]*AC-[0-9]+[[:space:]]*\|/ {
      id=$2; expt=$4; m=$5; st=$6; ev=$7
      gsub(/^[ \t]+/,"",id); gsub(/[ \t]+$/,"",id)
      gsub(/^[ \t]+/,"",expt); gsub(/[ \t]+$/,"",expt)
      gsub(/^[ \t]+/,"",m);  gsub(/[ \t]+$/,"",m)
      gsub(/^[ \t]+/,"",st); gsub(/[ \t]+$/,"",st)
      gsub(/^[ \t]+/,"",ev); gsub(/[ \t]+$/,"",ev)
      if (m == "run" && st == "verified") print id "\t" expt "\t" ev
    }' .loop/docs/acceptance-checklist.md 2>/dev/null || true)
  if [ -n "$run_rows" ]; then
    bad_runs=""
    while IFS=$'\t' read -r aid expectation ev; do
      [ -n "$aid" ] || continue
      case "$ev" in
        *.loop/observations/*)
          # First relative observations token at a path boundary; absolute or
          # prefixed aliases do not match. Trailing prose punctuation is stripped.
          # Boundary set (start, whitespace, '(', '[', markdown backtick) is
          # shared with loop.sh's observation_tokens() — both sides must parse
          # a citation identically.
          obs=$(printf '%s\n' "$ev" \
                | grep -oE '(^|[[:space:]([`])\.loop/observations/[^[:space:]|]+' | head -1 \
                | sed -E 's/^[[:space:]([`]//' \
                | sed -E 's|[^A-Za-z0-9_./-]+$||' || true)
          if ! validate_observation "$aid" "$obs" "$expectation"; then
            bad_runs="$bad_runs $aid($OBS_REASON)"
          fi
          ;;
        *last-verify.log*) : ;;   # probe output cited in the gate's own log
        *) bad_runs="$bad_runs $aid(no observation artifact cited)" ;;
      esac
    done <<EOF
$run_rows
EOF
    if [ -n "$bad_runs" ]; then
      emit CONTINUE "$promotion_subject run-method rows lack valid observation evidence:$bad_runs"
    fi
  fi
fi

if [ "$PREFLIGHT" -eq 1 ]; then
  emit SUCCESS_CANDIDATE "preflight ok"
fi

# ---------- 7. success gate ----------
gate_state="$agent_state"
if [ "$ASSUME_READY" -eq 1 ]; then
  # forced gate: escalation states already emitted above (section 6), so any
  # remaining agent state — CONTINUE, READY, or a malformed line — counts as
  # ready here. Do NOT string-match "CONTINUE" exactly: betting on an exact
  # self-report format is the same bug class this flag exists to bypass.
  gate_state="READY_FOR_REVIEW"
fi
if [ "$verify_ok" -eq 1 ] && [ "$gate_state" = "READY_FOR_REVIEW" ]; then
  if [ "$FINAL" -eq 1 ]; then
    if [ "$agent_state" = "READY_FOR_REVIEW" ]; then
      emit SUCCESS "all verification commands pass; agent declared ready; no unresolved contract-touching drift"
    fi
    emit SUCCESS "all verification commands pass; gate forced after MET stop-evals (agent had not declared ready)"
  fi
  emit SUCCESS_CANDIDATE "verify green + agent ready — pending review + evidence"
fi
if [ "$FINAL" -eq 1 ]; then
  emit BLOCKED "final re-check failed (verify_ok=$verify_ok, agent_state=$agent_state)"
fi

# ---------- 8. stagnation & repeated identical failure ----------
# note: .loop/docs updates (progress etc.) are excluded from `changed`, so an
# iteration that only wrote its log counts as stagnant — that is intentional.
if [ -z "$changed" ]; then
  n=$(($(cat .loop/stagnation-count 2>/dev/null || echo 0) + 1))
  echo "$n" > .loop/stagnation-count
  if [ "$n" -ge "$STAGNATION_N" ]; then
    emit STALLED "no project file changes for $n consecutive iterations"
  fi
else
  echo 0 > .loop/stagnation-count
fi

if [ "$verify_ok" -eq 0 ]; then
  # timing/address normalization before fingerprinting. \b is a GNU extension —
  # BSD sed treats it literally and the timing strip silently never matches, so
  # the word boundary is spelled ([^[:alnum:]_]|$) with the boundary char
  # restored via \2 (same semantics on BSD, GNU, and MSYS sed). Without this,
  # every failing log carrying a changing "1.23s" fingerprints uniquely and
  # neither the identical-repeat rule nor the oscillation window can ever fire.
  fp=$(sed -E 's/[0-9]+(\.[0-9]+)?s([^[:alnum:]_]|$)/\2/g; s/0x[0-9a-fA-F]+//g' .loop/last-verify.log | sha256)
  echo "$fp" >> .loop/fail-fingerprints
  recent=$(tail -"$REPEAT_FAIL_N" .loop/fail-fingerprints)
  count=$(echo "$recent" | grep -c . || true)
  uniqc=$(echo "$recent" | sort -u | grep -c . || true)
  if [ "$count" -ge "$REPEAT_FAIL_N" ] && [ "$uniqc" -eq 1 ]; then
    emit BLOCKED "identical verification failure repeated $REPEAT_FAIL_N times — needs a different approach or human help"
  fi
  # A/B oscillation: the identical-repeat rule above only catches N-in-a-row
  # of ONE fingerprint; a loop ping-ponging between two failure states (the
  # fix for A breaks B, the fix for B breaks A) never trips it. Over a window
  # of 2*N failures, no NEW fingerprint (<=2 distinct) means the loop is
  # cycling, not progressing — same terminal state as the identical rule.
  # Skipped when REPEAT_FAIL_N=1: that config already blocks on any repeat,
  # and a 2-wide window would block on the first two (different) failures.
  if [ "$REPEAT_FAIL_N" -ge 2 ]; then
    cyc_n=$((REPEAT_FAIL_N * 2))
    recent=$(tail -"$cyc_n" .loop/fail-fingerprints)
    count=$(echo "$recent" | grep -c . || true)
    uniqc=$(echo "$recent" | sort -u | grep -c . || true)
    if [ "$count" -ge "$cyc_n" ] && [ "$uniqc" -le 2 ]; then
      emit BLOCKED "verification failures cycling between $uniqc states over the last $cyc_n failing iterations — needs a different approach or human help"
    fi
  fi
fi

if [ "$verify_ok" -eq 1 ]; then
  emit CONTINUE "verify green but agent not ready (state: $agent_state)"
fi
emit CONTINUE "verification still failing — see .loop/last-verify.log"
