//! Liquid Glass, the material of macOS 26 and later, drawn by nanoui's own
//! renderers as mygo's glass plugin draws it (and as both measured it from
//! AppKit's NSGlassEffectView): what was painted under a pane shows through
//! it, blurred, bent near its edges as through the rim of a lens, mapped
//! to the glass's lightness, tinted, and lit along a hairline rim.
//!
//! Each pane reads what is under it (its backdrop): the frame's pixels
//! around it, averaged over squares of `down` pixels, then blurred by a
//! Gaussian along rows and along columns, each step kept in 8 bits as a
//! texture keeps it. The shader (`glass.metal`) and the CPU (`drawPane`)
//! compute the same steps, so the CPU renderer matches Metal's.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");

/// A pane's material, in points (but the tone, which is unitless).
pub const Material = struct {
    /// How far from the edge the surface curves, and how far at most it
    /// bends what shows through toward the middle.
    bezel: f32,
    refraction: f32,
    /// The rim is lit (by `rim`) within about `rim_width` of the edge.
    rim_width: f32,
    /// The standard deviation of the blur of what shows through.
    blur: f32,
    /// Black and white show at `low` and `high`, along a curve bent by
    /// `curve`; colors keep `saturation` times their distance from gray.
    low: f32,
    high: f32,
    curve: f32,
    saturation: f32,
    tint: [4]f32 = .{ 0, 0, 0, 0 },
};

/// The material of a pane `w` × `h` points, as macOS 27's: the regular
/// glass maps black to 54% and white to 100% in light mode, 15% and 51% in
/// dark mode, the clear one adds an eighth; larger panes blur more, up to
/// 10 points; the bezel curves the last 36 points, at most half the pane,
/// and bends what shows through by up to 1.6 times that; the rim is a
/// pixel wide, lit from above and below.
pub fn material(g: types.Glass, w: f32, h: f32, dark: bool, scale: f32) Material {
    const m = @min(w, h);
    const bezel = @min(36, m / 2);
    var mat: Material = .{
        .bezel = bezel,
        .refraction = 1.6 * bezel,
        .rim_width = 1 / scale,
        .blur = std.math.clamp(m * 0.035, 1, 10),
        .low = 0.541,
        .high = 1,
        .curve = 1.2,
        .saturation = 1,
    };
    if (g.style == .frost) {
        mat = .{ .bezel = 0, .refraction = 0, .rim_width = 0, .blur = @max(g.blur, 0.5), .low = 0, .high = 1, .curve = 1, .saturation = 1 };
    } else if (g.style == .clear) {
        mat.blur = 1;
        mat.low = 0.125;
        mat.high = 1.082;
        mat.curve = 1;
    } else if (dark) {
        mat.low = 0.15;
        mat.high = 0.51;
        mat.curve = 2;
        mat.saturation = 2.2;
    }
    // An opaque tint lets a little of the glass show, as AppKit's does.
    if (g.tint.a > 0) mat.tint = .{ g.tint.r, g.tint.g, g.tint.b, g.tint.a * 0.88 };
    return mat;
}

/// How much the rim is lit, at most.
pub const rim = 0.35;

/// The instance that draws a pane (`gpu.Kind.glass`), faded by `opacity`.
pub fn instance(m: Material, rect: [4]f32, radius: f32, clip: [4]f32, opacity: f32) gpu.Instance {
    return .{
        .rect = rect,
        .color = m.tint,
        .uv = .{ m.bezel, m.refraction, opacity, m.rim_width },
        .border_color = .{ m.low, m.high, m.curve, m.saturation },
        .border_width = m.blur,
        .radius = radius,
        .kind = gpu.Kind.glass,
        .clip = clip,
    };
}

/// What a pane reads of the frame: the pixels of `area` (x0, y0, x1, y1),
/// averaged over squares of `down` pixels a side into `w` × `h` texels,
/// which a Gaussian of standard deviation `sigma` texels blurs, out to
/// `radius` texels each way.
pub const Backdrop = struct {
    area: [4]i32,
    down: i32,
    sigma: f32,
    radius: i32,
    w: i32,
    h: i32,
};

