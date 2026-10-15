//! smp-pipeline-test -- multi-stage pipeline across Cortex-A72 cores on RPi4B
//! (the C++ test/rpi4b/smp-pipeline-test).
//!
//! Thirteen threads: 4 producers (timestamped records with a CRC), 4
//! compute workers (transform, new CRC), 2 SD writers (batches of 8 records
//! appended to pipe.dat), 1 auditor (reads pipe.dat back from its last
//! offset and checks every CRC and the per-source order), 1 LED pacer and 1
//! telemetry thread. Bounded queues with counting semaphores, and yield()
//! everywhere. After RUN_MS: PASS when records were audited without
//! a CRC, order or write error.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const sd = @import("sd");
const flatfs = @import("flatfs");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const ncpu = uos.config.ncpu;
const console = board.console;

pub const uos_options = board.options(4);

const run_ms: u32 = 4000;

fn cpuId() u32 {
    return uos.port.scheduler.cpuId();
}

var g_card: sd.SdCard = .{};
var g_fs: flatfs.FlatFs = .{};
const pipe_file = "pipe.dat";

// Mutexes.
var g_in_mtx: rtos.Mutex = .{ .name = "in_queue" };
var g_sd_mtx: rtos.Mutex = .{ .name = "sd_queue" };
var g_file_mtx: rtos.Mutex = .{ .name = "file_io" };

// The bounded queues' semaphores.
const in_cap = 32;
const sd_cap = 32;
var g_in_items: rtos.Semaphore = .counting("in_items", in_cap, 0);
var g_in_spaces: rtos.Semaphore = .counting("in_spaces", in_cap, in_cap);
var g_sd_items: rtos.Semaphore = .counting("sd_items", sd_cap, 0);
var g_sd_spaces: rtos.Semaphore = .counting("sd_spaces", sd_cap, sd_cap);
var g_audit_sem: rtos.Semaphore = .counting("audit_sem", 64, 0);

var g_finish = std.atomic.Value(bool).init(false);

fn finished() bool {
    return g_finish.load(.monotonic);
}

/// CRC32 (IEEE 802.3), bit by bit, as in C++.
fn calcCrc32(bytes: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (bytes) |b| {
        crc ^= b;
        for (0..8) |_| crc = (crc >> 1) ^ (0xEDB8_8320 & (0 -% (crc & 1)));
    }
    return ~crc;
}

fn crcOf(val: u32) u32 {
    return calcCrc32(std.mem.asBytes(&val));
}

const PipelineRecord = struct {
    seq: u32 = 0,
    src: u16 = 0,
    proc_core: u16 = 0,
    timestamp_ms: u32 = 0,
    val: u32 = 0,
    crc: u32 = 0,
};

// The input queue.
var g_in_buf: [in_cap]PipelineRecord = undefined;
var g_in_head: usize = 0;
var g_in_tail: usize = 0;
var g_in_count: usize = 0;

// The SD queue.
var g_sd_buf: [sd_cap]PipelineRecord = undefined;
var g_sd_head: usize = 0;
var g_sd_tail: usize = 0;
var g_sd_count: usize = 0;

const Counter = std.atomic.Value(u32);
// The yield statistics.
var g_yield_prod = Counter.init(0);
var g_yield_work = Counter.init(0);
var g_yield_compute = Counter.init(0);
var g_yield_writer = Counter.init(0);
var g_yield_auditor = Counter.init(0);
var g_yield_by_core: [ncpu]Counter = @splat(.init(0));

// Throughput and verification.
var g_total_produced = Counter.init(0);
var g_total_processed = Counter.init(0);
var g_total_written = Counter.init(0);
var g_total_audited = Counter.init(0);
var g_crc_errors = Counter.init(0);
var g_seq_errors = Counter.init(0);
var g_write_errors = Counter.init(0);
var g_prod_by_core: [ncpu]Counter = @splat(.init(0));
var g_proc_by_core: [ncpu]Counter = @splat(.init(0));

fn inc(c: *Counter) void {
    _ = c.fetchAdd(1, .monotonic);
}

fn countYield(c: *Counter) void {
    inc(c);
    const id = cpuId();
    if (id < ncpu) inc(&g_yield_by_core[id]);
}

// The audit read window: one read, not the file (which grows all along).
const audit_window = 64 * 1024;
var g_read_buf: [audit_window]u8 = undefined;

