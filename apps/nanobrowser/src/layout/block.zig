//! The block formatting context: widths by CSS 2 §10.3, margin collapsing,
//! floats and clearance. While a formatting context is in progress, boxes
//! hold their top in its coordinates; when a parent closes, its children's
//! tops become relative to it, once, so all this stays linear.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const floats_mod = @import("floats.zig");
const inl = @import("inline.zig");
const sizing = @import("sizing.zig");
const list = @import("list.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

/// Margins waiting to collapse: the most positive and the most negative.
const Strut = struct {
    pos: f32 = 0,
    neg: f32 = 0,

    fn add(s: *Strut, m: f32) void {
        s.pos = @max(s.pos, m);
        s.neg = @min(s.neg, m);
    }

    fn sum(s: Strut) f32 {
        return s.pos + s.neg;
    }
};

/// One formatting context in progress. `y` is the bottom of what has been
/// placed and `strut` the margins after it, not yet added.
const Flow = struct {
    c: *Ctx,
    floats: floats_mod.Floats = .{},
    y: f32 = 0,
    strut: Strut = .{},
    /// Set by clearance: where a parent with its top still open starts.
    clear_top: ?f32 = null,

    fn settle(f: *Flow) void {
        f.y += f.strut.sum();
        f.strut = .{};
    }

    fn fresh(f: *Flow, margin: f32) void {
        f.strut = .{};
        f.strut.add(margin);
    }
};

/// A block formatting context's root: lays out `b`'s content in a content box
/// `cw` wide, and gives back its height.
pub fn layoutContainer(c: *Ctx, b: *Box, cw: f32, ch: ?f32) Error!f32 {
    var f: Flow = .{ .c = c };
    var top: ?f32 = 0;
    const in_ch = ch orelse if (c.quirks and b.parent != null and b.parent.?.parent == null) c.vh else null;
    try insides(&f, b, 0, cw, in_ch, &top);
    f.settle();
    const h = @max(0, @max(f.y, f.floats.bottom()));
    if (!b.lay.inline_root) closeChildren(b, -ctx.bpTop(b));
    baselines(b);
    if (b.lay.has_marker) try list.place(c, b);
    return h;
}

fn closeChildren(p: *Box, y: f32) void {
    var k = p.first_child;
    while (k) |x| : (k = x.next) x.y -= y;
}

/// A block's baselines from its children's, now they are relative to it.
fn baselines(b: *Box) void {
    if (b.lay.inline_root) return;
    b.lay.first_baseline = null;
    b.lay.last_baseline = null;
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.style.isOutOfFlow() or x.style.float != .none) continue;
        if (x.lay.first_baseline) |v| if (b.lay.first_baseline == null) {
            b.lay.first_baseline = x.y + v;
        };
        if (x.lay.last_baseline) |v| b.lay.last_baseline = x.y + v;
    }
}

/// The content of `p`: lines, or block children. `top` is `p`'s border-box
/// top, once something inside has fixed it.
fn insides(f: *Flow, p: *Box, cx: f32, cw: f32, ch: ?f32, top: *?f32) Error!void {
    if (p.lay.inline_root) {
        const t = f.y + f.strut.sum();
        const r = try inl.layout(f.c, p, cw, cx, t, &f.floats, ch);
        if (r.lines > 0) {
            f.settle();
            if (top.* == null) top.* = f.y;
            f.y += r.h;
        }
        return;
    }
    p.runs = &.{};
    p.marker = null;
    const left = ctx.bpLeft(p);
    var k = p.first_child;
    while (k) |x| : (k = x.next) {
        if (x.style.isOutOfFlow()) {
            x.x = left;
            x.y = f.y + f.strut.sum();
        } else if (x.style.float != .none) {
            const y = f.y + f.strut.sum();
            try sizing.floatSize(f.c, x, cw, ch);
            const pos = try f.floats.place(f.c.arena, x.style.float == .left, x.style.clear, x.w + x.margin.horizontal(), x.h + x.margin.vertical(), y, cx, cw);
            x.x = pos.x - cx + left + x.margin.left;
            x.y = pos.y + x.margin.top;
        } else if (try flowChild(f, x, left, cx, cw, ch) and top.* == null) {
            top.* = f.clear_top orelse x.y;
            f.clear_top = null;
        }
    }
}

/// Clearance: true when it put the flow below floats.
fn applyClear(f: *Flow, s: *const css.Style, margin_top: f32) bool {
    if (s.clear == .none or !f.floats.any()) return false;
    var tentative = f.strut;
    tentative.add(margin_top);
    const cy = f.floats.clearY(s.clear);
    if (cy <= f.y + tentative.sum()) return false;
    f.clear_top = f.y + f.strut.sum();
    f.y = cy;
    f.strut = .{};
    return true;
}

