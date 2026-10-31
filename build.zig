const std = @import("std");
/// iOS app bundles, for nanoui's examples and for apps:
/// `@import("nanoui").ios.app(b, exe, .{ .name = "Notes", .id = "com.example.notes" })`.
pub const ios = @import("tools/ios/bundle.zig");
/// Android APKs, likewise: `@import("nanoui").android.apk(b, lib, .{ .name = "Notes", .id = "com.example.notes" })`.
pub const android = @import("tools/android/apk.zig");

const examples = [_][]const u8{ "hello", "counter", "gallery", "duo", "board", "basics", "map" };
const frameworks = [_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers", "CoreVideo" };
const ios_frameworks = [_][]const u8{ "UIKit", "CoreLocation", "MapKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers", "CoreVideo" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const portable = b.option(bool, "portable", "Use portable text and CPU rendering instead of native rasterization (for tests)") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "portable", portable);
    // The one place the version is kept: build.zig.zon (tools/version.sh).
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const nanoui = b.addModule("nanoui", .{
        .root_source_file = b.path("src/nanoui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nanoui.addOptions("build_options", options);
    const os = target.result.os.tag;
    if (os == .macos) {
        // A target other than this Mac's (an older macOS for a release,
        // `-Dtarget=aarch64-macos.13.0`) gets no SDK from Zig: use Xcode's.
        if (!target.query.isNative()) {
            if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
                nanoui.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
                nanoui.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
            }
        }
        for (frameworks) |f| nanoui.linkFramework(f, .{});
        nanoui.linkSystemLibrary("objc", .{});
    } else if (os == .ios) {
        // Never this machine: the SDK is Xcode's, the device's or the
        // Simulator's (`-Dtarget=aarch64-ios`, `aarch64-ios-simulator`).
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            nanoui.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            nanoui.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
        for (ios_frameworks) |f| nanoui.linkFramework(f, .{});
        nanoui.linkSystemLibrary("objc", .{});
    }
    if (target.result.abi.isAndroid()) {
        // The NDK's libraries; OpenGL ES is loaded with dlopen.
        if (android.Sdk.find(b)) |sdk| if (sdk.libDir(b, target.result)) |dir| nanoui.addLibraryPath(.{ .cwd_relative = dir });
        for ([_][]const u8{ "android", "log", "EGL" }) |l| nanoui.linkSystemLibrary(l, .{});
    }
    // Elsewhere GTK is loaded when the app starts (dlopen): nothing to link.
    // HTTP there is http-zig's (nanoui.http), fetched only for those targets.
    if (os != .macos and os != .ios) {
        if (b.lazyDependency("http_zig", .{ .target = target, .optimize = optimize })) |d| nanoui.addImport("http_zig", d.module("http_zig"));
    }

    // nui: the command that makes and checks apps (tools/nui).
    const nui_options = b.addOptions();
    nui_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const nui = b.addExecutable(.{ .name = "nui", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/nui/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = nui_options.createModule() }},
    }) });
    // A command for desktops: not part of a phone's build.
    if (os != .ios and !target.result.abi.isAndroid()) b.installArtifact(nui);
    b.step("nui", "Build zig-out/bin/nui").dependOn(&b.addInstallArtifact(nui, .{}).step);
    const nui_tests = b.addTest(.{ .root_module = nui.root_module });
    b.step("test-nui", "Test nui").dependOn(&b.addRunArtifact(nui_tests).step);

    for (examples) |name| {
        // Pages (the hello example) need a webview: macOS for now.
        if (os != .macos and std.mem.eql(u8, name, "hello")) continue;
        if (os == .ios) {
            addIosExample(b, name, target, optimize, nanoui);
            continue;
        }
        if (target.result.abi.isAndroid()) {
            addAndroidExample(b, name, target, optimize, nanoui);
            continue;
        }
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "nanoui", .module = nanoui }},
            }),
        });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name})).dependOn(&run.step);

        if (std.mem.eql(u8, name, "hello")) {
            const gen = b.addRunArtifact(exe);
            gen.addArg("--nanoui-generate=examples/hello/frontend");
            b.step("gen", "Write the hello example's generated client").dependOn(&gen.step);
        }
    }

    // The 30-second reel of ui.motion (tools/reel.sh adds the sound).
    const reel = b.addExecutable(.{
        .name = "nanoui-reel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/reel/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    b.step("reel", "Build the motion reel (zig-out/bin/nanoui-reel)").dependOn(&b.addInstallArtifact(reel, .{}).step);

    const tests = b.addTest(.{ .root_module = nanoui });
    // On Android, the tests are a program for a device (`adb push`, run in `adb shell`).
    if (target.result.abi.isAndroid()) if (android.Sdk.find(b)) |sdk| {
        _ = android.linkNdk(b, tests, sdk);
    };
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
    // The tests as a program, for another machine (Linux in a container).
    const test_bin = b.addInstallArtifact(tests, .{ .dest_sub_path = if (os == .windows) "nanoui-tests.exe" else "nanoui-tests" });
    b.step("test-bin", "Install the unit tests as zig-out/bin/nanoui-tests").dependOn(&test_bin.step);

    // The Android tools' own tests (zip writing, versions, the manifest), on this machine.
    const tools_step = b.step("test-tools", "Test the Android build tools");
    for ([_][]const u8{ "tools/android/pack.zig", "tools/android/apk.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = b.graph.host }) });
        tools_step.dependOn(&b.addRunArtifact(t).step);
    }

    const lines = b.addExecutable(.{
        .name = "lines",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lines.zig"),
            .target = b.graph.host,
        }),
    });
    const check = b.addRunArtifact(lines);
    check.setCwd(b.path("."));
    b.step("lines", "Check that every file is at most 600 lines").dependOn(&check.step);
}

