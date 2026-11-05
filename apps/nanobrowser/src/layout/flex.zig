//! Flexbox: the algorithm of CSS Flexible Box §9, in both axes. Sizes are kept
//! as border-box sizes and margins beside them. Cross sizes and baselines come
//! from `sizing`, whose cache keeps nesting in either axis from multiplying work.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const sizing = @import("sizing.zig");
const intrinsic_mod = @import("intrinsic.zig");
const lines_mod = @import("flex_lines.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;
const inf = std.math.inf(f32);

pub const Item = struct {
    b: *Box,
    /// Margins along the main and cross axes; auto ones count as zero until spare room is shared.
    ms: f32 = 0,
    me: f32 = 0,
    ms_auto: bool = false,
    me_auto: bool = false,
    cs: f32 = 0,
    ce: f32 = 0,
    cs_auto: bool = false,
    ce_auto: bool = false,
    base: f32 = 0,
    /// Border and padding along the main axis.
    bp: f32 = 0,
    hyp: f32 = 0,
    min: f32 = 0,
    max: f32 = inf,
    target: f32 = 0,
    frozen: bool = false,
    /// Border-box cross size; `ascent` above the baseline with its margin.
    cross: f32 = 0,
    ascent: f32 = 0,
    align_self: css.Align = .stretch,

    pub fn mainOuter(i: *const Item, v: f32) f32 {
        return v + i.ms + i.me;
    }

    pub fn crossOuter(i: *const Item) f32 {
        return i.cross + i.cs + i.ce;
    }

    /// A stretched item: the cross size comes from its line.
    pub fn stretches(i: *const Item, row: bool) bool {
        if (i.align_self != .stretch or i.cs_auto or i.ce_auto) return false;
        return (if (row) i.b.style.height else i.b.style.width).kind == .auto;
    }
};

pub const Setup = struct {
    c: *Ctx,
    b: *Box,
    row: bool,
    cw: f32,
    ch: ?f32,
    main: ?f32,
    cross: ?f32,
    gap_main: f32,
    gap_cross: f32,
};

fn selfAlign(k: *const Box, parent: *const css.Style) css.Align {
    const a = if (k.style.align_self != .auto) k.style.align_self else parent.align_items;
    return switch (a) {
        .auto, .normal => .stretch,
        .space_between, .space_around, .space_evenly => .start,
        else => a,
    };
}

fn fillItem(s: *const Setup, k: *Box) Error!Item {
    const c = s.c;
    ctx.setEdges(k, s.cw);
    const st = k.style;
    var it: Item = .{ .b = k, .align_self = selfAlign(k, s.b.style) };
    if (s.row) {
        it.ms = k.margin.left;
        it.me = k.margin.right;
        it.ms_auto = st.margin_left.kind == .auto;
        it.me_auto = st.margin_right.kind == .auto;
        it.cs = k.margin.top;
        it.ce = k.margin.bottom;
        it.cs_auto = st.margin_top.kind == .auto;
        it.ce_auto = st.margin_bottom.kind == .auto;
    } else {
        it.ms = k.margin.top;
        it.me = k.margin.bottom;
        it.ms_auto = st.margin_top.kind == .auto;
        it.me_auto = st.margin_bottom.kind == .auto;
        it.cs = k.margin.left;
        it.ce = k.margin.right;
        it.cs_auto = st.margin_left.kind == .auto;
        it.ce_auto = st.margin_right.kind == .auto;
    }
    if (!s.row) it.cross = try columnWidth(s, &it);

    const bph = ctx.bpH(k);
    const bpv = ctx.bpV(k);
    const bp = if (s.row) bph else bpv;
    it.bp = bp;

    // The flex base size.
    var base: ?f32 = null;
    const fb = st.flex_basis;
    if (fb.kind == .length and (!fb.hasPct() or s.main != null)) {
        const v = @max(0, ctx.len(fb, s.main orelse 0));
        base = if (st.box_sizing == .border_box) @max(v, bp) else v + bp;
    } else if (fb.kind == .auto or fb.kind == .length) {
        base = if (s.row) try ctx.specW(c, k, st.width, s.cw, bph) else ctx.specH(k, st.height, s.ch, bpv);
    }
    if (base == null and st.aspect_ratio > 0 and s.row) {
        if (ctx.specH(k, st.height, s.ch, bpv)) |h| base = ctx.aspectW(k, h);
    }
    if (base == null and k.kind == .replaced and s.row) {
        base = (try @import("replaced.zig").size(c, k, s.cw, s.ch)).w;
    }
    const content_main: ?f32 = if (base == null or !s.row) try contentMain(s, &it) else null;
    it.base = base orelse content_main.?;

    // Min and max along the main axis.
    if (s.row) {
        if (try ctx.specW(c, k, st.max_width, s.cw, bph)) |v| it.max = v;
        if (st.min_width.kind == .auto) {
            it.min = try autoMinWidth(s, k, bph);
        } else if (try ctx.specW(c, k, st.min_width, s.cw, bph)) |v| it.min = v;
    } else {
        if (ctx.specH(k, st.max_height, s.ch, bpv)) |v| it.max = v;
        if (st.min_height.kind == .auto) {
            if (st.clips()) {
                it.min = bpv;
            } else {
                const spec = ctx.specH(k, st.height, s.ch, bpv) orelse inf;
                it.min = @min(spec, content_main.?);
            }
        } else if (ctx.specH(k, st.min_height, s.ch, bpv)) |v| it.min = v;
    }
    it.min = @max(it.min, bp);
    if (it.max < it.min) it.max = it.min;
    it.hyp = std.math.clamp(it.base, it.min, it.max);
    it.target = it.hyp;
    return it;
}

fn autoMinWidth(s: *const Setup, k: *Box, bph: f32) Error!f32 {
    if (k.style.clips()) return bph;
    _ = try intrinsic_mod.of(s.c, k);
    var out = k.lay.content_min;
    if (try ctx.specW(s.c, k, k.style.width, s.cw, bph)) |w| out = @min(out, w);
    if (try ctx.specW(s.c, k, k.style.max_width, s.cw, bph)) |w| out = @min(out, w);
    return out;
}

/// The size along the main axis its content asks for.
fn contentMain(s: *const Setup, it: *const Item) Error!f32 {
    if (s.row) return (try intrinsic_mod.of(s.c, it.b)).max;
    return sizing.measureAuto(s.c, it.b, it.cross);
}

/// A column's item's width, stretched only as far as its line, which in a
/// single-line container is the container.
fn columnWidth(s: *const Setup, it: *const Item) Error!f32 {
    const k = it.b;
    const bph = ctx.bpH(k);
    const room = s.cw - it.cs - it.ce;
    var w = try ctx.specW(s.c, k, k.style.width, s.cw, bph);
    if (w == null and k.kind == .replaced) {
        w = (try @import("replaced.zig").size(s.c, k, s.cw, s.ch)).w;
    }
    const used = w orelse if (it.stretches(false) and s.b.style.flex_wrap == .nowrap) @max(bph, room) else try sizing.shrinkToFit(s.c, k, room);
    return ctx.clampW(s.c, k, used, s.cw, bph);
}

/// Lays out a flex container's items; gives back the height of its content box.
pub fn layout(c: *Ctx, b: *Box, cw: f32, ch: ?f32) Error!f32 {
    const st = b.style;
    const row = st.flex_direction == .row or st.flex_direction == .row_reverse;
    b.runs = &.{};
    b.marker = null;
    const s: Setup = .{
        .c = c,
        .b = b,
        .row = row,
        .cw = cw,
        .ch = ch,
        .main = if (row) cw else ch,
        .cross = if (row) ch else cw,
        .gap_main = @max(0, ctx.len(if (row) st.column_gap else st.row_gap, if (row) cw else ch orelse 0)),
        .gap_cross = @max(0, ctx.len(if (row) st.row_gap else st.column_gap, if (row) ch orelse 0 else cw)),
    };
    var items: std.ArrayList(Item) = .empty;
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.style.isOutOfFlow()) {
            x.x = ctx.bpLeft(b);
            x.y = ctx.bpTop(b);
            continue;
        }
        try items.append(c.arena, try fillItem(&s, x));
    }
    sortByOrder(items.items);
    return lines_mod.run(&s, items.items);
}

fn sortByOrder(items: []Item) void {
    var any = false;
    for (items) |*i| any = any or i.b.style.order != 0;
    if (!any) return;
    std.mem.sort(Item, items, {}, struct {
        fn less(_: void, a: Item, b: Item) bool {
            return a.b.style.order < b.b.style.order;
        }
    }.less);
}

/// Content-box widths.
pub fn intrinsic(c: *Ctx, b: *Box) Error!intrinsic_mod.Sizes {
    const st = b.style;
    const row = st.flex_direction == .row or st.flex_direction == .row_reverse;
    const gap = @max(0, ctx.len(st.column_gap, 0));
    var out: intrinsic_mod.Sizes = .{};
    var count: f32 = 0;
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.style.isOutOfFlow()) continue;
        const i = try intrinsic_mod.outer(c, x);
        count += 1;
        if (row) {
            out.max += i.max;
            if (st.flex_wrap == .nowrap) out.min += i.min else out.min = @max(out.min, i.min);
        } else {
            out.max = @max(out.max, i.max);
            out.min = @max(out.min, i.min);
        }
    }
    if (row and count > 1) {
        out.max += gap * (count - 1);
        if (st.flex_wrap == .nowrap) out.min += gap * (count - 1);
    }
    return out;
}
