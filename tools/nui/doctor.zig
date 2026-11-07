//! `nui doctor`: what a nanoui app needs, checked. Zig 0.17, and on Linux
//! GTK 3 (loaded when an app starts), and WebKitGTK if the app shows pages;
//! macOS and Windows need nothing more.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("main.zig");

pub fn run(a: std.mem.Allocator, io: std.Io, out: *cli.Out) !void {
    const r = std.process.run(a, io, .{ .argv = &.{ "zig", "version" } }) catch null;
    const zig_version = if (r) |x| std.mem.trim(u8, x.stdout, " \r\n") else "";
    const zig_ok = std.mem.startsWith(u8, zig_version, "0.17.");
    const gtk_ok = if (builtin.os.tag == .linux) found("libgtk-3.so.0") else true;
    const os = @tagName(builtin.os.tag);
    if (zig_ok) out.step("✓ zig {s}", .{zig_version}) else out.step("✗ zig {s} (nanoui needs 0.17)", .{if (zig_version.len > 0) zig_version else "not found"});
    if (builtin.os.tag == .linux) {
        if (gtk_ok) out.step("✓ GTK 3", .{}) else out.step("✗ GTK 3 not found (libgtk-3-0)", .{});
        // Only apps with pages need it: reported, not required.
        const four = found("libwebkit2gtk-4.1.so.0") or found("libwebkit2gtk-4.0.so.37");
        const six = found("libwebkitgtk-6.0.so.4");
        if (six and !four and bwrapRefuses(a, io))
            out.step("- WebKitGTK 6.0 can't start its sandbox here: web pages need libwebkit2gtk-4.1-0", .{})
        else if (four or six)
            out.step("✓ WebKitGTK", .{})
        else
            out.step("- WebKitGTK not found: web pages need it (libwebkit2gtk-4.1-0)", .{});
    }
    out.step("✓ {s} {s}", .{ os, @tagName(builtin.cpu.arch) });
    if (!zig_ok) return out.fail("zig 0.17 is needed", .{}, "install it from ziglang.org/download, or with zigup 0.17.0");
    if (!gtk_ok) return out.fail("GTK 3 is needed on Linux", .{}, "sudo apt install libgtk-3-0 (or your distribution's GTK 3)");
    out.done(.{ .zig = zig_version, .os = os, .arch = @tagName(builtin.cpu.arch) }, &.{});
}

/// Whether bubblewrap, which WebKitGTK 6.0 always runs in, refuses to run here.
/// The same check as `webkit.refuses` in an app.
fn bwrapRefuses(a: std.mem.Allocator, io: std.Io) bool {
    const r = std.process.run(a, io, .{ .argv = &.{ "bwrap", "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev", "--unshare-all", "true" } }) catch return false;
    return switch (r.term) {
        .exited => |code| code != 0,
        else => true,
    };
}

/// Whether a library is where the dynamic loader finds it (nui itself is
/// static, so it looks rather than loads).
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
