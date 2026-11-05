//! Boxes nanoui's one radius and one border can't draw, as triangles on a canvas:
//! corners that differ or aren't circles, and borders whose sides meet at a miter
//! with their own widths, colors and styles (so CSS's border triangles and
//! chevrons are right). Plain boxes never come here, or stay on nanoui's quads.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const css = @import("../css/style.zig");
const box = @import("../layout/box.zig");
const display = @import("display.zig");
const corners = @import("corners.zig");
const replay = @import("replay.zig");
const Rect = box.Rect;
const Corners = corners.Corners;
const P = ui.Point;

pub fn newCanvas(c: *ui.Context, placed: ui.Style) *ui.Canvas {
    const cv = c.alloc().create(ui.Canvas) catch @panic("nanobrowser: out of memory");
    cv.* = .{ .c = c };
    _ = c.leaf(placed, .{ .canvas = cv }, null);
    return cv;
}

/// A fill with any corners: a fan from its middle, so no seams inside.
pub fn rounded(c: *ui.Context, color: css.Color, shape: Corners, placed: ui.Style, r: Rect) void {
    if (color.a <= 0) return;
    const cv = newCanvas(c, placed);
    const pts = corners.outline(c.alloc(), 0, 0, r.w, r.h, shape) catch return;
    const k = replay.color(color);
    const mid: P = .{ .x = r.w / 2, .y = r.h / 2 };
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        if (p.x == q.x and p.y == q.y) continue;
        // Its edge is the triangle's second.
        cv.triangle(mid, .{ .x = p.x, .y = p.y }, .{ .x = q.x, .y = q.y }, k, 2);
    }
}

/// A fill in the shape of a `clip-path` polygon.
pub fn polygon(c: *ui.Context, color: css.Color, points: []const [2]f32, placed: ui.Style) void {
    if (color.a <= 0 or points.len < 3) return;
    const cv = newCanvas(c, placed);
    const pts = c.alloc().alloc(P, points.len) catch return;
    for (points, pts) |p, *o| o.* = .{ .x = p[0], .y = p[1] };
    cv.fill(pts, replay.color(color));
}

/// One corner's place on a curve some way into the border.
const Geo = struct {
    w: f32,
    h: f32,
    widths: box.Edges,
    shape: Corners,

    /// The widths of the sides that come in and go out of corner `k`, clockwise.
    fn around(g: Geo, k: usize) [2]f32 {
        const e = g.widths;
        return switch (k) {
            0 => .{ e.left, e.top },
            1 => .{ e.top, e.right },
            2 => .{ e.right, e.bottom },
            else => .{ e.bottom, e.left },
        };
    }

    /// Corner `k`'s radii across those two sides.
    fn radii(g: Geo, k: usize) [2]f32 {
        return if (k % 2 == 0) .{ g.shape.rx[k], g.shape.ry[k] } else .{ g.shape.ry[k], g.shape.rx[k] };
    }

    /// A point `a` in from the side coming in, `b` from the side going out.
    fn place(g: Geo, k: usize, a: f32, b: f32) P {
        return switch (k) {
            0 => .{ .x = a, .y = b },
            1 => .{ .x = g.w - b, .y = a },
            2 => .{ .x = g.w - a, .y = g.h - b },
            else => .{ .x = b, .y = g.h - a },
        };
    }

    /// Corner `k`'s curve at `frac` of the way through the border, and where on
    /// it (0 to 1) the line from the outer corner to the inner one crosses.
    fn split(g: Geo, k: usize, frac: f32) Curve {
        const w = g.around(k);
        const rad = g.radii(k);
        const fa = w[0] * frac;
        const fb = w[1] * frac;
        const ra = @max(0, rad[0] - fa);
        const rb = @max(0, rad[1] - fb);
        var q: f32 = 0.5;
        if (ra > 0 and rb > 0 and (w[0] > 0 or w[1] > 0)) {
            const ca = fa + ra;
            const cb = fb + rb;
            const aa = w[0] / ra;
            const bb = w[1] / rb;
            const ka = ca / ra;
            const kb = cb / rb;
            const qa = aa * aa + bb * bb;
            const qb = -2 * (aa * ka + bb * kb);
            const qc = ka * ka + kb * kb - 1;
            const disc = qb * qb - 4 * qa * qc;
            if (disc >= 0 and qa > 0) {
                const s = (-qb - @sqrt(disc)) / (2 * qa);
                q = std.math.atan2((cb - s * w[1]) / rb, (ca - s * w[0]) / ra) / (std.math.pi / 2.0);
            }
        }
        return .{ .fa = fa, .fb = fb, .ra = ra, .rb = rb, .split = std.math.clamp(q, 0, 1) };
    }

    fn at(g: Geo, k: usize, cu: Curve, q: f32) P {
        if (cu.ra <= 0 or cu.rb <= 0) return g.place(k, cu.fa, cu.fb);
        const t = q * std.math.pi / 2.0;
        return g.place(k, cu.fa + cu.ra - cu.ra * @cos(t), cu.fb + cu.rb - cu.rb * @sin(t));
    }
};

