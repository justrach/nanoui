//! The last stage of the JPEG decoder: frequency blocks to samples (the
//! inverse DCT), sample planes to one row of pixels (chroma replicated, colors
//! converted), and the turn an EXIF orientation asks for. Nothing here reads
//! the file, so nothing here can be led out of bounds by it: the sizes come
//! from `jpeg_decode.zig`, already checked. Arithmetic on samples wraps, since
//! a hostile quantization table can ask for values no real picture has.
const std = @import("std");
const Component = @import("jpeg_scan.zig").Component;

/// How a frame's components become red, green and blue.
pub const Color = enum { gray, rgb, ycc, cmyk, ycck };

const const_bits = 13;
const pass1_bits = 2;

/// One 1-D inverse DCT (the Loeffler factorization libjpeg calls "islow",
/// which this reproduces exactly), its results not yet scaled down.
inline fn idct1(v0: i32, v1: i32, v2: i32, v3: i32, v4: i32, v5: i32, v6: i32, v7: i32) [8]i32 {
    // Even part.
    const e = (v2 +% v6) *% 4433;
    const even2 = e -% v6 *% 15137;
    const even3 = e +% v2 *% 6270;
    const even0 = (v0 +% v4) *% (1 << const_bits);
    const even1 = (v0 -% v4) *% (1 << const_bits);
    const t10 = even0 +% even3;
    const t13 = even0 -% even3;
    const t11 = even1 +% even2;
    const t12 = even1 -% even2;
    // Odd part.
    const z5 = (v7 +% v3 +% v5 +% v1) *% 9633;
    const z1 = (v7 +% v1) *% -7373;
    const z2 = (v5 +% v3) *% -20995;
    const z3 = (v7 +% v3) *% -16069 +% z5;
    const z4 = (v5 +% v1) *% -3196 +% z5;
    const o0 = v7 *% 2446 +% z1 +% z3;
    const o1 = v5 *% 16819 +% z2 +% z4;
    const o2 = v3 *% 25172 +% z2 +% z3;
    const o3 = v1 *% 12299 +% z1 +% z4;
    return .{ t10 +% o3, t11 +% o2, t12 +% o1, t13 +% o0, t13 -% o0, t12 -% o1, t11 -% o2, t10 -% o3 };
}

/// Inverse DCT of dequantized coefficients in natural order; writes an 8×8 of
/// samples at the start of `out`, `stride` bytes a row.
pub fn idct(in: *const [64]i32, out: []u8, stride: usize) void {
    var ws: [64]i32 = undefined;
    const col_shift = const_bits - pass1_bits;
    const col_round: i32 = 1 << (col_shift - 1);
    for (0..8) |c| {
        if (in[8 + c] | in[16 + c] | in[24 + c] | in[32 + c] | in[40 + c] | in[48 + c] | in[56 + c] == 0) {
            const dc = in[c] *% (1 << pass1_bits);
            for (0..8) |r| ws[r * 8 + c] = dc;
            continue;
        }
        const t = idct1(in[c], in[8 + c], in[16 + c], in[24 + c], in[32 + c], in[40 + c], in[48 + c], in[56 + c]);
        for (t, 0..) |v, r| ws[r * 8 + c] = (v +% col_round) >> col_shift;
    }
    const row_shift = const_bits + pass1_bits + 3;
    const row_round: i32 = 1 << (row_shift - 1);
    for (0..8) |r| {
        const w = ws[r * 8 ..][0..8];
        const t = idct1(w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]);
        const dst = out[r * stride..][0..8];
        for (t, dst) |v, *d| d.* = clamp(((v +% row_round) >> row_shift) +% 128);
    }
}

inline fn clamp(v: i32) u8 {
    return if (v < 0) 0 else if (v > 255) 255 else @intCast(v);
}

/// Turns a progressive component's stored coefficients into its plane. A
/// component no scan reached keeps its plane as it was: mid gray.
pub fn finishProgressive(c: *Component) void {
    if (!c.latched) return;
    const stride: usize = @as(usize, c.blocks_w) * 8;
    var at: usize = 0;
    for (0..c.blocks_h) |by| {
        for (0..c.blocks_w) |bx| {
            var block: [64]i32 = undefined;
            for (&block, c.coefs[at..][0..64], &c.quant) |*b, coef, q| b.* = @as(i32, coef) *% q;
            idct(&block, c.plane[by * 8 * stride + bx * 8..], stride);
            at += 64;
        }
    }
}

