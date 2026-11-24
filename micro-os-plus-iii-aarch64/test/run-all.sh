#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run-all.sh -- run the board's tests one after the other, with a verdict table.
#
#     test/run-all.sh [test ...]        (default: every built test)
#
# Each test goes through test/hw.sh: an OpenOCD watchdog reset of the Pi,
# 10 s for it to boot, then the image is loaded and run to its verdict, in
# at most 3 minutes.
# The logs are zig-out/hw-logs/rpi4b/<test>.log.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FW="$ROOT/zig-out/firmware/rpi4b"

all=(smp-test0 smp-test1 smp-test2 smp-test3 smp-test4 smp-mat-test
     smp-pro-cons-test mutex-stress rtos-apis cmsis-os-validator
     sd_test smp-num-test smp-pipeline-test smp-mat-sdcard-test
     smp-mem-test smp-mem-inter-test)
tests=("$@")
((${#tests[@]})) || tests=("${all[@]}")

# Every test must end within 3 minutes (the user's limit), the reset and the
# load included.
secs_for () {
  echo 180
}

summary=()
failed=0
for t in "${tests[@]}"; do
  if [[ ! -f "$FW/$t.elf" ]]; then
    summary+=("$(printf '%-22s NOT BUILT' "$t")"); failed=$((failed + 1)); continue
  fi
  start=$(date +%s)
  if (cd "$ROOT" && bash test/hw.sh rpi4b "$FW/$t.elf" "$(secs_for "$t")" > /dev/null 2>&1); then
    v=PASS
  else
    v=FAIL; failed=$((failed + 1))
  fi
  summary+=("$(printf '%-22s %-5s %4ds' "$t" "$v" $(( $(date +%s) - start )))")
  echo "${summary[-1]}"
done

echo
printf '%s\n' "${summary[@]}"
echo "-- ${#tests[@]} tests, $failed failed"
[[ $failed -eq 0 ]]
