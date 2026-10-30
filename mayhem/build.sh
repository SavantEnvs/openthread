#!/usr/bin/env bash
#
# mayhem/build.sh — build OpenThread's fuzz harnesses (tests/fuzz, nexus platform) and the nexus
# functional tests. Runs in the commit image as `mayhem` in /mayhem. Re-runnable and offline: the only
# external input is the in-tree third_party/mbedtls/repo submodule (checked out with the source).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

FUZZERS="cli dnssd_server icmp6 ip6 mdns radio-one-node srp_server trel"
NEXUS_TESTS="1_1_5_1_1 1_1_5_2_1 1_1_5_5_1 1_3_SRP_TC_1 1_4_TREL_TC_1 1_4_DNS_TC_1"

# Sourced from the checkout, not fetched: fail clearly if the submodule is missing.
[ -f third_party/mbedtls/repo/CMakeLists.txt ] || { echo "third_party/mbedtls/repo is empty (submodule not checked out)" >&2; exit 1; }

# Re-configuring an existing nexus build dir fails (OT_PLATFORM resolves to a bogus value), so always build from scratch.
rm -rf build
mkdir -p build/obj

# 1) Sanitized fuzz build. -fsanitize=fuzzer-no-link instruments the whole project for coverage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/obj/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/obj/lsan_off.o

FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -GNinja -S . -B build/fuzz \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$SRC/build/obj/lsan_off.o" \
    -DOT_COMPILE_WARNING_AS_ERROR=OFF \
    -DOT_FUZZ_TARGETS=ON \
    -DOT_NEXUS_BUILD_TESTS=OFF \
    -DOT_PLATFORM=nexus \
    -DOT_THREAD_VERSION=1.4 \
    -DOT_APP_CLI=OFF -DOT_APP_NCP=OFF -DOT_APP_RCP=OFF \
    -DOT_PROJECT_CONFIG="$SRC/tests/nexus/openthread-core-nexus-config.h"
targets=""
for f in $FUZZERS; do targets="$targets $f-fuzzer"; done
# shellcheck disable=SC2086
ninja -C build/fuzz -j"$MAYHEM_JOBS" $targets

# 2) Per fuzzer: the libFuzzer binary, and a run-once standalone reproducer relinked from the same objects.
for f in $FUZZERS; do
    n="${f//_/-}"   # Mayhem target slugs use '-' instead of '_'
    cp "build/fuzz/tests/fuzz/$f-fuzzer" "/mayhem/$n-fuzzer"
    cmd="$(ninja -C build/fuzz -t commands "$f-fuzzer" | tail -n 1)"
    out=""
    for tok in $cmd; do
        case "$tok" in
            -fsanitize=fuzzer) tok="$SRC/build/obj/standalone_main.o" ;;
            "tests/fuzz/$f-fuzzer") tok="/mayhem/$n-fuzzer-standalone" ;;
        esac
        out="$out $tok"
    done
    ( cd build/fuzz && eval "$out" )
done

# 3) Functional tests with the project's NORMAL flags (independent, unsanitized build).
cmake -GNinja -S . -B build/test \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
    -DOT_COMPILE_WARNING_AS_ERROR=OFF \
    -DOT_NEXUS_BUILD_TESTS=ON \
    -DOT_PLATFORM=nexus \
    -DOT_THREAD_VERSION=1.4 \
    -DOT_APP_CLI=OFF -DOT_APP_NCP=OFF -DOT_APP_RCP=OFF \
    -DOT_PROJECT_CONFIG="$SRC/tests/nexus/openthread-core-nexus-config.h"
targets=""
for t in $NEXUS_TESTS; do targets="$targets nexus_$t"; done
# shellcheck disable=SC2086
ninja -C build/test -j"$MAYHEM_JOBS" $targets