/// Lays out an in-flow block-level box. True if it has fixed the position of
/// what holds it, rather than being collapsed through.
fn flowChild(f: *Flow, b: *Box, parent_left: f32, cx: f32, cw: f32, ch: ?f32) Error!bool {
    if (b.lay.adopted and !ctx.isBfcRoot(b)) {
        if (!f.floats.any() and b.lay.flow_reusable and b.lay.cached_flow_cw == cw and b.lay.cached_flow_ch == (ch orelse -1) and legacyAlign(b) == null and (b.parent == null or !b.parent.?.style.rtl)) {
            b.w = b.lay.cached_out_w;
            b.h = b.lay.cached_out_h;
            b.x = parent_left + b.margin.left;
            f.strut.add(b.margin.top);
            f.settle();
            b.y = f.y;
            f.y = b.y + b.h;
            f.fresh(b.margin.bottom);
            return true;
        }
        try @import("cache.zig").unadopt(f.c, b);
    }
    ctx.setEdges(b, cw);
    if (ctx.isBfcRoot(b)) return flowRoot(f, b, parent_left, cx, cw, ch);
    const c = f.c;
    const s = b.style;
    b.w = try blockWidth(c, b, cw, ch);
    b.x = parent_left + b.margin.left;
    const in_w = @max(0, b.w - ctx.bpH(b));
    const bpv = ctx.bpV(b);
    var def = ctx.specH(b, s.height, ch, bpv) orelse if (s.aspect_ratio > 0) ctx.aspectH(b, b.w) else null;
    const aspect_floor = s.aspect_ratio > 0 and s.height.kind == .auto and ctx.aspectGrows(b);
    const inner_ch: ?f32 = if (def) |d| @max(0, ctx.clampH(b, d, ch, bpv) - bpv) else if (c.quirks) ch else null;
    const tb = ctx.bpTop(b);
    const bb = b.border.bottom + b.padding.bottom;

    var top: ?f32 = null;
    if (applyClear(f, s, b.margin.top)) {
        top = f.y;
    } else {
        f.strut.add(b.margin.top);
    }
    if (tb > 0 and top == null) {
        f.settle();
        top = f.y;
    }
    if (top != null) f.y += tb;
    try insides(f, b, cx + b.margin.left + ctx.bpLeft(b), in_w, inner_ch, &top);
    // A height from `aspect-ratio` gives way to what's inside.
    if (aspect_floor) if (top) |t| {
        def = @max(def.?, f.y - t + bb);
    };

    var h: f32 = 0;
    var resolved = true;
    if (def) |d0| {
        const d = ctx.clampH(b, d0, ch, bpv);
        if (d > 0 or top != null) {
            if (top == null) {
                f.settle();
                top = f.y;
            }
            h = d;
            f.y = top.? + d;
            f.fresh(b.margin.bottom);
        } else {
            top = f.y + f.strut.sum();
            f.strut.add(b.margin.bottom);
            resolved = false;
        }
    } else if (top == null and bb == 0) {
        const y = f.y + f.strut.sum();
        h = ctx.clampH(b, 0, ch, bpv);
        const marker_h = if (b.lay.has_marker and !s.list_inside) c.lineHeight(s) else 0;
        h = @max(h, marker_h);
        top = y;
        if (h > 0) {
            f.settle();
            f.y += h;
            f.fresh(b.margin.bottom);
        } else {
            f.strut.add(b.margin.bottom);
            resolved = false;
        }
    } else {
        if (bb > 0) {
            f.settle();
            if (top == null) top = f.y;
            f.y += bb;
        }
        h = f.y - top.?;
        const clamped = ctx.clampH(b, h, ch, bpv);
        if (clamped != h) {
            h = clamped;
            f.y = top.? + h;
            f.strut = .{};
        }
        f.strut.add(b.margin.bottom);
    }
    b.y = top.?;
    b.h = h;
    if (!b.lay.inline_root) closeChildren(b, b.y);
    baselines(b);
    if (b.lay.has_marker) try list.place(c, b);
    b.lay.state_valid = false;
    if (resolved and !f.floats.any() and legacyAlign(b) == null and (b.parent == null or !b.parent.?.style.rtl)) {
        b.lay.cached_flow_cw = cw;
        b.lay.cached_flow_ch = ch orelse -1;
        b.lay.cached_out_w = b.w;
        b.lay.cached_out_h = b.h;
    } else {
        b.lay.cached_flow_cw = -1;
    }
    return resolved;
}

