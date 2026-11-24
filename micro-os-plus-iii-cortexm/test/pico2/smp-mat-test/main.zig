//! smp-mat-test (Pico 2 / RP2350) -- parallel block linear equation solver.
//!
//! The Zig port of test/pico2/smp-mat-test/main.cpp, line for line
//! (N = 120, B = 30, 2 cores). Solves A x = b (N x N, diagonally dominant):
//!   1. a Thread-Pool demo (10 workers, 20 tasks) proving cross-core task
//!      distribution through a semaphore+mutex pool;
//!   2. a PARALLEL BLOCK elimination (the real test): block Gaussian
//!      elimination with block size B, row blocks distributed across the two
//!      cores, synchronised by generation-based spin barriers on SIO hardware
//!      spinlocks (slots 2/3; 0 = kernel), with core 0 doing the diagonal LU
//!      and the back substitution;
//!   3. a CLASSICAL N x N LU solve on core 0, as ground truth.
//! Then it compares the two solutions (max/sum absolute difference), times
//! both, and prints the speedup.
//!
//! The matrix comes from the same newlib rand() sequence (srand(42)) as the
//! C++ test, so both solve the same system.
//!
//! Output on UART0 @115200; the LED blinks while the solver runs. The
//! performance lines and the verdict are also written to semihosting.

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const hal = microzig.hal;
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const uart = board.uart;
const semihosting = uos.port.semihosting;
const ncpu = 2;

pub const microzig_options = uos.port.microzig_options;

pub const uos_options: uos.Options = .{
    .ncpu = ncpu,
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

comptime {
    microzig.export_startup();
}

pub fn main() void {
    rtos.run(osMain);
}

fn timerUs32() u32 {
    return @truncate(hal.time.get_time_since_boot().to_us());
}

fn ld(p: anytype) @TypeOf(p.*) {
    return @atomicLoad(@TypeOf(p.*), p, .acquire);
}

fn st(p: anytype, v: @TypeOf(p.*)) void {
    @atomicStore(@TypeOf(p.*), p, v, .release);
}

inline fn dmb() void {
    asm volatile ("dmb" ::: .{ .memory = true });
}

// ---- Console helpers ---------------------------------------------------------

fn writeStr(s: []const u8) void {
    uart.write(s);
}

/// To the UART and, for the runner's log, to semihosting.
fn out(s: []const u8) void {
    uart.write(s);
    semihosting.write(s);
}

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [96]u8 = undefined;
    uart.write(std.fmt.bufPrint(&buf, fmt, args) catch buf[0..]);
}

var led_on = false;

fn ledToggle() void {
    led_on = !led_on;
    board.led.set(led_on);
}

/// "%d.%06d", as the C++ print_float().
fn fmtFloat(buf: []u8, value: f32) []const u8 {
    var val = value;
    var neg = false;
    if (val < 0.0) {
        neg = true;
        val = -val;
    }
    var int_part: i32 = @intFromFloat(val);
    var frac_part: i32 = @intFromFloat((val - @as(f32, @floatFromInt(int_part))) * 1000000.0 + 0.5);
    if (frac_part >= 1000000) {
        int_part += 1;
        frac_part -= 1000000;
    }
    return std.fmt.bufPrint(buf, "{s}{d}.{d:0>6}", .{ if (neg) "-" else "", int_part, @as(u32, @intCast(frac_part)) }) catch "";
}

fn printFloat(val: f32) void {
    var buf: [32]u8 = undefined;
    uart.write(fmtFloat(&buf, val));
}

/// "%d.%03d", as the C++ print_time_us() / print_ratio().
fn fmtMilli(buf: []u8, value: f64) []const u8 {
    var int_part: i64 = @intFromFloat(value);
    var frac_part: i64 = @intFromFloat((value - @as(f64, @floatFromInt(int_part))) * 1000.0 + 0.5);
    if (frac_part >= 1000) {
        int_part += 1;
        frac_part -= 1000;
    }
    return std.fmt.bufPrint(buf, "{d}.{d:0>3}", .{ int_part, @as(u64, @intCast(frac_part)) }) catch "";
}