/// The backdrop of a pane at `rect` (points) blurred by `blur` points, in
/// a frame `fw` × `fh` pixels: what the blur reaches around it. Large
/// blurs are computed at a fraction of the size, as browsers do: a power
/// of two up to 8 that leaves the blur at least 2 texels, less the
/// variance the averaging adds (down²/12). Null when none of it shows.
pub fn backdropOf(rect: [4]f32, blur_pt: f32, scale: f32, fw: usize, fh: usize) ?Backdrop {
    const blur = @max(blur_pt * scale, 0);
    var down: i32 = 1;
    while (down < 8 and blur / @as(f32, @floatFromInt(2 * down)) >= 2) down *= 2;
    const df: f32 = @floatFromInt(down);
    const sigma: f32 = if (blur == 0) 0 else @sqrt(@max(blur * blur - df * df / 12, 0)) / df;
    const radius: i32 = @intFromFloat(@ceil(3 * sigma));
    const reach: f32 = @floatFromInt(radius * down + down);
    const x0 = @max(@floor(rect[0] * scale - reach), 0);
    const y0 = @max(@floor(rect[1] * scale - reach), 0);
    const x1 = @min(@ceil((rect[0] + rect[2]) * scale + reach), @as(f32, @floatFromInt(fw)));
    const y1 = @min(@ceil((rect[1] + rect[3]) * scale + reach), @as(f32, @floatFromInt(fh)));
    if (x1 <= x0 or y1 <= y0) return null;
    const area: [4]i32 = .{ @intFromFloat(x0), @intFromFloat(y0), @intFromFloat(x1), @intFromFloat(y1) };
    return .{
        .area = area,
        .down = down,
        .sigma = sigma,
        .radius = radius,
        .w = @divFloor(area[2] - area[0] + down - 1, down),
        .h = @divFloor(area[3] - area[1] + down - 1, down),
    };
}

/// How far, as a fraction of the refraction, the glass bends what shows
/// through it `t` pixels inside its edge: the surface's height is Apple's
/// squircle profile, ⁴√(1-(1-x)⁴) for x = t/bezel, and light coming
/// straight down bends entering glass of index 1.5 (Snell's law), by the
/// tangent of the angle it turns, √5/2 at most, where the surface stands up.
pub fn lens(t: f32, bezel: f32) f32 {
    if (bezel <= 0 or t >= bezel) return 0;
    const u = 1 - @max(t, 0) / bezel;
    const v = 1 - u * u * u * u;
    const a = @sqrt(v * @sqrt(v));
    const b = u * u * u;
    const n = @sqrt(a * a + b * b);
    const s = b / n;
    const c = a / n;
    const st = s / 1.5;
    const ct = @sqrt(1 - st * st);
    return (s * ct - c * st) / (c * ct + s * st) / 1.1180340;
}

/// The direction of the edge's normal at (`qx`, `qy`) from the middle of a
/// box of half size `hx`, `hy`, smoothed: as of the box with corners half
/// again as round, so it turns gradually around a corner.
pub fn normal(qx: f32, qy: f32, hx: f32, hy: f32, radius: f32) [2]f32 {
    const r = @min(radius * 1.5, @min(hx, hy));
    const ax = @abs(qx) - (hx - r);
    const ay = @abs(qy) - (hy - r);
    if (ax > 0 or ay > 0) {
        const mx = @max(ax, 0);
        const my = @max(ay, 0);
        const n = @sqrt(mx * mx + my * my);
        return .{ sign(qx) * mx / n, sign(qy) * my / n };
    }
    return if (ax > ay) .{ sign(qx), 0 } else .{ 0, sign(qy) };
}

fn sign(v: f32) f32 {
    return if (v > 0) 1 else if (v < 0) -1 else 0;
}

/// The color behind the glass mapped to the glass's own, by its lightness.
pub fn tone(c: [3]f32, low: f32, high: f32, curve: f32, saturation: f32) [3]f32 {
    const l = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    const t = low + (high - low) * (1 - std.math.pow(f32, @max(1 - l, 0), curve));
    const k = (high - low) * saturation;
    var out: [3]f32 = undefined;
    for (0..3) |i| out[i] = std.math.clamp(t + (c[i] - l) * k, 0, 1);
    return out;
}

/// A backdrop as the CPU computes it: `w` × `h` texels of RGB, each a byte
/// over 255, as the GPU's texture holds them.
pub const Image = struct {
    b: Backdrop,
    pix: []f32,

    /// The backdrop at pixel (x, y) of the frame, bilinear from its texels
    /// and clamped to its edges, as the shader's `glass_sample`.
    pub fn sample(im: Image, x: f32, y: f32) [3]f32 {
        const k: f32 = @floatFromInt(im.b.down);
        const u = (x - @as(f32, @floatFromInt(im.b.area[0]))) / k - 0.5;
        const v = (y - @as(f32, @floatFromInt(im.b.area[1]))) / k - 0.5;
        const fu = @floor(u);
        const fv = @floor(v);
        const tx = u - fu;
        const ty = v - fv;
        const iu: i32 = @intFromFloat(fu);
        const iv: i32 = @intFromFloat(fv);
        var c: [3]f32 = undefined;
        for (0..3) |ch| {
            const top = im.at(iu, iv, ch) * (1 - tx) + im.at(iu + 1, iv, ch) * tx;
            const bot = im.at(iu, iv + 1, ch) * (1 - tx) + im.at(iu + 1, iv + 1, ch) * tx;
            c[ch] = top * (1 - ty) + bot * ty;
        }
        return c;
    }

    fn at(im: Image, x: i32, y: i32, ch: usize) f32 {
        const cx: usize = @intCast(std.math.clamp(x, 0, im.b.w - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, im.b.h - 1));
        return im.pix[(cy * @as(usize, @intCast(im.b.w)) + cx) * 3 + ch];
    }
};

