//! smp-mat-sdcard-test -- parallel block linear solver with matrices stored on SD card
//! (the C++ test/rpi4b/smp-mat-sdcard-test).
//!
//! N = 200, B = 50, OS_NCPU = 4 cores.
//! 1. SD card init + format flatfs volume.
//! 2. Generate diagonally-dominant A and b in RAM, store to A.mat and b.mat on SD.
//! 3. Load A_block / b_block back from SD card (working set).
//! 4. Load A_classic / b_classic back from SD card.
//! 5. Bring up secondary cores.
//! 6. Thread Pool demo (10 workers, 20 tasks).
//! 7. Parallel 4-core block elimination.
//! 8. Classical solve (ground truth).
//! 9. Compare solutions (max diff < 0.01).
//! 10. Store solutions back to SD card and verify round trip.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const sd = @import("sd");
const flatfs = @import("flatfs");
const rtos = uos.rtos;
const uart = board.uart;

pub const uos_options = board.options(4);

const OS_NCPU: usize = 4;
const N: usize = 200;
const B: usize = 50;

fn timerUs32() u32 {
    const f = uos.port.arch.cntFrq();
    const freq = if (f > 0) f else 54_000_000;
    return @truncate(uos.port.arch.cntPct() * 1_000_000 / freq);
}

// ----------------------------------------------------------------------------
// Generation-based Spin Barrier
// ----------------------------------------------------------------------------

const Barrier = struct {
    target: usize = 0,
    current: usize = 0,
    generation: usize = 0,
    lock_: u32 = 0,

    pub fn init(self: *Barrier, count: usize) void {
        self.target = count;
        self.current = 0;
        self.generation = 0;
        self.lock_ = 0;
    }

    pub fn wait(self: *Barrier) void {
        uos.port.arch.dmbIsh();
        const gen = @atomicLoad(usize, &self.generation, .monotonic);

        while (@atomicRmw(u32, &self.lock_, .Xchg, 1, .acquire) != 0) {
            rtos.this_thread.yield();
        }

        self.current += 1;
        if (self.current == self.target) {
            self.current = 0;
            @atomicStore(usize, &self.generation, gen +% 1, .monotonic);
            uos.port.arch.dmbIsh();
            @atomicStore(u32, &self.lock_, 0, .release);
        } else {
            @atomicStore(u32, &self.lock_, 0, .release);
            while (@atomicLoad(usize, &self.generation, .monotonic) == gen) {
                rtos.this_thread.yield();
            }
        }
    }
};

// ----------------------------------------------------------------------------
// Thread Pool
// ----------------------------------------------------------------------------

const TaskFunc = *const fn (arg: ?*anyopaque) void;

const Task = struct {
    func: ?TaskFunc = null,
    arg: ?*anyopaque = null,
};

const TASK_QUEUE_SIZE: usize = 64;
const POOL_WORKERS: usize = 10;

