//! pipeline/pipeline.zig -- one round of the capstone's pipeline.
//! (C++: app/pipeline/pipeline.*.)
//!
//! Four producers, one per sample source (data/samples.zig), each make 64
//! samples -- ids and values from the course's generator, seeded per round --
//! and send their addresses through one message queue to a consumer. The
//! consumer checks every sample lies where its source says, links them all
//! into one list, sorts it and takes its maximum, and compares the result with
//! the course's reference. Only then does it release the producers, which own
//! their samples: the stack producer's must outlive the consumer's use, the
//! heap and pool ones are given back by their producer.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");
const config = @import("../core/config.zig");
const threads = @import("../core/threads.zig");
const samples = @import("../data/samples.zig");

const rtos = uos.rtos;
const Sample = tutor.Sample;
const Source = samples.Source;

pub const RoundResult = struct {
    received: u32 = 0, // samples taken from the queue
    misplaced: u32 = 0, // not in their source's region, or seal broken
    shortfall: u32 = 0, // samples a producer could not get (pool or heap)
    checksum: u32 = 0,
    want_checksum: u32 = 0,
    max_value: i32 = -1,
    max_id: u32 = 0,
    matches: bool = false, // order, checksum and maximum are the reference's
    producer_core: [config.producers]u32 = @splat(99),
    consumer_core: u32 = 99,
};

const ProducerJob = struct {
    from: Source,
    seed: u32,
    first: u32, // its first id
    shortfall: u32 = 0,
    core: u32 = 99,
};

var s_queue: rtos.MessageQueueTyped(?*Sample).Static(32) = .{};
var s_queue_up = false;
var s_release: rtos.Semaphore = .counting("release", config.producers, 0);
var s_producer: [config.producers]*rtos.Thread = undefined;
var s_result: RoundResult = .{};

fn fill(s: *Sample, id: u32, seed: u32, from: Source) void {
    s.init(id, tutor.generate(seed, id), samples.regionOf(from));
}

fn producer(arg: ?*anyopaque) ?*anyopaque {
    const j: *ProducerJob = @ptrCast(@alignCast(arg.?));
    j.core = board.cpuSlot();
    var local: [config.per_producer]Sample = @splat(.{}); // the stack source's samples
    var mine: [config.per_producer]?*Sample = @splat(null);

    for (0..config.per_producer) |i| {
        const s: ?*Sample = switch (j.from) {
            .data => &samples.staticSamples()[i],
            .stack => &local[i],
            else => samples.take(j.from),
        };
        if (s) |p| {
            mine[i] = p;
            fill(p, j.first + @as(u32, @intCast(i)), j.seed, j.from);
        } else {
            j.shortfall += 1;
        }
        // A hole too: the consumer counts on per_round messages.
        s_queue.typed.send(s, 0) catch {};
    }

    // The samples are ours: keep them until the consumer is done.
    s_release.wait() catch {};
    for (mine) |m| {
        if (m) |p| samples.giveBack(j.from, p);
    }
    return null;
}

// The owner a sample's placement is checked against: for a stack sample, the
// producer whose stack it is in.
fn ownerOf(s: *const Sample) *rtos.Thread {
    const k = (s.id - config.first_id) / config.per_producer;
    return s_producer[if (k < config.producers) k else 0];
}

fn consumer(_: ?*anyopaque) ?*anyopaque {
    const r = &s_result;
    r.consumer_core = board.cpuSlot();
    var list: tutor.SampleList = .{};
    for (0..config.per_round) |_| {
        const got = s_queue.typed.receive() catch null;
        const s = got orelse continue;
        r.received += 1;
        if (!tutor.placed(s, ownerOf(s))) r.misplaced += 1;
        list.push(s);
    }
    tutor.sortList(&list);
    const m = tutor.maxOf(list);
    r.checksum = tutor.checksum(list);
    r.max_value = if (m) |x| x.value else -1;
    r.max_id = if (m) |x| x.id else 0;
    for (0..config.producers) |_| s_release.post() catch {};
    return null;
}

/// Round r: seed seed_base + r. Creates the five threads, runs them, reaps
/// them.
pub fn runRound(rnd: u32) RoundResult {
    if (!s_queue_up) {
        s_queue.init("samples", .{}) catch {};
        s_queue_up = true;
    }
    const seed = config.seed_base + rnd;
    s_result = .{};
    var jobs: [config.producers]ProducerJob = undefined;
    for (0..config.producers) |k| {
        jobs[k] = .{ .from = @enumFromInt(k), .seed = seed, .first = config.first_id + @as(u32, @intCast(k)) * config.per_producer };
    }

    // The producers first (they wait on the queue only when it is full), then
    // the consumer; the main thread, above them all, starts them all.
    var started: u32 = 0;
    for (0..config.producers) |k| {
        if (threads.spawn("producer", producer, &jobs[k], config.prio_worker, config.coreProducer(@intCast(k)))) |t| {
            s_producer[k] = t;
            started += 1;
        }
    }
    const cons = threads.spawn("consumer", consumer, null, config.prio_worker, config.core_consumer);
    if (cons) |c| threads.reap(c);
    for (0..started) |k| threads.reap(s_producer[k]);

    var r = s_result;
    for (0..config.producers) |k| {
        r.shortfall += jobs[k].shortfall;
        r.producer_core[k] = jobs[k].core;
    }
    const want = tutor.reference(seed, config.first_id, config.per_round);
    r.want_checksum = want.sorted_checksum;
    r.matches = r.received == config.per_round and r.checksum == want.sorted_checksum and r.max_value == want.max_value and r.max_id == want.max_id;
    return r;
}
