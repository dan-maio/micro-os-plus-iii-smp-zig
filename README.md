# µOS++ IIIe for Zig — the synthetic POSIX port

The port of the Zig µOS++ IIIe kernel (`../micro-os-plus-iii`) to a POSIX
host: µOS++ runs as an ordinary GNU/Linux process, with host threads acting
as CPUs. It is the Zig counterpart of the C++
`micro-os-plus-iii-posix-arch`, `smp` branch: glibc ucontexts for the
threads (no libucontext), a per-CPU `timer_create()` tick on `SIGRTMIN`,
IPIs on `SIGRTMIN + 1`, signal masks as interrupt masks.

The design is described in
[docs/posix-port-architecture-and-internals.md](docs/posix-port-architecture-and-internals.md)
(also as a PDF).

## Requirements

- Zig 0.17.0, on GNU/Linux (x86_64).
- The kernel, `../micro-os-plus-iii`.
- For `cmsis-os-validator`: the `@xpacks/arm-cmsis-rtos-validator` xPack
  (default `~/.local/xPacks/@xpacks/arm-cmsis-rtos-validator/1.0.0-4`,
  otherwise `-Dcmsis_rv=<folder>`; without it the test is skipped).

## Build and run

```sh
zig build                              # build every test
./zig-out/bin/smp-test1                # run one
zig build run -Dtest=smp-test1         # build only that one, and run it
test/run-all.sh                        # all of them, with a verdict table
test/run-all.sh smp-test1 flatfs-test  # some of them
```

A test's verdict is its exit code, and its last line is `RESULT: PASS` or
`RESULT: FAIL`. The SD tests use a 32 MiB `disk.img` in the current folder
(or `$UOS_SD_IMAGE`); `run-all.sh` runs every test in its own folder under
`zig-out/run/`, with its output in `zig-out/run/<test>.log`.

## Layout

| Path | Contents |
| --- | --- |
| `src/port.zig` | the port: contexts, signals, CPUs, kernel lock, clocks, trace, faults |
| `src/host.h` | the glibc headers translated into the `host_c` module |
| `include/cmsis-plus/rtos/port/os-c-storage.h` | the C API's larger `os_thread_t` (a thread carries a ucontext) |
| `drivers/` | the native board's storage: `sd.zig` (a host file as the SD card), `flatfs.zig` |
| `test/board.zig` | the native board (console, LED, secondary CPUs, verdict, kernel options) |
| `test/<name>/main.zig` | the tests, faithful ports of the C++ `test/native/` ones |
| `test/run-all.sh` | the runner |

## Tests

All of them pass; see the document above for the list and how they compare
with the C++ native builds.

## Licence

MIT, as µOS++; see `LICENSE`.
