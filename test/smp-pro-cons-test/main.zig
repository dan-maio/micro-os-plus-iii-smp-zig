//! smp-pro-cons-test -- producers and consumers over every kernel object
//! (the C++ test/rpi4b/smp-pro-cons-test).
//!
//! Four producers and four consumers, pinned one of each per CPU, pass
//! CRC-checked packets from a memory pool through a message queue, with a
//! counting semaphore as flow control. An aggregator waits on a condition
//! variable for batches, a stage worker on a binary semaphore, a pauser
//! suspends and resumes consumer 0, and telemetry waits on event flags
//! raised by a periodic timer. After RUN_MS (4 s) the pipeline stops; PASS
//! when data flowed on every CPU, no CRC failed, the pool did not leak, and
//! every mechanism ran.
//!
//! Differences from C++: the kernel prints its startup banner and creates
//! the secondary idle threads; the affinities are given at creation. The
//! 4096-byte stacks are used as given (above the port's 2 KiB minimum).

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const ncpu = uos.config.ncpu;
const console = board.console;

pub const uos_options = board.options(4);

const run_ms: u32 = 4000;

fn ledToggle() void {
    const S = struct {
        var state = false;
    };
    S.state = !S.state;
    board.led.set(S.state);
}

// ---------------------------------------------------------------------------
// The packet exchanged through the memory pool and the message queue.

const Packet = extern struct {
    seq: u32,
    prod_id: u32,
    core_id: u32,
    timestamp: u32,
    payload: u32,
    crc: u32,
};

/// CRC32 (IEEE 802.3), bit by bit, as in C++.
fn calcCrc32(bytes: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (bytes) |b| {
        crc ^= b;
        for (0..8) |_| crc = (crc >> 1) ^ (0xEDB8_8320 & (0 -% (crc & 1)));
    }
    return ~crc;
}

fn packetCrc(pkt: *const Packet) u32 {
    return calcCrc32(std.mem.asBytes(pkt)[0 .. @sizeOf(Packet) - @sizeOf(u32)]);
}

// 1. Mutexes.
var g_stats_mtx: rtos.Mutex = .{ .name = "stats_mtx" };
var g_cond_mtx: rtos.Mutex = .{ .name = "cond_mtx" };

// 2. Memory pool: fixed-size packet blocks.
const pool_blocks = 48;
var g_pkt_pool: rtos.MemoryPool = .{};

// 3. Message queue: a bounded FIFO of packet pointers.
const queue_capacity = 32;
var g_msg_queue: rtos.MessageQueue = .{};

// 4. Counting semaphore: token-bucket flow control.
const max_credits = 32;
var g_credit_sem: rtos.Semaphore = .counting("credit_sem", max_credits, max_credits);

// 5. Binary semaphore: pipeline stage handshake.
var g_stage_sem: rtos.Semaphore = .binary("stage_sem", 0);

// 6. Condition variable: batch notification.
var g_batch_cond: rtos.ConditionVariable = .{};
const batch_size = 16;
var g_batch_counter: usize = 0;
var g_batch_crc_sum: u32 = 0;

// 7. Event flags: status bits.
var g_events: rtos.EventFlags = .{};
const flag_prod_active: rtos.flags.Mask = 1 << 0;
const flag_cons_active: rtos.flags.Mask = 1 << 1;
const flag_timer_tick: rtos.flags.Mask = 1 << 2;
const flag_stage_sync: rtos.flags.Mask = 1 << 3;
const flag_shutdown: rtos.flags.Mask = 1 << 4;

// 8. Software timer: a periodic heartbeat.
const Counter = std.atomic.Value(u32);
var g_timer_ticks = Counter.init(0);

fn heartbeatTimerCb(_: ?*anyopaque) void {
    _ = g_timer_ticks.fetchAdd(1, .monotonic);
    _ = g_events.raise(flag_timer_tick) catch {};
    ledToggle();
}

