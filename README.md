# µOS++ IIIe for Zig — the portable kernel

A port of [µOS++ IIIe](https://micro-os-plus.github.io/) (the
`micro-os-plus-iii` C++ project, SMP branch) to **Zig 0.17**, written in
idiomatic Zig: explicit allocators, error unions instead of `result_t`,
comptime configuration, and the new `std.Io` interface.

This repository is the **portable part** only, as in C++. An application
also needs exactly one architecture port, a sibling repository:

```text
micro-os-plu-iii-smp-zig-pr-github/
├── micro-os-plus-iii/            ← this repository (the kernel, module `uos`)
└── micro-os-plus-iii-cortexm/    ← the Cortex-M port (Pico 2, WeAct F411, ...)
```

## What is in it

| Folder / file | Contents | C++ counterpart |
| --- | --- | --- |
| `src/uos.zig` | The module root: `uos.rtos`, `uos.memory`, `uos.trace`, `uos.Io`, `uos.io.devices` | `cmsis-plus/rtos/os.h` |
| `src/rtos/` | Scheduler (single core and SMP), threads, mutexes, condition variables, semaphores, event flags, message queues, memory pools, timers, clocks | `src/rtos/` |
| `src/memory/` | `FirstFitTop` (the system heap) and `BlockPool` allocators | `src/memory/` |
| `src/io/Io.zig` | A `std.Io` implementation on the RTOS (threads, mutexes, conditions, clocks, sleep, cancellation) | `estd/` (ISO C++ threads) |
| `src/io/devices.zig` | Char and block devices, partitions, locked devices, file descriptors, RAM disk | `posix-io/` |
| `src/c_api.zig`, `src/c_storage.zig` | The µOS++ C API (`os_thread_construct()`, `os_mutex_lock()`, ... — the 196 functions of `os-c-api.h`) | `src/rtos/os-c-wrapper.cpp` |
| `src/cmsis_os.zig` | The CMSIS-RTOS v1 API (`osThreadCreate()`, `osSignalWait()`, `osMailPut()`, ...) | `os-c-wrapper.cpp`, legacy part |
| `src/libc.zig` | A minimal C runtime for freestanding C code: `printf` & co., string functions, `assert`, `trace_printf` | newlib + `src/diag/` |
| `src/config.zig` | `uos.Options`, the configuration | `os-app-config.h` |
| `src/port_contract.zig` | What a port must provide, checked at compile time | `rtos/port/*.h` |
| `include/` | The C headers: `cmsis-plus/rtos/os-c-api.h`, `os-c-decls.h`, `cmsis-plus/legacy/cmsis_os.h`, `cmsis-plus/diag/trace.h`, and `c/` (the minimal C runtime) | `include/` |
| `tests/suites/` | Test suites shared by the ports | `tests/sources/` |
| `docs/` | Architecture and internals, porting guides | |

## Configuration

An application declares `pub const uos_options: uos.Options = .{ ... };`
in its root file. The fields mirror the C++ `OS_INTEGER_*`, `OS_INCLUDE_*`
and `OS_USE_*` macros, for example:

| Option | Default | C++ |
| --- | --- | --- |
| `ncpu`, `smp` | `1`, `false` | `OS_NCPU`, `OS_USE_SMP_SCHEDULER` |
| `systick_frequency_hz` | `1000` | `OS_INTEGER_SYSTICK_FREQUENCY_HZ` |
| `main_stack_size_bytes`, `default_stack_size_bytes`, `idle_stack_size_bytes` | `4096`, `2048`, `1024` | `OS_INTEGER_RTOS_*_STACK_SIZE_BYTES` |
| `critical_section_interrupt_priority` | `null` (PRIMASK) | `OS_INTEGER_RTOS_CRITICAL_SECTION_INTERRUPT_PRIORITY` |
| `dynamic_memory_size_bytes` | 16 KiB | `OS_INTEGER_RTOS_DYNAMIC_MEMORY_SIZE_BYTES` |
| `statistics_context_switches`, `statistics_cpu_cycles` | `false` | `OS_INCLUDE_RTOS_STATISTICS_THREAD_*` |
| `c_api` | `false` | Export the µOS++ C API |
| `cmsis_os` | `false` | Export the CMSIS-RTOS v1 API |
| `c_runtime` | `false` | Export the minimal C runtime (freestanding only) |

## C code

C sources can be linked with the kernel and call it through the same C API
as in C++. There is still one kernel: the C functions are thin wrappers that
convert their arguments and call the Zig objects.

- Enable `c_api` (and `cmsis_os` for the CMSIS-RTOS v1 API). On a
  freestanding target, enable `c_runtime` too: it provides the few libc
  functions such code needs, with the output on the trace channel.
- Add the include folders with `addCIncludes()` from this `build.zig`.
- The headers are the C++ ones, except `os-c-decls.h`: its types, enums and
  attributes are the C++ ones, but the objects (`os_thread_t`,
  `os_mutex_t`, ...) are opaque storage sized for the Zig objects. C code
  allocates them and passes pointers; it never reads their members. The
  sizes are in `src/c_storage.zig` too: the build fails when a Zig object
  outgrows its storage, and a host test fails when the header disagrees.
- Not available: `os_thread_get_user_storage()` and the C startup hooks
  (`os-hooks.h`); `os_thread_attr_t.th_cpu_affinity` is always present.

The original `test-c-api.c` of the C++ rtos-apis suite and the Arm
CMSIS-RTOS validator (60/60) run this way on the boards; see the Cortex-M
port.

## Building and testing

```sh
zig build test      # host unit tests of the port-independent parts
```

The kernel itself is tested through a port, on the boards; see
`micro-os-plus-iii-cortexm/README.md`.

A port uses `createModule()` (the `uos` module, wired to the port),
`createSuitesModule()` and `addCIncludes()` from `build.zig`.

## Licence

MIT, as µOS++; see `LICENSE`.
