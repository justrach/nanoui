//! What SVG shapes are painted with, onto premultiplied floats: one color, or
//! a linear or radial gradient (units, transform, spread, stops, `href`
//! inheritance), read from the document by id and kept in a table of 256
//! colors.
const std = @import("std");
const geom = @import("svg_geom.zig");
const style = @import("svg_style.zig");
const colors = @import("svg_colors.zig");
const raster = @import("svg_raster.zig");
const tags = @import("svg_tags.zig");
const Tag = tags.Tag;
const Tags = tags.Tags;
const Transform = geom.Transform;
const Region = raster.Region;

const lut_size = 256;

const Coord = struct {
    v: f32 = 0,
    pct: bool = false,

    fn of(s: []const u8) ?Coord {
        const t = std.mem.trim(u8, s, " \t\r\n");
        if (std.mem.endsWith(u8, t, "%")) return .{ .v = (std.fmt.parseFloat(f32, t[0 .. t.len - 1]) catch return null) / 100, .pct = true };
        return .{ .v = style.length(t, 0) orelse return null };
    }

    /// In bounding box units a fraction; else user units, a percentage of `ref`.
    fn resolve(c: Coord, bbox: bool, ref: f32) f32 {
        if (bbox) return c.v;
        return if (c.pct) c.v * ref else c.v;
    }
};

const Spread = enum { pad, reflect, repeat };

/// A gradient, its attributes gathered up its `href` chain.
pub const Gradient = struct {
    radial: bool = false,
    bbox: bool = true,
    t: Transform = .{},
    spread: Spread = .pad,
    x1: ?Coord = null,
    y1: ?Coord = null,
    x2: ?Coord = null,
    y2: ?Coord = null,
    cx: ?Coord = null,
    cy: ?Coord = null,
    r: ?Coord = null,
    fx: ?Coord = null,
    fy: ?Coord = null,
    fr: ?Coord = null,
    have_units: bool = false,
    have_t: bool = false,
    have_spread: bool = false,
    stops: u32 = 0,
    /// One stop's color (or none: paints nothing).
    solid: ?[4]f32 = null,
    /// Premultiplied.
    lut: [lut_size][4]f32 = undefined,
};

pub const Stop = struct { at: f32, c: [4]f32 };

/// Reads the gradient at `start`, following `href` for what it doesn't say.
pub fn load(gpa: std.mem.Allocator, src: []const u8, ids: *const std.StringHashMapUnmanaged(usize), start: usize, sheet: ?*const style.Sheet, current: [4]f32) !?Gradient {
    var g: Gradient = .{};
    var stops: std.ArrayList(Stop) = .empty;
    defer stops.deinit(gpa);
    var at: ?usize = start;
    var hops: u8 = 0;
    var first = true;
    while (at) |offset| : (hops += 1) {
        if (hops > 8) break;
        var it: Tags = .{ .s = src, .i = offset };
        const tag = it.next() orelse break;
        const radial = std.mem.eql(u8, tag.name, "radialGradient");
        if (!radial and !std.mem.eql(u8, tag.name, "linearGradient")) {
            if (first) return null;
            break;
        }
        if (first) g.radial = radial;
        first = false;
        gather(&g, tag, radial);
        if (stops.items.len == 0 and tag.kind == .open) try readStops(gpa, &it, sheet, current, &stops);
        const h = tag.href() orelse break;
        at = if (h.len > 1 and h[0] == '#') ids.get(h[1..]) else null;
    }
    g.stops = @intCast(stops.items.len);
    if (stops.items.len == 0) return g;
    if (stops.items.len == 1) {
        g.solid = stops.items[0].c;
        return g;
    }
    fillTable(&g, stops.items);
    return g;
}

