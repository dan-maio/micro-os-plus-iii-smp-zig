#!/usr/bin/env bash
# run.sh -- the capstone (Zig) on the board, with its USB transfer from the host.
#
#     test/tutor/19-capstone/run.sh [1cpu|4cpu] [file]
#
# The Zig version of the C++ course's run.sh. Power-cycle the board first. The
# PC's cable must be on the Pi 4's USB-C socket (the board powered through the
# GPIO header or a power/data splitter). Build the firmware first: zig build.
#
#   1. the host tool, usb_test_host (luckfox-lyra/smp_test6/host/): the one the
#      C++ run.sh built, else built here from USB_TEST_HOST_SRC;
#   2. the board run (test/hw.sh) in the background;
#   3. the gadget (2207:0019) waited for on the host's bus;
#   4. the file (default: 512 KiB of random bytes) sent with --big, the echo
#      checked;
#   5. the board's verdict.
#
# Env: UOS_HW_ADAPTER_SERIAL (the Pi's probe, with a second CMSIS-DAP probe on
# the host), USB_TEST_HOST_SRC (the host tool's source).
set -u

V="${1:-4cpu}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="$HERE/../../.."
WORK="${TMPDIR:-/tmp}/uos-capstone-usb"
mkdir -p "$WORK"

# 1. The host tool.
HOST="$WORK/usb_test_host"
SRC="${USB_TEST_HOST_SRC:-$HOME/Work2/micro-os-plus/micro-os-plus-iii-aarch32/test/luckfox-lyra/smp_test6/host/usb_test_host.cpp}"
if [[ ! -x "$HOST" ]]; then
  g++ -std=c++23 -O2 $(pkg-config --cflags libusb-1.0) "$SRC" \
    $(pkg-config --libs libusb-1.0) -o "$HOST" || exit 2
fi

# The file to send.
FILE="${2:-$WORK/usbfile.bin}"
[[ -f "$FILE" ]] || head -c 524288 /dev/urandom > "$FILE"
rm -f "$FILE.bak"

# 2. The board run.
ELF="$PORT/zig-out/firmware/rpi4b/tutor-19-capstone-$V.elf"
[[ -f "$ELF" ]] || { echo "run.sh: no $ELF -- run zig build first" >&2; exit 2; }
LOG="$WORK/hw-zig-tutor-19-capstone-$V.log"
(cd "$PORT" && test/hw.sh rpi4b "$ELF" 180) > "$LOG" 2>&1 &
BOARD=$!

# 3. The gadget on the bus -- this run's: only once the runner has started the
# new image (after its reset, which removes a gadget a previous run left on
# the bus; looking earlier found that old one, just as it went away).
for _ in $(seq 1 120); do
  grep -q "stage: resume" "$LOG" 2>/dev/null && break
  kill -0 "$BOARD" 2>/dev/null || break
  sleep 1
done
for _ in $(seq 1 90); do
  lsusb | grep -q "2207:0019" && break
  kill -0 "$BOARD" 2>/dev/null || break
  sleep 1
done

# 4. The transfer.
HOST_OK=1
if lsusb | grep -q "2207:0019"; then
  sleep 2
  (cd "$(dirname "$FILE")" && timeout 120 "$HOST" --big "$(basename "$FILE")") && HOST_OK=0
else
  echo "run.sh: the gadget did not appear on the bus" >&2
fi

# 5. The board's verdict.
wait "$BOARD"
BOARD_OK=$?
grep -E "RESULT:" "$LOG"
echo "host: $([[ $HOST_OK == 0 ]] && echo PASS || echo FAIL); board: $([[ $BOARD_OK == 0 ]] && echo PASS || echo FAIL) (log: $LOG)"
[[ $HOST_OK == 0 && $BOARD_OK == 0 ]]
