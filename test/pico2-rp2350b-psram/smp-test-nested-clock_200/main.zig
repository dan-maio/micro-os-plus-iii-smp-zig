//! smp-test-nested-clock_200 (Pico 2 / RP2350B) -- pot -> clock -> SMP nested test, with a
//! block linear solver in the PSRAM.
//!
//! The Zig port of test/pico2-rp2350b-psram/smp-test-nested-clock_200/main.cpp, line for line.
//! Its build: the from-scratch clock table up to 200 MHz, the PSRAM, the ADC
//! (C++ PICO2_CLOCK_FROM_SCRATCH PICO2_PSRAM).
//!
//!   - The clock is a row of the from-scratch table (`src/boards/rp2350_clocks.zig`,
//!     the C++ clocks.cpp), chosen through the watchdog scratch registers: 48 MHz on
//!     a cold boot. A gate shows the clock and the potentiometer (GPIO40 / ADC0)
//!     and waits for 'y' on the console; a pot band different from the running
//!     clock reboots into it (watchdog), and ESC goes back to 48 MHz.
//!   - The nesting interrupts of smp-test-nested: UART0 (priority 12, pended by
//!     hand every 1.5 s, busy ~2 ms), TIMER0 alarm 2 (8, every 1.25 s) and
//!     alarm 3 (10, every 1.2495 s), on both cores, with the lock-free trace
//!     log (SIO spinlock 4) and the handlers in RAM (`.ram_text`).
//!   - A parallel block solver (N = 500, B = 50, 2 cores) in the PSRAM, its
//!     solution printed; then 10 worker beats, and PASS when both workers did
//!     and the three interrupts fired. The other core is stopped (PSM) before
//!     the verdict, as in C++.
//!
//! Differences from C++: the kernel's startup banner and exit trace; the
//! clocks are brought up at the start of main() (C++: in the start-up, on the
//! boot clock: MicroZig has the chip at 150 MHz by then), after the PSRAM
//! init (C++: boot.S), so the PSRAM's QMI divider is adjusted the same way;
//! the solver's arrays and workspaces are placed in the PSRAM explicitly
//! (C++: all of .bss is in the PSRAM); the kernel creates each CPU's idle
//! thread itself, so the core-1 NVIC set-up of the C++ test's own idle1
//! thread is done by `nvic1`, a thread pinned to core 1 at the idle priority;
//! the threads are static objects (C++: `new thread`); the run ends with
//! osMain()'s return value through exit() (C++: hw_result::ok()).

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const arch = uos.port.arch;
const semihosting = uos.port.semihosting;
const uart = board.uart;
const adc = board.adc;
const psram = board.psram;
const rp_clocks = board.clocks;

/// The C++ build's PICO2_ENABLE_250MHZ and PICO2_PSRAM.
const clocks = rp_clocks.Clocks(false, true);

pub const microzig_options = uos.port.microzig_options;

pub const uos_options: uos.Options = .{
    .ncpu = 2,
    .smp = true,
    .systick_frequency_hz = 1000,
    .critical_section_interrupt_priority = 5,
    .main_stack_size_bytes = 8192,
    .idle_stack_size_bytes = 4096,
    .default_stack_size_bytes = 4096,
    .dynamic_memory_size_bytes = 96 * 1024,
};

/// Core 1 is launched by `osMain()`, as in C++.
pub const uos_port_options: uos.port.Options = .{ .launch_core1_at_start = false };

/// The three nesting interrupts.
pub const uos_interrupts = .{
    .UART0_IRQ = microzig.interrupt.Handler{ .c = uart0IrqHandler },
    .TIMER0_IRQ_2 = microzig.interrupt.Handler{ .c = timer0Irq2Handler },
    .TIMER0_IRQ_3 = microzig.interrupt.Handler{ .c = timer0Irq3Handler },
};

comptime {
    microzig.export_startup();
}

pub fn main() void {
    // The PSRAM first (C++: boot.S), at the start-up clock, then the clock
    // from the table, which also slows the PSRAM's QMI clock above 200 MHz
    // (C++: clocks::init() in the start-up); the console and the SysTick
    // follow the new frequency.
    psram_ok = psram.init();
    board.setCpuFrequency(clocks.init());
    rtos.run(osMain);
}

var psram_ok = false;

fn reg(a: usize) *volatile u32 {
    return @ptrFromInt(a);
}

fn ld(p: anytype) @TypeOf(p.*) {
    return @atomicLoad(@TypeOf(p.*), p, .acquire);
}

fn st(p: anytype, v: @TypeOf(p.*)) void {
    @atomicStore(@TypeOf(p.*), p, v, .release);
}

fn dmb() void {
    asm volatile ("dmb" ::: .{ .memory = true });
}

var g_global: u32 = 0;
var g_mutex: rtos.Mutex = .{ .name = "g" };

const StackElement = uos.port.StackElement;
var worker_stacks: [2][1024]StackElement align(8) = undefined;
var led_stack: [1024]StackElement align(8) = undefined;
var trigger_stack: [1024]StackElement align(8) = undefined;
var trace_stack: [1024]StackElement align(8) = undefined;
var pot_stack: [1024]StackElement align(8) = undefined;
var nvic1_stack: [512]StackElement align(8) = undefined;

