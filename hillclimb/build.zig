const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Benchmarks measure release code unless told otherwise.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default fast)") orelse .fast;
    const portable = b.option(bool, "portable", "Use portable text and CPU rasterizer") orelse false;

    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize, .portable = portable }).module("nanoui");
    const os = target.result.os.tag;
    const has_clay = os == .macos or (os == .linux and !target.result.abi.isAndroid());
    const opts = b.addOptions();
    opts.addOption(bool, "has_clay", has_clay);
    opts.addOption(bool, "portable", portable);

    const exe = b.addExecutable(.{
        .name = "hillclimb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nanoui", .module = nanoui },
                .{ .name = "build_options", .module = opts.createModule() },
            },
            .link_libc = true,
        }),
    });
    if (os == .ios) {
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
    }
    if (has_clay) {
        // Clay (a C layout library), for its twin of the scenes: its header
        // translated for Zig, and compiled with its implementation.
        const clay = b.dependency("clay", .{});
        const clay_c = b.addTranslateC(.{ .root_source_file = clay.path("clay.h"), .target = target, .optimize = optimize });
        exe.root_module.addImport("clay", clay_c.createModule());
        exe.root_module.addCSourceFile(.{ .file = clay.path("clay.h"), .flags = &.{ "-DCLAY_IMPLEMENTATION", "-O3" }, .language = .c });
    }
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("run", "Run the hill-climb benchmarks (headless)").dependOn(&run.step);
}
