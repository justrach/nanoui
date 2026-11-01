const std = @import("std");
/// iOS app bundles, for nanoui's examples and for apps:
/// `@import("nanoui").ios.app(b, exe, .{ .name = "Notes", .id = "com.example.notes" })`.
pub const ios = @import("tools/ios/bundle.zig");
/// Android APKs, likewise: `@import("nanoui").android.apk(b, lib, .{ .name = "Notes", .id = "com.example.notes" })`.
pub const android = @import("tools/android/apk.zig");

const examples = [_][]const u8{ "hello", "counter", "gallery", "duo", "board", "basics", "map", "turn", "access", "todo", "sgbus", "browser" };
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
        // The NDK's libraries; OpenGL ES is loaded with dlopen. Where the
        // host is Windows they are named as files, `-L` finding none there
        // (apk.zig's `libFile` says why).
        if (android.Sdk.find(b)) |sdk| {
            if (sdk.libDir(b, target.result)) |dir| nanoui.addLibraryPath(.{ .cwd_relative = dir });
            for ([_][]const u8{ "android", "log", "EGL" }) |l| {
                if (sdk.libFile(b, target.result, l)) |file| {
                    nanoui.addObjectFile(.{ .cwd_relative = file });
                } else nanoui.linkSystemLibrary(l, .{});
            }
        }
    }
    if (os == .windows) {
        // The D3D11 renderer (`ui/d3d11.zig`): d3d11 and dxgi are the
        // system's; d3dcompiler_47 turns the HLSL into shaders at startup,
        // and the Windows SDK has no import library for it (only the DLL),
        // so `ui/d3d11_glue.zig` loads it when it first compiles one.
        for ([_][]const u8{ "d3d11", "dxgi" }) |l| nanoui.linkSystemLibrary(l, .{});
    }
    // WebView2 (pages on Windows) is linked the way `d3dcompiler_47` is: at
    // no link time at all. `windows/webview2.zig` loads `WebView2Loader.dll`
    // with `LoadLibraryW`, and every COM call is a vtable slot. That is what
    // keeps the gnu ABI — Zig's default on Windows — building as well as the
    // MSVC one: the SDK's static loader is MSVC's C++ and its static CRT, and
    // would drag both into a `-gnu` binary.
    //
    // So the runtime dependency is that one DLL, and the build installs it
    // beside the executable. `-Dwebview2=none` builds without it (pages then
    // say the runtime is missing); `-Dwebview2=<folder>` uses a copy of your
    // own instead of the SDK's.
    if (os == .windows) {
        const webview2_dir = b.option([]const u8, "webview2", "WebView2's WebView2Loader.dll: 'sdk' (from the SDK), 'none', or a folder holding it") orelse "sdk";
        if (!std.mem.eql(u8, webview2_dir, "none")) {
            const dir = if (std.mem.eql(u8, webview2_dir, "sdk")) webview2Sdk(b) else webview2_dir;
            if (dir) |d| {
                const dll_path = b.pathJoin(&.{ d, "WebView2Loader.dll" });
                // Installed beside every executable the build installs.
                const dll = b.addInstallFile(.{ .cwd_relative = dll_path }, "bin/WebView2Loader.dll");
                b.getInstallStep().dependOn(&dll.step);
            }
        }
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
        // Pages (the hello and browser examples) need a webview: WKWebView on
        // macOS, WebView2 on Windows.
        if (os != .macos and os != .windows and (std.mem.eql(u8, name, "hello") or std.mem.eql(u8, name, "browser"))) continue;
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
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The accessibility demo, as VoiceOver reads it.
    if (!target.result.abi.isAndroid()) test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/access/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) })).step);
    // The SG bus example's planner, on its real stop lists (prints what it plans).
    const sg_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/sgbus/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("test-sgbus", "Test the SG bus example's journey planner").dependOn(&b.addRunArtifact(sg_tests).step);
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
        .location_usage = if (std.mem.eql(u8, name, "basics") or std.mem.eql(u8, name, "map") or std.mem.eql(u8, name, "sgbus")) "The example shows where you are." else null,
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

/// The WebView2 SDK's native folder (`.../build/native/x64`), where its import
/// and static libraries are: `-Dwebview2-sdk=` if given, else the newest in
/// the NuGet cache, else the one an installation (the MSI, a NuGet restore)
/// put under `CommonProgramFiles(x86)`.
fn webview2Sdk(b: *std.Build) ?[]const u8 {
    const abi = switch (b.graph.host.result.cpu.arch) {
        .x86_64, .aarch64 => @tagName(b.graph.host.result.cpu.arch),
        .x86 => "x86",
        else => return null,
    };
    const dir_name = if (b.graph.host.result.os.tag == .windows) blk: {
        break :blk switch (b.graph.host.result.cpu.arch) {
            .x86_64 => "x64",
            .aarch64 => "arm64",
            .x86 => "x86",
            else => return null,
        };
    } else abi;
    if (b.option([]const u8, "webview2-sdk", "The WebView2 SDK's build/native/<arch> folder")) |dir| {
        return if (hasLoader(b, dir)) dir else null;
    }
    const env = &b.graph.environ_map;
    const candidates = [_][]const u8{ "USERPROFILE", "HOME" };
    for (candidates) |name| {
        const home = env.get(name) orelse continue;
        const cache = b.pathJoin(&.{ home, ".nuget", "packages", "microsoft.web.webview2" });
        var dir = std.Io.Dir.cwd().openDir(b.graph.io, cache, .{ .iterate = true }) catch continue;
        defer dir.close(b.graph.io);
        var it = dir.iterate();
        var best: ?[]const u8 = null;
        var best_version: ?[]const u8 = null;
        while (it.next(b.graph.io) catch null) |e| {
            if (e.kind != .directory) continue;
            const native = b.pathJoin(&.{ cache, b.dupe(e.name), "build", "native", dir_name });
            if (!hasLoader(b, native)) continue;
            if (best_version == null or versionNewer(e.name, best_version.?)) {
                best_version = b.dupe(e.name);
                best = b.dupe(native);
            }
        }
        if (best) |found| return found;
    }
    if (env.get("CommonProgramFiles(x86)")) |common| {
        const native = b.pathJoin(&.{ common, "Microsoft Shared", "WebView2", dir_name });
        if (hasLoader(b, native)) return native;
    }
    std.log.warn("nanoui: no WebView2 SDK: pages can't be linked (pass -Dwebview2-sdk=<build/native/<arch>>)", .{});
    return null;
}

/// One dotted version after another ("1.0.4191.47"), numerically. A string
/// compare would put 1.0.99 ahead of 1.0.4191.
fn versionNewer(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next() orelse return false; // a ended: not newer
        const y = ib.next() orelse return true; // b ended, a went on: newer
        const nx = std.fmt.parseInt(u32, x, 10) catch return false;
        const ny = std.fmt.parseInt(u32, y, 10) catch return false;
        if (nx != ny) return nx > ny;
    }
}

fn hasLoader(b: *std.Build, dir: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(b.graph.io, dir, .{}) catch return false;
    defer d.close(b.graph.io);
    _ = d.statFile(b.graph.io, "WebView2Loader.dll", .{}) catch return false;
    return true;
}