const Ctx = struct {
    id: u32,
    local: u32,
};
var worker_ctx: [2]Ctx = undefined;

// How many times each nesting interrupt ran, for the verdict.
var g_irq_uart: u32 = 0;
var g_irq_t2: u32 = 0;
var g_irq_t3: u32 = 0;

// ---- TIMER0 alarm definitions -----------------------------------------------

const RESETS_BASE: usize = 0x4002_0000;
const TIMER0_BASE: usize = 0x400B_0000;
const TIMER0_RESET_BIT: u5 = 23;
const RESET_REG = RESETS_BASE + 0x00;
const RESET_DONE_REG = RESETS_BASE + 0x08;
const TIMER_TIMEHR = TIMER0_BASE + 0x08;
const TIMER_TIMELR = TIMER0_BASE + 0x0C;
const TICKS_BASE: usize = 0x4010_8000;
const TICKS_TIMER0_CTRL = TICKS_BASE + 0x18;
const TICKS_TIMER0_CYCLES = TICKS_BASE + 0x1C;
const TICKS_CTRL_ENABLE: u32 = 1 << 0;
const CLK_REF_HZ: u32 = 12_000_000;
const UART0_BASE: usize = 0x4007_0000;
const WATCHDOG_SCRATCH2: usize = 0x400D_8014;
const AUTOSTART_MAGIC: u32 = 0xA5A5_7A57;
const PSM_BASE: usize = 0x4001_8000;
const SIO_CPUID: usize = 0xD000_0000;

const TIMER0_IRQ_2: u32 = 2;
const TIMER0_IRQ_3: u32 = 3;
const UART0_IRQ: u32 = 33;

fn timerInit() void {
    reg(RESET_REG).* &= ~(@as(u32, 1) << TIMER0_RESET_BIT);
    while (reg(RESET_DONE_REG).* & (@as(u32, 1) << TIMER0_RESET_BIT) == 0) {}
    reg(TICKS_TIMER0_CYCLES).* = CLK_REF_HZ / 1_000_000;
    reg(TICKS_TIMER0_CTRL).* = TICKS_CTRL_ENABLE;
}

noinline fn timerUs32() linksection(".ram_text") u32 {
    const hi = reg(TIMER_TIMEHR).*;
    const lo = reg(TIMER_TIMELR).*;
    _ = hi;
    return lo;
}

noinline fn alarm2Arm(delay_us: u32) linksection(".ram_text") void {
    const now = timerUs32();
    reg(TIMER0_BASE + 0x18).* = now +% delay_us; // ALARM2
}

noinline fn alarm3Arm(delay_us: u32) linksection(".ram_text") void {
    const now = timerUs32();
    reg(TIMER0_BASE + 0x1c).* = now +% delay_us; // ALARM3
}

/// A priority in the NVIC's upper bits (C++ NVIC_SetPriority).
fn nvicPriority(irq: u32, prio: u8) void {
    arch.nvicSetPriority(irq, prio << (8 - @as(u4, arch.nvic_prio_bits)));
}

fn nvicSetPending(irq: u32) void {
    reg(0xE000_E200 + 4 * (irq / 32)).* = @as(u32, 1) << @intCast(irq % 32);
}

// ---- Lock-free trace logging -------------------------------------------------

const TraceEvent = struct {
    timestamp: u32,
    core: u8,
    event_name: []const u8,
    thread_name: []const u8,
    thread_id: usize,
};

const TRACE_MAX = 512;
var g_trace_buffer: [TRACE_MAX]TraceEvent = undefined;
var g_trace_count: u32 = 0;

// SIO spinlock 4 protects the trace buffer counter increment. Interrupts are
// disabled locally on the core before acquiring the spinlock to prevent a
// same-core preemption deadlock.
const TRACE_LOCK: usize = 0xD000_0100 + 16; // slot 4

noinline fn allocateTraceSlot() linksection(".ram_text") u32 {
    const saved = arch.getPrimask();
    asm volatile ("cpsid i" ::: .{ .memory = true });
    while (reg(TRACE_LOCK).* == 0) {}
    const idx = ld(&g_trace_count);
    st(&g_trace_count, idx + 1);
    reg(TRACE_LOCK).* = 1;
    arch.setPrimask(saved);
    return idx;
}

noinline fn logTraceAt(event_name: []const u8, timestamp: u32) linksection(".ram_text") void {
    const idx = allocateTraceSlot();
    if (idx < TRACE_MAX) {
        const cpu = uos.port.scheduler.cpuId();
        const th = uos.rtos.scheduler.current_thread[cpu];
        g_trace_buffer[idx] = .{
            .timestamp = timestamp,
            .core = @intCast(cpu),
            .event_name = event_name,
            .thread_name = if (th) |t| t.name else "none",
            .thread_id = if (th) |t| @intFromPtr(t) else 0,
        };
    }
}

noinline fn logTrace(event_name: []const u8) linksection(".ram_text") void {
    logTraceAt(event_name, timerUs32());
}

// ---- Worker/heartbeat line prints --------------------------------------------

fn line(role: []const u8, id: u32, local: u32, global: u32) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "[{d:>8} ms] {s:<6} #{d} (ID: 0x{x}) core={d} local={d:<4} global={d}\n", .{
        sysclock.now(), role, id, @intFromPtr(this_thread.thread()), uos.port.scheduler.cpuId(), local, global,
    }) catch return;
    g_mutex.lock() catch {};
    uart.write(s);
    g_mutex.unlock() catch {};
}

