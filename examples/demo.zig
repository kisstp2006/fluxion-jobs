// SPDX-License-Identifier: BSL-1.0

//! A tour of Fluxion Jobs. Run it with `zig build example`.
//!
//! It renders a Mandelbrot set as tiles, once with every core and once with
//! none - the second being exactly what the browser build does - and shows
//! that both produce the same picture, and a dependency graph that assembles
//! a "material" from three "decodes" that ran in whatever order they liked.

const std = @import("std");
const Io = std.Io;
const jobs_lib = @import("fluxion_jobs");
const Jobs = jobs_lib.Jobs;

const width = 512;
const height = 512;
const tile = 32;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    // --- the same work, with workers and without ------------------------

    const threaded = try gpa.alloc(u8, width * height);
    const alone = try gpa.alloc(u8, width * height);

    try out.print("--- {d}x{d} in {d}x{d} tiles ---\n", .{ width, height, tile, tile });
    const with = try render(gpa, .{ .io = io, .workers = .auto }, threaded, io);
    try out.print("{d: >2} workers: {d} ms\n", .{ with.workers, with.ms });
    const without = try render(gpa, .{ .io = null }, alone, io);
    try out.print("{d: >2} workers: {d} ms (the browser's way)\n", .{ without.workers, without.ms });
    try out.print("same picture: {}\n\n", .{std.mem.eql(u8, threaded, alone)});

    // --- a dependency graph ---------------------------------------------

    var jobs: Jobs = try .init(gpa, .{ .io = io });
    defer jobs.deinit();

    var log: Log = .{};
    const albedo = try jobs.spawn(decode, .{ &log, "albedo" });
    const normal = try jobs.spawn(decode, .{ &log, "normal" });
    const rough = try jobs.spawn(decode, .{ &log, "roughness" });
    const material = try jobs.spawnAfter(&.{ albedo, normal, rough }, assemble, .{&log});
    jobs.wait(material);

    try out.print("--- three decodes, then one assemble ---\n", .{});
    for (log.lines[0..log.count]) |line| try out.print("{s}\n", .{line});

    // --- fork and join --------------------------------------------------

    const values = try gpa.alloc(u64, 1 << 20);
    for (values, 0..) |*v, i| v.* = i;
    try jobs_lib.parallel.forSlice(&jobs, u64, values, 4096, square);
    try out.print("\n--- a million squares, in chunks of 4096 ---\n", .{});
    try out.print("values[1000] = {d}\n", .{values[1000]});

    try out.flush();
}

// -------------------------------------------------------------------------
// Tiles
// -------------------------------------------------------------------------

const Rendered = struct { workers: usize, ms: u64 };

fn render(gpa: std.mem.Allocator, options: Jobs.Options, into: []u8, io: Io) !Rendered {
    var jobs: Jobs = try .init(gpa, options);
    defer jobs.deinit();

    const started = Io.Timestamp.now(io, .awake);
    var y: u32 = 0;
    while (y < height) : (y += tile) {
        var x: u32 = 0;
        while (x < width) : (x += tile) {
            _ = try jobs.spawn(renderTile, .{ into, x, y });
        }
    }
    jobs.waitAll();
    const finished = Io.Timestamp.now(io, .awake);

    return .{
        .workers = jobs.workerCount(),
        .ms = @intCast(@divTrunc(finished.nanoseconds - started.nanoseconds, std.time.ns_per_ms)),
    };
}

/// One tile of the Mandelbrot set, as iteration counts.
fn renderTile(into: []u8, x0: u32, y0: u32) void {
    var y: u32 = y0;
    while (y < y0 + tile) : (y += 1) {
        var x: u32 = x0;
        while (x < x0 + tile) : (x += 1) {
            into[y * width + x] = escape(x, y);
        }
    }
}

fn escape(px: u32, py: u32) u8 {
    const cx = (@as(f64, @floatFromInt(px)) / width) * 3.0 - 2.0;
    const cy = (@as(f64, @floatFromInt(py)) / height) * 2.0 - 1.0;
    var zx: f64 = 0;
    var zy: f64 = 0;
    var i: u8 = 0;
    while (i < 255 and zx * zx + zy * zy < 4.0) : (i += 1) {
        const nx = zx * zx - zy * zy + cx;
        zy = 2 * zx * zy + cy;
        zx = nx;
    }
    return i;
}

// -------------------------------------------------------------------------
// The graph
// -------------------------------------------------------------------------

const Log = struct {
    lines: [8][]const u8 = undefined,
    count: usize = 0,
    mutex: std.Io.Mutex = .init,
};

fn decode(log: *Log, what: []const u8) void {
    // Pretend to work for an amount that depends on the name, so the three
    // finish in an order the graph must not depend on.
    var spin: u64 = 0;
    for (0..what.len * 100_000) |i| spin +%= i;
    std.mem.doNotOptimizeAway(spin);
    append(log, what);
}

fn assemble(log: *Log) void {
    append(log, "material, from all three");
}

fn append(log: *Log, line: []const u8) void {
    // Workers may finish at once; the log is shared.
    while (!log.mutex.tryLock()) std.atomic.spinLoopHint();
    defer log.mutex.state.store(.unlocked, .release);
    if (log.count < log.lines.len) {
        log.lines[log.count] = line;
        log.count += 1;
    }
}

fn square(chunk: []u64) void {
    for (chunk) |*v| v.* = v.* * v.*;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the tiles come out the same with and without workers" {
    const gpa = std.testing.allocator;
    const a = try gpa.alloc(u8, width * height);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, width * height);
    defer gpa.free(b);
    _ = try render(gpa, .{ .io = std.testing.io }, a, std.testing.io);
    _ = try render(gpa, .{ .io = null }, b, std.testing.io);
    try std.testing.expectEqualSlices(u8, a, b);
}
