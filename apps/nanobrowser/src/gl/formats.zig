//! Pixel arithmetic the driver won't check for us: how many bytes a call may read or
//! write, and the page's unpack options GL has never heard of.
const std = @import("std");

pub const RED: u32 = 0x1903;
pub const ALPHA: u32 = 0x1906;
pub const RGB: u32 = 0x1907;
pub const RGBA: u32 = 0x1908;
pub const LUMINANCE: u32 = 0x1909;
pub const LUMINANCE_ALPHA: u32 = 0x190A;
pub const DEPTH_COMPONENT: u32 = 0x1902;
pub const DEPTH_STENCIL: u32 = 0x84F9;
pub const RG: u32 = 0x8227;
pub const RG_INTEGER: u32 = 0x8228;
pub const RED_INTEGER: u32 = 0x8D94;
pub const RGB_INTEGER: u32 = 0x8D98;
pub const RGBA_INTEGER: u32 = 0x8D99;
pub const UNSIGNED_BYTE: u32 = 0x1401;
pub const HALF_FLOAT: u32 = 0x140B;
pub const HALF_FLOAT_OES: u32 = 0x8D61;

fn components(format: u32) u32 {
    return switch (format) {
        RED, ALPHA, LUMINANCE, RED_INTEGER, DEPTH_COMPONENT => 1,
        RG, LUMINANCE_ALPHA, RG_INTEGER => 2,
        RGB, RGB_INTEGER => 3,
        RGBA, RGBA_INTEGER => 4,
        else => 0,
    };
}

/// Bytes per pixel of `format` and `kind`, 0 for what isn't a pair.
pub fn bytesPerPixel(format: u32, kind: u32) u32 {
    return switch (kind) {
        0x1400, 0x1401 => components(format), // BYTE, UNSIGNED_BYTE
        0x1402, 0x1403, 0x140B, 0x8D61 => components(format) * 2, // SHORT, UNSIGNED_SHORT, HALF_FLOAT, its OES name
        0x1404, 0x1405, 0x1406 => components(format) * 4, // INT, UNSIGNED_INT, FLOAT
        0x8363, 0x8033, 0x8034 => 2, // 565, 4444, 5551
        0x8368, 0x8C3B, 0x8C3E, 0x84FA => 4, // 2_10_10_10_REV, 10F_11F_11F_REV, 5_9_9_9_REV, 24_8
        0x8DAD => 8, // FLOAT_32_UNSIGNED_INT_24_8_REV
        else => 0,
    };
}

/// Bytes from one row's start to the next's.
pub fn rowStride(width: u64, pixel: u64, alignment: u64) u64 {
    const row = width * pixel;
    return (row + alignment - 1) / alignment * alignment;
}

/// Bytes a `width` by `height` block takes, the last row unpadded as GL reads it.
pub fn blockBytes(width: u64, height: u64, pixel: u64, alignment: u64) u64 {
    if (width == 0 or height == 0) return 0;
    return (height - 1) * rowStride(width, pixel, alignment) + width * pixel;
}

/// Reverses `rows` of `stride` bytes in place.
pub fn flipRows(px: []u8, stride: usize, rows: usize, row_bytes: usize, scratch: []u8) void {
    if (rows < 2) return;
    var top: usize = 0;
    var bottom: usize = rows - 1;
    while (top < bottom) : ({
        top += 1;
        bottom -= 1;
    }) {
        const a = px[top * stride ..][0..row_bytes];
        const b = px[bottom * stride ..][0..row_bytes];
        @memcpy(scratch[0..row_bytes], a);
        @memcpy(a, b);
        @memcpy(b, scratch[0..row_bytes]);
    }
}

/// Multiplies color by alpha in 8-bit pixels whose alpha is byte 3.
pub fn premultiply(px: []u8) void {
    var i: usize = 0;
    while (i + 4 <= px.len) : (i += 4) {
        const a: u32 = px[i + 3];
        if (a == 255) continue;
        px[i] = @intCast((@as(u32, px[i]) * a + 127) / 255);
        px[i + 1] = @intCast((@as(u32, px[i + 1]) * a + 127) / 255);
        px[i + 2] = @intCast((@as(u32, px[i + 2]) * a + 127) / 255);
    }
}

const testing = std.testing;

test "webgl formats: bytes per pixel" {
    try testing.expectEqual(@as(u32, 4), bytesPerPixel(RGBA, UNSIGNED_BYTE));
    try testing.expectEqual(@as(u32, 3), bytesPerPixel(RGB, UNSIGNED_BYTE));
    try testing.expectEqual(@as(u32, 2), bytesPerPixel(RGB, 0x8363));
    try testing.expectEqual(@as(u32, 16), bytesPerPixel(RGBA, 0x1406));
    try testing.expectEqual(@as(u32, 8), bytesPerPixel(RGBA, HALF_FLOAT_OES));
    try testing.expectEqual(@as(u32, 0), bytesPerPixel(0x1234, UNSIGNED_BYTE));
    try testing.expectEqual(@as(u32, 0), bytesPerPixel(RGBA, 0x1234));
}

test "webgl formats: a block's bytes, the last row unpadded" {
    try testing.expectEqual(@as(u64, 4), rowStride(1, 3, 4));
    try testing.expectEqual(@as(u64, 7), blockBytes(1, 2, 3, 4));
    try testing.expectEqual(@as(u64, 16), blockBytes(2, 2, 4, 4));
    try testing.expectEqual(@as(u64, 0), blockBytes(0, 9, 4, 4));
}

test "webgl formats: rows flipped, padding left, alpha multiplied" {
    var px = [_]u8{ 1, 2, 9, 3, 4, 9, 5, 6, 9 };
    var scratch: [2]u8 = undefined;
    flipRows(&px, 3, 3, 2, &scratch);
    try testing.expectEqualSlices(u8, &.{ 5, 6, 9, 3, 4, 9, 1, 2, 9 }, &px);
    var c = [_]u8{ 255, 128, 0, 128, 10, 20, 30, 255 };
    premultiply(&c);
    try testing.expectEqualSlices(u8, &.{ 128, 64, 0, 128, 10, 20, 30, 255 }, &c);
}
