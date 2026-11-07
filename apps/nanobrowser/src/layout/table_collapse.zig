//! `border-collapse: collapse`: each line of the grid has one border, the winner of
//! all that want to be there (CSS 2 §17.6.2.1). Each box beside the line gets half of
//! it as its own border, so nothing else in table layout need know: cells keep what's
//! inside them clear of it, and the two halves drawn make up the whole. The table has
//! half of what's at its outer edges.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const table = @import("table.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;
const Border = css.Border;

fn styleRank(s: css.BorderStyle) u8 {
    return switch (s) {
        .hidden => 10,
        .double => 8,
        .solid => 7,
        .dashed => 6,
        .dotted => 5,
        .ridge => 4,
        .outset => 3,
        .groove => 2,
        .inset => 1,
        .none => 0,
    };
}

/// The border at a line, between what it is now and one that comes later, which has
/// less right to it when all else is equal. `hidden` beats all, then the widest, then
/// the style.
fn better(have: Border, other: Border) Border {
    if (have.style == .hidden) return have;
    if (other.style == .hidden) return other;
    const a = ctx.borderWidth(have);
    const b = ctx.borderWidth(other);
    if (b > a) return other;
    if (b == a and styleRank(other.style) > styleRank(have.style)) return other;
    return have;
}

const Side = enum { top, right, bottom, left };

fn sideOf(s: *const css.Style, side: Side) Border {
    return switch (side) {
        .top => s.border_top,
        .right => s.border_right,
        .bottom => s.border_bottom,
        .left => s.border_left,
    };
}

/// Half of a border, for the box on one side of the line.
fn half(b: Border) Border {
    const w = ctx.borderWidth(b);
    return .{ .width = w / 2, .style = if (w > 0) b.style else .none, .color = b.color };
}

fn noBorders(c: *Ctx, b: *Box) Error!void {
    const s = b.style;
    if (ctx.borderWidth(s.border_top) == 0 and ctx.borderWidth(s.border_right) == 0 and ctx.borderWidth(s.border_bottom) == 0 and ctx.borderWidth(s.border_left) == 0) return;
    const copy = try c.arena.create(css.Style);
    copy.* = s.*;
    copy.border_top = .{};
    copy.border_right = .{};
    copy.border_bottom = .{};
    copy.border_left = .{};
    b.style = copy;
}

/// Resolves every cell's borders, and the table's.
pub fn resolve(c: *Ctx, b: *Box, g: *table.Grid) Error!void {
    const nrows: u32 = @intCast(g.rows.len);
    const ncols = g.ncols;
    if (nrows == 0 or ncols == 0) return noBorders(c, b);
    const a = c.arena;
    const at = try a.alloc(?*table.Cell, nrows * ncols);
    @memset(at, null);
    for (g.cells) |*cell| {
        var r = cell.row;
        while (r < cell.row + cell.rows and r < nrows) : (r += 1) {
            var k = cell.col;
            while (k < cell.col + cell.cols and k < ncols) : (k += 1) at[r * ncols + k] = cell;
        }
    }
    const ts = b.style;
    var edge_top: Border = .{};
    var edge_bottom: Border = .{};
    var edge_left: Border = .{};
    var edge_right: Border = .{};
    const fresh = try a.alloc(css.Style, g.cells.len);
    for (g.cells, fresh, 0..) |*cell, *out, i| {
        _ = i;
        const s = cell.b.style;
        out.* = s.*;
        const row_end = @min(cell.row + cell.rows, nrows);
        const col_end = @min(cell.col + cell.cols, ncols);

        // Above and below, each column of it.
        var top = s.border_top;
        var bottom = s.border_bottom;
        top = better(top, g.rows[cell.row].b.style.border_top);
        top = better(top, g.rows[cell.row].group.style.border_top);
        bottom = better(bottom, g.rows[row_end - 1].b.style.border_bottom);
        bottom = better(bottom, g.rows[row_end - 1].group.style.border_bottom);
        if (cell.row == 0) top = better(top, ts.border_top);
        if (row_end == nrows) bottom = better(bottom, ts.border_bottom);
        var k = cell.col;
        while (k < col_end) : (k += 1) {
            if (cell.row > 0) if (at[(cell.row - 1) * ncols + k]) |n| {
                top = better(top, n.b.style.border_bottom);
                top = better(top, g.rows[cell.row - 1].b.style.border_bottom);
            };
            if (row_end < nrows) if (at[row_end * ncols + k]) |n| {
                bottom = better(bottom, n.b.style.border_top);
                bottom = better(bottom, g.rows[row_end].b.style.border_top);
            };
        }

        // Beside it, each row of it.
        var left = s.border_left;
        var right = s.border_right;
        if (cell.col == 0) left = better(left, ts.border_left);
        if (col_end == ncols) right = better(right, ts.border_right);
        var r = cell.row;
        while (r < row_end) : (r += 1) {
            if (cell.col == 0) left = better(left, g.rows[r].b.style.border_left);
            if (col_end == ncols) right = better(right, g.rows[r].b.style.border_right);
            if (cell.col > 0) if (at[r * ncols + cell.col - 1]) |n| {
                left = better(left, n.b.style.border_right);
            };
            if (col_end < ncols) if (at[r * ncols + col_end]) |n| {
                right = better(right, n.b.style.border_left);
            };
        }
        out.border_top = half(top);
        out.border_bottom = half(bottom);
        out.border_left = half(left);
        out.border_right = half(right);
        if (cell.row == 0) edge_top = better(edge_top, top);
        if (row_end == nrows) edge_bottom = better(edge_bottom, bottom);
        // The first row says how far the table's sides reach.
        if (cell.row == 0 and cell.col == 0) edge_left = left;
        if (cell.row == 0 and col_end == ncols) edge_right = right;
    }
    for (g.cells, fresh) |*cell, *out| cell.b.style = out;
    for (g.rows) |*r| {
        try noBorders(c, r.b);
        try noBorders(c, r.group);
    }
    const whole = try a.create(css.Style);
    whole.* = ts.*;
    whole.border_top = half(edge_top);
    whole.border_bottom = half(edge_bottom);
    whole.border_left = half(edge_left);
    whole.border_right = half(edge_right);
    b.style = whole;
}
