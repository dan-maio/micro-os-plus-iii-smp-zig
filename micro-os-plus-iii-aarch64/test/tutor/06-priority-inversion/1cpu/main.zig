//! tutor-06-priority-inversion-1cpu -- lesson 06, one CPU (see ../README.md). *
//! L (low) locks the mutex and works 20 ms in its critical section, sorting
//! the shared list; once it holds the mutex, H (high) asks for it and M
//! (normal) computes 100 ms without touching it. What decides how long H
//! waits is whether M can run while L holds the mutex:
//!
//!   none     M preempts L: H waits M's 100 ms and the rest of L's section --
//!            the high thread is held up by a medium one (priority inversion);
//!   inherit  L takes H's priority as soon as H blocks: M cannot preempt it,
//!            and H waits at most the rest of one critical section;
//!   protect  L runs at the mutex's ceiling (high) from the moment it locks:
//!            the same bound.
//!  
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/06-priority-inversion/1cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const Sample = tutor.Sample;
const sysclock = rtos.sysclock;
const second_timer = tutor.second_timer;
const prio = rtos.priority;

pub const uos_options = board.options(1);

const four = false;
const seed: u32 = 2026;
const cs_us: u32 = 20000; // L's critical section: 20 ms
const medium_us: u32 = 100000; // M's work: 100 ms

// ---- The shared list: 72 samples in the data segment --------------------------

const n_shared = 72;
var g_shared: [n_shared]Sample = @splat(.{});
var g_list: tutor.SampleList = .{};
var g_mx: *rtos.Mutex = undefined; // the scenario's mutex

// ---- The three threads ----------------------------------------------------------

const Record = struct {
    locked: bool = false, // L holds the mutex
    l_unlock_us: u32 = 0, // L released it
    l_max: rtos.Priority = 0, // the highest priority L ran at while holding it
    l_sorts: u32 = 0, // the sorts L did in its critical section
    h_try_us: u32 = 0, // H asked for the mutex
    h_got_us: u32 = 0, // H got it
    m_start_us: u32 = 0, // M's work
    m_end_us: u32 = 0,
};
var g_rec: Record = .{};
var g_done: *rtos.Semaphore = undefined;

// L: locks the mutex and works 20 ms in its critical section -- sorting the
// shared list again and again, never blocking.
fn lowFunc(_: ?*anyopaque) ?*anyopaque {
    g_mx.lock() catch {};
    @as(*volatile bool, &g_rec.locked).* = true;
    const t0 = second_timer.nowUs();
    const self = rtos.this_thread.thread();
    var mx_prio = self.priority();
    while (second_timer.nowUs() -% t0 < cs_us) {
        // Scramble the order a little, then sort it back.
        if (g_list.head) |h| {
            if (h.next) |second| {
                g_list.head = second;
                h.next = null;
                var t = second;
                while (t.next) |nx| t = nx;
                t.next = h;
            }
        }
        tutor.sortList(&g_list);
        g_rec.l_sorts += 1;
        mx_prio = @max(mx_prio, self.priority());
    }
    g_rec.l_max = mx_prio;
    g_rec.l_unlock_us = second_timer.nowUs();
    g_mx.unlock() catch {};
    g_done.post() catch {};
    return null;
}

// H: asks for the mutex, and is blocked until L releases it.
fn highFunc(_: ?*anyopaque) ?*anyopaque {
    g_rec.h_try_us = second_timer.nowUs();
    g_mx.lock() catch {};
    g_rec.h_got_us = second_timer.nowUs();
    g_mx.unlock() catch {};
    g_done.post() catch {};
    return null;
}

