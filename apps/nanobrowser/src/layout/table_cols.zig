//! Table column widths: what each column asks for (CSS 2.1 §17.5.2.2's
//! non-normative auto layout, spans last) and how a table's width is divided
//! among them, auto and fixed.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const intrinsic_mod = @import("intrinsic.zig");
const table = @import("table.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;
const Grid = table.Grid;

/// What a cell asks.
const Asks = struct { min: f32, max: f32, fixed: f32, pct: f32 };

fn asksOf(c: *Ctx, x: *Box) Error!Asks {
    _ = try intrinsic_mod.of(c, x);
    const s = x.style;
    const e = ctx.edgesOf(s, 0);
    const bp = e.border.horizontal() + e.padding.horizontal();
    const min = x.lay.content_min;
    var out: Asks = .{ .min = min, .max = @max(min, x.lay.content_max), .fixed = 0, .pct = 0 };
    if (s.width.kind == .length) {
        if (s.width.pct != 0) {
            out.pct = @max(0, ctx.clean(s.width.pct));
        } else {
            const v = @max(0, ctx.clean(s.width.px));
            out.fixed = if (s.box_sizing == .border_box) @max(v, bp) else v + bp;
            out.fixed = @max(out.fixed, min);
            out.max = out.fixed;
        }
    }
    return out;
}

/// Fills the grid's `col_*`: single-column cells first, then spans, shortest first.
pub fn measure(c: *Ctx, g: *Grid, sx: f32) Error!void {
    @memset(g.col_min, 0);
    @memset(g.col_max, 0);
    @memset(g.col_fixed, 0);
    @memset(g.col_pct, 0);
    for (g.cells) |*cell| {
        if (cell.cols != 1) continue;
        const a = try asksOf(c, cell.b);
        const i = cell.col;
        g.col_min[i] = @max(g.col_min[i], a.min);
        g.col_max[i] = @max(g.col_max[i], a.max);
        g.col_fixed[i] = @max(g.col_fixed[i], a.fixed);
        g.col_pct[i] = @max(g.col_pct[i], a.pct);
    }
    for (g.col_spec, 0..) |l, i| {
        if (l.kind != .length) continue;
        if (l.pct != 0) {
            g.col_pct[i] = @max(g.col_pct[i], @max(0, ctx.clean(l.pct)));
        } else {
            const v = @max(0, ctx.clean(l.px));
            g.col_fixed[i] = @max(g.col_fixed[i], v);
            g.col_max[i] = @max(g.col_max[i], v);
        }
    }
    var spans: std.ArrayList(*table.Cell) = .empty;
    for (g.cells) |*cell| if (cell.cols > 1) try spans.append(c.arena, cell);
    std.mem.sort(*table.Cell, spans.items, {}, struct {
        fn less(_: void, p: *table.Cell, q: *table.Cell) bool {
            return p.cols < q.cols;
        }
    }.less);
    for (spans.items) |cell| {
        const a = try asksOf(c, cell.b);
        const from = cell.col;
        const to = cell.col + cell.cols;
        const between = sx * @as(f32, @floatFromInt(cell.cols - 1));
        widen(g.col_min[from..to], g.col_max[from..to], a.min - between);
        widen(g.col_max[from..to], g.col_max[from..to], a.max - between);
        if (a.pct > 0) {
            var have: f32 = 0;
            var open: f32 = 0;
            for (g.col_pct[from..to]) |v| {
                have += v;
                if (v == 0) open += 1;
            }
            if (a.pct > have and open > 0) {
                for (g.col_pct[from..to]) |*v| if (v.* == 0) {
                    v.* = (a.pct - have) / open;
                };
            }
        }
        if (a.fixed > 0) {
            var have: f32 = 0;
            for (g.col_fixed[from..to]) |v| have += v;
            const want = a.fixed - between;
            if (want > have) {
                for (g.col_fixed[from..to], g.col_max[from..to]) |*v, *m| {
                    v.* += (want - have) / @as(f32, @floatFromInt(cell.cols));
                    m.* = @max(m.*, v.*);
                }
            }
        }
    }
    for (g.col_min, g.col_max) |lo, *hi| hi.* = @max(hi.*, lo);
}

/// Adds what `want` is over their total to `cols`, in proportion to `weights`.
fn widen(cols: []f32, weights: []const f32, want: f32) void {
    var have: f32 = 0;
    for (cols) |v| have += v;
    const extra = want - have;
    if (extra <= 0) return;
    var sum: f32 = 0;
    for (weights) |w| sum += w;
    const n: f32 = @floatFromInt(cols.len);
    for (cols, weights) |*v, w| {
        v.* += if (sum > 0) extra * w / sum else extra / n;
    }
}

/// The table width at which its percent columns get their share: a 50%
/// column wanting 100 asks for 200 in all.
pub fn percentNeed(g: *const Grid) f32 {
    var sum_pct: f32 = 0;
    var rest: f32 = 0;
    var need: f32 = 0;
    for (g.col_pct, g.col_max) |p, m| {
        if (p > 0) {
            sum_pct += p;
            need = @max(need, m * 100 / p);
        } else rest += m;
    }
    if (sum_pct <= 0) return 0;
    if (sum_pct < 100) need = @max(need, rest * 100 / (100 - sum_pct));
    return @min(need, 1e6);
}

/// Divides `room` among the columns.
pub fn distribute(c: *Ctx, b: *Box, g: *Grid, room: f32) Error![]f32 {
    const widths = try c.arena.alloc(f32, g.ncols);
    if (g.ncols == 0) return widths;
    if (b.style.table_fixed and b.style.width.kind != .auto) {
        fixedLayout(g, widths, room);
        return widths;
    }
    // Percentages first, as much as remains of 100; then fixed; then auto.
    var left_pct: f32 = 100;
    for (widths, 0..) |*w, i| {
        const p = @min(g.col_pct[i], left_pct);
        left_pct -= p;
        if (p > 0) {
            w.* = @max(g.col_min[i], room * p / 100);
        } else if (g.col_fixed[i] > 0) {
            w.* = @max(g.col_min[i], g.col_fixed[i]);
        } else {
            w.* = g.col_max[i];
        }
    }
    var sum: f32 = 0;
    for (widths) |w| sum += w;
    if (sum > room) {
        shrink(g, widths, room, .auto);
        shrink(g, widths, room, .fixed);
        shrink(g, widths, room, .percent);
    } else if (sum < room) {
        grow(g, widths, room);
    }
    return widths;
}

const Class = enum { auto, fixed, percent };

fn classOf(g: *const Grid, i: usize) Class {
    if (g.col_pct[i] > 0) return .percent;
    if (g.col_fixed[i] > 0) return .fixed;
    return .auto;
}

/// Takes the excess from a class of columns, each giving in proportion to
/// what it has over its minimum.
fn shrink(g: *const Grid, widths: []f32, room: f32, class: Class) void {
    var sum: f32 = 0;
    for (widths) |w| sum += w;
    const excess = sum - room;
    if (excess <= 0) return;
    var give: f32 = 0;
    for (widths, 0..) |w, i| if (classOf(g, i) == class) {
        give += w - g.col_min[i];
    };
    if (give <= 0) return;
    const take = @min(1, excess / give);
    for (widths, 0..) |*w, i| if (classOf(g, i) == class) {
        w.* -= (w.* - g.col_min[i]) * take;
    };
}

/// What is spare goes to auto columns by their max widths; with none, to fixed
/// ones; with none, to percent ones.
fn grow(g: *const Grid, widths: []f32, room: f32) void {
    var sum: f32 = 0;
    for (widths) |w| sum += w;
    const extra = room - sum;
    for ([_]Class{ .auto, .fixed, .percent }) |class| {
        var n: f32 = 0;
        var weight: f32 = 0;
        for (widths, 0..) |w, i| if (classOf(g, i) == class) {
            n += 1;
            weight += if (class == .auto) g.col_max[i] else w;
        };
        if (n == 0) continue;
        for (widths, 0..) |*w, i| if (classOf(g, i) == class) {
            const share = if (class == .auto) g.col_max[i] else w.*;
            w.* += if (weight > 0) extra * share / weight else extra / n;
        };
        return;
    }
}

/// `table-layout: fixed`: `<col>` and the first row decide, others share what is left.
fn fixedLayout(g: *const Grid, widths: []f32, room: f32) void {
    @memset(widths, -1);
    for (g.col_spec, 0..) |l, i| if (l.kind == .length) {
        widths[i] = ctx.len(l, room);
    };
    if (g.rows.len > 0) {
        const first = g.rows[0];
        for (g.cells[first.first .. first.first + first.count]) |*cell| {
            const s = cell.b.style;
            if (s.width.kind != .length) continue;
            const e = ctx.edgesOf(s, room);
            const bp = e.border.horizontal() + e.padding.horizontal();
            const raw = @max(0, ctx.len(s.width, room));
            const whole = if (s.box_sizing == .border_box or s.width.hasPct()) raw else raw + bp;
            const each = whole / @as(f32, @floatFromInt(cell.cols));
            for (widths[cell.col .. cell.col + cell.cols]) |*w| {
                if (w.* < 0) w.* = each;
            }
        }
    }
    var used: f32 = 0;
    var open: f32 = 0;
    for (widths) |w| {
        if (w < 0) open += 1 else used += w;
    }
    const left = @max(0, room - used);
    for (widths) |*w| {
        if (w.* < 0) w.* = left / open;
    }
    if (open == 0 and used < room and used > 0) {
        for (widths) |*w| w.* += (room - used) * w.* / used;
    }
}
