//! Flexbox's second half: collecting items into lines, resolving flexible
//! lengths with the freeze loop, cross sizes, stretching, and where everything
//! goes along both axes.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const sizing = @import("sizing.zig");
const flex = @import("flex.zig");
const Item = flex.Item;
const Setup = flex.Setup;
const Error = ctx.Error;

const Line = struct {
    from: usize,
    to: usize,
    cross: f32 = 0,
    /// Baseline-aligned items: the most above and below the baseline.
    up: f32 = 0,
    down: f32 = 0,
    pos: f32 = 0,
};

fn collect(s: *const Setup, items: []Item) Error![]Line {
    var lines: std.ArrayList(Line) = .empty;
    const a = s.c.arena;
    const wrap = s.b.style.flex_wrap != .nowrap and s.main != null;
    var from: usize = 0;
    var sum: f32 = 0;
    for (items, 0..) |*it, i| {
        const size = it.mainOuter(it.hyp);
        if (wrap and i > from and sum + s.gap_main + size > s.main.? + 0.001) {
            try lines.append(a, .{ .from = from, .to = i });
            from = i;
            sum = 0;
        }
        sum += (if (i > from) s.gap_main else 0) + size;
    }
    if (items.len > 0) try lines.append(a, .{ .from = from, .to = items.len });
    return lines.items;
}

/// §9.7: resolves the line's main sizes against `main`.
fn resolve(line: []Item, main: f32, gap: f32) void {
    const gaps = gap * @as(f32, @floatFromInt(line.len -| 1));
    var sum_hyp: f32 = 0;
    for (line) |*it| sum_hyp += it.mainOuter(it.hyp);
    const grow = sum_hyp + gaps < main;
    var unfrozen: usize = 0;
    for (line) |*it| {
        const factor = if (grow) it.b.style.flex_grow else it.b.style.flex_shrink;
        it.frozen = factor <= 0 or (grow and it.base > it.hyp) or (!grow and it.base < it.hyp);
        it.target = it.hyp;
        if (!it.frozen) unfrozen += 1;
    }
    var initial_free = main - gaps;
    for (line) |*it| initial_free -= it.mainOuter(if (it.frozen) it.target else it.base);

    var guard: usize = line.len + 2;
    while (unfrozen > 0 and guard > 0) : (guard -= 1) {
        var free = main - gaps;
        var sum_factor: f32 = 0;
        var sum_scaled: f32 = 0;
        for (line) |*it| {
            free -= it.mainOuter(if (it.frozen) it.target else it.base);
            if (it.frozen) continue;
            const st = it.b.style;
            sum_factor += if (grow) ctx.clean(st.flex_grow) else ctx.clean(st.flex_shrink);
            sum_scaled += ctx.clean(st.flex_shrink) * innerBase(it);
        }
        if (sum_factor < 1) {
            const scaled = initial_free * sum_factor;
            if (@abs(scaled) < @abs(free)) free = scaled;
        }
        var violation: f32 = 0;
        for (line) |*it| {
            if (it.frozen) continue;
            const st = it.b.style;
            var t = it.base;
            if (grow) {
                if (sum_factor > 0) t += free * ctx.clean(st.flex_grow) / sum_factor;
            } else if (sum_scaled > 0) {
                t += free * ctx.clean(st.flex_shrink) * innerBase(it) / sum_scaled;
            }
            const clamped = std.math.clamp(t, it.min, it.max);
            violation += clamped - t;
            it.target = clamped;
        }
        for (line) |*it| {
            if (it.frozen) continue;
            const t_raw = rawTarget(it, grow, free, sum_factor, sum_scaled);
            const min_hit = it.target > t_raw;
            const max_hit = it.target < t_raw;
            const freeze = if (violation == 0) true else if (violation > 0) min_hit else max_hit;
            if (freeze) {
                it.frozen = true;
                unfrozen -= 1;
            }
        }
    }
}

