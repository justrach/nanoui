//! The used sizes of pictures and frames (CSS 2 §10.3.2, §10.4, §10.6.2) and
//! the intrinsic sizes of form controls, by their font.
const std = @import("std");
const box = @import("box.zig");
const dom = @import("../dom.zig");
const ctx = @import("ctx.zig");
const intr = @import("intrinsic.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

pub const Dim = struct { px: f32 = 0, pct: bool = false };

/// An HTML dimension attribute: "100", "100px", "50%". Null for junk.
pub fn dimAttr(n: *const dom.Node, name: []const u8) ?Dim {
    const raw = std.mem.trim(u8, n.attr(name) orelse return null, " \t\r\n");
    var end: usize = 0;
    while (end < raw.len and (std.ascii.isDigit(raw[end]) or raw[end] == '.')) end += 1;
    if (end == 0) return null;
    const v = std.fmt.parseFloat(f32, raw[0..end]) catch return null;
    return .{ .px = ctx.clean(v), .pct = end < raw.len and raw[end] == '%' };
}

/// A dimension attribute on an SVG element: a CSS length (`1em`, `2.5pt`, `50%`),
/// where HTML's would read only the number.
fn svgDim(n: *const dom.Node, name: []const u8, font_size: f32) ?Dim {
    const raw = std.mem.trim(u8, n.attr(name) orelse return null, " \t\r\n");
    var end: usize = 0;
    while (end < raw.len and (std.ascii.isDigit(raw[end]) or raw[end] == '.')) end += 1;
    if (end == 0) return null;
    const v = std.fmt.parseFloat(f32, raw[0..end]) catch return null;
    const u = raw[end..];
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(u, "%")) return .{ .px = v, .pct = true };
    const k: f32 = if (u.len == 0 or eq(u, "px")) 1 else if (eq(u, "em")) font_size else if (eq(u, "rem")) 16 else if (eq(u, "ex")) font_size / 2 else if (eq(u, "pt")) 4.0 / 3.0 else if (eq(u, "pc")) 16 else if (eq(u, "in")) 96 else if (eq(u, "cm")) 96.0 / 2.54 else if (eq(u, "mm")) 96.0 / 25.4 else return null;
    return .{ .px = ctx.clean(v * k) };
}

fn attrDim(b: *const Box, n: *const dom.Node, name: []const u8) ?Dim {
    return if (n.ns == .svg) svgDim(n, name, b.style.font_size) else dimAttr(n, name);
}

/// `fills`: it has a shape but no size of its own, so where its width is free it
/// takes what room there is, and adds none to a box sized by its content.
const Natural = struct { w: ?f32 = null, h: ?f32 = null, ratio: ?f32 = null, fills: bool = false };

fn viewBoxRatio(n: *const dom.Node) ?f32 {
    const v = n.attr("viewBox") orelse n.attr("viewbox") orelse return null;
    var it = std.mem.tokenizeAny(u8, v, " ,\t\r\n");
    _ = it.next() orelse return null;
    _ = it.next() orelse return null;
    const w = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    const h = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    if (!(w > 0) or !(h > 0)) return null;
    return w / h;
}

/// What the picture and the element's attributes say of the size.
fn natural(c: *Ctx, b: *Box) Natural {
    const n = b.node orelse return .{ .w = 300, .h = 150, .ratio = 2 };
    var out: Natural = .{};
    // An inline `<svg>` has only what it says: its markup is drawn at any size.
    if (n.ns != .svg) if (c.m.image(c.m.ctx, n)) |s| {
        if (s.w < 0) {
            out = .{ .ratio = s.h, .fills = true };
        } else if (s.w > 0 and s.h > 0) {
            // Its density's pixels to the CSS pixel: `a.png 2x` is half its size.
            const d = @max(n.image_density, 0.001);
            out = .{ .w = ctx.clean(s.w / d), .h = ctx.clean(s.h / d), .ratio = s.w / s.h };
        }
    };
    const aw = attrDim(b, n, "width");
    const ah = attrDim(b, n, "height");
    if (aw) |d| if (!d.pct) {
        out.w = d.px;
    };
    if (ah) |d| if (!d.pct) {
        out.h = d.px;
    };
    if (aw != null and ah != null and !aw.?.pct and !ah.?.pct and aw.?.px > 0 and ah.?.px > 0) {
        out.ratio = aw.?.px / ah.?.px;
    }
    if (out.ratio == null) out.ratio = viewBoxRatio(n);
    // `aspect-ratio: 2`, over a picture's own; `auto 2` only where it has none.
    if (b.style.aspect_ratio > 0 and (!b.style.aspect_auto or out.ratio == null)) out.ratio = ctx.clean(b.style.aspect_ratio);
    if (out.ratio) |r| {
        if (out.w != null and out.h == null) out.h = out.w.? / r;
        if (out.h != null and out.w == null) out.w = out.h.? * r;
    }
    if (out.w == null and out.h == null and !n.isTag("img")) {
        if (out.ratio != null) {
            out.fills = true;
        } else {
            out.w = 300;
            out.h = 150;
            out.ratio = 2;
        }
    }
    return out;
}