// ---- Threads -------------------------------------------------------------------

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const c: *Ctx = @ptrCast(@alignCast(arg.?));
    while (true) {
        st(&c.local, c.local + 1);
        g_mutex.lock() catch {};
        g_global += 1;
        const g = g_global;
        g_mutex.unlock() catch {};
        line("worker", c.id, c.local, g);
        logTrace("Worker_Run");
        sysclock.sleepFor(1000) catch {};
    }
    return null;
}

fn ledThread(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        sysclock.sleepFor(3000) catch {};
        line("LED", 0, 0, g_global);
        logTrace("LED_Blink");
        for (0..3) |_| {
            board.led.set(true);
            sysclock.sleepFor(200) catch {};
            board.led.set(false);
            sysclock.sleepFor(200) catch {};
        }
    }
    return null;
}

fn triggerThread(_: ?*anyopaque) ?*anyopaque {
    sysclock.sleepFor(2000) catch {};
    while (true) {
        sysclock.sleepFor(1500) catch {}; // trigger the nesting sequence every 1.5 s
        const trig_time = timerUs32();
        // Pend the UART0 exception (priority 12).
        nvicSetPending(UART0_IRQ);
        logTraceAt("Trigger", trig_time);
    }
    return null;
}

fn tracePrinterThread(_: ?*anyopaque) ?*anyopaque {
    sysclock.sleepFor(3000) catch {}; // offset, to avoid overlapping startup prints
    while (true) {
        sysclock.sleepFor(4000) catch {}; // dump the trace log every 4 seconds

        g_mutex.lock() catch {};
        uart.write("\n================== TRACE LOG BUFFER DUMP ==================\n");

        var count = ld(&g_trace_count);
        if (count > TRACE_MAX) count = TRACE_MAX;

        for (g_trace_buffer[0..count]) |*e| {
            var buf: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "[{d:>8} us] C{d} Event: {s:<12} | Interrupted Thread: {s} (ID: 0x{x})\n", .{
                e.timestamp, e.core, e.event_name, e.thread_name, e.thread_id,
            }) catch continue;
            uart.write(s);
        }

        uart.write("===========================================================\n\n");

        // Reset the counter.
        st(&g_trace_count, 0);
        g_mutex.unlock() catch {};
    }
    return null;
}

// ---- Potentiometer -> clock selector (with y/Y confirmation) ------------------
// Reads GPIO40/ADC0, maps 0..4095 to one of the table rows. When the pot
// settles on a DIFFERENT row than the one we booted at, it prints the wanted
// clock and WAITS: the reset into the new clock only happens once the user
// presses 'y'/'Y' on the console. 'n'/'N' (or turning the pot back to the
// current clock) cancels; turning it to yet another band re-prompts. A short
// debounce (stable for a few samples) gives band-edge hysteresis.

const POT_N: u32 = clocks.sys_table_len;
const POT_DEBOUNCE = 4; // ~200 ms at 50 ms/sample

/// Drain all pending RX bytes and return the highest-priority action key seen:
/// ESC (27) beats 'y'/'Y' beats 'n'/'N'; -1 if none.
fn pollKey() i32 {
    var best: i32 = -1;
    for (0..64) |_| {
        const c = uart.getChar() orelse break;
        if (c == 27) {
            best = 27;
        } else if ((c == 'y' or c == 'Y') and best != 27) {
            best = 'y';
        } else if ((c == 'n' or c == 'N') and best < 0) {
            best = 'n';
        }
    }
    return best;
}

fn potBand() u32 {
    const raw = adc.read(adc.pot_channel);
    const band = (@as(u32, raw) * POT_N) / 4096;
    return if (band >= POT_N) POT_N - 1 else band;
}

fn potPrompt(band: u32) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\n[pot] wanted clock = {d} MHz (band {d}).\n      press 'y' to apply (reset into it), 'n' to cancel.\n", .{
        clocks.sys_table[band].khz / 1000, band,
    }) catch return;
    g_mutex.lock() catch {};
    uart.write(s);
    g_mutex.unlock() catch {};
}

fn locked(s: []const u8) void {
    g_mutex.lock() catch {};
    uart.write(s);
    g_mutex.unlock() catch {};
}