const Curve = struct { fa: f32, fb: f32, ra: f32, rb: f32, split: f32 };

/// Side `i`'s line at `frac` into the border: half of the corner before it,
/// and half of the one after. The same number of points at any `frac`.
fn sideLine(a: std.mem.Allocator, g: Geo, i: usize, frac: f32) ![]P {
    const next = (i + 1) % 4;
    var out: std.ArrayList(P) = .empty;
    const c0 = g.split(i, frac);
    const r0 = g.radii(i);
    const n0 = corners.pieces(r0[0], r0[1]);
    if (n0 == 0) try out.append(a, g.place(i, c0.fa, c0.fb));
    for (0..n0 + @as(usize, if (n0 > 0) 1 else 0)) |k| {
        const f = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(@max(n0, 1)));
        try out.append(a, g.at(i, c0, c0.split + (1 - c0.split) * f));
    }
    const c1 = g.split(next, frac);
    const r1 = g.radii(next);
    const n1 = corners.pieces(r1[0], r1[1]);
    if (n1 == 0) try out.append(a, g.place(next, c1.fa, c1.fb));
    for (0..n1 + @as(usize, if (n1 > 0) 1 else 0)) |k| {
        const f = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(@max(n1, 1)));
        try out.append(a, g.at(next, c1, c1.split * f));
    }
    return out.items;
}

fn differs(p: P, q: P) bool {
    return @abs(p.x - q.x) > 1e-3 or @abs(p.y - q.y) > 1e-3;
}

/// The band of side `i` from `f0` to `f1` of the way through the border. Its
/// ends are smoothed only where a side of another color meets it.
fn band(cv: *ui.Canvas, a: std.mem.Allocator, g: Geo, i: usize, f0: f32, f1: f32, k: ui.Color, smooth_start: bool, smooth_end: bool) void {
    if (k.a <= 0) return;
    const o = sideLine(a, g, i, f0) catch return;
    const n = sideLine(a, g, i, f1) catch return;
    const last = @min(o.len, n.len);
    if (last < 2) return;
    for (0..last - 1) |j| {
        const end_flag: u3 = if (j == last - 2 and smooth_end) 2 else 0;
        const start_flag: u3 = if (j == 0 and smooth_start) 4 else 0;
        if (differs(o[j], o[j + 1])) cv.triangle(o[j], o[j + 1], n[j + 1], k, 1 | end_flag);
        if (differs(n[j], n[j + 1])) cv.triangle(o[j], n[j + 1], n[j], k, 2 | start_flag);
    }
}

fn side(b: display.Border, i: usize) css.Border {
    return switch (i) {
        0 => b.top,
        1 => b.right,
        2 => b.bottom,
        else => b.left,
    };
}

fn widthOf(e: box.Edges, i: usize) f32 {
    return switch (i) {
        0 => e.top,
        1 => e.right,
        2 => e.bottom,
        else => e.left,
    };
}