/// An example as an iOS app: `zig-out/ios/<Name>.app`, and `run-<name>`
/// in the booted Simulator (a device installs it signed, from Xcode or
/// `xcrun devicectl`).
fn addIosExample(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, nanoui: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    const title = b.fmt("{c}{s}", .{ std.ascii.toUpper(name[0]), name[1..] });
    const opts: ios.Options = .{
        .name = title,
        .id = b.fmt("dev.nanoui.{s}", .{name}),
        .location_usage = if (std.mem.eql(u8, name, "basics") or std.mem.eql(u8, name, "map")) "The example shows where you are." else null,
    };
    const bundle = ios.app(b, exe, opts);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = bundle, .install_dir = .prefix, .install_subdir = b.fmt("ios/{s}.app", .{title}) }).step);
    const step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example in the booted Simulator", .{name}));
    if (target.result.abi == .simulator) {
        const run = ios.runInSimulator(b, bundle, opts, b.path("."));
        run.addPassthruArgs();
        step.dependOn(&run.step);
    } else step.dependOn(&b.addFail("run-* runs in the Simulator (-Dtarget=aarch64-ios-simulator); install on a device from Xcode or with xcrun devicectl").step);
}

/// An example as an Android app: `zig-out/android/<Name>.apk`, and
/// `run-<name>` on the device adb sees (an emulator, a phone).
fn addAndroidExample(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, nanoui: *std.Build.Module) void {
    const lib = android.library(b, .{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
        .nanoui = nanoui,
    });
    const title = b.fmt("{c}{s}", .{ std.ascii.toUpper(name[0]), name[1..] });
    const opts: android.Options = .{ .name = title, .id = b.fmt("dev.nanoui.{s}", .{name}) };
    const apk = android.apk(b, lib, opts);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(apk, .prefix, b.fmt("android/{s}.apk", .{title})).step);
    const run = android.runOnDevice(b, apk, opts, b.path("."));
    run.addPassthruArgs();
    b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example on the device adb sees", .{name})).dependOn(&run.step);
}