// ---- SD helpers --------------------------------------------------------------

fn sdPrepare() void {
    console("Initialising SD card via SDHCI...\n", .{});
    if (!g_card.init()) {
        console("  SD init FAILED: {s}\n", .{g_card.last_error()});
        board.hw_result.fail();
    }
    console("  SD card ready: {d} sectors (~{d} MiB)\n", .{ g_card.sector_count(), g_card.capacity_bytes() >> 20 });
    g_fs.format(&g_card) catch |err| {
        console("  flatfs format failed: {s}\n", .{flatfs.resultStr(err)});
        board.hw_result.fail();
    };
    g_fs.removeFile(pipe_file) catch {};
    console("  flatfs volume formatted, {s} ready\n", .{pipe_file});
}

fn sdAppend(text: []const u8) bool {
    g_fs.appendFile(pipe_file, text) catch return false;
    return true;
}

fn sdReadFrom(offset: u32, out: []u8) ?usize {
    return g_fs.readFileAt(pipe_file, offset, out) catch null;
}

/// Wait for a token, yielding meanwhile.
fn acquire(sem: *rtos.Semaphore, yields: *Counter) bool {
    var retries: u32 = 0;
    while (!finished()) {
        if (sem.tryWait()) |_| return true else |_| {}
        countYield(yields);
        this_thread.yield();
        retries += 1;
        if (retries > 6) {
            sysclock.sleepFor(4) catch {};
            retries = 0;
        }
    }
    return false;
}

// ---- 1. Producers (4) ----------------------------------------------------------

fn producerThread(arg: ?*anyopaque) ?*anyopaque {
    const src_id: u16 = @intCast(@intFromPtr(arg));
    var seq: u32 = 0;
    while (!finished()) {
        if (!acquire(&g_in_spaces, &g_yield_prod)) break;

        const core = cpuId();
        seq += 1;
        var rec: PipelineRecord = .{
            .seq = seq,
            .src = src_id,
            .proc_core = 0xFFFF,
            .timestamp_ms = @truncate(sysclock.now()),
            .val = seq *% 1000 +% @as(u32, src_id) * 100 +% seq % 97,
        };
        rec.crc = crcOf(rec.val);

        g_in_mtx.lock() catch {};
        g_in_buf[g_in_head] = rec;
        g_in_head = (g_in_head + 1) % in_cap;
        g_in_count += 1;
        g_in_mtx.unlock() catch {};
        g_in_items.post() catch {};

        inc(&g_total_produced);
        if (core < ncpu) inc(&g_prod_by_core[core]);
        sysclock.sleepFor(30 + @as(u32, src_id) * 5) catch {};
    }
    return null;
}

// ---- 2. Compute workers (4) ------------------------------------------------------

fn workerThread(arg: ?*anyopaque) ?*anyopaque {
    const worker_id: u32 = @intCast(@intFromPtr(arg));
    var local_count: u32 = 0;
    while (!finished()) {
        if (!acquire(&g_in_items, &g_yield_work)) break;

        g_in_mtx.lock() catch {};
        var rec = g_in_buf[g_in_tail];
        g_in_tail = (g_in_tail + 1) % in_cap;
        g_in_count -= 1;
        g_in_mtx.unlock() catch {};
        g_in_spaces.post() catch {};

        const core = cpuId();
        rec.proc_core = @intCast(core);
        rec.val +%= worker_id * 7;
        rec.crc = crcOf(rec.val);

        local_count += 1;
        if ((local_count & 0x03) == 0) {
            inc(&g_yield_compute);
            if (core < ncpu) inc(&g_yield_by_core[core]);
            this_thread.yield();
        }

        if (!acquire(&g_sd_spaces, &g_yield_work)) break;

        g_sd_mtx.lock() catch {};
        g_sd_buf[g_sd_head] = rec;
        g_sd_head = (g_sd_head + 1) % sd_cap;
        g_sd_count += 1;
        g_sd_mtx.unlock() catch {};
        g_sd_items.post() catch {};

        inc(&g_total_processed);
        if (core < ncpu) inc(&g_proc_by_core[core]);
    }
    return null;
}

// ---- 3. SD writers (2) -----------------------------------------------------------

