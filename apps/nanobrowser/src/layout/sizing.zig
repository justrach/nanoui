//! How a box that is laid out on its own gets its size: the dispatch to its
//! formatting context, the cache that keeps nested flex and tables from
//! re-doing their work, and the used sizes of out-of-flow and inline-level boxes.
//!
//! Everything inside a box is positioned relative to it, so a box laid out
//! again with the same width and height needs nothing done. A box's insides
//! only change through its parent's layout, which ends each child with a call
//! to `layoutBfc` for the size it settled on, so the state left behind is the
//! final one. `measureAuto` answers from memory when it can.
const std = @import("std");
const box = @import("box.zig");
const ctx = @import("ctx.zig");
const block = @import("block.zig");
const flex = @import("flex.zig");
const grid = @import("grid.zig");
const table = @import("table.zig");
const replaced = @import("replaced.zig");
const intrinsic = @import("intrinsic.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

fn edgesKey(b: *const Box) f32 {
    return ctx.bpH(b) + ctx.bpV(b) * 1000;
}

/// Lays out a box's insides at border-box width `w`, and height `def_h` when
/// it is definite. Sets `b.w`, `b.h` and gives back the height.
pub fn layoutBfc(c: *Ctx, b: *Box, w_in: f32, def_in: ?f32) Error!f32 {
    const n = &b.lay;
    const w = ctx.clean(w_in);
    const def_h: ?f32 = if (def_in) |d| ctx.clean(d) else null;
    const key_h = def_h orelse -1;
    const edges = edgesKey(b);
    if (n.state_valid and n.state_w == w and n.state_h == key_h and n.state_edges == edges) {
        b.w = n.state_out_w;
        b.h = n.state_out_h;
        return b.h;
    }
    n.state_valid = false;
    n.shift_y = 0;
    b.w = w;
    const cw = @max(0, w - ctx.bpH(b));
    const ch: ?f32 = if (def_h) |d| @max(0, d - ctx.bpV(b)) else null;
    const auto_h = switch (b.kind) {
        .flex => try flex.layout(c, b, cw, ch),
        .grid => try grid.layout(c, b, cw, ch),
        .table => try table.layout(c, b, cw, ch),
        .replaced => replaced.autoH(c, b, cw),
        .control => try replaced.controlH(c, b),
        else => try block.layoutContainer(c, b, cw, ch),
    };
    n.auto_h = ctx.clean(auto_h);
    const bpv = ctx.bpV(b);
    b.h = def_h orelse n.auto_h + bpv;
    if (b.kind == .table) b.h = @max(b.h, n.auto_h + bpv);
    if (def_h != null and n.center_v) {
        const room = b.h - bpv - n.auto_h;
        if (room > 0) ctx.shiftContents(b, room / 2);
    }
    n.state_valid = true;
    n.state_w = w;
    n.state_h = key_h;
    n.state_edges = edges;
    n.state_out_w = b.w;
    n.state_out_h = b.h;
    if (def_h == null) {
        n.measure_valid = true;
        n.measure_w = w;
        n.measure_edges = edges;
        n.measure_h = b.h;
    }
    return b.h;
}

/// The border-box height at width `w` with height auto. What the box's insides
/// are left as is unspecified: the caller ends with `layoutBfc`.
pub fn measureAuto(c: *Ctx, b: *Box, w: f32) Error!f32 {
    const n = &b.lay;
    if (n.measure_valid and n.measure_w == w and n.measure_edges == edgesKey(b)) return n.measure_h;
    return layoutBfc(c, b, w, null);
}

/// The definite height the box has without looking at its content.
fn definiteH(b: *Box, w: f32, ch: ?f32, stretch: ?f32) ?f32 {
    const bpv = ctx.bpV(b);
    const spec = ctx.specH(b, b.style.height, ch, bpv) orelse stretch;
    if (spec) |d| return ctx.clampH(b, d, ch, bpv);
    if (b.style.aspect_ratio > 0 and b.kind != .replaced) {
        const content = @max(0, w - ctx.bpH(b)) / ctx.clean(b.style.aspect_ratio);
        return ctx.clampH(b, content + bpv, ch, bpv);
    }
    return null;
}

/// Lays out a box of settled width with its height from its style, `stretch`
/// when that is auto, else its content, within its min and max.
pub fn place(c: *Ctx, b: *Box, w: f32, ch: ?f32, stretch: ?f32) Error!f32 {
    if (definiteH(b, w, ch, stretch)) |d| return layoutBfc(c, b, w, d);
    const h = try layoutBfc(c, b, w, null);
    const clamped = ctx.clampH(b, h, ch, ctx.bpV(b));
    if (clamped != h) return layoutBfc(c, b, w, clamped);
    return h;
}

/// What `place` would give it, without settling anything.
pub fn measureH(c: *Ctx, b: *Box, w: f32, ch: ?f32) Error!f32 {
    if (definiteH(b, w, ch, null)) |d| return d;
    return ctx.clampH(b, try measureAuto(c, b, w), ch, ctx.bpV(b));
}

/// min(max(min-content, available), max-content).
pub fn shrinkToFit(c: *Ctx, b: *Box, avail: f32) Error!f32 {
    const i = try intrinsic.of(c, b);
    return @min(i.max, @max(i.min, avail));
}

/// The width of a box that does not fill its container when auto: floats,
/// inline-blocks, absolutes, replaced and controls. Auto margins count as zero.
pub fn fitWidth(c: *Ctx, b: *Box, cw: f32, ch: ?f32) Error!f32 {
    const bp = ctx.bpH(b);
    switch (b.kind) {
        .replaced => return (try replaced.size(c, b, cw, ch)).w,
        .table => return table.usedWidth(c, b, cw),
        else => {},
    }
    var w = try ctx.specW(c, b, b.style.width, cw, bp);
    if (w == null and b.style.aspect_ratio > 0) {
        if (ctx.specH(b, b.style.height, ch, ctx.bpV(b))) |h| {
            w = (h - ctx.bpV(b)) * ctx.clean(b.style.aspect_ratio) + bp;
        }
    }
    const used = w orelse try shrinkToFit(c, b, cw - b.margin.horizontal());
    return ctx.clampW(c, b, used, cw, bp);
}

/// Sizes a float: edges against the container, then `fitWidth` and `place`.
pub fn floatSize(c: *Ctx, k: *Box, cw: f32, ch: ?f32) Error!void {
    ctx.setEdges(k, cw);
    const w = try fitWidth(c, k, cw, ch);
    _ = try place(c, k, w, ch, null);
}
