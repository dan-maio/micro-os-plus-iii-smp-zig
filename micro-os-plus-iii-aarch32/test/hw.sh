#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw.sh -- load a test image on a board and run it to its verdict.
#
#     test/hw.sh <board> <elf> [seconds]
#
# Usually reached through `zig build run -Dtest=<test>`.
#
# The flow of the C++ port's boards/luckfox-lyra/hw.sh and
# micro-os-plus-iii/test_smpl/run-hw.sh: OpenOCD only, never GDB. The board
# config (boards/<board>/openocd.cfg) runs `init` and enables semihosting on
# core 0; this script then halts core 0, turns its MMU and caches off and
# invalidates the I-cache, branch predictor and TLB (a hot load must not run
# through the previous image's mappings), loads the ELF and resumes core 0 at
# the entry point. Cores 1 and 2 stay in the BootROM until the test releases
# them (SRAM mailbox + CRU resets).
#
# The run is followed on OpenOCD's console (the semihosting mirror of the
# UART) until "RESULT: PASS", "RESULT: FAIL" or "FATAL:"; the log is
# zig-out/hw-logs/<board>/<test>.log. The UART is not touched.
#
# Every run is preceded by the RK3506 full global reset, in its own OpenOCD
# session (rk3506_reset_full in the board config: CRU glb_srstn_1), then 3 s
# for the board to boot: CPUs 1 and 2 are back in the BootROM and no power
# cycle is needed between tests. The reset's SWD errors go to
# <test>.reset.log, not to the run's log.
#
# Env: OPENOCD=<path>  a specific OpenOCD; ADAPTER_KHZ=<n>  SWD clock;
#      RESET_WAIT=<s>  wait after the reset (default 3);
#      NO_RESET=1  skip the reset (power-cycle by hand)
# -----------------------------------------------------------------------------
set -uo pipefail

BOARD="${1:?board}"
ELF="${2:?elf}"
SECS="${3:-300}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CFG="$ROOT/boards/$BOARD/openocd.cfg"
[[ -f "$CFG" ]] || { echo "hw.sh: no OpenOCD config for board '$BOARD' ($CFG)" >&2; exit 2; }

OCD="${OPENOCD:-$(ls -d "$HOME"/.local/xPacks/@xpack-dev-tools/openocd/*/.content/bin/openocd 2>/dev/null | sort -V | tail -1)}"
OCD="${OCD:-openocd}"
SCRIPTS_ARG=()
if [[ "$OCD" == *"/xPacks/"* ]]; then
  SCRIPTS_ARG=(-s "$(dirname "$(dirname "$OCD")")/openocd/scripts")
fi

case "$BOARD" in
  luckfox-lyra)
    TARGET="rk3506.a7.0"
    ENTRY=0x00200000
    ;;
  *)
    echo "hw.sh: unknown board '$BOARD'" >&2
    exit 2
    ;;
esac

if pgrep -x openocd >/dev/null 2>&1; then
  echo "hw.sh: WARNING: an OpenOCD process is already running -- the probe may be busy" >&2
fi

LOGS="${HW_LOGS:-${PWD}/zig-out/hw-logs/$BOARD}"
mkdir -p "$LOGS"
NAME="$(basename "$ELF" .elf)"
LOG="$LOGS/$NAME.log"
RUN_CFG="$LOGS/$NAME.cfg"
rm -f "$LOG"

if [[ -z "${NO_RESET:-}" ]]; then
  RESET_LOG="$LOGS/$NAME.reset.log"
  echo "== $BOARD : full global reset (glb_srstn_1) =="
  "$OCD" "${SCRIPTS_ARG[@]}" -s "$(dirname "$CFG")" -f "$CFG" \
    -c "catch { rk3506_reset_full }; shutdown" > "$RESET_LOG" 2>&1 || true
  if ! grep -q 'Triggering RK3506 Full Global Software Reset' "$RESET_LOG"; then
    echo "hw.sh: the reset session never reached the board (see $RESET_LOG)" >&2
    exit 7
  fi
  sleep "${RESET_WAIT:-3}"
fi

cat > "$RUN_CFG" <<EOF
${ADAPTER_KHZ:+adapter speed $ADAPTER_KHZ
}echo "--- stage: halt core 0 ---"
targets $TARGET
halt
arm semihosting enable
echo "--- stage: sanitize (MMU/caches off) ---"
if {[catch {
  set _s [$TARGET arm mrc 15 0 1 0 0]
  $TARGET arm mcr 15 0 1 0 0 [expr {\$_s & ~0x1005}]
  $TARGET arm mcr 15 0 7 5 0 0
  $TARGET arm mcr 15 0 7 5 6 0
  $TARGET arm mcr 15 0 8 7 0 0
} _e]} { echo "SANITIZE-ERR: \$_e" } else { echo [format "SANITIZE-OK: SCTLR 0x%08x -> MMU/caches off" \$_s] }
echo "--- stage: load_image $ELF ---"
load_image $ELF
echo "--- stage: resume core 0 at $ENTRY ---"
resume $ENTRY
EOF

echo "== $BOARD : $NAME =="

"$OCD" "${SCRIPTS_ARG[@]}" -s "$(dirname "$CFG")" -f "$CFG" -f "$RUN_CFG" > >(tee "$LOG") 2>&1 &
OCD_PID=$!

waited=0 rc=2
while (( waited < SECS )); do
  if grep -q 'RESULT: PASS' "$LOG" 2>/dev/null; then rc=0; break; fi
  if grep -qE 'RESULT: FAIL|FATAL:' "$LOG" 2>/dev/null; then rc=1; break; fi
  if ! kill -0 "$OCD_PID" 2>/dev/null; then rc=4; break; fi
  if grep -qE 'Invalid ACK|Polling failed|Examination failed' "$LOG" 2>/dev/null; then rc=6; break; fi
  sleep 1; waited=$((waited + 1))
done

# The run ends with a semihosting SYS_EXIT, which makes OpenOCD exit: give
# it a moment to print the last lines.
for _ in 1 2 3; do kill -0 "$OCD_PID" 2>/dev/null || break; sleep 1; done
kill "$OCD_PID" 2>/dev/null; wait "$OCD_PID" 2>/dev/null

# OpenOCD's console is block-buffered on a pipe: look once more.
if [[ $rc -eq 2 || $rc -eq 4 ]]; then
  if grep -q 'RESULT: PASS' "$LOG" 2>/dev/null; then rc=0
  elif grep -qE 'RESULT: FAIL|FATAL:' "$LOG" 2>/dev/null; then rc=1; fi
fi

printf '\n%-24s ' "$NAME"
case "$rc" in
  0) echo "PASS  (${waited}s)" ;;
  1) echo "FAIL  (see $LOG)" ;;
  4) echo "OPENOCD DIED  (see $LOG)" ;;
  6) echo "DEBUG LINK LOST  (see $LOG; retry with ADAPTER_KHZ=1000)" ;;
  *) echo "TIMEOUT after ${SECS}s  (see $LOG)" ;;
esac
[[ "$rc" -eq 0 ]]