fn sdWriterThread(_: ?*anyopaque) ?*anyopaque {
    var batch_buf: [1024]u8 = undefined;
    while (!finished()) {
        var batch: [8]PipelineRecord = undefined;
        var batch_count: usize = 0;
        while (batch_count < 8) {
            if (g_sd_items.tryWait()) |_| {
                g_sd_mtx.lock() catch {};
                batch[batch_count] = g_sd_buf[g_sd_tail];
                g_sd_tail = (g_sd_tail + 1) % sd_cap;
                g_sd_count -= 1;
                g_sd_mtx.unlock() catch {};
                g_sd_spaces.post() catch {};
                batch_count += 1;
            } else |_| {
                if (batch_count > 0 or finished()) break;
                this_thread.yield();
                sysclock.sleepFor(10) catch {};
            }
        }

        if (batch_count > 0) {
            var w: std.Io.Writer = .fixed(&batch_buf);
            for (batch[0..batch_count]) |rec| {
                w.print("[c{d}] seq={d:0>5} src={d} t={d} val={d} crc={x:0>8}\n", .{
                    rec.proc_core, rec.seq, rec.src, rec.timestamp_ms, rec.val, rec.crc,
                }) catch break;
            }
            const text = w.buffered();
            if (text.len > 0) {
                g_file_mtx.lock() catch {};
                const ok = sdAppend(text);
                g_file_mtx.unlock() catch {};
                if (ok) {
                    _ = g_total_written.fetchAdd(@intCast(batch_count), .monotonic);
                    g_audit_sem.post() catch {};
                } else {
                    _ = g_write_errors.fetchAdd(@intCast(batch_count), .monotonic);
                }
            }
        }

        countYield(&g_yield_writer);
        this_thread.yield();
        sysclock.sleepFor(20) catch {};
    }
    return null;
}

// ---- 4. SD auditor (1) -----------------------------------------------------------

const Parsed = struct { core: u32, seq: u32, src: u32, t: u32, val: u32, crc: u32 };

fn parseRecord(line: []const u8) ?Parsed {
    var rest = line;
    const S = struct {
        fn lit(r: *[]const u8, s: []const u8) bool {
            if (!std.mem.startsWith(u8, r.*, s)) return false;
            r.* = r.*[s.len..];
            return true;
        }
        fn num(r: *[]const u8, base: u8) ?u32 {
            var n: usize = 0;
            while (n < r.len and std.ascii.isHex(r.*[n]) and (base == 16 or std.ascii.isDigit(r.*[n]))) n += 1;
            if (n == 0) return null;
            const v = std.fmt.parseInt(u32, r.*[0..n], base) catch return null;
            r.* = r.*[n..];
            return v;
        }
    };
    if (!S.lit(&rest, "[c")) return null;
    const core = S.num(&rest, 10) orelse return null;
    if (!S.lit(&rest, "] seq=")) return null;
    const seq = S.num(&rest, 10) orelse return null;
    if (!S.lit(&rest, " src=")) return null;
    const src = S.num(&rest, 10) orelse return null;
    if (!S.lit(&rest, " t=")) return null;
    const t = S.num(&rest, 10) orelse return null;
    if (!S.lit(&rest, " val=")) return null;
    const val = S.num(&rest, 10) orelse return null;
    if (!S.lit(&rest, " crc=")) return null;
    const crc = S.num(&rest, 16) orelse return null;
    return .{ .core = core, .seq = seq, .src = src, .t = t, .val = val, .crc = crc };
}

fn sdAuditorThread(_: ?*anyopaque) ?*anyopaque {
    var last_offset: u32 = 0;
    var max_seq_by_src: [4]u32 = @splat(0);
    while (!finished()) {
        while (!finished()) {
            if (g_audit_sem.tryWait()) |_| break else |_| {}
            this_thread.yield();
            sysclock.sleepFor(50) catch {};
        }
        if (finished()) break;

        const base_offset = last_offset;
        g_file_mtx.lock() catch {};
        const got = sdReadFrom(last_offset, &g_read_buf);
        g_file_mtx.unlock() catch {};

        if (got) |chunk_len| {
            var p: usize = 0;
            while (p < chunk_len) {
                const nl = std.mem.indexOfScalarPos(u8, g_read_buf[0..chunk_len], p, '\n') orelse break;
                if (parseRecord(g_read_buf[p..nl])) |r| {
                    if (r.src < 4) {
                        const reorder_window: u32 = sd_cap + 2 * 8;
                        if (r.seq > max_seq_by_src[r.src]) {
                            max_seq_by_src[r.src] = r.seq;
                        } else if (max_seq_by_src[r.src] - r.seq > reorder_window) {
                            inc(&g_seq_errors);
                        }
                    }
                    if (crcOf(r.val) != r.crc) inc(&g_crc_errors);
                    inc(&g_total_audited);
                }
                p = nl + 1;
                last_offset = base_offset + @as(u32, @intCast(p));
                countYield(&g_yield_auditor);
                this_thread.yield();
            }
        }
        sysclock.sleepFor(40) catch {};
    }
    return null;
}

