const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const mac = target.result.os.tag == .macos;

    const exe = b.addExecutable(.{ .name = "nanocua", .root_module = module(b, "src/main.zig", target, optimize, nanoui, mac) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanocua (the control panel and the agents' server)").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module(b, "src/tests.zig", target, optimize, nanoui, mac) });
    b.step("test", "Run nanocua tests").dependOn(&b.addRunArtifact(tests).step);
    // The tests as a program, for another machine (Linux in a container).
    b.step("test-bin", "Install the tests as zig-out/bin/nanocua-tests").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = "nanocua-tests" }).step);
}

fn module(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, nanoui: *std.Build.Module, mac: bool) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    if (mac) {
        // The accessibility tree and events (ApplicationServices), pictures
        // of the screen (ScreenCaptureKit) and their encoding (ImageIO),
        // the global hot key that stops everything (Carbon).
        for ([_][]const u8{ "ApplicationServices", "CoreGraphics", "ImageIO", "ScreenCaptureKit", "Carbon", "AppKit" }) |f| mod.linkFramework(f, .{});
    }
    return mod;
}
