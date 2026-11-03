//! SVG geometry in pixels: affine transforms, and outlines flattened into
//! polylines (curves and arcs into lines fine enough that no point strays
//! more than `tolerance` pixels from the curve).
const std = @import("std");

pub const Point = [2]f32;

/// `a c e / b d f`: x' = a·x + c·y + e, y' = b·x + d·y + f, as SVG writes
/// `matrix(a b c d e f)`.
pub const Transform = struct {
    m: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },

    pub fn apply(t: Transform, p: Point) Point {
        return .{ t.m[0] * p[0] + t.m[2] * p[1] + t.m[4], t.m[1] * p[0] + t.m[3] * p[1] + t.m[5] };
    }

    /// `t` then `o`: first this transform, then the outer one.
    pub fn then(t: Transform, o: Transform) Transform {
        const a = o.m;
        const b = t.m;
        return .{ .m = .{
            a[0] * b[0] + a[2] * b[1],
            a[1] * b[0] + a[3] * b[1],
            a[0] * b[2] + a[2] * b[3],
            a[1] * b[2] + a[3] * b[3],
            a[0] * b[4] + a[2] * b[5] + a[4],
            a[1] * b[4] + a[3] * b[5] + a[5],
        } };
    }

    pub fn translate(x: f32, y: f32) Transform {
        return .{ .m = .{ 1, 0, 0, 1, x, y } };
    }

    pub fn scale(x: f32, y: f32) Transform {
        return .{ .m = .{ x, 0, 0, y, 0, 0 } };
    }

    pub fn rotate(deg: f32) Transform {
        const r = deg * std.math.pi / 180;
        return .{ .m = .{ @cos(r), @sin(r), -@sin(r), @cos(r), 0, 0 } };
    }

    /// How much it scales lengths, on average (a stroke's width).
    pub fn lengthScale(t: Transform) f32 {
        return @sqrt(@abs(t.m[0] * t.m[3] - t.m[1] * t.m[2]));
    }
};

pub const Subpath = struct { start: usize, len: usize, closed: bool };

