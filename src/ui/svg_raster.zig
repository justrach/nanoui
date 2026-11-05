//! Polygons to coverage, for SVG: each pixel row sampled on 16 lines, each
//! line's crossings walked with the fill rule (nonzero or evenodd), and the
//! spans inside added with their ends' fractions, so edges are exact across
//! and 16 steps deep down. Overlapping shapes join exactly, which is what
//! strokes need: a stroke is drawn as the union of its segments, joins and
//! caps, every piece wound the same way.
const std = @import("std");
const geom = @import("svg_geom.zig");
const Point = geom.Point;

pub const Rule = enum { nonzero, evenodd };
pub const Cap = enum { butt, round, square };
pub const Join = enum { miter, round, bevel };

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, dir: i8 };

const samples = 16;

/// Part of a buffer of pixels: columns `x0` to `x1`, rows `y0` to `y1`.
pub const Region = struct {
    x0: usize = 0,
    y0: usize = 0,
    x1: usize = 0,
    y1: usize = 0,

    pub fn isEmpty(r: Region) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }

    pub fn join(a: Region, b: Region) Region {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }
};

/// Edges of closed polygons, in pixels.
pub const Polygons = struct {
    gpa: std.mem.Allocator,
    edges: std.ArrayList(Edge) = .empty,
    /// Applied to what's given: a stroke made in user space, where a circle
    /// wouldn't stay one in pixels.
    xf: ?geom.Transform = null,

    pub fn deinit(p: *Polygons) void {
        p.edges.deinit(p.gpa);
    }

    pub fn clear(p: *Polygons) void {
        p.edges.clearRetainingCapacity();
    }

    pub fn line(p: *Polygons, a_in: Point, b_in: Point) !void {
        const a = if (p.xf) |t| t.apply(a_in) else a_in;
        const b = if (p.xf) |t| t.apply(b_in) else b_in;
        if (a[1] == b[1]) return;
        try p.edges.append(p.gpa, if (a[1] < b[1])
            .{ .x0 = a[0], .y0 = a[1], .x1 = b[0], .y1 = b[1], .dir = 1 }
        else
            .{ .x0 = b[0], .y0 = b[1], .x1 = a[0], .y1 = a[1], .dir = -1 });
    }

    /// A closed polygon as given.
    pub fn polygon(p: *Polygons, pts: []const Point) !void {
        if (pts.len < 2) return;
        for (pts, 0..) |a, i| try p.line(a, pts[(i + 1) % pts.len]);
    }

    /// A closed polygon wound positive (for unions under nonzero).
    pub fn positive(p: *Polygons, pts: []const Point) !void {
        if (pts.len < 3) return;
        var area: f32 = 0;
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            area += a[0] * b[1] - b[0] * a[1];
        }
        if (area >= 0) return p.polygon(pts);
        var i = pts.len;
        while (i > 0) {
            i -= 1;
            try p.line(pts[i], pts[if (i == 0) pts.len - 1 else i - 1]);
        }
    }

    /// Coverage of each pixel, 0 to 1, into `out` (w × h), by `rule`.
    pub fn fill(p: *Polygons, rule: Rule, w: usize, h: usize, out: []f32) !void {
        @memset(out[0 .. w * h], 0);
        _ = try p.fillRegion(rule, w, h, out, null);
    }

    /// Where the edges reach within the picture and `limit` (pixels).
    fn reach(p: *const Polygons, w: usize, h: usize, limit: ?[4]f32) Region {
        if (p.edges.items.len == 0) return .{};
        var x0: f32 = std.math.inf(f32);
        var y0: f32 = std.math.inf(f32);
        var x1: f32 = -std.math.inf(f32);
        var y1: f32 = -std.math.inf(f32);
        for (p.edges.items) |e| {
            x0 = @min(x0, @min(e.x0, e.x1));
            x1 = @max(x1, @max(e.x0, e.x1));
            y0 = @min(y0, e.y0);
            y1 = @max(y1, e.y1);
        }
        if (limit) |l| {
            x0 = @max(x0, l[0]);
            y0 = @max(y0, l[1]);
            x1 = @min(x1, l[2]);
            y1 = @min(y1, l[3]);
        }
        const wf: f32 = @floatFromInt(w);
        const hf: f32 = @floatFromInt(h);
        if (!(x0 < wf and y0 < hf and x1 > 0 and y1 > 0 and x1 > x0 and y1 > y0)) return .{};
        return .{
            .x0 = @intFromFloat(@floor(@max(x0, 0))),
            .y0 = @intFromFloat(@floor(@max(y0, 0))),
            .x1 = @intFromFloat(@ceil(@min(x1, wf))),
            .y1 = @intFromFloat(@ceil(@min(y1, hf))),
        };
    }

    /// Coverage where the polygons reach, within `limit` (pixels), which is
    /// all of `out` that's written: the rest is left as it was. Gives that
    /// part, so a small shape in a large picture costs what it covers.
    pub fn fillRegion(p: *Polygons, rule: Rule, w: usize, h: usize, out: []f32, limit: ?[4]f32) !Region {
        const r = p.reach(w, h, limit);
        if (r.isEmpty()) return .{};
        // The left of each row counts windings from off the picture, so every
        // edge stays; those above or below drop out as the rows pass them.
        std.mem.sort(Edge, p.edges.items, {}, struct {
            fn lt(_: void, a: Edge, b: Edge) bool {
                return a.y0 < b.y0;
            }
        }.lt);
        var active: std.ArrayList(Edge) = .empty;
        defer active.deinit(p.gpa);
        var xs: std.ArrayList(Cross) = .empty;
        defer xs.deinit(p.gpa);
        const left: f32 = @floatFromInt(r.x0);
        const right: f32 = @floatFromInt(r.x1);
        var next: usize = 0;
        for (r.y0..r.y1) |y| {
            const yf: f32 = @floatFromInt(y);
            const row = out[y * w ..][0..w];
            @memset(row[r.x0..r.x1], 0);
            var keep: usize = 0;
            for (active.items) |e| if (e.y1 > yf) {
                active.items[keep] = e;
                keep += 1;
            };
            active.shrinkRetainingCapacity(keep);
            while (next < p.edges.items.len and p.edges.items[next].y0 < yf + 1) : (next += 1) {
                const e = p.edges.items[next];
                if (e.y1 > yf) try active.append(p.gpa, e);
            }
            if (active.items.len == 0) continue;
            for (0..samples) |k| {
                const sy = yf + (@as(f32, @floatFromInt(k)) + 0.5) / samples;
                xs.clearRetainingCapacity();
                for (active.items) |e| if (sy >= e.y0 and sy < e.y1) {
                    const t = (sy - e.y0) / (e.y1 - e.y0);
                    try xs.append(p.gpa, .{ .x = e.x0 + (e.x1 - e.x0) * t, .dir = e.dir });
                };
                std.mem.sort(Cross, xs.items, {}, Cross.lt);
                var wind: i32 = 0;
                for (xs.items, 0..) |c, i| {
                    wind += c.dir;
                    const inside = switch (rule) {
                        .nonzero => wind != 0,
                        .evenodd => @mod(wind, 2) != 0,
                    };
                    if (inside and i + 1 < xs.items.len)
                        span(row, std.math.clamp(c.x, left, right), std.math.clamp(xs.items[i + 1].x, left, right), 1.0 / @as(f32, samples));
                }
            }
            for (row[r.x0..r.x1]) |*v| v.* = @min(v.*, 1);
        }
        return r;
    }
};

