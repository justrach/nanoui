//! Tables: analysing the grid of cells, the widths the table asks for, then
//! rows and where everything goes. Column widths are `table_cols.zig`'s.
//! Coordinates: groups in the table, rows in their group, cells in their row.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const sizing = @import("sizing.zig");
const intrinsic_mod = @import("intrinsic.zig");
const cols_mod = @import("table_cols.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

pub const Cell = struct { b: *Box, row: u32, col: u32, rows: u32, cols: u32 };
pub const Row = struct { b: *Box, group: *Box, first: u32 = 0, count: u32 = 0 };

/// A table's structure, kept on its box for as long as the tree lasts.
pub const Grid = struct {
    rows: []Row,
    cells: []Cell,
    captions: []*Box,
    ncols: u32,
    /// `<col>` widths, one for each column, kind auto where there is none.
    col_spec: []css.Len,
    /// What each column asks for, and the table's own widths from those.
    col_min: []f32,
    col_max: []f32,
    col_fixed: []f32,
    col_pct: []f32,
    min_w: f32 = 0,
    max_w: f32 = 0,
    measured: bool = false,
};

fn spacingX(s: *const css.Style) f32 {
    return if (s.border_collapse) 0 else @max(0, ctx.clean(s.border_spacing));
}

fn spacingY(s: *const css.Style) f32 {
    return if (s.border_collapse) 0 else @max(0, ctx.clean(s.border_spacing_y));
}

fn spanAttr(n: ?*const @import("../dom.zig").Node, name: []const u8) u32 {
    const node = n orelse return 1;
    const raw = std.mem.trim(u8, node.attr(name) orelse return 1, " \t\r\n");
    const v = std.fmt.parseInt(u32, raw, 10) catch return 1;
    return v;
}

pub fn analyse(c: *Ctx, b: *Box) Error!*Grid {
    if (b.lay.table) |p| return @ptrCast(@alignCast(p));
    const a = c.arena;
    var rows: std.ArrayList(Row) = .empty;
    var cells: std.ArrayList(Cell) = .empty;
    var captions: std.ArrayList(*Box) = .empty;
    var heads: std.ArrayList(*Box) = .empty;
    var bodies: std.ArrayList(*Box) = .empty;
    var feet: std.ArrayList(*Box) = .empty;
    var k = b.first_child;
    while (k) |x| : (k = x.next) switch (x.kind) {
        .table_caption => try captions.append(a, x),
        .table_row_group => switch (x.style.display) {
            .table_header_group => try heads.append(a, x),
            .table_footer_group => try feet.append(a, x),
            else => try bodies.append(a, x),
        },
        else => {},
    };
    // Each group's row spans stop at its end.
    var busy: std.ArrayList(u32) = .empty;
    var ncols: u32 = 0;
    for ([_][]*Box{ heads.items, bodies.items, feet.items }) |groups| for (groups) |g| {
        var group_rows: u32 = 0;
        var r = g.first_child;
        while (r) |x| : (r = x.next) if (x.kind == .table_row) {
            group_rows += 1;
        };
        busy.clearRetainingCapacity();
        var index: u32 = 0;
        r = g.first_child;
        while (r) |x| : (r = x.next) {
            if (x.kind != .table_row) continue;
            var row: Row = .{ .b = x, .group = g, .first = @intCast(cells.items.len) };
            const row_index: u32 = @intCast(rows.items.len);
            var col: u32 = 0;
            var q = x.first_child;
            while (q) |cell| : (q = cell.next) {
                if (cell.kind != .table_cell) continue;
                while (col < busy.items.len and busy.items[col] > 0) col += 1;
                const span_c = @max(1, @min(spanAttr(cell.node, "colspan"), 1000));
                const raw_r = spanAttr(cell.node, "rowspan");
                const left = group_rows - index;
                const span_r = if (raw_r == 0) left else @max(1, @min(raw_r, left));
                while (busy.items.len < col + span_c) try busy.append(a, 0);
                for (busy.items[col .. col + span_c]) |*v| v.* = span_r;
                try cells.append(a, .{ .b = cell, .row = row_index, .col = col, .rows = span_r, .cols = span_c });
                col += span_c;
                row.count += 1;
            }
            ncols = @max(ncols, @as(u32, @intCast(busy.items.len)));
            for (busy.items) |*v| v.* -|= 1;
            try rows.append(a, row);
            index += 1;
        }
    };
    const specs = try colElements(c, b);
    ncols = @max(ncols, @as(u32, @intCast(specs.len)));
    const col_spec = try a.alloc(css.Len, ncols);
    for (col_spec, 0..) |*v, i| v.* = if (i < specs.len) specs[i] else .auto;
    const g = try a.create(Grid);
    g.* = .{
        .rows = rows.items,
        .cells = cells.items,
        .captions = captions.items,
        .ncols = ncols,
        .col_spec = col_spec,
        .col_min = try a.alloc(f32, ncols),
        .col_max = try a.alloc(f32, ncols),
        .col_fixed = try a.alloc(f32, ncols),
        .col_pct = try a.alloc(f32, ncols),
    };
    b.lay.table = g;
    if (b.style.border_collapse) try @import("table_collapse.zig").resolve(c, b, g);
    return g;
}

/// The widths `<col>` and `<colgroup>` give: from their width attribute or style.
fn colElements(c: *Ctx, b: *Box) Error![]css.Len {
    var out: std.ArrayList(css.Len) = .empty;
    const n = b.node orelse return out.items;
    var k = n.first_child;
    while (k) |x| : (k = x.next) {
        if (x.isTag("col")) {
            try addCols(c, &out, x, .auto);
        } else if (x.isTag("colgroup")) {
            const own = colWidth(x);
            var any = false;
            var q = x.first_child;
            while (q) |y| : (q = y.next) if (y.isTag("col")) {
                any = true;
                try addCols(c, &out, y, own);
            };
            if (!any) try addCols(c, &out, x, own);
        }
    }
    return out.items;
}

fn colWidth(n: *const @import("../dom.zig").Node) css.Len {
    if (n.computed) |s| if (s.width.kind == .length) return s.width;
    if (@import("replaced.zig").dimAttr(n, "width")) |d| return if (d.pct) .{ .pct = d.px } else .{ .px = d.px };
    return .auto;
}

fn addCols(c: *Ctx, out: *std.ArrayList(css.Len), n: *const @import("../dom.zig").Node, fallback: css.Len) Error!void {
    const own = colWidth(n);
    const w = if (own.kind == .length) own else fallback;
    var span = @min(@max(spanAttr(n, "span"), 1), 1000);
    while (span > 0) : (span -= 1) try out.append(c.arena, w);
}

/// The table's widths (border box), from its columns and captions.
fn measured(c: *Ctx, b: *Box) Error!*Grid {
    const g = try analyse(c, b);
    if (g.measured) return g;
    try cols_mod.measure(c, g, spacingX(b.style));
    const n: f32 = @floatFromInt(g.ncols);
    const spacing = if (g.ncols > 0) spacingX(b.style) * (n + 1) else 0;
    const e = ctx.edgesOf(b.style, 0);
    const bp = e.border.horizontal() + e.padding.horizontal();
    var lo: f32 = 0;
    var hi: f32 = 0;
    for (g.col_min, g.col_max) |a, z| {
        lo += a;
        hi += z;
    }
    hi = @max(hi, cols_mod.percentNeed(g));
    g.min_w = lo + spacing + bp;
    g.max_w = @max(hi + spacing, lo + spacing) + bp;
    for (g.captions) |cap| {
        const i = try intrinsic_mod.of(c, cap);
        g.min_w = @max(g.min_w, i.min + bp);
    }
    g.measured = true;
    return g;
}

pub fn intrinsic(c: *Ctx, b: *Box) Error!intrinsic_mod.Sizes {
    const g = try measured(c, b);
    return .{ .min = g.min_w, .max = g.max_w };
}

/// The table's border-box width in a container `cw` wide.
pub fn usedWidth(c: *Ctx, b: *Box, cw: f32) Error!f32 {
    const g = try measured(c, b);
    const bp = ctx.bpH(b);
    var w: f32 = 0;
    if (try ctx.specW(c, b, b.style.width, cw, bp)) |v| {
        w = v;
    } else {
        w = @min(g.max_w, @max(g.min_w, cw - b.margin.horizontal()));
    }
    w = try ctx.clampW(c, b, w, cw, bp);
    return @max(w, g.min_w);
}

fn caption(c: *Ctx, cap: *Box, width: f32) Error!f32 {
    ctx.setEdges(cap, width);
    const w = @max(ctx.bpH(cap), width - cap.margin.horizontal());
    return sizing.place(c, cap, w, null, null);
}

/// Lays the table out in a content box `cw` wide; gives back its height.
pub fn layout(c: *Ctx, b: *Box, cw_in: f32, ch: ?f32) Error!f32 {
    const g = try measured(c, b);
    const s = b.style;
    b.runs = &.{};
    b.marker = null;
    const a = c.arena;
    const sx = spacingX(s);
    const sy = spacingY(s);
    const n: f32 = @floatFromInt(g.ncols);
    const room = @max(0, cw_in - (if (g.ncols > 0) sx * (n + 1) else 0));
    const widths = try cols_mod.distribute(c, b, g, room);
    var used: f32 = 0;
    for (widths) |w| used += w;
    if (g.ncols > 0) used += sx * (n + 1);
    const table_w = @max(used, cw_in);
    if (used > cw_in) b.w = used + ctx.bpH(b);

    const col_x = try a.alloc(f32, g.ncols + 1);
    var at: f32 = sx;
    for (widths, 0..) |w, i| {
        col_x[i] = at;
        at += w + sx;
    }
    col_x[g.ncols] = at;

    // Row heights, by the cells in each.
    const nrows = g.rows.len;
    const row_h = try a.alloc(f32, nrows);
    const up = try a.alloc(f32, nrows);
    @memset(up, 0);
    for (g.rows, 0..) |*r, i| {
        const rs = r.b.style;
        ctx.setEdges(r.b, table_w);
        ctx.setEdges(r.group, table_w);
        row_h[i] = if (ctx.specH(r.b, rs.height, ch, 0)) |v| v else 0;
    }
    const down = try a.alloc(f32, nrows);
    @memset(down, 0);
    for (g.cells) |*cell| {
        const x = cell.b;
        ctx.setEdges(x, table_w);
        const w = cellWidth(x, col_x, cell, sx);
        const bpv = ctx.bpV(x);
        var h = try sizing.measureAuto(c, x, w);
        if (ctx.specH(x, x.style.height, null, bpv)) |v| h = @max(h, v);
        if (cell.rows == 1) {
            if (x.style.vertical_align == .baseline) {
                _ = try sizing.layoutBfc(c, x, w, null);
                const base = x.lay.first_baseline orelse h;
                up[cell.row] = @max(up[cell.row], base);
                down[cell.row] = @max(down[cell.row], h - base);
                row_h[cell.row] = @max(row_h[cell.row], up[cell.row] + down[cell.row]);
            }
            row_h[cell.row] = @max(row_h[cell.row], h);
        }
    }
    try rowSpans(c, g, row_h, sy);

    // A definite table height spreads over the rows.
    var cap_top: f32 = 0;
    var cap_bottom: f32 = 0;
    for (g.captions) |cap| {
        const h = (try caption(c, cap, cw_in)) + cap.margin.vertical();
        if (cap.style.caption_bottom) cap_bottom += h else cap_top += h;
    }
    var rows_total: f32 = if (nrows > 0) sy * @as(f32, @floatFromInt(nrows + 1)) else 0;
    for (row_h) |h| rows_total += h;
    if (ch) |d| spread(row_h, d - cap_top - cap_bottom - rows_total);

    // Positions.
    const row_y = try a.alloc(f32, nrows + 1);
    var y: f32 = sy;
    for (row_h, 0..) |h, i| {
        row_y[i] = y;
        y += h + sy;
    }
    row_y[nrows] = y;
    const rows_end = if (nrows > 0) y else 0;
    const origin_x = ctx.bpLeft(b);
    const origin_y = ctx.bpTop(b) + cap_top;

    var cap_y = ctx.bpTop(b);
    var cap_after = origin_y + rows_end;
    for (g.captions) |cap| {
        cap.x = ctx.bpLeft(b) + cap.margin.left;
        if (cap.style.caption_bottom) {
            cap.y = cap_after + cap.margin.top;
            cap_after += cap.h + cap.margin.vertical();
        } else {
            cap.y = cap_y + cap.margin.top;
            cap_y += cap.h + cap.margin.vertical();
        }
    }

    // Groups and rows.
    var i: usize = 0;
    while (i < nrows) {
        const group = g.rows[i].group;
        var j = i;
        while (j < nrows and g.rows[j].group == group) j += 1;
        group.x = origin_x;
        group.y = origin_y + row_y[i];
        group.w = table_w;
        group.h = row_y[j] - row_y[i] - sy;
        for (g.rows[i..j], i..) |*r, q| {
            r.b.x = 0;
            r.b.y = row_y[q] - row_y[i];
            r.b.w = table_w;
            r.b.h = row_h[q];
            r.b.runs = &.{};
        }
        i = j;
    }
    // Groups with no rows sit out of the way, at the end of the rows.
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.kind == .table_row_group and x.first_child == null) {
            x.x = origin_x;
            x.y = origin_y + rows_end;
            x.w = table_w;
            x.h = 0;
        } else if (x.style.isOutOfFlow()) {
            x.x = ctx.bpLeft(b);
            x.y = ctx.bpTop(b);
        }
    }

    // Cells, and what is in them aligned.
    for (g.cells) |*cell| {
        const x = cell.b;
        const w = cellWidth(x, col_x, cell, sx);
        const last_row = cell.row + cell.rows;
        const area_h = row_y[last_row] - row_y[cell.row] - sy;
        const h = area_h;
        var pct_child = false;
        var q = x.first_child;
        while (q) |y2| : (q = y2.next) pct_child = pct_child or y2.style.height.hasPct();
        _ = try sizing.layoutBfc(c, x, w, if (pct_child) h else null);
        x.w = w;
        x.h = h;
        const free = h - ctx.bpV(x) - x.lay.auto_h;
        const want: f32 = switch (x.style.vertical_align) {
            .middle => free / 2,
            .bottom, .text_bottom => free,
            .top, .text_top, .sub, .super => 0,
            .baseline => if (x.lay.first_baseline) |v| up[cell.row] - (v - x.lay.shift_y) else 0,
        };
        ctx.shiftContents(x, want - x.lay.shift_y);
        x.x = col_x[cell.col];
        x.y = 0;
    }
    b.lay.first_baseline = null;
    b.lay.last_baseline = null;
    if (nrows > 0) {
        const base = origin_y + row_y[0] + up[0];
        b.lay.first_baseline = base;
        b.lay.last_baseline = base;
    }
    return @max(0, rows_end + cap_top + cap_bottom);
}

