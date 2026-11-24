#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-all.sh -- run every test built for a board, one after the other.
#
#     zig build -Dboard=pico2 && test/run-all.sh pico2 [seconds-per-test]
#
# Prints one PASS/FAIL line per test and a total; exits non-zero on any
# failure. The logs are in zig-out/hw-logs/<board>/.
# -----------------------------------------------------------------------------
set -uo pipefail
BOARD="${1:?board}"
SECS="${2:-300}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${FIRMWARE_DIR:-$PWD/zig-out/firmware/$BOARD}"
pass=0 fail=0 failed=()
for elf in "$DIR"/*.elf; do
  name="$(basename "$elf" .elf)"
  if bash "$HERE/hw.sh" "$BOARD" "$elf" "$SECS" > /dev/null 2>&1; then
    printf '%-20s PASS\n' "$name"; pass=$((pass + 1))
  else
    printf '%-20s FAIL\n' "$name"; fail=$((fail + 1)); failed+=("$name")
  fi
done
echo "-- $BOARD: $pass passed, $fail failed ${failed[*]:-}"
[[ $fail -eq 0 ]]
