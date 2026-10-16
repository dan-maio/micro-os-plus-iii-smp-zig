#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw.sh -- program a test image on a board and run it to its verdict.
#
#     test/hw.sh <board> <elf> [seconds]
#
# Usually reached through `zig build run -Dboard=<board> -Dtest=<test>`.
#
# OpenOCD only, never GDB. Semihosting is enabled before the resume: the
# trace and the verdict travel over it, and the run ends with a semihosting
# SYS_EXIT. The script tees OpenOCD's console to a log and stops at the
# first "RESULT: PASS" or "RESULT: FAIL".
#
# Probes (override with OCD_PROBE='0xVID 0xPID'):
#   weactf411              any CMSIS-DAP; a WCH-Link must be in ARM mode
#                          (1a86:8011), hold ModeS while plugging it in
#   weactf412              an ST-Link (as the C++ board), SWD, 1000 kHz
#   nucleof411             the on-board ST-Link
#   pico, pico2            the Raspberry Pi Debug Probe (2e8a:000c)
#
# Pico 2: `reset init` (not `reset`) re-runs the bootrom/XIP setup, and cm1
# is resumed before cm0 so that core 1 waits in the bootrom launch loop and
# answers the FIFO handshake. One test per power cycle is the safe habit on
# the RP boards: the SIO spinlocks survive a debugger reset.
#
# Env: OPENOCD=<path>  a specific OpenOCD; ADAPTER_KHZ=<n>  SWD clock
# -----------------------------------------------------------------------------
set -uo pipefail

BOARD="${1:?board}"
ELF="${2:?elf}"
SECS="${3:-600}"

OCD="${OPENOCD:-$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/openocd/*/.content/bin/openocd 2>/dev/null | sort -V | tail -1)}"
OCD="${OCD:-openocd}"
SCRIPTS_ARG=()
if [[ "$OCD" == *"/xPacks/"* ]]; then
  SCRIPTS_ARG=(-s "$(dirname "$(dirname "$OCD")")/openocd/scripts")
fi

KHZ="${ADAPTER_KHZ:-}"

# With several CMSIS-DAP probes attached, pin the one of the board: the
# WCH-Link (ARM mode) for the WeAct boards, the Raspberry Pi Debug Probe
# for the Picos -- when they are plugged in.
have_usb () { command -v lsusb >/dev/null && lsusb | grep -qi "ID $1"; }
DEFAULT_PROBE=""
case "$BOARD" in
  weactf411) have_usb 1a86:8011 && DEFAULT_PROBE="0x1a86 0x8011" ;;
  pico|pico2)          have_usb 2e8a:000c && DEFAULT_PROBE="0x2e8a 0x000c" ;;
esac
PROBE="${OCD_PROBE:-$DEFAULT_PROBE}"
PROBE_ARGS=()
[[ -n "$PROBE" ]] && PROBE_ARGS=(-c "cmsis-dap vid_pid $PROBE")
case "$BOARD" in
  weactf412)
    # As the C++ board (test/boards/weactf412/openocd.cfg): an ST-Link, SWD,
    # 1000 kHz.
    CFG=(-f interface/stlink.cfg -c "transport select swd" -c "adapter speed ${KHZ:-1000}" -f target/stm32f4x.cfg)
    RUN=(-c "init" -c "reset halt" -c "program \"$ELF\" verify"
         -c "arm semihosting enable" -c "reset run")
    ;;
  weactf411)
    CFG=(-f interface/cmsis-dap.cfg "${PROBE_ARGS[@]}")
    CFG+=(-c "transport select swd" -c "adapter speed ${KHZ:-4000}" -f target/stm32f4x.cfg)
    RUN=(-c "init" -c "reset halt" -c "program \"$ELF\" verify"
         -c "arm semihosting enable" -c "reset run")
    ;;
  nucleof411)
    # As the C++ board (test/boards/nucleof411/openocd.cfg): the integrated
    # ST-Link, NRST asserted while connecting.
    CFG=(-f board/st_nucleo_f4.cfg -c "reset_config connect_assert_srst")
    [[ -n "$KHZ" ]] && CFG+=(-c "adapter speed $KHZ")
    RUN=(-c "init" -c "reset halt" -c "program \"$ELF\" verify"
         -c "arm semihosting enable" -c "reset run")
    ;;
  pico2)
    CFG=(-f interface/cmsis-dap.cfg "${PROBE_ARGS[@]}" -c "adapter speed ${KHZ:-5000}"
         -c "set USE_CORE { cm0 cm1 }" -c "set USE_SMP 0" -f target/rp2350.cfg)
    RUN=(-c "init" -c "reset init" -c "program \"$ELF\" verify" -c "reset init"
         -c "targets rp2350.cm1" -c "arm semihosting enable" -c "resume"
         -c "targets rp2350.cm0" -c "arm semihosting enable" -c "resume")
    ;;
  pico)
    CFG=(-f interface/cmsis-dap.cfg "${PROBE_ARGS[@]}" -c "adapter speed ${KHZ:-15000}"
         -c "set FLASHSIZE 0x200000" -c "set USE_CORE BOTH" -f target/rp2040.cfg)
    RUN=(-c "init" -c "reset init" -c "program \"$ELF\" verify" -c "reset init"
         -c "targets rp2040.core1" -c "arm semihosting enable" -c "resume"
         -c "targets rp2040.core0" -c "arm semihosting enable" -c "resume")
    ;;
  *)
    echo "hw.sh: unknown board '$BOARD'" >&2
    exit 2
    ;;
esac

LOGS="$(dirname "$ELF")/../.hw-logs"
LOGS="${HW_LOGS:-${PWD}/zig-out/hw-logs/$BOARD}"
mkdir -p "$LOGS"
LOG="$LOGS/$(basename "$ELF" .elf).log"
rm -f "$LOG"

echo "== $BOARD : $(basename "$ELF" .elf) =="

"$OCD" "${SCRIPTS_ARG[@]}" "${CFG[@]}" -c "gdb port disabled" -c "tcl port disabled" \
  -c "telnet port disabled" "${RUN[@]}" > >(tee "$LOG") 2>&1 &
OCD_PID=$!

waited=0 rc=2
while (( waited < SECS )); do
  if grep -q 'RESULT: PASS' "$LOG" 2>/dev/null; then rc=0; break; fi
  if grep -q 'RESULT: FAIL' "$LOG" 2>/dev/null; then rc=1; break; fi
  if ! kill -0 "$OCD_PID" 2>/dev/null; then rc=4; break; fi
  sleep 1; waited=$((waited + 1))
done

sleep 1
kill "$OCD_PID" 2>/dev/null; wait "$OCD_PID" 2>/dev/null

# OpenOCD's console is block-buffered on a pipe: look once more.
if [[ $rc -eq 2 || $rc -eq 4 ]]; then
  if grep -q 'RESULT: PASS' "$LOG" 2>/dev/null; then rc=0
  elif grep -q 'RESULT: FAIL' "$LOG" 2>/dev/null; then rc=1; fi
fi

printf '\n%-24s ' "$(basename "$ELF" .elf)"
case "$rc" in
  0) echo "PASS  (${waited}s)" ;;
  1) echo "FAIL  (see $LOG)" ;;
  4) echo "OPENOCD DIED  (see $LOG)" ;;
  *) echo "TIMEOUT after ${SECS}s  (see $LOG)" ;;
esac
[[ "$rc" -eq 0 ]]