const Cross = struct {
    x: f32,
    dir: i8,

    fn lt(_: void, a: Cross, b: Cross) bool {
        return a.x < b.x;
    }
};

/// Adds `k` × how much of each pixel [a, b) covers.
fn span(row: []f32, a: f32, b: f32, k: f32) void {
    if (b <= a) return;
    const ia: usize = @intFromFloat(@floor(a));
    const ib: usize = @intFromFloat(@floor(b));
    if (ia == ib) {
        if (ia < row.len) row[ia] += (b - a) * k;
        return;
    }
    row[ia] += (@as(f32, @floatFromInt(ia + 1)) - a) * k;
    for (ia + 1..ib) |x| row[x] += k;
    if (ib < row.len) row[ib] += (b - @as(f32, @floatFromInt(ib))) * k;
}

pub const StrokeStyle = struct {
    /// Half the width, in pixels.
    half: f32,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f32 = 4,
    /// Pixels a unit of these points: how fine a round join's circle is.
    detail: f32 = 1,
};

/// `pts` cut by a dash pattern (lengths in the same units), each dash to
/// `sink.dash(points)`. A closed polyline is walked back to its start.
pub fn dash(gpa: std.mem.Allocator, pts: []const Point, closed: bool, pattern: []const f32, offset: f32, sink: anytype) !void {
    if (pts.len == 0) return;
    var total: f32 = 0;
    for (pattern) |d| total += d;
    if (total <= 0) return;
    // An odd count repeats to an even one.
    const n = if (pattern.len % 2 == 1) pattern.len * 2 else pattern.len;
    const whole = if (pattern.len % 2 == 1) total * 2 else total;
    var at = @mod(offset, whole);
    var i: usize = 0;
    while (at >= pattern[i % pattern.len]) {
        at -= pattern[i % pattern.len];
        i = (i + 1) % n;
        if (pattern[i % pattern.len] == 0 and at == 0) break;
    }
    var left = pattern[i % pattern.len] - at;
    var cur: std.ArrayList(Point) = .empty;
    defer cur.deinit(gpa);
    var on = i % 2 == 0;
    if (on) try cur.append(gpa, pts[0]);
    const count = if (closed) pts.len + 1 else pts.len;
    var budget: u32 = 200_000;
    var seg: usize = 1;
    var a = pts[0];
    while (seg < count) : (seg += 1) {
        const b = pts[seg % pts.len];
        var rest = dist(a, b);
        const d: Point = if (rest > 0) .{ (b[0] - a[0]) / rest, (b[1] - a[1]) / rest } else .{ 0, 0 };
        var p = a;
        while (rest >= left and budget > 0) : (budget -= 1) {
            p = .{ p[0] + d[0] * left, p[1] + d[1] * left };
            rest -= left;
            if (on) {
                try cur.append(gpa, p);
                try sink.dash(cur.items);
                cur.clearRetainingCapacity();
            } else try cur.append(gpa, p);
            on = !on;
            i = (i + 1) % n;
            left = pattern[i % pattern.len];
        }
        left -= rest;
        if (on) try cur.append(gpa, b);
        a = b;
    }
    if (on and cur.items.len > 0) try sink.dash(cur.items);
}

