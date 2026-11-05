//! Grid track sizing, after CSS Grid §11: base sizes and growth limits from
//! the items' contributions, non-spanning first and then spanning, spare room
//! up to the limits, then `fr`, then stretching what is left into auto tracks.
const std = @import("std");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const grid = @import("grid.zig");
const intrinsic_mod = @import("intrinsic.zig");
const Allocator = ctx.Allocator;
const Ctx = ctx.Ctx;
const Error = ctx.Error;
const Placed = grid.Placed;
const inf = std.math.inf(f32);

pub const Track = struct {
    spec: css.Track,
    base: f32 = 0,
    limit: f32 = inf,
    /// `auto-fit` and nothing in it: no size, and no gap after it.
    collapsed: bool = false,
};

/// `total` tracks: the template's starting at index `shift`, implicit ones around.
pub fn make(a: Allocator, template: []const css.Track, implicit: css.Track, shift: i32, count: i32) Error![]Track {
    const out = try a.alloc(Track, @intCast(@max(count, 0)));
    for (out, 0..) |*t, i| {
        const at = @as(i32, @intCast(i)) - shift;
        const spec = if (at >= 0 and at < template.len) template[@intCast(at)] else implicit;
        t.* = .{ .spec = spec };
    }
    return out;
}

fn isFlexible(t: *const Track) bool {
    return t.spec.kind == .fr or (t.spec.kind == .minmax and t.spec.fr > 0);
}

fn frOf(t: *const Track) f32 {
    return @max(0, ctx.clean(t.spec.fr));
}

/// Whether contributions can raise the track's base size.
fn intrinsicMin(t: *const Track) bool {
    return switch (t.spec.kind) {
        .auto, .min_content, .max_content, .fr => true,
        .minmax => t.spec.min_auto,
        .fixed => false,
    };
}

/// Whether max-content contributions raise the growth limit.
fn intrinsicMax(t: *const Track) bool {
    return switch (t.spec.kind) {
        .auto, .max_content => true,
        .minmax => t.spec.fr == 0 and t.spec.max_px < 0,
        else => false,
    };
}

/// A fixed track's size, or `minmax`'s least, against `ref`.
pub fn least(s: css.Track, ref: f32) f32 {
    if (s.math) |m| return ctx.clean(m.at(ref));
    return ctx.clean(s.px) + ctx.clean(s.pct) * ref / 100;
}

/// `minmax`'s most, or `fit-content`'s limit, against `ref`.
fn most(s: css.Track, ref: f32) f32 {
    if (s.max_math) |m| return ctx.clean(m.at(ref));
    return ctx.clean(s.max_px) + ctx.clean(s.max_pct) * ref / 100;
}

/// The starting base sizes and growth limits. Percentages of an unknown size act as auto.
fn start(list: []Track, avail: ?f32) void {
    for (list) |*t| {
        const s = t.spec;
        t.base = 0;
        t.limit = inf;
        switch (s.kind) {
            .fixed => {
                if (s.pct != 0 and avail == null) {
                    t.spec.kind = .auto;
                } else {
                    t.base = @max(0, least(s, avail orelse 0));
                    t.limit = t.base;
                }
            },
            .minmax => {
                if (!s.min_auto) t.base = @max(0, least(s, avail orelse 0));
                if (s.max_px >= 0) t.limit = @max(t.base, most(s, avail orelse 0));
            },
            else => {},
        }
        if (t.collapsed) {
            t.base = 0;
            t.limit = 0;
        }
    }
}

fn spanRange(list: []Track, s: i32, e: i32) []Track {
    const a: usize = @intCast(@max(s, 0));
    const b: usize = @intCast(@min(@max(e, 0), @as(i32, @intCast(list.len))));
    return if (a < b) list[a..b] else list[0..0];
}

pub const Contribution = struct { lo: f32, hi: f32, from: i32, to: i32 };

fn gapsIn(part: []const Track, gap: f32) f32 {
    var n: f32 = 0;
    for (part) |*t| if (!t.collapsed) {
        n += 1;
    };
    return gap * @max(0, n - 1);
}

