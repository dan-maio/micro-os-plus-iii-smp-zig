#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# hw.sh -- load a test image on a board and run it to its verdict over OpenOCD.
#
#     test/hw.sh <board> <elf> [seconds]
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
  rpi4b)
    TARGET="bcm2711.cpu0"
    ENTRY=0x80000
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

# 1. Reset through watchdog (skip if board was just power-cycled)
if [[ "${SKIP_RESET:-0}" != "1" ]]; then
  echo "--- stage: watchdog reset ---"
  "$OCD" -s "$ROOT/boards/$BOARD" "${SCRIPTS_ARG[@]}" -f "$CFG" -c init -f "$ROOT/boards/$BOARD/reset.cfg" > /dev/null 2>&1 || true
  sleep 10
fi

# 2. Build the run configuration
cat > "$RUN_CFG" <<EOF
echo "--- stage: halt core 0 ---"
targets $TARGET
halt

echo "--- stage: enable semihosting ---"
arm semihosting enable
targets bcm2711.cpu1; arm semihosting enable
targets bcm2711.cpu2; arm semihosting enable
targets bcm2711.cpu3; arm semihosting enable
targets $TARGET
if {[info procs rpi4b_enable_hde] ne ""} { rpi4b_enable_hde }

echo "--- stage: load image ---"
load_image "$ELF"

echo "--- stage: resume at entry 0x80000 ---"
reg pc $ENTRY
resume
sleep 300000
EOF

echo "== $BOARD : $NAME =="

"$OCD" -s "$ROOT/boards/$BOARD" "${SCRIPTS_ARG[@]}" -f "$CFG" -c init -f "$RUN_CFG" > >(tee "$LOG") 2>&1 &
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

if [[ $rc -eq 2 || $rc -eq 4 ]]; then
  if grep -q 'RESULT: PASS' "$LOG" 2>/dev/null; then rc=0
  elif grep -q 'RESULT: FAIL' "$LOG" 2>/dev/null; then rc=1; fi
fi

printf '\n%-24s ' "$NAME"
case "$rc" in
  0) echo "PASS  (${waited}s)" ;;
  1) echo "FAIL  (see $LOG)" ;;
  4) echo "OPENOCD DIED  (see $LOG)" ;;
  *) echo "TIMEOUT after ${SECS}s  (see $LOG)" ;;
esac
[[ "$rc" -eq 0 ]]
