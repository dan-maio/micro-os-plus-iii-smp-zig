# Lesson 15 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-15-thread-control-1cpu` | PASS | PASS, 14 s |
| `tutor-15-thread-control-4cpu` | PASS | PASS, 15 s |

Run on 2026-10-23, with the two kernel fixes of this lesson. The board's
verdict lines:

```
RESULT: PASS (states, suspend/resume, interrupt and kill; stack high-water marks; CPU time adding up; one CPU)
RESULT: PASS (states, suspend/resume, interrupt and kill across cores; stack high-water marks; CPU time adding up over four CPUs; a running thread killed; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 15 thread control (1 CPU) ==+

Lesson 15, one CPU: a thread's states, suspend/resume, interrupt, kill; its stack; its statistics.
  .data   00096688 .. 00096968
  heap    00912000 .. 3b400000
  stack   0009b210 .. 000ab208 (thread main)

-- part A: a worker (above_normal) paused and resumed 5 times, interrupted twice, killed
  the worker saw itself running (core 0); it paused 5 times, each time suspended until resumed
  [ok] a thread sees itself running
  [ok] suspended after each pause, it ran again only when resumed (5 times)
  waiting (suspended): interrupt() -> EINTR, flag set, cleared yes; sleeping 100 s: interrupt() after 5 ticks -> EINTR after 6 ticks
  [ok] a wait interrupted returns EINTR; the flag stays set until cleared
  [ok] a sleep interrupted returns EINTR at once
  waiting forever: kill() -> ok, state destroyed; a post then stays (value 1), phase 3
  [ok] a waiting thread killed: destroyed, and no longer on the semaphore's list
  a lower thread just created: ready; kill() -> ok, state destroyed, ran 0
  [ok] a ready thread killed before it ran
  a higher thread that returned: terminated; joined: destroyed, its result 42
  [ok] a returned thread is terminated until reaped; join gives its result

-- part B: the stack's high-water mark: recursion of 0, 4, 8, 16 frames of 256 B; interrupts
  of 8184 B: depth 0 used 808 B (the frame the thread started from), depth 4 1544 B, 8 2696 B, 16 5000 B -> 288 and 288 B per frame; shallow but interrupted: 2344 B (+1536 B); 0 run(s) again after a tick
  the main thread: 5256 B of 65528 B used
  [ok] the high-water mark grows with the depth, within the stack
  [ok] each frame costs its 256 B array plus a few words, the same at every depth
  [ok] an interrupt's frame lands on the interrupted thread's stack

-- part C: statistics: 1 pulse (50 x 2000 us of work, 2-tick sleeps) above 1 hog
  pulse 0: 100282 us of CPU, scheduled 152 times; hog 0: 99466 us
  elapsed 200014 us; all threads' CPU time 200080 us = 1.00 x elapsed
  [ok] each pulse used about 100000 us of CPU and was scheduled at least 50 times
  [ok] each hog had the rest of its core
  [ok] the CPU time of all threads adds up to 1 x the elapsed time
  [ok] heap back to 0 B
RESULT: PASS (states, suspend/resume, interrupt and kill; stack high-water marks; CPU time adding up; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 15 thread control (4 CPU) ==+

Lesson 15, four CPUs: a thread's states, suspend/resume, interrupt, kill; its stack; its statistics.
  .data   00097bc8 .. 000981e8
  heap    00920000 .. 3b400000
  stack   000a9530 .. 000b9520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

-- part A: a worker (above_normal, on core 1) paused and resumed 5 times, interrupted twice, killed
  the worker saw itself running (core 1); it paused 5 times, each time suspended until resumed
  [ok] a thread sees itself running
  [ok] suspended after each pause, it ran again only when resumed (5 times)
  [ok] the worker ran on core 1
  waiting (suspended): interrupt() -> EINTR, flag set, cleared yes; sleeping 100 s: interrupt() after 5 ticks -> EINTR after 5 ticks
  [ok] a wait interrupted returns EINTR; the flag stays set until cleared
  [ok] a sleep interrupted returns EINTR at once
  waiting forever: kill() -> ok, state destroyed; a post then stays (value 1), phase 3
  [ok] a waiting thread killed: destroyed, and no longer on the semaphore's list
  a lower thread just created: ready; kill() -> ok, state destroyed, ran 0
  [ok] a ready thread killed before it ran
  a higher thread that returned: terminated; joined: destroyed, its result 42
  [ok] a returned thread is terminated until reaped; join gives its result

-- part B: the stack's high-water mark: recursion of 0, 4, 8, 16 frames of 256 B; interrupts
  of 8184 B: depth 0 used 808 B (the frame the thread started from), depth 4 1544 B, 8 2696 B, 16 5000 B -> 288 and 288 B per frame; shallow but interrupted: 2344 B (+1536 B); 0 run(s) again after a tick
  the main thread: 5408 B of 65520 B used
  [ok] the high-water mark grows with the depth, within the stack
  [ok] each frame costs its 256 B array plus a few words, the same at every depth
  [ok] an interrupt's frame lands on the interrupted thread's stack

-- part C: statistics: 3 pulses (50 x 2000 us of work, 2-tick sleeps) above 3 hogs, one of each on cores 1, 2, 3
  pulse 0: 100523 us of CPU, scheduled 153 times; hog 0: 96741 us
  pulse 1: 100551 us of CPU, scheduled 156 times; hog 1: 96594 us
  pulse 2: 100640 us of CPU, scheduled 153 times; hog 2: 95639 us
  elapsed 197451 us; all threads' CPU time 791165 us = 4.00 x elapsed
  [ok] each pulse used about 100000 us of CPU and was scheduled at least 50 times
  [ok] each hog had the rest of its core
  [ok] the CPU time of all threads adds up to 4 x the elapsed time

-- part D: kill a thread while it runs on core 2
  spinner on core 2: running; kill() -> ok in 157 us, state destroyed; it spun 0 more times after
  [ok] the spinner was running on core 2
  [ok] killed while running on another core: it stopped there, at once
  [ok] heap back to 0 B
RESULT: PASS (states, suspend/resume, interrupt and kill across cores; stack high-water marks; CPU time adding up over four CPUs; a running thread killed; four CPUs)
```
