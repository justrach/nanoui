//! SVG documents to pixels, for icons and marks (`ui.svg`): `svg`, `g`,
//! `path`, `rect`, `circle`, `ellipse`, `line`, `polyline` and `polygon`,
//! with fills (nonzero, evenodd), strokes (width, caps, joins, miter
//! limit), opacity, `transform` and `style="…"`, inherited down groups.
//! Colors are named, `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`,
//! `var(--x, fallback)` and `currentColor`, which the caller picks. What it
//! doesn't draw (gradients, clip paths, masks, text) is skipped: a fill by
//! `url(#…)` paints nothing, and `defs` and the like are passed over.
const std = @import("std");
const geom = @import("svg_geom.zig");
const svg_path = @import("svg_path.zig");
const raster = @import("svg_raster.zig");
const Transform = geom.Transform;
const Flattener = geom.Flattener;

pub const Options = struct {
    /// The picture's size in pixels; the document's viewBox is fitted in
    /// it, centered, keeping its proportions.
    width: u32,
    height: u32,
    /// `currentColor`, straight RGBA from 0 to 1.
    current: [4]f32 = .{ 0, 0, 0, 1 },
};

const Paint = union(enum) { none, current, color: [4]f32 };

const Style = struct {
    fill: Paint = .{ .color = .{ 0, 0, 0, 1 } },
    stroke: Paint = .none,
    stroke_width: f32 = 1,
    cap: raster.Cap = .butt,
    join: raster.Join = .miter,
    miter_limit: f32 = 4,
    rule: raster.Rule = .nonzero,
    opacity: f32 = 1,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    t: Transform = .{},
    hidden: bool = false,
};

/// Elements whose content isn't drawn where it is.
const skipped = [_][]const u8{ "defs", "clipPath", "mask", "linearGradient", "radialGradient", "pattern", "symbol", "marker", "title", "desc", "metadata", "style", "script", "text", "filter", "foreignObject" };

/// The document's own size: its viewBox's, else its width and height.
pub fn size(src: []const u8) ?[2]f32 {
    var it: Tags = .{ .s = src };
    while (it.next()) |tag| if (tag.kind == .open and std.mem.eql(u8, tag.name, "svg")) {
        if (tag.attr("viewBox")) |vb| if (box(vb)) |b| return .{ b[2], b[3] };
        const w = length(tag.attr("width") orelse "") orelse return null;
        const h = length(tag.attr("height") orelse "") orelse return null;
        return .{ w, h };
    };
    return null;
}

/// The document drawn into premultiplied BGRA, `width` × `height`.
pub fn render(gpa: std.mem.Allocator, src: []const u8, opts: Options) ![]u8 {
    const w: usize = opts.width;
    const h: usize = opts.height;
    if (w == 0 or h == 0 or w * h > 4096 * 4096) return error.BadSize;
    const acc = try gpa.alloc(f32, w * h * 4);
    defer gpa.free(acc);
    @memset(acc, 0);
    const cov = try gpa.alloc(f32, w * h);
    defer gpa.free(cov);
    var f: Flattener = .{ .gpa = gpa };
    defer f.deinit();
    var polys: raster.Polygons = .{ .gpa = gpa };
    defer polys.deinit();

    var stack: [32]Style = undefined;
    var depth: usize = 0;
    var skip_depth: usize = 0;
    var it: Tags = .{ .s = src };
    var seen_root = false;
    while (it.next()) |tag| {
        if (skip_depth > 0) {
            switch (tag.kind) {
                .open => skip_depth += 1,
                .close => skip_depth -= 1,
                .empty => {},
            }
            continue;
        }
        if (tag.kind == .close) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (isSkipped(tag.name)) {
            if (tag.kind == .open) skip_depth = 1;
            continue;
        }
        var st: Style = if (depth > 0) stack[depth - 1] else .{};
        if (!seen_root and std.mem.eql(u8, tag.name, "svg")) {
            seen_root = true;
            st.t = fit(tag, @floatFromInt(w), @floatFromInt(h));
        }
        apply(&st, tag);
        if (tag.kind == .open) {
            if (depth == stack.len) return error.TooDeep;
            stack[depth] = st;
            depth += 1;
        }
        if (st.hidden or !seen_root) continue;
        f.clear();
        f.t = st.t;
        if (!try shape(&f, tag)) continue;
        try paint(&f, &polys, st, opts.current, w, h, cov, acc);
    }
    if (!seen_root) return error.NotSvg;
    const out = try gpa.alloc(u8, w * h * 4);
    for (0..w * h) |i| {
        const px = acc[i * 4 ..][0..4];
        out[i * 4 + 0] = byte(px[2]);
        out[i * 4 + 1] = byte(px[1]);
        out[i * 4 + 2] = byte(px[0]);
        out[i * 4 + 3] = byte(px[3]);
    }
    return out;
}