// ---- newlib rand() --------------------------------------------------------------

/// The newlib generator (srand/rand, RAND_MAX = 0x7FFFFFFF), so the matrix is
/// the one the C++ test solves.
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

// ---- Solver dimensions ----------------------------------------------------------

const N = 120;
const B = 30;

// ---- Generation-based spin barrier, SIO-hardware-spinlock protected ------------

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
        // The SIO hardware spinlock is the RP2350 cross-core primitive.
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

// ---- Thread Pool (10 workers, cross-core tasks) ----------------------------------

const TaskFn = *const fn (arg: usize) void;
const Task = struct { func: ?TaskFn = null, arg: usize = 0 };

const POOL_SIZE = 10;
const TASK_QUEUE_SIZE = 32;

const ThreadPool = struct {
    queue: [TASK_QUEUE_SIZE]Task = @splat(.{}),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: rtos.Mutex = .{},
    sem_tasks: rtos.Semaphore = .counting("pool_tasks", TASK_QUEUE_SIZE, 0),
    sem_free: rtos.Semaphore = .counting("pool_free", TASK_QUEUE_SIZE, TASK_QUEUE_SIZE),

    fn start(pool: *ThreadPool) void {
        for (0..POOL_SIZE) |i| {
            _ = std.fmt.bufPrint(&pool_thread_names[i], "pool_{d:0>2}", .{i}) catch {};
            const name: [:0]const u8 = std.mem.sliceTo(&pool_thread_names[i], 0);
            pool_threads[i].init(name, poolWorkerFunc, pool, .{ .stack = &pool_stacks[i] }, null) catch
                @panic("cannot create a pool worker");
            // Alternate workers across the two cores.
            pool_threads[i].setCpuAffinity(@as(u32, 1) << @intCast(i % ncpu));
        }
    }

    fn submit(pool: *ThreadPool, func: TaskFn, arg: usize) bool {
        pool.sem_free.wait() catch {};
        pool.mutex.lock() catch {};
        pool.queue[pool.tail] = .{ .func = func, .arg = arg };
        pool.tail = (pool.tail + 1) % TASK_QUEUE_SIZE;
        pool.count += 1;
        pool.mutex.unlock() catch {};
        pool.sem_tasks.post() catch {};
        return true;
    }

    fn workerLoop(pool: *ThreadPool) noreturn {
        while (true) {
            pool.sem_tasks.wait() catch {};
            pool.mutex.lock() catch {};
            const task = pool.queue[pool.head];
            pool.head = (pool.head + 1) % TASK_QUEUE_SIZE;
            pool.count -= 1;
            pool.mutex.unlock() catch {};
            pool.sem_free.post() catch {};
            if (task.func) |f| f(task.arg);
        }
    }
};

var g_pool: ThreadPool = .{};
var pool_thread_names: [POOL_SIZE][16:0]u8 = @splat(@splat(0));
var pool_stacks: [POOL_SIZE][512]uos.port.StackElement align(8) = undefined;
var pool_threads: [POOL_SIZE]rtos.Thread = undefined;

fn poolWorkerFunc(arg: ?*anyopaque) ?*anyopaque {
    const pool: *ThreadPool = @ptrCast(@alignCast(arg.?));
    pool.workerLoop();
}

var g_pool_task_count: u32 = 0;
var g_pool_print_mutex: rtos.Mutex = .{};

fn poolDemoTask(id: usize) void {
    var sum: u32 = 0;
    for (0..10000) |i| {
        sum +%= @intCast(i);
        std.mem.doNotOptimizeAway(&sum);
    }
    g_pool_print_mutex.lock() catch {};
    writeFmt("Thread Pool: Worker executed task {d} on CPU {d}\n", .{ id, uos.port.scheduler.cpuId() });
    st(&g_pool_task_count, g_pool_task_count + 1);
    g_pool_print_mutex.unlock() catch {};
}