/// A polyline's stroke as polygons, all wound positive: a quad per segment,
/// a join at each corner, a cap at each open end.
pub fn stroke(p: *Polygons, pts_in: []const Point, closed: bool, s: StrokeStyle) !void {
    // Repeated points carry no direction: dropped.
    var pts: std.ArrayList(Point) = .empty;
    defer pts.deinit(p.gpa);
    for (pts_in) |q| if (pts.items.len == 0 or dist(pts.items[pts.items.len - 1], q) > 1e-4) try pts.append(p.gpa, q);
    if (closed and pts.items.len > 1 and dist(pts.items[0], pts.items[pts.items.len - 1]) <= 1e-4) _ = pts.pop();
    const v = pts.items;
    if (v.len == 0) return;
    if (v.len == 1) {
        // A dot: only caps that have a shape draw it.
        switch (s.cap) {
            .round => try disc(p, v[0], s.half, s.detail),
            .square => try p.positive(&.{ .{ v[0][0] - s.half, v[0][1] - s.half }, .{ v[0][0] + s.half, v[0][1] - s.half }, .{ v[0][0] + s.half, v[0][1] + s.half }, .{ v[0][0] - s.half, v[0][1] + s.half } }),
            .butt => {},
        }
        return;
    }
    const n = v.len;
    const segs = if (closed) n else n - 1;
    for (0..segs) |i| {
        var a = v[i];
        var b = v[(i + 1) % n];
        const d = unit(a, b);
        if (!closed and s.cap == .square) {
            if (i == 0) a = .{ a[0] - d[0] * s.half, a[1] - d[1] * s.half };
            if (i == segs - 1) b = .{ b[0] + d[0] * s.half, b[1] + d[1] * s.half };
        }
        const nx = -d[1] * s.half;
        const ny = d[0] * s.half;
        try p.positive(&.{ .{ a[0] + nx, a[1] + ny }, .{ b[0] + nx, b[1] + ny }, .{ b[0] - nx, b[1] - ny }, .{ a[0] - nx, a[1] - ny } });
    }
    const first_join: usize = if (closed) 0 else 1;
    const last_join: usize = if (closed) n else n - 1;
    for (first_join..last_join) |i| try join(p, v[(i + n - 1) % n], v[i], v[(i + 1) % n], s);
    if (!closed and s.cap == .round) {
        try disc(p, v[0], s.half, s.detail);
        try disc(p, v[n - 1], s.half, s.detail);
    }
}

