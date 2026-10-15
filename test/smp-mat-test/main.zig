//! smp-mat-test -- Parallel block linear equation solver across 4 Cortex-A72 cores (Raspberry Pi 4 B).
//! N = 200, B = 50, 4 cores. Everything runs in RAM.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const uart = board.uart;

pub const uos_options = board.options(4);

pub const N: usize = 200;
pub const B: usize = 50;
pub const OS_NCPU: usize = 4;

// ----------------------------------------------------------------------------
// Microsecond Clock
// ----------------------------------------------------------------------------

inline fn timerUs32() u32 {
    const f = uos.port.arch.cntFrq();
    const freq = if (f > 0) f else 54_000_000;
    return @truncate(uos.port.arch.cntPct() * 1_000_000 / freq);
}

// ----------------------------------------------------------------------------
// Generation-based Spin Barrier
// ----------------------------------------------------------------------------

const Barrier = struct {
    target_count: u32 = 0,
    current_count: u32 = 0,
    generation: u32 = 0,
    lock_: u8 = 0,

    pub fn init(self: *Barrier, count: u32) void {
        self.target_count = count;
        self.current_count = 0;
        self.generation = 0;
        self.lock_ = 0;
    }

    pub fn wait(self: *Barrier) void {
        asm volatile ("dmb ish" ::: .{ .memory = true });
        const gen = @atomicLoad(u32, &self.generation, .monotonic);

        while (@atomicRmw(u8, &self.lock_, .Xchg, 1, .acquire) != 0) {
            rtos.this_thread.yield();
        }

        self.current_count += 1;
        if (self.current_count == self.target_count) {
            self.current_count = 0;
            _ = @atomicRmw(u32, &self.generation, .Add, 1, .monotonic);
            @atomicStore(u8, &self.lock_, 0, .release);
        } else {
            @atomicStore(u8, &self.lock_, 0, .release);
            while (@atomicLoad(u32, &self.generation, .monotonic) == gen) {
                rtos.this_thread.yield();
            }
        }

        asm volatile ("dmb ish" ::: .{ .memory = true });
    }
};

// ----------------------------------------------------------------------------
// Thread Pool (10 workers, 20 cross-core tasks)
// ----------------------------------------------------------------------------

const Task = struct {
    func: ?*const fn (?*anyopaque) void = null,
    arg: ?*anyopaque = null,
};

const POOL_SIZE = 10;
const TASK_QUEUE_SIZE = 32;

const ThreadPool = struct {
    queue: [TASK_QUEUE_SIZE]Task = @splat(.{}),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: rtos.Mutex = .{ .name = "pool" },
    sem_tasks: rtos.Semaphore = .counting("tasks", TASK_QUEUE_SIZE, 0),
    sem_free: rtos.Semaphore = .counting("free", TASK_QUEUE_SIZE, TASK_QUEUE_SIZE),
    workers: [POOL_SIZE]rtos.ThreadInclusive(4096) = undefined,

    pub fn start(self: *ThreadPool) void {
        const names = [_][:0]const u8{
            "pool_00", "pool_01", "pool_02", "pool_03", "pool_04",
            "pool_05", "pool_06", "pool_07", "pool_08", "pool_09",
        };
        for (&self.workers, 0..) |*w, i| {
            const aff: u32 = @as(u32, 1) << @intCast(i % OS_NCPU);
            w.init(names[i], workerFunc, self, .{ .cpu_affinity = aff }) catch unreachable;
        }
    }

    pub fn submit(self: *ThreadPool, func: *const fn (?*anyopaque) void, arg: ?*anyopaque) void {
        self.sem_free.wait() catch return;
        self.mutex.lock() catch return;
        self.queue[self.tail] = .{ .func = func, .arg = arg };
        self.tail = (self.tail + 1) % TASK_QUEUE_SIZE;
        self.count += 1;
        self.mutex.unlock() catch {};
        self.sem_tasks.post() catch {};
    }

    fn workerFunc(arg: ?*anyopaque) ?*anyopaque {
        const self: *ThreadPool = @ptrCast(@alignCast(arg.?));
        while (true) {
            self.sem_tasks.wait() catch break;
            self.mutex.lock() catch break;
            const task = self.queue[self.head];
            self.head = (self.head + 1) % TASK_QUEUE_SIZE;
            self.count -= 1;
            self.mutex.unlock() catch {};
            self.sem_free.post() catch {};

            if (task.func) |f| {
                f(task.arg);
            }
        }
        return null;
    }
};

