//! Files dropped on a Windows window: one HDROP becomes one native UI drop,
//! with file URLs like the ones AppKit delivers and the point in view points.
const std = @import("std");
const w = @import("win32.zig");
const Surface = @import("surface.zig").Surface;
const types = @import("../ui/types.zig");

/// One WM_DROPFILES, however many files it carries. The URLs and their UTF-8
/// storage live for the frame, as they do on the Mac; the HDROP does not.
pub fn handle(surface: ?*Surface, hwnd: w.HWND, hdrop: w.HDROP) void {
    const s = surface orelse {
        w.DragFinish(hdrop);
        return;
    };
    // A sent WM_DROPFILES can reenter the window procedure while the view is
    // building (Shell/COM calls pump messages). The Context's drop targets are
    // cleared at that point, and Surface.frame only queues a later frame; if we
    // continued, acceptsDropAt would reject it or the deferred input.drop would
    // be cleared before that frame ran. Repost the same HDROP and keep ownership
    // with Windows until it can be handled between frames.
    if (s.in_frame) {
        if (w.PostMessageW(hwnd, w.WM_DROPFILES, @intFromPtr(hdrop), 0) != 0) return;
        w.DragFinish(hdrop);
        return;
    }
    defer w.DragFinish(hdrop);
    var p: w.POINT = .{};
    // A non-client drop is reported in screen coordinates; a client one is
    // already in the coordinates the surface uses before its DPI scale.
    if (w.DragQueryPoint(hdrop, &p) == 0) _ = w.ScreenToClient(hwnd, &p);
    const point: types.Point = .{ .x = @as(f32, @floatFromInt(p.x)) / s.scale, .y = @as(f32, @floatFromInt(p.y)) / s.scale };
    // As on the Mac, a box opts in with acceptDrop. Other windows and boxes
    // keep their old behavior: no input event and no frame for a drop.
    if (!s.ctx.acceptsDropAt(point)) return;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const urls = readUrls(a, hdrop) catch return;
    if (urls.len == 0) return;
    s.ctx.input.drag_over = null;
    s.ctx.input.drop = .{ .point = point, .urls = urls };
    defer s.ctx.input.drop = null;
    s.frame();
}

fn readUrls(a: std.mem.Allocator, hdrop: w.HDROP) ![]const []const u8 {
    const count = w.DragQueryFileW(hdrop, 0xFFFF_FFFF, null, 0);
    const urls = try a.alloc([]const u8, count);
    var n: usize = 0;
    for (0..count) |i| {
        const index: u32 = @intCast(i);
        // With no buffer this is the length without the null terminator.
        const len = w.DragQueryFileW(hdrop, index, null, 0);
        if (len == 0) continue;
        const units = try a.alloc(u16, @as(usize, len) + 1);
        const got = w.DragQueryFileW(hdrop, index, units.ptr, @intCast(units.len));
        if (got == 0 or got > len) continue;
        urls[n] = fileUrlUtf16(a, units[0..got]) catch continue;
        n += 1;
    }
    return urls[0..n];
}

fn fileUrlUtf16(a: std.mem.Allocator, units: []const u16) ![]u8 {
    const path = try std.unicode.utf16LeToUtf8Alloc(a, units);
    defer a.free(path);
    return fileUrl(a, path);
}

/// A Windows path as the file URL `ui.Drop.urls` promises. Extended-length
/// prefixes are syntax for Win32, not part of the URL; a UNC's server becomes
/// the URL's authority. Every other path byte is UTF-8 and URL-escaped.
fn fileUrl(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var rest = path;
    var prefix: []const u8 = "file:///";
    if (std.mem.startsWith(u8, rest, "\\\\?\\UNC\\")) {
        rest = rest[8..];
        prefix = "file://";
    } else {
        if (std.mem.startsWith(u8, rest, "\\\\?\\")) rest = rest[4..];
        if (std.mem.startsWith(u8, rest, "\\\\")) {
            rest = rest[2..];
            prefix = "file://";
        }
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.ensureTotalCapacity(a, prefix.len + rest.len * 3);
    out.appendSliceAssumeCapacity(prefix);
    for (rest) |ch| {
        if (ch == '\\') {
            out.appendAssumeCapacity('/');
        } else if (isPathChar(ch)) {
            out.appendAssumeCapacity(ch);
        } else {
            const hex = "0123456789ABCDEF";
            out.appendAssumeCapacity('%');
            out.appendAssumeCapacity(hex[ch >> 4]);
            out.appendAssumeCapacity(hex[ch & 15]);
        }
    }
    return out.toOwnedSlice(a);
}

/// RFC 3986's pchar; its colon also keeps a Windows drive letter intact.
fn isPathChar(ch: u8) bool {
    return switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '/', ':', '@' => true,
        else => false,
    };
}

fn expectFileUrl(expected: []const u8, path: []const u8) !void {
    const a = std.testing.allocator;
    const units = try std.unicode.utf8ToUtf16LeAlloc(a, path);
    defer a.free(units);
    const url = try fileUrlUtf16(a, units);
    defer a.free(url);
    try std.testing.expectEqualStrings(expected, url);
}

test "file URL converts UTF-16 Chinese paths and escapes URL bytes" {
    try expectFileUrl("file:///C:/Users/%E4%B8%AD%E6%96%87/%E6%8A%A5%E5%91%8A%20%231%3F100%25.txt", "C:\\Users\\中文\\报告 #1?100%.txt");
}

test "file URL keeps a long path without its extended-length prefix" {
    const a = std.testing.allocator;
    const tail: [280]u8 = @splat('a');
    var path_buf: [320]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "\\\\?\\C:\\{s}\\file.txt", .{tail});
    const expected = try std.fmt.allocPrint(a, "file:///C:/{s}/file.txt", .{tail});
    defer a.free(expected);
    try expectFileUrl(expected, path);
}

test "file URL converts UNC and extended UNC paths" {
    try expectFileUrl("file://server/share/dir/%E4%B8%AD%E6%96%87.txt", "\\\\server\\share\\dir\\中文.txt");
    try expectFileUrl("file://server/share/long.txt", "\\\\?\\UNC\\server\\share\\long.txt");
}