/// Adds `extra` to `part`'s bases, equally among those with `pick`.
fn share(part: []Track, extra: f32, comptime pick: fn (*const Track) bool) void {
    var n: f32 = 0;
    for (part) |*t| if (pick(t) and !t.collapsed) {
        n += 1;
    };
    if (n == 0) return;
    for (part) |*t| if (pick(t) and !t.collapsed) {
        t.base += extra / n;
    };
}

/// §11.5: raises bases and limits for the items' contributions.
fn resolveIntrinsics(list: []Track, cons: []Contribution, gap: f32) void {
    // One track first.
    for (cons) |con| {
        if (con.to - con.from != 1) continue;
        const part = spanRange(list, con.from, con.to);
        if (part.len == 0) continue;
        const t = &part[0];
        if (t.collapsed) continue;
        switch (t.spec.kind) {
            .max_content => {
                t.base = @max(t.base, con.hi);
                if (t.limit == inf) t.limit = con.hi else t.limit = @max(t.limit, con.hi);
            },
            .min_content => {
                t.base = @max(t.base, con.lo);
                if (t.limit == inf) t.limit = con.lo else t.limit = @max(t.limit, con.lo);
            },
            else => {
                if (intrinsicMin(t)) t.base = @max(t.base, con.lo);
                if (intrinsicMax(t)) {
                    if (t.limit == inf) t.limit = con.hi else t.limit = @max(t.limit, con.hi);
                }
            },
        }
    }
    // Then the spans, shortest first.
    std.mem.sort(Contribution, cons, {}, struct {
        fn less(_: void, a: Contribution, b: Contribution) bool {
            return a.to - a.from < b.to - b.from;
        }
    }.less);
    for (cons) |con| {
        if (con.to - con.from <= 1) continue;
        const part = spanRange(list, con.from, con.to);
        if (part.len == 0) continue;
        var bases: f32 = gapsIn(part, gap);
        var limits: f32 = gapsIn(part, gap);
        var crosses_fr = false;
        for (part) |*t| {
            bases += t.base;
            limits += if (t.limit == inf) t.base else t.limit;
            crosses_fr = crosses_fr or isFlexible(t);
        }
        const extra = con.lo - bases;
        if (extra > 0) {
            if (crosses_fr) share(part, extra, isFlexible) else share(part, extra, intrinsicMin);
        }
        const more = con.hi - limits;
        if (more > 0 and !crosses_fr) {
            var n: f32 = 0;
            for (part) |*t| if (intrinsicMax(t) and !t.collapsed) {
                n += 1;
            };
            if (n > 0) for (part) |*t| if (intrinsicMax(t) and !t.collapsed) {
                t.limit = (if (t.limit == inf) t.base else t.limit) + more / n;
            };
        }
    }
    for (list) |*t| {
        if (t.limit < t.base) t.limit = t.base;
    }
}

/// §11.6: spare room up to the growth limits.
fn maximize(list: []Track, free_in: f32) void {
    var free = free_in;
    var guard: usize = list.len + 2;
    while (free > 0.001 and guard > 0) : (guard -= 1) {
        var open: f32 = 0;
        for (list) |*t| if (t.limit != inf and t.limit > t.base and !isFlexible(t)) {
            open += 1;
        };
        if (open == 0) return;
        const each = free / open;
        for (list) |*t| if (t.limit != inf and t.limit > t.base and !isFlexible(t)) {
            const add = @min(each, t.limit - t.base);
            t.base += add;
            free -= add;
        };
    }
}