fn potThread(_: ?*anyopaque) ?*anyopaque {
    const booted = clocks.currentIndex();
    var candidate: i32 = -1;
    var stable: i32 = 0;
    var wanted: i32 = -1; // band awaiting y/Y confirmation, or -1 while monitoring

    while (true) {
        const band = potBand();
        const c = pollKey();

        // ESC at any time: full reset back to the SAFE 48 MHz banner (index 0).
        if (c == 27) {
            locked("\n[esc] full reset to 48 MHz banner...\n");
            sysclock.sleepFor(20) catch {};
            reg(WATCHDOG_SCRATCH2).* = 0; // no autostart -> gate
            clocks.rebootToIndex(0);
        }

        if (wanted < 0) {
            // Monitoring: wait for a stable band different from the running one.
            if (band == booted) {
                candidate = -1;
                stable = 0;
            } else if (@as(i32, @intCast(band)) == candidate) {
                stable += 1;
                if (stable >= POT_DEBOUNCE) {
                    wanted = @intCast(band);
                    candidate = -1;
                    stable = 0;
                    potPrompt(@intCast(wanted));
                }
            } else {
                candidate = @intCast(band);
                stable = 1;
            }
        } else {
            // Awaiting confirmation for 'wanted'.
            if (c == 'y') {
                locked("[pot] confirmed: resetting...\n");
                sysclock.sleepFor(20) catch {}; // let the UART FIFO drain
                // Choosing the clock IS the confirmation to run: the next boot
                // skips the 'y' start gate.
                reg(WATCHDOG_SCRATCH2).* = AUTOSTART_MAGIC;
                clocks.rebootToIndex(@intCast(wanted));
            } else if (c == 'n') {
                locked("[pot] cancelled.\n");
                wanted = -1;
                candidate = -1;
                stable = 0;
            } else if (band != @as(u32, @intCast(wanted))) {
                // Pot moved while waiting: re-arm on the new stable band.
                if (@as(i32, @intCast(band)) == candidate) {
                    stable += 1;
                    if (stable >= POT_DEBOUNCE) {
                        candidate = -1;
                        stable = 0;
                        if (band == booted) {
                            locked("[pot] back to current clock; cancelled.\n");
                            wanted = -1;
                        } else {
                            wanted = @intCast(band);
                            potPrompt(@intCast(wanted));
                        }
                    }
                } else {
                    candidate = @intCast(band);
                    stable = 1;
                }
            } else {
                candidate = -1;
                stable = 0;
            }
        }
        sysclock.sleepFor(50) catch {};
    }
    return null;
}

// ---- Block linear solver (from smp-mat-test) -------------------------------------
// Solves A x = b (N x N, diagonally dominant) by parallel BLOCK Gaussian
// elimination: two solver threads pinned to cores 0/1, block size B, row
// blocks distributed across the two cores, synchronised by generation-based
// SIO-spinlock barriers; core 0 does the diagonal LU and the back
// substitution. The matrices are in the PSRAM. After the solution has been
// printed the threads return -> terminated.
// N=500, B=50 -> 10 blocks. Two N x N matrices (A + A_block).

const N = 500;
const B = 50;
const ncpu = 2;

comptime {
    if (N % B != 0) @compileError("N must be divisible by B");
    if ((N / B) % ncpu != 0) @compileError("the number of blocks N/B must be a multiple of the cores");
}

const Barrier = struct {
    target_count: u32 = 0,
    current_count: u32 = 0,
    generation: u32 = 0,
    lock_reg: *volatile u32 = undefined,

    fn init(br: *Barrier, count: u32, sio_slot: u32) void {
        br.target_count = count;
        br.current_count = 0;
        br.generation = 0;
        br.lock_reg = @ptrFromInt(0xD000_0100 + 4 * sio_slot);
    }

    fn wait(br: *Barrier) void {
        dmb();
        const gen = ld(&br.generation);
        // The SIO hardware spinlock (slot 2/3) is the RP2350 cross-core primitive.
        while (br.lock_reg.* == 0) this_thread.yield();
        st(&br.current_count, ld(&br.current_count) + 1);
        if (ld(&br.current_count) == br.target_count) {
            st(&br.current_count, 0);
            st(&br.generation, gen + 1);
            br.lock_reg.* = 1; // release
        } else {
            br.lock_reg.* = 1; // release
            while (ld(&br.generation) == gen) this_thread.yield();
        }
        dmb();
    }
};

var g_barrier_lu: Barrier = .{};
var g_barrier_step: Barrier = .{};
var g_solver_done: bool = false;
var g_block_start_us: u32 = 0;
var g_block_end_us: u32 = 0;

const Mat = [B][B]f32;

// The solver's matrices and workspaces, in the PSRAM (C++: static globals in
// .bss, which its linker script puts in the PSRAM).
const PsramData = extern struct {
    A: [N][N]f32,
    b: [N]f32,
    A_block: [N][N]f32,
    b_block: [N]f32,
    x_block: [N]f32,
    LU_k_T: Mat,
    workspace_Src_T: [ncpu]Mat,
    workspace_M_T: [ncpu]Mat,
    M_local: [ncpu]Mat,
    A_kj: [ncpu]Mat,
    A_ij: [ncpu]Mat,
    A_kk_T: Mat,
    A_ii: Mat,
    LU_ii: Mat,
    A_ij_temp: Mat,
};
comptime {
    if (@sizeOf(PsramData) > psram.size) @compileError("the solver data does not fit in the PSRAM");
}
const pd: *PsramData = @ptrFromInt(psram.base);
const A = &pd.A;
const b = &pd.b;
const A_block = &pd.A_block;
const b_block = &pd.b_block;
const x_block = &pd.x_block;
const LU_k_T = &pd.LU_k_T;

var pivot_k_T: [B]usize = undefined;
var pivot_ii: [B]usize = undefined;
var temp_bi: [B]f32 = undefined;

var solver_stacks: [ncpu][1024]StackElement align(8) = undefined;
var solver_threads: [ncpu]rtos.Thread = undefined;
const solver_thread_names = [ncpu][:0]const u8{ "solver_c0", "solver_c1" };
var core_ids: [ncpu]u32 = .{ 0, 1 };

