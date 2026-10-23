//! Threads (`os::rtos::thread`, `src/rtos/os-thread.cpp`).
//!
//! A `Thread` is an intrusive object: it is linked in the scheduler lists by
//! address, so it must not move once initialised. Static threads are
//! declared as variables and initialised in place:
//!
//! ```zig
//! var worker: uos.rtos.ThreadInclusive(2048) = undefined;
//! try worker.init("worker", workerMain, null, .{ .priority = .high });
//! ```
//!
//! Dynamic threads come from an allocator; `spawn()` also packs typed
//! arguments, like `std.Thread.spawn()`:
//!
//! ```zig
//! const th = try uos.rtos.Thread.spawn(gpa, .{}, "worker", work, .{ 1, 2 });
//! defer th.destroy();
//! try th.join();
//! ```

const std = @import("std");
const assert = std.debug.assert;

const port = @import("uos_port");
const config = @import("../config.zig");
const trace = @import("../trace.zig");
const result = @import("result.zig");
const Error = result.Error;
const interrupts = @import("interrupts.zig");
const scheduler = @import("scheduler.zig");
const lists = @import("lists.zig");
const flags = @import("flags.zig");
const clocks = @import("clocks.zig");
const Clock = clocks.Clock;
const Mutex = @import("mutex.zig").Mutex;

const tr = config.options.trace;
const ncpu = config.ncpu;

pub const StackElement = port.StackElement;

/// The function a thread runs; its return value is the exit value read by
/// `join()`.
pub const Func = *const fn (args: ?*anyopaque) ?*anyopaque;

/// Thread priorities. 16 levels per named step, `range` bits wide, as in
/// C++ (`thread::priority`).
pub const Priority = u8;

pub const priority = struct {
    pub const range = 4;
    /// Undefined, the thread does not run.
    pub const none: Priority = 0;
    /// The idle thread; no other thread should use it.
    pub const idle: Priority = 1 << range;
    pub const lowest: Priority = 2 << range;
    pub const low: Priority = 2 << range;
    pub const below_normal: Priority = 4 << range;
    pub const normal: Priority = 6 << range;
    pub const above_normal: Priority = 8 << range;
    pub const high: Priority = 10 << range;
    pub const realtime: Priority = 12 << range;
    pub const highest: Priority = ((13 + 1) << range) - 1;
    /// Reserved for the interrupt service threads.
    pub const isr: Priority = ((14 + 1) << range) - 1;
    /// Error value returned by the getters.
    pub const @"error": Priority = ((15 + 1) << range) - 1;
};

pub const State = enum(u8) {
    undefined = 0,
    ready = 1,
    running = 2,
    suspended = 3,
    terminated = 4,
    destroyed = 5,
    initializing = 6,
    destroying = 7,
};

pub const stack_magic: StackElement = if (@hasDecl(port, "stack_magic")) port.stack_magic else 0xEFBE_ADDE;

