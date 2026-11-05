//! Absolute and fixed boxes (CSS 2 §10.3.7, §10.6.4): sizes and places a box
//! against the padding box of its containing block, in page coordinates, its
//! static position standing in for insets left auto.
const std = @import("std");
const box = @import("box.zig");
const ctx = @import("ctx.zig");
const sizing = @import("sizing.zig");
const intrinsic = @import("intrinsic.zig");
const replaced = @import("replaced.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;
const Len = ctx.Len;

fn inset(l: Len, ref: f32) ?f32 {
    if (l.kind != .length) return null;
    return ctx.len(l, ref);
}

/// Places `b`, whose static position in the page is (`sx`, `sy`). A null `cb`,
/// or the initial containing block, is the viewport.
pub fn place(c: *Ctx, b: *Box, sx: f32, sy: f32, cb: ?*Box) Error!void {
    const s = b.style;
    const pad: box.Rect = if (cb) |q| (if (q.parent == null) box.Rect{ .w = c.vw, .h = c.vh } else q.paddingRect()) else .{ .w = c.vw, .h = c.vh };
    ctx.setEdges(b, pad.w);
    const bph = ctx.bpH(b);
    const bpv = ctx.bpV(b);
    const left = inset(s.left, pad.w);
    const right = inset(s.right, pad.w);
    const top = inset(s.top, pad.h);
    const bottom = inset(s.bottom, pad.h);
    const auto_l = s.margin_left.kind == .auto;
    const auto_r = s.margin_right.kind == .auto;
    const auto_t = s.margin_top.kind == .auto;
    const auto_b = s.margin_bottom.kind == .auto;

    // Width.
    var w: f32 = 0;
    const natural = if (b.kind == .replaced) try replaced.size(c, b, pad.w, pad.h) else box.Size{};
    var spec = if (b.kind == .replaced) natural.w else try ctx.specW(c, b, s.width, pad.w, bph);
    if (spec == null and s.aspect_ratio > 0) {
        if (ctx.specH(b, s.height, pad.h, bpv)) |h| spec = ctx.aspectW(b, h);
    }
    if (spec) |v| {
        w = v;
    } else if (b.kind == .table) {
        w = try sizing.fitWidth(c, b, pad.w, pad.h);
    } else if (left != null and right != null) {
        w = @max(bph, pad.w - left.? - right.? - b.margin.horizontal());
    } else {
        const room = if (left != null) pad.w - left.? else if (right != null) pad.w - right.? else pad.w - (sx - pad.x);
        w = try sizing.shrinkToFit(c, b, room - b.margin.horizontal());
    }
    w = try ctx.clampW(c, b, w, pad.w, bph);

    // Horizontal margins and position.
    if (left != null and right != null and (auto_l or auto_r)) {
        const free = pad.w - left.? - right.? - w - b.margin.horizontal();
        if (auto_l and auto_r) {
            if (free >= 0) {
                b.margin.left = free / 2;
                b.margin.right = free / 2;
            } else {
                b.margin.left = 0;
                b.margin.right = free;
            }
        } else if (auto_l) {
            b.margin.left = free;
        } else {
            b.margin.right = free;
        }
    }
    var x: f32 = 0;
    if (left) |v| {
        x = pad.x + v + b.margin.left;
    } else if (right) |v| {
        x = pad.x + pad.w - v - b.margin.right - w;
    } else {
        x = sx + b.margin.left + (b.lay.static_w - w - b.margin.horizontal()) * b.lay.static_fx;
    }

    // Height: from the insets when they stretch it, else content.
    var def: ?f32 = if (b.kind == .replaced) natural.h else ctx.specH(b, s.height, pad.h, bpv);
    if (def == null and top != null and bottom != null and (s.height.kind == .auto or s.height.kind == .stretch)) def = @max(bpv, pad.h - top.? - bottom.? - b.margin.vertical());
    if (def == null and s.aspect_ratio > 0 and b.kind != .replaced) def = ctx.aspectH(b, w);
    var h: f32 = 0;
    if (def) |d| {
        h = try sizing.layoutBfc(c, b, w, ctx.clampH(b, d, pad.h, bpv));
    } else {
        h = try sizing.layoutBfc(c, b, w, null);
        const clamped = ctx.clampH(b, h, pad.h, bpv);
        if (clamped != h) h = try sizing.layoutBfc(c, b, w, clamped);
    }

    if (top != null and bottom != null and (auto_t or auto_b)) {
        const free = pad.h - top.? - bottom.? - h - b.margin.vertical();
        if (auto_t and auto_b) {
            b.margin.top = free / 2;
            b.margin.bottom = free / 2;
        } else if (auto_t) {
            b.margin.top = free;
        } else {
            b.margin.bottom = free;
        }
    }
    var y: f32 = 0;
    if (top) |v| {
        y = pad.y + v + b.margin.top;
    } else if (bottom) |v| {
        y = pad.y + pad.h - v - b.margin.bottom - h;
    } else {
        y = sy + b.margin.top + (b.lay.static_h - h - b.margin.vertical()) * b.lay.static_fy;
    }
    b.x = x;
    b.y = y;
}