// ---- Solver console helpers ------------------------------------------------------

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [160]u8 = undefined;
    uart.write(std.fmt.bufPrint(&buf, fmt, args) catch buf[0..]);
}

/// "%d.%06d", as the C++ print_float().
fn printFloat(value: f32) void {
    var buf: [32]u8 = undefined;
    var val = value;
    if (val < 0.0) {
        uart.write("-");
        val = -val;
    }
    var int_part: i32 = @intFromFloat(val);
    var frac_part: i32 = @intFromFloat((val - @as(f32, @floatFromInt(int_part))) * 1000000.0 + 0.5);
    if (frac_part >= 1000000) {
        int_part += 1;
        frac_part -= 1000000;
    }
    uart.write(std.fmt.bufPrint(&buf, "{d}.{d:0>6}", .{ int_part, @as(u32, @intCast(frac_part)) }) catch "");
}

/// The newlib generator (srand/rand, RAND_MAX = 0x7FFFFFFF), so the matrix
/// is the one the C++ test solves.
const NewlibRand = struct {
    next: u64,

    const rand_max: u32 = 0x7FFF_FFFF;

    fn init(seed: u32) NewlibRand {
        return .{ .next = seed };
    }

    fn rand(r: *NewlibRand) u32 {
        r.next = r.next *% 6364136223846793005 +% 1;
        return @truncate((r.next >> 32) & rand_max);
    }
};

// ---- LU utilities for B x B blocks -------------------------------------------------

fn luDecompose(M: *const Mat, LU: *Mat, pivot: *[B]usize) bool {
    for (0..B) |i| {
        for (0..B) |j| LU[i][j] = M[i][j];
        pivot[i] = i;
    }
    for (0..B) |i| {
        var max_val: f32 = 0.0;
        var max_row = i;
        for (i..B) |r| {
            const val = @abs(LU[r][i]);
            if (val > max_val) {
                max_val = val;
                max_row = r;
            }
        }
        if (max_val < 1e-9) return false; // singular
        if (max_row != i) {
            std.mem.swap(usize, &pivot[i], &pivot[max_row]);
            for (0..B) |c| std.mem.swap(f32, &LU[i][c], &LU[max_row][c]);
        }
        for (i + 1..B) |r| {
            const factor = LU[r][i] / LU[i][i];
            LU[r][i] = factor;
            for (i + 1..B) |c| LU[r][c] = LU[r][c] - factor * LU[i][c];
        }
    }
    return true;
}

fn luSolve(LU: *const Mat, pivot: *const [B]usize, Y: *const [B]f32, X: *[B]f32) void {
    var temp: [B]f32 = undefined;
    for (0..B) |i| {
        temp[i] = Y[pivot[i]];
        for (0..i) |j| temp[i] = temp[i] - LU[i][j] * temp[j];
    }
    var i: usize = B;
    while (i > 0) {
        i -= 1;
        X[i] = temp[i];
        for (i + 1..B) |j| X[i] = X[i] - LU[i][j] * X[j];
        X[i] = X[i] / LU[i][i];
    }
}

/// Solve A_T * M_T = Src_T and transpose the result back to Dest.
fn solveBlockTranspose(LU_T: *const Mat, pivot_T: *const [B]usize, Src: *const Mat, Dest: *Mat, Src_T: *Mat, M_T: *Mat) void {
    for (0..B) |i| {
        for (0..B) |j| Src_T[i][j] = Src[j][i];
    }
    for (0..B) |col| {
        var y: [B]f32 = undefined;
        var x: [B]f32 = undefined;
        for (0..B) |r| y[r] = Src_T[r][col];
        luSolve(LU_T, pivot_T, &y, &x);
        for (0..B) |r| M_T[r][col] = x[r];
    }
    for (0..B) |i| {
        for (0..B) |j| Dest[i][j] = M_T[j][i];
    }
}

fn matMulSub(M: *const Mat, X: *const Mat, Dest: *Mat) void {
    for (0..B) |i| {
        for (0..B) |j| {
            var sum: f32 = 0.0;
            for (0..B) |k| sum = sum + M[i][k] * X[k][j];
            Dest[i][j] = Dest[i][j] - sum;
        }
    }
}

fn vecMulSub(M: *const Mat, v: *const [B]f32, Dest: *[B]f32) void {
    for (0..B) |i| {
        var sum: f32 = 0.0;
        for (0..B) |k| sum = sum + M[i][k] * v[k];
        Dest[i] = Dest[i] - sum;
    }
}

fn getMatrixBlock(Src: *const [N][N]f32, br: usize, bc: usize, Dest: *Mat) void {
    for (0..B) |i| {
        for (0..B) |j| Dest[i][j] = Src[br * B + i][bc * B + j];
    }
}

fn setMatrixBlock(Dest: *[N][N]f32, br: usize, bc: usize, Src: *const Mat) void {
    for (0..B) |i| {
        for (0..B) |j| Dest[br * B + i][bc * B + j] = Src[i][j];
    }
}

fn vecSlice(v: *[N]f32, block: usize) *[B]f32 {
    return v[block * B ..][0..B];
}

// ---- Per-core solver worker (block parallel elimination) ---------------------------

