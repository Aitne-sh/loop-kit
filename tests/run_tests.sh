#!/usr/bin/env bash
# run_tests.sh — driver for the zero-token E2E suite for loop-kit.
#
# The assertions live in tests/suite/*.sh (each sources tests/lib.sh and is
# independently runnable); this file only decides WHAT runs, in what order, and
# with how much concurrency, then aggregates the counts.
#
#   ./tests/run_tests.sh                 # parallel lane at -j <auto>, then the serial lane
#   ./tests/run_tests.sh -j1             # everything strictly in manifest order (baseline mode)
#   ./tests/run_tests.sh --only 50-discard   # one file (substring match); repeatable
#   ./tests/run_tests.sh --list          # what exists, and which lane it is in
#   LOOP_TEST_TIMING=1 ./tests/run_tests.sh   # + a slowest-sections table
#
# LANES. tests/suite/manifest.txt classifies every file as `parallel` or `serial`;
# an unclassified or missing file is a hard error, so a new suite file cannot be
# silently skipped. The `serial` lane runs alone, after the parallel lane drains,
# and holds exactly the tests that cannot tolerate a sibling lane:
#   - PID-identity tests that SIGKILL a real loop.sh and then assert the recorded
#     pid is dead. `ps -p <pid> -o command= | grep loop.sh` is machine-global, so a
#     pid recycled by a sibling lane's live loop.sh would read as "still alive".
#   - watchdog / interrupt tests that pin MAX_ITER_SECONDS=1 or observe process
#     topology, where CPU contention changes what is being measured.
# Everything else — including almost all of the fleet — waits on observable state
# with bounded polls and is lane-safe. Move a test into `serial` only for one of
# the two reasons above; widening it costs wall clock for nothing.
#
# Still do NOT run two copies of this driver (or a driver + a real fleet)
# concurrently: the lane rules above assume the suite owns its own PID namespace.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="$ROOT/tests/suite"
MANIFEST="$SUITE/manifest.txt"

ncpu() {
  local n=""
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) \
    || n=$(sysctl -n hw.ncpu 2>/dev/null) \
    || n=$(nproc 2>/dev/null) || n=2
  case "$n" in ''|*[!0-9]*) n=2 ;; esac
  echo "$n"
}

JOBS=""
LIST=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -j)       JOBS="${2:-}"; shift 2 ;;
    -j*)      JOBS="${1#-j}"; shift ;;
    --only)   ONLY="$ONLY ${2:-}"; shift 2 ;;
    --only=*) ONLY="$ONLY ${1#--only=}"; shift ;;
    --list)   LIST=1; shift ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "usage: $0 [-j N] [--only <name>] [--list]" >&2; exit 2 ;;
  esac
done
if [ -z "$JOBS" ]; then
  # The parallel stage is work-bound, not critical-path bound (measured: wall time
  # tracks total work / -j almost exactly), so -j is THE knob. The cap is
  # deliberate rather than optimal: this suite normally runs on a workstation that
  # is also hosting agent sessions, and each lane forks hard. Leave a core free on
  # small runners, never take more than 4. Raise it explicitly (-j8) on an idle box.
  JOBS=$(( $(ncpu) - 1 ))
  [ "$JOBS" -ge 2 ] || JOBS=2
  [ "$JOBS" -le 4 ] || JOBS=4
fi
case "$JOBS" in ''|*[!0-9]*|0) echo "-j must be a positive integer" >&2; exit 2 ;; esac

# ---------- manifest: the single source of truth for order and lane ----------
[ -f "$MANIFEST" ] || { echo "missing $MANIFEST" >&2; exit 2; }

NAMES=""; LANES=""
while read -r f lane; do
  case "$f" in ''|\#*) continue ;; esac
  [ -f "$SUITE/$f" ] || { echo "manifest lists a missing file: $f" >&2; exit 2; }
  case "$lane" in
    parallel|serial) ;;
    *) echo "$f: lane must be 'parallel' or 'serial' (got '${lane:-}')" >&2; exit 2 ;;
  esac
  NAMES="$NAMES $f"; LANES="$LANES $f:$lane"
done < "$MANIFEST"

