//! Lines and filled triangles on the CPU (`ui.Canvas`), as `shader.metal`
//! draws them: a triangle's pixels are those whose centers it holds, as
//! the GPU rasterizes (an edge through a center belongs to the triangle on
//! its left or above it, so two triangles sharing it draw it once), and a
//! line's are those its round-ended outline, half a pixel wider, reaches.
//! Each row is walked only where the shape can be.
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");

/// A line, a triangle, or a hole (`gpu.Kind`).
pub fn draw(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize) void {
    if (i.kind == gpu.Kind.segment) return segment(out, i, scale, b);
    if (i.kind == gpu.Kind.triangle) return triangle(out, i, scale, b);
    hole(out, i, scale, b);
}

/// Cuts a rounded box out of the frame, as the hole pipeline does: every
/// channel scaled by one minus its coverage.
fn hole(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize) void {
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const r = @min(@abs(i.radius), @min(hw, hh));
    const inv = 1 / scale;
    for (b[1]..b[3]) |y| {
        const py = (@as(f32, @floatFromInt(y)) + 0.5) * inv - (i.rect[1] + hh);
        for (b[0]..b[2]) |x| {
            const px = (@as(f32, @floatFromInt(x)) + 0.5) * inv - (i.rect[0] + hw);
            const sd = raster.cornerSdf(px, py, hw, hh, r);
            const aa = @max(sd[1] * inv, 0.0001) * 0.5;
            const keep = raster.smoothstep(-aa, aa, sd[0]);
            const at = (y * out.width + x) * 4;
            for (out.bytes[at .. at + 4]) |*ch| ch.* = @intFromFloat(@round(@as(f32, @floatFromInt(ch.*)) * keep));
        }
    }
}

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
    const moved = gpu.hasMatrix(i);
    const inv_local = raster.pixelAt(i, inv);
    for (b[1]..b[3]) |y| {
        const sy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const cols: [2]usize = if (moved) .{ b[0], b[2] } else columns(span(&box, sy) orelse continue, scale, b) orelse continue;
        const row = y * out.width * 4;
        for (cols[0]..cols[1]) |x| {
            const sx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const local = raster.unmatrix(i, sx, sy);
            const wx = local[0];
            const wy = local[1];
            const t: f32 = if (len2 > 0) std.math.clamp(((wx - ax) * abx + (wy - ay) * aby) / len2, 0, 1) else 0;
            const ox = wx - (ax + abx * t);
            const oy = wy - (ay + aby * t);
            const d = @sqrt(ox * ox + oy * oy);
            const grad: f32 = if (d > 0) (@abs(ox) + @abs(oy)) / d else 1;
            const aa = @max(grad * inv_local, 0.0001) * 0.5;
            var cover = 1 - raster.smoothstep(hw - aa, hw + aa, d);
            if (cover <= 0) continue;
            if (dashed) {
                // Along the line unclamped: its ends are cut square, as its dashes.
                const along = (if (len > 0) ((wx - ax) * abx + (wy - ay) * aby) / len else 0) + i.border_color[2];
                const m = along - (on + gap) * @floor(along / (on + gap));
                const edge = @min(m, on - m);
                const ug: f32 = if (len > 0) (@abs(abx) + @abs(aby)) / len else 0;
                const ea = @max(ug * inv_local, 0.0001) * 0.5;
                cover *= raster.smoothstep(-ea, ea, edge);
            }
            const a = c[3] * cover * raster.clipCover(i, sx, sy, inv);
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
    const moved = gpu.hasMatrix(i);
    const inv_local = raster.pixelAt(i, inv);
    for (b[1]..b[3]) |y| {
        const sy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const cols: [2]usize = if (moved) .{ b[0], b[2] } else columns(span(&v, sy) orelse continue, scale, b) orelse continue;
        const row = y * out.width * 4;
        pixels: for (cols[0]..cols[1]) |x| {
            const sx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const local = raster.unmatrix(i, sx, sy);
            const wx = local[0];
            const wy = local[1];
            var cover: f32 = 1;
            for (0..3) |k| {
                const p = v[k];
                const f = side * (ex[k] * (wy - p[1]) - ey[k] * (wx - p[0]));
                if (f < 0 or (f == 0 and !top_left[k])) continue :pixels;
                if (smooth & (@as(u32, 1) << @intCast(k)) != 0) {
                    const d = f / elen[k];
                    const aa = @max((@abs(ex[k]) + @abs(ey[k])) / elen[k] * inv_local, 0.0001) * 0.5;
                    cover *= raster.smoothstep(-aa, aa, d);
                }
            }
            const a = c[3] * cover * raster.clipCover(i, sx, sy, inv);
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

/// Y samples of each shadow's Gaussian: 8, as the shader. Hill-climb's
/// `--cheap-shadow` sets 1 (faster, but no longer Metal's pixels).
pub var shadow_samples: u32 = 8;

pub const F4 = @Vector(4, f32);

inline fn erf4(x: F4) F4 {
    const zero: F4 = @splat(0);
    const one: F4 = @splat(1);
    const neg_one: F4 = @splat(-1);
    const c1: F4 = @splat(0.278393);
    const c2: F4 = @splat(0.230389);
    const c3: F4 = @splat(0.078108);
    const s = @select(f32, x < zero, neg_one, one);
    const a = @abs(x);
    var y = one + (c1 + (c2 + c3 * (a * a)) * a) * a;
    y *= y;
    return s - s / (y * y);
}

/// Per-scanline shadow parameters: hoists y-only Gaussian weights, corner
/// curve widths, and flat-body folding out of the inner pixel loop.
pub const ShadowRow = struct {
    hw: f32,
    k: f32,
    w_flat: f32,
    w_total: f32,
    interior_x: f32,
    exterior_x: f32,
    rem_curved: [8]f32,
    rem_w: [8]f32,
    rem_n: u8,

    pub fn init(py: f32, hw: f32, hh: f32, corner: f32, sigma: f32) ?ShadowRow {
        const c = @abs(corner);
        const n = @min(@max(shadow_samples, 1), 8);
        const low = py - hh;
        const high = py + hh;
        const start = std.math.clamp(-3 * sigma, low, high);
        const end = std.math.clamp(3 * sigma, low, high);
        if (end <= start) return null;
        const step = (end - start) / @as(f32, @floatFromInt(n));
        var y = start + step * 0.5;
        var row: ShadowRow = .{
            .hw = hw,
            .k = @sqrt(@as(f32, 0.5)) / sigma,
            .w_flat = 0,
            .w_total = 0,
            .interior_x = 0,
            .exterior_x = 0,
            .rem_curved = undefined,
            .rem_w = undefined,
            .rem_n = 0,
        };
        var min_curved = std.math.inf(f32);
        var max_curved: f32 = 0;
        for (0..n) |_| {
            const wk = gaussian(y, sigma) * step;
            const delta = @min(hh - c - @abs(py - y), 0);
            row.w_total += wk;
            if (delta == 0) {
                row.w_flat += wk;
                min_curved = @min(min_curved, hw);
                max_curved = @max(max_curved, hw);
            } else {
                const curved = hw - c + @sqrt(@max(0, c * c - delta * delta));
                min_curved = @min(min_curved, curved);
                max_curved = @max(max_curved, curved);
                row.rem_curved[row.rem_n] = curved;
                row.rem_w[row.rem_n] = wk;
                row.rem_n += 1;
            }
            y += step;
        }
        row.interior_x = min_curved - 5.5 * sigma;
        row.exterior_x = max_curved + 5.5 * sigma;
        return row;
    }

    inline fn blurX(px: f32, curved: f32, k: f32) f32 {
        return 0.5 * (erf((px + curved) * k) - erf((px - curved) * k));
    }

    inline fn blurX4(px: F4, curved: f32, k: F4) F4 {
        const cv: F4 = @splat(curved);
        return @as(F4, @splat(0.5)) * (erf4((px + cv) * k) - erf4((px - cv) * k));
    }

    pub inline fn evalScalar(row: *const ShadowRow, px: f32) f32 {
        const apx = @abs(px);
        if (apx <= row.interior_x) return row.w_total;
        if (apx >= row.exterior_x) return 0;
        var alpha: f32 = if (row.w_flat > 0) row.w_flat * blurX(px, row.hw, row.k) else 0;
        for (0..row.rem_n) |j| alpha += row.rem_w[j] * blurX(px, row.rem_curved[j], row.k);
        return alpha;
    }

    pub inline fn eval4(row: *const ShadowRow, px: F4) F4 {
        const apx = @abs(px);
        if (@reduce(.And, apx <= @as(F4, @splat(row.interior_x)))) return @splat(row.w_total);
        if (@reduce(.And, apx >= @as(F4, @splat(row.exterior_x)))) return @splat(0);
        const k: F4 = @splat(row.k);
        var alpha: F4 = if (row.w_flat > 0) @as(F4, @splat(row.w_flat)) * blurX4(px, row.hw, k) else @splat(0);
        for (0..row.rem_n) |j| alpha += @as(F4, @splat(row.rem_w[j])) * blurX4(px, row.rem_curved[j], k);
        return alpha;
    }
};

pub fn shadowAlpha(px: f32, py: f32, hw: f32, hh: f32, corner: f32, sigma: f32) f32 {
    const c = @abs(corner);
    const n = @min(@max(shadow_samples, 1), 8);
    const low = py - hh;
    const high = py + hh;
    const start = std.math.clamp(-3 * sigma, low, high);
    const end = std.math.clamp(3 * sigma, low, high);
    const step = (end - start) / @as(f32, @floatFromInt(n));
    var y = start + step * 0.5;
    var alpha: f32 = 0;
    for (0..n) |_| {
        alpha += blurAlongX(px, py - y, sigma, c, hw, hh) * gaussian(y, sigma) * step;
        y += step;
    }
    return alpha;
}

test "scanline ShadowRow matches shadowAlpha within 1e-5" {
    const saved = shadow_samples;
    defer shadow_samples = saved;
    const cases = [_]struct { hw: f32, hh: f32, r: f32, sigma: f32 }{
        .{ .hw = 12, .hh = 12, .r = 6, .sigma = 4 },
        .{ .hw = 100, .hh = 60, .r = 12, .sigma = 16 },
        .{ .hw = 40, .hh = 16, .r = 0, .sigma = 6 },
        .{ .hw = 6, .hh = 8, .r = -6, .sigma = 2.5 },
    };
    for ([_]u32{ 8, 1 }) |samples| {
        shadow_samples = samples;
        for (cases) |tc| {
            var py = -tc.hh - 3.5 * tc.sigma;
            while (py <= tc.hh + 3.5 * tc.sigma) : (py += 3.5) {
                const row_opt = ShadowRow.init(py, tc.hw, tc.hh, tc.r, tc.sigma);
                var px = -tc.hw - 3.5 * tc.sigma;
                while (px <= tc.hw + 3.5 * tc.sigma) : (px += 3.0) {
                    const ref = shadowAlpha(px, py, tc.hw, tc.hh, tc.r, tc.sigma);
                    const s = if (row_opt) |*row| row.evalScalar(px) else 0;
                    try std.testing.expectApproxEqAbs(ref, s, 1e-5);
                    if (row_opt) |*row| {
                        const v4 = row.eval4(.{ px, px + 0.5, px + 1.0, px + 1.5 });
                        inline for (0..4) |lane| {
                            const pxl = px + @as(f32, @floatFromInt(lane)) * 0.5;
                            try std.testing.expectApproxEqAbs(shadowAlpha(pxl, py, tc.hw, tc.hh, tc.r, tc.sigma), v4[lane], 1e-5);
                        }
                    }
                }
            }
        }
    }
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

/// A dashed border's coverage at (`x`, `y`) from the box's centre, as
/// GPUI lays dashes (shader.metal's `dash_cover`); `px` is a pixel's size.
pub fn dashCover(x: f32, y: f32, hw: f32, hh: f32, r: f32, w: f32, px: f32) f32 {
    const pi = std.math.pi;
    const dv = 1 / (3 * w);
    const sx = (2 * hw - 2 * r) * dv;
    const sy = (2 * hh - 2 * r) * dv;
    const cq = r * pi * 0.5 * dv;
    const qx = @abs(x) - (hw - r);
    const qy = @abs(y) - (hh - r);
    const t: f32 = if (r > 0 and qx > 0 and qy > 0) blk: {
        const vx = x - std.math.sign(x) * (hw - r);
        const vy = y - std.math.sign(y) * (hh - r);
        const ang = std.math.atan2(vy, vx);
        break :blk if (x >= 0 and y < 0)
            sx + (ang + pi * 0.5) * r * dv
        else if (x >= 0)
            sx + cq + sy + ang * r * dv
        else if (y >= 0)
            2 * sx + 2 * cq + sy + (ang - pi * 0.5) * r * dv
        else
            2 * sx + 3 * cq + 2 * sy + (ang + pi) * r * dv;
    } else if ((hh - @abs(y)) < (hw - @abs(x)))
        (if (y < 0) (x + hw - r) * dv else sx + 2 * cq + sy + (hw - r - x) * dv)
    else
        (if (x > 0) sx + cq + (y + hh - r) * dv else 2 * sx + 3 * cq + sy + (hh - r - y) * dv);
    const max_t = 2 * (sx + sy) + 4 * cq;
    if (max_t < 1) return 1;
    const period = max_t / @floor(max_t);
    const len: f32 = 2.0 / 3.0;
    const u = t + period * 0.5 - len * 0.5;
    const centered = u - period * @floor(u / period) - period * 0.5;
    const sd = (@abs(centered) - len * 0.5) / dv;
    return std.math.clamp(0.5 - sd / px, 0, 1);
}