var g_pool: ThreadPool = .{};
var g_pool_task_count: u32 = 0;
var g_pool_print_mutex: rtos.Mutex = .{ .name = "pmtx" };

fn poolDemoTask(arg: ?*anyopaque) void {
    const id: usize = @intFromPtr(arg);
    var sum: usize = 0;
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        sum += i;
        std.mem.doNotOptimizeAway(&sum);
    }
    g_pool_print_mutex.lock() catch {};
    uart.print("Thread Pool: Worker executed task {d} on CPU {d}\n", .{ id, uos.port.scheduler.cpuId() });
    g_pool_task_count += 1;
    g_pool_print_mutex.unlock() catch {};
}

// ----------------------------------------------------------------------------
// Solver Globals
// ----------------------------------------------------------------------------

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

var workspace_Src_T: [OS_NCPU][B][B]f32 = undefined;
var workspace_M_T: [OS_NCPU][B][B]f32 = undefined;
var M_local: [OS_NCPU][B][B]f32 = undefined;
var A_kj: [OS_NCPU][B][B]f32 = undefined;
var A_ij: [OS_NCPU][B][B]f32 = undefined;

var A_kk_T: [B][B]f32 = undefined;
var A_ii: [B][B]f32 = undefined;
var LU_ii: [B][B]f32 = undefined;
var A_ij_temp: [B][B]f32 = undefined;
var pivot_ii: [B]usize = undefined;
var temp_bi: [B]f32 = undefined;

var solver_threads: [OS_NCPU]rtos.ThreadInclusive(16384) = undefined;

// ----------------------------------------------------------------------------
// B x B LU Utilities
// ----------------------------------------------------------------------------

fn luDecompose(M: *const [B][B]f32, LU: *[B][B]f32, pivot: *[B]usize) bool {
    for (0..B) |i| {
        for (0..B) |j| {
            LU[i][j] = M[i][j];
        }
        pivot[i] = i;
    }
    for (0..B) |i| {
        var max_val: f32 = 0;
        var max_row: usize = i;
        for (i..B) |r| {
            const val = @abs(LU[r][i]);
            if (val > max_val) {
                max_val = val;
                max_row = r;
            }
        }
        if (max_val < 1e-9) return false;
        if (max_row != i) {
            std.mem.swap(usize, &pivot[i], &pivot[max_row]);
            for (0..B) |c| {
                std.mem.swap(f32, &LU[i][c], &LU[max_row][c]);
            }
        }
        for (i + 1..B) |r| {
            const factor = LU[r][i] / LU[i][i];
            LU[r][i] = factor;
            for (i + 1..B) |c| {
                LU[r][c] -= factor * LU[i][c];
            }
        }
    }
    return true;
}

fn luSolve(LU: *const [B][B]f32, pivot: *const [B]usize, Y: *const [B]f32, X: *[B]f32) void {
    var temp: [B]f32 = undefined;
    for (0..B) |i| {
        temp[i] = Y[pivot[i]];
        for (0..i) |j| {
            temp[i] -= LU[i][j] * temp[j];
        }
    }
    var i: usize = B;
    while (i > 0) {
        i -= 1;
        X[i] = temp[i];
        for (i + 1..B) |j| {
            X[i] -= LU[i][j] * X[j];
        }
        X[i] /= LU[i][i];
    }
}

