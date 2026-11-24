//! The µOS++ C API (`os-c-api.h`, the C++ `os-c-wrapper.cpp`).
//!
//! A thin layer over the Zig RTOS: every function converts its C arguments
//! and calls the Zig object; there is no logic of its own. The symbols are
//! exported only with `Options.c_api`.
//!
//! The C objects (`os_thread_t`, `os_mutex_t`, ...) are opaque storage
//! declared in include/cmsis-plus/rtos/os-c-decls.h, in pointer words; the
//! Zig object lives at its start. c_storage.zig repeats those sizes and
//! the build fails when a Zig object does not fit.
//!
//! Threads and timers run C functions: the Zig object then calls a
//! trampoline, and the C function and its argument are kept in the storage
//! after the Zig object (`Tail`).

const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");
const port = @import("uos_port");
const memory = @import("memory.zig");
const rtos = @import("rtos.zig");

const Error = rtos.Error;
const Thread = rtos.Thread;
const Stack = rtos.ThreadStack;
const Clock = rtos.Clock;
const Mutex = rtos.Mutex;
const ConditionVariable = rtos.ConditionVariable;
const Semaphore = rtos.Semaphore;
const EventFlags = rtos.EventFlags;
const MessageQueue = rtos.MessageQueue;
const MemoryPool = rtos.MemoryPool;
const Timer = rtos.Timer;
const scheduler = rtos.scheduler;
const interrupts = rtos.interrupts;
const this_thread = rtos.this_thread;
const flags = rtos.flags;
const FirstFitTop = memory.FirstFitTop;

comptime {
    if (config.options.c_api) {
        for (@typeInfo(api).@"struct".decl_names) |decl| {
            @export(&@field(api, decl), .{ .name = decl });
        }
    }
}

// ----------------------------------------------------------------------------
// Storage.

/// The storage sizes: the defaults (c_storage.zig), or the port's, when it
/// raises them (`uos_port.c_storage_words`, matching its
/// cmsis-plus/rtos/port/os-c-storage.h).
pub const storage_words = struct {
    const defaults = @import("c_storage.zig").words;
    const overrides = if (@hasDecl(port, "c_storage_words")) port.c_storage_words else struct {};

    fn get(comptime field: []const u8) usize {
        return if (@hasDecl(overrides, field)) @field(overrides, field) else @field(defaults, field);
    }

    pub const thread = get("thread");
    pub const timer = get("timer");
    pub const mutex = get("mutex");
    pub const condvar = get("condvar");
    pub const semaphore = get("semaphore");
    pub const mempool = get("mempool");
    pub const mqueue = get("mqueue");
    pub const evflags = get("evflags");
};

const storage_align = 8;

pub fn storageBytes(comptime words: usize) usize {
    return words * @sizeOf(usize);
}

fn checkFits(comptime c_name: []const u8, comptime words: usize, comptime bytes: usize, comptime alignment: usize) void {
    if (bytes > storageBytes(words)) @compileError(std.fmt.comptimePrint(
        "{s}: the Zig object needs {d} bytes, the C storage has {d} ({d} words); raise OS_C_*_STORAGE_WORDS (os-c-decls.h and c_storage.zig, or the port's os-c-storage.h and c_storage_words)",
        .{ c_name, bytes, storageBytes(words), words },
    ));
    if (alignment > storage_align) @compileError(c_name ++ ": the Zig object needs a larger alignment than the C storage");
}

/// A Zig object followed by C data, in one C storage.
fn Tail(comptime T: type, comptime X: type) type {
    return struct {
        const offset = std.mem.alignForward(usize, @sizeOf(T), @alignOf(X));
        const size = offset + @sizeOf(X);

        pub fn of(obj: *T) *X {
            return @ptrFromInt(@intFromPtr(obj) + offset);
        }
    };
}

pub const CThreadFunc = *const fn (args: ?*anyopaque) callconv(.c) ?*anyopaque;
/// A CMSIS-RTOS v1 thread function (`os_pthread`).
pub const V1ThreadFunc = *const fn (args: ?*const anyopaque) callconv(.c) void;
pub const CTimerFunc = *const fn (args: ?*anyopaque) callconv(.c) void;

pub const ThreadFunc = union(enum) { c: CThreadFunc, v1: V1ThreadFunc };
pub const ThreadTail = Tail(Thread, struct { func: ThreadFunc, args: ?*anyopaque });
pub const TimerTail = Tail(Timer, struct { func: CTimerFunc, args: ?*anyopaque });

comptime {
    if (config.options.c_api) {
        checkFits("os_thread_t", storage_words.thread, ThreadTail.size, @alignOf(Thread));
        checkFits("os_timer_t", storage_words.timer, TimerTail.size, @alignOf(Timer));
        checkFits("os_mutex_t", storage_words.mutex, @sizeOf(Mutex), @alignOf(Mutex));
        checkFits("os_condvar_t", storage_words.condvar, @sizeOf(ConditionVariable), @alignOf(ConditionVariable));
        checkFits("os_semaphore_t", storage_words.semaphore, @sizeOf(Semaphore), @alignOf(Semaphore));
        checkFits("os_mempool_t", storage_words.mempool, @sizeOf(MemoryPool), @alignOf(MemoryPool));
        checkFits("os_mqueue_t", storage_words.mqueue, @sizeOf(MessageQueue), @alignOf(MessageQueue));
        checkFits("os_evflags_t", storage_words.evflags, @sizeOf(EventFlags), @alignOf(EventFlags));
    }
}

/// Storage for the `os_*_new()` objects, from the system heap.
pub fn newStorage(comptime T: type, comptime words: usize) ?*T {
    const bytes = memory.allocator().alignedAlloc(u8, .fromByteUnits(storage_align), storageBytes(words)) catch return null;
    return @ptrCast(bytes.ptr);
}

pub fn freeStorage(obj: anytype, comptime words: usize) void {
    const p: [*]align(storage_align) u8 = @ptrCast(@alignCast(obj));
    memory.allocator().free(p[0..storageBytes(words)]);
}