fn quantize(v: f32) f32 {
    return @round(std.math.clamp(v, 0, 1) * 255) / 255;
}

/// The backdrop of `b` from the frame's pixels (BGRA, premultiplied):
/// averaged, then blurred along rows and columns, each step in 8 bits.
pub fn readBackdrop(gpa: std.mem.Allocator, out: gpu.Pixels, b: Backdrop) !Image {
    const w: usize = @intCast(b.w);
    const h: usize = @intCast(b.h);
    const pix = try gpa.alloc(f32, w * h * 3);
    errdefer gpa.free(pix);
    for (0..h) |v| for (0..w) |u| {
        const x0: usize = @intCast(b.area[0] + @as(i32, @intCast(u)) * b.down);
        const y0: usize = @intCast(b.area[1] + @as(i32, @intCast(v)) * b.down);
        const x1: usize = @min(x0 + @as(usize, @intCast(b.down)), @as(usize, @intCast(b.area[2])));
        const y1: usize = @min(y0 + @as(usize, @intCast(b.down)), @as(usize, @intCast(b.area[3])));
        var sum: [3]f32 = .{ 0, 0, 0 };
        for (y0..y1) |y| for (x0..x1) |x| {
            const p = out.bytes[(y * out.width + x) * 4 ..][0..4];
            sum[0] += @as(f32, @floatFromInt(p[2])) / 255;
            sum[1] += @as(f32, @floatFromInt(p[1])) / 255;
            sum[2] += @as(f32, @floatFromInt(p[0])) / 255;
        };
        const n: f32 = @floatFromInt((x1 - x0) * (y1 - y0));
        for (0..3) |ch| pix[(v * w + u) * 3 + ch] = quantize(sum[ch] / n);
    };
    if (b.sigma > 0) {
        const tmp = try gpa.alloc(f32, pix.len);
        defer gpa.free(tmp);
        blurPass(pix, tmp, w, h, b, .{ 1, 0 });
        blurPass(tmp, pix, w, h, b, .{ 0, 1 });
    }
    return .{ .b = b, .pix = pix };
}

/// One direction of the Gaussian, as the shader's `glass_blur`.
fn blurPass(src: []const f32, dst: []f32, w: usize, h: usize, b: Backdrop, dir: [2]i32) void {
    for (0..h) |y| for (0..w) |x| {
        var sum: [3]f32 = .{ 0, 0, 0 };
        var wsum: f32 = 0;
        var k: i32 = -b.radius;
        while (k <= b.radius) : (k += 1) {
            const sx: usize = @intCast(std.math.clamp(@as(i32, @intCast(x)) + dir[0] * k, 0, @as(i32, @intCast(w)) - 1));
            const sy: usize = @intCast(std.math.clamp(@as(i32, @intCast(y)) + dir[1] * k, 0, @as(i32, @intCast(h)) - 1));
            const kf: f32 = @floatFromInt(k);
            const wt = @exp(-(kf * kf) / (2 * b.sigma * b.sigma));
            for (0..3) |ch| sum[ch] += src[(sy * w + sx) * 3 + ch] * wt;
            wsum += wt;
        }
        for (0..3) |ch| dst[(y * w + x) * 3 + ch] = quantize(sum[ch] / wsum);
    };
}

/// The glass's color at pixel center (`px`, `py`) of the frame, opaque,
/// as the shader's `fs_glass` before coverage.
pub fn color(i: *const gpu.Instance, im: Image, px: f32, py: f32, scale: f32) [3]f32 {
    const hx = i.rect[2] * 0.5 * scale;
    const hy = i.rect[3] * 0.5 * scale;
    const qx = px - i.rect[0] * scale - hx;
    const qy = py - i.rect[1] * scale - hy;
    const rr = @min(i.radius * scale, @min(hx, hy));
    const t = @max(-roundedBox(qx, qy, hx, hy, rr), 0);
    const bezel = i.uv[0] * scale;
    const refraction = i.uv[1] * scale;
    const rim_width = i.uv[3] * scale;
    var n: [2]f32 = .{ 0, 0 };
    if (t < bezel or t < 3 * rim_width) n = normal(qx, qy, hx, hy, rr);
    var sx = px;
    var sy = py;
    if (t < bezel) {
        const d = refraction * lens(t, bezel);
        sx -= n[0] * d;
        sy -= n[1] * d;
    }
    const tc = i.border_color;
    var c = tone(im.sample(sx, sy), tc[0], tc[1], tc[2], tc[3]);
    for (0..3) |ch| c[ch] += (i.color[ch] - c[ch]) * i.color[3];
    if (rim > 0 and t < 3 * rim_width) {
        const r = t / rim_width;
        const a = rim * @exp(-r * r);
        // Light from above and below: the more the edge faces it, the lighter.
        const l = @abs(n[1]);
        for (0..3) |ch| c[ch] += (l - c[ch]) * a;
    }
    return c;
}