fn gather(g: *Gradient, tag: Tag, radial: bool) void {
    const eq = std.mem.eql;
    var it = tag.attrs();
    while (it.next()) |a| {
        const n = a.name;
        const v = a.value;
        if (eq(u8, n, "gradientUnits")) {
            if (!g.have_units) g.bbox = !eq(u8, v, "userSpaceOnUse");
            g.have_units = true;
        } else if (eq(u8, n, "gradientTransform")) {
            if (!g.have_t) g.t = style.transform(v);
            g.have_t = true;
        } else if (eq(u8, n, "spreadMethod")) {
            if (!g.have_spread) g.spread = std.meta.stringToEnum(Spread, v) orelse .pad;
            g.have_spread = true;
        } else if (radial) {
            if (eq(u8, n, "cx") and g.cx == null) g.cx = Coord.of(v);
            if (eq(u8, n, "cy") and g.cy == null) g.cy = Coord.of(v);
            if (eq(u8, n, "r") and g.r == null) g.r = Coord.of(v);
            if (eq(u8, n, "fx") and g.fx == null) g.fx = Coord.of(v);
            if (eq(u8, n, "fy") and g.fy == null) g.fy = Coord.of(v);
            if (eq(u8, n, "fr") and g.fr == null) g.fr = Coord.of(v);
        } else {
            if (eq(u8, n, "x1") and g.x1 == null) g.x1 = Coord.of(v);
            if (eq(u8, n, "y1") and g.y1 == null) g.y1 = Coord.of(v);
            if (eq(u8, n, "x2") and g.x2 == null) g.x2 = Coord.of(v);
            if (eq(u8, n, "y2") and g.y2 == null) g.y2 = Coord.of(v);
        }
    }
}

fn readStops(gpa: std.mem.Allocator, it: *Tags, sheet: ?*const style.Sheet, current: [4]f32, out: *std.ArrayList(Stop)) !void {
    var depth: usize = 1;
    var last: f32 = 0;
    while (it.next()) |tag| {
        switch (tag.kind) {
            .open => depth += 1,
            .close => {
                depth -= 1;
                if (depth == 0) return;
                continue;
            },
            .empty => {},
        }
        if (depth > 2 or !std.mem.eql(u8, tag.name, "stop")) continue;
        const color = stopColor(tag, sheet, current);
        const raw = tag.attr("offset") orelse "0";
        const c = Coord.of(raw) orelse Coord{};
        // Each is at least where the one before it is.
        const offset = @max(last, std.math.clamp(c.v, 0, 1));
        last = offset;
        try out.append(gpa, .{ .at = offset, .c = color });
    }
}

fn stopColor(tag: Tag, sheet: ?*const style.Sheet, current: [4]f32) [4]f32 {
    var c: [4]f32 = .{ 0, 0, 0, 1 };
    var opacity: f32 = 1;
    const read = struct {
        fn one(name: []const u8, v_in: []const u8, cc: *[4]f32, op: *f32, cur: [4]f32) void {
            const v = std.mem.trim(u8, v_in, " \t\r\n");
            if (std.mem.eql(u8, name, "stop-color")) {
                if (std.ascii.eqlIgnoreCase(v, "currentColor")) {
                    cc.* = cur;
                } else if (colors.parse(v)) |k| cc.* = k;
            } else if (std.mem.eql(u8, name, "stop-opacity")) {
                if (std.fmt.parseFloat(f32, v)) |n| {
                    op.* = std.math.clamp(n, 0, 1);
                } else |_| {}
            }
        }
        fn decls(text: []const u8, cc: *[4]f32, op: *f32, cur: [4]f32) void {
            var it = std.mem.splitScalar(u8, text, ';');
            while (it.next()) |d| {
                const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
                one(std.mem.trim(u8, d[0..colon], " \t\r\n"), d[colon + 1 ..], cc, op, cur);
            }
        }
    };
    if (tag.attr("stop-color")) |v| read.one("stop-color", v, &c, &opacity, current);
    if (tag.attr("stop-opacity")) |v| read.one("stop-opacity", v, &c, &opacity, current);
    if (sheet) |sh| for (sh.rules.items) |r| if (style.Sheet.selects(r.selectors, tag)) read.decls(r.decls, &c, &opacity, current);
    if (tag.attr("style")) |css| read.decls(css, &c, &opacity, current);
    c[3] *= opacity;
    return c;
}

