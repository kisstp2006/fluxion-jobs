// SPDX-License-Identifier: BSL-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ident = b.dependency("fluxion_id", .{ .target = target, .optimize = optimize });

    // The importable module. Consumers do:
    //   const jobs = @import("fluxion_jobs");
    const mod = b.addModule("fluxion_jobs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_id", .module = ident.module("fluxion_id") },
        },
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-jobs-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build example
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluxion_jobs", .module = mod }},
    });
    const example = b.addExecutable(.{ .name = "fluxion-jobs-demo", .root_module = example_mod });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_example.addArgs(args);
    b.step("example", "Build and run the demo program").dependOn(&run_example.step);

    const example_tests = b.addTest(.{ .name = "fluxion-jobs-demo-tests", .root_module = example_mod });
    test_step.dependOn(&b.addRunArtifact(example_tests).step);

    // zig build web -> zig-out/web/{index.html, fluxion-jobs-web.wasm}
    //
    // The same library, for the browser: no threads, no Io, the page's frame
    // callback runs the jobs. Built for wasm32-freestanding whatever
    // -Dtarget says, because that is the only target a browser loads.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_ident = b.dependency("fluxion_id", .{ .target = wasm_target, .optimize = .ReleaseSmall });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "fluxion_id", .module = wasm_ident.module("fluxion_id") },
        },
    });
    const web_mod = b.createModule(.{
        .root_source_file = b.path("examples/web.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "fluxion_jobs", .module = wasm_mod }},
    });
    const web = b.addExecutable(.{ .name = "fluxion-jobs-web", .root_module = web_mod });
    web.entry = .disabled;
    web.rdynamic = true;

    const web_step = b.step("web", "Build the browser example into zig-out/web");
    web_step.dependOn(&b.addInstallArtifact(web, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    }).step);
    web_step.dependOn(&b.addInstallFile(b.path("examples/web/index.html"), "web/index.html").step);

    // The browser build is part of the test step too: a change that breaks
    // the no-thread path should fail here, not in a browser later.
    test_step.dependOn(web_step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{ .name = "fluxion-jobs", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&install_docs.step);
}
