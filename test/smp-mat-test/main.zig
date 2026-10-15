//! smp-mat-test -- a parallel block linear solver (the C++
//! test/rpi4b/smp-mat-test, N = 120, B = 20).
//!
//! First a thread pool demo (10 workers spread over the CPUs, 20 tasks);
//! then a diagonally dominant 120 x 120 system is solved by block
//! elimination on every CPU (spin barriers between the steps) and by a
//! classical LU solve on CPU 0; PASS when the two agree within 0.01.
//!
//! Faithful to the numbers too: the matrix comes from rand()/srand(42) as
//! the C++ image's newlib computes them (the same 64-bit LCG, below), and
//! the f32 arithmetic is done in the same order. The microsecond clock is
//! the generic timer, CNTPCT / (CNTFRQ / 1e6), as the board's timer_arm.
//!
//! Differences from C++: the kernel prints its startup banner and creates
//! the secondary idle threads; the affinities are given at creation. The
//! pool and solver stacks are 2048 elements, not 512 and 1024 (Zig's
//! formatting needs more stack than C++'s; the smaller ones overflowed) (not below the port's
//! 2 KiB minimum), as in C++.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const ncpu = uos.config.ncpu;
const led = board.led;

pub const uos_options = board.options(4);

// newlib's rand()/srand() (libc/stdlib/rand.c), the C++ image's.
var rand_next: u64 = 1;

fn srand(seed: c_uint) void {
    rand_next = seed;
}

fn rand() c_int {
    rand_next = rand_next *% 6364136223846793005 +% 1;
    return @intCast((rand_next >> 32) & 0x7FFF_FFFF);
}

const rand_max: f32 = 2147483647.0; // newlib RAND_MAX

fn cpuId() u32 {
    return uos.port.scheduler.cpuId();
}

// ---- Microsecond clock (the board's timer_arm: the generic timer) --------

var g_ticks_per_us: u64 = 19; // set in timerInit() from CNTFRQ

fn timerInit() void {
    const f: u64 = uos.port.arch.cntFrq(); // timer_arm::get_freq()
    g_ticks_per_us = if (f != 0) f / 1_000_000 else 19;
    if (g_ticks_per_us == 0) g_ticks_per_us = 1;
}

fn cntpct() u64 {
    return uos.port.arch.cntPct(); // timer_arm::get_count()
}

fn timerUs32() u32 {
    return @truncate(cntpct() / g_ticks_per_us);
}

// ---- Console helpers -------------------------------------------------------

fn writeStr(s: []const u8) void {
    board.uart.puts(s);
}

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(buf[0..95]);
    w.print(fmt, args) catch {};
    board.uart.puts(w.buffered());
}

fn ledToggle() void {
    const S = struct {
        var on = false;
    };
    S.on = !S.on;
    if (S.on) led.on() else led.off();
}

fn printFloat(value: f32) void {
    var val = value;
    if (val < 0.0) {
        writeStr("-");
        val = -val;
    }
    var int_part: i32 = @intFromFloat(val);
    var frac_part: i32 = @intFromFloat((val - @as(f32, @floatFromInt(int_part))) * 1000000.0 + 0.5);
    if (frac_part >= 1000000) {
        int_part += 1;
        frac_part -= 1000000;
    }
    writeFmt("{d}.{d:0>6}", .{ int_part, @as(u32, @intCast(frac_part)) });
}

fn printTimeUs(time_us: f64) void {
    var int_part: i32 = @intFromFloat(time_us);
    var frac_part: i32 = @intFromFloat((time_us - @as(f64, @floatFromInt(int_part))) * 1000.0 + 0.5);
    if (frac_part >= 1000) {
        int_part += 1;
        frac_part -= 1000;
    }
    writeFmt("{d}.{d:0>3} us", .{ int_part, @as(u32, @intCast(frac_part)) });
}

fn printRatio(ratio: f64) void {
    var int_part: i32 = @intFromFloat(ratio);
    var frac_part: i32 = @intFromFloat((ratio - @as(f64, @floatFromInt(int_part))) * 1000.0 + 0.5);
    if (frac_part >= 1000) {
        int_part += 1;
        frac_part -= 1000;
    }
    writeFmt("{d}.{d:0>3}", .{ int_part, @as(u32, @intCast(frac_part)) });
}

