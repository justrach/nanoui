//! Pictures and textures on the CPU, as `shader.metal` samples them: bilinear,
//! their corners rounded, or their shape filled with one color.
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");

/// A BGRA texel of the image atlas, bilinear as Metal's sampler.
/// Pixels to sample: the image atlas, or a texture's rows.
pub const Source = struct {
    pixels: []const u8,
    w: usize,
    h: usize,
    stride: usize,

    pub fn atlas(p: raster.Pictures) Source {
        return .{ .pixels = p.pixels, .w = p.size, .h = p.size, .stride = @as(usize, p.size) * 4 };
    }

    pub fn texture(t: gpu.Texture) Source {
        return .{ .pixels = t.bgra, .w = t.width, .h = t.height, .stride = if (t.stride > 0) t.stride else @as(usize, t.width) * 4 };
    }
};

fn samplePicture(p: Source, u: f32, v: f32) [4]f32 {
    const fx = u * @as(f32, @floatFromInt(p.w)) - 0.5;
    const fy = v * @as(f32, @floatFromInt(p.h)) - 0.5;
    const x0f = @floor(fx);
    const y0f = @floor(fy);
    const tx = fx - x0f;
    const ty = fy - y0f;
    const mx: i64 = @as(i64, @intCast(p.w)) - 1;
    const my: i64 = @as(i64, @intCast(p.h)) - 1;
    const xs = [2]usize{ @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)), 0, mx)), @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)) + 1, 0, mx)) };
    const ys = [2]usize{ @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)), 0, my)), @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)) + 1, 0, my)) };
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    const weights = [4]f32{ (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty };
    for (0..4) |k| {
        const t = p.pixels[ys[k / 2] * p.stride + xs[k % 2] * 4 ..][0..4];
        for (0..4) |ch| out[ch] += @as(f32, @floatFromInt(t[ch])) / 255 * weights[k];
    }
    return out;
}

pub fn picture(out: gpu.Pixels, i: *const gpu.Instance, p: Source, scale: f32, b: [4]usize) void {
    if (p.w == 0 or p.h == 0 or p.pixels.len < p.stride * p.h) return;
    const inv = 1 / scale;
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const r_abs = @min(@abs(i.radius), @min(hw, hh));
    const r: f32 = if (i.radius < 0) -r_abs else r_abs;
    const rot = i.xf[0] != 0 or gpu.hasMatrix(i);
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const up = raster.unrotate(i, wx, wy);
            if (rot and (up[0] < i.rect[0] or up[1] < i.rect[1] or up[0] > i.rect[0] + i.rect[2] or up[1] > i.rect[1] + i.rect[3])) continue;
            const tx = (up[0] - i.rect[0]) / i.rect[2];
            const ty = (up[1] - i.rect[1]) / i.rect[3];
            const v = i.uv[1] + (i.uv[3] - i.uv[1]) * ty;
            const sd = raster.cornerSdf(up[0] - i.rect[0] - hw, up[1] - i.rect[1] - hh, hw, hh, r);
            const aa = @max(sd[1] * raster.pixelAt(i, inv), 0.0001) * 0.5;
            const k = (1 - raster.smoothstep(-aa, aa, sd[0])) * i.color[3] * raster.clipCover(i, wx, wy, inv);
            if (k <= 0) continue;
            const t = samplePicture(p, i.uv[0] + (i.uv[2] - i.uv[0]) * tx, v);
            if (i.border_color[3] > 0) {
                const a = t[3] * i.border_color[3] * k;
                raster.blend(out.bytes, row + x * 4, i.border_color[0] * a, i.border_color[1] * a, i.border_color[2] * a, a);
                continue;
            }
            raster.blend(out.bytes, row + x * 4, t[2] * k, t[1] * k, t[0] * k, t[3] * k);
        }
    }
}

