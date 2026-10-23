//! Lines and filled triangles on the CPU (`ui.Canvas`), as `shader.metal`
//! draws them: a triangle's pixels are those whose centers it holds, as
//! the GPU rasterizes (an edge through a center belongs to the triangle on
//! its left or above it, so two triangles sharing it draw it once), and a
//! line's are those its round-ended outline, half a pixel wider, reaches.
//! Each row is walked only where the shape can be.
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");

/// The x (points) between which row `wy` crosses the convex polygon `v`
/// (either way round); null when it misses it.
fn span(v: []const [2]f32, wy: f32) ?[2]f32 {
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    for (v, 0..) |p, k| {
        const q = v[(k + 1) % v.len];
        if ((p[1] <= wy and q[1] >= wy) or (q[1] <= wy and p[1] >= wy)) {
            const x = if (q[1] == p[1]) @min(p[0], q[0]) else p[0] + (wy - p[1]) / (q[1] - p[1]) * (q[0] - p[0]);
            const x2 = if (q[1] == p[1]) @max(p[0], q[0]) else x;
            lo = @min(lo, x);
            hi = @max(hi, x2);
        }
    }
    return if (lo <= hi) .{ lo, hi } else null;
}

/// The pixel columns (within `b`) whose centers may lie between `s`'s
/// ends: one more each side, for rounding.
fn columns(s: [2]f32, scale: f32, b: [4]usize) ?[2]usize {
    const x0 = @floor(s[0] * scale - 0.5) - 1;
    const x1 = @ceil(s[1] * scale - 0.5) + 2;
    const lo: usize = @intFromFloat(std.math.clamp(x0, @as(f32, @floatFromInt(b[0])), @as(f32, @floatFromInt(b[2]))));
    const hi: usize = @intFromFloat(std.math.clamp(x1, @as(f32, @floatFromInt(b[0])), @as(f32, @floatFromInt(b[2]))));
    return if (hi > lo) .{ lo, hi } else null;
}