// ---- Solver dimensions -----------------------------------------------------

const N = 120;
const B = 20;

// ---- A generation-based spin barrier ---------------------------------------

const Barrier = struct {
    target_count: i32 = 0,
    current_count: i32 = 0,
    generation: i32 = 0,
    lock: u8 = 0,

    fn init(self: *Barrier, count: i32) void {
        self.* = .{ .target_count = count };
    }

    fn wait(self: *Barrier) void {
        _ = @atomicLoad(i32, &self.generation, .seq_cst); // full fence
        const gen = @atomicLoad(i32, &self.generation, .seq_cst);
        while (@atomicRmw(u8, &self.lock, .Xchg, 1, .acquire) != 0) this_thread.yield();
        self.current_count += 1;
        if (self.current_count == self.target_count) {
            self.current_count = 0;
            @atomicStore(i32, &self.generation, self.generation + 1, .seq_cst);
            @atomicStore(u8, &self.lock, 0, .release);
        } else {
            @atomicStore(u8, &self.lock, 0, .release);
            while (@atomicLoad(i32, &self.generation, .seq_cst) == gen) this_thread.yield();
        }
        _ = @atomicLoad(i32, &self.generation, .seq_cst); // full fence
    }
};

// ---- Thread pool (10 workers, cross-core tasks) -----------------------------

const TaskFn = *const fn (arg: ?*anyopaque) void;
const Task = struct { func: ?TaskFn = null, arg: ?*anyopaque = null };

const pool_size = 10;
const task_queue_size = 32;

const ThreadPool = struct {
    queue: [task_queue_size]Task = @splat(.{}),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: rtos.Mutex = .{},
    sem_tasks: rtos.Semaphore = .counting("pool_tasks", task_queue_size, 0),
    sem_free: rtos.Semaphore = .counting("pool_free", task_queue_size, task_queue_size),

    fn start(self: *ThreadPool) void {
        const gpa = uos.memory.allocator();
        for (0..pool_size) |i| {
            pool_thread_names[i] = "pool_00".*;
            pool_thread_names[i][5] = '0' + @as(u8, @intCast(i / 10));
            pool_thread_names[i][6] = '0' + @as(u8, @intCast(i % 10));
            // Alternate the workers across the CPUs.
            pool_threads[i] = rtos.Thread.create(gpa, &pool_thread_names[i], poolWorkerFunc, self, .{
                .stack = &pool_stacks[i],
                .cpu_affinity = @as(u32, 1) << @intCast(i % ncpu),
            }) catch unreachable;
        }
    }

    fn submit(self: *ThreadPool, func: TaskFn, arg: ?*anyopaque) bool {
        self.sem_free.wait() catch {};
        self.mutex.lock() catch {};
        self.queue[self.tail] = .{ .func = func, .arg = arg };
        self.tail = (self.tail + 1) % task_queue_size;
        self.count += 1;
        self.mutex.unlock() catch {};
        self.sem_tasks.post() catch {};
        return true;
    }

    fn workerLoop(self: *ThreadPool) noreturn {
        while (true) {
            self.sem_tasks.wait() catch {};
            self.mutex.lock() catch {};
            const task = self.queue[self.head];
            self.head = (self.head + 1) % task_queue_size;
            self.count -= 1;
            self.mutex.unlock() catch {};
            self.sem_free.post() catch {};
            if (task.func) |f| f(task.arg);
        }
    }
};

var g_pool: ThreadPool = .{};
var pool_thread_names: [pool_size][7:0]u8 = undefined;
// C++: 512 and 1024 elements. Zig's std.fmt in safe mode needs far more
// stack than C++'s vsnprintf() (a pool worker overflowed 512 x 8 bytes into
// main's stack on the board), so 2048 elements (16 KiB) each here.
var pool_stacks: [pool_size][2048]uos.port.StackElement = undefined;
var pool_threads: [pool_size]*rtos.Thread = undefined;

fn poolWorkerFunc(arg: ?*anyopaque) ?*anyopaque {
    const pool: *ThreadPool = @ptrCast(@alignCast(arg.?));
    pool.workerLoop();
}

var g_pool_task_count: i32 = 0;
var g_pool_print_mutex: rtos.Mutex = .{};

