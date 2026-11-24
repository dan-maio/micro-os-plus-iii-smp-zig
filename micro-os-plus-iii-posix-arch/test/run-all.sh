#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-all.sh -- build and run every test of the POSIX port, one after the
# other, and print a verdict table.
#
#     test/run-all.sh [test...]          (default: all of zig-out/bin)
#
# Each test runs in a fresh folder under zig-out/run/<test> (the SD tests
# create their disk.img there); its output goes to zig-out/run/<test>.log.
# A test passes when it exits with 0 within its time limit.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG="${ZIG:-zig}"
cd "$HERE"
"$ZIG" build || exit 2

RUN="$HERE/zig-out/run"
mkdir -p "$RUN"

if [ $# -gt 0 ]; then
  TESTS=("$@")
else
  mapfile -t TESTS < <(ls zig-out/bin)
fi

fails=0
for t in "${TESTS[@]}"; do
  dir="$RUN/$t"
  rm -rf "$dir"; mkdir -p "$dir"
  start=$(date +%s)
  ( cd "$dir" && timeout 300 "$HERE/zig-out/bin/$t" ) > "$RUN/$t.log" 2>&1
  code=$?
  secs=$(( $(date +%s) - start ))
  if [ $code -eq 0 ]; then
    printf "%-22s PASS  %3ss\n" "$t" "$secs"
  else
    printf "%-22s FAIL  %3ss  (exit %d, see %s)\n" "$t" "$secs" "$code" "$RUN/$t.log"
    fails=$((fails + 1))
  fi
done
rm -rf "$RUN"/*/disk.img
echo "-- ${#TESTS[@]} tests, $fails failed"
[ $fails -eq 0 ]