/// §11.7: the size of 1fr with `room` for all the tracks, those too large at it set aside.
fn findFr(list: []const Track, room: f32) f32 {
    var used = room;
    var flex: f32 = 0;
    for (list) |*t| {
        if (t.collapsed) continue;
        if (isFlexible(t)) flex += frOf(t) else used -= t.base;
    }
    if (flex <= 0) return 0;
    var share_size = @max(0, used) / @max(flex, 1);
    // Flexible tracks whose base is over their share leave the rest less.
    var guard: usize = list.len + 2;
    while (guard > 0) : (guard -= 1) {
        var again = false;
        var left = room;
        var sum: f32 = 0;
        for (list) |*t| {
            if (t.collapsed) continue;
            if (!isFlexible(t)) {
                left -= t.base;
            } else if (t.base > share_size * frOf(t)) {
                left -= t.base;
                again = true;
            } else sum += frOf(t);
        }
        if (!again) break;
        const next = @max(0, left) / @max(sum, 1);
        if (next == share_size) break;
        share_size = next;
    }
    return share_size;
}

fn expandFlexible(list: []Track, fr_size: f32) void {
    for (list) |*t| if (isFlexible(t) and !t.collapsed) {
        t.base = @max(t.base, fr_size * frOf(t));
        t.limit = t.base;
    };
}

/// §11.8: what is left goes equally into auto tracks.
fn stretchAuto(list: []Track, free: f32) void {
    if (free <= 0) return;
    var n: f32 = 0;
    for (list) |*t| if (isAutoMax(t) and !t.collapsed) {
        n += 1;
    };
    if (n == 0) return;
    for (list) |*t| if (isAutoMax(t) and !t.collapsed) {
        t.base += free / n;
    };
}

fn isAutoMax(t: *const Track) bool {
    if (t.spec.fit) return false;
    return t.spec.kind == .auto or (t.spec.kind == .minmax and t.spec.fr == 0 and t.spec.max_px < 0);
}

pub fn total(list: []const Track, gap: f32) f32 {
    var sum: f32 = gapsIn(list, gap);
    for (list) |*t| sum += t.base;
    return sum;
}

/// `fit-content(limit)`: the track's most stops at its limit, but no lower than its least.
fn capFitContent(list: []Track, avail: ?f32) void {
    for (list) |*t| {
        if (!t.spec.fit) continue;
        const cap = @max(t.base, most(t.spec, avail orelse 0));
        t.limit = if (t.limit == inf) cap else @min(t.limit, cap);
    }
}

fn sizeAxis(list: []Track, cons: []Contribution, avail: ?f32, gap: f32, stretch: bool) void {
    start(list, avail);
    resolveIntrinsics(list, cons, gap);
    capFitContent(list, avail);
    if (avail) |room| {
        maximize(list, room - total(list, gap));
        const gaps = gapsIn(list, gap);
        expandFlexible(list, findFr(list, room - gaps));
        if (stretch) stretchAuto(list, room - total(list, gap));
    } else {
        // Without a size to fill, 1fr is what the largest item asks of it.
        var fr_size: f32 = 0;
        for (cons) |con| {
            const part = spanRange(list, con.from, con.to);
            var flex: f32 = 0;
            var rest: f32 = gapsIn(part, gap);
            for (part) |*t| {
                if (isFlexible(t)) flex += frOf(t) else rest += t.base;
            }
            if (flex > 0) fr_size = @max(fr_size, (con.hi - rest) / @max(flex, 1));
        }
        for (list) |*t| {
            if (!isFlexible(t) and t.limit != inf) t.base = @max(t.base, t.limit);
        }
        expandFlexible(list, fr_size);
    }
    for (list) |*t| t.limit = t.base;
}

/// Spanning more than one track, a flexible one among them: such an item has no
/// automatic minimum size (CSS Grid §6.6), and its content can't push the tracks.
fn crossesFlexible(list: []Track, from: i32, to: i32) bool {
    if (to - from <= 1) return false;
    for (spanRange(list, from, to)) |*t| if (isFlexible(t)) return true;
    return false;
}

