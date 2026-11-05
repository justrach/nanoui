//! An SVG document's elements walked and drawn: groups and nested viewports,
//! `use` and `symbol`, shapes with fills and strokes, and what needs a layer
//! of its own (group opacity, clip paths, masks; `svg_mask.zig`). Text,
//! patterns, markers, filters and `foreignObject` draw nothing.
const std = @import("std");
const geom = @import("svg_geom.zig");
const svg_path = @import("svg_path.zig");
const raster = @import("svg_raster.zig");
const style = @import("svg_style.zig");
const paint_mod = @import("svg_paint.zig");
const mask_mod = @import("svg_mask.zig");
const tags = @import("svg_tags.zig");
const Tag = tags.Tag;
const Tags = tags.Tags;
const Style = style.Style;
const Transform = geom.Transform;
const Flattener = geom.Flattener;
const Region = raster.Region;
const Allocator = std.mem.Allocator;

const max_depth = 64;
const max_use_depth = 12;
/// Shapes drawn at most: `use`s of `use`s can ask for very many.
const max_shapes = 400_000;

/// Passed over with all they hold.
const undrawn = [_][]const u8{ "defs", "clipPath", "mask", "linearGradient", "radialGradient", "pattern", "symbol", "marker", "title", "desc", "metadata", "style", "script", "text", "filter", "foreignObject", "image" };

/// A picture being drawn: premultiplied floats, and where anything was.
pub const Layer = struct {
    px: []f32,
    dirty: Region = .{},
};

