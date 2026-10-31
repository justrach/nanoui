//! The desktop around the app on Windows: the clipboard (as UTF-16 text),
//! opening URLs and files with the shell, the known folders, the theme.
const std = @import("std");
const w = @import("win32.zig");

const CF_UNICODETEXT = 13;

pub const clipboard = struct {
    pub fn readText(gpa: std.mem.Allocator) !?[]u8 {
        if (w.OpenClipboard(null) == 0) return null;
        defer _ = w.CloseClipboard();
        const mem = w.GetClipboardData(CF_UNICODETEXT) orelse return null;
        const p: [*:0]const u16 = @ptrCast(@alignCast(w.GlobalLock(mem) orelse return null));
        defer _ = w.GlobalUnlock(mem);
        return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(p));
    }

    pub fn writeText(text: []const u8) void {
        const n = std.unicode.calcUtf16LeLen(text) catch return;
        // GMEM_MOVEABLE: the clipboard owns the block once `SetClipboardData`
        // has taken it. Until then — a lock that fails, a clipboard that will
        // not open, a set that fails — it is ours to free.
        const mem = w.GlobalAlloc(0x0002, (n + 1) * 2) orelse return;
        var owned = true;
        defer if (owned) {
            _ = w.GlobalFree(mem);
        };
        const p: [*]u16 = @ptrCast(@alignCast(w.GlobalLock(mem) orelse return));
        _ = std.unicode.utf8ToUtf16Le(p[0..n], text) catch {};
        p[n] = 0;
        _ = w.GlobalUnlock(mem);
        if (w.OpenClipboard(null) == 0) return;
        defer _ = w.CloseClipboard();
        _ = w.EmptyClipboard();
        if (w.SetClipboardData(CF_UNICODETEXT, mem) == null) return;
        owned = false;
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

fn shellOpen(target: []const u8) bool {
    var buf: [4096]u16 = undefined;
    const r = w.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), w.wide(&buf, target), null, null, 1);
    return @intFromPtr(r) > 32;
}

pub const shell = struct {
    pub fn openUrl(url: []const u8) bool {
        return shellOpen(url);
    }

    pub fn openPath(file: []const u8) bool {
        return shellOpen(file);
    }

    pub fn showInFolder(file: []const u8) void {
        _ = shellOpen(std.fs.path.dirname(file) orelse file);
    }

    pub fn trash(file: []const u8) bool {
        _ = file;
        return false;
    }

    pub fn beep() void {}
};

pub const Directory = enum { data, cache, home, documents, downloads, desktop, temp };

fn env(gpa: std.mem.Allocator, comptime name: []const u8) ?[]u8 {
    var buf: [1024]u16 = undefined;
    const n = w.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), &buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..n]) catch null;
}

pub fn path(gpa: std.mem.Allocator, dir: Directory, app_name: []const u8) ![]u8 {
    const home = env(gpa, "USERPROFILE") orelse try gpa.dupe(u8, "C:\\");
    defer gpa.free(home);
    const io = std.Io.Threaded.global_single_threaded.io();
    switch (dir) {
        .home => return gpa.dupe(u8, home),
        .temp => return env(gpa, "TEMP") orelse gpa.dupe(u8, "C:\\Windows\\Temp"),
        .documents => return std.fs.path.join(gpa, &.{ home, "Documents" }),
        .downloads => return std.fs.path.join(gpa, &.{ home, "Downloads" }),
        .desktop => return std.fs.path.join(gpa, &.{ home, "Desktop" }),
        .data, .cache => {
            const base = (if (dir == .data) env(gpa, "APPDATA") else env(gpa, "LOCALAPPDATA")) orelse try gpa.dupe(u8, home);
            defer gpa.free(base);
            const full = try std.fs.path.join(gpa, &.{ base, app_name });
            std.Io.Dir.cwd().createDirPath(io, full) catch {};
            return full;
        },
    }
}

/// Whether the system shows dark mode: Windows' "Choose your default app
/// mode" under Personalization > Colors, which apps read from HKCU.
pub fn isDark() bool {
    const sub = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    const value = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var app_mode: u32 = 1; // Light, the Windows default.
    var bytes: u32 = @sizeOf(u32);
    const status = w.RegGetValueW(w.HKEY_CURRENT_USER, sub, value, w.RRF_RT_REG_DWORD, null, &app_mode, &bytes);
    if (status != 0 or bytes != @sizeOf(u32)) return false;
    return app_mode == 0;
}

pub fn accentColor() [3]f32 {
    return .{ 0, 0.47, 0.84 };
}

test "paths come out for every directory, and the theme reads" {
    const testing = std.testing;
    const gpa = std.testing.allocator;
    // Every directory a desktop app asks for: each is an environment
    // variable or a folder under the home one, and an empty or relative
    // answer would send app data to the wrong place.
    inline for ([_]Directory{ .data, .cache, .home, .documents, .downloads, .desktop, .temp }) |dir| {
        const p = try path(gpa, dir, "nanoui-tests");
        defer gpa.free(p);
        try testing.expect(p.len > 0);
        try testing.expect(std.fs.path.isAbsolute(p));
    }
    // The theme is a bool, whatever the registry has: never a crash.
    _ = isDark();
}