fn columnContributions(c: *Ctx, list: []Track, items: []const Placed, only_min: bool) Error![]Contribution {
    var cons: std.ArrayList(Contribution) = .empty;
    for (items) |*it| {
        // A subgrid asks through what's in it, track by track.
        if (it.b.kind == .grid and it.b.style.grid_template_columns.subgrid) {
            for (try grid.subPlacement(c, it.b)) |*sub| {
                const o = try intrinsic_mod.outer(c, sub.b);
                try cons.append(c.arena, .{ .lo = o.min, .hi = if (only_min) o.min else o.max, .from = it.c0 + sub.c0, .to = it.c0 + sub.c1 });
            }
            continue;
        }
        const o = try intrinsic_mod.outer(c, it.b);
        const no_auto_min = it.b.style.min_width.kind == .auto and (it.b.style.clips() or (it.b.style.width.kind == .auto and crossesFlexible(list, it.c0, it.c1)));
        const lo = if (no_auto_min) @min(o.min, ctx.edgesOf(it.b.style, 0).margin.horizontal() + borderPad(it.b)) else o.min;
        const hi = if (only_min) o.min else o.max;
        try cons.append(c.arena, .{ .lo = lo, .hi = hi, .from = it.c0, .to = it.c1 });
    }
    return cons.items;
}

fn borderPad(b: anytype) f32 {
    const e = ctx.edgesOf(b.style, 0);
    return e.border.horizontal() + e.padding.horizontal();
}

pub fn sizeColumns(c: *Ctx, list: []Track, items: []const Placed, avail: f32, gap: f32, stretch: bool) Error!void {
    const cons = try columnContributions(c, list, items, false);
    sizeAxis(list, cons, avail, gap, stretch);
}

pub fn sizeRows(a: Allocator, list: []Track, items: []const Placed, heights: []const f32, extra: []const Contribution, avail: ?f32, gap: f32, stretch: bool) Error!void {
    const cons = try a.alloc(Contribution, items.len + extra.len);
    for (items, heights, 0..) |*it, h, i| {
        const none = it.b.style.height.kind == .auto and it.b.style.min_height.kind == .auto and crossesFlexible(list, it.r0, it.r1);
        cons[i] = .{ .lo = if (none) 0 else h, .hi = h, .from = it.r0, .to = it.r1 };
    }
    @memcpy(cons[items.len..], extra);
    sizeAxis(list, cons, avail, gap, stretch);
}

/// The columns' total when nothing asks for a particular width.
pub fn intrinsicColumns(c: *Ctx, list: []Track, items: []const Placed, gap: f32, want_max: bool) Error!f32 {
    const cons = try columnContributions(c, list, items, !want_max);
    sizeAxis(list, cons, null, gap, false);
    return total(list, gap);
}

/// The start of each track, with `align-content` or `justify-content` applied.
pub fn positions(a: Allocator, list: []const Track, avail: f32, gap: f32, how: css.Align) Error![]f32 {
    const out = try a.alloc(f32, list.len + 1);
    const free = avail - total(list, gap);
    const n: f32 = @floatFromInt(@max(list.len, 1));
    var at: f32 = 0;
    var between: f32 = 0;
    switch (how) {
        .end => at = free,
        .center => at = free / 2,
        .space_between => if (free > 0 and n > 1) {
            between = free / (n - 1);
        },
        .space_around => if (free > 0) {
            between = free / n;
            at = between / 2;
        } else {
            at = free / 2;
        },
        .space_evenly => if (free > 0) {
            between = free / (n + 1);
            at = between;
        } else {
            at = free / 2;
        },
        else => {},
    }
    for (list, 0..) |*t, i| {
        out[i] = at;
        if (t.collapsed) continue;
        at += t.base + gap + between;
    }
    out[list.len] = at;
    return out;
}

/// The size of the tracks from `s` to `e` with the gaps between.
pub fn areaSize(list: []const Track, s: i32, e: i32, gap: f32) f32 {
    const a: usize = @intCast(@max(s, 0));
    const b: usize = @intCast(@min(@max(e, 0), @as(i32, @intCast(list.len))));
    if (a >= b) return 0;
    const part = list[a..b];
    var sum = gapsIn(part, gap);
    for (part) |*t| sum += t.base;
    return sum;
}
