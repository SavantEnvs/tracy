#!/usr/bin/env bash
#
# mayhem/build.sh — build Tracy's fuzz targets and the functional-test tools.
#
# Runs inside the commit image as `mayhem` in /mayhem; offline-capable and re-runnable. The CMake
# project in mayhem/fuzz/ builds upstream's TracyServer library (cmake/server.cmake) and tools against
# the dependencies the Dockerfile cached under /opt/toolchains/deps (upstream downloads them with CPM).
#
#   _mayhem/fuzz  libFuzzer harnesses (+ -standalone reproducers): TracyServer and harness with
#                 $SANITIZER_FLAGS + SanCov, DWARF 3            -> /mayhem/fuzz_*
#   _mayhem/afl   upstream's tracy-import-chrome / tracy-import-fuchsia CLIs and the libbacktrace
#                 harness, afl-clang-fast with $SANITIZER_FLAGS, DWARF 3 (file-input AFL targets)
#                 -> /mayhem/tracy-import-*, /mayhem/backtrace_elf
#   _mayhem/test  the same CLIs + tracy-csvexport with normal flags, for mayhem/test.sh
#   _mayhem/lockdeadlocks  upstream's tests/lockdeadlocks unit test (asserts kept), for mayhem/test.sh
#
# Build dirs live under _mayhem/, which upstream's .gitignore (/_*/**) already ignores.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/_mayhem"
# Linked into every fuzz, -standalone and AFL harness binary: LeakSanitizer off, ASan/UBSan on.
LSAN_OFF="$SRC/mayhem/lsan_off.cc"

# UBSan's `alignment` check is relaxed (only that check; ASan and the rest of UBSan stay on and
# halting): Tracy's event structs (server/TracyEvent.hpp, MessageData, ZoneEvent, ...) are
# #pragma pack(1) by design and the loader binds references to their fields, so the check fires on
# every valid trace (TracyWorker.cpp:883, first message of a trace imported from a 1-event JSON).
RELAX_UB="-fno-sanitize=alignment"

# 1) libFuzzer harnesses. -fsanitize=fuzzer-no-link puts SanCov on TracyServer too, so the fuzzer
#    sees coverage of the library, not only the harness.
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS $RELAX_UB -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake -S mayhem/fuzz -B "$B/fuzz" -G Ninja -DMAYHEM_FUZZ=ON -DLSAN_OFF="$LSAN_OFF" \
      -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build "$B/fuzz" -j"$MAYHEM_JOBS" --target \
      fuzz_trace_load fuzz_trace_load-standalone \
      fuzz_trace_write fuzz_trace_write-standalone \
      fuzz_broadcast fuzz_broadcast-standalone
for t in fuzz_trace_load fuzz_trace_write fuzz_broadcast; do
  install -m 0755 "$B/fuzz/$t" "$SRC/$t"
  install -m 0755 "$B/fuzz/$t-standalone" "$SRC/$t-standalone"
done

# 2) AFL file-input targets: the importer CLIs (their main() exit()s on some malformed input, so they
#    are fuzzed as the real programs), and backtrace_elf (libbacktrace state is unfreeable by design).
AFL_FLAGS="-O1 $SANITIZER_FLAGS $RELAX_UB $DEBUG_FLAGS"
CC=afl-clang-fast CXX=afl-clang-fast++ AFL_QUIET=1 \
  cmake -S mayhem/fuzz -B "$B/afl" -G Ninja -DMAYHEM_TOOLS=ON -DMAYHEM_BACKTRACE=ON -DLSAN_OFF="$LSAN_OFF" \
      -DCMAKE_C_FLAGS="$AFL_FLAGS" -DCMAKE_CXX_FLAGS="$AFL_FLAGS"
AFL_QUIET=1 cmake --build "$B/afl" -j"$MAYHEM_JOBS" --target tracy-import-chrome tracy-import-fuchsia backtrace_elf
install -m 0755 "$B/afl/tracy-import-chrome" "$SRC/tracy-import-chrome"
install -m 0755 "$B/afl/tracy-import-fuchsia" "$SRC/tracy-import-fuchsia"
install -m 0755 "$B/afl/backtrace_elf" "$SRC/backtrace_elf"

# 3) Functional-test tools with the project's normal (release) flags, no sanitizers.
cmake -S mayhem/fuzz -B "$B/test" -G Ninja -DMAYHEM_TOOLS=ON -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$B/test" -j"$MAYHEM_JOBS" --target tracy-import-chrome tracy-import-fuchsia tracy-csvexport

# 4) Upstream's own unit test, tests/lockdeadlocks (DetectLockDeadlocks, which Worker(FileRead&) runs
#    on every loaded trace). No CMAKE_BUILD_TYPE: its checks are assert()s, and Release would define
#    NDEBUG and compile them out. PPQSort comes from the Dockerfile's cache instead of ~/.cache/cpm.
cmake -S tests/lockdeadlocks -B "$B/lockdeadlocks" -G Ninja \
      -DPPQSORT_INCLUDE_DIR=/opt/toolchains/deps/PPQSort-1.0.6/src/include \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$B/lockdeadlocks" -j"$MAYHEM_JOBS" --target lockdeadlocks-test
