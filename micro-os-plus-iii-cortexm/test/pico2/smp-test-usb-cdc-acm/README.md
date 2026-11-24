# `smp-test-usb-cdc-acm` — USB CDC-ACM Virtual Serial on RP2350 Dual-Core SMP in Zig

The **pure Zig** implementation of the **USB CDC-ACM (virtual serial port)** gadget test running on the **Raspberry Pi Pico 2 (RP2350, Dual Cortex-M33 with hardware FPU)** under the **micro-os-plus-iii-zig** kernel and **micro-os-plus-iii-cortexm-zig** port.

This test demonstrates concurrent multi-core SMP scheduling, hardware USB peripheral control, USB CDC-ACM enumeration and line-buffered bidirectional streaming, and cross-core thread isolation on bare silicon.

---

## 1. System Topology & Cross-Core Thread Architecture

The test distributes responsibilities between the two Cortex-M33 cores to ensure deterministic USB packet servicing without jitter:

```
  Host PC (Terminal / Dev Node)
      │
      ▼ USB Full-Speed (DP/DM)
  ┌───────────────────────────────────────────────────────────────┐
  │  Core 0 (Cortex-M33 #0)                                       │
  │  ├── usb_th (pinned Core 0):                                  │
  │  │     - Unresets USBCTRL peripheral                          │
  │  │     - Powers USB PHY (clears PHY_ISO on RP2350)            │
  │  │     - Polled USB controller event processing               │
  │  └── console_th (pinned Core 0):                              │
  │        - Monitors USB mount state                             │
  │        - Reads incoming bytes, assembles line buffer          │
  │        - Echoes line back to host: "you typed: <line>\r\n"    │
  │        - Mirrors line to hardware UART0 console               │
  │        - Triggers immediate PASS on host Escape (0x1B) key    │
  └───────────────────────────────┬───────────────────────────────┘
                                  │ SIO Spinlock / Atomics
  ┌───────────────────────────────┴───────────────────────────────┐
  │  Core 1 (Cortex-M33 #1)                                       │
  │  └── blink_th (pinned Core 1):                                │
  │        - Hardware heartbeat on onboard LED (GPIO25)           │
  │        - Toggles every 400 ms while unmounted                 │
  │        - 900 ms on / 100 ms off once mounted                  │
  │        - Proves independent execution alongside Core 0 USB    │
  └───────────────────────────────────────────────────────────────┘
```

### Thread Properties & Affinity Pinning

| Thread | Core Affinity | Stack Size | Role |
|---|---|---|---|
| `osMain` | Core 0 (`1 << 0`) | 8192 B | Startup coordinator: initializes threads, releases Core 1 via FIFO handshake, runs test supervisor. |
| `usb_th` | Core 0 (`1 << 0`) | 4096 B | Dedicated USB device task: services setup packets, buffer transfers, and endpoint control. |
| `console_th` | Core 0 (`1 << 0`) | 4096 B | Line-buffered console consumer and bridge between USB CDC and hardware UART0. |
| `blink_th` | Core 1 (`1 << 1`) | 4096 B | Heartbeat worker driving the GPIO25 onboard LED on the second core. |

---

## 2. Hardware Peripheral & Clock Details

- **Microcontroller**: Raspberry Pi RP2350 (Dual Cortex-M33, ARMv8-M Mainline with DSP and single-precision FPU).
- **System Clock (`clk_sys`)**: 150 MHz from PLL_SYS (12 MHz crystal input).
- **USB Peripheral Clock (`clk_usb`)**: Dedicated 48 MHz clock from PLL_USB.
- **Power Isolation**: RP2350 USB PHY isolation cell cleared (`USB.MAIN_CTRL.PHY_ISO = 0`).
- **USB Controller & DPRAM**:
  - Register Base: `0x50110000` (`USBCTRL_REGS`).
  - DPRAM Base: `0x50100000` (`USBCTRL_DPRAM`, 4 KiB dual-ported RAM).
  - VBUS Detection: Hardware VBUS override enabled (`USB_PWR.VBUS_DETECT = 1, VBUS_DETECT_OVERRIDE_EN = 1`).
  - Device Pull-Up: D+ pull-up resistor enabled (`SIE_CTRL.PULLUP_EN = 1`) presenting a Full-Speed (12 Mbps) device to the host.
- **Descriptors**:
  - Vendor ID: `0xCafe`
  - Product ID: `0x4013` (CDC-ACM)
  - Manufacturer: `Raspberry Pi`
  - Product Name: `Pico 2 CDC-ACM`
  - Serial: `PICO2-0001`

---

## 3. Silicon Hardware Execution Results

Run on 2026-10-16 with the **Raspberry Pi Debug Probe (`2e8a:000c`)** over SWD at 5000 kHz, after a board reset (`zig-out/hw-logs/pico2/smp-test-usb-cdc-acm.log`, the lines typed in a terminal on the gadget's `/dev/ttyACM*` abridged):

```text
µOS++ IIIe version 7.0.0 (Zig 0.17.0)
Copyright (c) 2007-2025 Liviu Ionescu
Board: Raspberry Pi Pico 2 (RP2350, 2x Cortex-M33)
Scheduler: µOS++ RP2350 SMP, 2 cores, PendSV, SIO spinlock
System clock: 150000000 Hz
Scheduler frequency: 1000 ticks/sec
Default stack size: 4096 bytes
Built with Zig 0.17.0, safe

scheduler.start()

=============================================
  Pico 2 / RP2350 - micro-os-plus-iii
  smp-test-usb-cdc-acm : USB virtual serial I/O
  (µOS++ Zig API only, no std:: layer)
=============================================
core 0: creating USB and console threads on core 0, blink thread on core 1...
core 0: launching core 1 (bootrom FIFO handshake)...
core 0: core 1 launched; SMP running.
core 0: CDC-ACM up. Open gadget port (Cafe:4013), type line,
        press Return; the line is echoed and mirrored here.
        send Escape to finish.
[usb] mounted
[line] jhkhjkjh
[line] lklkjljk
RESULT: PASS
_Exit()
Main thread stack: 1576/8188 bytes used
Interrupts stack: 528/2048 bytes used
```

The test runs until the host sends Escape (0x1B) in a line; then `RESULT: PASS (host sent Escape)` goes to the UART and one `RESULT: PASS` to semihosting, as in C++ (`hw_result::ok()`). Without a reset after another test it panics at start ("attempt to use null value"): the USB controller keeps its state across a debugger reset.

---

## 4. How to Build & Run

### Build
From `micro-os-plus-iii-cortexm`:
```bash
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=pico2 -Dtest=smp-test-usb-cdc-acm
```

### Run on Hardware
```bash
bash test/hw.sh pico2 zig-out/firmware/pico2/smp-test-usb-cdc-acm.elf 180   # then open the gadget's port and send Escape
```