// ---- 5. LED pacer, 6. telemetry ------------------------------------------------

fn ledThread(_: ?*anyopaque) ?*anyopaque {
    while (!finished()) {
        board.led.toggle();
        sysclock.sleepFor(150) catch {};
        this_thread.yield();
    }
    board.led.off();
    return null;
}

fn telemetryThread(_: ?*anyopaque) ?*anyopaque {
    while (!finished()) {
        sysclock.sleepFor(1000) catch {};
        if (finished()) break;
        console("[t={d:>5} ms] pipe: in_q={d:>2} sd_q={d:>2} | prod={d} proc={d} sd={d} aud={d} | yields: P={d} W={d} C={d} S={d} A={d}\n", .{
            @as(u32, @truncate(sysclock.now())),     g_in_count,                         g_sd_count,
            g_total_produced.load(.monotonic),       g_total_processed.load(.monotonic), g_total_written.load(.monotonic),
            g_total_audited.load(.monotonic),        g_yield_prod.load(.monotonic),      g_yield_work.load(.monotonic),
            g_yield_compute.load(.monotonic),        g_yield_writer.load(.monotonic),    g_yield_auditor.load(.monotonic),
        });
    }
    return null;
}

// ---- Stacks and threads --------------------------------------------------------

const El = uos.port.StackElement;
var s_prod_stk: [4][2048]El = undefined;
var s_work_stk: [4][2048]El = undefined;
var s_wrt_stk: [2][2048]El = undefined;
var s_aud_stk: [2048]El = undefined;
var s_led_stk: [1024]El = undefined;
var s_tel_stk: [2048]El = undefined;
var t_tel: rtos.Thread = undefined;
var t_led: rtos.Thread = undefined;
var t_aud: rtos.Thread = undefined;
var t_prod: [4]*rtos.Thread = undefined;
var t_work: [4]*rtos.Thread = undefined;
var t_wrt: [2]*rtos.Thread = undefined;

pub fn main() void {
    board.uart.init();
    board.led.init();
    rtos.run(osMain);
}

