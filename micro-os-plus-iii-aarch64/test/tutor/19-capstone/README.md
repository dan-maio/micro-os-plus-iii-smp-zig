# Lesson 19 (Zig) — The capstone: one application, every piece of the course, and a USB device

## 1. Theory

### From lessons to an application

Every lesson so far was one file that showed one mechanism. A real
application is many files, and the question becomes **where each piece
belongs**. The capstone is organised the way an embedded application usually
is, by domain:

| Domain | Files | What it owns |
|---|---|---|
| `core/` | `config.zig`, `threads.zig` | the numbers (sizes, files, priorities) and *where* each kind of thread runs for the build's CPU count |
| `data/` | `samples.zig` | where the data lives: a static array, a stack, `new`, a memory pool |
| `pipeline/` | `pipeline.zig` | one unit of work: producers → queue → consumer, checked against a reference |
| `churn/` | `churn.zig` | the work repeated, threads created and destroyed, everything back to its baseline after each round |
| `storage/` | `storage.zig` | the SD card's one owner, the log, the USB file |
| `usb/` | `usb_link.zig`, `big_transfer.zig` | the USB device, its service thread and interrupt, the transfer protocol |

`capstone.zig` only orders them; `1cpu/main.zig` and `4cpu/main.zig` are just
the entry points (their `uos_options` set the CPU count). Nothing in a domain
knows the CPU count except through `core/config.zig`: the same sources build
both versions, as one module (`capstone`).

### One owner per device, again — and two devices

Lesson 16's rule — one thread owns a device, the others send it requests —
now applies twice:

