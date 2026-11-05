//! Cursors made from an app's pixels on Windows (`ui.makeCursor`): a
//! 32-bit top-down DIB section with the pixels' alpha, and an all-zero
//! mask beside it, given to `CreateIconIndirect` as a cursor with its hot
//! spot, as macOS makes an NSCursor from them. The surface shows it with
//! `SetCursor` (`WM_SETCURSOR`), `DestroyIcon` frees it.
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
pub extern "user32" fn GetIconInfo(icon: *anyopaque, info: *ICONINFO) callconv(.winapi) i32;

/// A cursor from `rgba` (straight alpha, `w` × `h`, top row first) with its
/// hot spot at (`hot_x`, `hot_y`) pixels from its top left. Null if the
/// system will not make one.
pub fn make(rgba: []const u8, w: u32, h: u32, hot_x: f32, hot_y: f32) ?*anyopaque {
    if (w == 0 or h == 0 or rgba.len < @as(usize, w) * h * 4) return null;
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
    // there: all zero, one bit a pixel.
    const mask = CreateBitmap(@intCast(w), @intCast(h), 1, 1, null) orelse return null;
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
