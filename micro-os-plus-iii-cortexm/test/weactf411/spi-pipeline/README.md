# `spi-pipeline` — WeAct Studio F411CE SPI Flash Pipeline in Zig

The **pure Zig** implementation of the 5-thread SPI NOR Flash pipeline application on the **WeAct Studio Black Pill (STM32F411CE, Cortex-M4F with FPU)** under the **micro-os-plus-iii-zig** kernel and the **micro-os-plus-iii-cortexm-zig** port.

This test exercises multi-threaded producer-consumer pipelining, inter-thread synchronization via counting and binary semaphores, peripheral hardware drivers (hardware SPI1 master and Winbond W25Q128 16 MByte NOR Flash), a lightweight persistent flat-file archive (`FlatFS`), chunked RFC 4648 Base64 encoding/decoding, and end-to-end CRC-32 integrity verification across 8 complete iterations on physical silicon.

---

## 1. System Architecture & Concurrency Model

Five concurrent threads cooperate to stream the firmware image from on-chip Flash through an encoding pipeline onto SPI NOR Flash, while monitoring monotonic progress and verifying bit-for-bit reconstruction:

```
  image ──T1──▶ [buffer] ──T2──▶ [buffer_b64] ──T3──▶ enc<n>.b64
   0x08000000    256 B    Base64    ≤344 B    append   (partition 1)
                                                 │
                                      snapshot   ├──▶ T4  blink + UART
                                      file_done  └──▶ T5  decode, CRC,
                                                           dec<n>.bin
                                                           (partition 2)
```

### Thread Roles and Invariants

| Thread | Role | Waits On | Posts / Signals | Completion Condition |
|---|---|---|---|---|
| **T1: Producer** | Reads 256-byte chunks from flash image `0x08000000` into `g_raw_buf`. Paced across 2.4s. | `g_buf_empty` | `g_buf_full`, `g_copy_done` | All source image bytes read |
| **T2: Encoder** | RFC 4648 Base64 encoder with per-chunk padding. Converts ≤256 B raw to ≤344 B Base64 into `g_enc_buf`. | `g_b64_empty`, `g_buf_full` | `g_buf_empty`, `g_b64_full` | Final chunk encoded and forwarded |
| **T3: Writer** | Appends Base64 stream to `enc<n>.b64` on SPI Flash partition 1 via `FlatFS`. | `g_b64_full`, then `g_copy_done` | `g_b64_empty`, `g_write_snapshot`, `g_file_done` | All chunks written and file closed |
| **T4: Monitor** | Blinks onboard LED (300 ms half-period) and samples growing file size and head/tail contents to console. | `g_write_snapshot` (bounded 400 ms) | — | 5 blink cycles completed |
| **T5: Verifier** | Reads back `enc<n>.b64`, Base64-decodes to `dec<n>.bin` on partition 2, computes CRC-32, and verifies `CRC1 == CRC0`. | `g_file_done` | `g_verify_done` | Verification printed to UART & semihosting |

---

## 2. Hardware Peripherals & Storage Engine