fn byte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
}

fn isSkipped(name: []const u8) bool {
    for (skipped) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// The viewBox fitted into the picture, centered (xMidYMid meet).
fn fit(tag: Tag, w: f32, h: f32) Transform {
    const b = if (tag.attr("viewBox")) |vb| box(vb) else null;
    const vb = b orelse [4]f32{ 0, 0, length(tag.attr("width") orelse "") orelse w, length(tag.attr("height") orelse "") orelse h };
    if (vb[2] <= 0 or vb[3] <= 0) return .{};
    const k = @min(w / vb[2], h / vb[3]);
    return Transform.translate(-vb[0], -vb[1]).then(Transform.scale(k, k)).then(Transform.translate((w - vb[2] * k) / 2, (h - vb[3] * k) / 2));
}

fn box(s: []const u8) ?[4]f32 {
    var sc: svg_path.Scanner = .{ .s = s };
    var b: [4]f32 = undefined;
    for (&b) |*v| v.* = sc.number() orelse return null;
    return b;
}

/// A length's number; units other than px are taken as user units, and
/// `em` or `%` as not given.
fn length(s: []const u8) ?f32 {
    const t = std.mem.trim(u8, s, " \t\n");
    if (std.mem.endsWith(u8, t, "em") or std.mem.endsWith(u8, t, "%")) return null;
    var sc: svg_path.Scanner = .{ .s = t };
    return sc.number();
}

/// Builds the element's outline; false if it isn't a shape.
fn shape(f: *Flattener, tag: Tag) !bool {
    const n = tag.name;
    const num = struct {
        fn of(t: Tag, k: []const u8) f32 {
            return length(t.attr(k) orelse "") orelse 0;
        }
    }.of;
    if (std.mem.eql(u8, n, "path")) {
        try svg_path.path(f, tag.attr("d") orelse return false);
    } else if (std.mem.eql(u8, n, "rect")) {
        const rx = if (tag.attr("rx")) |v| length(v) else null;
        const ry = if (tag.attr("ry")) |v| length(v) else null;
        try svg_path.rect(f, num(tag, "x"), num(tag, "y"), num(tag, "width"), num(tag, "height"), rx, ry);
    } else if (std.mem.eql(u8, n, "circle")) {
        const r = num(tag, "r");
        try svg_path.ellipse(f, num(tag, "cx"), num(tag, "cy"), r, r);
    } else if (std.mem.eql(u8, n, "ellipse")) {
        try svg_path.ellipse(f, num(tag, "cx"), num(tag, "cy"), num(tag, "rx"), num(tag, "ry"));
    } else if (std.mem.eql(u8, n, "line")) {
        try f.moveTo(.{ num(tag, "x1"), num(tag, "y1") });
        try f.lineTo(.{ num(tag, "x2"), num(tag, "y2") });
    } else if (std.mem.eql(u8, n, "polyline") or std.mem.eql(u8, n, "polygon")) {
        try svg_path.poly(f, tag.attr("points") orelse return false, n[4] == 'g');
    } else return false;
    return f.subpaths.items.len > 0;
}

fn paint(f: *Flattener, polys: *raster.Polygons, st: Style, current: [4]f32, w: usize, h: usize, cov: []f32, acc: []f32) !void {
    const fill_color = colorOf(st.fill, current);
    if (fill_color) |c| {
        polys.clear();
        // Every subpath is closed for filling.
        for (f.subpaths.items) |s| try polys.polygon(f.of(s));
        try polys.fill(st.rule, w, h, cov);
        composite(acc, cov, c, st.opacity * st.fill_opacity);
    }
    const stroke_color = colorOf(st.stroke, current);
    if (stroke_color) |c| if (st.stroke_width > 0) {
        polys.clear();
        const half = st.stroke_width * st.t.lengthScale() / 2;
        for (f.subpaths.items) |s| try raster.stroke(polys, f.of(s), s.closed, .{ .half = half, .cap = st.cap, .join = st.join, .miter_limit = st.miter_limit });
        try polys.fill(.nonzero, w, h, cov);
        composite(acc, cov, c, st.opacity * st.stroke_opacity);
    };
}

fn colorOf(p: Paint, current: [4]f32) ?[4]f32 {
    return switch (p) {
        .none => null,
        .current => current,
        .color => |c| c,
    };
}

/// Source over, premultiplied.
fn composite(acc: []f32, cov: []const f32, c: [4]f32, opacity: f32) void {
    const a = c[3] * opacity;
    if (a <= 0) return;
    for (cov, 0..) |k, i| {
        if (k <= 0) continue;
        const sa = a * k;
        const d = acc[i * 4 ..][0..4];
        d[0] = c[0] * sa + d[0] * (1 - sa);
        d[1] = c[1] * sa + d[1] * (1 - sa);
        d[2] = c[2] * sa + d[2] * (1 - sa);
        d[3] = sa + d[3] * (1 - sa);
    }
}

/// The element's own presentation attributes and `style`, over what it
/// inherits.
fn apply(st: *Style, tag: Tag) void {
    var it = tag.attrs();
    while (it.next()) |a| property(st, a.name, a.value);
    if (tag.attr("style")) |css| {
        var decls = std.mem.splitScalar(u8, css, ';');
        while (decls.next()) |d| {
            const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
            property(st, std.mem.trim(u8, d[0..colon], " \t\n"), std.mem.trim(u8, d[colon + 1 ..], " \t\n"));
        }
    }
}

fn property(st: *Style, name: []const u8, v: []const u8) void {
    const eq = std.mem.eql;
    if (eq(u8, name, "fill")) {
        if (parsePaint(v)) |p| st.fill = p;
    } else if (eq(u8, name, "stroke")) {
        if (parsePaint(v)) |p| st.stroke = p;
    } else if (eq(u8, name, "stroke-width")) {
        if (length(v)) |x| st.stroke_width = x;
    } else if (eq(u8, name, "stroke-linecap")) {
        st.cap = std.meta.stringToEnum(raster.Cap, v) orelse st.cap;
    } else if (eq(u8, name, "stroke-linejoin")) {
        st.join = if (eq(u8, v, "miter-clip") or eq(u8, v, "arcs")) .miter else std.meta.stringToEnum(raster.Join, v) orelse st.join;
    } else if (eq(u8, name, "stroke-miterlimit")) {
        if (length(v)) |x| st.miter_limit = @max(1, x);
    } else if (eq(u8, name, "fill-rule")) {
        st.rule = std.meta.stringToEnum(raster.Rule, v) orelse st.rule;
    } else if (eq(u8, name, "opacity")) {
        if (length(v)) |x| st.opacity *= std.math.clamp(x, 0, 1);
    } else if (eq(u8, name, "fill-opacity")) {
        if (length(v)) |x| st.fill_opacity = std.math.clamp(x, 0, 1);
    } else if (eq(u8, name, "stroke-opacity")) {
        if (length(v)) |x| st.stroke_opacity = std.math.clamp(x, 0, 1);
    } else if (eq(u8, name, "transform")) {
        st.t = transform(v).then(st.t);
    } else if (eq(u8, name, "display")) {
        if (eq(u8, v, "none")) st.hidden = true;
    } else if (eq(u8, name, "visibility")) {
        st.hidden = eq(u8, v, "hidden") or eq(u8, v, "collapse");
    }
}

/// `translate`, `scale`, `rotate`, `skewX`, `skewY` and `matrix`, in order.
fn transform(s: []const u8) Transform {
    var t: Transform = .{};
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, '(')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, ')') orelse break;
        const name = std.mem.trim(u8, rest[0..open], " \t\n,");
        var sc: svg_path.Scanner = .{ .s = rest[open + 1 .. close] };
        var a: [6]f32 = undefined;
        var n: usize = 0;
        while (n < 6) : (n += 1) a[n] = sc.number() orelse break;
        const eq = std.mem.eql;
        const m: Transform = if (eq(u8, name, "translate") and n >= 1)
            .translate(a[0], if (n > 1) a[1] else 0)
        else if (eq(u8, name, "scale") and n >= 1)
            .scale(a[0], if (n > 1) a[1] else a[0])
        else if (eq(u8, name, "rotate") and n >= 1)
            (if (n >= 3) Transform.translate(-a[1], -a[2]).then(.rotate(a[0])).then(.translate(a[1], a[2])) else Transform.rotate(a[0]))
        else if (eq(u8, name, "skewX") and n >= 1)
            .{ .m = .{ 1, 0, @tan(a[0] * std.math.pi / 180), 1, 0, 0 } }
        else if (eq(u8, name, "skewY") and n >= 1)
            .{ .m = .{ 1, @tan(a[0] * std.math.pi / 180), 0, 1, 0, 0 } }
        else if (eq(u8, name, "matrix") and n == 6)
            .{ .m = a }
        else
            .{};
        // Each applies before those to its left.
        t = m.then(t);
        rest = rest[close + 1 ..];
    }
    return t;
}