const ThreadPool = struct {
    workers: [POOL_WORKERS]rtos.ThreadInclusive(4096) = undefined,
    queue: [TASK_QUEUE_SIZE]Task = @splat(.{}),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex_: rtos.Mutex = .{ .name = "pool_mtx" },
    sem_tasks_: rtos.Semaphore = .counting("pool_tasks", TASK_QUEUE_SIZE, 0),
    sem_free_: rtos.Semaphore = .counting("pool_free", TASK_QUEUE_SIZE, TASK_QUEUE_SIZE),
    started: bool = false,

    pub fn init(self: *ThreadPool) void {
        self.head = 0;
        self.tail = 0;
        self.count = 0;
        self.started = false;
    }

    pub fn start(self: *ThreadPool) void {
        if (self.started) return;
        self.started = true;
        const names = [_][:0]const u8{
            "pworker_0", "pworker_1", "pworker_2", "pworker_3", "pworker_4",
            "pworker_5", "pworker_6", "pworker_7", "pworker_8", "pworker_9",
        };
        for (&self.workers, 0..) |*w, i| {
            const aff: u32 = @as(u32, 1) << @intCast(i % OS_NCPU);
            w.init(names[i], workerLoopWrapper, self, .{ .cpu_affinity = aff }) catch unreachable;
        }
    }

    fn workerLoopWrapper(arg: ?*anyopaque) ?*anyopaque {
        const pool: *ThreadPool = @ptrCast(@alignCast(arg.?));
        pool.workerLoop();
        return null;
    }

    fn workerLoop(self: *ThreadPool) void {
        while (true) {
            self.sem_tasks_.wait() catch continue;

            self.mutex_.lock() catch continue;
            const task = self.queue[self.head];
            self.head = (self.head + 1) % TASK_QUEUE_SIZE;
            self.count -= 1;
            self.mutex_.unlock() catch {};

            self.sem_free_.post() catch {};

            if (task.func) |f| {
                f(task.arg);
            }
        }
    }

    pub fn submit(self: *ThreadPool, func: TaskFunc, arg: ?*anyopaque) void {
        self.sem_free_.wait() catch return;

        self.mutex_.lock() catch return;
        self.queue[self.tail] = .{ .func = func, .arg = arg };
        self.tail = (self.tail + 1) % TASK_QUEUE_SIZE;
        self.count += 1;
        self.mutex_.unlock() catch {};

        self.sem_tasks_.post() catch {};
    }
};

var g_pool: ThreadPool = .{};
var g_pool_task_count: usize = 0;
var g_pool_print_mutex: rtos.Mutex = .{};

fn poolDemoTask(arg: ?*anyopaque) void {
    const id: usize = @intFromPtr(arg);
    var sum: usize = 0;
    for (0..10000) |i| {
        sum +%= i;
    }
    g_pool_print_mutex.lock() catch {};
    uart.print("Thread Pool: Worker executed task {d} on CPU {d}\n", .{ id, uos.port.scheduler.cpuId() });
    g_pool_task_count += 1;
    g_pool_print_mutex.unlock() catch {};
}

// ----------------------------------------------------------------------------
// SD Matrix Store Globals & Utilities
// ----------------------------------------------------------------------------

var g_card: sd.SdCard = .{};
var g_fs: flatfs.FlatFs = .{};

const kFileA = "A.mat";
const kFileB = "b.mat";
const kFileXb = "x_block.mat";
const kFileXc = "xclassic.mat";

fn sdStore(name: []const u8, data: []const u8) bool {
    g_fs.writeFile(name, data) catch |err| {
        uart.print("    SD store {s} failed: {s}\n", .{ name, flatfs.resultStr(err) });
        return false;
    };
    return true;
}

fn sdLoad(name: []const u8, data: []u8) bool {
    const sz = g_fs.fileSize(name) catch |err| {
        uart.print("    SD load {s} size query failed: {s}\n", .{ name, flatfs.resultStr(err) });
        return false;
    };
    if (sz != data.len) {
        uart.print("    SD load {s}: wrong file size ({d} != {d})\n", .{ name, sz, data.len });
        return false;
    }
    _ = g_fs.readFile(name, data) catch |err| {
        uart.print("    SD load {s} read failed: {s}\n", .{ name, flatfs.resultStr(err) });
        return false;
    };
    return true;
}

// ----------------------------------------------------------------------------
// Solver Globals (in .bss to keep thread stacks tiny)
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

var A_classic: [N][N]f32 = undefined;
var b_classic: [N]f32 = undefined;
var x_classic: [N]f32 = undefined;

var LU_k_T: [B][B]f32 = undefined;
var pivot_k_T: [B]usize = undefined;

var A_kj: [OS_NCPU][B][B]f32 = undefined;
var M_local: [OS_NCPU][B][B]f32 = undefined;
var workspace_Src_T: [OS_NCPU][B][B]f32 = undefined;
var workspace_M_T: [OS_NCPU][B][B]f32 = undefined;
var A_ij: [OS_NCPU][B][B]f32 = undefined;

