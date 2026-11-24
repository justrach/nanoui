//! `nui doctor`: checks Zig 0.17 and platform toolchains (GTK 4/3 and
//! WebKitGTK on Linux, Xcode/iOS SDK on macOS, Android SDK/NDK, WebView2 on Windows).
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("main.zig");
const proj = @import("project.zig");

pub fn run(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *cli.Out, rest: []const []const u8) !void {
    var target_spec: ?proj.TargetSpec = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (cli.eq(arg, "--target") or cli.eq(arg, "-t")) {
            i += 1;
            if (i >= rest.len) return out.fail("{s} needs a target", .{arg}, "nui doctor --target ios-sim");
            target_spec = proj.resolveTarget(rest[i]) orelse return out.fail("unknown target {s}", .{rest[i]}, "try macos, linux, windows, ios-sim, ios, android, web");
        } else {
            return out.fail("what is {s}?", .{arg}, "nui doctor [--target TARGET]");
        }
    }

    const r = std.process.run(a, io, .{ .argv = &.{ "zig", "version" } }) catch null;
    const zig_version = if (r) |x| std.mem.trim(u8, x.stdout, " \r\n") else "";
    const zig_ok = std.mem.startsWith(u8, zig_version, "0.17.");
    const os = @tagName(builtin.os.tag);
    if (zig_ok) out.step("✓ zig {s}", .{zig_version}) else out.step("✗ zig {s} (nanoui needs 0.17)", .{if (zig_version.len > 0) zig_version else "not found"});

    const gtk4 = if (builtin.os.tag == .linux) found("libgtk-4.so.1") else false;
    const gtk3 = if (builtin.os.tag == .linux) found("libgtk-3.so.0") else false;
    const gtk_ok = if (builtin.os.tag == .linux) (gtk4 or gtk3) else true;
    var webkit_ok = false;
    if (builtin.os.tag == .linux) {
        if (gtk4 and gtk3) {
            out.step("✓ GTK 4 and GTK 3", .{});
        } else if (gtk4) {
            out.step("✓ GTK 4 (libgtk-4.so.1)", .{});
        } else if (gtk3) {
            out.step("✓ GTK 3 (libgtk-3.so.0)", .{});
        } else {
            out.step("✗ GTK not found (libgtk-4-1 or libgtk-3-0)", .{});
        }
        const four = found("libwebkit2gtk-4.1.so.0") or found("libwebkit2gtk-4.0.so.37");
        const six = found("libwebkitgtk-6.0.so.4");
        webkit_ok = four or six;
        if (six and !four and bwrapRefuses(a, io))
            out.step("- WebKitGTK 6.0 can't start its sandbox here: web pages need libwebkit2gtk-4.1-0", .{})
        else if (webkit_ok)
            out.step("✓ WebKitGTK", .{})
        else
            out.step("- WebKitGTK not found: web pages need it (libwebkit2gtk-4.1-0)", .{});
    }

    const mac_sdk = if (builtin.os.tag == .macos) hasSdk(a, io, "macosx") else true;
    if (builtin.os.tag == .macos) {
        if (mac_sdk) out.step("✓ macOS SDK", .{}) else out.step("✗ macOS SDK not found (xcode-select --install)", .{});
    }

    const ios_sdk = if (builtin.os.tag == .macos) hasSdk(a, io, "iphonesimulator") else false;
    if (builtin.os.tag == .macos) {
        if (ios_sdk) out.step("✓ iOS Simulator SDK (optional)", .{}) else out.step("- iOS Simulator SDK not found (optional; install Xcode for iOS)", .{});
    }

    const android_home = androidSdk(a, io, env);
    if (android_home) |ah| {
        out.step("✓ Android SDK ({s})", .{ah});
    } else {
        out.step("- Android SDK not found (optional; set ANDROID_HOME)", .{});
    }

    if (builtin.os.tag == .windows) {
        if (hasWebView2(a, io, env)) {
            out.step("✓ WebView2 SDK (optional, NuGet cache)", .{});
        } else {
            out.step("- WebView2 SDK not found (optional, needed only for `--template page`)", .{});
        }
    }

    const node_ok = hasCmd(a, io, &.{ "node", "--version" });
    if (node_ok) out.step("✓ node (optional, for WebGPU host tests)", .{}) else out.step("- node not found (optional, for WebGPU local host)", .{});

    out.step("✓ host: {s} {s}", .{ os, @tagName(builtin.cpu.arch) });

    if (!zig_ok) return out.fail("zig 0.17 is needed", .{}, "install it from ziglang.org/download, or with zigup 0.17.0");
    if (!gtk_ok) return out.fail("GTK 4 or GTK 3 is needed on Linux", .{}, "sudo apt install libgtk-4-1 libgtk-3-0 (or your distribution's GTK)");
    if (!mac_sdk) return out.fail("macOS SDK is needed", .{}, "run: xcode-select --install");

    if (target_spec) |ts| {
        if (ts.is_ios) {
            if (builtin.os.tag != .macos) return out.fail("iOS builds require macOS and Xcode", .{}, "run on macOS with Xcode installed");
            if (!ios_sdk) return out.fail("iOS SDK not found", .{}, "install Xcode and select it with `sudo xcode-select -s /Applications/Xcode.app`");
        } else if (ts.is_android) {
            const ah = android_home orelse return out.fail("Android SDK not found", .{}, "install Android Studio SDK + NDK and set ANDROID_HOME");
            if (!hasCmd(a, io, &.{ "java", "-version" })) return out.fail("Java is needed to sign Android APKs", .{}, "install a JDK (`java -version` must succeed)");
            const ndk_ok = env.get("ANDROID_NDK_HOME") != null or env.get("ANDROID_NDK_ROOT") != null or hasSubdir(a, io, ah, "ndk");
            if (!ndk_ok) return out.fail("Android NDK not found in {s}/ndk", .{ah}, "install the NDK in Android Studio SDK Manager or set ANDROID_NDK_HOME");
        }
    }

    out.done(.{
        .zig = zig_version,
        .os = os,
        .arch = @tagName(builtin.cpu.arch),
        .ios_sdk = ios_sdk,
        .android_sdk = android_home != null,
        .node = node_ok,
    }, &.{});
}