// ---- Solver globals --------------------------------------------------------------

var g_barrier_lu: Barrier = .{};
var g_barrier_step: Barrier = .{};
var g_solver_done: bool = false;
var g_block_start_us: u32 = 0;
var g_block_end_us: u32 = 0;

var A: [N][N]f32 = undefined;
var b: [N]f32 = undefined;
var A_block: [N][N]f32 = undefined;
var b_block: [N]f32 = undefined;
var x_block: [N]f32 = undefined;
var x_classic: [N]f32 = undefined;
var LU_k_T: [B][B]f32 = undefined;
var pivot_k_T: [B]usize = undefined;

var solver_stacks: [ncpu][1024]uos.port.StackElement align(8) = undefined;
var solver_threads: [ncpu]rtos.Thread = undefined;
const solver_thread_names = [ncpu][:0]const u8{ "solver_c0", "solver_c1" };
var core_ids: [ncpu]u32 = .{ 0, 1 };

const Mat = [B][B]f32;

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

// Per-core workspace (static to keep thread stacks tiny). A_kj doubles as the
// A_ik scratch: it is only needed again after solveBlockTranspose.
var workspace_Src_T: [ncpu]Mat = undefined;
var workspace_M_T: [ncpu]Mat = undefined;
var M_local: [ncpu]Mat = undefined;
var A_kj: [ncpu]Mat = undefined;
var A_ij: [ncpu]Mat = undefined;
var A_kk_T: Mat = undefined;
var A_ii: Mat = undefined;
var LU_ii: Mat = undefined;
var A_ij_temp: Mat = undefined;
var pivot_ii: [B]usize = undefined;
var temp_bi: [B]f32 = undefined;

fn solverThreadFunc(arg: ?*anyopaque) ?*anyopaque {
    const core_id: usize = @as(*const u32, @ptrCast(@alignCast(arg.?))).*;
    const num_blocks = N / B;

    if (core_id == 0) st(&g_block_start_us, timerUs32());

    for (0..num_blocks - 1) |k| {
        if (core_id == 0) {
            // Core 0: LU-decompose the diagonal block A_kk (transposed layout).
            for (0..B) |i| {
                for (0..B) |j| A_kk_T[i][j] = A_block[k * B + j][k * B + i];
            }
            _ = luDecompose(&A_kk_T, &LU_k_T, &pivot_k_T);
        }
        g_barrier_lu.wait();

        // All cores: compute multipliers + update their assigned row blocks.
        for (k + 1..num_blocks) |i| {
            if ((i - (k + 1)) % ncpu == core_id) {
                // A_ik = A_block[i][k]
                getMatrixBlock(&A_block, i, k, &A_kj[core_id]);
                solveBlockTranspose(&LU_k_T, &pivot_k_T, &A_kj[core_id], &M_local[core_id], &workspace_Src_T[core_id], &workspace_M_T[core_id]);
                // A_ij = A_ij - M_ik * A_kj  for j > k
                for (k + 1..num_blocks) |j| {
                    getMatrixBlock(&A_block, k, j, &A_kj[core_id]);
                    getMatrixBlock(&A_block, i, j, &A_ij[core_id]);
                    matMulSub(&M_local[core_id], &A_kj[core_id], &A_ij[core_id]);
                    setMatrixBlock(&A_block, i, j, &A_ij[core_id]);
                }
                // b_i = b_i - M_ik * b_k
                vecMulSub(&M_local[core_id], vecSlice(&b_block, k), vecSlice(&b_block, i));
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
                getMatrixBlock(&A_block, i, j, &A_ij_temp);
                for (0..B) |r| {
                    for (0..B) |c| temp_bi[r] = temp_bi[r] - A_ij_temp[r][c] * x_block[j * B + c];
                }
            }
            getMatrixBlock(&A_block, i, i, &A_ii);
            _ = luDecompose(&A_ii, &LU_ii, &pivot_ii);
            luSolve(&LU_ii, &pivot_ii, &temp_bi, vecSlice(&x_block, i));
        }
        st(&g_block_end_us, timerUs32());
        st(&g_solver_done, true);
    }
    g_barrier_lu.wait(); // sync all cores at exit
    while (true) sysclock.sleepFor(10000) catch {};
}