// ----------------------------------------------------------------------------
// Conversions.

pub const os_result_t = u32;
const os_ok: os_result_t = 0;

fn result(r: Error!void) os_result_t {
    r catch |err| return @intCast(rtos.errno(err));
    return os_ok;
}

pub fn name(n: ?[*:0]const u8) [:0]const u8 {
    return if (n) |p| std.mem.span(p) else "-";
}

pub fn clockOf(c: ?*anyopaque) ?*Clock {
    return @ptrCast(@alignCast(c));
}

fn mode(m: u32) flags.Mode {
    return @bitCast(m);
}

/// A constructor failed: as the C++ wrapper (an assert there), stop.
pub fn failed(comptime what: []const u8, err: Error) noreturn {
    std.debug.panic(what ++ "() failed: {s}", .{@errorName(err)});
}

fn irqState(s: interrupts.State) u32 {
    return switch (@typeInfo(interrupts.State)) {
        .bool => @intFromBool(s),
        .int => @intCast(s),
        else => @compileError("unsupported interrupts state type"),
    };
}

fn fromIrqState(s: u32) interrupts.State {
    return switch (@typeInfo(interrupts.State)) {
        .bool => s != 0,
        .int => @intCast(s),
        else => @compileError("unsupported interrupts state type"),
    };
}

/// A C buffer as a slice aligned for `T`: the start rounded up, the size
/// reduced by as much.
pub fn alignedBuffer(comptime alignment: usize, address: *anyopaque, size_bytes: usize) []align(alignment) u8 {
    const raw = @intFromPtr(address);
    const start = std.mem.alignForward(usize, raw, alignment);
    const len = size_bytes -| (start - raw);
    const p: [*]align(alignment) u8 = @ptrFromInt(start);
    return p[0..len];
}

// ----------------------------------------------------------------------------
// The C attributes (os-c-decls.h).

pub const ThreadAttr = extern struct {
    clock: ?*anyopaque = null,
    th_stack_address: ?*anyopaque = null,
    th_stack_size_bytes: usize = 0,
    th_priority: u8 = rtos.priority.normal,
    th_enable_assert_reuse: bool = false,
    th_cpu_affinity: u32 = 0xFFFF_FFFF,
};

const TimerAttr = extern struct {
    clock: ?*anyopaque = null,
    tm_type: u8 = @intFromEnum(rtos.timer.Run.once),
};

const MutexAttr = extern struct {
    clock: ?*anyopaque = null,
    mx_priority_ceiling: u8 = rtos.priority.highest,
    mx_protocol: u8 = @intFromEnum(rtos.mutex.Protocol.inherit),
    mx_robustness: u8 = @intFromEnum(rtos.mutex.Robustness.stalled),
    mx_type: u8 = @intFromEnum(rtos.mutex.Type.normal),
    mx_max_count: i16 = 0x7FFF,
};

const CondvarAttr = extern struct {
    clock: ?*anyopaque = null,
};

const SemaphoreAttr = extern struct {
    clock: ?*anyopaque = null,
    sm_max_value: i16 = 1,
    sm_initial_value: i16 = 0,
};

pub const MempoolAttr = extern struct {
    clock: ?*anyopaque = null,
    mp_pool_address: ?*anyopaque = null,
    mp_pool_size_bytes: usize = 0,
};

pub const MqueueAttr = extern struct {
    clock: ?*anyopaque = null,
    mq_queue_addr: ?*anyopaque = null,
    mq_queue_size_bytes: usize = 0,
};

const EvflagsAttr = extern struct {
    clock: ?*anyopaque = null,
};

const timer_periodic_attr: TimerAttr = .{ .tm_type = @intFromEnum(rtos.timer.Run.periodic) };
const mutex_recursive_attr: MutexAttr = .{ .mx_type = @intFromEnum(rtos.mutex.Type.recursive) };
const semaphore_binary_attr: SemaphoreAttr = .{ .sm_max_value = 1, .sm_initial_value = 0 };

fn mutexAttributes(a: *const MutexAttr) rtos.mutex.Attributes {
    return .{
        .priority_ceiling = a.mx_priority_ceiling,
        .protocol = @enumFromInt(a.mx_protocol),
        .robustness = @enumFromInt(a.mx_robustness),
        .type = @enumFromInt(a.mx_type),
        .max_count = if (a.mx_max_count > 0) @intCast(a.mx_max_count) else 1,
        .clock = clockOf(a.clock),
    };
}

// ----------------------------------------------------------------------------
// Trampolines.

fn threadTrampoline(args: ?*anyopaque) ?*anyopaque {
    const th: *Thread = @ptrCast(@alignCast(args.?));
    const tail = ThreadTail.of(th);
    switch (tail.func) {
        .c => |f| return f(tail.args),
        .v1 => |f| {
            f(tail.args);
            return null;
        },
    }
}

pub fn timerTrampoline(args: ?*anyopaque) void {
    const tm: *Timer = @ptrCast(@alignCast(args.?));
    const tail = TimerTail.of(tm);
    tail.func(tail.args);
}

pub fn constructThread(th: *Thread, n: ?[*:0]const u8, func: ThreadFunc, args: ?*anyopaque, attr: ?*const ThreadAttr) Error!void {
    const a: *const ThreadAttr = attr orelse &.{};
    var za: Thread.Attributes = .{
        .stack_size_bytes = a.th_stack_size_bytes,
        .priority = a.th_priority,
        .clock = clockOf(a.clock),
        .cpu_affinity = a.th_cpu_affinity,
    };
    if (a.th_stack_address) |address| {
        const buf = alignedBuffer(@alignOf(port.StackElement), address, a.th_stack_size_bytes);
        za.stack = std.mem.bytesAsSlice(port.StackElement, buf[0 .. buf.len / @sizeOf(port.StackElement) * @sizeOf(port.StackElement)]);
    }
    ThreadTail.of(th).* = .{ .func = func, .args = args };
    try th.init(name(n), threadTrampoline, th, za, memory.allocator());
}