fn solverThreadFunc(arg: ?*anyopaque) ?*anyopaque {
    const core_id: usize = @as(*const u32, @ptrCast(@alignCast(arg.?))).*;
    const num_blocks = N / B;

    if (core_id == 0) st(&g_block_start_us, timerUs32());

    for (0..num_blocks - 1) |k| {
        if (core_id == 0) {
            // Core 0: LU-decompose the diagonal block A_kk (transposed layout).
            for (0..B) |i| {
                for (0..B) |j| pd.A_kk_T[i][j] = A_block[k * B + j][k * B + i];
            }
            _ = luDecompose(&pd.A_kk_T, LU_k_T, &pivot_k_T);
        }
        g_barrier_lu.wait();

        // All cores: compute multipliers + update their assigned row blocks.
        for (k + 1..num_blocks) |i| {
            if ((i - (k + 1)) % ncpu == core_id) {
                getMatrixBlock(A_block, i, k, &pd.A_kj[core_id]);
                solveBlockTranspose(LU_k_T, &pivot_k_T, &pd.A_kj[core_id], &pd.M_local[core_id], &pd.workspace_Src_T[core_id], &pd.workspace_M_T[core_id]);
                for (k + 1..num_blocks) |j| {
                    getMatrixBlock(A_block, k, j, &pd.A_kj[core_id]);
                    getMatrixBlock(A_block, i, j, &pd.A_ij[core_id]);
                    matMulSub(&pd.M_local[core_id], &pd.A_kj[core_id], &pd.A_ij[core_id]);
                    setMatrixBlock(A_block, i, j, &pd.A_ij[core_id]);
                }
                vecMulSub(&pd.M_local[core_id], vecSlice(b_block, k), vecSlice(b_block, i));
            }
        }
        g_barrier_step.wait();
    }

    // Final block k = num_blocks - 1: sequential back substitution (core 0).
    if (core_id == 0) {
        var i: usize = num_blocks;
        while (i > 0) {
            i -= 1;
            for (0..B) |r| temp_bi[r] = b_block[i * B + r];
            for (i + 1..num_blocks) |j| {
                getMatrixBlock(A_block, i, j, &pd.A_ij_temp);
                for (0..B) |r| {
                    for (0..B) |c| temp_bi[r] = temp_bi[r] - pd.A_ij_temp[r][c] * x_block[j * B + c];
                }
            }
            getMatrixBlock(A_block, i, i, &pd.A_ii);
            _ = luDecompose(&pd.A_ii, &pd.LU_ii, &pivot_ii);
            luSolve(&pd.LU_ii, &pivot_ii, &temp_bi, vecSlice(x_block, i));
        }
        st(&g_block_end_us, timerUs32());
    }

    g_barrier_lu.wait(); // sync all cores at exit

    if (core_id == 0) {
        // Print the full solution, then set the done flag so osMain can
        // report. Both solver threads return right after (terminated).
        printSolution();
        st(&g_solver_done, true);
    }
    return null;
}

fn printSolution() void {
    g_mutex.lock() catch {};
    uart.write("\n==== BLOCK SOLVER (PSRAM) -> solution x = A^-1 b ====\n");
    for (0..N) |i| {
        writeFmt("x[{d:>3}] = ", .{i});
        printFloat(x_block[i]);
        uart.write("\n");
    }
    uart.write("==== block solve finished ====\n");
    g_mutex.unlock() catch {};
}

/// The core-1 NVIC set-up of the C++ test's idle1 thread (see the header).
fn nvic1Func(_: ?*anyopaque) ?*anyopaque {
    if (uos.port.scheduler.cpuId() != 1) this_thread.yield();

    // 1. TIMER0 alarm 2 (IRQ 2), priority 8 (high).
    nvicPriority(TIMER0_IRQ_2, 8);
    arch.nvicEnable(TIMER0_IRQ_2);
    // 2. TIMER0 alarm 3 (IRQ 3), priority 10 (medium-high).
    nvicPriority(TIMER0_IRQ_3, 10);
    arch.nvicEnable(TIMER0_IRQ_3);
    // 3. UART0 (IRQ 33), priority 12 (lower than alarms 2/3).
    nvicPriority(UART0_IRQ, 12);
    arch.nvicEnable(UART0_IRQ);

    while (true) {
        asm volatile ("dsb" ::: .{ .memory = true });
        asm volatile ("wfi");
        this_thread.yield();
    }
    return null;
}

// ---- ISRs ------------------------------------------------------------------------

/// UART0 interrupt handler (priority 12, medium).
fn uart0IrqHandler() linksection(".ram_text") callconv(.c) void {
    const entry_time = timerUs32();
    reg(UART0_BASE + 0x44).* = 0x7FF; // clear the UART interrupt status
    logTraceAt("UART_Start", entry_time);
    st(&g_irq_uart, ld(&g_irq_uart) + 1);

    // Busy loop for ~2 ms (at 150 MHz) so the alarms preempt it.
    var count: u32 = 0;
    var j: u32 = 0;
    while (j < 55000) : (j += 1) {
        @as(*volatile u32, &count).* += 1;
        asm volatile ("" ::: .{ .memory = true });
    }

    logTrace("UART_End");
}

