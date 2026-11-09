//! What an app brings to the GPU and the pointer: 3D LUTs for a texture's
//! colour stage (`lut`), the Metal device to make its own textures on
//! (`metalDevice`), and cursors drawn from its own pixels (`makeCursor`).
const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

const apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

/// A 3D LUT for `Texture.lut` or `Texture.source_lut`: `size`³ RGBA half
/// floats (2 to 65 a side), red fastest as a .cube lists them. The GPU's
/// copy is made the first time `key` is seen and kept by it: a changed
/// LUT takes a new key. `rgba16f_data` is the app's, kept while it is
/// drawn. Set `domain_min`/`domain_max` on the result for a .cube's
/// DOMAIN_MIN/MAX.
pub fn lut(c: *Context, key: []const u8, size: u16, rgba16f_data: []const f16) gpu.Lut {
    _ = c;
    var h = std.hash.Wyhash.init(0x6c75_7433_64);
    h.update(key);
    h.update(std.mem.asBytes(&size));
    return .{ .key = h.final(), .size = size, .data = rgba16f_data };
}

/// The Metal device nanoui draws with; null where there's no Metal.
pub fn metalDevice() ?*anyopaque {
    if (comptime !apple) return null;
    return @import("metal_app.zig").metalDevice();
}

/// A cursor made from pixels (an NSCursor on macOS): `rgba` straight
/// alpha, `w` × `h`, shown at one point a pixel with its hot spot at
/// (`hot_x`, `hot_y`) from its top left. Show it with `setCursor`; free it
/// with `freeCursor` once nothing shows it. Null where custom cursors
/// aren't drawn (the arrow stays).
pub fn makeCursor(rgba: []const u8, w: u32, h: u32, hot_x: f32, hot_y: f32) ?*anyopaque {
    if (comptime builtin.os.tag != .macos) return null;
    if (w == 0 or h == 0 or rgba.len < @as(usize, w) * h * 4) return null;
    const objc = @import("../objc.zig");
    const pool = objc.Pool.push();
    defer pool.pop();
    const wi: objc.NSInteger = @intCast(w);
    const hi: objc.NSInteger = @intCast(h);
    // Non-premultiplied alpha (bitmap format 2), as given.
    const rep = objc.msg(?objc.Object, objc.alloc("NSBitmapImageRep"), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null),                 wi,                      hi,                          @as(objc.NSInteger, 8),  @as(objc.NSInteger, 4), objc.YES, objc.NO,
        objc.nsString("NSDeviceRGBColorSpace"), @as(objc.NSUInteger, 2), @as(objc.NSInteger, wi * 4), @as(objc.NSInteger, 32),
    }) orelse return null;
    defer objc.release(rep);
    const px: [*]u8 = objc.msg(?[*]u8, rep, "bitmapData", .{}) orelse return null;
    const stride: usize = @intCast(objc.msg(objc.NSInteger, rep, "bytesPerRow", .{}));
    for (0..h) |y| @memcpy(px[y * stride ..][0 .. @as(usize, w) * 4], rgba[y * w * 4 ..][0 .. @as(usize, w) * 4]);
    const img = objc.msg(objc.Object, objc.alloc("NSImage"), "initWithSize:", .{objc.CGSize{ .width = @floatFromInt(w), .height = @floatFromInt(h) }});
    defer objc.release(img);
    objc.msg(void, img, "addRepresentation:", .{rep});
    const cur = objc.msg(?objc.Object, objc.alloc("NSCursor"), "initWithImage:hotSpot:", .{ img, objc.CGPoint{ .x = hot_x, .y = hot_y } }) orelse return null;
    return @ptrCast(cur);
}

/// Shows `cursor` (`makeCursor`) over the view this frame, as
/// `c.cursor = .custom` does.
pub fn setCursor(c: *Context, cursor: ?*anyopaque) void {
    c.cursor = if (cursor != null) .custom else null;
    c.custom_cursor = cursor;
}

/// Frees a cursor `makeCursor` made.
pub fn freeCursor(cursor: ?*anyopaque) void {
    if (comptime builtin.os.tag != .macos) return;
    const objc = @import("../objc.zig");
    if (cursor) |cur| objc.release(@ptrCast(cur));
}

test "makeCursor makes a cursor from pixels" {
    var px: [16 * 16 * 4]u8 = undefined;
    for (0..16 * 16) |k| px[k * 4 ..][0..4].* = .{ 255, 255, 255, if (k % 3 == 0) 255 else 0 };
    const cur = makeCursor(&px, 16, 16, 8, 8);
    defer freeCursor(cur);
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(cur != null);
    const objc = @import("../objc.zig");
    const obj: objc.Object = @ptrCast(cur.?);
    try std.testing.expect(objc.msg(objc.BOOL, obj, "isKindOfClass:", .{objc.class("NSCursor")}));
    const hot = objc.msg(objc.CGPoint, obj, "hotSpot", .{});
    try std.testing.expectEqual(@as(f64, 8), hot.x);
    // Too few pixels: none.
    try std.testing.expect(makeCursor(px[0..10], 16, 16, 0, 0) == null);
}
