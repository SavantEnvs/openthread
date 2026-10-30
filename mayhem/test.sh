#!/usr/bin/env bash
#
# mayhem/test.sh — RUN OpenThread's nexus simulation tests (built by mayhem/build.sh with normal flags).
# Each test forms a Thread network in the nexus simulator, asserts protocol behavior with
# VerifyOrQuit(...), exports a JSON trace of the exchanged packets, and prints "All tests passed" last.
# A test counts as passed only if it exits 0, prints that marker AND wrote a non-trivial trace, so a
# no-op binary cannot pass.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

NEXUS_TESTS="1_1_5_1_1 1_1_5_2_1 1_1_5_5_1 1_3_SRP_TC_1 1_4_TREL_TC_1 1_4_DNS_TC_1"

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

work="$(mktemp -d "${TMPDIR:-/tmp}/nexus-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

passed=0 failed=0
for t in $NEXUS_TESTS; do
  bin="$SRC/build/test/tests/nexus/nexus_$t"
  if [ ! -x "$bin" ]; then
    echo "missing test binary $bin (mayhem/build.sh did not build it)" >&2
    failed=$((failed + 1)); continue
  fi
  d="$work/$t"; mkdir -p "$d"
  if ( cd "$d" && OT_NEXUS_PCAP_FILE="test_$t.pcapng" "$bin" "" "test_$t.json" ) >"$d/out.log" 2>&1 \
     && tail -n 1 "$d/out.log" | grep -q 'All tests passed$' \
     && [ "$(wc -c < "$d/test_$t.json" 2>/dev/null || echo 0)" -gt 1000 ] \
     && grep -q '"' "$d/test_$t.json"; then
    echo "PASS nexus_$t"; passed=$((passed + 1))
  else
    echo "FAIL nexus_$t"; tail -n 20 "$d/out.log" >&2; failed=$((failed + 1))
  fi
done

emit_ctrf "nexus" "$passed" "$failed" 0