fn osMain() void {
    console("\n+== " ++ board.banner_short ++ " µOS++ SMP PIPELINE TEST (" ++ board.banner_isa ++ ") ==+\n", .{});
    console("13 threads, {d} cores, shared queues, SD-card persistence & yield() stress\n\n", .{ncpu});

    sdPrepare();

    _ = rtos.interrupts.UncriticalSection.enter();
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    console("join: {s} ({d} ms)\n", .{ board.smp.joinSummary(), waited });

    const gpa = uos.memory.allocator();
    t_tel.init("telemetry", telemetryThread, null, .{ .stack = &s_tel_stk, .priority = rtos.priority.high }, gpa) catch unreachable;
    t_led.init("led", ledThread, null, .{ .stack = &s_led_stk, .priority = rtos.priority.above_normal }, gpa) catch unreachable;
    const prod_names = [_][:0]const u8{ "prod0", "prod1", "prod2", "prod3" };
    for (0..4) |i| t_prod[i] = rtos.Thread.create(gpa, prod_names[i], producerThread, @ptrFromInt(i), .{ .stack = &s_prod_stk[i], .priority = rtos.priority.normal }) catch unreachable;
    const work_names = [_][:0]const u8{ "work0", "work1", "work2", "work3" };
    for (0..4) |i| t_work[i] = rtos.Thread.create(gpa, work_names[i], workerThread, @ptrFromInt(i), .{ .stack = &s_work_stk[i], .priority = rtos.priority.normal }) catch unreachable;
    const wrt_names = [_][:0]const u8{ "sdwrt0", "sdwrt1" };
    for (0..2) |i| t_wrt[i] = rtos.Thread.create(gpa, wrt_names[i], sdWriterThread, @ptrFromInt(i), .{ .stack = &s_wrt_stk[i], .priority = rtos.priority.normal }) catch unreachable;
    t_aud.init("auditor", sdAuditorThread, null, .{ .stack = &s_aud_stk, .priority = rtos.priority.normal }, gpa) catch unreachable;

    console("13 pipeline threads successfully started!\n", .{});
    console("running pipeline for {d} ms ...\n", .{run_ms});
    const start_ms: u32 = @truncate(sysclock.now());
    while (@as(u32, @truncate(sysclock.now())) -% start_ms < run_ms) sysclock.sleepFor(200) catch {};

    // Stop the threads.
    console("\nstopping pipeline threads...\n", .{});
    g_finish.store(true, .monotonic);
    sysclock.sleepFor(200) catch {};
    // Release the blocked ones.
    for (0..32) |_| {
        g_in_spaces.post() catch {};
        g_in_items.post() catch {};
        g_sd_spaces.post() catch {};
        g_sd_items.post() catch {};
        g_audit_sem.post() catch {};
    }
    sysclock.sleepFor(200) catch {};

    const prod_total = g_total_produced.load(.monotonic);
    const proc_total = g_total_processed.load(.monotonic);
    const wrt_total = g_total_written.load(.monotonic);
    const aud_total = g_total_audited.load(.monotonic);
    const y_prod = g_yield_prod.load(.monotonic);
    const y_work = g_yield_work.load(.monotonic);
    const y_comp = g_yield_compute.load(.monotonic);
    const y_wrt = g_yield_writer.load(.monotonic);
    const y_aud = g_yield_auditor.load(.monotonic);
    const y_all = y_prod +% y_work +% y_comp +% y_wrt +% y_aud;
    const crc_err = g_crc_errors.load(.monotonic);
    const seq_err = g_seq_errors.load(.monotonic);
    const wrt_err = g_write_errors.load(.monotonic);

    console("\n================ Pipeline Test Summary ================\n", .{});
    console("Records Produced:  {d}\n", .{prod_total});
    console("Records Processed: {d}\n", .{proc_total});
    console("Records Written:   {d}\n", .{wrt_total});
    console("Records Audited:   {d}\n", .{aud_total});
    console("Errors: CRC={d}, Sequence={d}, Write={d}\n", .{ crc_err, seq_err, wrt_err });
    console("Yield Calls Breakdown:\n", .{});
    console("  Producer yield backpressure: {d}\n", .{y_prod});
    console("  Worker queue wait yields:    {d}\n", .{y_work});
    console("  Compute chunking yields:     {d}\n", .{y_comp});
    console("  SD writer turn yields:       {d}\n", .{y_wrt});
    console("  Auditor chunk read yields:   {d}\n", .{y_aud});
    console("  Total yield() calls:         {d}\n", .{y_all});
    console("Yields by Core: c0={d} c1={d} c2={d} c3={d}\n", .{ g_yield_by_core[0].load(.monotonic), g_yield_by_core[1].load(.monotonic), g_yield_by_core[2].load(.monotonic), g_yield_by_core[3].load(.monotonic) });
    console("Produced by Core: c0={d} c1={d} c2={d} c3={d}\n", .{ g_prod_by_core[0].load(.monotonic), g_prod_by_core[1].load(.monotonic), g_prod_by_core[2].load(.monotonic), g_prod_by_core[3].load(.monotonic) });
    console("Processed by Core: c0={d} c1={d} c2={d} c3={d}\n", .{ g_proc_by_core[0].load(.monotonic), g_proc_by_core[1].load(.monotonic), g_proc_by_core[2].load(.monotonic), g_proc_by_core[3].load(.monotonic) });
    console("=======================================================\n", .{});

    var any_proc = false;
    for (&g_proc_by_core) |*c| any_proc = any_proc or c.load(.monotonic) > 0;
    const pass = aud_total >= 20 and crc_err == 0 and seq_err == 0 and wrt_err == 0 and y_all >= 50 and any_proc;
    board.uart.puts(if (pass) "\nRESULT: PASS\n" else "\nRESULT: FAIL\n");
    if (pass) board.hw_result.ok() else board.hw_result.fail();
}