fn fillTable(g: *Gradient, stops: []const Stop) void {
    var at: usize = 0;
    for (0..lut_size) |i| {
        const t = @as(f32, @floatFromInt(i)) / (lut_size - 1);
        while (at + 1 < stops.len and stops[at + 1].at <= t) at += 1;
        var c: [4]f32 = undefined;
        if (t <= stops[0].at) {
            c = stops[0].c;
        } else if (at + 1 >= stops.len) {
            c = stops[stops.len - 1].c;
        } else {
            const a = stops[at];
            const b = stops[at + 1];
            const span = b.at - a.at;
            const k = if (span > 0) (t - a.at) / span else 1;
            for (0..4) |j| c[j] = a.c[j] + (b.c[j] - a.c[j]) * k;
        }
        g.lut[i] = .{ c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3] };
    }
}

/// A shape's paint, in pixels.
pub const Source = union(enum) {
    /// Straight RGBA.
    color: [4]f32,
    gradient: Placed,
};

/// A gradient resolved for one shape.
pub const Placed = struct {
    g: *const Gradient,
    /// Pixels to gradient space.
    inv: Transform,
    // Linear: the start and the vector scaled by one over its length squared.
    x1: f32 = 0,
    y1: f32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    // Radial.
    cx: f32 = 0,
    cy: f32 = 0,
    r: f32 = 0,
    fx: f32 = 0,
    fy: f32 = 0,
    fr: f32 = 0,

    fn colorAt(p: *const Placed, x: f32, y: f32) [4]f32 {
        const q = p.inv.apply(.{ x, y });
        var t: f32 = undefined;
        if (p.g.radial) {
            t = p.radialT(q[0], q[1]);
        } else {
            t = (q[0] - p.x1) * p.dx + (q[1] - p.y1) * p.dy;
        }
        t = switch (p.g.spread) {
            .pad => std.math.clamp(t, 0, 1),
            .repeat => t - @floor(t),
            .reflect => blk: {
                const m = @mod(t, 2);
                break :blk if (m > 1) 2 - m else m;
            },
        };
        return p.g.lut[@intFromFloat(t * (lut_size - 1) + 0.5)];
    }

    fn radialT(p: *const Placed, x: f32, y: f32) f32 {
        const dx = x - p.fx;
        const dy = y - p.fy;
        const dd = dx * dx + dy * dy;
        if (dd == 0) return 0;
        const cdx = p.fx - p.cx;
        const cdy = p.fy - p.cy;
        const b = cdx * dx + cdy * dy;
        const a = p.r * p.r - (cdx * cdx + cdy * cdy);
        const s = (-b + @sqrt(@max(0, b * b + dd * a))) / dd;
        if (s <= 0) return 1;
        const base = 1 / s;
        return if (p.fr > 0) p.fr / p.r + (1 - p.fr / p.r) * base else base;
    }
};

/// The gradient placed for a shape with bounding box `bbox` (x, y, w, h in
/// user units) under `ctm`, with `vp` for percentages; null when it paints
/// nothing (a flat shape's box, a flat transform).
pub fn place(g: *const Gradient, ctm: Transform, bbox: [4]f32, vp: [2]f32) ?Placed {
    var m = g.t;
    if (g.bbox) {
        if (bbox[2] <= 0 or bbox[3] <= 0) return null;
        m = m.then(.{ .m = .{ bbox[2], 0, 0, bbox[3], bbox[0], bbox[1] } });
    }
    const inv = m.then(ctm).inverse() orelse return null;
    var out: Placed = .{ .g = g, .inv = inv };
    const b = g.bbox;
    if (g.radial) {
        const diag = @sqrt((vp[0] * vp[0] + vp[1] * vp[1]) / 2);
        out.cx = (g.cx orelse Coord{ .v = 0.5, .pct = true }).resolve(b, vp[0]);
        out.cy = (g.cy orelse Coord{ .v = 0.5, .pct = true }).resolve(b, vp[1]);
        out.r = (g.r orelse Coord{ .v = 0.5, .pct = true }).resolve(b, diag);
        if (out.r <= 0) return null;
        out.fx = if (g.fx) |c| c.resolve(b, vp[0]) else out.cx;
        out.fy = if (g.fy) |c| c.resolve(b, vp[1]) else out.cy;
        out.fr = if (g.fr) |c| c.resolve(b, diag) else 0;
        // A focal point outside the circle is brought just inside it.
        const fdx = out.fx - out.cx;
        const fdy = out.fy - out.cy;
        const fl = @sqrt(fdx * fdx + fdy * fdy);
        if (fl >= out.r) {
            out.fx = out.cx + fdx / fl * out.r * 0.995;
            out.fy = out.cy + fdy / fl * out.r * 0.995;
        }
        return out;
    }
    out.x1 = (g.x1 orelse Coord{}).resolve(b, vp[0]);
    out.y1 = (g.y1 orelse Coord{}).resolve(b, vp[1]);
    const x2 = (g.x2 orelse Coord{ .v = 1, .pct = true }).resolve(b, vp[0]);
    const y2 = (g.y2 orelse Coord{}).resolve(b, vp[1]);
    const vx = x2 - out.x1;
    const vy = y2 - out.y1;
    const len2 = vx * vx + vy * vy;
    // The two ends together: the last stop's color everywhere.
    if (len2 <= 0) {
        out.dx = 0;
        out.dy = 0;
        out.x1 = -1;
        return out;
    }
    out.dx = vx / len2;
    out.dy = vy / len2;
    return out;
}