### STM32F411 SPI1 Hardware Master Driver
- **Pins**: `PA4` = CS# (GPIO push-pull, 100 MHz speed), `PA5` = SCK (AF5), `PA6` = MISO (AF5), `PA7` = MOSI (AF5).
- **Clock**: APB2 peripheral clock (100 MHz / 4 = 25 MHz SPI SCK).
- **Configuration**: SPI Master, Mode 0 (`CPOL=0`, `CPHA=0`), 8-bit frames, MSB-first, Software NSS (`SSM=1, SSI=1`).
- **Timing & Settlement**: Datasheet $t_\text{SHSL}$ (CS# deasserted minimum duration: 50 ns after read, 100 ns after program/erase) is strictly maintained with compile-time inline spin loops (`csSettle()`).

### Winbond W25Q128 NOR Flash Protocol
- **JEDEC ID Probe (`0x9F`)**: Identifies physical Winbond `0xEF 0x40 0x18` (16 MByte capacity).
- **Sector Erase (`0x20`)**: 4 KiB uniform erase units.
- **Page Program (`0x02`)**: Up to 256 bytes per page, with automatic page boundary alignment handling in `flash.write()`.
- **Status Register 1 (`0x05`)**: Bounded busy polling (`waitIdle()`) on bit 0 (`BUSY`).

### FlatFS Partition Archive
- Sized dynamically at boot to accommodate 8 iterations without sector collision:
  - **Partition 1 (`encoded`)**: Base `0x00100000`, size 348 KiB (holds `enc0.b64` .. `enc7.b64`).
  - **Partition 2 (`decoded`)**: Base `0x00157000`, size 260 KiB (holds `dec0.bin` .. `dec7.bin`).
- **Superblock (`0x46414C31`)**: Magic, version 1, header size 32 B, 64 TOC entries, blob offset 2080 B.
- **TOC Entry**: 16-byte filename, 4-byte offset, 4-byte size, 4-byte CRC-32, 4-byte state (`0x4C495645` = LIVE).

---

## 3. Physical Silicon Execution Results

Run on 2026-10-16 on the **WeAct Studio Black Pill (STM32F411CE)** through the **WCH-Link CMSIS-DAP** (`test/run-all.sh weactf411`; the semihosting log, `zig-out/hw-logs/weactf411/spi-pipeline.log`, with the per-cycle snapshots left out). The CRCs depend on the image, so they change from build to build.

```text
spi-pipeline: heap 16384 bytes
spi-pipeline: SPI transport polled (bulk from 16 bytes)
spi-pipeline: JEDEC 0xef 0x40 0x18 -> SPI flash store
spi-pipeline: enc 348 KiB @ 0x00100000, dec 260 KiB @ 0x00157000 (8 iterations)
spi-pipeline: enc 348 KiB @ 0x100000, dec 260 KiB @ 0x157000
spi-pipeline: fs done
spi-pipeline: image 32768 bytes at 0x08000000, source 32768, crc0 0x08f2dd12
spi-pipeline: 128 chunks of 256 (last 256), 44032 encoded, 18 ms per chunk
[   17192 ms] iter 0: 128 chunks, enc 44032 B, dec 32768 B, crc 0x08f2dd12==0x08f2dd12, 5 cycles (4 fresh), 0 error(s), heap 16384 B
[   20760 ms] iter 1: 128 chunks, enc 44032 B, dec 32768 B, crc 0x08f2dd12==0x08f2dd12, 5 cycles (4 fresh), 0 error(s), heap 16384 B
[   24328 ms] iter 2: 128 chunks, enc 44032 B, dec 32768 B, crc 0x08f2dd12==0x08f2dd12, 5 cycles (4 fresh), 0 error(s), heap 16384 B
[   27896 ms] iter 3: 128 chunks, enc 44032 B, dec 32768 B, crc 0x08f2dd12==0x08f2dd12, 5 cycles (4 fresh), 0 error(s), heap 16384 B
[   31462 ms] iter 4: 128 chunks, enc 44032 B, dec 32768 B, crc 0x08f2dd12==0x08f2dd12, 5 cycles (4 fresh), 0 error(s), heap 16384 B
[   35028 ms] iter 5: 128 chunks, enc 44032 B, dec 32768 B, crc 0x08f2dd12==0x08f2dd12, 5 cycles (4 fresh), 0 error(s), heap 16384 B
[   38596 ms] iter 6: 128 chunks, enc 44032 B, dec 32768 B, crc 0x08f2dd12==0x08f2dd12, 5 cycles (4 fresh), 0 error(s), heap 16384 B
[   42171 ms] iter 7: 128 chunks, enc 44032 B, dec 32768 B, crc 0x08f2dd12==0x08f2dd12, 5 cycles (4 fresh), 0 error(s), heap 16384 B
spi-pipeline: enc partition, 354336 bytes used
  enc0.b64          44032 bytes  crc 0x59d38ba1
  enc1.b64          44032 bytes  crc 0x59d38ba1
  enc2.b64          44032 bytes  crc 0x59d38ba1
  enc3.b64          44032 bytes  crc 0x59d38ba1
  enc4.b64          44032 bytes  crc 0x59d38ba1
  enc5.b64          44032 bytes  crc 0x59d38ba1
  enc6.b64          44032 bytes  crc 0x59d38ba1
  enc7.b64          44032 bytes  crc 0x59d38ba1
spi-pipeline: dec partition, 264224 bytes used
  dec0.bin          32768 bytes  crc 0x08f2dd12
  dec1.bin          32768 bytes  crc 0x08f2dd12
  dec2.bin          32768 bytes  crc 0x08f2dd12
  dec3.bin          32768 bytes  crc 0x08f2dd12
  dec4.bin          32768 bytes  crc 0x08f2dd12
  dec5.bin          32768 bytes  crc 0x08f2dd12
  dec6.bin          32768 bytes  crc 0x08f2dd12
  dec7.bin          32768 bytes  crc 0x08f2dd12
pipe 1: 8 of 8 iterations wrote 128 chunks and saw the final one
pipe 2: 8 of 8 produced 44032 encoded and 32768 decoded bytes
pipe 3: 8 of 8 decoded back to crc0 0x08f2dd12
pipe 4: 8 of 8 ran 5 blink cycles with snapshots that never shrank
pipe 5: base64 matches the RFC 4648 vectors: true
pipe 6: banner printed 4 lines at console-lock depth 2: true
spi-pipeline: 8 of 8 iterations clean, heap 16384 bytes
spi-pipeline: PASS
RESULT: PASS
Main thread stack: 2116/8188 bytes used
Interrupts stack: 536/2048 bytes used
```

---

## 4. How to Build & Run

### Build
From `micro-os-plus-iii-cortexm`:
```bash
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=weactf411 -Dtest=spi-pipeline
```

### Flash & Run on Hardware
```bash
bash test/hw.sh weactf411 zig-out/firmware/weactf411/spi-pipeline.elf 120
```
Console output mirrors simultaneously to USART1 (115200 8N1) and OpenOCD semihosting.