// ---- Classical N x N LU solve (ground truth, core 0) --------------------------------

var classic_LU: [N][N]f32 = undefined;
var classic_pivot: [N]usize = undefined;

fn solveClassical(src_A: *const [N][N]f32, src_b: *const [N]f32, dest_x: *[N]f32) bool {
    const LU = &classic_LU;
    const pivot = &classic_pivot;
    var temp: [N]f32 = undefined;
    for (0..N) |i| {
        for (0..N) |j| LU[i][j] = src_A[i][j];
        pivot[i] = i;
    }
    for (0..N) |i| {
        var max_val: f32 = 0.0;
        var max_row = i;
        for (i..N) |r| {
            const val = @abs(LU[r][i]);
            if (val > max_val) {
                max_val = val;
                max_row = r;
            }
        }
        if (max_val < 1e-9) return false; // singular
        if (max_row != i) {
            std.mem.swap(usize, &pivot[i], &pivot[max_row]);
            for (0..N) |c| std.mem.swap(f32, &LU[i][c], &LU[max_row][c]);
        }
        for (i + 1..N) |r| {
            const factor = LU[r][i] / LU[i][i];
            LU[r][i] = factor;
            for (i + 1..N) |c| LU[r][c] = LU[r][c] - factor * LU[i][c];
        }
    }
    // Forward substitution (L * temp = b_pivoted).
    for (0..N) |i| {
        temp[i] = src_b[pivot[i]];
        for (0..i) |j| temp[i] = temp[i] - LU[i][j] * temp[j];
    }
    // Backward substitution (U * x = temp).
    var i: usize = N;
    while (i > 0) {
        i -= 1;
        dest_x[i] = temp[i];
        for (i + 1..N) |j| dest_x[i] = dest_x[i] - LU[i][j] * dest_x[j];
        dest_x[i] = dest_x[i] / LU[i][i];
    }
    return true;
}

// ---- Main ----------------------------------------------------------------------------

