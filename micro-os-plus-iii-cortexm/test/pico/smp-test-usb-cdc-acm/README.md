# `smp-test-usb-cdc-acm` — USB CDC-ACM Virtual Serial on RP2040 Dual-Core SMP in Zig

The **pure Zig** implementation of the **USB CDC-ACM (virtual serial port)** gadget test running on the **Raspberry Pi Pico (RP2040, Dual Cortex-M0+)** under the **micro-os-plus-iii-zig** kernel and **micro-os-plus-iii-cortexm-zig** port.

This test demonstrates concurrent multi-core SMP scheduling, hardware USB peripheral control, USB CDC-ACM enumeration and line-buffered bidirectional streaming, and cross-core thread isolation on bare silicon.

---

## 1. System Topology & Cross-Core Thread Architecture

The test distributes responsibilities between the two Cortex-M0+ cores to ensure deterministic USB packet servicing without jitter:

```text
  Host PC (Terminal / Dev Node)
      │
      ▼ USB Full-Speed (DP/DM)
  ┌───────────────────────────────────────────────────────────────┐
  │  Core 0 (Cortex-M0+ #0)                                       │
  │  ├── usb_th (pinned Core 0):                                  │
  │  │     - Unresets USBCTRL peripheral                          │
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
  │  Core 1 (Cortex-M0+ #1)                                       │
  │  └── blink_th (pinned Core 1):                                │
  │        - Hardware heartbeat on onboard LED (GPIO25)           │
  │        - Solid ON while unmounted, 900/100 ms beat mounted    │
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

- **Microcontroller**: Raspberry Pi RP2040 (Dual Cortex-M0+, ARMv6-M).
- **System Clock (`clk_sys`)**: 125 MHz from PLL_SYS (12 MHz crystal input).
- **USB Peripheral Clock (`clk_usb`)**: Dedicated 48 MHz clock from PLL_USB.
- **USB Controller & DPRAM**:
  - Register Base: `0x50110000` (`USBCTRL_REGS`).
  - DPRAM Base: `0x50100000` (`USBCTRL_DPRAM`, 4 KiB dual-ported RAM).
  - VBUS Detection: Hardware VBUS override enabled (`USB_PWR.VBUS_DETECT = 1, VBUS_DETECT_OVERRIDE_EN = 1`).
  - Device Pull-Up: D+ pull-up resistor enabled (`SIE_CTRL.PULLUP_EN = 1`) presenting a Full-Speed (12 Mbps) device to the host.
- **Descriptors**:
  - Vendor ID: `0xCafe`
  - Product ID: `0x4013` (CDC-ACM)
  - Manufacturer: `Raspberry Pi`
  - Product Name: `Pico CDC-ACM`
  - Serial: `PICO-0001`

---

## 3. How to Build & Run

### Build
From `micro-os-plus-iii-cortexm`:
```bash
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=pico -Dtest=smp-test-usb-cdc-acm
```

### Run on Hardware
```bash
bash test/hw.sh pico zig-out/firmware/pico/smp-test-usb-cdc-acm.elf 180   # then open the gadget's port and send Escape
```