pub fn segment(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize) void {
    const ax = i.uv[0];
    const ay = i.uv[1];
    const abx = i.uv[2] - ax;
    const aby = i.uv[3] - ay;
    const len2 = abx * abx + aby * aby;
    const len = @sqrt(len2);
    const hw = i.border_width * 0.5;
    const inv = 1 / scale;
    const on = i.border_color[0];
    const gap = i.border_color[1];
    const dashed = on > 0 and gap > 0;
    // The box the shader draws: along the line, a point past its ends.
    const ux: f32 = if (len > 0) abx / len else 1;
    const uy: f32 = if (len > 0) aby / len else 0;
    const e = hw + 1;
    const box = [4][2]f32{
        .{ ax - ux * e + uy * e, ay - uy * e - ux * e },
        .{ ax + abx + ux * e + uy * e, ay + aby + uy * e - ux * e },
        .{ ax + abx + ux * e - uy * e, ay + aby + uy * e + ux * e },
        .{ ax - ux * e - uy * e, ay - uy * e + ux * e },
    };
    const c = i.color;
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const cols = columns(span(&box, wy) orelse continue, scale, b) orelse continue;
        const row = y * out.width * 4;
        for (cols[0]..cols[1]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const t: f32 = if (len2 > 0) std.math.clamp(((wx - ax) * abx + (wy - ay) * aby) / len2, 0, 1) else 0;
            const ox = wx - (ax + abx * t);
            const oy = wy - (ay + aby * t);
            const d = @sqrt(ox * ox + oy * oy);
            const grad: f32 = if (d > 0) (@abs(ox) + @abs(oy)) / d else 1;
            const aa = @max(grad * inv, 0.0001) * 0.5;
            var cover = 1 - raster.smoothstep(hw - aa, hw + aa, d);
            if (cover <= 0) continue;
            if (dashed) {
                // Along the line unclamped: its ends are cut square, as its dashes.
                const along = (if (len > 0) ((wx - ax) * abx + (wy - ay) * aby) / len else 0) + i.border_color[2];
                const m = along - (on + gap) * @floor(along / (on + gap));
                const edge = @min(m, on - m);
                const ug: f32 = if (len > 0) (@abs(abx) + @abs(aby)) / len else 0;
                const ea = @max(ug * inv, 0.0001) * 0.5;
                cover *= raster.smoothstep(-ea, ea, edge);
            }
            const a = c[3] * cover * raster.clipCover(i, wx, wy, inv);
            raster.blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

pub fn triangle(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize) void {
    const v = [3][2]f32{ .{ i.uv[0], i.uv[1] }, .{ i.uv[2], i.uv[3] }, .{ i.border_color[0], i.border_color[1] } };
    const area = (v[1][0] - v[0][0]) * (v[2][1] - v[0][1]) - (v[1][1] - v[0][1]) * (v[2][0] - v[0][0]);
    if (area == 0) return;
    const side: f32 = if (area < 0) -1 else 1;
    const smooth: u32 = @intFromFloat(@max(i.border_color[2], 0));
    // Each edge's function (positive inside), its length, and whether a
    // center on it is inside: on the triangle's left or top edges.
    var ex: [3]f32 = undefined;
    var ey: [3]f32 = undefined;
    var elen: [3]f32 = undefined;
    var top_left: [3]bool = undefined;
    for (0..3) |k| {
        const p = v[k];
        const q = v[(k + 1) % 3];
        ex[k] = q[0] - p[0];
        ey[k] = q[1] - p[1];
        elen[k] = @max(@sqrt(ex[k] * ex[k] + ey[k] * ey[k]), 0.0001);
        // The normal pointing inside: right (a left edge) or down (a top one).
        const nx = side * -ey[k];
        const ny = side * ex[k];
        top_left[k] = nx > 0 or (nx == 0 and ny > 0);
    }
    const inv = 1 / scale;
    const c = i.color;
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const cols = columns(span(&v, wy) orelse continue, scale, b) orelse continue;
        const row = y * out.width * 4;
        pixels: for (cols[0]..cols[1]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            var cover: f32 = 1;
            for (0..3) |k| {
                const p = v[k];
                const f = side * (ex[k] * (wy - p[1]) - ey[k] * (wx - p[0]));
                if (f < 0 or (f == 0 and !top_left[k])) continue :pixels;
                if (smooth & (@as(u32, 1) << @intCast(k)) != 0) {
                    const d = f / elen[k];
                    const aa = @max((@abs(ex[k]) + @abs(ey[k])) / elen[k] * inv, 0.0001) * 0.5;
                    cover *= raster.smoothstep(-aa, aa, d);
                }
            }
            const a = c[3] * cover * raster.clipCover(i, wx, wy, inv);
            raster.blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

// Shadows as the shader draws them: a box's coverage blurred by a
// Gaussian, exact along x with erf, sampled eight times along y.
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

pub fn shadowAlpha(px: f32, py: f32, hw: f32, hh: f32, corner: f32, sigma: f32) f32 {
    const c = @abs(corner);
    const low = py - hh;
    const high = py + hh;
    const start = std.math.clamp(-3 * sigma, low, high);
    const end = std.math.clamp(3 * sigma, low, high);
    const step = (end - start) / 8;
    var y = start + step * 0.5;
    var alpha: f32 = 0;
    for (0..8) |_| {
        alpha += blurAlongX(px, py - y, sigma, c, hw, hh) * gaussian(y, sigma) * step;
        y += step;
    }
    return alpha;
}

pub fn shadowDither(x: usize, y: usize) f32 {
    const ux: u32 = @truncate(x);
    const uy: u32 = @truncate(y);
    var h1: u32 = (ux *% 1664525 +% uy *% 1013904223) ^ 0x68bc21eb;
    h1 ^= h1 >> 15;
    h1 *%= 0x85ebca6b;
    h1 ^= h1 >> 13;
    var h2: u32 = (ux *% 22695477 +% uy *% 2891336453) ^ 0x02e5be93;
    h2 ^= h2 >> 15;
    h2 *%= 0xc2b2ae35;
    h2 ^= h2 >> 13;
    const v1 = @as(f32, @floatFromInt(h1 & 0xffff)) / 65535.0;
    const v2 = @as(f32, @floatFromInt(h2 & 0xffff)) / 65535.0;
    return (v1 + v2 - 1.0) * (0.5 / 255.0);
}