fn styleW(c: *Ctx, b: *Box, cw: ?f32) Error!?f32 {
    if (try ctx.specW(c, b, b.style.width, cw, ctx.bpH(b))) |w| return w - ctx.bpH(b);
    if (b.node) |n| if (attrDim(b, n, "width")) |d| if (d.pct) {
        if (cw) |r| return r * d.px / 100;
    };
    return null;
}

/// The content height of a parent whose height is written in lengths: what a
/// percentage of it means even when the caller is only measuring.
fn parentH(b: *const Box) ?f32 {
    const p = b.parent orelse return null;
    const l = p.style.height;
    if (l.kind != .length or l.hasPct()) return null;
    const v = @max(0, ctx.len(l, 0));
    if (p.style.box_sizing != .border_box) return v;
    const e = ctx.edgesOf(p.style, 0);
    return @max(0, v - e.padding.vertical() - e.border.vertical());
}

fn styleH(b: *Box, ch_in: ?f32) ?f32 {
    const ch = ch_in orelse if (b.style.height.hasPct()) parentH(b) else null;
    if (ctx.specH(b, b.style.height, ch, ctx.bpV(b))) |h| return h - ctx.bpV(b);
    if (b.node) |n| if (attrDim(b, n, "height")) |d| if (d.pct) {
        if (ch) |r| return r * d.px / 100;
    };
    return null;
}

/// The used border-box size.
pub fn size(c: *Ctx, b: *Box, cw: ?f32, ch: ?f32) Error!box.Size {
    const nat = natural(c, b);
    const bph = ctx.bpH(b);
    const bpv = ctx.bpV(b);
    const sw = try styleW(c, b, cw);
    const sh = styleH(b, ch);
    var w: f32 = 0;
    var h: f32 = 0;
    if (sw != null and sh != null) {
        w = sw.?;
        h = sh.?;
    } else if (sw) |v| {
        w = v;
        h = if (nat.ratio) |r| v / r else nat.h orelse 0;
    } else if (sh) |v| {
        h = v;
        w = if (nat.ratio) |r| v * r else nat.w orelse 0;
    } else if (nat.fills) {
        // As a block's width would be, if the room doesn't depend on it.
        const room = if (cw) |r| @max(0, r - bph - b.margin.horizontal()) else 0;
        w = room;
        h = if (nat.ratio) |r| room / r else 0;
    } else {
        w = nat.w orelse 0;
        h = nat.h orelse 0;
    }
    // Min and max, which keep the shape when a side is free to follow.
    const cw2 = try ctx.clampW(c, b, w + bph, cw, bph) - bph;
    if (cw2 != w) {
        if (sh == null) if (nat.ratio) |r| {
            h = cw2 / r;
        };
        w = cw2;
    }
    const ch2 = ctx.clampH(b, h + bpv, ch, bpv) - bpv;
    if (ch2 != h) {
        if (sw == null) if (nat.ratio) |r| {
            const w2 = try ctx.clampW(c, b, ch2 * r + bph, cw, bph) - bph;
            w = w2;
        };
        h = ch2;
    }
    return .{ .w = ctx.clean(w + bph), .h = ctx.clean(h + bpv) };
}

/// The content height of a picture given `cw` of width (a flex or grid item,
/// whose width was decided outside).
pub fn autoH(c: *Ctx, b: *Box, cw: f32) f32 {
    const nat = natural(c, b);
    if (nat.ratio) |r| return cw / r;
    return nat.h orelse 0;
}

