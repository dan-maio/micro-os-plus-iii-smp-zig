//! The CMSIS-RTOS v1 API (include/cmsis-plus/legacy/cmsis_os.h, the second
//! part of the C++ `os-c-wrapper.cpp`), over the Zig RTOS; exported with
//! `Options.cmsis_os`.
//!
//! As the C++ one, a thin layer: the objects are the C API ones (the
//! `osXxxDef()` macros allocate `os_thread_t`, `os_mutex_t`, ... storage),
//! and the status codes are mapped exactly as there.

const std = @import("std");

const config = @import("config.zig");
const rtos = @import("rtos.zig");
const c = @import("c_api.zig");

const Error = rtos.Error;
const Thread = rtos.Thread;
const Timer = rtos.Timer;
const Mutex = rtos.Mutex;
const Semaphore = rtos.Semaphore;
const MemoryPool = rtos.MemoryPool;
const MessageQueue = rtos.MessageQueue;
const interrupts = rtos.interrupts;
const this_thread = rtos.this_thread;
const words = c.storage_words;

comptime {
    if (config.options.cmsis_os) {
        for (@typeInfo(api).@"struct".decl_names) |decl| {
            @export(&@field(api, decl), .{ .name = decl });
        }
    }
}

// ----------------------------------------------------------------------------
// cmsis_os.h types (the C enums are int-sized; the C side checks it).

const osStatus = c_int;
const osOK: osStatus = 0;
const osEventSignal: osStatus = 0x08;
const osEventMessage: osStatus = 0x10;
const osEventMail: osStatus = 0x20;
const osEventTimeout: osStatus = 0x40;
const osErrorParameter: osStatus = 0x80;
const osErrorResource: osStatus = 0x81;
const osErrorTimeoutResource: osStatus = 0xC1;
const osErrorISR: osStatus = 0x82;
const osErrorValue: osStatus = 0x86;
const osErrorOS: osStatus = 0xFF;

const osPriority = c_int;
const osPriorityIdle: osPriority = rtos.priority.idle;
const osPriorityError: osPriority = rtos.priority.@"error";

const osWaitForever: u32 = 0xFFFF_FFFF;
const osFeature_Semaphore = 30;

/// The C object storages, as declared in os-c-decls.h.
fn Storage(comptime w: usize) type {
    return extern struct { storage: [w]usize align(8) };
}

const ThreadSlot = Storage(words.thread);

const MailQ = extern struct {
    pool: Storage(words.mempool),
    queue: Storage(words.mqueue),
};

const ThreadDef = extern struct {
    name: ?[*:0]const u8,
    pthread: c.V1ThreadFunc,
    tpriority: osPriority,
    instances: u32,
    stacksize: u32,
    data: [*]ThreadSlot,
    stack: ?[*]u64,
};

const TimerDef = extern struct {
    name: ?[*:0]const u8,
    ptimer: c.CTimerFunc,
    data: *Timer,
};

const MutexDef = extern struct {
    name: ?[*:0]const u8,
    data: *Mutex,
};

const SemaphoreDef = extern struct {
    name: ?[*:0]const u8,
    data: *Semaphore,
};

const PoolDef = extern struct {
    name: ?[*:0]const u8,
    items: u32,
    item_sz: u32,
    pool: ?*anyopaque,
    pool_sz: u32,
    data: *MemoryPool,
};

const MessageQDef = extern struct {
    name: ?[*:0]const u8,
    items: u32,
    item_sz: u32,
    queue: ?*anyopaque,
    queue_sz: u32,
    data: *MessageQueue,
};

const MailQDef = extern struct {
    name: ?[*:0]const u8,
    items: u32,
    pool_item_sz: u32,
    queue_item_sz: u32,
    pool: ?*anyopaque,
    pool_sz: u32,
    queue: ?*anyopaque,
    queue_sz: u32,
    data: *MailQ,
};

const osEvent = extern struct {
    status: osStatus = osOK,
    value: extern union { v: u32, p: ?*anyopaque, signals: i32 } = .{ .v = 0 },
    def: extern union { mail_id: ?*MailQ, message_id: ?*MessageQueue } = .{ .mail_id = null },
};

fn poolOf(m: *MailQ) *MemoryPool {
    return @ptrCast(&m.pool);
}

fn queueOf(m: *MailQ) *MessageQueue {
    return @ptrCast(&m.queue);
}

/// Milliseconds to systick ticks, rounded up (`clock_systick::ticks_cast`).
fn ticks(millisec: u32) rtos.Duration {
    return rtos.Clock.ticksCast(@as(u64, millisec) * 1000);
}

