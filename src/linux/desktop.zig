//! The desktop around the app on Linux: the clipboard (GTK's), opening
//! URLs and files with `xdg-open`, the XDG directories, and the theme.
const std = @import("std");
const appearance = @import("appearance.zig");
const gtk = @import("gtk.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

fn env(name: [*:0]const u8) ?[]const u8 {
    return if (getenv(name)) |v| std.mem.span(v) else null;
}

/// The CLIPBOARD selection: GTK 3's, or GTK 4's display's.
fn board() ?*anyopaque {
    if (!gtk.ready()) return null;
    if (gtk.v4) return gtk.v4api.gdk_display_get_clipboard(gtk.api.gdk_display_get_default() orelse return null);
    return gtk.v3.gtk_clipboard_get(gtk.v3.gdk_atom_intern("CLIPBOARD", 0));
}

/// GTK 4 reads the clipboard only asynchronously: the answer, waited for
/// on GLib's loop (as GTK 3's wait_for_text waits), a second at most.
const Read = struct {
    done: bool = false,
    text: ?[*:0]u8 = null,
    fn finish(source: *anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
        const r: *Read = @ptrCast(@alignCast(data));
        r.text = gtk.v4api.gdk_clipboard_read_text_finish(source, result, null);
        r.done = true;
    }
};

fn readText4(b: *anyopaque) ?[*:0]u8 {
    var r: Read = .{};
    gtk.v4api.gdk_clipboard_read_text_async(b, null, Read.finish, &r);
    var spins: usize = 0;
    while (!r.done and spins < 1000) : (spins += 1) {
        if (gtk.api.g_main_context_iteration(null, 0) == 0) std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(1), .awake) catch {};
    }
    return r.text;
}

pub const clipboard = struct {
    pub fn readText(gpa: std.mem.Allocator) !?[]u8 {
        const b = board() orelse return null;
        const s = (if (gtk.v4) readText4(b) else gtk.v3.gtk_clipboard_wait_for_text(b)) orelse return null;
        defer gtk.api.g_free(s);
        return try gpa.dupe(u8, std.mem.span(s));
    }

    pub fn writeText(text: []const u8) void {
        const b = board() orelse return;
        if (gtk.v4) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(std.heap.c_allocator);
            buf.appendSlice(std.heap.c_allocator, text) catch return;
            buf.append(std.heap.c_allocator, 0) catch return;
            gtk.v4api.gdk_clipboard_set_text(b, @ptrCast(buf.items.ptr));
        } else gtk.v3.gtk_clipboard_set_text(b, text.ptr, @intCast(text.len));
    }

    pub fn changeCount() isize {
        return 0;
    }

    /// Images on the clipboard: not read here yet.
    pub fn readImage(_: std.mem.Allocator) !?[]u8 {
        return null;
    }

    /// Files on the clipboard: not read here yet.
    pub fn readFiles(_: std.mem.Allocator) !?[][]u8 {
        return null;
    }
};

/// Runs `xdg-open` on `target`, not waiting for it.
fn xdgOpen(target: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (target.len >= buf.len) return false;
    @memcpy(buf[0..target.len], target);
    buf[target.len] = 0;
    const argv = [_:null]?[*:0]const u8{ "xdg-open", @ptrCast(&buf) };
    var pid: c_int = 0;
    return posix_spawnp(&pid, "xdg-open", null, null, &argv, environ) == 0;
}

pub const shell = struct {
    pub fn openUrl(url: []const u8) bool {
        return xdgOpen(url);
    }

    pub fn openPath(file: []const u8) bool {
        return xdgOpen(file);
    }

    pub fn showInFolder(file: []const u8) void {
        _ = xdgOpen(std.fs.path.dirname(file) orelse file);
    }

    pub fn trash(file: []const u8) bool {
        _ = file;
        return false;
    }

    pub fn beep() void {}
};

pub const Directory = enum { data, cache, home, documents, downloads, desktop, temp };

/// The path of a standard directory, by the XDG conventions; for `data`
/// and `cache`, the app's own, created if missing. Caller frees it.
pub fn path(gpa: std.mem.Allocator, dir: Directory, app_name: []const u8) ![]u8 {
    const home = env("HOME") orelse "/tmp";
    const io = std.Io.Threaded.global_single_threaded.io();
    const full = switch (dir) {
        .temp => return gpa.dupe(u8, env("TMPDIR") orelse "/tmp"),
        .home => return gpa.dupe(u8, home),
        .documents => return std.fs.path.join(gpa, &.{ home, "Documents" }),
        .downloads => return std.fs.path.join(gpa, &.{ home, "Downloads" }),
        .desktop => return std.fs.path.join(gpa, &.{ home, "Desktop" }),
        .data => if (env("XDG_DATA_HOME")) |d| try std.fs.path.join(gpa, &.{ d, app_name }) else try std.fs.path.join(gpa, &.{ home, ".local", "share", app_name }),
        .cache => if (env("XDG_CACHE_HOME")) |d| try std.fs.path.join(gpa, &.{ d, app_name }) else try std.fs.path.join(gpa, &.{ home, ".cache", app_name }),
    };
    std.Io.Dir.cwd().createDirPath(io, full) catch {};
    return full;
}

/// Whether the desktop asks for dark colors: `GTK_THEME`, where it is set (as
/// GTK itself reads it), else the portal's scheme, else GtkSettings — see
/// `appearance.zig`.
pub fn isDark() bool {
    return appearance.dark(env("GTK_THEME"));
}

pub fn accentColor() [3]f32 {
    return .{ 0.21, 0.52, 0.89 };
}