fn freeNewThread(th: *Thread) void {
    freeStorage(th, storage_words.thread);
}

pub fn constructMempool(mp: *MemoryPool, n: ?[*:0]const u8, blocks: usize, block_size_bytes: usize, attr: ?*const MempoolAttr) Error!void {
    const a: *const MempoolAttr = attr orelse &.{};
    const za: rtos.mempool.Attributes = .{ .clock = clockOf(a.clock) };
    if (a.mp_pool_address) |address| {
        try mp.init(name(n), blocks, block_size_bytes, alignedBuffer(@alignOf(usize), address, a.mp_pool_size_bytes), za);
    } else {
        try mp.create(memory.allocator(), name(n), blocks, block_size_bytes, za);
    }
}

pub fn constructMqueue(mq: *MessageQueue, n: ?[*:0]const u8, msgs: usize, msg_size_bytes: usize, attr: ?*const MqueueAttr) Error!void {
    const a: *const MqueueAttr = attr orelse &.{};
    const za: rtos.mqueue.Attributes = .{ .clock = clockOf(a.clock) };
    if (a.mq_queue_addr) |address| {
        const p: [*]u8 = @ptrCast(address);
        try mq.init(name(n), msgs, msg_size_bytes, p[0..a.mq_queue_size_bytes], za);
    } else {
        try mq.create(memory.allocator(), name(n), msgs, msg_size_bytes, za);
    }
}

var irq_stack: Stack = .{};

fn heapOf(m: *anyopaque) *FirstFitTop {
    return @ptrCast(@alignCast(m));
}

// ----------------------------------------------------------------------------
// The exported functions, in the order of os-c-api.h.