fn solveBlockTranspose(
    LU_T: *const [B][B]f32,
    pivot_T: *const [B]usize,
    Src: *const [B][B]f32,
    Dest: *[B][B]f32,
    Src_T: *[B][B]f32,
    M_T: *[B][B]f32,
) void {
    for (0..B) |i| {
        for (0..B) |j| {
            Src_T[i][j] = Src[j][i];
        }
    }
    for (0..B) |col| {
        var y: [B]f32 = undefined;
        var x: [B]f32 = undefined;
        for (0..B) |r| {
            y[r] = Src_T[r][col];
        }
        luSolve(LU_T, pivot_T, &y, &x);
        for (0..B) |r| {
            M_T[r][col] = x[r];
        }
    }
    for (0..B) |i| {
        for (0..B) |j| {
            Dest[i][j] = M_T[j][i];
        }
    }
}

fn matMulSub(M: *const [B][B]f32, X: *const [B][B]f32, Dest: *[B][B]f32) void {
    for (0..B) |i| {
        for (0..B) |j| {
            var sum: f32 = 0;
            for (0..B) |k| {
                sum += M[i][k] * X[k][j];
            }
            Dest[i][j] -= sum;
        }
    }
}

fn vecMulSub(M: *const [B][B]f32, v: []const f32, Dest: []f32) void {
    for (0..B) |i| {
        var sum: f32 = 0;
        for (0..B) |k| {
            sum += M[i][k] * v[k];
        }
        Dest[i] -= sum;
    }
}

fn getMatrixBlock(Src: *const [N][N]f32, br: usize, bc: usize, Dest: *[B][B]f32) void {
    for (0..B) |i| {
        for (0..B) |j| {
            Dest[i][j] = Src[br * B + i][bc * B + j];
        }
    }
}

fn setMatrixBlock(Dest: *[N][N]f32, br: usize, bc: usize, Src: *const [B][B]f32) void {
    for (0..B) |i| {
        for (0..B) |j| {
            Dest[br * B + i][bc * B + j] = Src[i][j];
        }
    }
}

// ----------------------------------------------------------------------------
// Parallel Solver Worker Function
// ----------------------------------------------------------------------------

fn solverThreadFunc(arg: ?*anyopaque) ?*anyopaque {
    const core_id: usize = @intFromPtr(arg);
    const num_blocks = N / B;

    if (core_id == 0) {
        g_block_start_us = timerUs32();
    }

    var k: usize = 0;
    while (k < num_blocks - 1) : (k += 1) {
        if (core_id == 0) {
            for (0..B) |i| {
                for (0..B) |j| {
                    A_kk_T[i][j] = A_block[k * B + j][k * B + i];
                }
            }
            _ = luDecompose(&A_kk_T, &LU_k_T, &pivot_k_T);
        }

        g_barrier_lu.wait();

        var i: usize = k + 1;
        while (i < num_blocks) : (i += 1) {
            if ((i - (k + 1)) % OS_NCPU == core_id) {
                getMatrixBlock(&A_block, i, k, &A_kj[core_id]);
                solveBlockTranspose(
                    &LU_k_T,
                    &pivot_k_T,
                    &A_kj[core_id],
                    &M_local[core_id],
                    &workspace_Src_T[core_id],
                    &workspace_M_T[core_id],
                );

                var j: usize = k + 1;
                while (j < num_blocks) : (j += 1) {
                    getMatrixBlock(&A_block, k, j, &A_kj[core_id]);
                    getMatrixBlock(&A_block, i, j, &A_ij[core_id]);
                    matMulSub(&M_local[core_id], &A_kj[core_id], &A_ij[core_id]);
                    setMatrixBlock(&A_block, i, j, &A_ij[core_id]);
                }

                vecMulSub(&M_local[core_id], b_block[k * B .. (k + 1) * B], b_block[i * B .. (i + 1) * B]);
            }
        }

        g_barrier_step.wait();
    }

    if (core_id == 0) {
        var i: usize = num_blocks;
        while (i > 0) {
            i -= 1;
            for (0..B) |r| temp_bi[r] = b_block[i * B + r];
            for (i + 1..num_blocks) |j| {
                getMatrixBlock(&A_block, i, j, &A_ij_temp);
                for (0..B) |r| {
                    for (0..B) |c| {
                        temp_bi[r] -= A_ij_temp[r][c] * x_block[j * B + c];
                    }
                }
            }
            getMatrixBlock(&A_block, i, i, &A_ii);
            _ = luDecompose(&A_ii, &LU_ii, &pivot_ii);
            luSolve(&LU_ii, &pivot_ii, &temp_bi, x_block[i * B .. (i + 1) * B][0..B]);
        }

        g_block_end_us = timerUs32();
        g_solver_done = true;
    }

    g_barrier_lu.wait();
    return null;
}

