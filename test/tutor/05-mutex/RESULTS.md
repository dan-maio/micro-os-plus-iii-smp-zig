# Lesson 05 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-05-mutex-1cpu` | PASS | PASS, 15 s |
| `tutor-05-mutex-4cpu` | PASS | PASS, 15 s (one earlier run failed, see below) |

Run on 2026-10-22. The board's verdict lines:

```
RESULT: PASS (no node lost under the mutex; types, try_lock and timed_lock as specified; one CPU)
RESULT: PASS (no node lost under the mutex across 4 cores; types, try_lock and timed_lock as specified; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. Under QEMU the results are the C++ lesson's:
596 nodes lost with one CPU, the same number as in C++ (the yield makes it
deterministic), 51 with four (timing), and all 800 under the mutex.

## Open point: core 3 faulted while starting

The first four-CPU board run — straight after the one-CPU run, without a
power-cycle — failed: core 3 never joined the scheduler (`c3=0`). Its UART
showed

```
!! PANIC: incorrectalignment (cpu3, at 0x8f474)
   from 0x90430
   from 0x8f474
   from 0x811bc
  cores joined after 3000 ms: c1=3 c2=3 c3=0
```

The addresses are `startup.S`'s `fatal_from_vec` → `port_fatal_exception()`
(`src/faults.zig`): core 3 took an exception while starting, and the report
itself failed. It read the faulting instruction through `@ptrFromInt(elr)`
as a `*const u32`, and Zig's alignment check found `ELR` not even 4-byte
aligned: core 3 had jumped to a junk address. The report now reads the code
word only when `ELR` is aligned and inside RAM, so the next occurrence will
show `ESR`, `ELR` and `FAR`. The cause is not found yet; the same core 3
ran nothing in two runs of lesson 04's four-CPU version on the board, also
after a run without a power-cycle. The re-run here passed.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 05 mutex (1 CPU) ==+

Lesson 05, one CPU: mutex, normal, errorcheck, recursive, try_lock, timed_lock.
  .data   00093f98 .. 0009a708
  heap    0091d570 .. 3b400000
  stack   000a7210 .. 000b7208 (thread main)

-- part A: 4 workers push 200 nodes each on one list, no lock
  the list holds 204 of 800 nodes: 596 lost
  [ok] without the lock nodes are lost (one CPU: the yield in the window makes it certain)

-- part B: the same, each push under one mutex
  the list holds 800 of 800 nodes
  [ok] with the mutex: all 800 nodes in the list, each once
  [ok] the sorted list's checksum equals the reference (341eecf1)

-- part C: normal, errorcheck, recursive
  normal: lock, then try_lock by the owner: EWOULDBLOCK
  [ok] normal: the owner's try_lock does not deadlock, returns EWOULDBLOCK
  errorcheck: lock, lock again: EDEADLK; unlock: ok; unlock again: EPERM
  [ok] errorcheck: relock EDEADLK, extra unlock EPERM
  recursive: 5 locks and 5 unlocks ok; another thread's try_lock: EWOULDBLOCK; a 6th unlock: EPERM
  [ok] recursive: 5 deep, busy for another thread, the 6th unlock EPERM

-- part D: a holder keeps the mutex 50 ticks
  try_lock: EWOULDBLOCK; timed_lock(10): ETIMEDOUT after 11 ticks; timed_lock(200): ok after 39 ticks, 0 ticks after the release
  [ok] try_lock on a held mutex: EWOULDBLOCK at once
  [ok] timed_lock(10): ETIMEDOUT after 10 ticks
  [ok] timed_lock(200): the mutex as soon as the holder released it
  [ok] heap back to 0 B
RESULT: PASS (no node lost under the mutex; types, try_lock and timed_lock as specified; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 05 mutex (4 CPU) ==+

Lesson 05, four CPUs: mutex, normal, errorcheck, recursive, try_lock, timed_lock.
  .data   00094290 .. 0009ad38
  heap    00929930 .. 3b400000
  stack   000b3530 .. 000c3520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

-- part A: 4 workers push 200 nodes each on one list, no lock
  the list holds 749 of 800 nodes: 51 lost
  [ok] without the lock: no more than 800 nodes (lost ones are printed above)

-- part B: the same, each push under one mutex
  the list holds 800 of 800 nodes
  [ok] with the mutex: all 800 nodes in the list, each once
  [ok] the sorted list's checksum equals the reference (341eecf1)

-- part C: normal, errorcheck, recursive
  normal: lock, then try_lock by the owner: EWOULDBLOCK
  [ok] normal: the owner's try_lock does not deadlock, returns EWOULDBLOCK
  errorcheck: lock, lock again: EDEADLK; unlock: ok; unlock again: EPERM
  [ok] errorcheck: relock EDEADLK, extra unlock EPERM
  recursive: 5 locks and 5 unlocks ok; another thread's try_lock: EWOULDBLOCK; a 6th unlock: EPERM
  [ok] recursive: 5 deep, busy for another thread, the 6th unlock EPERM

-- part D: a holder keeps the mutex 50 ticks, on core 1
  try_lock: EWOULDBLOCK; timed_lock(10): ETIMEDOUT after 10 ticks; timed_lock(200): ok after 39 ticks, 0 ticks after the release
  [ok] try_lock on a held mutex: EWOULDBLOCK at once
  [ok] timed_lock(10): ETIMEDOUT after 10 ticks
  [ok] timed_lock(200): the mutex as soon as the holder released it
  [ok] heap back to 0 B
RESULT: PASS (no node lost under the mutex across 4 cores; types, try_lock and timed_lock as specified; four CPUs)
```