// M: 100 ms of computing that never touches the mutex.
fn mediumFunc(_: ?*anyopaque) ?*anyopaque {
    g_rec.m_start_us = second_timer.nowUs();
    while (second_timer.nowUs() -% g_rec.m_start_us < medium_us) {}
    g_rec.m_end_us = second_timer.nowUs();
    g_done.post() catch {};
    return null;
}

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: *const fn (?*anyopaque) ?*anyopaque, p: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = p, .stack_size_bytes = 8 * 1024 };
    if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    return rtos.Thread.create(gpa, name, f, null, attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

fn protocolName(p: rtos.mutex.Protocol) []const u8 {
    return switch (p) {
        .none => "none",
        .inherit => "inherit",
        .protect => "protect",
    };
}

fn prioName(p: rtos.Priority) []const u8 {
    return if (p == prio.low) "low" else if (p == prio.normal) "normal" else if (p == prio.high) "high" else "other";
}

// One scenario: L locks, then H asks while M computes. Returns H's wait in µs.
fn run(gpa: std.mem.Allocator, protocol: rtos.mutex.Protocol, core_l: ?u32, core_m: ?u32, core_h: ?u32, where: []const u8) u32 {
    // The ceiling is used by protect.
    var mx: rtos.Mutex = .initWith("shared", .{ .protocol = protocol, .priority_ceiling = prio.high });
    g_mx = &mx;
    var done: rtos.Semaphore = .counting("done", 3, 0);
    g_done = &done;
    g_rec = .{};

    // L first, alone: the main thread (realtime) sleeps until L holds it.
    const tl = spawn(gpa, "L", lowFunc, prio.low, core_l);
    while (!@as(*volatile bool, &g_rec.locked).*) sysclock.sleepFor(1) catch {};
    // Then H and M together, while L is in its critical section.
    const th = spawn(gpa, "H", highFunc, prio.high, core_h);
    const tm = spawn(gpa, "M", mediumFunc, prio.normal, core_m);
    for (0..3) |_| done.wait() catch {};
    for ([_]*rtos.Thread{ tl, th, tm }) |t| {
        _ = t.join() catch null;
        t.destroy();
    }

    const wait = g_rec.h_got_us -% g_rec.h_try_us;
    const m_inside = g_rec.m_start_us < g_rec.h_got_us; // M ran while H waited
    board.console("  {s: <8} {s: <26} H waited {d: >6} us; L at {s} while holding, {d} sorts; M {s}\n", .{
        protocolName(protocol), where, wait, prioName(g_rec.l_max), g_rec.l_sorts, if (m_inside) "ran while H waited" else "ran after H",
    });
    return wait;
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("06 priority inversion");
    board.console(if (four) "Lesson 06, four CPUs: priority inversion, and the protocols that bound it.\n" else "Lesson 06, one CPU: priority inversion, and the protocols that bound it.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();
    // The bounds on the board; under QEMU looser (its cores are not real-time).
    const slack_us: u32 = if (tutor.onHardware()) 2000 else 20000;

    for (&g_shared, 0..) |*s, i| {
        const id: u32 = @intCast(i);
        s.init(id, tutor.generate(seed, id), .data);
        g_list.push(s);
    }
    const want = tutor.reference(seed, 0, n_shared).sorted_checksum;

    // The main thread above the three, so that it orchestrates.
    self.setPriority(prio.realtime) catch {};
    board.console("\n-- L (low) holds the mutex {d} ms; H (high) asks for it; M (normal) computes {d} ms\n", .{ cs_us / 1000, medium_us / 1000 });
    const bounded = cs_us + slack_us;
    const w_none = run(gpa, .none, null, null, null, "");
    const p_none = g_rec.l_max;
    const w_inh = run(gpa, .inherit, null, null, null, "");
    const p_inh = g_rec.l_max;
    const w_pro = run(gpa, .protect, null, null, null, "");
    const p_pro = g_rec.l_max;
    _ = tutor.check(w_none >= medium_us, "none: H waited M's whole {d} ms (priority inversion)", .{medium_us / 1000});
    _ = tutor.check(w_inh <= bounded, "inherit: H waited at most one critical section ({d} ms)", .{cs_us / 1000});
    _ = tutor.check(w_pro <= bounded, "protect: H waited at most one critical section", .{});
    _ = tutor.check(p_none == prio.low and p_inh == prio.high and p_pro == prio.high, "L ran at low with none, at high with inherit (H's) and with protect (the ceiling)", .{});

    tutor.sortList(&g_list);
    _ = tutor.check(g_list.count() == n_shared and tutor.checksum(g_list) == want, "the shared list intact after every scenario ({d} samples, checksum exact)", .{n_shared});
    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish("none lets M invert H; inherit and protect bound H to one critical section; one CPU");
}