// ----------------------------------------------------------------------------
// Classical N x N LU Solve (Ground Truth)
// ----------------------------------------------------------------------------

var LU_classic: [N][N]f32 = undefined;
var pivot_classic: [N]usize = undefined;

fn solveClassical(src_A: *const [N][N]f32, src_b: *const [N]f32, dest_x: *[N]f32) bool {
    for (0..N) |i| {
        for (0..N) |j| {
            LU_classic[i][j] = src_A[i][j];
        }
        pivot_classic[i] = i;
    }
    for (0..N) |i| {
        var max_val: f32 = 0;
        var max_row: usize = i;
        for (i..N) |r| {
            const val = @abs(LU_classic[r][i]);
            if (val > max_val) {
                max_val = val;
                max_row = r;
            }
        }
        if (max_val < 1e-9) return false;
        if (max_row != i) {
            std.mem.swap(usize, &pivot_classic[i], &pivot_classic[max_row]);
            for (0..N) |c| {
                std.mem.swap(f32, &LU_classic[i][c], &LU_classic[max_row][c]);
            }
        }
        for (i + 1..N) |r| {
            const factor = LU_classic[r][i] / LU_classic[i][i];
            LU_classic[r][i] = factor;
            for (i + 1..N) |c| {
                LU_classic[r][c] -= factor * LU_classic[i][c];
            }
        }
    }

    var temp: [N]f32 = undefined;
    for (0..N) |i| {
        temp[i] = src_b[pivot_classic[i]];
        for (0..i) |j| {
            temp[i] -= LU_classic[i][j] * temp[j];
        }
    }
    var i: usize = N;
    while (i > 0) {
        i -= 1;
        dest_x[i] = temp[i];
        for (i + 1..N) |j| {
            dest_x[i] -= LU_classic[i][j] * dest_x[j];
        }
        dest_x[i] /= LU_classic[i][i];
    }
    return true;
}

// ----------------------------------------------------------------------------
// Main Entry Points
// ----------------------------------------------------------------------------

