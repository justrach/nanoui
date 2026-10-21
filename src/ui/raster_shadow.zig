//! CPU Gaussian shadows, the same math as `shader.metal` (erf along x,
//! four samples along y). `samples` defaults to 4 so the Metal raster
//! tests still match; hill-climb can set 1 for a cheaper Linux encode.
const std = @import("std");
const gpu = @import("gpu.zig");

/// Y samples of the Gaussian integral. The shader uses 4.
pub var samples: u32 = 4;

fn gaussian(x: f32, sigma: f32) f32 {
    return @exp(-(x * x) / (2 * sigma * sigma)) / (@sqrt(2 * std.math.pi) * sigma);
}

fn erf(x: f32) f32 {
    const s: f32 = if (x < 0) -1 else 1;
    const a = @abs(x);
    var y = 1 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    y *= y;
    return s - s / (y * y);
}

fn blurAlongX(x: f32, y: f32, sigma: f32, corner: f32, hw: f32, hh: f32) f32 {
    const delta = @min(hh - corner - @abs(y), 0);
    const curved = hw - corner + @sqrt(@max(0, corner * corner - delta * delta));
    const k = @sqrt(@as(f32, 0.5)) / sigma;
    const lo = 0.5 + 0.5 * erf((x - curved) * k);
    const hi = 0.5 + 0.5 * erf((x + curved) * k);
    return hi - lo;
}

/// How much of the rounded box is under this pixel, as the shader's
/// `shadow_alpha`. `n` Y samples; 4 matches Metal.
pub fn alpha(px: f32, py: f32, hw: f32, hh: f32, corner: f32, sigma: f32, n: u32) f32 {
    const count: f32 = @floatFromInt(@max(n, 1));
    const low = py - hh;
    const high = py + hh;
    const start = std.math.clamp(-3 * sigma, low, high);
    const end = std.math.clamp(3 * sigma, low, high);
    const step = (end - start) / count;
    var y = start + step * 0.5;
    var a: f32 = 0;
    for (0..@max(n, 1)) |_| {
        a += blurAlongX(px, py - y, sigma, corner, hw, hh) * gaussian(y, sigma) * step;
        y += step;
    }
    return a;
}

/// `cover` is `raster.clipCover` (1 when the clip is a plain rectangle).
pub fn draw(
    out: gpu.Pixels,
    i: *const gpu.Instance,
    scale: f32,
    b: [4]usize,
    cover: *const fn (*const gpu.Instance, f32, f32, f32) f32,
) void {
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const cx = i.rect[0] + hw;
    const cy = i.rect[1] + hh;
    const r = @min(i.radius, @min(hw, hh));
    const sigma = @max(i.border_width, 0.25);
    const c = i.color;
    const inv = 1 / scale;
    const n = @min(@max(samples, 1), 8);
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const py = wy - cy;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const pxl = wx - cx;
            var a = alpha(pxl, py, hw, hh, r, sigma, n);
            if (i.clip_round > 0) a *= cover(i, wx, wy, inv);
            a *= c[3];
            if (a <= 0) continue;
            blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

inline fn blend(bytes: []u8, at: usize, r: f32, g: f32, bl: f32, a: f32) void {
    const inv = 1 - a;
    const d = bytes[at..][0..4];
    d[0] = @intFromFloat(@min(255, bl * 255 + @as(f32, @floatFromInt(d[0])) * inv + 0.5));
    d[1] = @intFromFloat(@min(255, g * 255 + @as(f32, @floatFromInt(d[1])) * inv + 0.5));
    d[2] = @intFromFloat(@min(255, r * 255 + @as(f32, @floatFromInt(d[2])) * inv + 0.5));
    d[3] = @intFromFloat(@min(255, a * 255 + @as(f32, @floatFromInt(d[3])) * inv + 0.5));
}

test "four samples stay in (0, 1]" {
    const a = alpha(3, 2, 12, 12, 6, 4, 4);
    try std.testing.expect(a > 0 and a <= 1);
}
