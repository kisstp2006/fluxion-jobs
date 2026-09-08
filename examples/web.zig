// SPDX-License-Identifier: BSL-1.0

//! Fluxion Jobs in a browser. Built by `zig build web` into
//! `zig-out/web/`, and driven by `index.html` next to it.
//!
//! The same scheduler as the native demo, with no `Io` and so no workers.
//! The page's frame callback calls `tick` with how many jobs it can afford
//! this frame; the rest wait. Nothing in here is different for the browser
//! except that the entry points are exported instead of called.

const std = @import("std");
const jobs_lib = @import("fluxion_jobs");
const Jobs = jobs_lib.Jobs;

const gpa = std.heap.wasm_allocator;

var jobs: ?Jobs = null;
var pixels: []u8 = &.{};
var width: u32 = 0;
var height: u32 = 0;
var tile: u32 = 32;

/// Set up a picture of `w` by `h` in tiles of `t`, and spawn one job per
/// tile. Returns how many jobs there are, or zero if something failed.
export fn start(w: u32, h: u32, t: u32) u32 {
    stop();
    width = w;
    height = h;
    tile = @max(t, 1);

    pixels = gpa.alloc(u8, w * h * 4) catch return 0;
    @memset(pixels, 0);

    const tiles_x = (w + tile - 1) / tile;
    const tiles_y = (h + tile - 1) / tile;
    jobs = Jobs.init(gpa, .{ .capacity = tiles_x * tiles_y + 1 }) catch return 0;

    var count: u32 = 0;
    var y: u32 = 0;
    while (y < h) : (y += tile) {
        var x: u32 = 0;
        while (x < w) : (x += tile) {
            _ = jobs.?.spawn(renderTile, .{ x, y }) catch return count;
            count += 1;
        }
    }
    return count;
}

/// Run up to `budget` jobs. Returns how many are still waiting.
export fn tick(budget: u32) u32 {
    const js = &(jobs orelse return 0);
    _ = js.runUpTo(budget);
    return js.pending();
}

/// Where the RGBA pixels are, for the page to draw straight from memory.
export fn pixelsPtr() [*]u8 {
    return pixels.ptr;
}

export fn pixelsLen() u32 {
    return @intCast(pixels.len);
}

/// Whether this build has worker threads. In a browser, never - which is the
/// point being made.
export fn workers() u32 {
    const js = &(jobs orelse return 0);
    return @intCast(js.workerCount());
}

export fn stop() void {
    if (jobs) |*js| js.deinit();
    jobs = null;
    if (pixels.len != 0) gpa.free(pixels);
    pixels = &.{};
}

fn renderTile(x0: u32, y0: u32) void {
    var y: u32 = y0;
    while (y < @min(y0 + tile, height)) : (y += 1) {
        var x: u32 = x0;
        while (x < @min(x0 + tile, width)) : (x += 1) {
            const i = escape(x, y);
            const at = (y * width + x) * 4;
            // A palette that makes the tiles visibly arrive.
            pixels[at + 0] = i *% 7;
            pixels[at + 1] = i *% 3;
            pixels[at + 2] = 255 - i;
            pixels[at + 3] = 255;
        }
    }
}

fn escape(px: u32, py: u32) u8 {
    const cx = (@as(f64, @floatFromInt(px)) / @as(f64, @floatFromInt(width))) * 3.0 - 2.0;
    const cy = (@as(f64, @floatFromInt(py)) / @as(f64, @floatFromInt(height))) * 2.0 - 1.0;
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