fn rawTarget(it: *const Item, grow: bool, free: f32, sum_factor: f32, sum_scaled: f32) f32 {
    const st = it.b.style;
    if (grow) return if (sum_factor > 0) it.base + free * ctx.clean(st.flex_grow) / sum_factor else it.base;
    return if (sum_scaled > 0) it.base + free * ctx.clean(st.flex_shrink) * innerBase(it) / sum_scaled else it.base;
}

fn innerBase(it: *const Item) f32 {
    return @max(0, it.base - it.bp);
}

/// Where a line's cross size comes from, its items' cross sizes.
fn crossSizes(s: *const Setup, items: []Item, line: *Line, item_ch: ?f32) Error!void {
    const c = s.c;
    for (items[line.from..line.to]) |*it| {
        const k = it.b;
        if (s.row) {
            if (it.align_self == .baseline and !it.cs_auto and !it.ce_auto) {
                _ = try sizing.place(c, k, it.target, item_ch, null);
                it.cross = k.h;
                const base = k.lay.first_baseline orelse k.h;
                it.ascent = base + it.cs;
                line.up = @max(line.up, it.ascent);
                line.down = @max(line.down, it.crossOuter() - it.ascent);
                continue;
            }
            it.cross = try sizing.measureH(c, k, it.target, item_ch);
        }
        line.cross = @max(line.cross, it.crossOuter());
    }
    line.cross = @max(line.cross, line.up + line.down);
}

fn distribute(a: css.Align, free: f32, n: usize) struct { start: f32, between: f32, each: f32 } {
    const count: f32 = @floatFromInt(n);
    return switch (a) {
        .auto, .normal, .stretch => if (free > 0) .{ .start = 0, .between = 0, .each = free / count } else .{ .start = 0, .between = 0, .each = 0 },
        .start, .baseline => .{ .start = 0, .between = 0, .each = 0 },
        .end => .{ .start = free, .between = 0, .each = 0 },
        .center => .{ .start = free / 2, .between = 0, .each = 0 },
        .space_between => if (free > 0 and n > 1) .{ .start = 0, .between = free / (count - 1), .each = 0 } else .{ .start = 0, .between = 0, .each = 0 },
        .space_around => if (free > 0) .{ .start = free / count / 2, .between = free / count, .each = 0 } else .{ .start = free / 2, .between = 0, .each = 0 },
        .space_evenly => if (free > 0) .{ .start = free / (count + 1), .between = free / (count + 1), .each = 0 } else .{ .start = free / 2, .between = 0, .each = 0 },
    };
}

/// Runs the rest of the algorithm over `items`, already in `order` and with
/// their hypothetical sizes; gives back the height of the content box.
pub fn run(s: *const Setup, items: []Item) Error!f32 {
    const b = s.b;
    const st = b.style;
    b.lay.first_baseline = null;
    b.lay.last_baseline = null;
    if (items.len == 0) return 0;
    const lines = try collect(s, items);

    // Main sizes.
    var longest: f32 = 0;
    for (lines) |*line| {
        const part = items[line.from..line.to];
        var sum: f32 = s.gap_main * @as(f32, @floatFromInt(part.len -| 1));
        for (part) |*it| sum += it.mainOuter(it.hyp);
        resolve(part, s.main orelse sum, s.gap_main);
        var used: f32 = s.gap_main * @as(f32, @floatFromInt(part.len -| 1));
        for (part) |*it| used += it.mainOuter(it.target);
        longest = @max(longest, used);
    }

    // Cross sizes.
    const item_ch: ?f32 = if (s.row) s.ch else null;
    for (lines) |*line| try crossSizes(s, items, line, item_ch);
    if (lines.len == 1 and st.flex_wrap == .nowrap) {
        if (s.cross) |cross| lines[0].cross = cross;
    }
    var total_cross = s.gap_cross * @as(f32, @floatFromInt(lines.len -| 1));
    for (lines) |*line| total_cross += line.cross;

    const used_cross = s.cross orelse total_cross;
    const ac = distribute(if (st.flex_wrap == .nowrap) .start else st.align_content, used_cross - total_cross, lines.len);
    var cursor = ac.start;
    if (st.flex_wrap == .wrap_reverse) {
        var i = lines.len;
        while (i > 0) {
            i -= 1;
            lines[i].cross += ac.each;
            lines[i].pos = cursor;
            cursor += lines[i].cross + s.gap_cross + ac.between;
        }
    } else {
        for (lines) |*line| {
            line.cross += ac.each;
            line.pos = cursor;
            cursor += line.cross + s.gap_cross + ac.between;
        }
    }

    const main_size = s.main orelse longest;
    const dir = st.flex_direction;
    var flip_main = dir == .row_reverse or dir == .column_reverse;
    if (s.row and st.rtl) flip_main = !flip_main;
    const left = ctx.bpLeft(b);
    const top = ctx.bpTop(b);
    for (lines) |*line| {
        const part = items[line.from..line.to];
        try placeLine(s, part, line, main_size, flip_main, left, top);
    }
    if (items.len > 0) {
        const f = items[0].b;
        const base = f.y + (f.lay.first_baseline orelse f.h);
        b.lay.first_baseline = base;
        b.lay.last_baseline = base;
    }
    return if (s.row) @max(total_cross, 0) else longest;
}