pub const Renderer = struct {
    gpa: Allocator,
    src: []const u8,
    w: usize,
    h: usize,
    root_style: Style,
    ids: std.StringHashMapUnmanaged(usize) = .empty,
    sheet: style.Sheet = .{},
    gradients: std.StringHashMapUnmanaged(?*paint_mod.Gradient) = .empty,
    f: Flattener,
    polys: raster.Polygons,
    cov: []f32,
    base: Layer,
    layer: *Layer = undefined,
    spare: std.ArrayList([]f32) = .empty,
    depth: u32 = 0,
    use_stack: [max_use_depth]usize = undefined,
    use_depth: u32 = 0,
    shapes: u32 = 0,
    /// Pixels a user unit at the root, for `non-scaling-stroke`.
    root_scale: f32 = 1,

    pub fn init(gpa: Allocator, src: []const u8, w: usize, h: usize, current: [4]f32) !*Renderer {
        const r = try gpa.create(Renderer);
        errdefer gpa.destroy(r);
        const acc = try gpa.alloc(f32, w * h * 4);
        errdefer gpa.free(acc);
        @memset(acc, 0);
        const cov = try gpa.alloc(f32, w * h);
        r.* = .{
            .gpa = gpa,
            .src = src,
            .w = w,
            .h = h,
            .root_style = .{ .color = current, .vp = .{ @floatFromInt(w), @floatFromInt(h) } },
            .f = .{ .gpa = gpa },
            .polys = .{ .gpa = gpa },
            .cov = cov,
            .base = .{ .px = acc },
        };
        r.layer = &r.base;
        try r.prepass();
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        const gpa = r.gpa;
        r.ids.deinit(gpa);
        r.sheet.deinit(gpa);
        var it = r.gradients.valueIterator();
        while (it.next()) |g| if (g.*) |x| gpa.destroy(x);
        r.gradients.deinit(gpa);
        r.f.deinit();
        r.polys.deinit();
        gpa.free(r.cov);
        gpa.free(r.base.px);
        for (r.spare.items) |px| gpa.free(px);
        r.spare.deinit(gpa);
        gpa.destroy(r);
    }

    /// Every id's place, and the document's `<style>`s.
    fn prepass(r: *Renderer) !void {
        var it: Tags = .{ .s = r.src };
        while (it.next()) |tag| {
            if (tag.kind == .close) continue;
            if (tag.attr("id")) |id| {
                const gop = try r.ids.getOrPut(r.gpa, id);
                if (!gop.found_existing) gop.value_ptr.* = tag.start;
            }
            if (tag.kind == .open and std.mem.eql(u8, tag.name, "style")) {
                const end = std.mem.indexOfPos(u8, r.src, it.i, "</") orelse continue;
                var text = r.src[it.i..end];
                // The text may be in a CDATA section, whose `]]>` `</` follows.
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t\r\n"), "<![CDATA[")) {
                    const from = std.mem.indexOf(u8, text, "<![CDATA[").? + 9;
                    text = text[from..];
                    if (std.mem.indexOf(u8, text, "]]>")) |e| text = text[0..e];
                }
                try r.sheet.parse(r.gpa, text);
            }
        }
    }

    fn sheetOf(r: *const Renderer) ?*const style.Sheet {
        return if (r.sheet.rules.items.len > 0) &r.sheet else null;
    }

    /// The first `<svg>`, drawn into the whole picture. False if there's none.
    pub fn run(r: *Renderer) !bool {
        var it: Tags = .{ .s = r.src };
        while (it.next()) |tag| {
            if (tag.kind == .close or !std.mem.eql(u8, tag.name, "svg")) continue;
            var st = r.root_style.inherit();
            style.apply(&st, tag, r.sheetOf());
            if (st.hidden) return true;
            const w: f32 = @floatFromInt(r.w);
            const h: f32 = @floatFromInt(r.h);
            var vb = viewBox(tag);
            if (vb == null) vb = .{ 0, 0, style.length(tag.attr("width") orelse "", w) orelse w, style.length(tag.attr("height") orelse "", h) orelse h };
            const fit = fitViewBox(vb.?, 0, 0, w, h, tag.attr("preserveAspectRatio"));
            st.t = fit.then(st.t);
            st.vp = .{ vb.?[2], vb.?[3] };
            r.root_scale = fit.lengthScale();
            try r.group(&it, tag, &st);
            return true;
        }
        return false;
    }

    /// Premultiplied BGRA bytes of what was drawn.
    pub fn bytes(r: *Renderer, gpa: Allocator) ![]u8 {
        const out = try gpa.alloc(u8, r.w * r.h * 4);
        const acc = r.base.px;
        for (0..r.w * r.h) |i| {
            const px = acc[i * 4 ..][0..4];
            out[i * 4 + 0] = byte(px[2]);
            out[i * 4 + 1] = byte(px[1]);
            out[i * 4 + 2] = byte(px[0]);
            out[i * 4 + 3] = byte(px[3]);
        }
        return out;
    }

    pub fn children(r: *Renderer, it: *Tags, st: *const Style) anyerror!void {
        while (it.next()) |tag| {
            if (tag.kind == .close) return;
            try r.element(it, tag, st);
        }
    }

    fn skip(it: *Tags, tag: Tag) void {
        if (tag.kind != .open) return;
        var depth: usize = 1;
        while (depth > 0) {
            const t = it.next() orelse return;
            switch (t.kind) {
                .open => depth += 1,
                .close => depth -= 1,
                .empty => {},
            }
        }
    }

    fn isUndrawn(name: []const u8) bool {
        for (undrawn) |s| if (std.mem.eql(u8, s, name)) return true;
        return false;
    }

    fn element(r: *Renderer, it: *Tags, tag: Tag, parent: *const Style) anyerror!void {
        const n = tag.name;
        if (r.depth >= max_depth or isUndrawn(n)) return skip(it, tag);
        var st = parent.inherit();
        style.apply(&st, tag, r.sheetOf());
        if (st.hidden) return skip(it, tag);
        r.depth += 1;
        defer r.depth -= 1;
        const eq = std.mem.eql;
        if (eq(u8, n, "g") or eq(u8, n, "a")) return r.group(it, tag, &st);
        if (eq(u8, n, "svg")) return r.nestedViewport(it, tag, &st, null, null);
        if (eq(u8, n, "switch")) return r.switchOf(it, tag, &st);
        if (eq(u8, n, "use")) {
            defer skip(it, tag);
            return r.use(tag, &st);
        }
        defer skip(it, tag);
        try r.shape(tag, &st);
    }

    /// The first child for this reader: one with no language asked, or English.
    fn switchOf(r: *Renderer, it: *Tags, tag: Tag, st: *const Style) anyerror!void {
        if (tag.kind != .open) return;
        var drawn = false;
        while (it.next()) |child| {
            if (child.kind == .close) return;
            const lang = child.attr("systemLanguage");
            const fits = lang == null or std.mem.startsWith(u8, lang.?, "en") or std.mem.indexOf(u8, lang.?, ",en") != null;
            if (drawn or !fits or child.attr("requiredFeatures") != null or std.mem.eql(u8, child.name, "foreignObject")) {
                skip(it, child);
                continue;
            }
            drawn = true;
            try r.element(it, child, st);
        }
    }

    /// What's in `tag`, in a layer when it has effects of its own.
    fn group(r: *Renderer, it: *Tags, tag: Tag, st: *const Style) anyerror!void {
        if (tag.kind != .open) return;
        if (!st.wantsLayer()) return r.children(it, st);
        const prev = try r.pushLayer();
        var failed: ?anyerror = null;
        r.children(it, st) catch |e| {
            failed = e;
        };
        const bbox: [4]f32 = .{ 0, 0, st.vp[0], st.vp[1] };
        try r.popLayer(prev, st, bbox);
        if (failed) |e| return e;
    }

    /// A nested `<svg>`, or a `symbol` a `use` draws (its sizes in `w`, `h`).
    fn nestedViewport(r: *Renderer, it: *Tags, tag: Tag, st_in: *const Style, w_in: ?f32, h_in: ?f32) anyerror!void {
        var st = st_in.*;
        const x = style.length(tag.attr("x") orelse "", st.vp[0]) orelse 0;
        const y = style.length(tag.attr("y") orelse "", st.vp[1]) orelse 0;
        const w = w_in orelse style.length(tag.attr("width") orelse "", st.vp[0]) orelse st.vp[0];
        const h = h_in orelse style.length(tag.attr("height") orelse "", st.vp[1]) orelse st.vp[1];
        if (w <= 0 or h <= 0) return skip(it, tag);
        const vb = viewBox(tag);
        const overflow = tag.attr("overflow") orelse "";
        if (!std.mem.eql(u8, overflow, "visible") and st.t.axisAligned()) {
            const a = st.t.apply(.{ x, y });
            const b = st.t.apply(.{ x + w, y + h });
            var c: [4]f32 = .{ @min(a[0], b[0]), @min(a[1], b[1]), @max(a[0], b[0]), @max(a[1], b[1]) };
            if (st.clip_rect) |o| c = .{ @max(c[0], o[0]), @max(c[1], o[1]), @min(c[2], o[2]), @min(c[3], o[3]) };
            st.clip_rect = c;
        }
        st.t = (if (vb) |v| fitViewBox(v, x, y, w, h, tag.attr("preserveAspectRatio")) else Transform.translate(x, y)).then(st.t);
        st.vp = if (vb) |v| .{ v[2], v[3] } else .{ w, h };
        try r.group(it, tag, &st);
    }

    fn use(r: *Renderer, tag: Tag, st_in: *const Style) anyerror!void {
        const h = tag.href() orelse return;
        if (h.len < 2 or h[0] != '#') return;
        const at = r.ids.get(h[1..]) orelse return;
        if (r.use_depth >= max_use_depth) return;
        for (r.use_stack[0..r.use_depth]) |o| if (o == at) return;
        r.use_stack[r.use_depth] = at;
        r.use_depth += 1;
        defer r.use_depth -= 1;
        var st = st_in.*;
        const x = style.length(tag.attr("x") orelse "", st.vp[0]) orelse 0;
        const y = style.length(tag.attr("y") orelse "", st.vp[1]) orelse 0;
        st.t = Transform.translate(x, y).then(st.t);
        var body = st;
        const layered = st.wantsLayer();
        // Effects of the `use` itself wrap what it shows, which mustn't take
        // them again.
        body.opacity = 1;
        body.clip = null;
        body.mask = null;
        const prev = if (layered) try r.pushLayer() else null;
        var failed: ?anyerror = null;
        r.instance(at, tag, &body) catch |e| {
            failed = e;
        };
        if (layered) try r.popLayer(prev.?, &st, .{ 0, 0, st.vp[0], st.vp[1] });
        if (failed) |e| return e;
    }

    fn instance(r: *Renderer, at: usize, use_tag: Tag, st: *const Style) anyerror!void {
        var it: Tags = .{ .s = r.src, .i = at };
        const target = it.next() orelse return;
        const eq = std.mem.eql;
        if (eq(u8, target.name, "symbol") or eq(u8, target.name, "svg")) {
            var own = st.inherit();
            style.apply(&own, target, r.sheetOf());
            if (own.hidden) return;
            const w = style.length(use_tag.attr("width") orelse "", st.vp[0]) orelse (if (eq(u8, target.name, "svg")) style.length(target.attr("width") orelse "", st.vp[0]) else null) orelse st.vp[0];
            const h = style.length(use_tag.attr("height") orelse "", st.vp[1]) orelse (if (eq(u8, target.name, "svg")) style.length(target.attr("height") orelse "", st.vp[1]) else null) orelse st.vp[1];
            return r.nestedViewport(&it, target, &own, w, h);
        }
        return r.element(&it, target, st);
    }

    /// Draws one shape element; what isn't one draws nothing.
    fn shape(r: *Renderer, tag: Tag, st: *const Style) anyerror!void {
        if (!st.visible and !st.wantsLayer()) return;
        r.shapes += 1;
        if (r.shapes > max_shapes) return;
        r.f.clear();
        r.f.t = st.t;
        if (!try outline(&r.f, tag, st.vp)) return;
        const fills = paints(st.fill);
        const strokes = paints(st.stroke) and st.stroke_width > 0;
        const both_group = fills and strokes and st.opacity < 0.999;
        if (st.clip != null or st.mask != null or both_group) {
            const bbox = r.userBox(st);
            const prev = try r.pushLayer();
            var inner = st.*;
            inner.opacity = 1;
            inner.clip = null;
            inner.mask = null;
            r.paintShape(&inner, bbox) catch |e| {
                r.layer = prev;
                return e;
            };
            try r.popLayer(prev, st, bbox);
            return;
        }
        if (!st.visible) return;
        try r.paintShape(st, r.userBox(st));
    }

    fn paints(p: style.Paint) bool {
        return p != .none;
    }

    /// The flattened shape's box in user units.
    fn userBox(r: *const Renderer, st: *const Style) [4]f32 {
        const inv = st.t.inverse() orelse return .{ 0, 0, 0, 0 };
        var x0: f32 = std.math.inf(f32);
        var y0: f32 = std.math.inf(f32);
        var x1: f32 = -std.math.inf(f32);
        var y1: f32 = -std.math.inf(f32);
        for (r.f.points.items) |p| {
            const q = inv.apply(p);
            x0 = @min(x0, q[0]);
            y0 = @min(y0, q[1]);
            x1 = @max(x1, q[0]);
            y1 = @max(y1, q[1]);
        }
        if (x1 < x0) return .{ 0, 0, 0, 0 };
        return .{ x0, y0, x1 - x0, y1 - y0 };
    }

    fn paintShape(r: *Renderer, st: *const Style, bbox: [4]f32) !void {
        if (st.stroke_first) try r.strokeOf(st, bbox);
        if (paints(st.fill)) if (try r.sourceOf(st.fill, st, bbox)) |src| {
            r.polys.clear();
            r.polys.xf = null;
            for (r.f.subpaths.items) |s| try r.polys.polygon(r.f.of(s));
            const reg = try r.polys.fillRegion(st.rule, r.w, r.h, r.cov, st.clip_rect);
            r.put(reg, src, st.opacity * st.fill_opacity);
        };
        if (!st.stroke_first) try r.strokeOf(st, bbox);
    }

    fn strokeOf(r: *Renderer, st: *const Style, bbox: [4]f32) !void {
        if (!paints(st.stroke) or st.stroke_width <= 0) return;
        const src = try r.sourceOf(st.stroke, st, bbox) orelse return;
        r.polys.clear();
        const scale = st.t.lengthScale();
        // A shape's stroke scales as it does; where that isn't the same both
        // ways, it's made in user space and carried over.
        const in_user = !st.non_scaling_stroke and !st.t.uniform();
        const inv = if (in_user) st.t.inverse() else null;
        const k: f32 = if (inv != null) 1 else if (st.non_scaling_stroke) r.root_scale else scale;
        const opts: raster.StrokeStyle = .{
            .half = st.stroke_width * k / 2,
            .cap = st.cap,
            .join = st.join,
            .miter_limit = st.miter_limit,
            .detail = if (inv != null) scale else 1,
        };
        r.polys.xf = if (inv != null) st.t else null;
        defer r.polys.xf = null;
        var user: std.ArrayList(geom.Point) = .empty;
        defer user.deinit(r.gpa);
        for (r.f.subpaths.items) |s| {
            var pts = r.f.of(s);
            if (inv) |iv| {
                user.clearRetainingCapacity();
                for (pts) |p| try user.append(r.gpa, iv.apply(p));
                pts = user.items;
            }
            if (st.dash_n > 0) {
                var scaled: [style.max_dashes]f32 = undefined;
                for (st.dash[0..st.dash_n], 0..) |d, i| scaled[i] = d * k;
                var sink: DashSink = .{ .polys = &r.polys, .opts = opts };
                try raster.dash(r.gpa, pts, s.closed, scaled[0..st.dash_n], st.dash_offset * k, &sink);
            } else {
                try raster.stroke(&r.polys, pts, s.closed, opts);
            }
        }
        const reg = try r.polys.fillRegion(.nonzero, r.w, r.h, r.cov, st.clip_rect);
        r.put(reg, src, st.opacity * st.stroke_opacity);
    }

    const DashSink = struct {
        polys: *raster.Polygons,
        opts: raster.StrokeStyle,
        pub fn dash(s: *DashSink, pts: []const geom.Point) !void {
            try raster.stroke(s.polys, pts, false, s.opts);
        }
    };

    fn put(r: *Renderer, reg: Region, src: paint_mod.Source, opacity: f32) void {
        if (reg.isEmpty()) return;
        paint_mod.composite(r.layer.px, r.cov, r.w, reg, src, opacity);
        r.layer.dirty = r.layer.dirty.join(reg);
    }

    fn sourceOf(r: *Renderer, p: style.Paint, st: *const Style, bbox: [4]f32) !?paint_mod.Source {
        return switch (p) {
            .none => null,
            .current => .{ .color = st.color },
            .color => |c| .{ .color = c },
            .url => |u| blk: {
                if (try r.gradient(u.id, st)) |g| {
                    if (g.stops == 0) break :blk null;
                    if (g.solid) |c| break :blk .{ .color = c };
                    const placed = paint_mod.place(g, st.t, bbox, st.vp) orelse break :blk null;
                    break :blk .{ .gradient = placed };
                }
                break :blk switch (u.fallback) {
                    .none => null,
                    .current => .{ .color = st.color },
                    .color => |c| .{ .color = c },
                };
            },
        };
    }

    fn gradient(r: *Renderer, id: []const u8, st: *const Style) !?*const paint_mod.Gradient {
        if (r.gradients.get(id)) |g| return g;
        const at = r.ids.get(id);
        var made: ?*paint_mod.Gradient = null;
        if (at) |offset| if (try paint_mod.load(r.gpa, r.src, &r.ids, offset, r.sheetOf(), st.color)) |g| {
            const p = try r.gpa.create(paint_mod.Gradient);
            p.* = g;
            made = p;
        };
        try r.gradients.put(r.gpa, id, made);
        return made;
    }

    /// A fresh layer to draw into; gives the one to go back to.
    pub fn pushLayer(r: *Renderer) !*Layer {
        const prev = r.layer;
        const l = try r.gpa.create(Layer);
        errdefer r.gpa.destroy(l);
        const px = r.spare.pop() orelse blk: {
            const fresh = try r.gpa.alloc(f32, r.w * r.h * 4);
            @memset(fresh, 0);
            break :blk fresh;
        };
        l.* = .{ .px = px };
        r.layer = l;
        return prev;
    }

    /// The current layer over `prev`, through `st`'s opacity, clip and mask.
    pub fn popLayer(r: *Renderer, prev: *Layer, st: *const Style, bbox: [4]f32) !void {
        const cur = r.layer;
        r.layer = prev;
        defer r.recycle(cur);
        if (cur.dirty.isEmpty()) return;
        var clip: ?[]f32 = null;
        defer if (clip) |x| r.gpa.free(x);
        var masked: ?[]f32 = null;
        defer if (masked) |x| r.gpa.free(x);
        if (st.clip) |id| clip = try mask_mod.clipCoverage(r, id, st, bbox);
        if (st.mask) |id| masked = try mask_mod.maskCoverage(r, id, st, bbox);
        const d = cur.dirty;
        for (d.y0..d.y1) |y| {
            const row = y * r.w;
            for (d.x0..d.x1) |x| {
                const i = row + x;
                var k = st.opacity;
                if (clip) |c| k *= c[i];
                if (masked) |m| k *= m[i];
                if (k <= 0) continue;
                const s = cur.px[i * 4 ..][0..4];
                const t = prev.px[i * 4 ..][0..4];
                const ia = 1 - s[3] * k;
                t[0] = s[0] * k + t[0] * ia;
                t[1] = s[1] * k + t[1] * ia;
                t[2] = s[2] * k + t[2] * ia;
                t[3] = s[3] * k + t[3] * ia;
            }
        }
        prev.dirty = prev.dirty.join(d);
    }

    /// Back to the spares, clean.
    pub fn recycle(r: *Renderer, l: *Layer) void {
        const d = l.dirty;
        for (d.y0..d.y1) |y| @memset(l.px[(y * r.w + d.x0) * 4..(y * r.w + d.x1) * 4], 0);
        r.spare.append(r.gpa, l.px) catch r.gpa.free(l.px);
        r.gpa.destroy(l);
    }
};

fn byte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
}

