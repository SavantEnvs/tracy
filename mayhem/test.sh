#!/usr/bin/env bash
#
# mayhem/test.sh — Tracy functional oracle (tools built by mayhem/build.sh with normal flags).
# exit 0 = pass. Two parts:
#   1. upstream's unit test tests/lockdeadlocks (lock-deadlock detection; one `ok` line per case,
#      assert() aborts at the first failure). tests/tracy is a client demo app, not a test.
#   2. upstream's own tools end to end on committed inputs, diffed against golden output:
#   tracy-import-chrome  mayhem/test/chrome.json  -> .tracy   (Chrome JSON importer + Worker::Write)
#   tracy-import-fuchsia mayhem/test/fuchsia.fxt  -> .tracy   (Fuchsia FXT importer + Worker::Write)
#   tracy-csvexport {stats, -u unwrap, -m messages} on each  (FileRead + Worker trace loader)
#
# PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

T="$SRC/_mayhem/test"
for b in tracy-import-chrome tracy-import-fuchsia tracy-csvexport; do
  [ -x "$T/$b" ] || { echo "missing $T/$b — mayhem/build.sh did not build it" >&2; emit_ctrf tracy-golden 0 1; exit 1; }
done
work="$(mktemp -d "${TMPDIR:-/tmp}/tracy-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
G="$SRC/mayhem/test"
passed=0 failed=0
check() {  # check <name> <golden> <cmd...>
  local name="$1" golden="$2"; shift 2
  if "$@" > "$work/$name.out" 2> "$work/$name.err" && diff -u "$golden" "$work/$name.out"; then
    echo "PASS $name"; passed=$((passed+1))
  else
    echo "FAIL $name"; cat "$work/$name.err" >&2; failed=$((failed+1))
  fi
}
for fmt in chrome:chrome.json fuchsia:fuchsia.fxt; do
  n="${fmt%%:*}" in="${fmt#*:}"
  # The importer writes <dir>/<n>.tracy; the capture name stored in it is that file name.
  if (cd "$work" && "$T/tracy-import-$n" "$G/$in" "$n.tracy" > /dev/null) && [ -s "$work/$n.tracy" ]; then
    check "$n-stats"    "$G/$n.stats.csv"    "$T/tracy-csvexport" "$work/$n.tracy"
    check "$n-unwrap"   "$G/$n.unwrap.csv"   "$T/tracy-csvexport" -u "$work/$n.tracy"
    check "$n-messages" "$G/$n.messages.csv" "$T/tracy-csvexport" -m "$work/$n.tracy"
  else
    echo "FAIL $n-import"; failed=$((failed+3))
  fi
done

# Upstream unit test: each case prints "<name>... ok"; a failed assert aborts the binary, so the case
# without an `ok` fails and every case after it never ran (counted failed too). Case names, in order,
# come from the test source.
#
# Known upstream failure, skipped by name: "convoy without cycle" (test.cpp, fdd94f55) uses waiter
# thread ids 200+w, so waiter 0 is TB, a shared holder; TB holding shared while waiting exclusive is
# the upgrade self-deadlock TracyLocks.cpp reports (and "upgrade with co-holders" asserts), so the
# case's groups.size()==0 assert fails on unmodified upstream. When the run aborts in that case it and
# the cases it kept from running are counted skipped, not failed; once upstream fixes it they pass.
KNOWN_UPSTREAM_FAIL=("convoy without cycle")
known_fail() { local k; for k in "${KNOWN_UPSTREAM_FAIL[@]}"; do [ "$k" = "$1" ] && return 0; done; return 1; }
L="$SRC/_mayhem/lockdeadlocks/lockdeadlocks-test"
mapfile -t ld_names < <(grep -o 'Run( "[^"]*"' "$SRC/tests/lockdeadlocks/test.cpp" | sed 's/^Run( "//; s/"$//')
ld_total=${#ld_names[@]}
ld_ok=0 ld_fail=0 ld_skip=0
if [ "$ld_total" -eq 0 ]; then
  echo "FAIL lockdeadlocks: no cases found in tests/lockdeadlocks/test.cpp" >&2; ld_fail=1
elif [ -x "$L" ]; then
  stdbuf -oL "$L" > "$work/lockdeadlocks.out" 2>&1; rc=$?
  cat "$work/lockdeadlocks.out"
  ld_ok=$(grep -c 'ok$' "$work/lockdeadlocks.out")
  [ "$ld_ok" -le "$ld_total" ] || ld_ok=$ld_total
  rest=$(( ld_total - ld_ok ))
  if [ "$rc" -eq 0 ] && [ "$rest" -eq 0 ] && grep -q '^All deadlock detection tests passed\.$' "$work/lockdeadlocks.out"; then
    :
  elif [ "$rc" -ne 0 ] && [ "$rest" -gt 0 ] && known_fail "${ld_names[$ld_ok]}" \
       && grep -qF "${ld_names[$ld_ok]}... " "$work/lockdeadlocks.out"; then
    echo "SKIP lockdeadlocks: '${ld_names[$ld_ok]}' is a known upstream failure; $rest case(s) skipped"
    ld_skip=$rest
  else
    [ "$rest" -gt 0 ] || { rest=1; ld_ok=$(( ld_ok - 1 )); }
    echo "FAIL lockdeadlocks: '${ld_names[$ld_ok]:-?}' and later cases (exit $rc)"
    ld_fail=$rest
  fi
  echo "lockdeadlocks: $ld_ok passed, $ld_fail failed, $ld_skip skipped (exit $rc)"
else
  echo "missing $L — mayhem/build.sh did not build it" >&2
  ld_fail=$ld_total
fi
passed=$(( passed + ld_ok )) failed=$(( failed + ld_fail ))
emit_ctrf tracy-golden+lockdeadlocks "$passed" "$failed" "$ld_skip"