fn poolDemoTask(arg: ?*anyopaque) void {
    const id: usize = @intFromPtr(arg);
    var sum: i32 = 0;
    var i: i32 = 0;
    while (i < 10000) : (i += 1) @as(*volatile i32, &sum).* = @as(*volatile i32, &sum).* +% i;
    g_pool_print_mutex.lock() catch {};
    writeFmt("Thread Pool: Worker executed task {d} on CPU {d}\n", .{ id, cpuId() });
    @as(*volatile i32, &g_pool_task_count).* += 1;
    g_pool_print_mutex.unlock() catch {};
}

// ---- Solver globals --------------------------------------------------------

var g_barrier_lu: Barrier = .{};
var g_barrier_step: Barrier = .{};
var g_solver_done = std.atomic.Value(bool).init(false);
var g_block_start_us: u32 = 0;
var g_block_end_us: u32 = 0;

const Block = [B][B]f32;

var A: [N][N]f32 = undefined;
var b: [N]f32 = undefined;
var A_block: [N][N]f32 = undefined;
var b_block: [N]f32 = undefined;
var x_block: [N]f32 = undefined;
var x_classic: [N]f32 = undefined;
var LU_k_T: Block = undefined;
var pivot_k_T: [B]usize = undefined;

var solver_stacks: [ncpu][2048]uos.port.StackElement = undefined;
var solver_threads: [ncpu]*rtos.Thread = undefined;
var solver_thread_names: [ncpu][9:0]u8 = undefined;

// ---- LU utilities for B x B blocks -----------------------------------------

fn luDecompose(M: *const Block, LU: *Block, pivot: *[B]usize) bool {
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
            for (0..B) |col| std.mem.swap(f32, &LU[i][col], &LU[max_row][col]);
        }
        for (i + 1..B) |r| {
            const factor = LU[r][i] / LU[i][i];
            LU[r][i] = factor;
            for (i + 1..B) |col| LU[r][col] = LU[r][col] - factor * LU[i][col];
        }
    }
    return true;
}