/// Outlines as polylines in pixels: user-space commands in, transformed
/// and flattened points out.
pub const Flattener = struct {
    gpa: std.mem.Allocator,
    t: Transform = .{},
    tolerance: f32 = 0.12,
    points: std.ArrayList(Point) = .empty,
    subpaths: std.ArrayList(Subpath) = .empty,
    /// The pen and where its subpath began, in user space.
    pen: Point = .{ 0, 0 },
    begin: Point = .{ 0, 0 },
    open: bool = false,

    pub fn deinit(f: *Flattener) void {
        f.points.deinit(f.gpa);
        f.subpaths.deinit(f.gpa);
    }

    /// Empties it for the next shape, its pen back at the origin: a path's
    /// first `m` is absolute, whatever the shape before ended on.
    pub fn clear(f: *Flattener) void {
        f.points.clearRetainingCapacity();
        f.subpaths.clearRetainingCapacity();
        f.open = false;
        f.pen = .{ 0, 0 };
        f.begin = .{ 0, 0 };
    }

    pub fn moveTo(f: *Flattener, p: Point) !void {
        f.open = true;
        try f.subpaths.append(f.gpa, .{ .start = f.points.items.len, .len = 0, .closed = false });
        f.pen = p;
        f.begin = p;
        try f.push(p);
    }

    fn push(f: *Flattener, p: Point) !void {
        try f.points.append(f.gpa, f.t.apply(p));
        f.subpaths.items[f.subpaths.items.len - 1].len += 1;
    }

    /// A drawing command with no subpath open starts one where the pen is.
    fn ensure(f: *Flattener) !void {
        if (!f.open) try f.moveTo(f.pen);
    }

    pub fn lineTo(f: *Flattener, p: Point) !void {
        try f.ensure();
        try f.push(p);
        f.pen = p;
    }

    pub fn quadTo(f: *Flattener, c: Point, p: Point) !void {
        const c1: Point = .{ f.pen[0] + 2.0 / 3.0 * (c[0] - f.pen[0]), f.pen[1] + 2.0 / 3.0 * (c[1] - f.pen[1]) };
        const c2: Point = .{ p[0] + 2.0 / 3.0 * (c[0] - p[0]), p[1] + 2.0 / 3.0 * (c[1] - p[1]) };
        try f.cubicTo(c1, c2, p);
    }

    pub fn cubicTo(f: *Flattener, c1: Point, c2: Point, p: Point) !void {
        try f.ensure();
        const p0 = f.t.apply(f.pen);
        const q1 = f.t.apply(c1);
        const q2 = f.t.apply(c2);
        const p3 = f.t.apply(p);
        // Wang's formula: segments enough that the flattening error stays
        // under the tolerance.
        const dx = @max(@abs(p0[0] - 2 * q1[0] + q2[0]), @abs(q1[0] - 2 * q2[0] + p3[0]));
        const dy = @max(@abs(p0[1] - 2 * q1[1] + q2[1]), @abs(q1[1] - 2 * q2[1] + p3[1]));
        const dd = @sqrt(dx * dx + dy * dy);
        const n: usize = @intFromFloat(std.math.clamp(@ceil(@sqrt(0.75 * dd / f.tolerance)), 1, 200));
        for (1..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const mt = 1 - t;
            const a = mt * mt * mt;
            const b = 3 * mt * mt * t;
            const c = 3 * mt * t * t;
            const d = t * t * t;
            try f.points.append(f.gpa, .{
                a * p0[0] + b * q1[0] + c * q2[0] + d * p3[0],
                a * p0[1] + b * q1[1] + c * q2[1] + d * p3[1],
            });
            f.subpaths.items[f.subpaths.items.len - 1].len += 1;
        }
        f.pen = p;
    }

    /// SVG's elliptical arc from the pen to `p` (the spec's appendix B.2.4:
    /// endpoint to center parameterization).
    pub fn arcTo(f: *Flattener, rx_in: f32, ry_in: f32, rot_deg: f32, large: bool, sweep: bool, p: Point) !void {
        try f.ensure();
        const p0 = f.pen;
        if (p0[0] == p[0] and p0[1] == p[1]) return;
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if (rx == 0 or ry == 0) return f.lineTo(p);
        const phi = rot_deg * std.math.pi / 180;
        const cs = @cos(phi);
        const sn = @sin(phi);
        const hx = (p0[0] - p[0]) / 2;
        const hy = (p0[1] - p[1]) / 2;
        const x1 = cs * hx + sn * hy;
        const y1 = -sn * hx + cs * hy;
        // Radii too small to reach: scaled up until they just do.
        const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lambda > 1) {
            const s = @sqrt(lambda);
            rx *= s;
            ry *= s;
        }
        const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var k = @sqrt(@max(0, num / den));
        if (large == sweep) k = -k;
        const cxp = k * rx * y1 / ry;
        const cyp = -k * ry * x1 / rx;
        const cx = cs * cxp - sn * cyp + (p0[0] + p[0]) / 2;
        const cy = sn * cxp + cs * cyp + (p0[1] + p[1]) / 2;
        const t1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry);
        var dt = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry);
        if (!sweep and dt > 0) dt -= 2 * std.math.pi;
        if (sweep and dt < 0) dt += 2 * std.math.pi;
        // Segments by the radius in pixels: each spans an angle whose chord
        // strays at most the tolerance.
        const r_px = @max(rx, ry) * f.t.lengthScale();
        const step = 2 * std.math.acos(std.math.clamp(1 - f.tolerance / @max(r_px, f.tolerance), -1, 1));
        const n: usize = @intFromFloat(std.math.clamp(@ceil(@abs(dt) / @max(step, 0.01)), 1, 400));
        for (1..n + 1) |i| {
            const a = t1 + dt * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const ex = rx * @cos(a);
            const ey = ry * @sin(a);
            try f.push(if (i == n) p else .{ cx + cs * ex - sn * ey, cy + sn * ex + cs * ey });
        }
        f.pen = p;
    }

    pub fn close(f: *Flattener) void {
        if (!f.open) return;
        f.subpaths.items[f.subpaths.items.len - 1].closed = true;
        f.pen = f.begin;
        f.open = false;
    }

    pub fn of(f: *const Flattener, s: Subpath) []const Point {
        return f.points.items[s.start..][0..s.len];
    }
};

fn angle(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
    return std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
}

test "transforms compose in order, and arcs end where they're asked" {
    const t = Transform.scale(2, 2).then(Transform.translate(10, 0));
    const p = t.apply(.{ 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 12), p[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), p[1], 1e-5);
    var f: Flattener = .{ .gpa = std.testing.allocator };
    defer f.deinit();
    try f.moveTo(.{ 0, 10 });
    try f.arcTo(10, 10, 0, false, true, .{ 20, 10 });
    const pts = f.of(f.subpaths.items[0]);
    try std.testing.expect(pts.len > 8);
    try std.testing.expectEqual(Point{ 20, 10 }, pts[pts.len - 1]);
    // The half circle's top, through (10, 0) for a clockwise sweep in y-down.
    var top: f32 = 100;
    for (pts) |q| top = @min(top, q[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0), top, 0.2);
}