fn roundedBox(px: f32, py: f32, hw: f32, hh: f32, r: f32) f32 {
    const qx = @abs(px) - hw + r;
    const qy = @abs(py) - hh + r;
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    return @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0) - r;
}

test "the lens bends most at the rim and not at all inside the bezel" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), lens(0, 36), 1e-4);
    try std.testing.expectEqual(@as(f32, 0), lens(36, 36));
    try std.testing.expectEqual(@as(f32, 0), lens(5, 0));
    try std.testing.expect(lens(9, 36) > lens(18, 36) and lens(18, 36) > lens(27, 36));
    // The normal points out of the nearest side, and around a corner.
    try std.testing.expectEqual([2]f32{ 1, 0 }, normal(49, 0, 50, 20, 10));
    try std.testing.expectEqual([2]f32{ 0, -1 }, normal(0, -19, 50, 20, 10));
    const corner = normal(49, 19, 50, 20, 10);
    try std.testing.expect(corner[0] > 0 and corner[1] > 0);
}

test "the material: light, dark, clear, tinted; the backdrop's plan" {
    const light = material(.{}, 200, 40, false, 2);
    try std.testing.expectEqual(@as(f32, 20), light.bezel);
    try std.testing.expectEqual(@as(f32, 0.541), light.low);
    try std.testing.expectApproxEqAbs(@as(f32, 1.4), light.blur, 1e-5);
    const dark = material(.{}, 600, 600, true, 2);
    try std.testing.expectEqual(@as(f32, 36), dark.bezel);
    try std.testing.expectEqual(@as(f32, 10), dark.blur);
    try std.testing.expectEqual(@as(f32, 0.15), dark.low);
    const clear = material(.{ .style = .clear, .tint = .{ .r = 1, .a = 1 } }, 100, 100, false, 1);
    try std.testing.expectEqual(@as(f32, 1), clear.blur);
    try std.testing.expectApproxEqAbs(@as(f32, 0.88), clear.tint[3], 1e-6);
    // White stays white in light mode; black lifts to `low`.
    try std.testing.expectApproxEqAbs(@as(f32, 1), tone(.{ 1, 1, 1 }, 0.541, 1, 1.2, 1)[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.541), tone(.{ 0, 0, 0 }, 0.541, 1, 1.2, 1)[0], 1e-6);

    // 20 pixels of blur: averaged by 8, leaving a sigma of about 2.5 texels.
    const b = backdropOf(.{ 10, 10, 100, 40 }, 10, 2, 400, 200).?;
    try std.testing.expectEqual(@as(i32, 8), b.down);
    try std.testing.expectApproxEqAbs(@as(f32, 2.4833), b.sigma, 1e-3);
    try std.testing.expectEqual(@as(i32, 8), b.radius);
    try std.testing.expectEqual([4]i32{ 0, 0, 292, 172 }, b.area);
    try std.testing.expectEqual(@as(i32, 37), b.w);
    try std.testing.expect(backdropOf(.{ 500, 500, 10, 10 }, 1, 1, 100, 100) == null);
}

test "on a flat backdrop, the rim is lit above and below and shaded at the sides" {
    var pix: [4 * 4 * 3]f32 = @splat(0.5);
    const im: Image = .{ .b = .{ .area = .{ 0, 0, 400, 400 }, .down = 100, .sigma = 0, .radius = 0, .w = 4, .h = 4 }, .pix = &pix };
    const i = instance(material(.{}, 200, 100, false, 1), .{ 0, 0, 200, 100 }, 20, .{ -1e6, -1e6, 1e6, 1e6 }, 1);
    const mid = color(&i, im, 100, 50, 1)[0];
    // Gray at half lightness shows at about 80% on light glass.
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), mid, 0.01);
    try std.testing.expect(color(&i, im, 100, 0.5, 1)[0] > mid);
    try std.testing.expect(color(&i, im, 100, 99.5, 1)[0] > mid);
    try std.testing.expect(color(&i, im, 0.5, 50, 1)[0] < mid);
}