pub fn viewBox(tag: Tag) ?[4]f32 {
    const v = tag.attr("viewBox") orelse return null;
    var sc: svg_path.Scanner = .{ .s = v };
    var b: [4]f32 = undefined;
    for (&b) |*x| x.* = sc.number() orelse return null;
    if (b[2] <= 0 or b[3] <= 0) return null;
    return b;
}

/// `vb` in the box at (x, y), `w` × `h`, as `preserveAspectRatio` says
/// (centered and whole when it says nothing).
pub fn fitViewBox(vb: [4]f32, x: f32, y: f32, w: f32, h: f32, par: ?[]const u8) Transform {
    var align_x: f32 = 0.5;
    var align_y: f32 = 0.5;
    var slice = false;
    var none = false;
    if (par) |p| {
        var it = std.mem.tokenizeAny(u8, p, " \t\r\n");
        if (it.next()) |a| {
            if (std.mem.eql(u8, a, "none")) {
                none = true;
            } else if (a.len == 8 and a[0] == 'x' and a[4] == 'Y') {
                align_x = if (std.mem.eql(u8, a[1..4], "Min")) 0 else if (std.mem.eql(u8, a[1..4], "Max")) 1 else 0.5;
                align_y = if (std.mem.eql(u8, a[5..8], "Min")) 0 else if (std.mem.eql(u8, a[5..8], "Max")) 1 else 0.5;
            }
        }
        if (it.next()) |b| slice = std.mem.eql(u8, b, "slice");
    }
    var kx = w / vb[2];
    var ky = h / vb[3];
    if (!none) {
        const k = if (slice) @max(kx, ky) else @min(kx, ky);
        kx = k;
        ky = k;
    }
    return Transform.translate(-vb[0], -vb[1]).then(Transform.scale(kx, ky)).then(Transform.translate(x + (w - vb[2] * kx) * align_x, y + (h - vb[3] * ky) * align_y));
}