fn join(p: *Polygons, a: Point, b: Point, c: Point, s: StrokeStyle) !void {
    const d1 = unit(a, b);
    const d2 = unit(b, c);
    const cross = d1[0] * d2[1] - d1[1] * d2[0];
    const dot = d1[0] * d2[0] + d1[1] * d2[1];
    if (@abs(cross) < 1e-5 and dot > 0) return; // straight on
    if (s.join == .round) return disc(p, b, s.half, s.detail);
    // The outer side: away from the turn.
    const side: f32 = if (cross > 0) -1 else 1;
    const o1: Point = .{ b[0] - d1[1] * s.half * side, b[1] + d1[0] * s.half * side };
    const o2: Point = .{ b[0] - d2[1] * s.half * side, b[1] + d2[0] * s.half * side };
    if (s.join == .miter) {
        // The miter's length over the width is 1 / sin(θ/2).
        const cos_theta = std.math.clamp(-dot, -1, 1);
        const sin_half = @sqrt(@max(0, (1 - cos_theta) / 2));
        if (sin_half > 1e-4 and 1 / sin_half <= s.miter_limit) {
            const mx = (o1[0] + o2[0]) / 2 - b[0];
            const my = (o1[1] + o2[1]) / 2 - b[1];
            const ml = @sqrt(mx * mx + my * my);
            if (ml > 1e-6) {
                const reach = s.half / sin_half;
                const tip: Point = .{ b[0] + mx / ml * reach, b[1] + my / ml * reach };
                return p.positive(&.{ b, o1, tip, o2 });
            }
        }
    }
    try p.positive(&.{ b, o1, o2 });
}

fn disc(p: *Polygons, c: Point, r: f32, detail: f32) !void {
    const n: usize = @intFromFloat(std.math.clamp(@ceil(r * detail * 4), 8, 64));
    var pts: [64]Point = undefined;
    for (0..n) |i| {
        const t = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        pts[i] = .{ c[0] + r * @cos(t), c[1] + r * @sin(t) };
    }
    try p.positive(pts[0..n]);
}

fn dist(a: Point, b: Point) f32 {
    return @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
}

fn unit(a: Point, b: Point) Point {
    const l = @max(dist(a, b), 1e-6);
    return .{ (b[0] - a[0]) / l, (b[1] - a[1]) / l };
}

const testing = std.testing;

test "a square half a pixel off: exact across, and the rules differ on holes" {
    var p: Polygons = .{ .gpa = testing.allocator };
    defer p.deinit();
    try p.polygon(&.{ .{ 2, 2 }, .{ 6.5, 2 }, .{ 6.5, 6 }, .{ 2, 6 } });
    var out: [64]f32 = undefined;
    try p.fill(.nonzero, 8, 8, &out);
    try testing.expectApproxEqAbs(@as(f32, 1), out[3 * 8 + 3], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[3 * 8 + 6], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), out[1 * 8 + 3], 1e-4);
    // A hole wound the same way: filled under nonzero, empty under evenodd.
    try p.polygon(&.{ .{ 3, 3 }, .{ 5, 3 }, .{ 5, 5 }, .{ 3, 5 } });
    try p.fill(.nonzero, 8, 8, &out);
    try testing.expectApproxEqAbs(@as(f32, 1), out[4 * 8 + 4], 1e-4);
    try p.fill(.evenodd, 8, 8, &out);
    try testing.expectApproxEqAbs(@as(f32, 0), out[4 * 8 + 4], 1e-4);
}

