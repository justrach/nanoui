//! An inline `<svg>` as markup nanoui's rasterizer draws on its own: every
//! element's cascaded paint written out as attributes, `<defs>` and the targets
//! of `use`, `fill`, `clip-path` and `mask` from elsewhere in the document
//! brought along, and what the rasterizer has no use for left behind. Made
//! again when what it's made of changes; a change that comes out the same keeps
//! the same key, so its pixels are kept too.
const std = @import("std");
const dom = @import("../dom.zig");
const css = @import("../css/style.zig");
const cascade = @import("../css/cascade.zig");
const layout = @import("../layout/layout.zig");
const Page = @import("../page.zig").Page;
const Node = dom.Node;
const Style = css.Style;
const Allocator = std.mem.Allocator;

const max_depth = 96;

const Entry = struct { bytes: []u8, key: []u8, sig: u64 };

/// What each drawn `<svg>` was last made into. A node's `image` and `image_key`
/// point here.
pub const Cache = struct {
    map: std.AutoHashMapUnmanaged(*Node, Entry) = .empty,
    /// The outermost `<svg>`s of the document, as of `roots_of`.
    roots: std.ArrayList(*Node) = .empty,
    roots_of: u32 = 0,
    roots_known: bool = false,

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        var it = c.map.valueIterator();
        while (it.next()) |e| {
            gpa.free(e.bytes);
            gpa.free(e.key);
        }
        c.map.deinit(gpa);
        c.roots.deinit(gpa);
    }
};

/// Brings every `<svg>` that has a box up to date. Style and layout are.
pub fn refresh(p: *Page) void {
    p.doc.svg_dirty = false;
    // Every rebuild of the list comes here: walk the document only when it changed.
    const c = &p.svgs;
    if (!c.roots_known or c.roots_of != p.doc.generation) {
        c.roots.clearRetainingCapacity();
        var at = p.doc.node.first_child;
        while (at) |n| {
            if (n.kind == .element and n.ns == .svg and n.isTag("svg")) {
                c.roots.append(p.gpa, n) catch {};
                at = n.nextSkippingChildren(p.doc.node);
            } else at = n.nextInTree(p.doc.node);
        }
        c.roots_of = p.doc.generation;
        c.roots_known = true;
    }
    for (c.roots.items) |n| one(p, n);
}

fn one(p: *Page, root: *Node) void {
    const st = root.computed orelse return;
    if (st.display == .none) return;
    const b = layout.boxOfNode(root) orelse return;
    const rect = b.contentRect();
    if (rect.w <= 0 or rect.h <= 0) return;
    const sig = signature(p, root, rect.w, rect.h);
    if (p.svgs.map.get(root)) |e| if (e.sig == sig and root.image.ptr == e.bytes.ptr) return;
    var a = std.heap.ArenaAllocator.init(p.gpa);
    defer a.deinit();
    var w: Writer = .{ .a = a.allocator(), .engine = &p.engine, .doc = p.doc, .page = p };
    const text = w.document(root, rect.w, rect.h) catch return;
    store(p, root, text, sig);
}

fn store(p: *Page, root: *Node, text: []const u8, sig: u64) void {
    const gop = p.svgs.map.getOrPut(p.gpa, root) catch return;
    if (gop.found_existing and std.mem.eql(u8, gop.value_ptr.bytes, text)) {
        gop.value_ptr.sig = sig;
        root.image = gop.value_ptr.bytes;
        root.image_key = gop.value_ptr.key;
        return;
    }
    const bytes = p.gpa.dupe(u8, text) catch {
        if (!gop.found_existing) _ = p.svgs.map.remove(root);
        return;
    };
    const key = std.fmt.allocPrint(p.gpa, "svg:{x}", .{std.hash.Wyhash.hash(0, text)}) catch {
        p.gpa.free(bytes);
        if (!gop.found_existing) _ = p.svgs.map.remove(root);
        return;
    };
    if (gop.found_existing) {
        p.gpa.free(gop.value_ptr.bytes);
        p.gpa.free(gop.value_ptr.key);
    }
    gop.value_ptr.* = .{ .bytes = bytes, .key = key, .sig = sig };
    root.image = bytes;
    root.image_key = key;
}