fn cellWidth(x: *const Box, col_x: []const f32, cell: *const Cell, sx: f32) f32 {
    _ = x;
    return col_x[cell.col + cell.cols] - col_x[cell.col] - sx;
}

/// Rows too short for the cells spanning them share what is missing equally.
fn rowSpans(c: *Ctx, g: *Grid, row_h: []f32, sy: f32) Error!void {
    var spanning: std.ArrayList(*Cell) = .empty;
    for (g.cells) |*cell| if (cell.rows > 1) try spanning.append(c.arena, cell);
    std.mem.sort(*Cell, spanning.items, {}, struct {
        fn less(_: void, a: *Cell, b: *Cell) bool {
            return a.rows < b.rows;
        }
    }.less);
    for (spanning.items) |cell| {
        const x = cell.b;
        var h = x.lay.measure_h;
        if (ctx.specH(x, x.style.height, null, ctx.bpV(x))) |v| h = @max(h, v);
        const part = row_h[cell.row .. cell.row + cell.rows];
        var have = sy * @as(f32, @floatFromInt(cell.rows - 1));
        for (part) |v| have += v;
        if (h > have) {
            const each = (h - have) / @as(f32, @floatFromInt(cell.rows));
            for (part) |*v| v.* += each;
        }
    }
}

fn spread(row_h: []f32, extra: f32) void {
    if (extra <= 0 or row_h.len == 0) return;
    var sum: f32 = 0;
    for (row_h) |v| sum += v;
    for (row_h) |*v| {
        v.* += if (sum > 0) extra * v.* / sum else extra / @as(f32, @floatFromInt(row_h.len));
    }
}