/// Source over `acc` (w wide, premultiplied) where `cov` covers, in `r`.
pub fn composite(acc: []f32, cov: []const f32, w: usize, r: Region, src: Source, opacity: f32) void {
    switch (src) {
        .color => |c| {
            const a = c[3] * opacity;
            if (a <= 0) return;
            for (r.y0..r.y1) |y| {
                const row = y * w;
                for (r.x0..r.x1) |x| {
                    const k = cov[row + x];
                    if (k <= 0) continue;
                    const sa = a * k;
                    const d = acc[(row + x) * 4 ..][0..4];
                    const ia = 1 - sa;
                    d[0] = c[0] * sa + d[0] * ia;
                    d[1] = c[1] * sa + d[1] * ia;
                    d[2] = c[2] * sa + d[2] * ia;
                    d[3] = sa + d[3] * ia;
                }
            }
        },
        .gradient => |*p| {
            for (r.y0..r.y1) |y| {
                const row = y * w;
                const fy = @as(f32, @floatFromInt(y)) + 0.5;
                for (r.x0..r.x1) |x| {
                    const k = cov[row + x];
                    if (k <= 0) continue;
                    const c = p.colorAt(@as(f32, @floatFromInt(x)) + 0.5, fy);
                    const m = k * opacity;
                    const d = acc[(row + x) * 4 ..][0..4];
                    const ia = 1 - c[3] * m;
                    d[0] = c[0] * m + d[0] * ia;
                    d[1] = c[1] * m + d[1] * ia;
                    d[2] = c[2] * m + d[2] * ia;
                    d[3] = c[3] * m + d[3] * ia;
                }
            }
        },
    }
}

test "a linear gradient across a shape's box runs from stop to stop" {
    const gpa = std.testing.allocator;
    const src =
        \\<linearGradient id="a"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff" stop-opacity=".5"/></linearGradient>
    ;
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    defer ids.deinit(gpa);
    const g = (try load(gpa, src, &ids, 0, null, .{ 0, 0, 0, 1 })).?;
    const p = place(&g, .{}, .{ 10, 0, 100, 10 }, .{ 100, 100 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), p.colorAt(10, 5)[3], 0.01);
    const end = p.colorAt(110, 5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), end[3], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), end[0], 0.01); // premultiplied
    // Padded past its ends.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.colorAt(500, 5)[3], 0.01);
}

test "a radial gradient: its center and its edge, and spreads" {
    const gpa = std.testing.allocator;
    const src =
        \\<radialGradient id="a" cx="50" cy="50" r="50" gradientUnits="userSpaceOnUse" spreadMethod="reflect"><stop offset="0" stop-color="#f00"/><stop offset="100%" stop-color="#00f"/></radialGradient>
    ;
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    defer ids.deinit(gpa);
    const g = (try load(gpa, src, &ids, 0, null, .{ 0, 0, 0, 1 })).?;
    const p = place(&g, .{}, .{ 0, 0, 0, 0 }, .{ 100, 100 }).?;
    try std.testing.expect(p.colorAt(50, 50)[0] > 0.95);
    try std.testing.expect(p.colorAt(100, 50)[2] > 0.95);
    // Reflected: as far past the edge as inside it.
    try std.testing.expect(p.colorAt(150, 50)[0] > 0.95);
}