/// What the markup depends on: computed styles are kept by pointer while they
/// don't change, and any change to any `<svg>` moves the document's version.
fn signature(p: *Page, root: *Node, w: f32, h: f32) u64 {
    var hash = std.hash.Wyhash.init(0x5f6);
    hash.update(std.mem.asBytes(&p.doc.svg_version));
    hash.update(std.mem.asBytes(&p.engine.generation));
    hash.update(std.mem.asBytes(&[2]f32{ w, h }));
    var at: ?*Node = root;
    while (at) |n| : (at = n.nextInTree(root)) {
        if (n.kind != .element) continue;
        const c: usize = if (n.computed) |s| @intFromPtr(s) else 0;
        hash.update(std.mem.asBytes(&c));
        // A paint-only restyle writes over the style where it is, so its address
        // says nothing of what it now holds.
        if (n.computed) |s| {
            hash.update(std.mem.asBytes(&s.color));
            hash.update(std.mem.asBytes(&s.svg));
        }
    }
    return hash.final();
}

const Writer = struct {
    a: Allocator,
    engine: *cascade.Engine,
    doc: *dom.Document,
    page: *Page,
    out: std.ArrayList(u8) = .empty,
    /// Elements already written, and ids asked for that may not be.
    written: std.StringHashMapUnmanaged(void) = .empty,
    wanted: std.ArrayList([]const u8) = .empty,
    memo: cascade.DetachedMemo = .empty,
    budget: u32 = 200_000,

    fn put(w: *Writer, s: []const u8) !void {
        try w.out.appendSlice(w.a, s);
    }

    fn print(w: *Writer, comptime f: []const u8, args: anytype) !void {
        try w.out.print(w.a, f, args);
    }

    fn document(w: *Writer, root: *Node, bw: f32, bh: f32) ![]const u8 {
        const st = root.computed.?;
        try w.put("<svg");
        if (root.attr("viewBox")) |v| {
            try w.attr("viewBox", v);
        } else {
            // No viewBox: a user unit is a CSS pixel, whatever the box's size.
            try w.print(" viewBox=\"0 0 {d} {d}\"", .{ bw, bh });
        }
        if (root.attr("preserveAspectRatio")) |v| try w.attr("preserveAspectRatio", v);
        try w.print(" color=\"{f}\"", .{Hex{ .c = st.color }});
        try w.paints(&st.svg, null, st.color);
        if (st.svg.clip_path.len > 0) try w.reference(" clip-path", st.svg.clip_path);
        if (st.svg.mask.len > 0) try w.reference(" mask", st.svg.mask);
        try w.put(">");
        if (root.attr("id")) |id| try w.written.put(w.a, id, {});
        try w.kids(root, st, 0);
        // What was asked for that isn't in here, or wasn't drawn where it is.
        var i: usize = 0;
        var opened = false;
        while (i < w.wanted.items.len) : (i += 1) {
            const id = w.wanted.items[i];
            if (w.written.contains(id)) continue;
            const target = w.doc.getElementById(id) orelse continue;
            if (!isSvgThing(target)) continue;
            if (!opened) try w.put("<defs>");
            opened = true;
            const parent = target.parent;
            const up = if (parent != null and parent.?.kind == .element) w.styleOf(parent.?) else null;
            try w.element(target, up, 0, true);
        }
        if (opened) try w.put("</defs>");
        try w.put("</svg>");
        return w.out.items;
    }

    fn isSvgThing(n: *const Node) bool {
        return n.kind == .element and n.ns == .svg;
    }

    fn styleOf(w: *Writer, n: *Node) ?*const Style {
        return w.engine.styleAnyway(n, &w.memo, w.a) catch null;
    }

    fn kids(w: *Writer, n: *Node, st: *const Style, depth: u32) anyerror!void {
        var k = n.first_child;
        while (k) |x| : (k = x.next) if (x.kind == .element) try w.element(x, st, depth + 1, false);
    }

    /// One element and what's in it. `inherits`: what its parent gives it, which
    /// it needn't say again. `wanted`: named from elsewhere, drawn though hidden.
    fn element(w: *Writer, n: *Node, inherits: ?*const Style, depth: u32, wanted: bool) anyerror!void {
        if (depth > max_depth or w.budget == 0) return;
        if (n.ns != .svg or !isDrawnTag(n.tag)) return;
        w.budget -= 1;
        const st = w.styleOf(n) orelse return;
        const holds_defs = isDefinition(n.tag);
        if (st.display == .none and !holds_defs and !wanted) return;
        if (n.attr("id")) |id| try w.written.put(w.a, id, {});
        try w.print("<{s}", .{n.tag});
        for (n.attrs.items) |a| if (isGeometry(a.name)) {
            if (std.mem.eql(u8, a.name, "transform") and st.svg.transform.len > 0) continue;
            try w.attr(a.name, a.value);
            if (isHref(a.name) and a.value.len > 1 and a.value[0] == '#') try w.wanted.append(w.a, a.value[1..]);
        };
        if (st.svg.transform.len > 0) try w.attr("transform", st.svg.transform);
        try w.own(n, st, inherits);
        if (n.first_child == null) return w.put("/>");
        try w.put(">");
        try w.kids(n, st, depth);
        try w.print("</{s}>", .{n.tag});
    }

    /// What differs from what it inherits, and what never inherits.
    fn own(w: *Writer, n: *Node, st: *const Style, up: ?*const Style) !void {
        if (up == null or !sameColor(up.?.color, st.color)) try w.print(" color=\"{f}\"", .{Hex{ .c = st.color }});
        if (st.opacity < 1) try w.print(" opacity=\"{d}\"", .{st.opacity});
        if (up != null and up.?.visibility != st.visibility) try w.print(" visibility=\"{s}\"", .{@tagName(st.visibility)});
        if (st.svg.clip_path.len > 0) try w.reference(" clip-path", st.svg.clip_path);
        if (st.svg.mask.len > 0) try w.reference(" mask", st.svg.mask);
        try w.paints(&st.svg, if (up) |u| &u.svg else null, st.color);
        if (std.mem.eql(u8, n.tag, "stop")) {
            const c = if (st.svg.stop_color.kind == .current) st.color else st.svg.stop_color.color;
            try w.print(" stop-color=\"{f}\"", .{Hex{ .c = c }});
            if (st.svg.stop_opacity < 1) try w.print(" stop-opacity=\"{d}\"", .{st.svg.stop_opacity});
        }
        if (std.mem.eql(u8, n.tag, "mask")) if (n.attr("style")) |css_text| {
            if (std.mem.indexOf(u8, css_text, "mask-type:alpha") != null or std.mem.indexOf(u8, css_text, "mask-type: alpha") != null) try w.put(" mask-type=\"alpha\"");
        };
    }

    fn reference(w: *Writer, name: []const u8, id: []const u8) !void {
        try w.print("{s}=\"url(#{s})\"", .{ name, id });
        try w.wanted.append(w.a, id);
    }

    /// `up`: the parent's, whose values need no saying; null: SVG's initial ones.
    fn paints(w: *Writer, s: *const css.Svg, up: ?*const css.Svg, color: css.Color) !void {
        _ = color;
        const init: css.Svg = .{};
        const base = up orelse &init;
        if (!samePaint(s.fill, base.fill)) try w.paint("fill", s.fill);
        if (!samePaint(s.stroke, base.stroke)) try w.paint("stroke", s.stroke);
        if (s.stroke_width != base.stroke_width) try w.print(" stroke-width=\"{d}\"", .{s.stroke_width});
        if (s.fill_opacity != base.fill_opacity) try w.print(" fill-opacity=\"{d}\"", .{s.fill_opacity});
        if (s.stroke_opacity != base.stroke_opacity) try w.print(" stroke-opacity=\"{d}\"", .{s.stroke_opacity});
        if (s.fill_evenodd != base.fill_evenodd) try w.print(" fill-rule=\"{s}\"", .{if (s.fill_evenodd) "evenodd" else "nonzero"});
        if (s.clip_evenodd != base.clip_evenodd) try w.print(" clip-rule=\"{s}\"", .{if (s.clip_evenodd) "evenodd" else "nonzero"});
        if (s.cap != base.cap) try w.print(" stroke-linecap=\"{s}\"", .{@tagName(s.cap)});
        if (s.join != base.join) try w.print(" stroke-linejoin=\"{s}\"", .{@tagName(s.join)});
        if (s.miter_limit != base.miter_limit) try w.print(" stroke-miterlimit=\"{d}\"", .{s.miter_limit});
        if (s.dash_offset != base.dash_offset) try w.print(" stroke-dashoffset=\"{d}\"", .{s.dash_offset});
        if (!std.mem.eql(f32, s.dash, base.dash)) {
            try w.put(" stroke-dasharray=\"");
            if (s.dash.len == 0) try w.put("none");
            for (s.dash, 0..) |d, i| try w.print("{s}{d}", .{ if (i > 0) " " else "", d });
            try w.put("\"");
        }
        if (s.stroke_first != base.stroke_first) try w.print(" paint-order=\"{s}\"", .{if (s.stroke_first) "stroke" else "normal"});
        if (s.non_scaling_stroke) try w.put(" vector-effect=\"non-scaling-stroke\"");
    }

    fn paint(w: *Writer, name: []const u8, p: css.SvgPaint) !void {
        switch (p.kind) {
            .none => try w.print(" {s}=\"none\"", .{name}),
            .current => try w.print(" {s}=\"currentColor\"", .{name}),
            .color => try w.print(" {s}=\"{f}\"", .{ name, Hex{ .c = p.color } }),
            .url => {
                try w.wanted.append(w.a, p.url);
                if (p.url_fallback) |c| {
                    try w.print(" {s}=\"url(#{s}) {f}\"", .{ name, p.url, Hex{ .c = c } });
                } else try w.print(" {s}=\"url(#{s})\"", .{ name, p.url });
            },
        }
    }

    fn attr(w: *Writer, name: []const u8, value: []const u8) !void {
        try w.print(" {s}=\"", .{name});
        for (value) |c| {
            if (c == '"') try w.put("&quot;") else if (c == '<') try w.put("&lt;") else try w.out.append(w.a, c);
        }
        try w.put("\"");
    }
};