fn parsePaint(v_in: []const u8) ?Paint {
    var v = std.mem.trim(u8, v_in, " \t\n");
    // A custom property's fallback stands for it.
    if (std.mem.startsWith(u8, v, "var(")) {
        const comma = std.mem.indexOfScalar(u8, v, ',') orelse return null;
        const close = std.mem.lastIndexOfScalar(u8, v, ')') orelse return null;
        if (close < comma) return null;
        v = std.mem.trim(u8, v[comma + 1 .. close], " \t\n");
    }
    if (std.mem.eql(u8, v, "none") or std.mem.eql(u8, v, "transparent") or std.mem.startsWith(u8, v, "url(")) return .none;
    if (std.ascii.eqlIgnoreCase(v, "currentColor")) return .current;
    return if (color(v)) |c| .{ .color = c } else null;
}

pub fn color(v: []const u8) ?[4]f32 {
    if (v.len > 0 and v[0] == '#') {
        const hex = v[1..];
        const x = std.fmt.parseInt(u32, hex, 16) catch return null;
        return switch (hex.len) {
            3 => .{ ch((x >> 8 & 15) * 17), ch((x >> 4 & 15) * 17), ch((x & 15) * 17), 1 },
            4 => .{ ch((x >> 12 & 15) * 17), ch((x >> 8 & 15) * 17), ch((x >> 4 & 15) * 17), ch((x & 15) * 17) },
            6 => .{ ch(x >> 16 & 255), ch(x >> 8 & 255), ch(x & 255), 1 },
            8 => .{ ch(x >> 24 & 255), ch(x >> 16 & 255), ch(x >> 8 & 255), ch(x & 255) },
            else => null,
        };
    }
    if (std.mem.startsWith(u8, v, "rgb")) {
        const open = std.mem.indexOfScalar(u8, v, '(') orelse return null;
        var sc: svg_path.Scanner = .{ .s = v[open + 1 ..] };
        var c: [4]f32 = .{ 0, 0, 0, 1 };
        for (0..3) |i| c[i] = (sc.number() orelse return null) / 255;
        if (sc.number()) |a| c[3] = a;
        return c;
    }
    const names = [_]struct { []const u8, u32 }{
        .{ "black", 0x000000 }, .{ "white", 0xffffff }, .{ "red", 0xff0000 },   .{ "green", 0x008000 },
        .{ "blue", 0x0000ff },  .{ "gray", 0x808080 },  .{ "grey", 0x808080 },  .{ "yellow", 0xffff00 },
        .{ "orange", 0xffa500 }, .{ "purple", 0x800080 }, .{ "silver", 0xc0c0c0 }, .{ "lime", 0x00ff00 },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(v, n[0])) return .{ ch(n[1] >> 16 & 255), ch(n[1] >> 8 & 255), ch(n[1] & 255), 1 };
    return null;
}

fn ch(x: u32) f32 {
    return @as(f32, @floatFromInt(x)) / 255;
}

const Tag = @import("svg_tags.zig").Tag;
const Tags = @import("svg_tags.zig").Tags;

test {
    _ = geom;
    _ = svg_path;
    _ = raster;
    _ = @import("svg_tags.zig");
    _ = @import("svg_tests.zig");
}