/// Builds the element's outline; false if it isn't a shape.
pub fn outline(f: *Flattener, tag: Tag, vp: [2]f32) !bool {
    const n = tag.name;
    const eq = std.mem.eql;
    const num = struct {
        fn of(t: Tag, k: []const u8, ref: f32) f32 {
            return style.length(t.attr(k) orelse "", ref) orelse 0;
        }
    }.of;
    if (eq(u8, n, "path")) {
        try svg_path.path(f, tag.attr("d") orelse return false);
    } else if (eq(u8, n, "rect")) {
        const rx = if (tag.attr("rx")) |v| style.length(v, vp[0]) else null;
        const ry = if (tag.attr("ry")) |v| style.length(v, vp[1]) else null;
        try svg_path.rect(f, num(tag, "x", vp[0]), num(tag, "y", vp[1]), num(tag, "width", vp[0]), num(tag, "height", vp[1]), rx, ry);
    } else if (eq(u8, n, "circle")) {
        const diag = @sqrt((vp[0] * vp[0] + vp[1] * vp[1]) / 2);
        const c = num(tag, "r", diag);
        try svg_path.ellipse(f, num(tag, "cx", vp[0]), num(tag, "cy", vp[1]), c, c);
    } else if (eq(u8, n, "ellipse")) {
        try svg_path.ellipse(f, num(tag, "cx", vp[0]), num(tag, "cy", vp[1]), num(tag, "rx", vp[0]), num(tag, "ry", vp[1]));
    } else if (eq(u8, n, "line")) {
        try f.moveTo(.{ num(tag, "x1", vp[0]), num(tag, "y1", vp[1]) });
        try f.lineTo(.{ num(tag, "x2", vp[0]), num(tag, "y2", vp[1]) });
    } else if (eq(u8, n, "polyline") or eq(u8, n, "polygon")) {
        try svg_path.poly(f, tag.attr("points") orelse return false, n[4] == 'g');
    } else return false;
    return f.subpaths.items.len > 0;
}
