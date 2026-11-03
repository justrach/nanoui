//! A transparent window on Windows (`Options.transparent`): each frame's
//! pixels, BGRA premultiplied as the CPU renderer draws them, handed to the
//! system whole with `UpdateLayeredWindow`. What the view doesn't draw isn't
//! there: no background, nothing square behind rounded corners, and clicks
//! on it fall through to the window below. Windows 10 and 11 alike, and in a
//! VM (where DWM's own corner rounding is off).
//!
//! Such a window is never painted in WM_PAINT: the system keeps the bitmap
//! it was last given, so a frame is presented as soon as it is built. A
//! flip-model swap chain can't be a layered window's, so the GPU stands down.
const std = @import("std");
const w = @import("win32.zig");

const SIZE = extern struct { cx: i32, cy: i32 };
const BLENDFUNCTION = extern struct { op: u8 = 0, flags: u8 = 0, alpha: u8 = 255, format: u8 = ac_src_alpha };
const BITMAPINFO = extern struct { header: w.BITMAPINFOHEADER, colors: [1]u32 = .{0} };
const ac_src_alpha = 1;
const ulw_alpha = 2;

extern "user32" fn GetDC(hwnd: ?w.HWND) callconv(.winapi) ?w.HDC;
extern "user32" fn ReleaseDC(hwnd: ?w.HWND, dc: w.HDC) callconv(.winapi) i32;
extern "user32" fn UpdateLayeredWindow(hwnd: w.HWND, dst: ?w.HDC, at: ?*const w.POINT, size: ?*const SIZE, src: ?w.HDC, from: ?*const w.POINT, key: u32, blend: ?*const BLENDFUNCTION, flags: u32) callconv(.winapi) w.BOOL;
extern "gdi32" fn CreateCompatibleDC(dc: ?w.HDC) callconv(.winapi) ?w.HDC;
extern "gdi32" fn DeleteDC(dc: w.HDC) callconv(.winapi) w.BOOL;
extern "gdi32" fn CreateDIBSection(dc: ?w.HDC, info: *const BITMAPINFO, usage: u32, bits: *?*anyopaque, section: ?*anyopaque, offset: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SelectObject(dc: w.HDC, obj: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(.winapi) w.BOOL;
extern "gdi32" fn GdiFlush() callconv(.winapi) w.BOOL;

/// The bitmap frames are copied into, kept while the size stays.
pub const Layered = struct {
    dc: ?w.HDC = null,
    bitmap: ?*anyopaque = null,
    old: ?*anyopaque = null,
    bits: ?[*]u8 = null,
    width: usize = 0,
    height: usize = 0,

    /// Shows `bytes` (`width` × `height`, BGRA premultiplied, rows from the
    /// top) as the window, `opacity` times as opaque. False if GDI failed.
    pub fn present(l: *Layered, h: w.HWND, bytes: []const u8, width: usize, height: usize, opacity: f64) bool {
        if (width == 0 or height == 0 or bytes.len < width * height * 4) return false;
        if (l.bits == null or width != l.width or height != l.height) {
            l.deinit();
            const dc = CreateCompatibleDC(null) orelse return false;
            const info: BITMAPINFO = .{ .header = .{ .biWidth = @intCast(width), .biHeight = -@as(i32, @intCast(height)) } };
            var bits: ?*anyopaque = null;
            const bitmap = CreateDIBSection(dc, &info, 0, &bits, null, 0) orelse {
                _ = DeleteDC(dc);
                return false;
            };
            l.* = .{ .dc = dc, .bitmap = bitmap, .old = SelectObject(dc, bitmap), .bits = @ptrCast(bits), .width = width, .height = height };
        }
        // GDI may still be reading the bitmap from the last frame.
        _ = GdiFlush();
        @memcpy(l.bits.?[0 .. width * height * 4], bytes[0 .. width * height * 4]);
        const size: SIZE = .{ .cx = @intCast(width), .cy = @intCast(height) };
        const from: w.POINT = .{};
        const blend: BLENDFUNCTION = .{ .alpha = @intFromFloat(@round(std.math.clamp(opacity, 0, 1) * 255)) };
        const screen = GetDC(null);
        defer if (screen) |s| {
            _ = ReleaseDC(null, s);
        };
        return UpdateLayeredWindow(h, screen, null, &size, l.dc, &from, 0, &blend, ulw_alpha) != 0;
    }

    pub fn deinit(l: *Layered) void {
        if (l.dc) |dc| {
            if (l.old) |o| _ = SelectObject(dc, o);
            _ = DeleteDC(dc);
        }
        if (l.bitmap) |b| _ = DeleteObject(b);
        l.* = .{};
    }
};
