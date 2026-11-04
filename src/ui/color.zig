//! The colour stage's maths on the CPU: what `texture_post.metal` (the
//! real app's post-process shader, lifted verbatim) computes for a texel,
//! so the CPU renderer draws a video frame as the GPU does. Y'CbCr to
//! R'G'B' by its range and matrix, the transfer decoded to linear light,
//! PQ and HLG brought to SDR, display sRGB encoded, then the source LUT and
//! the output LUT sampled trilinear as Metal's linear sampler samples a 3D
//! texture.
const std = @import("std");
const gpu = @import("gpu.zig");

/// The post shader's `PostUniforms`, field for field (16-byte padded as
/// MSL lays the struct out).
pub const Uniforms = extern struct {
    domain_min: [4]f32 = .{ 0, 0, 0, 0 },
    domain_max: [4]f32 = .{ 1, 1, 1, 0 },
    source_domain_min: [4]f32 = .{ 0, 0, 0, 0 },
    source_domain_max: [4]f32 = .{ 1, 1, 1, 0 },
    lut_size: f32 = 0,
    lut_enabled: u32 = 0,
    source_lut_size: f32 = 0,
    source_lut_enabled: u32 = 0,
    /// 0 RGB as sampled, 1 8-bit Y'CbCr, 2 10-bit Y'CbCr, 3 linear RGB.
    source_mode: u32 = 0,
    range_mode: u32 = 0,
    matrix_mode: u32 = 0,
    transfer_mode: u32 = 0,
    hdr_tone_map: u32 = 0,
    _pad: [3]u32 = .{ 0, 0, 0 },
};
comptime {
    std.debug.assert(@sizeOf(Uniforms) == 112);
}

/// The source mode a texture's format takes (`Uniforms.source_mode`).
pub fn sourceMode(f: gpu.Format) u32 {
    return switch (f) {
        .bgra8 => 0,
        .ycbcr420_8 => 1,
        .ycbcr420_10, .ycbcr422_10, .ycbcr444_10 => 2,
        .rgba16f => 3,
    };
}

/// The uniforms for `t`, its source read as `mode`.
pub fn uniforms(t: gpu.Texture, mode: u32) Uniforms {
    var u: Uniforms = .{
        .source_mode = mode,
        .range_mode = @backingInt(t.range),
        .matrix_mode = @backingInt(t.matrix),
        .transfer_mode = @backingInt(t.transfer),
        .hdr_tone_map = @intFromBool(t.tone_map),
    };
    if (t.lut) |l| if (l.valid()) {
        u.lut_enabled = 1;
        u.lut_size = @floatFromInt(l.size);
        u.domain_min = .{ l.domain_min[0], l.domain_min[1], l.domain_min[2], 0 };
        u.domain_max = .{ l.domain_max[0], l.domain_max[1], l.domain_max[2], 0 };
    };
    if (t.source_lut) |l| if (l.valid()) {
        u.source_lut_enabled = 1;
        u.source_lut_size = @floatFromInt(l.size);
        u.source_domain_min = .{ l.domain_min[0], l.domain_min[1], l.domain_min[2], 0 };
        u.source_domain_max = .{ l.domain_max[0], l.domain_max[1], l.domain_max[2], 0 };
    };
    return u;
}

fn pow3(v: [3]f32, e: f32) [3]f32 {
    return .{ std.math.pow(f32, v[0], e), std.math.pow(f32, v[1], e), std.math.pow(f32, v[2], e) };
}

fn rec709ToLinear(v: f32) f32 {
    return if (v < 0.081) v / 4.5 else std.math.pow(f32, (v + 0.099) / 1.099, 1.0 / 0.45);
}

fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgb(v_in: f32) f32 {
    const v = @max(v_in, 0);
    return if (v <= 0.0031308) 12.92 * v else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

fn pqToLinear(v: f32) f32 {
    const m1: f32 = 2610.0 / 16384.0;
    const m2: f32 = 2523.0 / 32.0;
    const c1: f32 = 3424.0 / 4096.0;
    const c2: f32 = 2413.0 / 128.0;
    const c3: f32 = 2392.0 / 128.0;
    const p = std.math.pow(f32, @max(v, 0), 1.0 / m2);
    return std.math.pow(f32, @max((p - c1) / (c2 - c3 * p), 0), 1.0 / m1);
}

fn hlgToLinear(v: f32) f32 {
    return if (v <= 0.5) v * v / 3.0 else (@exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0;
}

fn hdrToSdr(linear: [3]f32, transfer_mode: u32, tone_map: u32) [3]f32 {
    const peak: f32 = if (transfer_mode == 3) 10000 else 1000;
    const nits = [3]f32{ linear[0] * peak, linear[1] * peak, linear[2] * peak };
    if (tone_map == 0) return .{ std.math.clamp(nits[0] / 100, 0, 1), std.math.clamp(nits[1] / 100, 0, 1), std.math.clamp(nits[2] / 100, 0, 1) };
    const l = @max(nits[0] * 0.2627 + nits[1] * 0.6780 + nits[2] * 0.0593, 0);
    if (l <= 0.000001) return .{ 0, 0, 0 };
    const k = (l / (l + 100)) / l;
    return .{ std.math.clamp(nits[0] * k, 0, 1), std.math.clamp(nits[1] * k, 0, 1), std.math.clamp(nits[2] * k, 0, 1) };
}

/// `alc_ycbcr_to_rgb`: normalized code values to clamped R'G'B'.
pub fn ycbcrToRgb(y: f32, cb: f32, cr: f32, u: Uniforms) [3]f32 {
    const ten = u.source_mode == 2;
    const code_max: f32 = if (ten) 1023 else 255;
    const y_min: f32 = if (ten) 64 else 16;
    const y_range: f32 = if (ten) 876 else 219;
    const c_mid: f32 = if (ten) 512 else 128;
    const c_range: f32 = if (ten) 896 else 224;
    const Y = if (u.range_mode == 0) (y - y_min / code_max) * (code_max / y_range) else y;
    const Cb = if (u.range_mode == 0) (cb - c_mid / code_max) * (code_max / c_range) else cb - 0.5;
    const Cr = if (u.range_mode == 0) (cr - c_mid / code_max) * (code_max / c_range) else cr - 0.5;
    const rgb: [3]f32 = switch (u.matrix_mode) {
        1 => .{ Y + 1.402 * Cr, Y - 0.344136 * Cb - 0.714136 * Cr, Y + 1.772 * Cb },
        2 => .{ Y + 1.4746 * Cr, Y - 0.164553 * Cb - 0.571353 * Cr, Y + 1.8814 * Cb },
        else => .{ Y + 1.5748 * Cr, Y - 0.187324 * Cb - 0.468124 * Cr, Y + 1.8556 * Cb },
    };
    return .{ std.math.clamp(rgb[0], 0, 1), std.math.clamp(rgb[1], 0, 1), std.math.clamp(rgb[2], 0, 1) };
}

/// Encoded R'G'B' to display sRGB by `u`'s transfer and tone map.
pub fn toDisplay(encoded: [3]f32, u: Uniforms) [3]f32 {
    var linear: [3]f32 = undefined;
    for (encoded, 0..) |v, k| linear[k] = switch (u.transfer_mode) {
        1 => srgbToLinear(v),
        2 => v,
        3 => pqToLinear(v),
        4 => hlgToLinear(v),
        else => rec709ToLinear(v),
    };
    if (u.transfer_mode == 3 or u.transfer_mode == 4) linear = hdrToSdr(linear, u.transfer_mode, u.hdr_tone_map);
    return .{ linearToSrgb(linear[0]), linearToSrgb(linear[1]), linearToSrgb(linear[2]) };
}

/// Linear RGB (source mode 3) to display sRGB.
pub fn linearToDisplay(rgb: [3]f32, u: Uniforms) [3]f32 {
    var out: [3]f32 = undefined;
    for (rgb, 0..) |v_in, k| {
        var v = @max(v_in, 0);
        if (u.hdr_tone_map == 1) v = v / (1 + v);
        out[k] = linearToSrgb(std.math.clamp(v, 0, 1));
    }
    return out;
}

/// A 3D LUT sampled as Metal's linear, clamped sampler samples its
/// texture at texel centres (`alc_apply_cube`): trilinear between the
/// nearest grid points.
pub fn applyLut(l: gpu.Lut, rgb: [3]f32) [3]f32 {
    if (!l.valid()) return rgb;
    const n: usize = l.size;
    var lo: [3]usize = undefined;
    var hi: [3]usize = undefined;
    var t: [3]f32 = undefined;
    for (0..3) |a| {
        const span = @max(l.domain_max[a] - l.domain_min[a], 1e-6);
        const norm = std.math.clamp((rgb[a] - l.domain_min[a]) / span, 0, 1);
        const pos = norm * @as(f32, @floatFromInt(n - 1));
        lo[a] = @min(@as(usize, @intFromFloat(@floor(pos))), n - 1);
        hi[a] = @min(lo[a] + 1, n - 1);
        t[a] = pos - @as(f32, @floatFromInt(lo[a]));
    }
    var out: [3]f32 = undefined;
    for (0..3) |ch| {
        const at = struct {
            fn f(lut: gpu.Lut, size: usize, r: usize, g: usize, b: usize, c: usize) f32 {
                return @floatCast(lut.data[((b * size + g) * size + r) * 4 + c]);
            }
        }.f;
        const x00 = lerp(at(l, n, lo[0], lo[1], lo[2], ch), at(l, n, hi[0], lo[1], lo[2], ch), t[0]);
        const x10 = lerp(at(l, n, lo[0], hi[1], lo[2], ch), at(l, n, hi[0], hi[1], lo[2], ch), t[0]);
        const x01 = lerp(at(l, n, lo[0], lo[1], hi[2], ch), at(l, n, hi[0], lo[1], hi[2], ch), t[0]);
        const x11 = lerp(at(l, n, lo[0], hi[1], hi[2], ch), at(l, n, hi[0], hi[1], hi[2], ch), t[0]);
        out[ch] = lerp(lerp(x00, x10, t[1]), lerp(x01, x11, t[1]), t[2]);
    }
    return out;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a * (1 - t) + b * t;
}

/// The stage after the source is decoded: the source LUT, then the
/// output LUT, as `alc_post_fs` ends.
pub fn applyLuts(t: gpu.Texture, rgb: [3]f32) [3]f32 {
    var c = rgb;
    if (t.source_lut) |l| c = applyLut(l, c);
    if (t.lut) |l| c = applyLut(l, c);
    return c;
}

/// A colour 0 to 1 as an 8-bit unorm, as the GPU stores it.
pub fn unorm8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

test "video-range BT.709 black and white land on display endpoints" {
    const u: Uniforms = .{ .source_mode = 1 };
    const black = toDisplay(ycbcrToRgb(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, u), u);
    const white = toDisplay(ycbcrToRgb(235.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, u), u);
    for (black) |v| try std.testing.expectApproxEqAbs(@as(f32, 0), v, 0.0001);
    for (white) |v| try std.testing.expectApproxEqAbs(@as(f32, 1), v, 0.0001);
}

test "an identity LUT returns what it is given" {
    var data: [3 * 3 * 3 * 4]f16 = undefined;
    for (0..3) |b| for (0..3) |g| for (0..3) |r| {
        const i = ((b * 3 + g) * 3 + r) * 4;
        data[i] = @floatFromInt(r);
        data[i + 1] = @floatFromInt(g);
        data[i + 2] = @floatFromInt(b);
        data[i + 3] = 1;
        for (0..3) |k| data[i + k] /= 2;
    };
    const l: gpu.Lut = .{ .key = 1, .size = 3, .data = &data };
    const out = applyLut(l, .{ 0.2, 0.55, 0.9 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), out[2], 0.001);
}