var g_heartbeat_timer: rtos.Timer = .init("heartbeat", heartbeatTimerCb, null, .periodic);

// The metrics.
var g_running = std.atomic.Value(bool).init(true);
var g_produced = Counter.init(0);
var g_consumed = Counter.init(0);
var g_batches_checked = Counter.init(0);
var g_stage_sync_count = Counter.init(0);
var g_crc_errors = Counter.init(0);
var g_total_yields = Counter.init(0);
var g_pool_alloc_count = Counter.init(0);
var g_pool_free_count = Counter.init(0);
var g_suspends = Counter.init(0);
var g_resumes = Counter.init(0);
var g_suspend_req = std.atomic.Value(bool).init(false);
var g_is_suspended = std.atomic.Value(bool).init(false);
var g_core_produced: [ncpu]u32 = @splat(0);
var g_core_consumed: [ncpu]u32 = @splat(0);
var g_core_yields: [ncpu]u32 = @splat(0);

fn running() bool {
    return g_running.load(.monotonic);
}

fn countYield() void {
    _ = g_total_yields.fetchAdd(1, .monotonic);
    g_stats_mtx.lock() catch {};
    g_core_yields[board.cpuSlot()] += 1;
    g_stats_mtx.unlock() catch {};
}

// ---------------------------------------------------------------------------
// The threads.

fn producerThread(arg: ?*anyopaque) ?*anyopaque {
    const id: u32 = @intCast(@intFromPtr(arg));
    _ = g_events.raise(flag_prod_active) catch {};
    while (running()) {
        // 1. A credit token.
        g_credit_sem.wait() catch break;
        if (!running()) break;
        // 2. A packet from the pool.
        const mem = g_pkt_pool.alloc() catch {
            g_credit_sem.post() catch {};
            this_thread.yield();
            continue;
        };
        _ = g_pool_alloc_count.fetchAdd(1, .monotonic);
        const pkt: *Packet = @ptrCast(@alignCast(mem));
        const core = board.cpuSlot();
        const seq = g_produced.fetchAdd(1, .monotonic);
        pkt.* = .{
            .seq = seq,
            .prod_id = id,
            .core_id = core,
            .timestamp = @truncate(sysclock.now()),
            .payload = (seq *% 1103515245 +% 12345) ^ id,
            .crc = 0,
        };
        pkt.crc = packetCrc(pkt);
        g_stats_mtx.lock() catch {};
        g_core_produced[core] += 1;
        g_stats_mtx.unlock() catch {};
        // 3. Its pointer through the queue.
        g_msg_queue.send(std.mem.asBytes(&pkt), 0) catch {};
        this_thread.yield();
        countYield();
        sysclock.sleepFor(10 + id * 2) catch {};
    }
    return null;
}

fn consumerThread(arg: ?*anyopaque) ?*anyopaque {
    const id: u32 = @intCast(@intFromPtr(arg));
    _ = g_events.raise(flag_cons_active) catch {};
    while (running()) {
        // Cooperative suspend, for cons_0.
        if (id == 0 and g_suspend_req.load(.monotonic)) {
            g_suspend_req.store(false, .monotonic);
            g_is_suspended.store(true, .release);
            _ = g_suspends.fetchAdd(1, .monotonic);
            this_thread.@"suspend"();
            g_is_suspended.store(false, .release);
        }
        // 1. A packet pointer from the queue.
        var pkt: ?*Packet = null;
        _ = g_msg_queue.receive(std.mem.asBytes(&pkt)) catch {
            if (!running()) break;
            this_thread.yield();
            continue;
        };
        const p = pkt orelse {
            if (!running()) break;
            this_thread.yield();
            continue;
        };
        const core = board.cpuSlot();
        // 2. Its CRC.
        if (p.crc != packetCrc(p)) _ = g_crc_errors.fetchAdd(1, .monotonic);
        g_stats_mtx.lock() catch {};
        g_core_consumed[core] += 1;
        g_stats_mtx.unlock() catch {};
        const c_count = g_consumed.fetchAdd(1, .monotonic);
        // 3. Batch aggregation, signalled through the condition variable.
        g_cond_mtx.lock() catch {};
        g_batch_counter += 1;
        g_batch_crc_sum ^= p.crc;
        if (g_batch_counter >= batch_size) g_batch_cond.signal() catch {};
        g_cond_mtx.unlock() catch {};
        // 4. The stage trigger, every 8 packets.
        if ((c_count & 7) == 0) g_stage_sem.post() catch {};
        // 5. The block back to the pool.
        g_pkt_pool.free(p) catch {};
        _ = g_pool_free_count.fetchAdd(1, .monotonic);
        // 6. The credit back.
        g_credit_sem.post() catch {};
        this_thread.yield();
        countYield();
        sysclock.sleepFor(5) catch {};
    }
    return null;
}