pub fn intrinsic(c: *Ctx, b: *Box) Error!intr.Sizes {
    const e = ctx.edgesOf(b.style, 0);
    const saved = .{ b.margin, b.border, b.padding };
    b.margin = e.margin;
    b.border = e.border;
    b.padding = e.padding;
    defer {
        b.margin = saved[0];
        b.border = saved[1];
        b.padding = saved[2];
    }
    const whole = try size(c, b, null, null);
    // What only a percentage limits can shrink to nothing in a table or flex.
    var attr_pct = false;
    if (b.node) |n| if (dimAttr(n, "width")) |d| {
        attr_pct = d.pct;
    };
    const compressible = b.style.width.hasPct() or b.style.max_width.hasPct() or attr_pct;
    return .{ .min = if (compressible) ctx.bpH(b) else whole.w, .max = whole.w };
}

fn isTextLike(n: *const dom.Node) bool {
    if (n.isTag("textarea")) return true;
    if (!n.isTag("input")) return false;
    const t = n.attr("type") orelse return true;
    for ([_][]const u8{ "checkbox", "radio", "range", "color", "progress" }) |x| {
        if (std.ascii.eqlIgnoreCase(t, x)) return false;
    }
    return true;
}

fn parseCount(n: *const dom.Node, name: []const u8, default: f32) f32 {
    const raw = std.mem.trim(u8, n.attr(name) orelse return default, " \t\r\n");
    const v = std.fmt.parseInt(u32, raw, 10) catch return default;
    if (v == 0) return default;
    return @floatFromInt(@min(v, 10000));
}

/// A control's content-box size.
fn controlSize(c: *Ctx, b: *Box) Error!box.Size {
    const n = b.node orelse return .{};
    const s = b.style;
    const font = box.fontOf(s);
    const line = c.lineHeight(s);
    const ch = c.width("0", font);
    if (n.isTag("textarea")) return .{ .w = parseCount(n, "cols", 20) * ch, .h = parseCount(n, "rows", 2) * line };
    if (n.isTag("progress")) return .{ .w = 160, .h = 16 };
    if (n.isTag("meter")) return .{ .w = 80, .h = 16 };
    if (n.isTag("select")) {
        var widest: f32 = 0;
        var count: f32 = 0;
        var at = n.first_child;
        while (at) |k| {
            if (k.isTag("option")) {
                const label = k.attr("label") orelse try k.textContent(c.arena);
                widest = @max(widest, c.width(std.mem.trim(u8, label, " \t\r\n"), font));
                count += 1;
            }
            at = k.nextInTree(n);
        }
        const rows = if (n.hasAttr("multiple")) parseCount(n, "size", 4) else parseCount(n, "size", 1);
        return .{ .w = widest + 22, .h = line * rows };
    }
    if (n.isTag("input")) {
        const t = n.attr("type") orelse "text";
        if (std.ascii.eqlIgnoreCase(t, "checkbox") or std.ascii.eqlIgnoreCase(t, "radio")) return .{ .w = 13, .h = 13 };
        if (std.ascii.eqlIgnoreCase(t, "range")) return .{ .w = 129, .h = 16 };
        if (std.ascii.eqlIgnoreCase(t, "color")) return .{ .w = 44, .h = 23 };
        return .{ .w = parseCount(n, "size", 20) * ch, .h = line };
    }
    return .{ .w = 20 * ch, .h = line };
}

pub fn controlH(c: *Ctx, b: *Box) Error!f32 {
    const sz = try controlSize(c, b);
    b.lay.first_baseline = null;
    b.lay.last_baseline = null;
    if (b.node) |n| if (isTextLike(n)) {
        const m = c.metrics(box.fontOf(b.style));
        const half = (c.lineHeight(b.style) - m.ascent - m.descent) / 2;
        const base = ctx.bpTop(b) + half + m.ascent;
        b.lay.first_baseline = base;
        b.lay.last_baseline = base;
    };
    return sz.h;
}

pub fn controlIntrinsic(c: *Ctx, b: *Box) Error!intr.Sizes {
    const sz = try controlSize(c, b);
    const e = ctx.edgesOf(b.style, 0);
    const w = sz.w + e.border.horizontal() + e.padding.horizontal();
    return .{ .min = if (b.style.width.hasPct()) e.border.horizontal() + e.padding.horizontal() else w, .max = w };
}