- the **SD card** is owned by the logger thread (the course's SD log): it
  prints and logs every line, and it also writes the USB file;
- the **USB device** is owned by the USB service thread, pinned to core 0,
  where its interrupt is routed: it answers the host's control requests and
  runs the transfer.

The two owners talk through a queue, never by touching each other's device.

### A USB device on the Pi 4

USB is asymmetric: one **host** (the PC) and **devices**. The Pi 4's four
USB-A ports are host ports (the VL805 controller): they can never act as a
device. The BCM2711's own controller, a DWC2 OTG core, is wired only to the
**USB-C** socket — which is also the power input. So the PC's cable goes into
USB-C, and the board is powered through the GPIO header or a USB-C power/data
splitter.

As a device, the Pi presents itself (descriptors), lets the host give it an
address and a configuration over **endpoint 0** (control transfers: a SETUP,
an optional data stage, a status stage), and then moves data over two
**bulk endpoints**: OUT (host → device, 0x01) and IN (device → host, 0x81),
512-byte packets at high speed. The host polls; the device answers each
token with data, an ACK, or a **NAK** — "not now".

### A device must not leave the bus waiting

A NAK is legal, and the host retries. But the host does not wait forever:
on this PC, through a hub, a device that NAKed for 20 ms between blocks was
fine, one that NAKed for 50 ms made the host give up with I/O errors. Writing
32 KiB to the SD card takes longer than that. So the USB thread must never
wait for the card: it receives straight into the blocks of a **ring** of
buffers (16 × 32 KiB), hands each full block to the card's owner **without
waiting**, and goes on with the next one. A counting semaphore of free
blocks paces the two sides; the USB thread waits only if every block is still
waiting for the card. This is the producer/consumer bound of lessons 07 and
11, used to decouple a fast, impatient device from a slow one.

## 2. In µOS++ (Zig)

- Everything of the course: `rtos.Thread` with priorities and affinity,
  `MessageQueueTyped(T).Static(n)`, `Semaphore.counting`, `MemoryPoolTyped`,
  `join()`/`destroy()`, `Thread.init()` on a static stack, the heap's
  allocated bytes, the course's regions and reference
  (`test/tutor/common/tutor.zig`) and SD log (`test/tutor/common/sdlog.zig`).
- The SD log, new for this lesson: `streamOpen()`, `streamClose()`,
  `streamWriteAsync(data, done)` (written in the logger's turn, then `done`
  posted), `streamErrors()`, `fileCrc()`, `crc32()`; under them the FatFs
  wrapper's `fatfs.Stream` (`drivers/fatfs.zig`), a file kept open.
- The interrupt: the lesson's root exports `uos_external_irq`
  (`capstone.onExternalIrq`), which the board's dispatcher calls for every
  interrupt it does not own — here the USB core's, INTID 105.
- The USB driver, `drivers/usb_dwc2.zig` (new: the C++ `usb_dwc2.cpp`
  ported function for function, with its EP0 fix and `epWriteStream()`):
  `init(identity)`, `serviceThreadBody()`, `setConfiguredCallback()`,
  `epRead()`, `epWrite()`, `epWriteStream()`, `isr()`; and
  `drivers/mailbox.zig` (new: the VideoCore mailbox, to power the USB domain).
- The build (`build.zig`): the entries with `.devices = true` (the card),
  `.usb = true` (the driver and the mailbox) and `.app` (the `capstone`
  module, rooted at `test/tutor/19-capstone/app/capstone.zig`).
- The host side: `usb_test_host --big <file>` (from the C++ workspaces,
  `micro-os-plus-iii-aarch32/test/luckfox-lyra/smp_test6/host/`).

## 3. The lesson

`capstone.run()` (`app/capstone.zig`):

1. (four CPUs) cores 1–3 released;
2. the card and its owner, the logger: every line from here on is logged;
3. the USB device up — on the board only: the image is the same for QEMU and
   the board, and QEMU's raspi4b has no device-mode DWC2 — and `tests/usbfile.bin` created and kept open, so that the
   host can send its file while the rest runs;
4. **the churn**: 8 rounds. Each round four producers make 64 samples each
   from their source — the static array, their own stack, `new`, the pool —
   and send their addresses through a 32-slot queue to a consumer, which
   checks every sample lies in its source's region, links them into one
   list, sorts it, takes its maximum and compares with the reference; then it
   releases the producers, which give their samples back. After each round:
   the heap at its level, the pool empty. Four CPUs: producer *k* on core
   *k*, the consumer floating;
5. **the USB transfer**, waited for (at most 100 s): the file received into
   the ring, echoed at once, block by block to the card's owner, the ack;
6. the logger stopped; the log read back (size, CRC-32, lines) and the USB
   file read back (size and CRC-32 against what was received); the verdict.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own sources in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/19-capstone/1cpu/main.zig` (or `4cpu/main.zig`), and `app/`: `capstone.zig`, `core/config.zig`, `core/threads.zig`, `data/samples.zig`, `pipeline/pipeline.zig`, `churn/churn.zig`, `storage/storage.zig`, `usb/usb_link.zig`, `usb/big_transfer.zig`
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig`, `sdlog.zig`
- the card: `micro-os-plus-iii-aarch64/drivers/sd.zig`, `drivers/fatfs.zig`, `drivers/ff_api.h`, `drivers/fatfs/ff.c`, `drivers/fatfs/ffconf.h`
- the USB device: `micro-os-plus-iii-aarch64/drivers/usb_dwc2.zig`, `drivers/mailbox.zig`
- `micro-os-plus-iii-aarch64/test/board.zig`, the port (`micro-os-plus-iii-aarch64/src/port.zig`, `src/gic.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/mqueue.zig`, `mempool.zig`, `semaphore.zig`, `thread.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-19-capstone-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- (on the board) the USB device is up and `tests/usbfile.bin` is created;
- the pool is created; all 8 rounds give the reference's result, every
  sample lies where its source says, after every round the heap is back and
  the pool empty, 40 threads created and destroyed; (4 CPUs) the producers
  ran on all four cores;
- (on the board) the host's file arrived: every byte received, echoed and
  stored; the log read back as written; the USB file read back with the size
  and CRC-32 received;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

And on the host, `usb_test_host --big` reports every echoed byte identical
and the ack `status OK`.

## 5. Running it

The board needs its SD card, and the PC's USB cable on the **USB-C** socket
(the board powered through the GPIO header or a power/data splitter). Power
the board off and on before each run. From `micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build                                      # every image, the capstone's too
zig build -Dtest=tutor-19-capstone-1cpu run    # QEMU
zig build -Dtest=tutor-19-capstone-4cpu run
# the board AND the host transfer, in one go:
test/tutor/19-capstone/run.sh 1cpu
test/tutor/19-capstone/run.sh 4cpu
```

`run.sh` takes the host tool the C++ `run.sh` built (`/tmp/uos-capstone-usb/`),
else builds it from `USB_TEST_HOST_SRC`; makes a 512 KiB random file; starts
the board run (`test/hw.sh rpi4b …`); waits until the runner has started the
image, then for the gadget (`2207:0019`) on the host's bus; sends the file
with `--big`; prints the board's verdict and `host: PASS|FAIL; board:
PASS|FAIL`. With a second CMSIS-DAP probe on the host, set
`UOS_HW_ADAPTER_SERIAL=<the Pi's probe serial>`.

## 6. Results

Both versions PASS on the board, the USB transfer included, and under QEMU
(no card, no device-mode USB) (2026-10-24). The churn gave the C++ version's
results round for round (round 0: max 9975, id 188); through a hub at high
speed the host sent 512 KiB and received the identical echo at 7.0–7.3 MB/s
each way, and the ack; the card then held the bytes with the CRC-32 received.
See [`RESULTS.md`](RESULTS.md).

### What this lesson found

- The Zig port had no USB driver: `drivers/usb_dwc2.zig` and
  `drivers/mailbox.zig` are new, ported from the C++ ones after the C++
  capstone had found and fixed the EP0 bug and the trailing zero-length
  packet, and they worked on the board at the first run.
- The ring of buffers, the asynchronous card writes and the file kept open
  came from the C++ lesson too (a pause of 50 ms in serving the bus made the
  host give up); the Zig SD log and FatFs wrapper gained the same operations.
- `run.sh` first looked for the gadget as soon as it started the runner and
  found the one a previous run had left on the bus, just as the runner's
  reset removed it ("Failed to find/claim device: -5"). It now waits until the
  runner has started the new image (the same fix in the C++ `run.sh`).
