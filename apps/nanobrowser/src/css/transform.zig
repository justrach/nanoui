//! A style's transform as one matrix for a box of a given size: the `translate`,
//! `rotate` and `scale` properties, then `transform`'s functions, about
//! `transform-origin`. Lists of different shapes interpolate by decomposing.
const std = @import("std");
const style = @import("style.zig");
const fx = @import("effects.zig");

const Mat = fx.Mat;
const Op = fx.Op;
const Style = style.Style;

fn ofOps(ops: []const Op, w: f32, h: f32) Mat {
    var m: Mat = .{};
    for (ops) |o| m = m.times(ofOp(o, w, h));
    return m;
}

fn ofOp(o: Op, w: f32, h: f32) Mat {
    return switch (o) {
        .translate => |t| Mat.translate(t.x.resolve(w, 0), t.y.resolve(h, 0)),
        .scale => |s| Mat.scale(s[0], s[1]),
        .rotate => |d| Mat.rotate(d),
        .skew => |s| Mat.skew(s[0], s[1]),
        .matrix => |m| m,
        .mix => |x| blend(ofOps(x.a, w, h), ofOps(x.b, w, h), x.k),
    };
}

/// The style's whole transform, or null when it has none.
pub fn of(s: *const Style, w: f32, h: f32) ?Mat {
    if (!s.hasTransform()) return null;
    const ox = s.transform_origin_x.resolve(w, 0);
    const oy = s.transform_origin_y.resolve(h, 0);
    var m = Mat.translate(ox, oy);
    m = m.times(Mat.translate(s.translate_x.resolve(w, 0), s.translate_y.resolve(h, 0)));
    if (s.rotate != 0) m = m.times(Mat.rotate(s.rotate));
    if (s.scale_x != 1 or s.scale_y != 1) m = m.times(Mat.scale(s.scale_x, s.scale_y));
    if (s.transform) |t| m = m.times(ofOps(t.ops, w, h));
    return m.times(Mat.translate(-ox, -oy));
}

const Parts = struct { tx: f32, ty: f32, sx: f32, sy: f32, skew: f32, angle: f32 };

/// CSS's "unmatrix" for two dimensions.
fn decompose(m: Mat) Parts {
    var a = m.a;
    var b = m.b;
    var c = m.c;
    var d = m.d;
    var sx = @sqrt(a * a + b * b);
    if (sx > 0) {
        a /= sx;
        b /= sx;
    }
    var shear = a * c + b * d;
    c -= a * shear;
    d -= b * shear;
    const sy = @sqrt(c * c + d * d);
    if (sy > 0) {
        c /= sy;
        d /= sy;
        shear /= sy;
    }
    if (a * d - b * c < 0) {
        a = -a;
        b = -b;
        shear = -shear;
        sx = -sx;
    }
    return .{ .tx = m.e, .ty = m.f, .sx = sx, .sy = sy, .skew = shear, .angle = std.math.atan2(b, a) };
}

/// Part way from `p` to `q`, turning the short way round.
pub fn blend(p: Mat, q: Mat, k: f32) Mat {
    const a = decompose(p);
    const b = decompose(q);
    var turn = b.angle - a.angle;
    if (turn > std.math.pi) turn -= 2 * std.math.pi;
    if (turn < -std.math.pi) turn += 2 * std.math.pi;
    const l = struct {
        fn f(x: f32, y: f32, t: f32) f32 {
            return x + (y - x) * t;
        }
    }.f;
    const angle = a.angle + turn * k;
    const ca = @cos(angle);
    const sa = @sin(angle);
    const sx = l(a.sx, b.sx, k);
    const sy = l(a.sy, b.sy, k);
    const shear = l(a.skew, b.skew, k);
    return .{
        .a = ca * sx,
        .b = sa * sx,
        .c = (ca * shear - sa) * sy,
        .d = (sa * shear + ca) * sy,
        .e = l(a.tx, b.tx, k),
        .f = l(a.ty, b.ty, k),
    };
}

/// Whether two lists run function by function.
pub fn sameShape(a: []const Op, b: []const Op) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return true;
}

test "a style's matrix turns about its origin" {
    const ops = [_]Op{.{ .rotate = 90 }};
    const s: Style = .{ .transform = .{ .ops = &ops } };
    const m = of(&s, 100, 50).?;
    // The middle stays; the top left swings round it.
    const mid = m.apply(50, 25);
    try std.testing.expectApproxEqAbs(@as(f32, 50), mid[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 25), mid[1], 1e-3);
    const corner = m.apply(0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 75), corner[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -25), corner[1], 1e-3);
    const none: Style = .{};
    try std.testing.expect(of(&none, 10, 10) == null);
}

test "percentages in a transform are of the box" {
    const ops = [_]Op{.{ .translate = .{ .x = .{ .pct = 50 }, .y = .{ .px = 3 } } }};
    const s: Style = .{ .transform = .{ .ops = &ops } };
    const m = of(&s, 100, 50).?;
    try std.testing.expect(m.onlyMoves());
    try std.testing.expectApproxEqAbs(@as(f32, 50), m.e, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 3), m.f, 1e-3);
}

test "blending matrices keeps their parts" {
    const m = blend(Mat.rotate(0), Mat.rotate(90), 0.5);
    try std.testing.expectApproxEqAbs(@cos(@as(f32, std.math.pi) / 4), m.a, 1e-4);
    const s = blend(Mat.scale(1, 1), Mat.scale(3, 5), 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), s.a, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 3), s.d, 1e-4);
    const t = blend(Mat.translate(0, 0), Mat.translate(10, 20), 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 5), t.e, 1e-4);
}
