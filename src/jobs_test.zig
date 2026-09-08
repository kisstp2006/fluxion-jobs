// SPDX-License-Identifier: BSL-1.0

//! The scheduler, both ways: with workers and with none.
//!
//! Every test here runs twice - once with an `Io` and as many workers as the
//! machine will give, once with neither, which is the browser. The point is
//! that they pass the same way: the order jobs run in may differ, what they
//! did may not.

const std = @import("std");
const testing = std.testing;

const Jobs = @import("Jobs.zig");
const parallel = @import("parallel.zig");

const gpa = testing.allocator;

/// The two ways to make a scheduler.
const modes = [_]Jobs.Options{
    .{ .io = testing.io, .workers = .auto },
    .{ .io = null },
};

// -------------------------------------------------------------------------
// What a job does
// -------------------------------------------------------------------------

fn addOne(counter: *std.atomic.Value(u32)) void {
    _ = counter.fetchAdd(1, .monotonic);
}

fn writeAt(into: []u32, index: usize, value: u32) void {
    into[index] = value;
}

test "a spawned job runs, and a handle to it says when" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        var counter: std.atomic.Value(u32) = .init(0);
        const handle = try jobs.spawn(addOne, .{&counter});
        jobs.wait(handle);

        try testing.expectEqual(@as(u32, 1), counter.load(.monotonic));
        try testing.expect(jobs.isDone(handle));
        try testing.expectEqual(@as(u32, 0), jobs.pending());
        // Waiting again is free, and true of the handle for ever after.
        jobs.wait(handle);
    }
}

test "a thousand jobs each run exactly once" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        var counter: std.atomic.Value(u32) = .init(0);
        for (0..1000) |_| _ = try jobs.spawn(addOne, .{&counter});
        jobs.waitAll();

        try testing.expectEqual(@as(u32, 1000), counter.load(.monotonic));
    }
}

test "a job after others runs after them" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        // Each job records the order it ran in. Whatever that order is
        // across the first three, the fourth is last.
        var order: std.atomic.Value(u32) = .init(0);
        var ran_at: [4]u32 = .{ 0, 0, 0, 0 };
        const Record = struct {
            fn run(at: *u32, tick: *std.atomic.Value(u32)) void {
                at.* = tick.fetchAdd(1, .monotonic) + 1;
            }
        };

        const a = try jobs.spawn(Record.run, .{ &ran_at[0], &order });
        const b = try jobs.spawn(Record.run, .{ &ran_at[1], &order });
        const c = try jobs.spawn(Record.run, .{ &ran_at[2], &order });
        const d = try jobs.spawnAfter(&.{ a, b, c }, Record.run, .{ &ran_at[3], &order });
        jobs.wait(d);

        try testing.expectEqual(@as(u32, 4), ran_at[3]);
        try testing.expect(ran_at[0] != 0 and ran_at[1] != 0 and ran_at[2] != 0);
        // Waiting on `d` is waiting on all of them.
        try testing.expect(jobs.isDone(a) and jobs.isDone(b) and jobs.isDone(c));
    }
}

test "a chain of dependencies runs in order, however long" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        var trail: [200]u32 = undefined;
        var previous: Jobs.Handle = .none;
        for (0..trail.len) |i| {
            previous = try jobs.spawnAfter(&.{previous}, writeAt, .{ &trail, i, @as(u32, @intCast(i)) });
        }
        jobs.wait(previous);
        for (trail, 0..) |value, i| try testing.expectEqual(@as(u32, @intCast(i)), value);
    }
}

test "a dependency that is already done costs nothing and blocks nothing" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        var counter: std.atomic.Value(u32) = .init(0);
        const first = try jobs.spawn(addOne, .{&counter});
        jobs.wait(first);

        // `first` is done and its slot may already hold something else;
        // the handle still means "done", and `none` always does.
        const second = try jobs.spawnAfter(&.{ first, .none }, addOne, .{&counter});
        jobs.wait(second);
        try testing.expectEqual(@as(u32, 2), counter.load(.monotonic));
    }
}

test "a handle outlives its slot and still reads as done" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, .{ .io = mode.io, .workers = mode.workers, .capacity = 2 });
        defer jobs.deinit();

        var counter: std.atomic.Value(u32) = .init(0);
        const first = try jobs.spawn(addOne, .{&counter});
        jobs.wait(first);

        // Fill and recycle the slots several times over.
        for (0..10) |_| {
            const h = try jobs.spawn(addOne, .{&counter});
            jobs.wait(h);
        }
        try testing.expect(jobs.isDone(first));
        try testing.expectEqual(@as(u32, 11), counter.load(.monotonic));
    }
}