const api = struct {
    // ---- Scheduler ----------------------------------------------------------

    pub fn os_sched_initialize() callconv(.c) os_result_t {
        return result(scheduler.initialize());
    }

    pub fn os_sched_start() callconv(.c) noreturn {
        scheduler.start();
    }

    pub fn os_sched_is_started() callconv(.c) bool {
        return scheduler.started();
    }

    pub fn os_sched_lock() callconv(.c) bool {
        return scheduler.lock();
    }

    pub fn os_sched_unlock() callconv(.c) bool {
        return scheduler.unlock();
    }

    pub fn os_sched_set_locked(state: bool) callconv(.c) bool {
        return scheduler.setLocked(state);
    }

    pub fn os_sched_is_locked() callconv(.c) bool {
        return scheduler.locked();
    }

    pub fn os_sched_is_preemptive() callconv(.c) bool {
        return scheduler.isPreemptive();
    }

    pub fn os_sched_set_preemptive(state: bool) callconv(.c) bool {
        return scheduler.preemptive(state) catch scheduler.isPreemptive();
    }

    pub fn os_sched_stat_get_context_switches() callconv(.c) u64 {
        return scheduler.statistics.context_switches;
    }

    pub fn os_sched_stat_get_cpu_cycles() callconv(.c) u64 {
        return scheduler.statistics.cpu_cycles;
    }

    // ---- Interrupts ---------------------------------------------------------

    pub fn os_irq_in_handler_mode() callconv(.c) bool {
        return interrupts.inHandlerMode();
    }

    pub fn os_irq_critical_enter() callconv(.c) u32 {
        return irqState(port.interrupts.criticalEnter());
    }

    pub fn os_irq_critical_exit(state: u32) callconv(.c) void {
        port.interrupts.criticalExit(fromIrqState(state));
    }

    pub fn os_irq_uncritical_enter() callconv(.c) u32 {
        return irqState(port.interrupts.uncriticalEnter());
    }

    pub fn os_irq_uncritical_exit(state: u32) callconv(.c) void {
        port.interrupts.uncriticalExit(fromIrqState(state));
    }

    pub fn os_irq_get_stack() callconv(.c) ?*Stack {
        const s = interrupts.stack() orelse return null;
        irq_stack.set(s.ptr, s.len * @sizeOf(port.StackElement));
        return &irq_stack;
    }

    // ---- The current thread -------------------------------------------------

    pub fn os_this_thread() callconv(.c) *Thread {
        return this_thread.thread();
    }

    pub fn os_this_thread_suspend() callconv(.c) void {
        this_thread.@"suspend"();
    }

    pub fn os_this_thread_exit(exit_ptr: ?*anyopaque) callconv(.c) noreturn {
        this_thread.exit(exit_ptr);
    }

    pub fn os_this_thread_flags_wait(mask: u32, oflags: ?*u32, m: u32) callconv(.c) os_result_t {
        const f = this_thread.flagsWait(mask, mode(m)) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_this_thread_flags_try_wait(mask: u32, oflags: ?*u32, m: u32) callconv(.c) os_result_t {
        const f = this_thread.flagsTryWait(mask, mode(m)) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_this_thread_flags_timed_wait(mask: u32, timeout: u32, oflags: ?*u32, m: u32) callconv(.c) os_result_t {
        const f = this_thread.flagsTimedWait(mask, timeout, mode(m)) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_this_thread_flags_clear(mask: u32, oflags: ?*u32) callconv(.c) os_result_t {
        const f = this_thread.flagsClear(mask) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_this_thread_flags_get(mask: u32, m: u32) callconv(.c) u32 {
        return this_thread.flagsGet(mask, mode(m));
    }

    // ---- Threads ------------------------------------------------------------

    pub fn os_thread_attr_init(attr: *ThreadAttr) callconv(.c) void {
        attr.* = .{};
    }

    pub fn os_thread_construct(th: *Thread, n: ?[*:0]const u8, func: CThreadFunc, args: ?*anyopaque, attr: ?*const ThreadAttr) callconv(.c) void {
        constructThread(th, n, .{ .c = func }, args, attr) catch |err| failed("os_thread_construct", err);
    }

    pub fn os_thread_destruct(th: *Thread) callconv(.c) void {
        th.deinit();
    }

    pub fn os_thread_new(n: ?[*:0]const u8, func: CThreadFunc, args: ?*anyopaque, attr: ?*const ThreadAttr) callconv(.c) ?*Thread {
        const th = newStorage(Thread, storage_words.thread) orelse return null;
        constructThread(th, n, .{ .c = func }, args, attr) catch |err| {
            freeNewThread(th);
            failed("os_thread_new", err);
        };
        th.free_self = freeNewThread;
        return th;
    }

    pub fn os_thread_delete(th: *Thread) callconv(.c) void {
        th.destroy();
    }

    pub fn os_thread_is_constructed(th: *Thread) callconv(.c) bool {
        return th.isConstructed();
    }

    pub fn os_thread_get_name(th: *Thread) callconv(.c) [*:0]const u8 {
        return th.name.ptr;
    }

    pub fn os_thread_get_priority(th: *Thread) callconv(.c) u8 {
        return th.priority();
    }

    pub fn os_thread_set_priority(th: *Thread, prio: u8) callconv(.c) os_result_t {
        return result(th.setPriority(prio));
    }

    pub fn os_thread_kill(th: *Thread) callconv(.c) os_result_t {
        return result(th.kill());
    }

    pub fn os_thread_join(th: *Thread, exit_ptr: ?*?*anyopaque) callconv(.c) os_result_t {
        const r = th.join() catch |err| return result(err);
        if (exit_ptr) |p| p.* = r;
        return os_ok;
    }

    pub fn os_thread_resume(th: *Thread) callconv(.c) void {
        th.@"resume"();
    }

    pub fn os_thread_flags_raise(th: *Thread, mask: u32, oflags: ?*u32) callconv(.c) os_result_t {
        const f = th.flagsRaise(mask) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_thread_get_state(th: *Thread) callconv(.c) u8 {
        return @intFromEnum(th.getState());
    }

    pub fn os_thread_get_stack(th: *Thread) callconv(.c) *Stack {
        return th.stack();
    }

    pub fn os_thread_stack_get_default_size() callconv(.c) usize {
        return Stack.default_size_bytes;
    }

    pub fn os_thread_stack_set_default_size(size_bytes: usize) callconv(.c) usize {
        const old = Stack.default_size_bytes;
        Stack.default_size_bytes = size_bytes;
        return old;
    }

    pub fn os_thread_stack_get_min_size() callconv(.c) usize {
        return Stack.min_size_bytes;
    }

    pub fn os_thread_stack_set_min_size(size_bytes: usize) callconv(.c) usize {
        const old = Stack.min_size_bytes;
        Stack.min_size_bytes = size_bytes;
        return old;
    }

    pub fn os_thread_stack_get_bottom(st: *Stack) callconv(.c) [*]port.StackElement {
        return st.bottom();
    }

    pub fn os_thread_stack_get_top(st: *Stack) callconv(.c) [*]port.StackElement {
        return st.top();
    }

    pub fn os_thread_stack_get_size(st: *Stack) callconv(.c) usize {
        return st.size();
    }

    pub fn os_thread_stack_get_available(st: *Stack) callconv(.c) usize {
        return st.available();
    }

    pub fn os_thread_stack_check_bottom_magic(st: *Stack) callconv(.c) bool {
        return st.checkBottomMagic();
    }

    pub fn os_thread_stack_check_top_magic(st: *Stack) callconv(.c) bool {
        return st.checkTopMagic();
    }

    pub fn os_thread_stat_get_context_switches(th: *Thread) callconv(.c) u64 {
        return th.statistics.context_switches;
    }

    pub fn os_thread_stat_get_cpu_cycles(th: *Thread) callconv(.c) u64 {
        return th.statistics.cpu_cycles;
    }

    // The children of a thread (the top threads for NULL), walked through
    // their `child_links`; the iterator is the links address.

    pub fn os_children_threads_iter_begin(th: ?*Thread) callconv(.c) *anyopaque {
        const list = scheduler.childrenThreads(th);
        return list.head.next orelse &list.head;
    }

    pub fn os_children_threads_iter_end(th: ?*Thread) callconv(.c) *anyopaque {
        return &scheduler.childrenThreads(th).head;
    }

    pub fn os_children_threads_iter_get(it: *anyopaque) callconv(.c) *Thread {
        const links: *rtos.lists.Links = @ptrCast(@alignCast(it));
        return @alignCast(@fieldParentPtr("child_links", links));
    }

    pub fn os_children_threads_iter_next(it: *anyopaque) callconv(.c) *anyopaque {
        const links: *rtos.lists.Links = @ptrCast(@alignCast(it));
        return links.next.?;
    }

    // ---- Clocks -------------------------------------------------------------

    pub fn os_clock_get_name(c: *Clock) callconv(.c) [*:0]const u8 {
        return c.name.ptr;
    }

    pub fn os_clock_now(c: *Clock) callconv(.c) u64 {
        return c.now();
    }

    pub fn os_clock_steady_now(c: *Clock) callconv(.c) u64 {
        return c.steadyNow();
    }

    pub fn os_clock_sleep_for(c: *Clock, duration: u32) callconv(.c) os_result_t {
        return result(c.sleepFor(duration));
    }

    pub fn os_clock_sleep_until(c: *Clock, timestamp: u64) callconv(.c) os_result_t {
        return result(c.sleepUntil(timestamp));
    }

    pub fn os_clock_wait_for(c: *Clock, timeout: u32) callconv(.c) os_result_t {
        return result(c.waitFor(timeout));
    }

    pub fn os_clock_get_offset(c: *Clock) callconv(.c) i64 {
        return c.getOffset();
    }

    pub fn os_clock_set_offset(c: *Clock, offset: i64) callconv(.c) i64 {
        return c.setOffset(offset);
    }

    pub fn os_clock_get_sysclock() callconv(.c) *Clock {
        return rtos.sysclock;
    }

    pub fn os_clock_get_rtclock() callconv(.c) *Clock {
        return rtos.rtclock;
    }

    pub fn os_clock_get_hrclock() callconv(.c) *Clock {
        return rtos.hrclock;
    }

    pub fn os_sysclock_now() callconv(.c) u64 {
        return rtos.sysclock.now();
    }

    pub fn os_sysclock_sleep_for(duration: u32) callconv(.c) os_result_t {
        return result(rtos.sysclock.sleepFor(duration));
    }

    pub fn os_sysclock_sleep_until(timestamp: u64) callconv(.c) os_result_t {
        return result(rtos.sysclock.sleepUntil(timestamp));
    }

    pub fn os_sysclock_wait_for(timeout: u32) callconv(.c) os_result_t {
        return result(rtos.sysclock.waitFor(timeout));
    }

    // ---- Timers -------------------------------------------------------------

    pub fn os_timer_attr_init(attr: *TimerAttr) callconv(.c) void {
        attr.* = .{};
    }

    pub fn os_timer_attr_periodic_init(attr: *TimerAttr) callconv(.c) void {
        attr.* = timer_periodic_attr;
    }

    pub fn os_timer_attr_get_periodic() callconv(.c) *const TimerAttr {
        return &timer_periodic_attr;
    }

    pub fn os_timer_construct(tm: *Timer, n: ?[*:0]const u8, func: CTimerFunc, args: ?*anyopaque, attr: ?*const TimerAttr) callconv(.c) void {
        const a: *const TimerAttr = attr orelse &.{};
        tm.* = .initWith(name(n), timerTrampoline, tm, .{ .type = @enumFromInt(a.tm_type), .clock = clockOf(a.clock) });
        TimerTail.of(tm).* = .{ .func = func, .args = args };
    }

    pub fn os_timer_destruct(tm: *Timer) callconv(.c) void {
        tm.deinit();
    }

    pub fn os_timer_new(n: ?[*:0]const u8, func: CTimerFunc, args: ?*anyopaque, attr: ?*const TimerAttr) callconv(.c) ?*Timer {
        const tm = newStorage(Timer, storage_words.timer) orelse return null;
        os_timer_construct(tm, n, func, args, attr);
        return tm;
    }

    pub fn os_timer_delete(tm: *Timer) callconv(.c) void {
        tm.deinit();
        freeStorage(tm, storage_words.timer);
    }

    pub fn os_timer_get_name(tm: *Timer) callconv(.c) [*:0]const u8 {
        return tm.name.ptr;
    }

    pub fn os_timer_start(tm: *Timer, period: u32) callconv(.c) os_result_t {
        return result(tm.start(period));
    }

    pub fn os_timer_stop(tm: *Timer) callconv(.c) os_result_t {
        return result(tm.stop());
    }

    // ---- Mutexes ------------------------------------------------------------

    pub fn os_mutex_attr_init(attr: *MutexAttr) callconv(.c) void {
        attr.* = .{};
    }

    pub fn os_mutex_attr_recursive_init(attr: *MutexAttr) callconv(.c) void {
        attr.* = mutex_recursive_attr;
    }

    pub fn os_mutex_attr_get_recursive() callconv(.c) *const MutexAttr {
        return &mutex_recursive_attr;
    }

    pub fn os_mutex_construct(mx: *Mutex, n: ?[*:0]const u8, attr: ?*const MutexAttr) callconv(.c) void {
        mx.init(name(n), mutexAttributes(attr orelse &.{})) catch |err| failed("os_mutex_construct", err);
    }

    pub fn os_mutex_recursive_construct(mx: *Mutex, n: ?[*:0]const u8, attr: ?*const MutexAttr) callconv(.c) void {
        var a = mutexAttributes(attr orelse &mutex_recursive_attr);
        a.type = .recursive;
        mx.init(name(n), a) catch |err| failed("os_mutex_recursive_construct", err);
    }

    pub fn os_mutex_destruct(mx: *Mutex) callconv(.c) void {
        mx.deinit();
    }

    pub fn os_mutex_new(n: ?[*:0]const u8, attr: ?*const MutexAttr) callconv(.c) ?*Mutex {
        const mx = newStorage(Mutex, storage_words.mutex) orelse return null;
        os_mutex_construct(mx, n, attr);
        return mx;
    }

    pub fn os_mutex_recursive_new(n: ?[*:0]const u8, attr: ?*const MutexAttr) callconv(.c) ?*Mutex {
        const mx = newStorage(Mutex, storage_words.mutex) orelse return null;
        os_mutex_recursive_construct(mx, n, attr);
        return mx;
    }

    pub fn os_mutex_delete(mx: *Mutex) callconv(.c) void {
        mx.deinit();
        freeStorage(mx, storage_words.mutex);
    }

    pub fn os_mutex_get_name(mx: *Mutex) callconv(.c) [*:0]const u8 {
        return mx.name.ptr;
    }

    pub fn os_mutex_lock(mx: *Mutex) callconv(.c) os_result_t {
        return result(mx.lock());
    }

    pub fn os_mutex_try_lock(mx: *Mutex) callconv(.c) os_result_t {
        return result(mx.tryLock());
    }

    pub fn os_mutex_timed_lock(mx: *Mutex, timeout: u32) callconv(.c) os_result_t {
        return result(mx.timedLock(timeout));
    }

    pub fn os_mutex_unlock(mx: *Mutex) callconv(.c) os_result_t {
        return result(mx.unlock());
    }

    pub fn os_mutex_get_prio_ceiling(mx: *Mutex) callconv(.c) u8 {
        return mx.getPriorityCeiling();
    }

    pub fn os_mutex_set_prio_ceiling(mx: *Mutex, prio_ceiling: u8, old_prio_ceiling: ?*u8) callconv(.c) os_result_t {
        const old = mx.setPriorityCeiling(prio_ceiling) catch |err| return result(err);
        if (old_prio_ceiling) |o| o.* = old;
        return os_ok;
    }

    pub fn os_mutex_mark_consistent(mx: *Mutex) callconv(.c) os_result_t {
        return result(mx.consistent());
    }

    pub fn os_mutex_get_owner(mx: *Mutex) callconv(.c) ?*Thread {
        return mx.getOwner();
    }

    pub fn os_mutex_get_type(mx: *Mutex) callconv(.c) u8 {
        return @intFromEnum(mx.getType());
    }

    pub fn os_mutex_get_protocol(mx: *Mutex) callconv(.c) u8 {
        return @intFromEnum(mx.protocol);
    }

    pub fn os_mutex_get_robustness(mx: *Mutex) callconv(.c) u8 {
        return @intFromEnum(mx.robustness);
    }

    pub fn os_mutex_reset(mx: *Mutex) callconv(.c) os_result_t {
        return result(mx.reset());
    }

    // ---- Condition variables ------------------------------------------------

    pub fn os_condvar_attr_init(attr: *CondvarAttr) callconv(.c) void {
        attr.* = .{};
    }

    pub fn os_condvar_construct(cv: *ConditionVariable, n: ?[*:0]const u8, attr: ?*const CondvarAttr) callconv(.c) void {
        const a: *const CondvarAttr = attr orelse &.{};
        cv.init(name(n), .{ .clock = clockOf(a.clock) }) catch |err| failed("os_condvar_construct", err);
    }

    pub fn os_condvar_destruct(cv: *ConditionVariable) callconv(.c) void {
        cv.deinit();
    }

    pub fn os_condvar_new(n: ?[*:0]const u8, attr: ?*const CondvarAttr) callconv(.c) ?*ConditionVariable {
        const cv = newStorage(ConditionVariable, storage_words.condvar) orelse return null;
        os_condvar_construct(cv, n, attr);
        return cv;
    }

    pub fn os_condvar_delete(cv: *ConditionVariable) callconv(.c) void {
        cv.deinit();
        freeStorage(cv, storage_words.condvar);
    }

    pub fn os_condvar_get_name(cv: *ConditionVariable) callconv(.c) [*:0]const u8 {
        return cv.name.ptr;
    }

    pub fn os_condvar_signal(cv: *ConditionVariable) callconv(.c) os_result_t {
        return result(cv.signal());
    }

    pub fn os_condvar_broadcast(cv: *ConditionVariable) callconv(.c) os_result_t {
        return result(cv.broadcast());
    }

    pub fn os_condvar_wait(cv: *ConditionVariable, mx: *Mutex) callconv(.c) os_result_t {
        return result(cv.wait(mx));
    }

    pub fn os_condvar_timed_wait(cv: *ConditionVariable, mx: *Mutex, timeout: u32) callconv(.c) os_result_t {
        return result(cv.timedWait(mx, timeout));
    }

    // ---- Semaphores ---------------------------------------------------------

    pub fn os_semaphore_attr_init(attr: *SemaphoreAttr) callconv(.c) void {
        attr.* = .{};
    }

    pub fn os_semaphore_attr_binary_init(attr: *SemaphoreAttr, initial_value: i16) callconv(.c) void {
        attr.* = .{ .sm_max_value = 1, .sm_initial_value = initial_value };
    }

    pub fn os_semaphore_attr_counting_init(attr: *SemaphoreAttr, max_value: i16, initial_value: i16) callconv(.c) void {
        attr.* = .{ .sm_max_value = max_value, .sm_initial_value = initial_value };
    }

    pub fn os_semaphore_attr_get_binary() callconv(.c) *const SemaphoreAttr {
        return &semaphore_binary_attr;
    }

    pub fn os_semaphore_construct(sem: *Semaphore, n: ?[*:0]const u8, attr: ?*const SemaphoreAttr) callconv(.c) void {
        const a: *const SemaphoreAttr = attr orelse &semaphore_binary_attr;
        sem.init(name(n), .{
            .initial_value = a.sm_initial_value,
            .max_value = a.sm_max_value,
            .clock = clockOf(a.clock),
        }) catch |err| failed("os_semaphore_construct", err);
    }

    pub fn os_semaphore_binary_construct(sem: *Semaphore, n: ?[*:0]const u8, initial_value: i16) callconv(.c) void {
        os_semaphore_construct(sem, n, &.{ .sm_max_value = 1, .sm_initial_value = initial_value });
    }

    pub fn os_semaphore_counting_construct(sem: *Semaphore, n: ?[*:0]const u8, max_value: i16, initial_value: i16) callconv(.c) void {
        os_semaphore_construct(sem, n, &.{ .sm_max_value = max_value, .sm_initial_value = initial_value });
    }

    pub fn os_semaphore_destruct(sem: *Semaphore) callconv(.c) void {
        sem.deinit();
    }

    pub fn os_semaphore_new(n: ?[*:0]const u8, attr: ?*const SemaphoreAttr) callconv(.c) ?*Semaphore {
        const sem = newStorage(Semaphore, storage_words.semaphore) orelse return null;
        os_semaphore_construct(sem, n, attr);
        return sem;
    }

    pub fn os_semaphore_binary_new(n: ?[*:0]const u8, initial_value: i16) callconv(.c) ?*Semaphore {
        const sem = newStorage(Semaphore, storage_words.semaphore) orelse return null;
        os_semaphore_binary_construct(sem, n, initial_value);
        return sem;
    }

    pub fn os_semaphore_counting_new(n: ?[*:0]const u8, max_value: i16, initial_value: i16) callconv(.c) ?*Semaphore {
        const sem = newStorage(Semaphore, storage_words.semaphore) orelse return null;
        os_semaphore_counting_construct(sem, n, max_value, initial_value);
        return sem;
    }

    pub fn os_semaphore_delete(sem: *Semaphore) callconv(.c) void {
        sem.deinit();
        freeStorage(sem, storage_words.semaphore);
    }

    pub fn os_semaphore_get_name(sem: *Semaphore) callconv(.c) [*:0]const u8 {
        return sem.name.ptr;
    }

    pub fn os_semaphore_post(sem: *Semaphore) callconv(.c) os_result_t {
        return result(sem.post());
    }

    pub fn os_semaphore_wait(sem: *Semaphore) callconv(.c) os_result_t {
        return result(sem.wait());
    }

    pub fn os_semaphore_try_wait(sem: *Semaphore) callconv(.c) os_result_t {
        return result(sem.tryWait());
    }

    pub fn os_semaphore_timed_wait(sem: *Semaphore, timeout: u32) callconv(.c) os_result_t {
        return result(sem.timedWait(timeout));
    }

    pub fn os_semaphore_get_value(sem: *Semaphore) callconv(.c) i16 {
        return sem.value();
    }

    pub fn os_semaphore_reset(sem: *Semaphore) callconv(.c) os_result_t {
        return result(sem.reset());
    }

    pub fn os_semaphore_get_initial_value(sem: *Semaphore) callconv(.c) i16 {
        return sem.initialValue();
    }

    pub fn os_semaphore_get_max_value(sem: *Semaphore) callconv(.c) i16 {
        return sem.maxValue();
    }

    // ---- Memory pools -------------------------------------------------------

    pub fn os_mempool_attr_init(attr: *MempoolAttr) callconv(.c) void {
        attr.* = .{};
    }

    pub fn os_mempool_construct(mp: *MemoryPool, n: ?[*:0]const u8, blocks: usize, block_size_bytes: usize, attr: ?*const MempoolAttr) callconv(.c) void {
        constructMempool(mp, n, blocks, block_size_bytes, attr) catch |err| failed("os_mempool_construct", err);
    }

    pub fn os_mempool_destruct(mp: *MemoryPool) callconv(.c) void {
        mp.deinit();
    }

    pub fn os_mempool_new(n: ?[*:0]const u8, blocks: usize, block_size_bytes: usize, attr: ?*const MempoolAttr) callconv(.c) ?*MemoryPool {
        const mp = newStorage(MemoryPool, storage_words.mempool) orelse return null;
        os_mempool_construct(mp, n, blocks, block_size_bytes, attr);
        return mp;
    }

    pub fn os_mempool_delete(mp: *MemoryPool) callconv(.c) void {
        mp.deinit();
        freeStorage(mp, storage_words.mempool);
    }

    pub fn os_mempool_get_name(mp: *MemoryPool) callconv(.c) [*:0]const u8 {
        return mp.name.ptr;
    }

    pub fn os_mempool_alloc(mp: *MemoryPool) callconv(.c) ?*anyopaque {
        return mp.alloc() catch null;
    }

    pub fn os_mempool_try_alloc(mp: *MemoryPool) callconv(.c) ?*anyopaque {
        return mp.tryAlloc() catch null;
    }

    pub fn os_mempool_timed_alloc(mp: *MemoryPool, timeout: u32) callconv(.c) ?*anyopaque {
        return mp.timedAlloc(timeout) catch null;
    }

    pub fn os_mempool_free(mp: *MemoryPool, block: ?*anyopaque) callconv(.c) os_result_t {
        return result(mp.free(block orelse return result(error.InvalidArgument)));
    }

    pub fn os_mempool_get_capacity(mp: *MemoryPool) callconv(.c) usize {
        return mp.capacity();
    }

    pub fn os_mempool_get_count(mp: *MemoryPool) callconv(.c) usize {
        return mp.countUsed();
    }

    pub fn os_mempool_get_block_size(mp: *MemoryPool) callconv(.c) usize {
        return mp.block_size;
    }

    pub fn os_mempool_is_empty(mp: *MemoryPool) callconv(.c) bool {
        return mp.isEmpty();
    }

    pub fn os_mempool_is_full(mp: *MemoryPool) callconv(.c) bool {
        return mp.isFull();
    }

    pub fn os_mempool_reset(mp: *MemoryPool) callconv(.c) os_result_t {
        return result(mp.reset());
    }

    pub fn os_mempool_get_pool(mp: *MemoryPool) callconv(.c) ?*anyopaque {
        return mp.pool.ptr;
    }

    // ---- Message queues -----------------------------------------------------

    pub fn os_mqueue_attr_init(attr: *MqueueAttr) callconv(.c) void {
        attr.* = .{};
    }

    pub fn os_mqueue_construct(mq: *MessageQueue, n: ?[*:0]const u8, msgs: usize, msg_size_bytes: usize, attr: ?*const MqueueAttr) callconv(.c) void {
        constructMqueue(mq, n, msgs, msg_size_bytes, attr) catch |err| failed("os_mqueue_construct", err);
    }

    pub fn os_mqueue_destruct(mq: *MessageQueue) callconv(.c) void {
        mq.deinit();
    }

    pub fn os_mqueue_new(n: ?[*:0]const u8, msgs: usize, msg_size_bytes: usize, attr: ?*const MqueueAttr) callconv(.c) ?*MessageQueue {
        const mq = newStorage(MessageQueue, storage_words.mqueue) orelse return null;
        os_mqueue_construct(mq, n, msgs, msg_size_bytes, attr);
        return mq;
    }

    pub fn os_mqueue_delete(mq: *MessageQueue) callconv(.c) void {
        mq.deinit();
        freeStorage(mq, storage_words.mqueue);
    }

    pub fn os_mqueue_get_name(mq: *MessageQueue) callconv(.c) [*:0]const u8 {
        return mq.name.ptr;
    }

    pub fn os_mqueue_send(mq: *MessageQueue, msg: [*]const u8, nbytes: usize, mprio: u8) callconv(.c) os_result_t {
        return result(mq.send(msg[0..nbytes], mprio));
    }

    pub fn os_mqueue_try_send(mq: *MessageQueue, msg: [*]const u8, nbytes: usize, mprio: u8) callconv(.c) os_result_t {
        return result(mq.trySend(msg[0..nbytes], mprio));
    }

    pub fn os_mqueue_timed_send(mq: *MessageQueue, msg: [*]const u8, nbytes: usize, timeout: u32, mprio: u8) callconv(.c) os_result_t {
        return result(mq.timedSend(msg[0..nbytes], timeout, mprio));
    }

    pub fn os_mqueue_receive(mq: *MessageQueue, msg: [*]u8, nbytes: usize, mprio: ?*u8) callconv(.c) os_result_t {
        const p = mq.receive(msg[0..nbytes]) catch |err| return result(err);
        if (mprio) |o| o.* = p;
        return os_ok;
    }

    pub fn os_mqueue_try_receive(mq: *MessageQueue, msg: [*]u8, nbytes: usize, mprio: ?*u8) callconv(.c) os_result_t {
        const p = mq.tryReceive(msg[0..nbytes]) catch |err| return result(err);
        if (mprio) |o| o.* = p;
        return os_ok;
    }

    pub fn os_mqueue_timed_receive(mq: *MessageQueue, msg: [*]u8, nbytes: usize, timeout: u32, mprio: ?*u8) callconv(.c) os_result_t {
        const p = mq.timedReceive(msg[0..nbytes], timeout) catch |err| return result(err);
        if (mprio) |o| o.* = p;
        return os_ok;
    }

    pub fn os_mqueue_get_capacity(mq: *MessageQueue) callconv(.c) usize {
        return mq.capacity();
    }

    pub fn os_mqueue_get_length(mq: *MessageQueue) callconv(.c) usize {
        return mq.length();
    }

    pub fn os_mqueue_get_msg_size(mq: *MessageQueue) callconv(.c) usize {
        return mq.msgSize();
    }

    pub fn os_mqueue_is_empty(mq: *MessageQueue) callconv(.c) bool {
        return mq.isEmpty();
    }

    pub fn os_mqueue_is_full(mq: *MessageQueue) callconv(.c) bool {
        return mq.isFull();
    }

    pub fn os_mqueue_reset(mq: *MessageQueue) callconv(.c) os_result_t {
        return result(mq.reset());
    }

    // ---- Event flags --------------------------------------------------------

    pub fn os_evflags_attr_init(attr: *EvflagsAttr) callconv(.c) void {
        attr.* = .{};
    }

    pub fn os_evflags_construct(ev: *EventFlags, n: ?[*:0]const u8, attr: ?*const EvflagsAttr) callconv(.c) void {
        const a: *const EvflagsAttr = attr orelse &.{};
        ev.init(name(n), .{ .clock = clockOf(a.clock) }) catch |err| failed("os_evflags_construct", err);
    }

    pub fn os_evflags_destruct(ev: *EventFlags) callconv(.c) void {
        ev.deinit();
    }

    pub fn os_evflags_new(n: ?[*:0]const u8, attr: ?*const EvflagsAttr) callconv(.c) ?*EventFlags {
        const ev = newStorage(EventFlags, storage_words.evflags) orelse return null;
        os_evflags_construct(ev, n, attr);
        return ev;
    }

    pub fn os_evflags_delete(ev: *EventFlags) callconv(.c) void {
        ev.deinit();
        freeStorage(ev, storage_words.evflags);
    }

    pub fn os_evflags_get_name(ev: *EventFlags) callconv(.c) [*:0]const u8 {
        return ev.name.ptr;
    }

    pub fn os_evflags_wait(ev: *EventFlags, mask: u32, oflags: ?*u32, m: u32) callconv(.c) os_result_t {
        const f = ev.wait(mask, mode(m)) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_evflags_try_wait(ev: *EventFlags, mask: u32, oflags: ?*u32, m: u32) callconv(.c) os_result_t {
        const f = ev.tryWait(mask, mode(m)) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_evflags_timed_wait(ev: *EventFlags, mask: u32, timeout: u32, oflags: ?*u32, m: u32) callconv(.c) os_result_t {
        const f = ev.timedWait(mask, timeout, mode(m)) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_evflags_raise(ev: *EventFlags, mask: u32, oflags: ?*u32) callconv(.c) os_result_t {
        const f = ev.raise(mask) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_evflags_clear(ev: *EventFlags, mask: u32, oflags: ?*u32) callconv(.c) os_result_t {
        const f = ev.clear(mask) catch |err| return result(err);
        if (oflags) |o| o.* = f;
        return os_ok;
    }

    pub fn os_evflags_get(ev: *EventFlags, mask: u32, m: u32) callconv(.c) u32 {
        return ev.get(mask, mode(m));
    }

    pub fn os_evflags_are_waiting(ev: *EventFlags) callconv(.c) bool {
        return ev.waiting();
    }

    // ---- Memory resources ---------------------------------------------------
    // The default one is the system heap; the C calls lock the scheduler
    // around it, as its Zig allocator does.

    pub fn os_memory_get_default() callconv(.c) *anyopaque {
        return memory.systemHeap();
    }

    pub fn os_memory_allocate(m: *anyopaque, bytes: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const scs = scheduler.KernelCriticalSection.enter();
        defer scs.exit();
        return heapOf(m).allocate(bytes, if (alignment == 0) 8 else alignment);
    }

    pub fn os_memory_deallocate(m: *anyopaque, addr: ?*anyopaque, bytes: usize, alignment: usize) callconv(.c) void {
        _ = alignment;
        const a = addr orelse return;
        const scs = scheduler.KernelCriticalSection.enter();
        defer scs.exit();
        heapOf(m).deallocate(@ptrCast(a), bytes);
    }

    pub fn os_memory_reset(m: *anyopaque) callconv(.c) void {
        const scs = scheduler.KernelCriticalSection.enter();
        defer scs.exit();
        heapOf(m).reset();
    }

    /// The free chunks are merged when released; nothing left to do.
    pub fn os_memory_coalesce(m: *anyopaque) callconv(.c) bool {
        _ = m;
        return false;
    }

    pub fn os_memory_get_total_bytes(m: *anyopaque) callconv(.c) usize {
        return heapOf(m).stats.total_bytes;
    }

    pub fn os_memory_get_allocated_bytes(m: *anyopaque) callconv(.c) usize {
        return heapOf(m).stats.allocated_bytes;
    }

    pub fn os_memory_get_free_bytes(m: *anyopaque) callconv(.c) usize {
        return heapOf(m).stats.free_bytes;
    }

    pub fn os_memory_get_allocated_chunks(m: *anyopaque) callconv(.c) usize {
        return heapOf(m).stats.allocated_chunks;
    }

    pub fn os_memory_get_free_chunks(m: *anyopaque) callconv(.c) usize {
        return heapOf(m).stats.free_chunks;
    }
};