const Hex = struct {
    c: css.Color,
    pub fn format(h: Hex, out: *std.Io.Writer) std.Io.Writer.Error!void {
        const b = struct {
            fn f(v: f32) u8 {
                return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
            }
        }.f;
        try out.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ b(h.c.r), b(h.c.g), b(h.c.b), b(h.c.a) });
    }
};

fn sameColor(a: css.Color, b: css.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn samePaint(a: css.SvgPaint, b: css.SvgPaint) bool {
    if (a.kind != b.kind) return false;
    return switch (a.kind) {
        .none, .current => true,
        .color => sameColor(a.color, b.color),
        .url => std.mem.eql(u8, a.url, b.url),
    };
}

fn isDrawnTag(tag: []const u8) bool {
    const l = [_][]const u8{ "svg", "g", "a", "switch", "defs", "symbol", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "linearGradient", "radialGradient", "stop", "clipPath", "mask" };
    for (l) |x| if (std.mem.eql(u8, tag, x)) return true;
    return false;
}

/// Drawn where they're named, whatever `display` says of them.
fn isDefinition(tag: []const u8) bool {
    const l = [_][]const u8{ "defs", "symbol", "linearGradient", "radialGradient", "stop", "clipPath", "mask" };
    for (l) |x| if (std.mem.eql(u8, tag, x)) return true;
    return false;
}

fn isHref(name: []const u8) bool {
    return std.mem.eql(u8, name, "href") or std.mem.eql(u8, name, "xlink:href");
}

fn isGeometry(name: []const u8) bool {
    const l = [_][]const u8{ "id", "d", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "fr", "width", "height", "points", "viewBox", "preserveAspectRatio", "transform", "href", "xlink:href", "offset", "gradientUnits", "gradientTransform", "spreadMethod", "clipPathUnits", "maskUnits", "maskContentUnits", "overflow", "systemLanguage", "requiredFeatures" };
    for (l) |x| if (std.mem.eql(u8, name, x)) return true;
    return false;
}