/// TIMER0 alarm 2 handler (priority 8, the highest): every 1.25 s.
fn timer0Irq2Handler() linksection(".ram_text") callconv(.c) void {
    const entry_time = timerUs32();
    reg(TIMER0_BASE + 0x3C).* = 1 << 2; // clear the alarm 2 interrupt
    alarm2Arm(1_250_000);
    logTraceAt("T2_Alarm", entry_time);
    st(&g_irq_t2, ld(&g_irq_t2) + 1);
}

/// TIMER0 alarm 3 handler (priority 10, medium-high): every 1.2495 s.
fn timer0Irq3Handler() linksection(".ram_text") callconv(.c) void {
    const entry_time = timerUs32();
    reg(TIMER0_BASE + 0x3C).* = 1 << 3; // clear the alarm 3 interrupt
    alarm3Arm(1_249_500);
    logTraceAt("T3_Alarm", entry_time);
    st(&g_irq_t3, ld(&g_irq_t3) + 1);
}

// ---- Entry point -------------------------------------------------------------------

var workers: [2]rtos.Thread = undefined;
var led_th: rtos.Thread = undefined;
var trigger_th: rtos.Thread = undefined;
var trace_th: rtos.Thread = undefined;
var pot_th: rtos.Thread = undefined;
var nvic1_th: rtos.Thread = undefined;
const worker_names = [2][:0]const u8{ "wrk0", "wrk1" };