fn inHandler() bool {
    return interrupts.inHandlerMode();
}

// ----------------------------------------------------------------------------

const api = struct {
    // ---- Kernel -------------------------------------------------------------

    pub fn osKernelInitialize() callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        rtos.scheduler.initialize() catch {};
        return osOK;
    }

    pub fn osKernelStart() callconv(.c) osStatus {
        rtos.scheduler.start();
    }

    pub fn osKernelRunning() callconv(.c) i32 {
        return if (rtos.scheduler.started()) 1 else 0;
    }

    pub fn osKernelSysTick() callconv(.c) u32 {
        return @truncate(rtos.hrclock.now());
    }

    // ---- Threads ------------------------------------------------------------

    pub fn osThreadCreate(def: ?*const ThreadDef, args: ?*anyopaque) callconv(.c) ?*Thread {
        if (inHandler()) return null;
        const d = def orelse return null;
        if (d.tpriority >= osPriorityError) return null;

        var attr: c.ThreadAttr = .{
            .th_priority = @intCast(d.tpriority),
            .th_stack_size_bytes = d.stacksize,
            // As the C++ one (only with OS_USE_SMP_SCHEDULER there): the
            // v1 threads run on the first CPU.
            .th_cpu_affinity = 1 << 0,
        };
        for (0..d.instances) |i| {
            const th: *Thread = @ptrCast(&d.data[i]);
            if (th.state == .undefined or th.state == .destroyed) {
                // The C++ one computes the stack address even when the
                // definition has no stack (osThreadAllocatedDef); here only
                // when there is one.
                if (d.stacksize > 0) if (d.stack) |stack| {
                    attr.th_stack_address = &stack[i * ((d.stacksize + @sizeOf(u64) - 1) / @sizeOf(u64))];
                };
                c.constructThread(th, d.name, .{ .v1 = d.pthread }, args, &attr) catch |err|
                    c.failed("osThreadCreate", err);
                return th;
            }
        }
        return null;
    }

    pub fn osThreadGetId() callconv(.c) ?*Thread {
        if (inHandler()) return null;
        return this_thread.thread();
    }

    pub fn osThreadTerminate(thread_id: ?*Thread) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        const th = thread_id orelse return osErrorParameter;
        if (th.getState() == .undefined) return osErrorResource;
        if (th == this_thread.thread()) this_thread.exit(null);
        th.kill() catch {};
        return osOK;
    }

    pub fn osThreadYield() callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        this_thread.yield();
        return osOK;
    }

    pub fn osThreadSetPriority(thread_id: ?*Thread, priority: osPriority) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        const th = thread_id orelse return osErrorParameter;
        const state = th.getState();
        if (state == .undefined or @intFromEnum(state) >= @intFromEnum(Thread.State.destroyed)) return osErrorResource;
        if (priority < osPriorityIdle or priority >= osPriorityError) return osErrorValue;
        th.setPriority(@intCast(priority)) catch |err| return switch (err) {
            error.InvalidArgument => osErrorValue,
            else => osErrorOS,
        };
        return osOK;
    }

    pub fn osThreadGetPriority(thread_id: ?*Thread) callconv(.c) osPriority {
        if (inHandler()) return osPriorityError;
        const th = thread_id orelse return osPriorityError;
        return th.priority();
    }

    // ---- Generic wait -------------------------------------------------------

    /// The C++ sleep_for() returns ETIMEDOUT when the time elapsed; the Zig
    /// one returns normally.
    pub fn osDelay(millisec: u32) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        rtos.sysclock.sleepFor(ticks(millisec)) catch |err| return switch (err) {
            error.TimedOut => osEventTimeout,
            else => osErrorOS,
        };
        return osEventTimeout;
    }

    pub fn osWait(millisec: u32) callconv(.c) osEvent {
        if (inHandler()) return .{ .status = osErrorISR };
        rtos.sysclock.waitFor(ticks(millisec)) catch |err| return .{ .status = switch (err) {
            error.TimedOut => osEventTimeout,
            else => osErrorOS,
        } };
        return .{ .status = osErrorOS };
    }

    // ---- Timers -------------------------------------------------------------

    pub fn osTimerCreate(def: ?*const TimerDef, timer_type: c_int, args: ?*anyopaque) callconv(.c) ?*Timer {
        if (inHandler()) return null;
        const d = def orelse return null;
        const tm = d.data;
        tm.* = .initWith(c.name(d.name), c.timerTrampoline, tm, .{ .type = @enumFromInt(timer_type) });
        c.TimerTail.of(tm).* = .{ .func = d.ptimer, .args = args };
        return tm;
    }

    pub fn osTimerStart(timer_id: ?*Timer, millisec: u32) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        const tm = timer_id orelse return osErrorParameter;
        tm.start(ticks(millisec)) catch return osErrorOS;
        return osOK;
    }

    pub fn osTimerStop(timer_id: ?*Timer) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        const tm = timer_id orelse return osErrorParameter;
        tm.stop() catch |err| return switch (err) {
            error.Again => osErrorResource,
            else => osErrorOS,
        };
        return osOK;
    }

    pub fn osTimerDelete(timer_id: ?*Timer) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        const tm = timer_id orelse return osErrorParameter;
        tm.deinit();
        return osOK;
    }

    // ---- Signals ------------------------------------------------------------

    pub fn osSignalSet(thread_id: ?*Thread, signals: i32) callconv(.c) i32 {
        const err_value: i32 = @bitCast(@as(u32, 0x8000_0000));
        const th = thread_id orelse return err_value;
        if (signals == err_value) return err_value;
        const osig = th.flagsRaise(@bitCast(signals)) catch return err_value;
        return @bitCast(osig);
    }

    pub fn osSignalClear(thread_id: ?*Thread, signals: i32) callconv(.c) i32 {
        const err_value: i32 = @bitCast(@as(u32, 0x8000_0000));
        const th = thread_id orelse return err_value;
        if (inHandler() or signals == 0) return err_value;
        const sig = th.flagsClear(@bitCast(signals)) catch return err_value;
        return @bitCast(sig);
    }

    pub fn osSignalWait(signals: i32, millisec: u32) callconv(.c) osEvent {
        if (inHandler()) return .{ .status = osErrorISR };
        const mask: u32 = @bitCast(signals);
        if (mask & 0x8000_0000 != 0) return .{ .status = osErrorValue };

        // this_thread::flags_wait()'s default mode: all, and clear.
        const mode: rtos.flags.Mode = .all_clear;
        const r = if (millisec == osWaitForever)
            this_thread.flagsWait(mask, mode)
        else if (millisec == 0)
            this_thread.flagsTryWait(mask, mode)
        else
            this_thread.flagsTimedWait(mask, ticks(millisec), mode);

        const got = r catch |err| return .{ .status = switch (err) {
            error.WouldBlock => osOK, // only for try_flags_wait()
            error.TimedOut => osEventTimeout, // only for timed_flags_wait()
            error.NotPermitted => osErrorISR,
            error.InvalidArgument => osErrorValue,
            else => osErrorOS,
        } };
        return .{ .status = osEventSignal, .value = .{ .signals = @bitCast(got) } };
    }

    // ---- Mutexes ------------------------------------------------------------

    pub fn osMutexCreate(def: ?*const MutexDef) callconv(.c) ?*Mutex {
        if (inHandler()) return null;
        const d = def orelse return null;
        d.data.init(c.name(d.name), .{ .type = .recursive, .protocol = .inherit }) catch |err|
            c.failed("osMutexCreate", err);
        return d.data;
    }

    pub fn osMutexWait(mutex_id: ?*Mutex, millisec: u32) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        const mx = mutex_id orelse return osErrorParameter;
        const r = if (millisec == osWaitForever)
            mx.lock()
        else if (millisec == 0)
            mx.tryLock()
        else
            mx.timedLock(ticks(millisec));
        r catch |err| return switch (err) {
            error.WouldBlock => osErrorResource,
            error.NotRecoverable => osErrorResource,
            error.TimedOut => osErrorTimeoutResource,
            else => osErrorOS,
        };
        return osOK;
    }

    pub fn osMutexRelease(mutex_id: ?*Mutex) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        const mx = mutex_id orelse return osErrorParameter;
        mx.unlock() catch |err| return switch (err) {
            error.NotPermitted, error.NotRecoverable => osErrorResource,
            else => osErrorOS,
        };
        return osOK;
    }

    pub fn osMutexDelete(mutex_id: ?*Mutex) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        const mx = mutex_id orelse return osErrorParameter;
        mx.deinit();
        return osOK;
    }

    // ---- Semaphores ---------------------------------------------------------

    pub fn osSemaphoreCreate(def: ?*const SemaphoreDef, count: i32) callconv(.c) ?*Semaphore {
        if (inHandler()) return null;
        const d = def orelse return null;
        d.data.init(c.name(d.name), .{
            .initial_value = @intCast(count),
            .max_value = @intCast(if (count == 0) osFeature_Semaphore else count),
        }) catch |err| c.failed("osSemaphoreCreate", err);
        return d.data;
    }

    pub fn osSemaphoreWait(semaphore_id: ?*Semaphore, millisec: u32) callconv(.c) i32 {
        if (inHandler()) return -1;
        const sem = semaphore_id orelse return -1;
        if (millisec == osWaitForever) {
            sem.wait() catch return -1;
        } else if (millisec == 0) {
            sem.tryWait() catch |err| return if (err == error.WouldBlock) 0 else -1;
        } else {
            sem.timedWait(ticks(millisec)) catch |err| return if (err == error.TimedOut) 0 else -1;
        }
        return @as(i32, sem.value()) + 1;
    }

    pub fn osSemaphoreRelease(semaphore_id: ?*Semaphore) callconv(.c) osStatus {
        const sem = semaphore_id orelse return osErrorParameter;
        if (sem.initialValue() == 0) return osErrorResource;
        sem.post() catch |err| return switch (err) {
            error.Again => osErrorResource,
            else => osErrorOS,
        };
        return osOK;
    }

    pub fn osSemaphoreDelete(semaphore_id: ?*Semaphore) callconv(.c) osStatus {
        if (inHandler()) return osErrorISR;
        const sem = semaphore_id orelse return osErrorParameter;
        sem.deinit();
        return osOK;
    }

    // ---- Memory pools -------------------------------------------------------

    pub fn osPoolCreate(def: ?*const PoolDef) callconv(.c) ?*MemoryPool {
        if (inHandler()) return null;
        const d = def orelse return null;
        const attr: c.MempoolAttr = .{ .mp_pool_address = d.pool, .mp_pool_size_bytes = d.pool_sz };
        c.constructMempool(d.data, d.name, d.items, d.item_sz, &attr) catch |err|
            c.failed("osPoolCreate", err);
        return d.data;
    }

    pub fn osPoolAlloc(pool_id: ?*MemoryPool) callconv(.c) ?*anyopaque {
        const mp = pool_id orelse return null;
        return mp.tryAlloc() catch null;
    }

    pub fn osPoolCAlloc(pool_id: ?*MemoryPool) callconv(.c) ?*anyopaque {
        const mp = pool_id orelse return null;
        const block = mp.tryAlloc() catch return null;
        const p: [*]u8 = @ptrCast(block);
        @memset(p[0..mp.block_size], 0);
        return block;
    }

    pub fn osPoolFree(pool_id: ?*MemoryPool, block: ?*anyopaque) callconv(.c) osStatus {
        const mp = pool_id orelse return osErrorParameter;
        const b = block orelse return osErrorParameter;
        mp.free(b) catch |err| return switch (err) {
            error.InvalidArgument => osErrorValue,
            else => osErrorOS,
        };
        return osOK;
    }

    // ---- Message queues -----------------------------------------------------

    pub fn osMessageCreate(def: ?*const MessageQDef, thread_id: ?*Thread) callconv(.c) ?*MessageQueue {
        _ = thread_id;
        if (inHandler()) return null;
        const d = def orelse return null;
        const attr: c.MqueueAttr = .{ .mq_queue_addr = d.queue, .mq_queue_size_bytes = d.queue_sz };
        c.constructMqueue(d.data, d.name, d.items, d.item_sz, &attr) catch |err|
            c.failed("osMessageCreate", err);
        return d.data;
    }

    pub fn osMessagePut(queue_id: ?*MessageQueue, info: u32, millisec: u32) callconv(.c) osStatus {
        const mq = queue_id orelse return osErrorParameter;
        const msg = std.mem.asBytes(&info);
        const r = if (millisec == osWaitForever) blk: {
            if (inHandler()) return osErrorParameter;
            break :blk mq.send(msg, 0);
        } else if (millisec == 0)
            mq.trySend(msg, 0)
        else blk: {
            if (inHandler()) return osErrorParameter;
            break :blk mq.timedSend(msg, ticks(millisec), 0);
        };
        r catch |err| return switch (err) {
            error.WouldBlock => osErrorResource,
            error.TimedOut => osErrorTimeoutResource,
            error.InvalidArgument, error.MessageSize => osErrorParameter,
            else => osErrorOS,
        };
        return osOK;
    }

    pub fn osMessageGet(queue_id: ?*MessageQueue, millisec: u32) callconv(.c) osEvent {
        var event: osEvent = .{};
        const mq = queue_id orelse return .{ .status = osErrorParameter };
        const buf = std.mem.asBytes(&event.value.v);
        const r = if (millisec == osWaitForever) blk: {
            if (inHandler()) return .{ .status = osErrorParameter };
            break :blk mq.receive(buf);
        } else if (millisec == 0)
            mq.tryReceive(buf)
        else blk: {
            if (inHandler()) return .{ .status = osErrorParameter };
            break :blk mq.timedReceive(buf, ticks(millisec));
        };
        if (r) |_| {
            event.status = osEventMessage;
        } else |err| event.status = switch (err) {
            error.TimedOut => osEventTimeout,
            error.InvalidArgument, error.MessageSize => osErrorParameter,
            error.WouldBlock => osOK,
            else => osErrorOS,
        };
        return event;
    }

    // ---- Mail queues --------------------------------------------------------

    pub fn osMailCreate(def: ?*const MailQDef, thread_id: ?*Thread) callconv(.c) ?*MailQ {
        _ = thread_id;
        if (inHandler()) return null;
        const d = def orelse return null;
        const pool_attr: c.MempoolAttr = .{ .mp_pool_address = d.pool, .mp_pool_size_bytes = d.pool_sz };
        c.constructMempool(poolOf(d.data), d.name, d.items, d.pool_item_sz, &pool_attr) catch |err|
            c.failed("osMailCreate", err);
        const queue_attr: c.MqueueAttr = .{ .mq_queue_addr = d.queue, .mq_queue_size_bytes = d.queue_sz };
        c.constructMqueue(queueOf(d.data), d.name, d.items, d.queue_item_sz, &queue_attr) catch |err|
            c.failed("osMailCreate", err);
        return d.data;
    }

    pub fn osMailAlloc(mail_id: ?*MailQ, millisec: u32) callconv(.c) ?*anyopaque {
        const m = mail_id orelse return null;
        const mp = poolOf(m);
        if (millisec == osWaitForever) {
            if (inHandler()) return null;
            return mp.alloc() catch null;
        } else if (millisec == 0) {
            return mp.tryAlloc() catch null;
        } else {
            if (inHandler()) return null;
            return mp.timedAlloc(ticks(millisec)) catch null;
        }
    }

    pub fn osMailCAlloc(mail_id: ?*MailQ, millisec: u32) callconv(.c) ?*anyopaque {
        const block = osMailAlloc(mail_id, millisec) orelse return null;
        const p: [*]u8 = @ptrCast(block);
        @memset(p[0..poolOf(mail_id.?).block_size], 0);
        return block;
    }

    pub fn osMailPut(mail_id: ?*MailQ, mail: ?*anyopaque) callconv(.c) osStatus {
        const m = mail_id orelse return osErrorParameter;
        const p = mail orelse return osErrorValue;
        const mp = poolOf(m);
        const start = @intFromPtr(mp.pool.ptr);
        const addr = @intFromPtr(p);
        if (addr < start or addr >= start + mp.capacity() * mp.block_size) return osErrorValue;
        queueOf(m).trySend(std.mem.asBytes(&p), 0) catch return osErrorOS;
        return osOK;
    }

    pub fn osMailGet(mail_id: ?*MailQ, millisec: u32) callconv(.c) osEvent {
        var event: osEvent = .{};
        const m = mail_id orelse return .{ .status = osErrorParameter };
        const mq = queueOf(m);
        const buf = std.mem.asBytes(&event.value.p);
        const r = if (millisec == osWaitForever) blk: {
            if (inHandler()) return .{ .status = osErrorParameter };
            break :blk mq.receive(buf);
        } else if (millisec == 0)
            mq.tryReceive(buf)
        else blk: {
            if (inHandler()) return .{ .status = osErrorParameter };
            break :blk mq.timedReceive(buf, ticks(millisec));
        };
        if (r) |_| {
            event.status = osEventMail;
        } else |err| event.status = switch (err) {
            error.WouldBlock => osOK,
            error.InvalidArgument, error.MessageSize => osErrorParameter,
            error.TimedOut => osEventTimeout,
            else => osErrorOS,
        };
        return event;
    }

    pub fn osMailFree(mail_id: ?*MailQ, mail: ?*anyopaque) callconv(.c) osStatus {
        const m = mail_id orelse return osErrorParameter;
        if (mail == null) return osErrorValue;
        return osPoolFree(poolOf(m), mail);
    }
};
