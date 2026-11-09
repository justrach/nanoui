//! Cursors made from an app's pixels on Windows (`ui.makeCursor`): a
//! 32-bit top-down DIB section with the pixels' alpha, and an all-zero
//! mask beside it, given to `CreateIconIndirect` as a cursor with its hot
//! spot, as macOS makes an NSCursor from them. The surface shows it with
//! `SetCursor` (`WM_SETCURSOR`), `DestroyIcon` frees it. The pixels are one
//! point each, as on macOS: at 150% or 200% the cursor is made that much
//! larger (`GetDpiForSystem`), its hot spot with it.
const std = @import("std");

const BITMAPV5HEADER = extern struct {
    size: u32 = @sizeOf(BITMAPV5HEADER),
    width: i32,
    height: i32,
    planes: u16 = 1,
    bit_count: u16 = 32,
    compression: u32 = 3, // BI_BITFIELDS
    size_image: u32 = 0,
    x_ppm: i32 = 0,
    y_ppm: i32 = 0,
    clr_used: u32 = 0,
    clr_important: u32 = 0,
    red_mask: u32 = 0x00ff0000,
    green_mask: u32 = 0x0000ff00,
    blue_mask: u32 = 0x000000ff,
    alpha_mask: u32 = 0xff000000,
    cs_type: u32 = 0x73524742, // LCS_sRGB
    endpoints: [36]u8 = @splat(0),
    gamma_red: u32 = 0,
    gamma_green: u32 = 0,
    gamma_blue: u32 = 0,
    intent: u32 = 0,
    profile_data: u32 = 0,
    profile_size: u32 = 0,
    reserved: u32 = 0,
};
comptime {
    std.debug.assert(@sizeOf(BITMAPV5HEADER) == 124);
}

pub const ICONINFO = extern struct {
    icon: i32,
    hot_x: u32,
    hot_y: u32,
    mask: ?*anyopaque,
    color: ?*anyopaque,
};

extern "gdi32" fn CreateDIBSection(dc: ?*anyopaque, info: *const BITMAPV5HEADER, usage: u32, bits: *?*anyopaque, section: ?*anyopaque, offset: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CreateBitmap(w: i32, h: i32, planes: u32, bpp: u32, bits: ?*const anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(.winapi) i32;
extern "user32" fn CreateIconIndirect(info: *const ICONINFO) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyIcon(icon: *anyopaque) callconv(.winapi) i32;
extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;

/// The system's scale (1 at 96 DPI): the size a point's pixel is drawn at.
pub fn systemScale() f32 {
    const dpi = GetDpiForSystem();
    return if (dpi == 0) 1 else @as(f32, @floatFromInt(dpi)) / 96;
}

/// `rgba` (straight alpha, `w` × `h`) at `out_w` × `out_h`, bilinear on
/// premultiplied values so a transparent edge does not darken, straight
/// alpha out again.
pub fn resample(rgba: []const u8, w: u32, h: u32, out: []u8, out_w: u32, out_h: u32) void {
    const sx = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(out_w));
    const sy = @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(out_h));
    for (0..out_h) |y| for (0..out_w) |x| {
        const fx = std.math.clamp((@as(f32, @floatFromInt(x)) + 0.5) * sx - 0.5, 0, @as(f32, @floatFromInt(w - 1)));
        const fy = std.math.clamp((@as(f32, @floatFromInt(y)) + 0.5) * sy - 0.5, 0, @as(f32, @floatFromInt(h - 1)));
        const x0: usize = @intFromFloat(@floor(fx));
        const y0: usize = @intFromFloat(@floor(fy));
        const x1 = @min(x0 + 1, w - 1);
        const y1 = @min(y0 + 1, h - 1);
        const tx = fx - @floor(fx);
        const ty = fy - @floor(fy);
        var acc: [4]f32 = .{ 0, 0, 0, 0 };
        const taps = [4]struct { usize, usize, f32 }{ .{ x0, y0, (1 - tx) * (1 - ty) }, .{ x1, y0, tx * (1 - ty) }, .{ x0, y1, (1 - tx) * ty }, .{ x1, y1, tx * ty } };
        for (taps) |t| {
            const s = rgba[(t[1] * w + t[0]) * 4 ..][0..4];
            const a = @as(f32, @floatFromInt(s[3])) / 255;
            for (0..3) |ch| acc[ch] += @as(f32, @floatFromInt(s[ch])) * a * t[2];
            acc[3] += a * t[2];
        }
        const o = out[(y * out_w + x) * 4 ..][0..4];
        for (0..3) |ch| o[ch] = if (acc[3] > 0) @intFromFloat(@round(std.math.clamp(acc[ch] / acc[3], 0, 255))) else 0;
        o[3] = @intFromFloat(@round(std.math.clamp(acc[3] * 255, 0, 255)));
    };
}
pub extern "user32" fn GetIconInfo(icon: *anyopaque, info: *ICONINFO) callconv(.winapi) i32;

