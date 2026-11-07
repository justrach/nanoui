//! SVG's clip paths and masks as coverage: one float a pixel a layer is
//! multiplied by when it's put down.
const std = @import("std");
const geom = @import("svg_geom.zig");
const raster = @import("svg_raster.zig");
const style = @import("svg_style.zig");
const render = @import("svg_render.zig");
const tags = @import("svg_tags.zig");
const Renderer = render.Renderer;
const Style = style.Style;
const Tag = tags.Tag;
const Tags = tags.Tags;
const Transform = geom.Transform;

/// `clip-path="url(#id)"` under `st`: what its shapes cover, a shape's own
/// rule and transform applied. Null if the id names no clip path, which then
/// doesn't clip.
pub fn clipCoverage(r: *Renderer, id: []const u8, st: *const Style, bbox: [4]f32) anyerror!?[]f32 {
    const at = r.ids.get(id) orelse return null;
    var it: Tags = .{ .s = r.src, .i = at };
    const tag = it.next() orelse return null;
    if (!std.mem.eql(u8, tag.name, "clipPath")) return null;
    const cov = try r.gpa.alloc(f32, r.w * r.h);
    errdefer r.gpa.free(cov);
    @memset(cov, 0);
    var base = st.t;
    var own: Style = .{ .t = base, .vp = st.vp, .clip_rule = st.clip_rule };
    style.apply(&own, tag, null);
    base = own.t;
    if (std.mem.eql(u8, tag.attr("clipPathUnits") orelse "", "objectBoundingBox")) {
        base = Transform.scale(bbox[2], bbox[3]).then(.translate(bbox[0], bbox[1])).then(base);
    }
    if (tag.kind == .open) try clipChildren(r, &it, base, st.vp, own.clip_rule, cov, 0);
    // A clip path may itself be clipped.
    if (own.clip) |other| if (!std.mem.eql(u8, other, id)) {
        if (try clipCoverage(r, other, st, bbox)) |c2| {
            defer r.gpa.free(c2);
            for (cov, c2) |*a, b| a.* *= b;
        }
    };
    return cov;
}

fn clipChildren(r: *Renderer, it: *Tags, base: Transform, vp: [2]f32, rule: raster.Rule, cov: []f32, depth: u32) anyerror!void {
    var f: geom.Flattener = .{ .gpa = r.gpa };
    defer f.deinit();
    var polys: raster.Polygons = .{ .gpa = r.gpa };
    defer polys.deinit();
    const tmp = try r.gpa.alloc(f32, r.w * r.h);
    defer r.gpa.free(tmp);
    while (it.next()) |tag| {
        if (tag.kind == .close) return;
        if (tag.kind == .open) {
            // A shape with children (a `title`, say) closes after them.
            var d: usize = 1;
            var inner = it.*;
            while (d > 0) {
                const t = inner.next() orelse break;
                switch (t.kind) {
                    .open => d += 1,
                    .close => d -= 1,
                    .empty => {},
                }
            }
            it.* = inner;
        }
        var st: Style = .{ .t = base, .vp = vp, .clip_rule = rule };
        style.apply(&st, tag, null);
        if (st.hidden or !st.visible) continue;
        var target = tag;
        if (std.mem.eql(u8, tag.name, "use") and depth < 4) {
            const h = tag.href() orelse continue;
            if (h.len < 2) continue;
            const at = r.ids.get(h[1..]) orelse continue;
            var ti: Tags = .{ .s = r.src, .i = at };
            target = ti.next() orelse continue;
            const x = style.length(tag.attr("x") orelse "", vp[0]) orelse 0;
            const y = style.length(tag.attr("y") orelse "", vp[1]) orelse 0;
            st.t = Transform.translate(x, y).then(st.t);
            style.apply(&st, target, null);
        }
        f.clear();
        f.t = st.t;
        if (!try render.outline(&f, target, vp)) continue;
        polys.clear();
        for (f.subpaths.items) |s| try polys.polygon(f.of(s));
        const reg = try polys.fillRegion(st.clip_rule, r.w, r.h, tmp, null);
        for (reg.y0..reg.y1) |y| {
            const row = y * r.w;
            for (reg.x0..reg.x1) |x| cov[row + x] = @max(cov[row + x], tmp[row + x]);
        }
    }
}

/// `mask="url(#id)"` under `st`: its content drawn on nothing, read by
/// luminance (or alpha, for `mask-type: alpha`). Null if the id names no mask.
pub fn maskCoverage(r: *Renderer, id: []const u8, st: *const Style, bbox: [4]f32) anyerror!?[]f32 {
    const at = r.ids.get(id) orelse return null;
    var it: Tags = .{ .s = r.src, .i = at };
    const tag = it.next() orelse return null;
    if (!std.mem.eql(u8, tag.name, "mask")) return null;
    const cov = try r.gpa.alloc(f32, r.w * r.h);
    errdefer r.gpa.free(cov);
    @memset(cov, 0);
    if (tag.kind != .open) return cov;
    var inner: Style = .{ .color = st.color, .t = st.t, .vp = st.vp };
    style.apply(&inner, tag, null);
    inner.opacity = 1;
    inner.clip = null;
    inner.mask = null;
    inner.clip_rect = null;
    const alpha = isAlphaMask(tag);
    if (std.mem.eql(u8, tag.attr("maskContentUnits") orelse "", "objectBoundingBox")) {
        inner.t = Transform.scale(bbox[2], bbox[3]).then(.translate(bbox[0], bbox[1])).then(inner.t);
    }
    // A region in user space is honored; the default, 120% of the box, is
    // wide enough to be left out.
    if (std.mem.eql(u8, tag.attr("maskUnits") orelse "", "userSpaceOnUse") and tag.attr("width") != null and tag.attr("height") != null and st.t.axisAligned()) {
        const x = style.length(tag.attr("x") orelse "", st.vp[0]) orelse 0;
        const y = style.length(tag.attr("y") orelse "", st.vp[1]) orelse 0;
        const w = style.length(tag.attr("width") orelse "", st.vp[0]) orelse st.vp[0];
        const h = style.length(tag.attr("height") orelse "", st.vp[1]) orelse st.vp[1];
        const a = st.t.apply(.{ x, y });
        const b = st.t.apply(.{ x + w, y + h });
        inner.clip_rect = .{ @min(a[0], b[0]), @min(a[1], b[1]), @max(a[0], b[0]), @max(a[1], b[1]) };
    }
    const prev = try r.pushLayer();
    const lay = r.layer;
    var failed: ?anyerror = null;
    r.children(&it, &inner) catch |e| {
        failed = e;
    };
    r.layer = prev;
    defer r.recycle(lay);
    if (failed) |e| return e;
    const d = lay.dirty;
    for (d.y0..d.y1) |y| {
        const row = y * r.w;
        for (d.x0..d.x1) |x| {
            const i = row + x;
            const p = lay.px[i * 4 ..][0..4];
            cov[i] = if (alpha) p[3] else 0.2125 * p[0] + 0.7154 * p[1] + 0.0721 * p[2];
        }
    }
    return cov;
}

fn isAlphaMask(tag: Tag) bool {
    if (std.mem.eql(u8, tag.attr("mask-type") orelse "", "alpha")) return true;
    const css = tag.attr("style") orelse return false;
    const at = std.mem.indexOf(u8, css, "mask-type") orelse return false;
    const colon = std.mem.indexOfScalarPos(u8, css, at, ':') orelse return false;
    return std.mem.startsWith(u8, std.mem.trimStart(u8, css[colon + 1 ..], " \t\r\n"), "alpha");
}