/// Waits on the condition variable and checks the batches.
fn aggregatorThread(_: ?*anyopaque) ?*anyopaque {
    while (running()) {
        g_cond_mtx.lock() catch {};
        while (g_batch_counter < batch_size and running()) g_batch_cond.wait(&g_cond_mtx) catch {};
        if (g_batch_counter >= batch_size) {
            g_batch_counter = 0;
            g_batch_crc_sum = 0;
            _ = g_batches_checked.fetchAdd(1, .monotonic);
        }
        g_cond_mtx.unlock() catch {};
        sysclock.sleepFor(20) catch {};
    }
    return null;
}

/// Triggered by the binary semaphore.
fn stageWorkerThread(_: ?*anyopaque) ?*anyopaque {
    while (running()) {
        g_stage_sem.wait() catch break;
        if (!running()) break;
        _ = g_stage_sync_count.fetchAdd(1, .monotonic);
        _ = g_events.raise(flag_stage_sync) catch {};
        this_thread.yield();
    }
    return null;
}

var g_target_worker: ?*rtos.Thread = null;

/// Suspends (cooperatively) and resumes the target worker.
fn pauserThread(_: ?*anyopaque) ?*anyopaque {
    while (running()) {
        sysclock.sleepFor(300) catch {};
        if (!running()) break;
        const target = g_target_worker orelse break;
        g_suspend_req.store(true, .release);
        var wait_ms: u32 = 0;
        while (!g_is_suspended.load(.acquire) and wait_ms < 100 and running()) {
            sysclock.sleepFor(10) catch {};
            wait_ms += 10;
        }
        if (g_is_suspended.load(.acquire)) {
            // Let the system run while the worker is suspended.
            sysclock.sleepFor(50) catch {};
            target.@"resume"();
            _ = g_resumes.fetchAdd(1, .monotonic);
        }
    }
    return null;
}

/// Waits on the event flags and logs the pipeline rates.
fn telemetryThread(_: ?*anyopaque) ?*anyopaque {
    var last_produced: u32 = 0;
    var last_consumed: u32 = 0;
    var print_counter: u32 = 0;
    while (running()) {
        const oflags = g_events.wait(flag_timer_tick | flag_shutdown, .any_clear) catch 0;
        if (oflags & flag_shutdown != 0) break;
        print_counter += 1;
        if (print_counter >= 5) { // every ~1000 ms (5 x 200 ms)
            print_counter = 0;
            const cur_p = g_produced.load(.monotonic);
            const cur_c = g_consumed.load(.monotonic);
            const delta_p = cur_p - last_produced;
            const delta_c = cur_c - last_consumed;
            last_produced = cur_p;
            last_consumed = cur_c;
            const now_ms: u32 = @truncate(sysclock.now());
            console("[t={d:>5} ms] pipe: prod={d} (+{d}) cons={d} (+{d}) | pool={d}/{d} | yields={d} | ticks={d} | stages={d}\n", .{
                now_ms,                              cur_p,                           delta_p,
                cur_c,                               delta_c,                         g_pool_alloc_count.load(.monotonic),
                g_pool_free_count.load(.monotonic),  g_total_yields.load(.monotonic), g_timer_ticks.load(.monotonic),
                g_stage_sync_count.load(.monotonic),
            });
        }
    }
    return null;
}