/// The thread stack (`thread::stack`). Extern: the C API exposes it as
/// `os_thread_stack_t`.
pub const Stack = extern struct {
    bottom_address: ?[*]StackElement = null,
    size_bytes: usize = 0,

    pub var min_size_bytes: usize = config.options.min_stack_size_bytes;
    pub var default_size_bytes: usize = config.options.default_stack_size_bytes;

    pub fn set(st: *Stack, address: [*]StackElement, size_bytes: usize) void {
        st.bottom_address = address;
        st.size_bytes = size_bytes;
    }

    pub fn clear(st: *Stack) void {
        st.* = .{};
    }

    pub fn bottom(st: *const Stack) [*]StackElement {
        return st.bottom_address.?;
    }

    /// The topmost element; it holds a magic word too, guarding overflows
    /// of the area above the stack.
    pub fn top(st: *const Stack) [*]StackElement {
        return st.bottom() + st.size_bytes / @sizeOf(StackElement);
    }

    pub fn size(st: *const Stack) usize {
        return st.size_bytes;
    }

    /// The usable elements, as a slice (bottom up to, excluding, top).
    pub fn slice(st: *const Stack) []StackElement {
        return st.bottom()[0 .. st.size_bytes / @sizeOf(StackElement)];
    }

    /// Align the stack to `port.stack_alignment`, fill it with the magic
    /// word, and leave the top element as a guard.
    pub fn initialize(st: *Stack) Error!void {
        const raw = @intFromPtr(st.bottom_address orelse return error.InvalidArgument);
        const aligned = std.mem.alignForward(usize, raw, port.stack_alignment);
        if (aligned - raw >= st.size_bytes) return error.OutOfMemory;
        const usable = st.size_bytes - (aligned - raw);
        const count = usable / @sizeOf(StackElement);
        if (count < 2) return error.OutOfMemory;
        const p: [*]StackElement = @ptrFromInt(aligned);
        @memset(p[0..count], stack_magic);
        st.bottom_address = p;
        st.size_bytes = (count - 1) * @sizeOf(StackElement);
    }

    pub fn checkBottomMagic(st: *const Stack) bool {
        return st.bottom()[0] == stack_magic;
    }

    pub fn checkTopMagic(st: *const Stack) bool {
        return st.top()[0] == stack_magic;
    }

    /// Bytes never written, counted from the bottom.
    pub fn available(st: *const Stack) usize {
        var count: usize = 0;
        const p = st.bottom();
        while (count / @sizeOf(StackElement) < st.size_bytes / @sizeOf(StackElement) and
            p[count / @sizeOf(StackElement)] == stack_magic) : (count += @sizeOf(StackElement))
        {}
        return count;
    }
};

/// The execution context: the stack plus the port's saved machine state.
pub const Context = struct {
    stack: Stack = .{},
    port: port.Context = .{},
};

pub const IoCancel = struct {
    /// A cancel request waits for the next cancellation point.
    requested: bool = false,
    /// `std.Io.CancelProtection.blocked`.
    protected: bool = false,
};

pub const Statistics = struct {
    context_switches: u64 = 0,
    cpu_cycles: u64 = 0,
};

/// Creation attributes (`thread::attributes`).
pub const Attributes = struct {
    /// A user supplied stack; when null (or too small) the stack is
    /// allocated with the thread's allocator.
    stack: ?[]StackElement = null,
    /// The stack size when it is allocated; 0 means the default.
    stack_size_bytes: usize = 0,
    priority: Priority = priority.normal,
    /// The clock used by the timed waits; null means `sysclock`.
    clock: ?*Clock = null,
    /// SMP: the CPUs this thread may run on, one bit per CPU.
    cpu_affinity: u32 = 0xFFFF_FFFF,
};

const prio_levels = priority;
const thread_state = State;
const thread_attributes = Attributes;