# every file on disk must be classified — a new suite file cannot slip through
for f in "$SUITE"/*.sh; do
  b=$(basename "$f")
  case " $NAMES " in
    *" $b "*) ;;
    *) echo "$b exists but is not classified in $MANIFEST" >&2; exit 2 ;;
  esac
done

lane_of() { # $1 file -> lane
  local e
  for e in $LANES; do
    [ "${e%%:*}" = "$1" ] && { echo "${e##*:}"; return 0; }
  done
  echo parallel
}

selected() { # $1 file -> 0 if it should run
  local pat
  [ -n "$ONLY" ] || return 0
  for pat in $ONLY; do
    case "$1" in *"$pat"*) return 0 ;; esac
  done
  return 1
}

if [ "$LIST" -eq 1 ]; then
  for f in $NAMES; do printf '%-28s %s\n' "$f" "$(lane_of "$f")"; done
  exit 0
fi

RUN=""
for f in $NAMES; do selected "$f" && RUN="$RUN $f"; done
[ -n "$RUN" ] || { echo "no suite file matches --only$ONLY" >&2; exit 2; }
# shellcheck disable=SC2086  # $RUN is a deliberate whitespace-separated list
NRUN=$(printf '%s\n' $RUN | wc -l | tr -d ' ')
[ "$NRUN" -gt 1 ] || JOBS=1   # a single file has nothing to run beside it

# ---------- driver state ----------
DWORK="$(mktemp -d /tmp/loop-suite.XXXXXX)"
RES="$DWORK/results"
mkdir -p "$RES"
PIDS=""

dcleanup() {
  local p
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  if [ -n "$PIDS" ]; then
    sleep 2
    for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
  fi
  rm -rf "$DWORK"
}
trap dcleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# One `loop.sh init` for the whole suite instead of one per lane; make_fixture
# clones it (see tests/lib.sh).
export LOOP_TEST_GOLDEN="$DWORK/golden"
"$ROOT/bin/loop.sh" init "$LOOP_TEST_GOLDEN" >/dev/null

if [ -n "${LOOP_TEST_TIMING:-}" ]; then
  export LOOP_TEST_TIMING_FILE="$DWORK/timing.tsv"
  : > "$LOOP_TEST_TIMING_FILE"
fi
# Lanes share the CPU: raise the hang backstops so contention reads as a slower
# suite, never as a spurious timeout FAIL. Assertion thresholds are untouched.
#
# The backstops scale WITH -j instead of sitting at one fixed pair, because how
# much a bounded wait gets stretched is set by how wide the lane is. A run widened
# past the auto cap — CI pins -j4, including on a 3-core macOS runner — stretches
# every poll, and a ceiling frozen at the -j2 value would convert that into a
# spurious FAIL, which is the one thing these numbers must never do. -j2 still
# resolves to exactly 2 / 240s, so the default lane is byte-compatible. The cap
# keeps a genuine hang detectable in bounded time on a wide idle box (-j8 -> 720s).
if [ "$JOBS" -gt 1 ]; then
  scale=$JOBS; [ "$scale" -le 6 ] || scale=6
  export LOOP_TEST_SUP_WAIT_MAX="${LOOP_TEST_SUP_WAIT_MAX:-$(( 120 * scale ))}"
  export LOOP_TEST_POLL_SCALE="${LOOP_TEST_POLL_SCALE:-$scale}"
fi

reap() { # drop finished pids from PIDS; echo how many are still running
  local p live=""
  for p in $PIDS; do kill -0 "$p" 2>/dev/null && live="$live $p"; done
  PIDS="$live"
  # shellcheck disable=SC2086  # $live is a deliberate whitespace-separated list
  printf '%s\n' $live | grep -c . || true
}

run_stage() { # $1 lane, $2 max concurrency
  local lane="$1" j="$2" f n
  for f in $RUN; do
    [ "$(lane_of "$f")" = "$lane" ] || continue
    if [ "$j" -eq 1 ]; then
      echo "--- $f"
      LOOP_TEST_RESULT="$RES/$f.res" bash "$SUITE/$f" || true
      continue
    fi
    while :; do
      n=$(reap)
      [ "$n" -lt "$j" ] && break
      sleep 0.1
    done
    printf '  -> %s\n' "$f"
    LOOP_TEST_RESULT="$RES/$f.res" bash "$SUITE/$f" > "$RES/$f.log" 2>&1 &
    PIDS="$PIDS $!"
  done
  while :; do
    n=$(reap)
    [ "$n" -eq 0 ] && break
    sleep 0.2
  done
  [ "$j" -eq 1 ] && return 0
  # replay buffered lane output in manifest order: deterministic regardless of
  # which lane finished first
  for f in $RUN; do
    [ "$(lane_of "$f")" = "$lane" ] || continue
    echo "--- $f"
    [ -f "$RES/$f.log" ] && cat "$RES/$f.log"
  done
  return 0
}

STARTED=$SECONDS
echo "suite: $NRUN files, -j$JOBS"
run_stage parallel "$JOBS"
run_stage serial 1

# ---------- aggregate ----------
PASS=0; FAIL=0; FAILED=""
for f in $RUN; do
  if [ ! -f "$RES/$f.res" ]; then
    FAIL=$((FAIL + 1)); FAILED="$FAILED $f(no-result)"
    continue
  fi
  p=$(sed -n 's/^PASS=//p' "$RES/$f.res")
  q=$(sed -n 's/^FAIL=//p' "$RES/$f.res")
  n=$(sed -n 's/^FAILED=//p' "$RES/$f.res")
  rc=$(sed -n 's/^RC=//p' "$RES/$f.res")
  PASS=$((PASS + ${p:-0}))
  FAIL=$((FAIL + ${q:-0}))
  FAILED="$FAILED$n"
  # a lane that died mid-file (set -e) reports its partial counts plus a nonzero
  # rc; surface that as its own failure so a truncated lane can never read green
  case "${rc:-0}" in
    0|1) ;;                       # 1 = assertion failures, already counted
    *) FAIL=$((FAIL + 1)); FAILED="$FAILED $f(exit $rc)" ;;
  esac
done

if [ -n "${LOOP_TEST_TIMING:-}" ] && [ -s "$LOOP_TEST_TIMING_FILE" ]; then
  echo
  echo "slowest sections:"
  sort -rn "$LOOP_TEST_TIMING_FILE" | head -30 \
    | awk -F'\t' '{ printf "  %5ds  %-24s %s\n", $1, $2, $3 }'
fi

echo
echo "passed: $PASS  failed: $FAIL"
echo "wall: $(( (SECONDS - STARTED) / 60 ))m $(( (SECONDS - STARTED) % 60 ))s  (-j$JOBS)"
if [ "$FAIL" -gt 0 ]; then
  echo "failed tests:$FAILED"
  exit 1
fi