test "every slot taken is an error, not an allocation" {
    // With no workers, nothing finishes until asked to, so the slots fill.
    var jobs: Jobs = try .init(gpa, .{ .io = null, .capacity = 3 });
    defer jobs.deinit();

    var counter: std.atomic.Value(u32) = .init(0);
    _ = try jobs.spawn(addOne, .{&counter});
    _ = try jobs.spawn(addOne, .{&counter});
    _ = try jobs.spawn(addOne, .{&counter});
    try testing.expectError(error.TooManyJobs, jobs.spawn(addOne, .{&counter}));

    // Running one frees one.
    try testing.expect(jobs.runOne());
    _ = try jobs.spawn(addOne, .{&counter});
    jobs.waitAll();
    try testing.expectEqual(@as(u32, 4), counter.load(.monotonic));
}

test "every edge taken is an error too" {
    var jobs: Jobs = try .init(gpa, .{ .io = null, .capacity = 8, .edges = 2 });
    defer jobs.deinit();

    var counter: std.atomic.Value(u32) = .init(0);
    const a = try jobs.spawn(addOne, .{&counter});
    const b = try jobs.spawn(addOne, .{&counter});
    const c = try jobs.spawn(addOne, .{&counter});
    // Three dependencies, two edges: refused, and the two it took are
    // given back, so the next spawn with two works.
    try testing.expectError(error.TooManyEdges, jobs.spawnAfter(&.{ a, b, c }, addOne, .{&counter}));
    _ = try jobs.spawnAfter(&.{ a, b }, addOne, .{&counter});
    jobs.waitAll();
    try testing.expectEqual(@as(u32, 4), counter.load(.monotonic));
}

// -------------------------------------------------------------------------
// The browser's verbs
// -------------------------------------------------------------------------

test "without workers, jobs run when the caller says and not before" {
    var jobs: Jobs = try .init(gpa, .{ .io = null });
    defer jobs.deinit();
    try testing.expectEqual(@as(usize, 0), jobs.workerCount());

    var counter: std.atomic.Value(u32) = .init(0);
    for (0..10) |_| _ = try jobs.spawn(addOne, .{&counter});

    // Spawned, not run.
    try testing.expectEqual(@as(u32, 0), counter.load(.monotonic));
    try testing.expectEqual(@as(u32, 10), jobs.pending());

    // A frame's worth.
    try testing.expectEqual(@as(usize, 4), jobs.runUpTo(4));
    try testing.expectEqual(@as(u32, 4), counter.load(.monotonic));
    try testing.expectEqual(@as(u32, 6), jobs.pending());

    // The rest, and then there is nothing to run.
    try testing.expectEqual(@as(usize, 6), jobs.runUpTo(100));
    try testing.expect(!jobs.runOne());
    try testing.expectEqual(@as(u32, 10), counter.load(.monotonic));
}

test "a job can spawn jobs, and waiting on the outer one does not wait on the inner" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        const Outer = struct {
            fn run(js: *Jobs, counter: *std.atomic.Value(u32), inner: *Jobs.Handle) void {
                inner.* = js.spawn(addOne, .{counter}) catch unreachable;
            }
        };
        var counter: std.atomic.Value(u32) = .init(0);
        var inner: Jobs.Handle = .none;
        const outer = try jobs.spawn(Outer.run, .{ &jobs, &counter, &inner });
        jobs.wait(outer);
        // The inner job exists now; whether it has run yet is its own affair.
        try testing.expect(!inner.isNone());
        jobs.wait(inner);
        try testing.expectEqual(@as(u32, 1), counter.load(.monotonic));
    }
}

// -------------------------------------------------------------------------
// Fork and join
// -------------------------------------------------------------------------

test "a range in parallel covers every index once" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        const hits = try gpa.alloc(u32, 10_000);
        defer gpa.free(hits);
        @memset(hits, 0);

        const Mark = struct {
            fn run(all: []u32, begin: usize, stop: usize) void {
                for (all[begin..stop]) |*hit| hit.* += 1;
            }
        };
        try parallel.forEach(&jobs, hits.len, 97, hits, Mark.run);

        for (hits) |hit| try testing.expectEqual(@as(u32, 1), hit);
        try testing.expectEqual(@as(u32, 0), jobs.pending());
    }
}

test "a slice in parallel, chunk by chunk" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        var values: [1000]u64 = undefined;
        for (&values, 0..) |*v, i| v.* = i;

        const Square = struct {
            fn run(chunk: []u64) void {
                for (chunk) |*v| v.* = v.* * v.*;
            }
        };
        try parallel.forSlice(&jobs, u64, &values, 64, Square.run);
        for (values, 0..) |v, i| try testing.expectEqual(@as(u64, i * i), v);

        // An empty range is nothing to do, and not an error.
        try parallel.forSlice(&jobs, u64, values[0..0], 64, Square.run);
    }
}

test "the arguments are copied, so the caller's copy may go" {
    for (modes) |mode| {
        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        var out: [3]u32 = .{ 0, 0, 0 };
        {
            var value: u32 = 42;
            _ = try jobs.spawn(writeAt, .{ &out, 0, value });
            value = 7; // too late to matter
            _ = try jobs.spawn(writeAt, .{ &out, 1, value });
        }
        jobs.waitAll();
        try testing.expectEqual(@as(u32, 42), out[0]);
        try testing.expectEqual(@as(u32, 7), out[1]);
    }
}