// ---------------------------------------------------------------------------

pub fn main() void {
    board.uart.init();
    board.led.init();
    rtos.run(osMain);
}

const worker_stack_size = 4096;
const Stack = [worker_stack_size / @sizeOf(uos.port.StackElement)]uos.port.StackElement;
var s_prod_stacks: [4]Stack = undefined;
var s_cons_stacks: [4]Stack = undefined;
var s_agg_stack: Stack = undefined;
var s_stage_stack: Stack = undefined;
var s_pause_stack: Stack = undefined;
var s_telem_stack: Stack = undefined;
var s_prods: [4]*rtos.Thread = undefined;
var s_conss: [4]*rtos.Thread = undefined;
var s_prod_names: [4][6:0]u8 = undefined;
var s_cons_names: [4][6:0]u8 = undefined;
var s_agg_thread: rtos.Thread = undefined;
var s_stage_thread: rtos.Thread = undefined;
var s_pause_thread: rtos.Thread = undefined;
var s_telem_thread: rtos.Thread = undefined;

fn osMain() void {
    const gpa = uos.memory.allocator();
    // The C++ static objects.
    g_pkt_pool.create(gpa, "pkt_pool", pool_blocks, @sizeOf(Packet), .{}) catch unreachable;
    g_msg_queue.create(gpa, "msg_queue", queue_capacity, @sizeOf(*Packet), .{}) catch unreachable;
    g_batch_cond.init("batch_cond", .{}) catch unreachable;
    g_events.init("app_events", .{}) catch unreachable;

    console("\n+=============================================================+\n", .{});
    console("|  " ++ board.banner_short ++ " µOS++ SMP PRODUCER-CONSUMER KERNEL OBJECT TEST |\n", .{});
    console("|  " ++ board.banner_cpu ++ " — ALL Kernel Objects Demo |\n", .{});
    console("+=============================================================+\n\n", .{});

    // 1. Release the secondary CPUs.
    _ = rtos.interrupts.UncriticalSection.enter();
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    console("Secondary cores joined: {s} ({d} ms)\n", .{ board.smp.joinSummary(), waited });

    // 2. The heartbeat timer.
    console("Starting periodic software timer (200 ms)...\n", .{});
    g_heartbeat_timer.start(200) catch {};

    // 3. The threads.
    for (0..4) |i| {
        s_prod_names[i] = "prod_0".*;
        s_prod_names[i][5] = '0' + @as(u8, @intCast(i));
        s_prods[i] = rtos.Thread.create(gpa, &s_prod_names[i], producerThread, @ptrFromInt(i), .{
            .stack = &s_prod_stacks[i],
            .priority = rtos.priority.normal,
            .cpu_affinity = @as(u32, 1) << @intCast(i),
        }) catch unreachable;
    }
    for (0..4) |i| {
        s_cons_names[i] = "cons_0".*;
        s_cons_names[i][5] = '0' + @as(u8, @intCast(i));
        s_conss[i] = rtos.Thread.create(gpa, &s_cons_names[i], consumerThread, @ptrFromInt(i), .{
            .stack = &s_cons_stacks[i],
            .priority = rtos.priority.normal,
            .cpu_affinity = @as(u32, 1) << @intCast(i),
        }) catch unreachable;
    }
    g_target_worker = s_conss[0];

    s_agg_thread.init("aggregator", aggregatorThread, null, .{ .stack = &s_agg_stack, .priority = rtos.priority.above_normal, .cpu_affinity = 1 << 1 }, gpa) catch unreachable;
    s_stage_thread.init("stage_worker", stageWorkerThread, null, .{ .stack = &s_stage_stack, .priority = rtos.priority.above_normal, .cpu_affinity = 1 << 2 }, gpa) catch unreachable;
    s_pause_thread.init("pauser", pauserThread, null, .{ .stack = &s_pause_stack, .priority = rtos.priority.above_normal, .cpu_affinity = 1 << 3 }, gpa) catch unreachable;
    s_telem_thread.init("telemetry", telemetryThread, null, .{ .stack = &s_telem_stack, .priority = rtos.priority.high, .cpu_affinity = 1 << 0 }, gpa) catch unreachable;

    console("12 concurrent threads started across {d} cores!\n", .{ncpu});
    console("Running pipeline for {d} ms ...\n\n", .{run_ms});

    sysclock.sleepFor(run_ms) catch {};

    console("\nStopping producer-consumer pipeline threads...\n", .{});
    g_running.store(false, .monotonic);
    _ = g_events.raise(flag_shutdown) catch {};
    g_stage_sem.post() catch {};

    // Let the queues and the packets in flight drain.
    sysclock.sleepFor(400) catch {};
    g_heartbeat_timer.stop() catch {};

    const total_p = g_produced.load(.monotonic);
    const total_c = g_consumed.load(.monotonic);
    const allocs = g_pool_alloc_count.load(.monotonic);
    const frees = g_pool_free_count.load(.monotonic);
    const crc_err = g_crc_errors.load(.monotonic);
    const yields = g_total_yields.load(.monotonic);
    const susp = g_suspends.load(.monotonic);
    const resm = g_resumes.load(.monotonic);
    const ticks = g_timer_ticks.load(.monotonic);
    const batches = g_batches_checked.load(.monotonic);
    const stages = g_stage_sync_count.load(.monotonic);

    console("\n================ Producer-Consumer Test Summary ================\n", .{});
    console("Kernel Objects Tested:\n", .{});
    console("  [1] thread              : 12 threads active across {d} cores\n", .{ncpu});
    console("  [2] memory_pool         : allocs={d}, frees={d} (diff={d})\n", .{ allocs, frees, @as(i32, @bitCast(allocs -% frees)) });
    console("  [3] message_queue       : sent={d}, received={d}\n", .{ total_p, total_c });
    console("  [4] semaphore_counting  : flow-control tokens acquired & returned\n", .{});
    console("  [5] semaphore_binary    : {d} stage synchronizations verified\n", .{stages});
    console("  [6] mutex               : protected console, stats, and condition var\n", .{});
    console("  [7] condition_variable  : {d} batches signaled & verified\n", .{batches});
    console("  [8] event_flags         : multi-bit lifecycle & timer flags handled\n", .{});
    console("  [9] timer               : {d} software timer ticks delivered\n", .{ticks});
    console("  [10] sysclock           : sleep_for() & timestamping verified\n", .{});
    console("  [11] yield/suspend/res  : {d} yields, {d} suspends, {d} resumes\n", .{ yields, susp, resm });
    console("Errors:\n", .{});
    console("  CRC Errors: {d}\n", .{crc_err});
    console("SMP Core Distribution:\n", .{});
    board.reportPerCore("Produced by core", &g_core_produced);
    board.reportPerCore("Consumed by core", &g_core_consumed);
    board.reportPerCore("Yields by core  ", &g_core_yields);
    console("================================================================\n\n", .{});

    var all_cores_active = true;
    for (0..ncpu) |c| {
        if (g_core_produced[c] == 0 or g_core_consumed[c] == 0) all_cores_active = false;
    }
    const pass = total_p > 50 and total_c > 50 and crc_err == 0 and allocs == frees and
        batches > 0 and stages > 0 and ticks > 0 and susp > 0 and resm > 0 and all_cores_active;
    console("RESULT: {s}\n", .{if (pass) "PASS" else "FAIL"});
    if (pass) board.hw_result.ok() else board.hw_result.fail();
}