test "a stroke is the union of its pieces: no seams, no doubled ink" {
    var p: Polygons = .{ .gpa = testing.allocator };
    defer p.deinit();
    // An L with a round join and round caps, 2 pixels wide.
    try stroke(&p, &.{ .{ 4, 4 }, .{ 4, 16 }, .{ 16, 16 } }, false, .{ .half = 1, .cap = .round, .join = .round });
    var out: [20 * 20]f32 = undefined;
    try p.fill(.nonzero, 20, 20, &out);
    for (out) |v| try testing.expect(v <= 1);
    try testing.expectApproxEqAbs(@as(f32, 1), out[10 * 20 + 3], 0.07); // on the vertical
    try testing.expectApproxEqAbs(@as(f32, 1), out[16 * 20 + 10], 0.07); // on the horizontal
    try testing.expect(out[16 * 20 + 4] > 0.9); // the corner
    try testing.expect(out[10 * 20 + 8] < 0.01); // inside the L
    // Ink about the stroke's area: 2 wide × 24 long, plus the round ends.
    var ink: f32 = 0;
    for (out) |v| ink += v;
    try testing.expectApproxEqAbs(@as(f32, 2 * 24 + std.math.pi), ink, 1.5);
}

test "dashes cut a line, and a closed line walks back to its start" {
    const Sink = struct {
        lens: std.ArrayList(f32) = .empty,
        fn dash(s: *@This(), pts: []const Point) !void {
            var l: f32 = 0;
            for (pts[1..], 0..) |q, i| l += dist(pts[i], q);
            try s.lens.append(testing.allocator, l);
        }
    };
    var s: Sink = .{};
    defer s.lens.deinit(testing.allocator);
    try dash(testing.allocator, &.{ .{ 0, 0 }, .{ 10, 0 } }, false, &.{ 2, 1 }, 0, &s);
    try testing.expectEqual(@as(usize, 4), s.lens.items.len);
    try testing.expectApproxEqAbs(@as(f32, 2), s.lens.items[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), s.lens.items[3], 1e-4);
    // An offset starts inside the pattern.
    s.lens.clearRetainingCapacity();
    try dash(testing.allocator, &.{ .{ 0, 0 }, .{ 10, 0 } }, false, &.{ 2, 1 }, 1, &s);
    try testing.expectApproxEqAbs(@as(f32, 1), s.lens.items[0], 1e-4);
    // Round the square: all its edge is walked.
    s.lens.clearRetainingCapacity();
    try dash(testing.allocator, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } }, true, &.{ 2, 2 }, 0, &s);
    var ink: f32 = 0;
    for (s.lens.items) |l| ink += l;
    try testing.expectApproxEqAbs(@as(f32, 8), ink, 1e-3);
}

test "a region is all that's touched" {
    var p: Polygons = .{ .gpa = testing.allocator };
    defer p.deinit();
    try p.polygon(&.{ .{ 2, 2 }, .{ 4, 2 }, .{ 4, 4 }, .{ 2, 4 } });
    var out: [64]f32 = @splat(7);
    const r = try p.fillRegion(.nonzero, 8, 8, &out, null);
    try testing.expectEqual(Region{ .x0 = 2, .y0 = 2, .x1 = 4, .y1 = 4 }, r);
    try testing.expectEqual(@as(f32, 7), out[0]);
    try testing.expectEqual(@as(f32, 1), out[2 * 8 + 2]);
    // A limit cuts it, on whole pixels.
    p.clear();
    try p.polygon(&.{ .{ 0, 0 }, .{ 8, 0 }, .{ 8, 8 }, .{ 0, 8 } });
    const c = try p.fillRegion(.nonzero, 8, 8, &out, .{ 6, 6, 7, 7 });
    try testing.expectEqual(Region{ .x0 = 6, .y0 = 6, .x1 = 7, .y1 = 7 }, c);
    try testing.expectEqual(@as(f32, 1), out[6 * 8 + 6]);
    try testing.expectEqual(@as(f32, 7), out[5 * 8 + 5]);
}

test "a miter reaches its tip; past the limit it's a bevel" {
    var p: Polygons = .{ .gpa = testing.allocator };
    defer p.deinit();
    try stroke(&p, &.{ .{ 2, 2 }, .{ 10, 2 }, .{ 10, 10 } }, false, .{ .half = 1.5 });
    var out: [14 * 14]f32 = undefined;
    try p.fill(.nonzero, 14, 14, &out);
    try testing.expect(out[0 * 14 + 11] > 0.2); // the miter's corner at (11.5, 0.5)
    p.clear();
    try stroke(&p, &.{ .{ 2, 2 }, .{ 10, 2 }, .{ 10, 10 } }, false, .{ .half = 1.5, .join = .bevel });
    try p.fill(.nonzero, 14, 14, &out);
    try testing.expect(out[0 * 14 + 11] < 0.2);
}