pub const Thread = struct {
    pub const State = thread_state;
    pub const Attributes = thread_attributes;

    name: [:0]const u8 = "-",

    func: ?Func = null,
    func_args: ?*anyopaque = null,
    func_result: ?*anyopaque = null,

    parent: ?*Thread = null,
    /// Links in the parent's `children` list (or the top threads list).
    child_links: lists.Links = .{},
    children: lists.List = .{},

    /// Links in the ready list (and, once terminated, the funeral list).
    ready_node: lists.WaitingThreadNode = .{ .thread = undefined },

    /// The mutexes owned, linked through `Mutex.owner_links`.
    mutexes: lists.List = .{},
    acquired_mutexes: usize = 0,

    joiner: ?*Thread = null,
    waiting_node: ?*lists.WaitingThreadNode = null,
    clock_node: ?*lists.TimeoutThreadNode = null,
    clock: *Clock = &clocks.sysclock,

    allocator: ?std.mem.Allocator = null,
    allocated_stack: ?[]align(8) u8 = null,
    /// Frees the thread object itself (set by `create()`/`spawn()`).
    free_self: ?*const fn (th: *Thread) void = null,

    prio_assigned: Priority = prio_levels.none,
    prio_inherited: Priority = prio_levels.none,
    cpu_affinity: u32 = 0xFFFF_FFFF,
    state: thread_state = .undefined,
    interrupted: bool = false,

    event_flags: flags.EventFlags = .{},
    statistics: Statistics = .{},
    /// `std.Io` cancellation state of this thread (see `uos.Io`).
    io_cancel: IoCancel = .{},
    context: Context = .{},

    // ------------------------------------------------------------------------
    // Construction.

    /// Initialise a thread in place and make it ready. With a user stack
    /// (`attr.stack`) nothing is allocated and `allocator` may be null.
    pub fn init(
        th: *Thread,
        name: [:0]const u8,
        function: Func,
        args: ?*anyopaque,
        attr: thread_attributes,
        allocator: ?std.mem.Allocator,
    ) Error!void {
        th.* = .{ .name = name };
        if (tr.thread) trace.print("Thread.init() @{*} {s}\n", .{ th, name });

        th.state = .initializing;
        th.cpu_affinity = attr.cpu_affinity;
        th.allocator = allocator;

        if (attr.stack) |user_stack| {
            if (user_stack.len * @sizeOf(StackElement) > Stack.min_size_bytes) {
                return th.internalConstruct(function, args, attr, user_stack);
            }
        }

        const gpa = allocator orelse return error.OutOfMemory;
        const size_bytes = if (attr.stack_size_bytes > Stack.min_size_bytes)
            attr.stack_size_bytes
        else
            Stack.default_size_bytes;
        const bytes = gpa.alignedAlloc(u8, .@"8", std.mem.alignForward(usize, size_bytes, 8)) catch
            return error.OutOfMemory;
        th.allocated_stack = bytes;
        const elements: [*]StackElement = @ptrCast(bytes.ptr);
        return th.internalConstruct(function, args, attr, elements[0 .. bytes.len / @sizeOf(StackElement)]);
    }

    fn internalConstruct(th: *Thread, function: Func, args: ?*anyopaque, attr: thread_attributes, stack_mem: []StackElement) Error!void {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (attr.priority == prio_levels.none or attr.priority >= prio_levels.@"error") return error.InvalidArgument;

        th.clock = attr.clock orelse &clocks.sysclock;
        th.context.stack.set(stack_mem.ptr, stack_mem.len * @sizeOf(StackElement));
        th.ready_node = .{ .thread = th };

        if (tr.thread) trace.print("Thread.construct() @{*} {s} p{d} stack{{{*},{d}}}\n", .{
            th, th.name, attr.priority, stack_mem.ptr, stack_mem.len * @sizeOf(StackElement),
        });

        {
            const scs = scheduler.KernelCriticalSection.enter();
            defer scs.exit();

            th.prio_assigned = attr.priority;
            th.func = function;
            th.func_args = args;

            th.parent = this_thread.get();
            if (scheduler.started() and th.parent != null) {
                th.parent.?.children.append(&th.child_links);
            } else {
                scheduler.top_threads_list.append(&th.child_links);
            }

            try th.context.stack.initialize();

            port.contextCreate(&th.context.port, th.context.stack.slice(), invokeWithExit, th);

            if (!scheduler.started()) {
                scheduler.current_thread[port.scheduler.cpuId()] = th;
            }

            th.@"resume"();
        }
        // Let a higher priority thread run now.
        this_thread.yield();
    }

    /// The entry the port's context starts; runs the function and exits.
    fn invokeWithExit(arg: ?*anyopaque) callconv(.c) noreturn {
        const th: *Thread = @ptrCast(@alignCast(arg.?));
        if (tr.thread) trace.print("invokeWithExit() @{*} {s}\n", .{ th, th.name });
        const exit_ptr = th.func.?(th.func_args);
        th.internalExit(exit_ptr);
    }

    /// Allocate and initialise a thread whose object and stack come from
    /// `gpa`; release it with `destroy()`.
    pub fn create(gpa: std.mem.Allocator, name: [:0]const u8, function: Func, args: ?*anyopaque, attr: thread_attributes) Error!*Thread {
        const th = gpa.create(Thread) catch return error.OutOfMemory;
        errdefer gpa.destroy(th);
        try th.init(name, function, args, attr, gpa);
        th.free_self = struct {
            fn free(t: *Thread) void {
                t.allocator.?.destroy(t);
            }
        }.free;
        return th;
    }

    /// Spawn a thread running `function(args...)`, with typed arguments.
    /// The function may return anything; an error is traced, any other
    /// value is discarded. Release it with `destroy()`.
    pub fn spawn(
        gpa: std.mem.Allocator,
        attr: thread_attributes,
        name: [:0]const u8,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) Error!*Thread {
        const Args = @TypeOf(args);
        const Closure = struct {
            thread: Thread,
            args: Args,

            fn entry(raw: ?*anyopaque) ?*anyopaque {
                const c: *@This() = @ptrCast(@alignCast(raw.?));
                const ret = @call(.auto, function, c.args);
                switch (@typeInfo(@TypeOf(ret))) {
                    .error_union => _ = ret catch |err| {
                        trace.print("thread {s}: error.{s}\n", .{ c.thread.name, @errorName(err) });
                    },
                    else => {},
                }
                return null;
            }

            fn free(t: *Thread) void {
                const c: *@This() = @alignCast(@fieldParentPtr("thread", t));
                t.allocator.?.destroy(c);
            }
        };

        const c = gpa.create(Closure) catch return error.OutOfMemory;
        errdefer gpa.destroy(c);
        c.args = args;
        try c.thread.init(name, Closure.entry, c, attr, gpa);
        c.thread.free_self = Closure.free;
        return &c.thread;
    }

    /// The destructor: kill the thread unless it is the caller.
    pub fn deinit(th: *Thread) void {
        if (tr.thread) trace.print("Thread.deinit() @{*} {s}\n", .{ th, th.name });
        if (th != this_thread.get()) {
            if (th.state != .destroyed) th.kill() catch {};
        }
    }

    /// `deinit()` plus releasing the object, for `create()`/`spawn()`.
    pub fn destroy(th: *Thread) void {
        th.deinit();
        if (th.free_self) |free| free(th);
    }

    pub fn isConstructed(th: *const Thread) bool {
        return switch (th.state) {
            .ready, .running, .suspended, .terminated => true,
            else => false,
        };
    }

    // ------------------------------------------------------------------------
    // Scheduling.

    /// Make the thread ready, if suspended, and request a reschedule. Can
    /// be called from interrupt handlers.
    pub fn @"resume"(th: *Thread) void {
        if (tr.thread_context) trace.print("Thread.resume() @{*} {s} {d}\n", .{ th, th.name, th.prio_assigned });
        assert(interrupts.isPriorityValid());
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            if (th.state == .suspended or th.state == .initializing) {
                if (th.ready_node.links.isUnlinked()) {
                    scheduler.ready_threads_list.link(&th.ready_node);
                }
            }
        }
        port.scheduler.reschedule();

        if (ncpu > 1 and config.options.resume_ipi) {
            // When this CPU may not run the thread, wake one that may.
            const this_cpu = port.scheduler.cpuId();
            if (th.cpu_affinity & (@as(u32, 1) << @intCast(this_cpu)) == 0) {
                for (0..ncpu) |c| {
                    if (c != this_cpu and th.cpu_affinity & (@as(u32, 1) << @intCast(c)) != 0) {
                        port.scheduler.ipi(@intCast(c));
                        break;
                    }
                }
            }
        }
    }

    /// The effective priority: the assigned one, raised by inheritance.
    pub fn priority(th: *const Thread) Priority {
        if (th.prio_inherited == prio_levels.none) return th.prio_assigned;
        return @max(th.prio_inherited, th.prio_assigned);
    }

    pub fn priorityInherited(th: *const Thread) Priority {
        return th.prio_inherited;
    }

    /// Set the assigned priority.
    pub fn setPriority(th: *Thread, prio: Priority) Error!void {
        if (tr.thread) trace.print("Thread.setPriority({d}) @{*} {s}\n", .{ prio, th, th.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (prio >= prio_levels.@"error" or prio == prio_levels.none) return error.InvalidArgument;
        if (th.prio_assigned == prio) return;
        th.prio_assigned = prio;
        th.relinkReady();
        this_thread.yield();
    }

    /// Set the inherited priority (used by the mutexes).
    pub fn setPriorityInherited(th: *Thread, prio: Priority) Error!void {
        if (tr.thread) trace.print("Thread.setPriorityInherited({d}) @{*} {s}\n", .{ prio, th, th.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (prio >= prio_levels.@"error") return error.InvalidArgument;
        if (prio == th.prio_inherited) return;
        th.prio_inherited = prio;
        if (th.prio_inherited < th.prio_assigned) {
            // Lowering the inherited priority below the assigned one does
            // not change the effective priority.
            return;
        }
        th.relinkReady();
        this_thread.yield();
    }

    /// Re-link a ready thread at the position of its new priority.
    fn relinkReady(th: *Thread) void {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        if (th.state == .ready and th.ready_node.links.isLinked()) {
            th.ready_node.links.unlink();
            scheduler.ready_threads_list.link(&th.ready_node);
        }
    }

    pub fn cpuAffinity(th: *const Thread) u32 {
        return th.cpu_affinity;
    }

    pub fn setCpuAffinity(th: *Thread, mask: u32) void {
        th.cpu_affinity = mask;
    }

    /// Detach the thread from its parent.
    pub fn detach(th: *Thread) Error!void {
        if (tr.thread) trace.print("Thread.detach() @{*} {s}\n", .{ th, th.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        if (th.state == .destroyed) return error.InvalidArgument;
        if (th.parent != null) {
            th.child_links.unlink();
            scheduler.top_threads_list.append(&th.child_links);
            th.parent = null;
        }
    }

    /// Wait for the thread to terminate; returns its exit value.
    pub fn join(th: *Thread) Error!?*anyopaque {
        if (tr.thread) trace.print("Thread.join() @{*} {s}\n", .{ th, th.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (scheduler.locked()) return error.NotPermitted;

        const crt = this_thread.get().?;
        assert(th != crt);

        // Wait for the thread to be destroyed by the idle thread.
        while (true) {
            {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                if (th.state == .destroyed) break;
                th.joiner = crt;
                port.scheduler.prepareSuspend();
                crt.state = .suspended;
            }
            port.scheduler.reschedule();
        }

        if (ncpu > 1) {
            // The thread may still be on its way out of another CPU.
            while (true) {
                var still_running = false;
                for (&scheduler.current_thread) |*ct| {
                    if (@atomicLoad(?*Thread, ct, .acquire) == th) still_running = true;
                }
                if (!still_running) break;
                this_thread.yield();
            }
        }

        if (tr.thread) trace.print("Thread.join() @{*} {s} joined\n", .{ th, th.name });
        return th.func_result;
    }

    /// Cancellation points are not implemented, as in C++.
    pub fn cancel(th: *Thread) Error!void {
        if (tr.thread) trace.print("Thread.cancel() @{*} {s}\n", .{ th, th.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
    }

    /// Set (or clear) the interrupted flag and resume the thread, so that
    /// its current wait returns `error.Interrupted`. Returns the previous
    /// flag.
    pub fn interrupt(th: *Thread, value: bool) bool {
        if (tr.thread) trace.print("Thread.interrupt() @{*} {s}\n", .{ th, th.name });
        const prev = th.interrupted;
        th.interrupted = value;
        th.@"resume"();
        return prev;
    }

    pub fn isInterrupted(th: *const Thread) bool {
        return @atomicLoad(bool, &th.interrupted, .acquire);
    }

    pub fn getState(th: *const Thread) thread_state {
        return @atomicLoad(thread_state, &th.state, .acquire);
    }

    pub fn stack(th: *Thread) *Stack {
        return &th.context.stack;
    }

    /// Suspend the calling thread (the thread must be the current one).
    pub fn internalSuspend(th: *Thread) void {
        if (tr.thread) trace.print("Thread.internalSuspend() @{*} {s}\n", .{ th, th.name });
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            port.scheduler.prepareSuspend();
            th.state = .suspended;
        }
        port.scheduler.reschedule();
    }

    /// Terminate the calling thread; the idle thread destroys it later.
    pub fn internalExit(th: *Thread, exit_ptr: ?*anyopaque) noreturn {
        if (tr.thread) trace.print("Thread.internalExit() @{*} {s}\n", .{ th, th.name });
        assert(!interrupts.inHandlerMode());
        {
            const scs = scheduler.KernelCriticalSection.enter();
            defer scs.exit();
            {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                // Remove the thread from the ready list and from its parent.
                th.ready_node.links.unlink();
                th.child_links.unlink();
            }
            assert(th.children.isEmpty());
            th.parent = null;
            th.func = null;
            th.func_args = null;
            assert(th.mutexes.isEmpty());
            assert(th.acquired_mutexes == 0);
            th.func_result = exit_ptr;
        }
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            // Add to the funeral list; the idle thread destroys it.
            scheduler.terminated_threads_list.link(&th.ready_node);
        }
        port.scheduler.reschedule();
        while (true) {}
    }

    /// Re-link the outgoing running thread to the ready list (from the
    /// context switch).
    pub fn internalRelinkRunning(th: *Thread) void {
        if (th.state != .running) return;
        if (th.ready_node.links.isUnlinked()) {
            scheduler.ready_threads_list.link(&th.ready_node);
        }
        // A simple test that the thread did not underflow its stack.
        if (th.context.stack.bottom_address != null and !th.context.stack.checkBottomMagic()) {
            trace.print("\nstack underflow @{*} {s}\n", .{ th, th.name });
            @panic("thread stack underflow");
        }
    }

    fn internalCheckStack(th: *Thread) void {
        if (th.context.stack.size() == 0) return;
        if (!th.context.stack.checkBottomMagic() or !th.context.stack.checkTopMagic()) {
            trace.print("internalCheckStack() @{*} {s}\n", .{ th, th.name });
            assert(th.context.stack.checkBottomMagic());
            assert(th.context.stack.checkTopMagic());
        }
        if (tr.thread) trace.print("internalCheckStack() @{*} {s} stack: {d}/{d} bytes used\n", .{
            th, th.name, th.context.stack.size() - th.context.stack.available(), th.context.stack.size(),
        });
        th.context.stack.clear();
    }

    /// Release the resources of a terminated (or killed) thread and wake the
    /// joiner. Called by the idle thread or by `kill()`.
    pub fn internalDestroy(th: *Thread) void {
        if (tr.thread) trace.print("Thread.internalDestroy() @{*} {s}\n", .{ th, th.name });
        th.internalCheckStack();

        if (th.allocated_stack) |bytes| {
            th.allocator.?.free(bytes);
            th.allocated_stack = null;
        }

        {
            const scs = scheduler.KernelCriticalSection.enter();
            defer scs.exit();
            // Release the mutexes the thread still owns.
            while (th.mutexes.popFirst()) |links| {
                const mx: *Mutex = @alignCast(@fieldParentPtr("owner_links", links));
                mx.internalMarkOwnerDead();
                mx.internalUnlock(th) catch {};
            }
        }

        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            @atomicStore(thread_state, &th.state, .destroyed, .release);
            if (th.joiner) |joiner| {
                joiner.@"resume"();
            }
        }
        port.scheduler.reschedule();
    }

    /// Force the thread to terminate and release its resources.
    pub fn kill(th: *Thread) Error!void {
        if (tr.thread) trace.print("Thread.kill() @{*} {s}\n", .{ th, th.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;

        const scs = scheduler.KernelCriticalSection.enter();
        defer scs.exit();

        if (ncpu > 1) {
            // On SMP the thread may be running on another CPU (typically
            // still inside its own internalExit()), or be claimed by an idle
            // reaper. Wait, with the lock released, until it is off every CPU
            // and unclaimed; from then on the lock keeps it so.
            while (true) {
                if (th.getState() == .destroyed) break;

                var busy = @atomicLoad(?[*]StackElement, &th.context.port.stack_ptr, .acquire) == null;
                var busy_cpu: usize = ncpu;
                for (&scheduler.current_thread, 0..) |*ct, c| {
                    if (@atomicLoad(?*Thread, ct, .acquire) == th) {
                        busy = true;
                        busy_cpu = c;
                        break;
                    }
                }
                const st = th.getState();
                if (st == .destroying) busy = true;
                if (st == .terminated and th.ready_node.links.isUnlinked()) busy = true; // reaper claimed it
                if (!busy) break;

                if (busy_cpu < ncpu and busy_cpu != port.scheduler.cpuId()) {
                    port.scheduler.ipi(@intCast(busy_cpu));
                }
                {
                    const us = scheduler.KernelUncriticalSection.enter();
                    defer us.exit();
                    this_thread.yield();
                }
            }
        }

        if (th.state == .destroyed) {
            if (tr.thread) trace.print("Thread.kill() @{*} {s} already gone\n", .{ th, th.name });
            return;
        }

        var we_claimed = false;
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            if (th.state != .destroying and th.state != .destroyed) {
                we_claimed = true;
                th.state = .destroying;
                // Remove the thread from the ready/funeral list, from the
                // object it waits for, and from the clock list.
                th.ready_node.links.unlink();
                if (th.waiting_node) |n| n.links.unlink();
                if (th.clock_node) |n| n.node.links.unlink();
                th.child_links.unlink();
            }
        }

        if (!we_claimed) {
            // Someone else is destroying it; wait until done.
            while (th.getState() != .destroyed) {
                const us = scheduler.KernelUncriticalSection.enter();
                defer us.exit();
                this_thread.yield();
            }
            return;
        }

        assert(th.children.isEmpty());
        th.parent = null;
        th.func_result = null;
        th.func = null;
        th.func_args = null;

        th.internalDestroy();

        assert(th.mutexes.isEmpty());
        assert(th.acquired_mutexes == 0);
    }

    // ------------------------------------------------------------------------
    // Thread event flags.

    /// Raise flags of this thread and resume it; may be called from ISRs.
    /// Returns the previous flags.
    pub fn flagsRaise(th: *Thread, mask: flags.Mask) Error!flags.Mask {
        if (tr.thread_flags) trace.print("Thread.flagsRaise(0x{X}) @{*} {s}\n", .{ mask, th, th.name });
        assert(interrupts.isPriorityValid());
        const prev = blk: {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            break :blk try th.event_flags.raise(mask);
        };
        th.@"resume"();
        return prev;
    }

    /// Clear flags of this thread; returns the previous flags.
    pub fn flagsClear(th: *Thread, mask: flags.Mask) Error!flags.Mask {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return th.event_flags.clear(mask);
    }

    fn internalFlagsWait(th: *Thread, mask: flags.Mask, mode: flags.Mode) Error!flags.Mask {
        if (tr.thread_flags) trace.print("this_thread.flagsWait(0x{X}) @{*} {s}\n", .{ mask, th, th.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (scheduler.locked()) return error.NotPermitted;
        while (true) {
            {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                if (th.event_flags.checkRaised(mask, mode)) |matched| return matched;
            }
            th.internalSuspend();
            if (th.isInterrupted()) return error.Interrupted;
        }
    }

    fn internalFlagsTryWait(th: *Thread, mask: flags.Mask, mode: flags.Mode) Error!flags.Mask {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return th.event_flags.checkRaised(mask, mode) orelse error.WouldBlock;
    }

    fn internalFlagsTimedWait(th: *Thread, mask: flags.Mask, timeout: clocks.Duration, mode: flags.Mode) Error!flags.Mask {
        if (tr.thread_flags) trace.print("this_thread.flagsTimedWait(0x{X}, {d}) @{*} {s}\n", .{ mask, timeout, th, th.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (scheduler.locked()) return error.NotPermitted;
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            if (th.event_flags.checkRaised(mask, mode)) |matched| return matched;
        }

        const clock_list = &th.clock.steady_list;
        const timeout_timestamp = th.clock.steadyNow() + timeout;
        var timeout_node: lists.TimeoutThreadNode = .init(timeout_timestamp, th);

        while (true) {
            {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                if (th.event_flags.checkRaised(mask, mode)) |matched| return matched;
                port.scheduler.prepareSuspend();
                clock_list.link(&timeout_node.node);
                th.clock_node = &timeout_node;
                th.state = .suspended;
            }
            port.scheduler.reschedule();
            {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                // Remove the node from the clock list, if the tick did not.
                th.clock_node = null;
                timeout_node.node.links.unlink();
            }
            if (th.isInterrupted()) return error.Interrupted;
            if (th.clock.steadyNow() >= timeout_timestamp) return error.TimedOut;
        }
    }
};

/// A thread with its stack embedded (`thread_inclusive<N>`).
pub fn ThreadInclusive(comptime stack_size_bytes: usize) type {
    return struct {
        thread: Thread,
        stack: [stack_size_bytes / @sizeOf(StackElement)]StackElement align(8),

        const Self = @This();

        pub fn init(self: *Self, name: [:0]const u8, function: Func, args: ?*anyopaque, attr: Attributes) Error!void {
            var a = attr;
            a.stack = &self.stack;
            return self.thread.init(name, function, args, a, null);
        }

        pub fn deinit(self: *Self) void {
            self.thread.deinit();
        }
    };
}

// ----------------------------------------------------------------------------

/// Functions acting on the calling thread (`os::rtos::this_thread`).
pub const this_thread = struct {
    /// The current thread, or null before any thread exists.
    pub fn get() ?*Thread {
        if (config.smp) {
            // Read the CPU index and that CPU's current thread with the
            // interrupts masked; otherwise a preemption between the two reads
            // could move the caller to another CPU and return the thread now
            // running on the CPU it left.
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            return scheduler.current_thread[port.scheduler.cpuId()];
        }
        return scheduler.current_thread[0];
    }

    /// The current thread; must not be called from interrupt handlers.
    pub fn thread() *Thread {
        assert(!interrupts.inHandlerMode());
        return get().?;
    }

    /// Request a context switch to a ready thread of equal or higher
    /// priority.
    pub fn yield() void {
        assert(!interrupts.inHandlerMode());
        if (!scheduler.started()) return;
        if (tr.thread_context) trace.print("this_thread.yield()\n", .{});
        port.scheduler.reschedule();
    }

    /// Suspend the current thread until resumed.
    pub fn @"suspend"() void {
        thread().internalSuspend();
    }

    /// Terminate the current thread.
    pub fn exit(exit_ptr: ?*anyopaque) noreturn {
        thread().internalExit(exit_ptr);
    }

    /// Wait for thread event flags.
    pub fn flagsWait(mask: flags.Mask, mode: flags.Mode) Error!flags.Mask {
        return thread().internalFlagsWait(mask, mode);
    }

    pub fn flagsTryWait(mask: flags.Mask, mode: flags.Mode) Error!flags.Mask {
        return thread().internalFlagsTryWait(mask, mode);
    }

    pub fn flagsTimedWait(mask: flags.Mask, timeout: clocks.Duration, mode: flags.Mode) Error!flags.Mask {
        return thread().internalFlagsTimedWait(mask, timeout, mode);
    }

    /// Get (and optionally clear) the thread's flags.
    pub fn flagsGet(mask: flags.Mask, mode: flags.Mode) flags.Mask {
        assert(!interrupts.inHandlerMode());
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return thread().event_flags.get(mask, mode);
    }

    pub fn flagsClear(mask: flags.Mask) Error!flags.Mask {
        return thread().flagsClear(mask);
    }

    /// Sleep on `sysclock` (convenience; see `Clock.sleepFor`).
    pub fn sleepFor(ticks: clocks.Duration) Error!void {
        return clocks.sysclock.sleepFor(ticks);
    }
};
