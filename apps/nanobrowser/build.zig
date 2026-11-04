const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const portable = b.option(bool, "portable", "nanoui's own text and CPU renderer on macOS too") orelse false;
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize, .portable = portable }).module("nanoui");

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    const exe = b.addExecutable(.{ .name = "nanobrowser", .root_module = root });
    // nanoui links WebKit for pages, which this app doesn't show: it draws
    // pages itself, and the framework shouldn't even be loaded.
    exe.dead_strip_dylibs = true;
    // A script may recurse deep (its stack is checked against this): Windows
    // gives a main thread 1 MB unless asked; elsewhere the system's 8 MB.
    if (target.result.os.tag == .windows) exe.stack_size = 16 << 20;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanobrowser").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