fn same(a: css.Color, b: css.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

/// Blink's `Color::Dark`, and white's fixed answer.
fn dark(c: css.Color) css.Color {
    if (c.r == 1 and c.g == 1 and c.b == 1) return .{ .r = 171.0 / 255.0, .g = 171.0 / 255.0, .b = 171.0 / 255.0, .a = c.a };
    const v = @max(c.r, @max(c.g, c.b));
    if (v <= 0) return c;
    const m = @max(0, (v - 0.33) / v);
    return .{ .r = c.r * m, .g = c.g * m, .b = c.b * m, .a = c.a };
}

/// Blink's `Color::Light`.
fn light(c: css.Color) css.Color {
    const v = @max(c.r, @max(c.g, c.b));
    if (v <= 0) return .{ .r = 84.0 / 255.0, .g = 84.0 / 255.0, .b = 84.0 / 255.0, .a = c.a };
    const m = @min(1, v + 0.33) / v;
    return .{ .r = c.r * m, .g = c.g * m, .b = c.b * m, .a = c.a };
}

fn luminance(c: css.Color) f32 {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

/// The two tones a 3D style gives side `i`: its edge is dark or plain, the plain
/// one lightened when dark wouldn't stand out from it.
fn tone(s: css.BorderStyle, i: usize, c: css.Color) css.Color {
    const top_left = i == 0 or i == 3;
    const darken = top_left == (s == .inset or s == .groove);
    const d = dark(c);
    if (darken) return d;
    const hi = @max(luminance(c), luminance(d)) + 0.05;
    const lo = @min(luminance(c), luminance(d)) + 0.05;
    return if (hi / lo < 1.75) light(c) else c;
}

/// Dashes that end where they started: the gap nearest asked for that fits.
fn fittedGap(length: f32, on: f32, off: f32) f32 {
    const few = @floor((length + off) / (on + off));
    const many = few + 1;
    const few_gap = if (few > 1) (length - few * on) / (few - 1) else off;
    const many_gap = if (many > 1) (length - many * on) / (many - 1) else off;
    return if (many_gap <= 0 or @abs(few_gap - off) < @abs(many_gap - off)) few_gap else many_gap;
}

/// A dashed or dotted side, along the middle of its band.
fn dashes(cv: *ui.Canvas, a: std.mem.Allocator, g: Geo, i: usize, w: f32, style: css.BorderStyle, k: ui.Color) void {
    if (k.a <= 0 or w <= 0) return;
    const line = sideLine(a, g, i, 0.5) catch return;
    var length: f32 = 0;
    for (line[0 .. line.len - 1], line[1..]) |p, q| length += @sqrt((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y));
    if (length <= 0) return;
    if (style == .dotted and w >= 2) {
        // Round dots, as Chromium draws them when there's room.
        const gap = @max(fittedGap(length, w, w), 0);
        const step = w + gap;
        var pos: f32 = w / 2;
        var walked: f32 = 0;
        for (line[0 .. line.len - 1], line[1..]) |p, q| {
            const len = @sqrt((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y));
            while (len > 0 and pos <= walked + len + 0.01) : (pos += step) {
                const t = (pos - walked) / len;
                cv.circle(.{ .x = p.x + (q.x - p.x) * t, .y = p.y + (q.y - p.y) * t }, w / 2, k);
            }
            walked += len;
        }
        return;
    }
    const on: f32 = if (style == .dotted) w else if (w >= 3) 2 * w else 3 * w;
    const off: f32 = if (style == .dotted) w else if (w >= 3) w else 2 * w;
    const gap = @max(fittedGap(length, on, off), 0.1);
    cv.polyline(line, .{ .width = w, .color = k, .dash = .{ on, gap } });
}

/// Whether nanoui's bordered quad draws it, or bars where nothing meets.
fn draws(c: *ui.Context, b: display.Border, placed: ui.Style, r: Rect) bool {
    const w = b.widths;
    const shape = if (b.corners) |p| p.* else Corners{};
    const allowed = struct {
        fn f(s: css.BorderStyle) bool {
            return s == .solid or s == .none or s == .hidden;
        }
    }.f;
    const plain = allowed(b.top.style) and allowed(b.right.style) and allowed(b.bottom.style) and allowed(b.left.style);
    const even = w.top == w.right and w.top == w.bottom and w.top == w.left;
    const one_color = same(b.top.color, b.right.color) and same(b.top.color, b.bottom.color) and same(b.top.color, b.left.color);
    if (even and one_color and plain and b.top.color.a > 0) if (shape.uniform()) |radius| {
        var s = placed;
        s.border = replay.color(b.top.color);
        s.border_width = w.top;
        s.radius = radius;
        s.corner_circular = true;
        _ = c.leaf(s, .none, null);
        return true;
    };
    if (b.corners != null or !plain) return false;
    // Square and solid: bars, if no two sides of different colors meet.
    const meets = struct {
        fn f(x: f32, kx: css.Color, y: f32, ky: css.Color) bool {
            return x > 0 and y > 0 and !same(kx, ky);
        }
    }.f;
    if (meets(w.top, b.top.color, w.left, b.left.color) or meets(w.top, b.top.color, w.right, b.right.color) or
        meets(w.bottom, b.bottom.color, w.left, b.left.color) or meets(w.bottom, b.bottom.color, w.right, b.right.color)) return false;
    const x = placed.offset.x;
    const y = placed.offset.y;
    const bar = struct {
        fn add(cc: *ui.Context, p: ui.Style, k: css.Color, bx: f32, by: f32, bw: f32, bh: f32) void {
            if (k.a <= 0 or bw <= 0 or bh <= 0) return;
            _ = cc.leaf(.{ .absolute = true, .offset = .{ .x = bx, .y = by }, .width = .{ .px = bw }, .height = .{ .px = bh }, .background = replay.color(k), .opacity = p.opacity }, .none, null);
        }
    }.add;
    bar(c, placed, b.top.color, x, y, r.w, w.top);
    bar(c, placed, b.bottom.color, x, y + r.h - w.bottom, r.w, w.bottom);
    bar(c, placed, b.left.color, x, y + w.top, w.left, r.h - w.top - w.bottom);
    bar(c, placed, b.right.color, x + r.w - w.right, y + w.top, w.right, r.h - w.top - w.bottom);
    return true;
}

pub fn border(c: *ui.Context, b: display.Border, placed: ui.Style, r: Rect) void {
    if (draws(c, b, placed, r)) return;
    const cv = newCanvas(c, placed);
    const a = c.alloc();
    const g: Geo = .{ .w = r.w, .h = r.h, .widths = b.widths, .shape = if (b.corners) |p| p.* else Corners{} };
    for (0..4) |i| {
        const s = side(b, i);
        const w = widthOf(b.widths, i);
        if (w <= 0 or s.style == .none or s.style == .hidden) continue;
        const before = side(b, (i + 3) % 4);
        const after = side(b, (i + 1) % 4);
        const smooth_start = widthOf(b.widths, (i + 3) % 4) <= 0 or !same(before.color, s.color) or before.style != s.style;
        const smooth_end = widthOf(b.widths, (i + 1) % 4) <= 0 or !same(after.color, s.color) or after.style != s.style;
        const k = replay.color(s.color);
        switch (s.style) {
            .dashed, .dotted => dashes(cv, a, g, i, w, s.style, k),
            .double => {
                if (w < 3) {
                    band(cv, a, g, i, 0, 1, k, smooth_start, smooth_end);
                } else {
                    band(cv, a, g, i, 0, 1.0 / 3.0, k, smooth_start, smooth_end);
                    band(cv, a, g, i, 2.0 / 3.0, 1, k, smooth_start, smooth_end);
                }
            },
            .groove, .ridge => {
                const outer_style: css.BorderStyle = if (s.style == .groove) .inset else .outset;
                const inner_style: css.BorderStyle = if (s.style == .groove) .outset else .inset;
                band(cv, a, g, i, 0, 0.5, replay.color(tone(outer_style, i, s.color)), true, true);
                band(cv, a, g, i, 0.5, 1, replay.color(tone(inner_style, i, s.color)), true, true);
            },
            .inset, .outset => band(cv, a, g, i, 0, 1, replay.color(tone(s.style, i, s.color)), true, true),
            else => band(cv, a, g, i, 0, 1, k, smooth_start, smooth_end),
        }
    }
}

/// How much of an inset shadow shows `d` beyond its hole's edge, for a blur of
/// standard deviation `sigma`.
fn insetCover(d: f32, sigma: f32) f32 {
    const t = d / @max(sigma * std.math.sqrt2, 0.001);
    // The Gaussian's integral, by Abramowitz and Stegun's 7.1.27 fit.
    const a = @abs(t);
    const x = 1 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    const e = 1 - 1 / (x * x * x * x);
    return 0.5 + 0.5 * (if (t < 0) -e else e);
}

/// An inset shadow: within the padding box, everything outside its hole, drawn
/// as rings; a blur is rings of a step in the Gaussian's fall, no finer than a
/// pixel, so it is near without a picture of it.
pub fn insetShadow(c: *ui.Context, s: display.Kind.InsetShadow, placed: ui.Style, r: Rect) void {
    const sh = s.shadow;
    if (sh.color.a <= 0) return;
    var clip = placed;
    clip.clip = true;
    clip.radius = s.corners.largest();
    clip.clip_corners = s.corners.mask();
    _ = c.open(clip, null);
    defer c.end();
    const base = s.corners.largest();
    // The hole, in the box's terms.
    const hx = sh.x + sh.spread;
    const hy = sh.y + sh.spread;
    const hw = @max(0, r.w - 2 * sh.spread);
    const hh = @max(0, r.h - 2 * sh.spread);
    const hr = @max(0, base - sh.spread);
    const far = @max(r.w, r.h) + @abs(sh.x) + @abs(sh.y) + @abs(sh.spread) + 8;
    const ring = struct {
        fn draw(cc: *ui.Context, x: f32, y: f32, w: f32, h: f32, radius: f32, width: f32, k: ui.Color) void {
            if (k.a <= 0.002 or w <= 0 or h <= 0) return;
            _ = cc.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = h }, .radius = radius, .corner_circular = true, .border = k, .border_width = width }, .none, null);
        }
    }.draw;
    const k = replay.color(sh.color);
    const sigma = sh.blur / 2;
    if (sigma < 0.3) {
        ring(c, hx - far, hy - far, hw + 2 * far, hh + 2 * far, hr + far, far, k);
        return;
    }
    // From well inside the hole's edge to well outside it.
    const reach = sigma * 2.5;
    const steps = @min(@ceil(2 * reach), 28);
    const step = 2 * reach / steps;
    var i: f32 = 0;
    while (i < steps) : (i += 1) {
        const d0 = -reach + i * step;
        const d1 = d0 + step;
        // A ring whose outer edge is `d1` out of the hole, `step` wide.
        ring(c, hx - d1, hy - d1, hw + 2 * d1, hh + 2 * d1, @max(0, hr + d1), step, k.alpha(insetCover((d0 + d1) / 2, sigma)));
    }
    // Past that, all of it.
    ring(c, hx - reach - far, hy - reach - far, hw + 2 * (reach + far), hh + 2 * (reach + far), hr + reach + far, far, k);
}

test "dashes fit their line" {
    const g = fittedGap(100, 3, 2);
    // A whole number of dashes and gaps, ending on a dash.
    const n = @round((100 + g) / (3 + g));
    try std.testing.expectApproxEqAbs(@as(f32, 100), n * 3 + (n - 1) * g, 0.01);
}

test "tones of the 3D styles" {
    const gray: css.Color = .{ .r = 0.5, .g = 0.5, .b = 0.5 };
    // Inset darkens the top and left; outset the bottom and right.
    try std.testing.expect(tone(.inset, 0, gray).r < tone(.inset, 2, gray).r);
    try std.testing.expect(tone(.outset, 2, gray).r < tone(.outset, 0, gray).r);
    // Black can't darken: the other edge lightens.
    try std.testing.expect(tone(.outset, 0, .{}).r > 0.3);
}

test "inset cover falls through the middle" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), insetCover(0, 4), 0.001);
    try std.testing.expect(insetCover(8, 4) > 0.97);
    try std.testing.expect(insetCover(-8, 4) < 0.03);
}