fn placeLine(s: *const Setup, part: []Item, line: *const Line, main_size: f32, flip: bool, left: f32, top: f32) Error!void {
    const c = s.c;
    const st = s.b.style;
    var free = main_size - s.gap_main * @as(f32, @floatFromInt(part.len -| 1));
    var autos: f32 = 0;
    for (part) |*it| {
        free -= it.mainOuter(it.target);
        if (it.ms_auto) autos += 1;
        if (it.me_auto) autos += 1;
    }
    var per_auto: f32 = 0;
    var start: f32 = 0;
    var between: f32 = 0;
    if (autos > 0 and free > 0) {
        per_auto = free / autos;
    } else {
        const a: css.Align = switch (st.justify_content) {
            .normal, .start, .stretch => .start,
            .end => .end,
            .center => .center,
            .space_between => .space_between,
            .space_around => .space_around,
            .space_evenly => .space_evenly,
        };
        const d = distribute(a, free, part.len);
        start = d.start;
        between = d.between;
    }
    var pos = start;
    for (part) |*it| {
        const k = it.b;
        pos += if (it.ms_auto) per_auto else 0;
        const main_at = pos + it.ms;
        pos = main_at + it.target + it.me + (if (it.me_auto) per_auto else 0) + s.gap_main + between;

        // The cross size, stretched or not.
        const inner_ch: ?f32 = if (s.row) s.ch else null;
        if (s.row) {
            const stretched: ?f32 = if (it.stretches(true)) @max(0, line.cross - it.cs - it.ce) else null;
            _ = try sizing.place(c, k, it.target, inner_ch, stretched);
            it.cross = k.h;
        } else {
            if (it.stretches(false)) {
                const w = try ctx.clampW(c, k, @max(0, line.cross - it.cs - it.ce), s.cw, ctx.bpH(k));
                it.cross = @max(w, ctx.bpH(k));
            }
            _ = try sizing.layoutBfc(c, k, it.cross, it.target);
            it.cross = k.w;
        }
        const size_main = if (s.row) k.w else k.h;
        const room = line.cross - it.crossOuter();
        var off: f32 = 0;
        if (it.cs_auto or it.ce_auto) {
            if (room > 0) {
                if (it.cs_auto and it.ce_auto) off = room / 2 else if (it.cs_auto) off = room;
            }
        } else switch (it.align_self) {
            .end => off = room,
            .center => off = room / 2,
            .baseline => off = line.up - it.ascent,
            else => {},
        }
        const cross_at = line.pos + it.cs + off;
        const main_final = if (flip) main_size - main_at - size_main else main_at;
        if (s.row) {
            k.margin.left = if (it.ms_auto) per_auto else it.ms;
            k.margin.right = if (it.me_auto) per_auto else it.me;
            k.x = left + main_final;
            k.y = top + cross_at;
        } else {
            k.margin.top = if (it.ms_auto) per_auto else it.ms;
            k.margin.bottom = if (it.me_auto) per_auto else it.me;
            k.x = left + cross_at;
            k.y = top + main_final;
        }
    }
}