fn osMain() u8 {
    this_thread.thread().setCpuAffinity(1 << 0);

    board.led.init();

    g_barrier_lu.init(ncpu, 2); // SIO spinlock slot 2
    g_barrier_step.init(ncpu, 3); // SIO spinlock slot 3
    st(&g_solver_done, false);

    writeStr("\n");
    writeStr("=============================================\n");
    writeStr("  Pico 2 / RP2350 - micro-os-plus-iii\n");
    writeStr("  smp-mat-test : parallel block linear solver\n");
    writeFmt("  N = {d}, B = {d}, cores = {d}\n", .{ N, B, ncpu });
    writeStr("=============================================\n");

    writeStr("core 0: launching core 1 (bootrom FIFO handshake)...\n");
    uos.port.launchCore1();
    writeStr("core 0: core 1 launched; SMP running.\n");

    // ---- Thread Pool demo --------------------------------------------------
    writeStr("Starting Thread Pool of 10 worker threads...\n");
    g_pool.start();
    writeStr("Submitting 20 tasks to the Thread Pool...\n");
    for (0..20) |i| _ = g_pool.submit(poolDemoTask, i);
    while (ld(&g_pool_task_count) < 20) sysclock.sleepFor(10) catch {};
    writeStr("Thread Pool demo finished. All 20 tasks executed successfully.\n\n");

    // ---- Generate the diagonally dominant system ---------------------------
    const num_blocks = N / B;
    comptime std.debug.assert(N % B == 0);
    comptime std.debug.assert(num_blocks % ncpu == 0);

    writeFmt("Generating diagonally dominant {d} x {d} matrix...\n", .{ N, N });
    var rng: NewlibRand = .init(42);
    for (0..N) |i| {
        for (0..N) |j| {
            A[i][j] = -5.0 + @as(f32, @floatFromInt(rng.rand())) /
                (@as(f32, @floatFromInt(NewlibRand.rand_max)) / 10.0);
        }
    }
    for (0..N) |i| {
        var sum: f32 = 0.0;
        for (0..N) |j| {
            if (i != j) sum = sum + @abs(A[i][j]);
        }
        A[i][i] = sum + 5.0; // strictly diagonally dominant
        b[i] = 1.0;
    }
    A_block = A;
    b_block = b;

    // ---- Launch the parallel solver threads --------------------------------
    writeStr("Starting parallel 2-core block elimination...\n");
    for (0..ncpu) |c| {
        solver_threads[c].init(solver_thread_names[c], solverThreadFunc, &core_ids[c], .{ .stack = &solver_stacks[c] }, null) catch
            @panic("cannot create a solver");
        solver_threads[c].setCpuAffinity(@as(u32, 1) << @intCast(c));
    }

    var led_state = false;
    while (!ld(&g_solver_done)) {
        sysclock.sleepFor(100) catch {};
        led_state = !led_state;
        board.led.set(led_state);
    }
    board.led.set(false);
    writeStr("Block elimination finished.\n");

    // ---- Classical solve (ground truth) ------------------------------------
    writeStr("Solving full system using classical elimination...\n");
    const classic_start = timerUs32();
    _ = solveClassical(&A, &b, &x_classic);
    const classic_end = timerUs32();
    writeStr("Classical elimination finished.\n\n");

    // ---- Performance + comparison ------------------------------------------
    const block_us = ld(&g_block_end_us) -% ld(&g_block_start_us);
    const classic_us = classic_end -% classic_start;
    writeStr("+---------------------------------------------------+\n");
    writeStr("| COMPARING BLOCK ELIMINATION VS CLASSICAL SOLVER  |\n");
    writeStr("+---------------------------------------------------+\n");

    var max_diff: f32 = 0.0;
    var sum_diff: f32 = 0.0;
    for (0..N) |i| {
        const diff = @abs(x_block[i] - x_classic[i]);
        sum_diff = sum_diff + diff;
        if (diff > max_diff) max_diff = diff;
        writeStr("x[");
        writeFmt("{d}", .{i});
        writeStr("] Block = ");
        printFloat(x_block[i]);
        writeStr(" | Classic = ");
        printFloat(x_classic[i]);
        writeStr(" | Abs Diff = ");
        printFloat(diff);
        writeStr("\n");
    }

    var fb: [32]u8 = undefined;
    var lb: [96]u8 = undefined;
    out("-----------------------------------------------------\n");
    out(std.fmt.bufPrint(&lb, "Total Absolute Difference (Sum): {s}\n", .{fmtFloat(&fb, sum_diff)}) catch "");
    out(std.fmt.bufPrint(&lb, "Max Absolute Difference:        {s}\n", .{fmtFloat(&fb, max_diff)}) catch "");
    out("-----------------------------------------------------\n");
    out("Performance Metrics:\n");
    out(std.fmt.bufPrint(&lb, "  Parallel Block Solver: {s} us\n", .{fmtMilli(&fb, @floatFromInt(block_us))}) catch "");
    out(std.fmt.bufPrint(&lb, "  Classical Solver:      {s} us\n", .{fmtMilli(&fb, @floatFromInt(classic_us))}) catch "");
    const ratio: f64 = if (classic_us > 0) @as(f64, @floatFromInt(classic_us)) / @as(f64, @floatFromInt(block_us)) else 0.0;
    out(std.fmt.bufPrint(&lb, "  Speedup Ratio:         {s}x\n", .{fmtMilli(&fb, ratio)}) catch "");
    out("+---------------------------------------------------+\n");

    const pass = max_diff < 0.01;
    out(if (pass) "RESULT: PASS (block == classical within tolerance)\n" else "RESULT: FAIL\n");
    writeStr("---------------------------------------------\n");

    // The verdict and the semihosting exit (hw_result::ok()/fail() in C++).
    uos.rtos.terminate(if (pass) 0 else 1);
}