/// A block-level box that is a formatting context of its own, or a table,
/// flex, grid or replaced box: placed as one thing, clear of floats.
fn flowRoot(f: *Flow, b: *Box, parent_left: f32, cx: f32, cw: f32, ch: ?f32) Error!bool {
    const c = f.c;
    const s = b.style;
    const fills = b.kind != .replaced and b.kind != .table and b.kind != .control and s.width.kind == .auto and !b.lay.shrink;
    var w = try rootWidth(c, b, cw, ch);
    if (!applyClear(f, s, b.margin.top)) f.strut.add(b.margin.top);
    var y = f.y + f.strut.sum();
    var x = cx + b.margin.left;
    var h = try sizing.place(c, b, w, ch, null);
    if (f.floats.any()) {
        var tries: u8 = 0;
        while (tries < 32) : (tries += 1) {
            const room = f.floats.band(y, @max(h + b.margin.vertical(), 0.01), cx, cw);
            const narrowed = room.x0 > cx or room.x1 < cx + cw;
            if (!narrowed) break;
            const space = room.x1 - room.x0;
            const mh = b.margin.horizontal();
            if (fills) {
                const min = (try @import("intrinsic.zig").of(c, b)).min;
                if (space - mh >= min or f.floats.nextBelow(y) == null) {
                    const tw = try ctx.clampW(c, b, @max(0, space - mh), cw, ctx.bpH(b));
                    x = room.x0 + b.margin.left;
                    if (tw == w) break;
                    w = tw;
                    const old = h;
                    h = try sizing.place(c, b, w, ch, null);
                    if (h <= old) break;
                    continue;
                }
            } else if (w + mh <= space) {
                x = @max(x, room.x0 + b.margin.left);
                if (x + w + b.margin.right > room.x1) x = room.x0 + b.margin.left;
                break;
            }
            y = f.floats.nextBelow(y) orelse break;
        }
    }
    b.x = x - cx + parent_left;
    b.y = y;
    f.y = y + h;
    f.fresh(b.margin.bottom);
    return true;
}

fn rootWidth(c: *Ctx, b: *Box, cw: f32, ch: ?f32) Error!f32 {
    if (b.kind == .replaced or b.kind == .table or b.kind == .control) {
        const w = try sizing.fitWidth(c, b, cw, ch);
        resolveMargins(b, w, cw);
        return w;
    }
    return blockWidth(c, b, cw, ch);
}

/// Whether the HTML above asks a block to be centered or pushed: `<center>`
/// and `align` on what holds it; `margin: 0 auto` in all but name.
fn legacyAlign(b: *const Box) ?css.TextAlign {
    const n = (b.parent orelse return null).node orelse return null;
    if (n.tag.len == 6 and n.isTag("center")) return .center;
    if ((n.attr_filter & comptime @import("../perf_rules.zig").attrBit("align")) == 0) return null;
    const name = n.attr("align") orelse return null;
    if (std.ascii.eqlIgnoreCase(name, "center") or std.ascii.eqlIgnoreCase(name, "middle")) return .center;
    if (std.ascii.eqlIgnoreCase(name, "right")) return .right;
    return null;
}

/// Auto margins, given the width: CSS 2 §10.3.3.
fn resolveMargins(b: *Box, w: f32, cw: f32) void {
    const s = b.style;
    var left_auto = s.margin_left.kind == .auto;
    var right_auto = s.margin_right.kind == .auto;
    if (!left_auto and !right_auto and b.margin.left == 0 and b.margin.right == 0) {
        if (legacyAlign(b)) |a| {
            left_auto = true;
            right_auto = a == .center;
        }
    }
    const rest = cw - w - (if (left_auto) 0 else b.margin.left) - (if (right_auto) 0 else b.margin.right);
    if (left_auto and right_auto) {
        b.margin.left = @max(0, rest / 2);
        b.margin.right = rest - b.margin.left;
    } else if (left_auto) {
        b.margin.left = if (rest > 0) rest else 0;
    } else if (right_auto) {
        b.margin.right = rest;
    } else if (b.parent != null and b.parent.?.style.rtl) {
        b.margin.left = cw - w - b.margin.right;
    } else {
        b.margin.right = cw - w - b.margin.left;
    }
}

/// A block's border-box width in `cw`; sets its margins.
pub fn blockWidth(c: *Ctx, b: *Box, cw: f32, ch: ?f32) Error!f32 {
    const s = b.style;
    const bp = ctx.bpH(b);
    var spec = try ctx.specW(c, b, s.width, cw, bp);
    if (spec == null and s.aspect_ratio > 0) {
        if (ctx.specH(b, s.height, ch, ctx.bpV(b))) |h| spec = ctx.aspectW(b, h);
    }
    const room = cw - b.margin.horizontal();
    const w0 = spec orelse if (b.lay.shrink) try sizing.shrinkToFit(c, b, room) else @max(bp, room);
    const w = try ctx.clampW(c, b, w0, cw, bp);
    resolveMargins(b, w, cw);
    return w;
}
