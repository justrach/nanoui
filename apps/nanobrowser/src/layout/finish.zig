//! The last pass, once everything in flow has its size: walks the tree from
//! the top, turning coordinates relative to the parent into page coordinates,
//! applying relative offsets, laying out absolute and fixed boxes against their
//! containing blocks, which are final by the time they are reached, and
//! gathering overflow on the way back up. One visit per box.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const positioned = @import("positioned.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

const Cbs = struct { abs: *Box, fixed: ?*Box };

/// Finishes the tree under the initial containing block.
pub fn run(c: *Ctx, root: *Box) Error!void {
    try inside(c, root, 0, 0, .{ .abs = root, .fixed = null });
}

/// A box's relative offset, from its containing block.
fn relativeOffset(b: *const Box) [2]f32 {
    const s = b.style;
    // Sticky boxes stay where the flow put them; a frame moves them as the
    // page scrolls (`paint/display.zig`).
    if (s.position != .relative) return .{ 0, 0 };
    const p = b.parent orelse return .{ 0, 0 };
    const rw = p.contentRect().w;
    var dx: f32 = 0;
    if (s.left.kind == .length) {
        dx = ctx.len(s.left, rw);
    } else if (s.right.kind == .length) {
        dx = -ctx.len(s.right, rw);
    }
    const definite = p.style.height.kind == .length and !p.style.height.hasPct();
    const rh = p.contentRect().h;
    var dy: f32 = 0;
    if (s.top.kind == .length and (!s.top.hasPct() or definite)) {
        dy = ctx.len(s.top, rh);
    } else if (s.bottom.kind == .length and (!s.bottom.hasPct() or definite)) {
        dy = -ctx.len(s.bottom, rh);
    }
    return .{ dx, dy };
}

/// Places `b` given the page position of what its coordinates are relative
/// to, then finishes what is in it.
fn visit(c: *Ctx, b: *Box, ox: f32, oy: f32, cbs: Cbs) Error!void {
    const rel = relativeOffset(b);
    b.x += ox + rel[0];
    b.y += oy + rel[1];
    if (b.kind == .inline_box) {
        const inner_x = ox + rel[0];
        const inner_y = oy + rel[1];
        const frags: []box.Rect = @constCast(b.frags);
        for (frags) |*r| {
            r.x += inner_x;
            r.y += inner_y;
        }
        try inside(c, b, inner_x, inner_y, nextCbs(b, cbs));
        return;
    }
    try inside(c, b, b.x, b.y, nextCbs(b, cbs));
}

fn nextCbs(b: *Box, cbs: Cbs) Cbs {
    var out = cbs;
    if (b.style.position != .static or b.style.hasTransform()) out.abs = b;
    if (b.style.hasTransform()) out.fixed = b;
    return out;
}

/// `ox`, `oy` is the page position of what `b`'s runs and children are relative to.
fn inside(c: *Ctx, b: *Box, ox: f32, oy: f32, cbs: Cbs) Error!void {
    const runs: []box.TextRun = @constCast(b.runs);
    var right: f32 = b.lay.extra_r;
    var bottom: f32 = b.lay.extra_b;
    for (runs) |*r| {
        r.x += ox;
        r.baseline += oy;
        r.line_top += oy;
        right = @max(right, r.x + r.w);
        bottom = @max(bottom, r.line_top + r.line_h);
    }
    if (b.marker) |*m| {
        m.x += ox;
        m.y += oy;
    }
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.style.isOutOfFlow()) {
            const fixed = x.style.position == .fixed;
            const cb: ?*Box = if (fixed) cbs.fixed else cbs.abs;
            try positioned.place(c, x, x.x + ox, x.y + oy, cb);
            try inside(c, x, x.x, x.y, nextCbs(x, cbs));
            if (!fixed or cb != null) {
                const target = cb.?;
                const reach = extents(x);
                target.lay.extra_r = @max(target.lay.extra_r, reach[0]);
                target.lay.extra_b = @max(target.lay.extra_b, reach[1]);
            }
            continue;
        }
        try visit(c, x, ox, oy, cbs);
        const reach = extents(x);
        right = @max(right, reach[0]);
        bottom = @max(bottom, reach[1]);
    }
    // Positioned descendants may have reported to this box while its children ran.
    right = @max(right, b.lay.extra_r);
    bottom = @max(bottom, b.lay.extra_b);
    const pad = b.paddingRect();
    var cw = right - pad.x;
    var ch = bottom - pad.y;
    if (b.style.clips()) {
        if (cw > 0) cw += b.padding.right;
        if (ch > 0) ch += b.padding.bottom;
    }
    b.content_w = @max(pad.w, cw);
    b.content_h = @max(pad.h, ch);
}

/// The page's right and bottom of what a box reaches, past its clip if it has none.
fn extents(x: *const Box) [2]f32 {
    var r = x.x + x.w;
    var b = x.y + x.h;
    if (x.kind != .inline_box and !x.style.clips()) {
        const px = x.x + x.border.left;
        const py = x.y + x.border.top;
        r = @max(r, px + x.content_w);
        b = @max(b, py + x.content_h);
    }
    if (x.kind == .inline_box) {
        r = @max(r, x.x + x.content_w);
        b = @max(b, x.y + x.content_h);
    }
    return .{ r, b };
}
