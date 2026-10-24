# Lesson 19 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `run.sh`: board + host transfer) |
|---|---|---|
| `tutor-19-capstone-1cpu` | PASS (no card, no USB device) | PASS; host: 512 KiB echoed identical, 6.99 MB/s each way |
| `tutor-19-capstone-4cpu` | PASS (no card, no USB device) | PASS; host: 512 KiB echoed identical, 7.31 MB/s each way |

Run on 2026-10-24. The PC's cable on the Pi's USB-C socket through a USB-C
power/data splitter and a USB hub, high speed; the host side is
`usb_test_host --big` on a 512 KiB random file. The board's verdict lines:

```
RESULT: PASS (the capstone: rounds, regions, pool, queues, SD log and USB file verified; one CPU)
RESULT: PASS (the capstone: rounds, regions, pool, queues, SD log and USB file verified; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. The full consoles below are the QEMU runs.

The host's end of the 1 CPU run (`run.sh 1cpu`):

```
Found device: 2207:0019
Current configuration: 1
Interface 0 claimed successfully
Using endpoints: IN=0x81 OUT=0x01
Streaming 524288 bytes from 'usbfile.bin' (echo -> 'usbfile.bin.bak')...
All 524288 bytes sent, draining echo...
Round-trip 0.08 s  (6.99 MB/s each way)
ACK: count=524288, status OK
Saved 524288 echoed bytes to 'usbfile.bin.bak'
PASSED: all 524288 bytes match
RESULT: PASS (the capstone: rounds, regions, pool, queues, SD log and USB file verified; one CPU)
host: PASS; board: PASS (log: /tmp/uos-capstone-usb/hw-zig-tutor-19-capstone-1cpu.log)
```

| | 1 CPU, QEMU | 4 CPUs, QEMU |
|---|---|---|
| rounds as the reference / clean / misplaced | 8 / 8 / 0 | 8 / 8 / 0 |
| threads created and destroyed | 40 | 40 |
| producers' cores | 0 | 0, 1, 2, 3 |
| heap before the pool and rounds / at the end | 8472 / 8472 B | 8472 / 8472 B |

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 19 capstone (1 CPU) ==+

Lesson 19, one CPU: the capstone -- threads, regions, a pool, queues, the SD card and the USB device.
  .data   000a9788 .. 000acf40
  heap    009b6000 .. 3b400000
  stack   0013f250 .. 0014f248 (thread main)

-- the card: none in this image (QEMU): the lines go to the UART only
  the logger owns the UART and the card (tests/tutor19.log); the USB file goes to tests/usbfile.bin

-- the USB device: the DWC2 gadget behind the USB-C socket, 2207:0019
  not up: no device-mode DWC2 under QEMU
  [ok] the sample pool, on the heap: 64 blocks

-- the churn: 8 rounds of 4 producers (static, stack, new, pool) and one consumer
  round 0: 256 samples as the reference, max 9975 (id 188); 0 misplaced; heap back, pool empty; cores 0000
  round 1: 256 samples as the reference, max 9976 (id 159); 0 misplaced; heap back, pool empty; cores 0000
  round 2: 256 samples as the reference, max 9904 (id 211); 0 misplaced; heap back, pool empty; cores 0000
  round 3: 256 samples as the reference, max 9967 (id 2); 0 misplaced; heap back, pool empty; cores 0000
  round 4: 256 samples as the reference, max 9926 (id 211); 0 misplaced; heap back, pool empty; cores 0000
  round 5: 256 samples as the reference, max 9929 (id 18); 0 misplaced; heap back, pool empty; cores 0000
  round 6: 256 samples as the reference, max 9939 (id 243); 0 misplaced; heap back, pool empty; cores 0000
  round 7: 256 samples as the reference, max 9974 (id 57); 0 misplaced; heap back, pool empty; cores 0000
  [ok] every round's result was the reference's (8 of 8)
  [ok] every sample lay where its source says
  [ok] after every round the heap was back and the pool empty
  [ok] 40 threads created and destroyed

-- the card read back
  the churn: 8 rounds, 8 as the reference, 8 clean, 0 misplaced, 40 threads
  heap: 8472 B before the pool and the rounds, 8472 B at the end
  [ok] the heap is back to its level
RESULT: PASS (the capstone: rounds, regions, pool, queues; no SD card, no USB device under QEMU; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 19 capstone (4 CPU) ==+

Lesson 19, four CPUs: the capstone -- threads, regions, a pool, queues, the SD card and the USB device.
  .data   000a75d8 .. 000ab0c8
  heap    009c1000 .. 3b400000
  stack   0014a570 .. 0015a560 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

-- the card: none in this image (QEMU): the lines go to the UART only
  the logger owns the UART and the card (tests/tutor19.log); the USB file goes to tests/usbfile.bin

-- the USB device: the DWC2 gadget behind the USB-C socket, 2207:0019
  not up: no device-mode DWC2 under QEMU
  [ok] the sample pool, on the heap: 64 blocks

-- the churn: 8 rounds of 4 producers (static, stack, new, pool) and one consumer
  round 0: 256 samples as the reference, max 9975 (id 188); 0 misplaced; heap back, pool empty; cores 0123
  round 1: 256 samples as the reference, max 9976 (id 159); 0 misplaced; heap back, pool empty; cores 0123
  round 2: 256 samples as the reference, max 9904 (id 211); 0 misplaced; heap back, pool empty; cores 0123
  round 3: 256 samples as the reference, max 9967 (id 2); 0 misplaced; heap back, pool empty; cores 0123
  round 4: 256 samples as the reference, max 9926 (id 211); 0 misplaced; heap back, pool empty; cores 0123
  round 5: 256 samples as the reference, max 9929 (id 18); 0 misplaced; heap back, pool empty; cores 0123
  round 6: 256 samples as the reference, max 9939 (id 243); 0 misplaced; heap back, pool empty; cores 0123
  round 7: 256 samples as the reference, max 9974 (id 57); 0 misplaced; heap back, pool empty; cores 0123
  [ok] every round's result was the reference's (8 of 8)
  [ok] every sample lay where its source says
  [ok] after every round the heap was back and the pool empty
  [ok] 40 threads created and destroyed
  [ok] the producers ran on all 4 cores

-- the card read back
  the churn: 8 rounds, 8 as the reference, 8 clean, 0 misplaced, 40 threads
  heap: 8472 B before the pool and the rounds, 8472 B at the end
  [ok] the heap is back to its level
RESULT: PASS (the capstone: rounds, regions, pool, queues; no SD card, no USB device under QEMU; four CPUs)
```
