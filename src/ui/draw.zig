//! A box to draw in (`ui.canvas`): lines, filled triangles and polygons,
//! circles and rounded rectangles, at points within the box. They are
//! drawn as the frame paints the box, clipped to it, and kept only for
//! the frame, like everything else in it. A map, a chart, a diagram.
//!
//!     const cv = ui.canvas(c, .{ .width = .fill, .height = .{ .px = 200 } });
//!     cv.polyline(&points, .{ .width = 2, .color = c.theme.accent });
//!     cv.fill(&outline, c.theme.muted);
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const Context = @import("context.zig").Context;
const triangulation = @import("triangulate.zig");

pub const Point = types.Point;
const Color = types.Color;

pub const Stroke = struct {
    width: f32 = 1,
    color: Color,
    /// A dash's length and the gap after it, in points: null for a solid line.
    dash: ?[2]f32 = null,
};

pub const Canvas = struct {
    c: *Context,
    /// What is drawn, at points within the box.
    shapes: std.ArrayList(gpu.Instance) = .empty,
    /// The box's size at the last layout: zero in its first frame (which
    /// is built again once it has one).
    size: types.Size = .{},

    fn add(cv: *Canvas, i: gpu.Instance) void {
        cv.shapes.append(cv.c.alloc(), i) catch {};
    }

    /// A line from `a` to `b`, its ends round.
    pub fn line(cv: *Canvas, a: Point, b: Point, s: Stroke) void {
        cv.dashed(a, b, s, 0);
    }

    fn dashed(cv: *Canvas, a: Point, b: Point, s: Stroke, phase: f32) void {
        const e = s.width * 0.5 + 1;
        const dash = s.dash orelse .{ 0, 0 };
        cv.add(.{
            .rect = .{ @min(a.x, b.x) - e, @min(a.y, b.y) - e, @abs(b.x - a.x) + 2 * e, @abs(b.y - a.y) + 2 * e },
            .color = gpu.color4(s.color),
            .uv = .{ a.x, a.y, b.x, b.y },
            .border_color = .{ dash[0], dash[1], phase, 0 },
            .border_width = s.width,
            .kind = gpu.Kind.segment,
        });
    }

    /// Lines through `points` in turn, a dash carrying on round each corner.
    pub fn polyline(cv: *Canvas, points: []const Point, s: Stroke) void {
        var along: f32 = 0;
        for (points[0..points.len -| 1], points[@min(1, points.len)..]) |a, b| {
            cv.dashed(a, b, s, along);
            along += @sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y));
        }
    }

    /// A filled triangle. `smooth`: its edges smoothed (1 `a` to `b`, 2 `b`
    /// to `p`, 4 `p` to `a`); leave out those it shares with another, so
    /// the two meet without a seam.
    pub fn triangle(cv: *Canvas, a: Point, b: Point, p: Point, color: Color, smooth: u3) void {
        const x0 = @min(a.x, @min(b.x, p.x));
        const y0 = @min(a.y, @min(b.y, p.y));
        cv.add(.{
            .rect = .{ x0, y0, @max(a.x, @max(b.x, p.x)) - x0, @max(a.y, @max(b.y, p.y)) - y0 },
            .color = gpu.color4(color),
            .uv = .{ a.x, a.y, b.x, b.y },
            .border_color = .{ p.x, p.y, @floatFromInt(smooth), 0 },
            .kind = gpu.Kind.triangle,
        });
    }

    /// Triangles made already (`triangulate`): `tris` index `points`, its
    /// edges smoothed as `tris` says.
    pub fn mesh(cv: *Canvas, points: []const Point, tris: []const Triangle, color: Color) void {
        for (tris) |t| cv.triangle(points[t.v[0]], points[t.v[1]], points[t.v[2]], color, t.smooth);
    }

    /// A polygon filled (its outline once round, either way; no holes),
    /// its outline smoothed.
    pub fn fill(cv: *Canvas, points: []const Point, color: Color) void {
        const tris = triangulate(cv.c.alloc(), points) catch return;
        cv.mesh(points, tris, color);
    }

    pub fn circle(cv: *Canvas, center: Point, r: f32, color: Color) void {
        cv.rect(.{ .x = center.x - r, .y = center.y - r, .w = 2 * r, .h = 2 * r }, color, r);
    }

    pub fn rect(cv: *Canvas, r: types.Rect, color: Color, radius: f32) void {
        cv.add(.{ .rect = .{ r.x, r.y, r.w, r.h }, .color = gpu.color4(color), .radius = radius });
    }

    /// A ring: a circle's outline `width` wide.
    pub fn ring(cv: *Canvas, center: Point, r: f32, width: f32, color: Color) void {
        cv.add(.{
            .rect = .{ center.x - r, center.y - r, 2 * r, 2 * r },
            .color = .{ 0, 0, 0, 0 },
            .border_color = gpu.color4(color),
            .border_width = width,
            .radius = r,
        });
    }
};

/// A box to draw in, sized and placed by `style`.
pub fn canvas(c: *Context, style: types.Style) *Canvas {
    const cv = c.alloc().create(Canvas) catch @panic("nanoui: out of memory");
    const id = c.peekId(null);
    cv.* = .{ .c = c };
    if (c.rects.get(id)) |r| {
        cv.size = .{ .w = r.w, .h = r.h };
    } else if (style.width == .px and style.height == .px) {
        cv.size = .{ .w = style.width.px, .h = style.height.px };
    } else {
        c.changed = true;
    }
    _ = c.leaf(style, .{ .canvas = cv }, null);
    return cv;
}

pub const Triangle = triangulation.Triangle;
pub const triangulate = triangulation.triangulate;