pub fn main() void {
    uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    _ = rtos.interrupts.UncriticalSection.enter();

    g_barrier_lu.init(OS_NCPU);
    g_barrier_step.init(OS_NCPU);
    g_solver_done = false;

    uart.print("\n", .{});
    uart.print("=============================================\n", .{});
    uart.print("  {s} - {s}\n", .{ board.banner_long, board.banner_cpu });
    uart.print("  micro-os-plus-iii  smp-mat-test (all in RAM)\n", .{});
    uart.print("  parallel block linear solver\n", .{});
    uart.print("  N = {d}, B = {d}, cores = {d}\n", .{ N, B, OS_NCPU });
    uart.print("=============================================\n", .{});

    uart.print("core 0: releasing cores 1..3...\n", .{});
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    uart.print("core 0: SMP up ({s}, {d} ms).\n", .{ board.smp.joinSummary(), waited });

    // Thread Pool demo
    uart.print("Starting Thread Pool of 10 worker threads...\n", .{});
    g_pool.start();
    uart.print("Submitting 20 tasks to the Thread Pool...\n", .{});
    for (0..20) |i| {
        g_pool.submit(poolDemoTask, @ptrFromInt(i));
    }
    while (g_pool_task_count < 20) {
        rtos.sysclock.sleepFor(10) catch {};
    }
    uart.print("Thread Pool demo finished. All 20 tasks executed successfully.\n\n", .{});

    // Validate blocks
    const num_blocks = N / B;
    if (num_blocks % OS_NCPU != 0) {
        uart.print("NOTE: {d} blocks over {d} cores (uneven round-robin split).\n", .{ num_blocks, OS_NCPU });
    }

    uart.print("Generating diagonally dominant {d} x {d} matrix...\n", .{ N, N });
    var next_rand: u64 = 42;
    for (0..N) |i| {
        for (0..N) |j| {
            next_rand = next_rand *% 1103515245 +% 12345;
            const r: u32 = @truncate((next_rand / 65536) % 32768);
            A[i][j] = -5.0 + @as(f32, @floatFromInt(r)) / (32767.0 / 10.0);
        }
    }
    for (0..N) |i| {
        var sum: f32 = 0;
        for (0..N) |j| {
            if (i != j) sum += @abs(A[i][j]);
        }
        A[i][i] = sum + 5.0;
        b[i] = 1.0;
    }
    for (0..N) |i| {
        for (0..N) |j| {
            A_block[i][j] = A[i][j];
        }
        b_block[i] = b[i];
    }

    // Launch parallel solver threads
    uart.print("Starting parallel {d} -core block elimination...\n", .{OS_NCPU});
    const solver_names = [_][:0]const u8{ "solver_c0", "solver_c1", "solver_c2", "solver_c3" };
    for (0..OS_NCPU) |c| {
        const aff: u32 = @as(u32, 1) << @intCast(c);
        solver_threads[c].init(solver_names[c], solverThreadFunc, @ptrFromInt(c), .{ .cpu_affinity = aff }) catch unreachable;
    }

    while (!g_solver_done) {
        rtos.sysclock.sleepFor(50) catch {};
        board.led.toggle();
    }
    board.led.off();
    uart.print("Block elimination finished.\n", .{});

    // Classical solve
    uart.print("Solving full system using classical elimination...\n", .{});
    const classic_start = timerUs32();
    _ = solveClassical(&A, &b, &x_classic);
    const classic_end = timerUs32();
    uart.print("Classical elimination finished.\n\n", .{});

    const block_us = g_block_end_us - g_block_start_us;
    const classic_us = classic_end - classic_start;

    uart.print("+---------------------------------------------------+\n", .{});
    uart.print("| COMPARING BLOCK ELIMINATION VS CLASSICAL SOLVER  |\n", .{});
    uart.print("+---------------------------------------------------+\n", .{});

    var max_diff: f32 = 0;
    var sum_diff: f32 = 0;
    for (0..N) |i| {
        const diff = @abs(x_block[i] - x_classic[i]);
        sum_diff += diff;
        if (diff > max_diff) max_diff = diff;
        uart.print("x[{d}] Block = {d:.6} | Classic = {d:.6} | Abs Diff = {d:.6}\n", .{
            i, x_block[i], x_classic[i], diff,
        });
    }

    uart.print("-----------------------------------------------------\n", .{});
    uart.print("Total Absolute Difference (Sum): {d:.6}\n", .{sum_diff});
    uart.print("Max Absolute Difference:        {d:.6}\n", .{max_diff});
    uart.print("-----------------------------------------------------\n", .{});
    uart.print("Performance Metrics:\n", .{});
    uart.print("  Parallel Block Solver: {d} us\n", .{block_us});
    uart.print("  Classical Solver:      {d} us\n", .{classic_us});
    const speedup: f64 = if (block_us > 0) @as(f64, @floatFromInt(classic_us)) / @as(f64, @floatFromInt(block_us)) else 0.0;
    uart.print("  Speedup Ratio:         {d:.3}x\n", .{speedup});
    uart.print("+---------------------------------------------------+\n", .{});

    const pass = (max_diff < 0.01);
    if (pass) {
        uart.print("RESULT: PASS (block == classical within tolerance)\n", .{});
        uart.print("---------------------------------------------\n", .{});
        board.hw_result.ok();
    } else {
        uart.print("RESULT: FAIL\n", .{});
        uart.print("---------------------------------------------\n", .{});
        board.hw_result.fail();
    }
}
