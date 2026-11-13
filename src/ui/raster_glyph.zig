//! The CPU renderer's text quads (`raster.zig`): glyph coverage sampled
//! from the atlas, as Metal's linear filter does, and native Windows glyphs
//! blended as the Direct3D 11 shader blends them.
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const Mask = raster.Mask;
const blend = raster.blend;
const clipCover = raster.clipCover;
const unit = raster.unit;
const unrotate = raster.unrotate;

/// The atlas sampled as Metal's linear filter with clamped edges does.
fn sample(mask: Mask, u: f32, v: f32) f32 {
    const s: f32 = @floatFromInt(mask.size);
    const fx = u * s - 0.5;
    const fy = v * s - 0.5;
    const x0f = @floor(fx);
    const y0f = @floor(fy);
    const tx = fx - x0f;
    const ty = fy - y0f;
    const max: i64 = @as(i64, mask.size) - 1;
    const x0: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)), 0, max));
    const y0: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)), 0, max));
    const x1: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)) + 1, 0, max));
    const y1: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)) + 1, 0, max));
    const n: usize = mask.size;
    const a = @as(f32, @floatFromInt(mask.pixels[y0 * n + x0]));
    const bb = @as(f32, @floatFromInt(mask.pixels[y0 * n + x1]));
    const c = @as(f32, @floatFromInt(mask.pixels[y1 * n + x0]));
    const d = @as(f32, @floatFromInt(mask.pixels[y1 * n + x1]));
    const top = a + (bb - a) * tx;
    const bottom = c + (d - c) * tx;
    return (top + (bottom - top) * ty) / 255;
}

/// A text quad: its atlas cell's coverage, native ClearType and grayscale
/// glyphs blended as DirectWrite blends them, by the quad's color.
pub fn glyph(out: gpu.Pixels, i: *const gpu.Instance, mask: Mask, scale: f32, b: [4]usize) void {
    if (mask.size == 0) return;
    const inv = 1 / scale;
    const c = i.color;
    const rot = i.xf[0] != 0 or gpu.hasMatrix(i);
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const up = unrotate(i, wx, wy);
            if (rot and (up[0] < i.rect[0] or up[1] < i.rect[1] or up[0] > i.rect[0] + i.rect[2] or up[1] > i.rect[1] + i.rect[3])) continue;
            const tx = (up[0] - i.rect[0]) / i.rect[2];
            const ty = (up[1] - i.rect[1]) / i.rect[3];
            const u = i.uv[0] + (i.uv[2] - i.uv[0]) * tx;
            const v = i.uv[1] + (i.uv[3] - i.uv[1]) * ty;
            var opacity = c[3] * clipCover(i, wx, wy, inv);
            // A truncated line fading out, as the shader fades it.
            if (i.border_width > 0) opacity *= std.math.clamp((i.radius - wx) / i.border_width, 0, 1);
            const at = row + x * 4;
            if (mask.native_pixels.len > 0) {
                const side: f32 = @floatFromInt(mask.size);
                const ax: usize = @intFromFloat(std.math.clamp(@floor(u * side), 0, side - 1));
                const ay: usize = @intFromFloat(std.math.clamp(@floor(v * side), 0, side - 1));
                const native = mask.native_pixels[(ay * mask.size + ax) * 4 ..][0..4];
                if (native[3] != 0) {
                    const classic = native[3] == 254 or native[3] == 127;
                    const text_params = if (classic) mask.classic_text_params else mask.text_params;
                    const gray_params = if (classic) mask.classic_gray_params else mask.text_params;
                    const lightness = 0.30 * c[0] + 0.59 * c[1] + 0.11 * c[2];
                    // ClearType requires an opaque destination. Transparent
                    // pixels retain genuine grayscale coverage and alpha.
                    if ((native[3] == 255 or native[3] == 254) and out.bytes[at + 3] == 255) {
                        for (0..3) |channel| {
                            const cov = text_params.coverage(@as(f32, @floatFromInt(native[channel])) / 255, c[channel], lightness, true) * opacity;
                            const dest = at + 2 - channel; // output is BGRA
                            out.bytes[dest] = unit(c[channel] * cov + @as(f32, @floatFromInt(out.bytes[dest])) / 255 * (1 - cov));
                        }
                        continue;
                    }
                    const a = gray_params.coverage(sample(mask, u, v), 0.25 * c[0] + 0.5 * c[1] + 0.25 * c[2], lightness, false) * opacity;
                    blend(out.bytes, at, c[0] * a, c[1] * a, c[2] * a, a);
                    continue;
                }
            }
            const a = sample(mask, u, v) * opacity;
            blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}