var A_kk_T: [B][B]f32 = undefined;
var A_ii: [B][B]f32 = undefined;
var LU_ii: [B][B]f32 = undefined;
var A_ij_temp: [B][B]f32 = undefined;
var pivot_ii: [B]usize = undefined;
var temp_bi: [B]f32 = undefined;

var solver_threads: [OS_NCPU]rtos.ThreadInclusive(16384) = undefined;

// ----------------------------------------------------------------------------
// LU Utilities for B x B Blocks
// ----------------------------------------------------------------------------

fn luDecompose(M: *const [B][B]f32, LU: *[B][B]f32, pivot: *[B]usize) bool {
    for (0..B) |i| {
        for (0..B) |j| {
            LU[i][j] = M[i][j];
        }
        pivot[i] = i;
    }
    for (0..B) |i| {
        var max_val: f32 = 0.0;
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
        for (0..B) |r| y[r] = Src_T[col][r];
        luSolve(LU_T, pivot_T, &y, &x);
        for (0..B) |r| M_T[col][r] = x[r];
    }
    for (0..B) |i| {
        for (0..B) |j| {
            Dest[i][j] = M_T[j][i];
        }
    }
}

fn getMatrixBlock(src: *const [N][N]f32, bi: usize, bj: usize, dest: *[B][B]f32) void {
    for (0..B) |i| {
        for (0..B) |j| {
            dest[i][j] = src[bi * B + i][bj * B + j];
        }
    }
}

fn setMatrixBlock(dest: *[N][N]f32, bi: usize, bj: usize, src: *const [B][B]f32) void {
    for (0..B) |i| {
        for (0..B) |j| {
            dest[bi * B + i][bj * B + j] = src[i][j];
        }
    }
}

fn matMulSub(m1: *const [B][B]f32, m2: *const [B][B]f32, dest: *[B][B]f32) void {
    for (0..B) |i| {
        for (0..B) |j| {
            var sum: f32 = 0;
            for (0..B) |k| sum += m1[i][k] * m2[k][j];
            dest[i][j] -= sum;
        }
    }
}

fn vecMulSub(m: *const [B][B]f32, v: *const [B]f32, dest: *[B]f32) void {
    for (0..B) |i| {
        var sum: f32 = 0;
        for (0..B) |k| sum += m[i][k] * v[k];
        dest[i] -= sum;
    }
}

