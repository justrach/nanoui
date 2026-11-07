//! Where WebView2 keeps its profile, and the folders it needs there.
//!
//! The runtime writes cookies and caches into this folder, and only one
//! browser process may hold one at a time: a second `CreateCoreWebView2-
//! EnvironmentWithOptions` against the same folder, before the first has
//! let go, comes back `ERROR_BUSY` (0x800700AA). So the folder is made
//! before the environment is asked for, and a run can name its own with
//! `NANOUI_WEBVIEW_PROFILE`.
const std = @import("std");
const w = @import("windows/win32.zig");
const Window = @import("windows/window.zig").Window;

/// WebView2's profile folder: `%LOCALAPPDATA%\<app>\WebView2`, or
/// `NANOUI_WEBVIEW_PROFILE` when the run named one.
///
/// The folder is made before WebView2 is asked for, and the making is not
/// allowed to fail the page: a run from a folder Windows denies writes to
/// (`zig-out\bin` here: an inherited `Everyone: deny delete` ACE) still gets
/// a working WebView2, which uses its own default profile when the one we
/// name cannot be made. A page that says "no runtime" instead would be a
/// lie: the runtime is there, the folder was not.
pub fn userDataDir(window: *Window, gpa: std.mem.Allocator, name: []const u8) ![:0]u16 {
    const path = if (window.app.webview_profile) |dir|
        try gpa.dupe(u8, dir)
    else blk: {
        const base = window.app.local_appdata orelse ".";
        break :blk try std.fmt.allocPrint(gpa, "{s}\\{s}\\WebView2", .{ base, name });
    };
    defer gpa.free(path);
    const n = try std.unicode.calcUtf16LeLen(path);
    const buf = try gpa.alloc(u16, n + 1);
    _ = try std.unicode.utf8ToUtf16Le(buf, path);
    buf[n] = 0;
    makeDirTreeW(buf[0..n :0]) catch |err| {
        if (window.app.debug)
            std.debug.print("nanoui: no WebView2 profile at {s} ({s}): the runtime's own is used\n", .{ path, @errorName(err) });
        buf[0] = 0; // an empty folder: WebView2 picks its default
    };
    if (window.app.debug) std.debug.print("nanoui: WebView2 profile '{s}'\n", .{path});
    return buf[0..n :0];
}

/// `C:\a\b\c` made one prefix at a time, by the system's own call. `std.Io`'s
/// absolute-path helpers resolve through `cwd` on Windows and come back
/// `AccessDenied` for a drive-qualified path; `CreateDirectoryW` takes the
/// path as it is, and each level's parent exists by then.
pub fn makeDirTreeW(path: [:0]const u16) !void {
    if (path.len == 0) return;
    // One fixed buffer for every prefix: each is `path[0..i]`, and the zero
    // after it is what `CreateDirectoryW` reads up to. A second copy of the
    // whole path is made in it for the last call, so no pointer with a
    // different sentinel cast is ever handed to the system.
    var buf: [1024]u16 = undefined;
    if (path.len + 1 > buf.len) return error.NameTooLong;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != '\\' and path[i] != '/') continue;
        // A drive's own separator (`C:\`) has nothing to make.
        if (i == 2 and path[1] == ':') continue;
        if (i == 0) continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        if (w.CreateDirectoryW(@ptrCast(buf[0..i :0].ptr), null) == 0) {
            const code = w.GetLastError();
            if (code != w.ERROR_ALREADY_EXISTS) return error.MakeDir;
        }
    }
    @memcpy(buf[0..path.len], path[0..path.len]);
    buf[path.len] = 0;
    if (w.CreateDirectoryW(@ptrCast(buf[0..path.len :0].ptr), null) != 0) return;
    const code = w.GetLastError();
    if (code == w.ERROR_ALREADY_EXISTS) return;
    return error.MakeDir;
}