fn luSolve(LU: *const Block, pivot: *const [B]usize, Y: *const [B]f32, X: *[B]f32) void {
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
fn solveBlockTranspose(LU_T: *const Block, pivot_T: *const [B]usize, Src: *const Block, Dest: *Block, Src_T: *Block, M_T: *Block) void {
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

fn matMulSub(M: *const Block, X: *const Block, Dest: *Block) void {
    for (0..B) |i| {
        for (0..B) |j| {
            var sum: f32 = 0.0;
            for (0..B) |k| sum = sum + M[i][k] * X[k][j];
            Dest[i][j] = Dest[i][j] - sum;
        }
    }
}

fn vecMulSub(M: *const Block, v: []const f32, Dest: []f32) void {
    for (0..B) |i| {
        var sum: f32 = 0.0;
        for (0..B) |k| sum = sum + M[i][k] * v[k];
        Dest[i] = Dest[i] - sum;
    }
}

fn getMatrixBlock(Src: *const [N][N]f32, br: usize, bc: usize, Dest: *Block) void {
    for (0..B) |i| {
        for (0..B) |j| Dest[i][j] = Src[br * B + i][bc * B + j];
    }
}

fn setMatrixBlock(Dest: *[N][N]f32, br: usize, bc: usize, Src: *const Block) void {
    for (0..B) |i| {
        for (0..B) |j| Dest[br * B + i][bc * B + j] = Src[i][j];
    }
}

// ---- Per-core solver worker (block parallel elimination) -------------------

// Per-core workspace (static, to keep the thread stacks small).
var workspace_Src_T: [ncpu]Block = undefined;
var workspace_M_T: [ncpu]Block = undefined;
var M_local: [ncpu]Block = undefined;
var A_kj: [ncpu]Block = undefined;
var A_ij: [ncpu]Block = undefined;
var A_kk_T: Block = undefined;
var A_ii: Block = undefined;
var LU_ii: Block = undefined;
var A_ij_temp: Block = undefined;
var pivot_ii: [B]usize = undefined;
var temp_bi: [B]f32 = undefined;

fn solverThreadFunc(arg: ?*anyopaque) ?*anyopaque {
    const core_id: usize = @intFromPtr(arg);
    const num_blocks = N / B;

    if (core_id == 0) @atomicStore(u32, &g_block_start_us, timerUs32(), .monotonic);

    var k: usize = 0;
    while (k < num_blocks - 1) : (k += 1) {
        if (core_id == 0) {
            // CPU 0: LU-decompose the diagonal block A_kk (transposed).
            for (0..B) |i| {
                for (0..B) |j| A_kk_T[i][j] = A_block[k * B + j][k * B + i];
            }
            _ = luDecompose(&A_kk_T, &LU_k_T, &pivot_k_T);
        }
        g_barrier_lu.wait();
        // Every CPU: the multipliers, and the update of its row blocks.
        for (k + 1..num_blocks) |i| {
            if ((i - (k + 1)) % ncpu == core_id) {
                getMatrixBlock(&A_block, i, k, &A_kj[core_id]);
                solveBlockTranspose(&LU_k_T, &pivot_k_T, &A_kj[core_id], &M_local[core_id], &workspace_Src_T[core_id], &workspace_M_T[core_id]);
                // A_ij = A_ij - M_ik * A_kj, for j > k
                for (k + 1..num_blocks) |j| {
                    getMatrixBlock(&A_block, k, j, &A_kj[core_id]);
                    getMatrixBlock(&A_block, i, j, &A_ij[core_id]);
                    matMulSub(&M_local[core_id], &A_kj[core_id], &A_ij[core_id]);
                    setMatrixBlock(&A_block, i, j, &A_ij[core_id]);
                }
                // b_i = b_i - M_ik * b_k
                vecMulSub(&M_local[core_id], b_block[k * B ..][0..B], b_block[i * B ..][0..B]);
            }
        }
        g_barrier_step.wait();
    }

    // The last block: sequential back substitution (CPU 0).
    if (core_id == 0) {
        var i: usize = num_blocks;
        while (i > 0) {
            i -= 1;
            for (0..B) |r| temp_bi[r] = b_block[i * B + r];
            for (i + 1..num_blocks) |j| {
                getMatrixBlock(&A_block, i, j, &A_ij_temp);
                for (0..B) |r| {
                    for (0..B) |col| temp_bi[r] = temp_bi[r] - A_ij_temp[r][col] * x_block[j * B + col];
                }
            }
            getMatrixBlock(&A_block, i, i, &A_ii);
            _ = luDecompose(&A_ii, &LU_ii, &pivot_ii);
            luSolve(&LU_ii, &pivot_ii, &temp_bi, x_block[i * B ..][0..B]);
        }
        @atomicStore(u32, &g_block_end_us, timerUs32(), .monotonic);
        g_solver_done.store(true, .release);
    }
    g_barrier_lu.wait(); // all CPUs meet at the end
    while (true) sysclock.sleepFor(10000) catch {};
}

// ---- Classical N x N LU solve (the ground truth, CPU 0) ---------------------

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
            for (0..N) |col| std.mem.swap(f32, &LU[i][col], &LU[max_row][col]);
        }
        for (i + 1..N) |r| {
            const factor = LU[r][i] / LU[i][i];
            LU[r][i] = factor;
            for (i + 1..N) |col| LU[r][col] = LU[r][col] - factor * LU[i][col];
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

// ---- Main ------------------------------------------------------------------

pub fn main() void {
    board.uart.init();
    led.init();
    timerInit();
    rtos.run(osMain);
}

fn osMain() void {
    this_thread.thread().setCpuAffinity(1 << 0);
    led.init();
    timerInit();
    g_barrier_lu.init(ncpu);
    g_barrier_step.init(ncpu);
    g_solver_done.store(false, .monotonic);

    writeStr("\n");
    writeStr("=============================================\n");
    writeStr("  " ++ board.banner_long ++ " - " ++ board.banner_cpu ++ "\n");
    writeStr("  micro-os-plus-iii  smp-mat-test (all in RAM)\n");
    writeStr("  parallel block linear solver\n");
    writeFmt("  N = {d}, B = {d}, cores = {d}\n", .{ N, B, ncpu });
    writeStr("=============================================\n");

    writeFmt("core 0: releasing cores 1..{d}...\n", .{ncpu - 1});
    board.smp.startSecondaryCores();
    {
        const waited = board.smp.waitSecondaries(3000);
        writeFmt("core 0: SMP up ({s}, {d} ms).\n", .{ board.smp.joinSummary(), waited });
    }

    // ---- The thread pool demo.
    writeStr("Starting Thread Pool of 10 worker threads...\n");
    g_pool.start();
    writeStr("Submitting 20 tasks to the Thread Pool...\n");
    for (0..20) |i| _ = g_pool.submit(poolDemoTask, @ptrFromInt(i));
    while (@as(*volatile i32, &g_pool_task_count).* < 20) sysclock.sleepFor(10) catch {};
    writeStr("Thread Pool demo finished. All 20 tasks executed successfully.\n\n");

    // ---- The diagonally dominant system.
    const num_blocks = N / B;
    if (num_blocks % ncpu != 0) {
        writeFmt("NOTE: {d} blocks over {d} cores (uneven round-robin split).\n", .{ num_blocks, ncpu });
    }
    writeFmt("Generating diagonally dominant {d} x {d} matrix...\n", .{ N, N });
    srand(42);
    for (0..N) |i| {
        for (0..N) |j| A[i][j] = -5.0 + @as(f32, @floatFromInt(rand())) / (rand_max / 10.0);
    }
    for (0..N) |i| {
        var sum: f32 = 0.0;
        for (0..N) |j| {
            if (i != j) sum = sum + @abs(A[i][j]);
        }
        A[i][i] = sum + 5.0; // strictly diagonally dominant
        b[i] = 1.0;
    }
    for (0..N) |i| {
        for (0..N) |j| A_block[i][j] = A[i][j];
        b_block[i] = b[i];
    }

    // ---- The parallel solver threads.
    writeFmt("Starting parallel {d} -core block elimination...\n", .{ncpu});
    const gpa = uos.memory.allocator();
    for (0..ncpu) |c| {
        solver_thread_names[c] = "solver_c0".*;
        solver_thread_names[c][8] = '0' + @as(u8, @intCast(c));
        solver_threads[c] = rtos.Thread.create(gpa, &solver_thread_names[c], solverThreadFunc, @ptrFromInt(c), .{
            .stack = &solver_stacks[c],
            .cpu_affinity = @as(u32, 1) << @intCast(c),
        }) catch unreachable;
    }
    var led_state = false;
    while (!g_solver_done.load(.acquire)) {
        sysclock.sleepFor(100) catch {};
        led_state = !led_state;
        if (led_state) led.on() else led.off();
    }
    led.off();
    writeStr("Block elimination finished.\n");

    // ---- The classical solve.
    writeStr("Solving full system using classical elimination...\n");
    const classic_start = timerUs32();
    _ = solveClassical(&A, &b, &x_classic);
    const classic_end = timerUs32();
    writeStr("Classical elimination finished.\n\n");

    // ---- Performance and comparison.
    const block_us = @atomicLoad(u32, &g_block_end_us, .monotonic) -% @atomicLoad(u32, &g_block_start_us, .monotonic);
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
    writeStr("-----------------------------------------------------\n");
    writeStr("Total Absolute Difference (Sum): ");
    printFloat(sum_diff);
    writeStr("\n");
    writeStr("Max Absolute Difference:        ");
    printFloat(max_diff);
    writeStr("\n");
    writeStr("-----------------------------------------------------\n");
    writeStr("Performance Metrics:\n");
    writeStr("  Parallel Block Solver: ");
    printTimeUs(@floatFromInt(block_us));
    writeStr("\n");
    writeStr("  Classical Solver:      ");
    printTimeUs(@floatFromInt(classic_us));
    writeStr("\n");
    writeStr("  Speedup Ratio:         ");
    printRatio(if (classic_us > 0) @as(f64, @floatFromInt(classic_us)) / @as(f64, @floatFromInt(block_us)) else 0.0);
    writeStr("x\n");
    writeStr("+---------------------------------------------------+\n");
    const pass = max_diff < 0.01;
    writeFmt("RESULT: {s}\n", .{if (pass) "PASS (block == classical within tolerance)" else "FAIL"});
    writeStr("---------------------------------------------\n");
    if (pass) board.hw_result.ok() else board.hw_result.fail();
}