/// YCbCr to RGB with libjpeg's rounding.
inline fn yccToRgb(y: u8, cb: u8, cr: u8) [3]u8 {
    const l: i32 = y;
    const b: i32 = @as(i32, cb) - 128;
    const r: i32 = @as(i32, cr) - 128;
    return .{
        clamp(l + ((91881 * r + 32768) >> 16)),
        clamp(l + ((-22554 * b - 46802 * r + 32768) >> 16)),
        clamp(l + ((116130 * b + 32768) >> 16)),
    };
}

inline fn scale(a: u8, b: u8) u8 {
    return @intCast((@as(u32, a) * b + 127) / 255);
}

/// The whole picture as opaque BGRA, owned by `gpa`. Chroma is replicated,
/// at any ratio of sampling factors.
pub fn render(gpa: std.mem.Allocator, comps: []const Component, width: u32, height: u32, hmax: u32, vmax: u32, color: Color) error{OutOfMemory}![]u8 {
    const w: usize = width;
    const out = try gpa.alloc(u8, w * height * 4);
    errdefer gpa.free(out);
    const rows = try gpa.alloc(u8, w * comps.len);
    defer gpa.free(rows);
    const xmap = try gpa.alloc(u32, w * comps.len);
    defer gpa.free(xmap);
    for (comps, 0..) |c, i| {
        for (xmap[i * w..][0..w], 0..) |*m, x| m.* = @intCast(x * c.h / hmax);
    }
    var lines: [4][]const u8 = @splat(&.{});
    for (0..height) |y| {
        for (comps, 0..) |c, i| {
            const stride = @as(usize, c.blocks_w) * 8;
            const src = c.plane[(y * c.v / vmax) * stride..][0..stride];
            if (c.h == hmax) {
                lines[i] = src[0..w];
            } else {
                const row = rows[i * w..][0..w];
                for (row, xmap[i * w..][0..w]) |*d, sx| d.* = src[sx];
                lines[i] = row;
            }
        }
        convertRow(out[y * w * 4..][0 .. w * 4], &lines, color);
    }
    return out;
}

fn convertRow(dst: []u8, lines: *const [4][]const u8, color: Color) void {
    const n = dst.len / 4;
    for (0..n) |x| {
        const rgb: [3]u8 = switch (color) {
            .gray => .{ lines[0][x], lines[0][x], lines[0][x] },
            .rgb => .{ lines[0][x], lines[1][x], lines[2][x] },
            .ycc => yccToRgb(lines[0][x], lines[1][x], lines[2][x]),
            // Adobe stores CMYK inverted, and browsers read every CMYK JPEG so.
            .cmyk => .{ scale(lines[0][x], lines[3][x]), scale(lines[1][x], lines[3][x]), scale(lines[2][x], lines[3][x]) },
            .ycck => blk: {
                const c = yccToRgb(lines[0][x], lines[1][x], lines[2][x]);
                const k = lines[3][x];
                break :blk .{ scale(255 - c[0], k), scale(255 - c[1], k), scale(255 - c[2], k) };
            },
        };
        const p = dst[x * 4..][0..4];
        p[0] = rgb[2];
        p[1] = rgb[1];
        p[2] = rgb[0];
        p[3] = 255;
    }
}

pub const Oriented = struct { bgra: []u8, width: u32, height: u32 };

/// Applies an EXIF orientation (2..8) to `src`, which is freed on success and
/// left to the caller on failure.
pub fn orient(gpa: std.mem.Allocator, src: []u8, width: u32, height: u32, orientation: u8) error{OutOfMemory}!Oriented {
    const dst = try gpa.alloc(u8, src.len);
    const w: usize = width;
    const h: usize = height;
    const swap = orientation >= 5;
    const dw = if (swap) h else w;
    for (0..h) |y| {
        for (0..w) |x| {
            const at: [2]usize = switch (orientation) {
                2 => .{ w - 1 - x, y },
                3 => .{ w - 1 - x, h - 1 - y },
                4 => .{ x, h - 1 - y },
                5 => .{ y, x },
                6 => .{ h - 1 - y, x },
                7 => .{ h - 1 - y, w - 1 - x },
                8 => .{ y, w - 1 - x },
                else => .{ x, y },
            };
            @memcpy(dst[(at[1] * dw + at[0]) * 4..][0..4], src[(y * w + x) * 4..][0..4]);
        }
    }
    gpa.free(src);
    return .{ .bgra = dst, .width = if (swap) height else width, .height = if (swap) width else height };
}
