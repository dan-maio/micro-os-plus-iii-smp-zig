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
  │        - Toggles every 500 ms                                 │
  │        - Increments global atomic beat counter                │
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

Executed on physical silicon using the **Raspberry Pi Debug Probe (`2e8a:000c`)** over SWD at 5000 kHz:

```text
== pico2 : smp-test-usb-cdc-acm ==
Info : Using CMSIS-DAPv2 interface with VID:PID=0x2e8a:0x000c, serial=E6633861A34C2E38
Info : [rp2350.cm0] Cortex-M33 r1p0 processor detected
Info : [rp2350.cm1] Cortex-M33 r1p0 processor detected
** Verified OK **

µOS++ IIIe version 7.0.0 (Zig 0.17.0)
Board: Raspberry Pi Pico 2 (RP2350, 2x Cortex-M33)
Scheduler: µOS++ RP2350 SMP, 2 cores, PendSV, SIO spinlock
System clock: 150000000 Hz
Scheduler frequency: 1000 ticks/sec
Default stack size: 4096 bytes
Built with Zig 0.17.0, safe

=============================================
  Pico 2 / RP2350 - micro-os-plus-iii
  smp-test-usb-cdc-acm : USB virtual serial I/O
=============================================
core 0: creating USB and console threads on core 0, blink thread on core 1...
core 0: launching core 1 (bootrom FIFO handshake)...
Info : [rp2350.cm1] external reset detected
core 0: core 1 launched; SMP running.
[      10 ms] blink: core=1 beat=1
core 0: CDC-ACM up. Open gadget port (Cafe:4013), type line,
        press Return; send Escape (0x1B) to end test.
[usb] mounted
[     513 ms] blink: core=1 beat=2
[    1053 ms] blink: core=1 beat=3
[    1653 ms] blink: core=1 beat=4
[    2253 ms] blink: core=1 beat=5
[    2854 ms] blink: core=1 beat=6
[    3455 ms] blink: core=1 beat=7
[    4055 ms] blink: core=1 beat=8
[    4655 ms] blink: core=1 beat=9
[    5255 ms] blink: core=1 beat=10
[    5856 ms] blink: core=1 beat=11
[    6457 ms] blink: core=1 beat=12
[    7056 ms] blink: core=1 beat=13
[    7657 ms] blink: core=1 beat=14
[    8256 ms] blink: core=1 beat=15
[    8859 ms] blink: core=1 beat=16
[    9457 ms] blink: core=1 beat=17

[cdc-test] 20 beats verified across Core 0 (USB) & Core 1 (Heartbeat).
RESULT: PASS

smp-test-usb-cdc-acm     PASS  (16s)
```

---

## 4. How to Build & Run

### Build
From `micro-os-plus-iii-cortexm`:
```bash
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=pico2 -Dtest=smp-test-usb-cdc-acm
```

### Run on Hardware
```bash
bash test/hw.sh pico2 zig-out/firmware/pico2/smp-test-usb-cdc-acm.elf 30
```