fn solverThreadFunc(arg: ?*anyopaque) ?*anyopaque {
    const core_id: usize = @intFromPtr(arg);
    const num_blocks = N / B;

    g_barrier_lu.wait();

    if (core_id == 0) {
        g_block_start_us = timerUs32();
    }

    for (0..num_blocks - 1) |k| {
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

                const bk_slice: *const [B]f32 = @ptrCast(&b_block[k * B]);
                const bi_slice: *[B]f32 = @ptrCast(&b_block[i * B]);
                vecMulSub(&M_local[core_id], bk_slice, bi_slice);
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
            const xi_slice: *[B]f32 = @ptrCast(&x_block[i * B]);
            luSolve(&LU_ii, &pivot_ii, &temp_bi, xi_slice);
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
    g_pool.init();
    g_solver_done = false;

    uart.print("\n", .{});
    uart.print("=============================================\n", .{});
    uart.print("  {s} - {s}\n", .{ board.banner_long, board.banner_cpu });
    uart.print("  micro-os-plus-iii  smp-mat-sdcard-test\n", .{});
    uart.print("  parallel block linear solver, matrices on SD\n", .{});
    uart.print("  N = {d}, B = {d}, cores = {d}\n", .{ N, B, OS_NCPU });
    uart.print("=============================================\n", .{});

    // 1. SD card and flatfs init
    uart.print("Initialising SD card (Arasan EMMC/SDHCI)...\n", .{});
    if (!g_card.init()) {
        uart.print("FATAL: SD card init failed: {s}\n", .{g_card.last_error()});
        board.hw_result.fail();
    }
    uart.print("  SD ready: {d} sectors (~{d} MiB)\n", .{ g_card.sector_count(), g_card.capacity_bytes() >> 20 });
    g_fs.format(&g_card) catch |err| {
        uart.print("FATAL: flatfs format failed: {s}\n", .{flatfs.resultStr(err)});
        board.hw_result.fail();
    };
    uart.print("  flatfs volume formatted.\n", .{});

    // 2. Generate matrix in RAM
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
    uart.print("  matrix generated.\n", .{});

    // 3. Store A and b to SD card
    uart.print("Storing A and b on the SD card (A.mat, b.mat)...\n", .{});
    const bytes_A = std.mem.asBytes(&A);
    const bytes_b = std.mem.asBytes(&b);
    if (!sdStore(kFileA, bytes_A) or !sdStore(kFileB, bytes_b)) {
        uart.print("FATAL: storing matrices to SD failed\n", .{});
        board.hw_result.fail();
    }
    uart.print("  stored A.mat ({d} bytes)\n", .{bytes_A.len});
    uart.print("  stored b.mat ({d} bytes)\n", .{bytes_b.len});

    // 4. Load working sets from SD card
    uart.print("Loading A_block/b_block from the SD card (solver working set)...\n", .{});
    if (!sdLoad(kFileA, std.mem.asBytes(&A_block)) or !sdLoad(kFileB, std.mem.asBytes(&b_block))) {
        uart.print("FATAL: solver working set load from SD failed\n", .{});
        board.hw_result.fail();
    }
    uart.print("  solver working set loaded from SD.\n", .{});

    uart.print("Loading A/b for the classical solve from the SD card...\n", .{});
    if (!sdLoad(kFileA, std.mem.asBytes(&A_classic)) or !sdLoad(kFileB, std.mem.asBytes(&b_classic))) {
        uart.print("FATAL: classical matrix load from SD failed\n", .{});
        board.hw_result.fail();
    }
    uart.print("  classical working set loaded from SD.\n\n", .{});

    // 5. Release secondary cores
    uart.print("core 0: releasing cores 1..3...\n", .{});
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    uart.print("core 0: SMP up ({s}, {d} ms).\n", .{ board.smp.joinSummary(), waited });

    // 6. Thread Pool demo
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

    // 7. Parallel block elimination
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

    // 8. Classical solve
    uart.print("Solving full system using classical elimination...\n", .{});
    const classic_start = timerUs32();
    _ = solveClassical(&A_classic, &b_classic, &x_classic);
    const classic_end = timerUs32();
    uart.print("Classical elimination finished.\n\n", .{});

    const block_us = g_block_end_us - g_block_start_us;
    const classic_us = classic_end - classic_start;

    // 9. Store solutions back to SD card and verify round trip
    uart.print("Storing solutions back to SD card...\n", .{});
    if (!sdStore(kFileXb, std.mem.asBytes(&x_block)) or !sdStore(kFileXc, std.mem.asBytes(&x_classic))) {
        uart.print("FATAL: storing solutions to SD failed\n", .{});
        board.hw_result.fail();
    }
    uart.print("  stored x_block.mat and xclassic.mat\n", .{});

    var verify_x: [N]f32 = undefined;
    if (!sdLoad(kFileXb, std.mem.asBytes(&verify_x))) {
        uart.print("FATAL: round-trip verification failed\n", .{});
        board.hw_result.fail();
    }
    uart.print("  round-trip read verification passed.\n\n", .{});

    uart.print("+---------------------------------------------------+\n", .{});
    uart.print("| COMPARING BLOCK ELIMINATION VS CLASSICAL SOLVER  |\n", .{});
    uart.print("+---------------------------------------------------+\n", .{});

    var max_diff: f32 = 0;
    var sum_diff: f32 = 0;
    for (0..N) |i| {
        const diff = @abs(x_block[i] - x_classic[i]);
        sum_diff += diff;
        if (diff > max_diff) max_diff = diff;
        if (i < 5 or i >= N - 5) {
            uart.print("x[{d}] Block = {d:.6} | Classic = {d:.6} | Abs Diff = {d:.6}\n", .{
                i, x_block[i], x_classic[i], diff,
            });
        }
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