fn hasSdk(a: std.mem.Allocator, io: std.Io, sdk: []const u8) bool {
    const r = std.process.run(a, io, .{ .argv = &.{ "xcrun", "--sdk", sdk, "--show-sdk-path" } }) catch return false;
    return r.term.success() and std.mem.trim(u8, r.stdout, " \t\r\n").len > 0;
}

fn hasCmd(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const r = std.process.run(a, io, .{ .argv = argv }) catch return false;
    return r.term.success();
}

fn androidSdk(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    for ([_][]const u8{ "ANDROID_HOME", "ANDROID_SDK_ROOT" }) |k| {
        if (env.get(k)) |v| if (v.len > 0) return v;
    }
    const base = if (builtin.os.tag == .windows)
        (env.get("LOCALAPPDATA") orelse env.get("USERPROFILE") orelse env.get("HOME") orelse return null)
    else
        (env.get("HOME") orelse return null);
    const def = switch (builtin.os.tag) {
        .macos => std.fs.path.join(a, &.{ base, "Library", "Android", "sdk" }) catch return null,
        .windows => std.fs.path.join(a, &.{ base, "Android", "Sdk" }) catch return null,
        else => std.fs.path.join(a, &.{ base, "Android", "Sdk" }) catch return null,
    };
    if (std.Io.Dir.cwd().access(io, def, .{})) |_| return def else |_| return null;
}

fn hasWebView2(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return false;
    return hasSubdir(a, io, home, ".nuget\\packages\\microsoft.web.webview2");
}

fn hasSubdir(a: std.mem.Allocator, io: std.Io, parent: []const u8, sub: []const u8) bool {
    const path = std.fs.path.join(a, &.{ parent, sub }) catch return false;
    var d = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer d.close(io);
    var it = d.iterate();
    return (it.next(io) catch null) != null;
}

/// Whether bubblewrap, which WebKitGTK 6.0 always runs in, refuses to run here.
fn bwrapRefuses(a: std.mem.Allocator, io: std.Io) bool {
    const r = std.process.run(a, io, .{ .argv = &.{ "bwrap", "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev", "--unshare-all", "true" } }) catch return false;
    return switch (r.term) {
        .exited => |code| code != 0,
        else => true,
    };
}

/// Whether a library is where the dynamic loader finds it.
fn found(lib: []const u8) bool {
    const arch = @tagName(builtin.cpu.arch);
    const dirs = [_][]const u8{ "/usr/lib/" ++ arch ++ "-linux-gnu", "/lib/" ++ arch ++ "-linux-gnu", "/usr/lib64", "/usr/lib", "/lib64", "/lib", "/usr/local/lib" };
    var buf: [256]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    for (dirs) |d| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, lib }) catch continue;
        if (std.Io.Dir.cwd().access(io, p, .{})) |_| return true else |_| {}
    }
    return false;
}
