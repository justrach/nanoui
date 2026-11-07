//! A box's four corners, as CSS resolves them: each with its own radii, ellipses
//! and percentages included, shrunk together when they would overlap. And their
//! outlines as points, for what nanoui's one radius a box can't draw.
const std = @import("std");
const css = @import("../css/style.zig");
const Allocator = std.mem.Allocator;

pub const Point = struct { x: f32, y: f32 };

/// Horizontal and vertical radii: top left, top right, bottom right, bottom left.
pub const Corners = struct {
    rx: [4]f32 = .{ 0, 0, 0, 0 },
    ry: [4]f32 = .{ 0, 0, 0, 0 },

    /// What `st` says for a box of `w` × `h`.
    pub fn of(st: *const css.Style, w: f32, h: f32) Corners {
        var c: Corners = .{};
        var any = false;
        for (0..4) |i| {
            c.rx[i] = @max(0, st.radius[i] + st.radius_pct[i] * w / 100);
            c.ry[i] = @max(0, st.radius_y[i] + st.radius_y_pct[i] * h / 100);
            if (c.rx[i] <= 0 or c.ry[i] <= 0) {
                c.rx[i] = 0;
                c.ry[i] = 0;
            } else any = true;
        }
        if (!any) return c;
        // Radii that don't fit their side all shrink by the one factor.
        var f: f32 = 1;
        const fit = struct {
            fn at(k: *f32, a: f32, b: f32, side: f32) void {
                if (a + b > side and a + b > 0) k.* = @min(k.*, side / (a + b));
            }
        }.at;
        fit(&f, c.rx[0], c.rx[1], w);
        fit(&f, c.rx[3], c.rx[2], w);
        fit(&f, c.ry[0], c.ry[3], h);
        fit(&f, c.ry[1], c.ry[2], h);
        if (f < 1) for (0..4) |i| {
            c.rx[i] *= f;
            c.ry[i] *= f;
        };
        return c;
    }

    pub fn isSquare(c: Corners) bool {
        for (c.rx, c.ry) |x, y| if (x > 0 or y > 0) return false;
        return true;
    }

    /// The one circular radius they all have, if they do.
    pub fn uniform(c: Corners) ?f32 {
        for (c.rx, c.ry) |x, y| if (@abs(x - c.rx[0]) > 0.01 or @abs(y - c.rx[0]) > 0.01) return null;
        return c.rx[0];
    }

    /// The largest radius, for what has only one to go by.
    pub fn largest(c: Corners) f32 {
        var r: f32 = 0;
        for (c.rx, c.ry) |x, y| r = @max(r, @min(x, y));
        return r;
    }

    /// The corners that are round (1 top left, 2 top right, 4 bottom right, 8 bottom left).
    pub fn mask(c: Corners) u4 {
        var m: u4 = 0;
        for (c.rx, 0..) |x, i| {
            if (x > 0) m |= @as(u4, 1) << @intCast(i);
        }
        return m;
    }

    /// The curve of a box inside this one, by how far in each side is.
    pub fn inset(c: Corners, top: f32, right: f32, bottom: f32, left: f32) Corners {
        const sx = [4]f32{ left, right, right, left };
        const sy = [4]f32{ top, top, bottom, bottom };
        var o: Corners = .{};
        for (0..4) |i| {
            o.rx[i] = @max(0, c.rx[i] - sx[i]);
            o.ry[i] = @max(0, c.ry[i] - sy[i]);
        }
        return o;
    }

    /// Outward by `s`: a square corner stays square.
    pub fn outset(c: Corners, s: f32) Corners {
        var o: Corners = .{};
        for (0..4) |i| {
            if (c.rx[i] <= 0) continue;
            o.rx[i] = @max(0, c.rx[i] + s);
            o.ry[i] = @max(0, c.ry[i] + s);
        }
        return o;
    }
};

/// How many straight pieces a quarter of this size is cut into.
pub fn pieces(rx: f32, ry: f32) usize {
    const r = @max(rx, ry);
    if (r <= 0) return 0;
    return @intFromFloat(std.math.clamp(@ceil(@sqrt(r) * 2.2), 3, 32));
}

/// The outline of the box (x, y, w, h) with these corners, clockwise from the
/// top left corner's start.
pub fn outline(a: Allocator, x: f32, y: f32, w: f32, h: f32, c: Corners) Allocator.Error![]Point {
    var out: std.ArrayList(Point) = .empty;
    const centers = [4]Point{
        .{ .x = x + c.rx[0], .y = y + c.ry[0] },
        .{ .x = x + w - c.rx[1], .y = y + c.ry[1] },
        .{ .x = x + w - c.rx[2], .y = y + h - c.ry[2] },
        .{ .x = x + c.rx[3], .y = y + h - c.ry[3] },
    };
    const starts = [4]f32{ std.math.pi, 1.5 * std.math.pi, 0, 0.5 * std.math.pi };
    for (0..4) |i| {
        const n = pieces(c.rx[i], c.ry[i]);
        if (n == 0) {
            try out.append(a, centers[i]);
            continue;
        }
        for (0..n + 1) |k| {
            const t = starts[i] + @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n)) * 0.5 * std.math.pi;
            try out.append(a, .{ .x = centers[i].x + c.rx[i] * @cos(t), .y = centers[i].y + c.ry[i] * @sin(t) });
        }
    }
    return out.items;
}

test "corners that don't fit shrink together" {
    const s: css.Style = .{ .radius = .{ 100, 100, 100, 100 }, .radius_y = .{ 100, 100, 100, 100 } };
    const c = Corners.of(&s, 200, 40);
    try std.testing.expectApproxEqAbs(@as(f32, 20), c.rx[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), c.uniform().?, 0.001);
    const none: css.Style = .{};
    try std.testing.expect(Corners.of(&none, 10, 10).isSquare());
}

test "percentages are of each axis: an ellipse" {
    const s: css.Style = .{ .radius_pct = .{ 50, 50, 50, 50 }, .radius_y_pct = .{ 50, 50, 50, 50 } };
    const c = Corners.of(&s, 100, 40);
    try std.testing.expectEqual(@as(f32, 50), c.rx[0]);
    try std.testing.expectEqual(@as(f32, 20), c.ry[0]);
    try std.testing.expect(c.uniform() == null);
    const square = Corners.of(&s, 40, 40);
    try std.testing.expectEqual(@as(f32, 20), square.uniform().?);
}

test "inner corners and masks" {
    const s: css.Style = .{ .radius = .{ 10, 0, 4, 0 }, .radius_y = .{ 10, 0, 4, 0 } };
    const c = Corners.of(&s, 100, 100);
    try std.testing.expectEqual(@as(u4, 5), c.mask());
    const i = c.inset(2, 2, 6, 2);
    try std.testing.expectEqual(@as(f32, 8), i.rx[0]);
    try std.testing.expectEqual(@as(f32, 0), i.ry[2]);
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const o = try outline(a.allocator(), 0, 0, 100, 100, c);
    try std.testing.expect(o.len > 4);
    try std.testing.expectEqual(@as(f32, 0), o[0].x);
    try std.testing.expectApproxEqAbs(@as(f32, 10), o[0].y, 1e-3);
}