/// A cursor from `rgba` (straight alpha, `w` × `h`, top row first) with its
/// hot spot at (`hot_x`, `hot_y`) pixels from its top left. Null if the
/// system will not make one.
pub fn make(rgba: []const u8, w: u32, h: u32, hot_x: f32, hot_y: f32) ?*anyopaque {
    return makeAt(rgba, w, h, hot_x, hot_y, systemScale());
}

/// `make` at `scale` pixels a point: the pixels resampled to that size.
pub fn makeAt(rgba_in: []const u8, w_in: u32, h_in: u32, hot_x_in: f32, hot_y_in: f32, scale: f32) ?*anyopaque {
    if (w_in == 0 or h_in == 0 or rgba_in.len < @as(usize, w_in) * h_in * 4) return null;
    const gpa = std.heap.page_allocator;
    var rgba = rgba_in;
    var w = w_in;
    var h = h_in;
    var hot_x = hot_x_in;
    var hot_y = hot_y_in;
    var big: ?[]u8 = null;
    defer if (big) |b| gpa.free(b);
    if (scale > 1.01) {
        w = @intFromFloat(@round(@as(f32, @floatFromInt(w_in)) * scale));
        h = @intFromFloat(@round(@as(f32, @floatFromInt(h_in)) * scale));
        const b = gpa.alloc(u8, @as(usize, w) * h * 4) catch return null;
        big = b;
        resample(rgba_in, w_in, h_in, b, w, h);
        rgba = b;
        hot_x *= scale;
        hot_y *= scale;
    }
    const header: BITMAPV5HEADER = .{ .width = @intCast(w), .height = -@as(i32, @intCast(h)) };
    var bits: ?*anyopaque = null;
    const color = CreateDIBSection(null, &header, 0, &bits, null, 0) orelse return null;
    defer _ = DeleteObject(color);
    const px: [*]u8 = @ptrCast(bits orelse return null);
    // RGBA in, BGRA (the DIB's byte order) out; alpha straight, as an
    // alpha cursor's colour bitmap takes it.
    for (0..@as(usize, w) * h) |i| {
        const s = rgba[i * 4 ..][0..4];
        px[i * 4 ..][0..4].* = .{ s[2], s[1], s[0], s[3] };
    }
    // The mask is ignored where the colour bitmap has alpha, but must be
    // there: all zero, one bit a pixel, its rows a whole number of 16-bit
    // words. `CreateBitmap` with no bits leaves them undefined, which some
    // drivers XOR over the screen: they are given, zeroed.
    const mask_row: usize = ((@as(usize, w) + 15) / 16) * 2;
    const zeros = gpa.alloc(u8, mask_row * h) catch return null;
    defer gpa.free(zeros);
    @memset(zeros, 0);
    const mask = CreateBitmap(@intCast(w), @intCast(h), 1, 1, zeros.ptr) orelse return null;
    defer _ = DeleteObject(mask);
    const info: ICONINFO = .{
        .icon = 0,
        .hot_x = @intFromFloat(std.math.clamp(@round(hot_x), 0, @as(f32, @floatFromInt(w - 1)))),
        .hot_y = @intFromFloat(std.math.clamp(@round(hot_y), 0, @as(f32, @floatFromInt(h - 1)))),
        .mask = mask,
        .color = color,
    };
    return CreateIconIndirect(&info);
}

pub fn free(cursor: *anyopaque) void {
    _ = DestroyIcon(cursor);
}

/// The cursor's hot spot as the system has it (for the tests); its
/// bitmaps are freed here.
pub fn hotSpot(cursor: *anyopaque) ?[2]u32 {
    var info: ICONINFO = undefined;
    if (GetIconInfo(cursor, &info) == 0) return null;
    if (info.mask) |m| _ = DeleteObject(m);
    if (info.color) |c| _ = DeleteObject(c);
    if (info.icon != 0) return null;
    return .{ info.hot_x, info.hot_y };
}

test "a cursor at 200% is twice the pixels, its hot spot with them" {
    var px: [8 * 8 * 4]u8 = undefined;
    for (0..64) |k| px[k * 4 ..][0..4].* = .{ 255, 0, 0, if (k % 2 == 0) 255 else 0 };
    const cur = makeAt(&px, 8, 8, 3, 5, 2) orelse return error.NoCursor;
    defer free(cur);
    try std.testing.expectEqual([2]u32{ 6, 10 }, hotSpot(cur).?);
}

test "resample keeps an opaque colour and blends alpha without darkening" {
    const src = [_]u8{ 10, 20, 30, 255, 200, 200, 200, 0 };
    var out: [4 * 4]u8 = undefined;
    resample(&src, 2, 1, &out, 4, 1);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, out[0..4]);
    // Half covered: the colour is the opaque one's, the alpha in between.
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, out[4..7]);
    try std.testing.expect(out[7] > 100 and out[7] < 255);
}