fn osMain() u8 {
    // Pin the main thread to core 0 during start-up.
    this_thread.thread().setCpuAffinity(1 << 0);

    board.led.init();
    timerInit();

    // Potentiometer ADC (GPIO40/ADC0): clk_adc from PLL_USB, then the ADC.
    rp_clocks.adcClkInit();
    adc.init();
    adc.gpioInit(adc.pot_pin);

    {
        const mhz = clocks.currentKhz() / 1000;
        const mv = rp_clocks.vselToMv(clocks.currentVsel());
        var buf: [256]u8 = undefined;
        uart.write(std.fmt.bufPrint(&buf, "\n" ++
            "=============================================\n" ++
            "  Pico 2 / RP2350B - micro-os-plus-iii_____________\n" ++
            "  smp-test-nested-clock : pot -> clock -> SMP nested test\n" ++
            "  solve linear system by blocks (PSRAM)\n" ++
            "  clock = {d} MHz  (VREG {d}.{d:0>2} V, table idx {d})\n" ++
            "=============================================\n", .{ mhz, mv / 1000, (mv % 1000) / 10, clocks.currentIndex() }) catch "");
    }
    if (!psram_ok) uart.write("PSRAM init failed\n");

    // ---- Gate: show the clock + the live GPIO40 tension until 'y' --------------
    // ...UNLESS we just rebooted from a pot clock-selection 'y' (WATCHDOG
    // SCRATCH2 = the autostart magic): choosing the clock already confirmed
    // the run. ESC and a cold boot leave the flag clear -> gate.
    const autostart = reg(WATCHDOG_SCRATCH2).* == AUTOSTART_MAGIC;
    reg(WATCHDOG_SCRATCH2).* = 0; // consume the flag either way
    if (!autostart) {
        uart.write("\npress 'y' to start the RTOS / SMP nested test at this clock.\n");
        _ = pollKey(); // drain stale input
        const now_mhz = clocks.currentKhz() / 1000;
        while (true) {
            const raw = adc.read(adc.pot_channel);
            const mv = (@as(u32, raw) * 3300) / 4096;
            var band = (@as(u32, raw) * clocks.sys_table_len) / 4096;
            if (band >= clocks.sys_table_len) band = clocks.sys_table_len - 1;
            writeFmt("\rGPIO40 = {d}.{d:0>3} V (adc {d:>4}) | now {d} MHz | pot->{d} MHz  press 'y'... ", .{
                mv / 1000, mv % 1000, raw, now_mhz, clocks.sys_table[band].khz / 1000,
            });

            const c = pollKey();
            if (c == 'y') {
                // A pot on a DIFFERENT band than the running clock: a single 'y'
                // selects AND runs it (reboot with the autostart flag).
                if (band != clocks.currentIndex()) {
                    uart.write("\nstarting at selected clock...\n");
                    reg(WATCHDOG_SCRATCH2).* = AUTOSTART_MAGIC;
                    sysclock.sleepFor(20) catch {};
                    clocks.rebootToIndex(band); // never returns
                }
                break; // the pot matches the current clock -> start here
            }
            sysclock.sleepFor(300) catch {};
        }
    }
    uart.write("\nstarting...\n");

    // The core-1 NVIC set-up (C++: the test's idle1 thread).
    nvic1_th.init("nvic1", nvic1Func, null, .{ .stack = &nvic1_stack, .priority = rtos.priority.idle, .cpu_affinity = 1 << 1 }, null) catch
        @panic("cannot create nvic1");

    // Worker threads with the default (any core) affinity: no pinning.
    for (&workers, &worker_stacks, &worker_ctx, 0..) |*th, *stack, *c, i| {
        c.* = .{ .id = @intCast(i), .local = 0 };
        th.init(worker_names[i], worker, c, .{ .stack = stack }, null) catch @panic("cannot create a worker");
    }
    led_th.init("led", ledThread, null, .{ .stack = &led_stack }, null) catch @panic("cannot create led");
    trigger_th.init("trigger", triggerThread, null, .{ .stack = &trigger_stack }, null) catch @panic("cannot create trigger");
    trace_th.init("trace", tracePrinterThread, null, .{ .stack = &trace_stack }, null) catch @panic("cannot create trace");
    // The potentiometer poller (any core): reboots into the selected clock.
    pot_th.init("pot", potThread, null, .{ .stack = &pot_stack }, null) catch @panic("cannot create pot");

    // ---- NVIC configuration for the nesting demo (core 0) -----------------
    nvicPriority(TIMER0_IRQ_2, 8);
    alarm2Arm(1_250_000); // in 1.25 s
    reg(TIMER0_BASE + 0x40).* |= 1 << 2; // enable alarm 2 in the timer's INTE
    arch.nvicEnable(TIMER0_IRQ_2);

    nvicPriority(TIMER0_IRQ_3, 10);
    alarm3Arm(1_249_500); // in 1.2495 s
    reg(TIMER0_BASE + 0x40).* |= 1 << 3; // enable alarm 3 in the timer's INTE
    arch.nvicEnable(TIMER0_IRQ_3);

    nvicPriority(UART0_IRQ, 12);
    arch.nvicEnable(UART0_IRQ);

    uart.write("core 0: launching core 1 (bootrom FIFO handshake)...\n");
    uos.port.launchCore1();
    uart.write("core 0: core 1 launched; SMP running without worker affinity.\n");

    // ---- Block linear solver (PSRAM) --------------------------------------
    g_barrier_lu.init(ncpu, 2); // SIO spinlock slot 2
    g_barrier_step.init(ncpu, 3); // SIO spinlock slot 3
    st(&g_solver_done, false);

    {
        const a_addr = @intFromPtr(&A[0][0]);
        writeFmt("matrix A @ 0x{x:0>8} [{s}] (N = {d}, B = {d}, cores = {d})\n", .{
            a_addr, if (a_addr >= 0x1100_0000 and a_addr < 0x1180_0000) "PSRAM" else "SRAM", N, B, ncpu,
        });
    }

    uart.write("Generating diagonally dominant matrix in PSRAM...\n");
    var rng = NewlibRand.init(42);
    for (0..N) |r| {
        for (0..N) |c| {
            A[r][c] = -5.0 + @as(f32, @floatFromInt(rng.rand())) / (@as(f32, @floatFromInt(NewlibRand.rand_max)) / 10.0);
        }
    }
    for (0..N) |r| {
        var sum: f32 = 0.0;
        for (0..N) |c| {
            if (r != c) sum = sum + @abs(A[r][c]);
        }
        A[r][r] = sum + 5.0; // strictly diagonally dominant
        b[r] = 1.0;
    }
    for (0..N) |r| {
        for (0..N) |c| A_block[r][c] = A[r][c];
        b_block[r] = b[r];
    }

    // ---- Launch the parallel solver threads (pinned to cores 0 and 1) --------
    uart.write("Starting parallel 2-core block elimination...\n");
    for (&solver_threads, &solver_stacks, 0..) |*th, *stack, c| {
        th.init(solver_thread_names[c], solverThreadFunc, &core_ids[c], .{ .stack = stack }, null) catch @panic("cannot create a solver");
        th.setCpuAffinity(@as(u32, 1) << @intCast(c));
    }

    while (!ld(&g_solver_done)) sysclock.sleepFor(100) catch {};
    writeFmt("Block elimination finished in {d} us; solver threads destroyed.\n", .{ld(&g_block_end_us) -% ld(&g_block_start_us)});

    // Bounded run: after 'y', each worker does k_iters beats (~k_iters * 1 s),
    // then the verdict.
    const k_iters = 10;
    var i: u32 = 0;
    while (i < 600 and (ld(&worker_ctx[0].local) < k_iters or ld(&worker_ctx[1].local) < k_iters)) : (i += 1) {
        sysclock.sleepFor(100) catch {};
    }

    const ok = ld(&worker_ctx[0].local) >= k_iters and ld(&worker_ctx[1].local) >= k_iters and
        ld(&g_irq_uart) > 0 and ld(&g_irq_t2) > 0 and ld(&g_irq_t3) > 0;
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\nRESULT: {s}  (wrk0={d} wrk1={d} uart={d} t2={d} t3={d})\n", .{
        if (ok) "PASS" else "FAIL", ld(&worker_ctx[0].local), ld(&worker_ctx[1].local),
        ld(&g_irq_uart),                    ld(&g_irq_t2),             ld(&g_irq_t3),
    }) catch "\nRESULT: ?\n";
    g_mutex.lock() catch {};
    uart.write(s);
    g_mutex.unlock() catch {};

    // STOP THE WHOLE CHIP before the verdict: hold the other core in reset
    // (PSM FRCE_OFF; PROC0 = bit 23, PROC1 = bit 24), as in C++, or it would
    // run on after the semihosting exit halts this one.
    sysclock.sleepFor(20) catch {};
    asm volatile ("cpsid i" ::: .{ .memory = true });
    {
        const self = reg(SIO_CPUID).* & 1;
        reg(PSM_BASE + 0x04).* |= if (self != 0) @as(u32, 1 << 23) else @as(u32, 1 << 24);
    }

    // As hw_result::ok() / fail(): the verdict on semihosting (what the
    // runner reads), then the end of the run (exit()).
    semihosting.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
    return if (ok) 0 else 1;
}
