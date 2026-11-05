//! Multiple columns: the content laid out once at a column's width, cut into
//! unbreakable pieces (lines, and what can't be split), the shortest height found
//! that holds them in the columns, and each piece moved to its column. A box cut
//! across columns keeps the rect of its first part.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const block = @import("block.zig");
const intrinsic_mod = @import("intrinsic.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

pub fn isMulticol(s: *const css.Style) bool {
    return s.column_count > 0 or s.column_width > 0;
}

const Shape = struct { count: f32, width: f32, gap: f32 };

fn gapOf(s: *const css.Style, cw: f32) f32 {
    // `normal` is 1em here, though it's 0 for flex and grid.
    if (s.column_gap.kind != .length) return ctx.clean(s.font_size);
    return @max(0, ctx.len(s.column_gap, cw));
}

/// How many columns, and how wide: CSS Multicol §3.4.
fn shapeOf(s: *const css.Style, cw: f32) Shape {
    const gap = gapOf(s, cw);
    var n: f32 = if (s.column_count > 0) @floatFromInt(s.column_count) else 0;
    if (s.column_width > 0) {
        const fit = @max(1, @floor((cw + gap) / (ctx.clean(s.column_width) + gap)));
        n = if (n > 0) @min(n, fit) else fit;
    }
    n = @max(1, n);
    return .{ .count = n, .width = @max(0, (cw - gap * (n - 1)) / n), .gap = gap };
}

/// Min-content and max-content of the columns, from those of what's in them.
pub fn intrinsic(s: *const css.Style, inner: intrinsic_mod.Sizes) intrinsic_mod.Sizes {
    const gap = gapOf(s, 0);
    if (s.column_count > 0) {
        const n: f32 = @floatFromInt(s.column_count);
        const w = @max(inner.max, ctx.clean(s.column_width));
        return .{ .min = n * inner.min + gap * (n - 1), .max = n * w + gap * (n - 1) };
    }
    return .{ .min = @min(inner.min, ctx.clean(s.column_width)), .max = @max(inner.max, ctx.clean(s.column_width)) };
}

/// A piece of content that stays together, in the container's coordinates.
const Piece = struct { top: f32, bottom: f32 };

/// Lays out `b`'s content in columns; the height its content box takes.
pub fn layout(c: *Ctx, b: *Box, cw: f32, ch: ?f32) Error!f32 {
    const sh = shapeOf(b.style, cw);
    const flow_h = try block.layoutContainer(c, b, sh.width, null);
    const tb = ctx.bpTop(b);
    var pieces: std.ArrayList(Piece) = .empty;
    try gather(c, b, 0, -tb, &pieces);
    if (pieces.items.len == 0) return flow_h;
    sortPieces(pieces.items);

    // The shortest height that holds everything in the columns.
    var tallest: f32 = 0;
    for (pieces.items) |p| tallest = @max(tallest, p.bottom - p.top);
    var hi = @max(tallest, flow_h);
    var lo = @max(tallest, flow_h / sh.count);
    if (ch) |h| {
        // A set height is what each column has; more columns overflow to the side.
        lo = @max(0.01, h);
        hi = lo;
    } else {
        var tries: u8 = 0;
        while (tries < 24 and hi - lo > 0.25) : (tries += 1) {
            const mid = (lo + hi) / 2;
            if (columnsFor(pieces.items, mid) <= sh.count) hi = mid else lo = mid;
        }
    }
    const used = hi;
    var cuts: std.ArrayList(Cut) = .empty;
    try cutsFor(c, pieces.items, used, &cuts);
    try moveInto(b, cuts.items, sh, tb);
    var height: f32 = 0;
    for (cuts.items, 0..) |cut, i| {
        const next = if (i + 1 < cuts.items.len) cuts.items[i + 1].from else std.math.inf(f32);
        var bottom = cut.from;
        for (pieces.items) |p| if (p.top >= cut.from and p.top < next) {
            bottom = @max(bottom, p.bottom);
        };
        height = @max(height, bottom - cut.from);
    }
    return ch orelse height;
}

fn sortPieces(list: []Piece) void {
    std.mem.sort(Piece, list, {}, struct {
        fn less(_: void, a: Piece, x: Piece) bool {
            return a.top < x.top;
        }
    }.less);
}

/// A column: where in the flow it begins.
const Cut = struct { from: f32 };

fn columnsFor(pieces: []const Piece, h: f32) f32 {
    var n: f32 = 1;
    var start = pieces[0].top;
    for (pieces) |p| {
        if (p.bottom - start > h + 0.01) {
            n += 1;
            start = p.top;
        }
    }
    return n;
}

fn cutsFor(c: *Ctx, pieces: []const Piece, h: f32, out: *std.ArrayList(Cut)) Error!void {
    var start = pieces[0].top;
    try out.append(c.arena, .{ .from = start });
    for (pieces) |p| {
        if (p.bottom - start > h + 0.01) {
            start = p.top;
            try out.append(c.arena, .{ .from = start });
        }
    }
}

/// `b`'s pieces. `oy` is what to add to a coordinate relative to `b`.
fn gather(c: *Ctx, b: *Box, oy: f32, adjust: f32, out: *std.ArrayList(Piece)) Error!void {
    if (b.lay.inline_root) return gatherLines(c, b, oy + adjust, out);
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.style.isOutOfFlow()) continue;
        const top = oy + x.y;
        const before = out.items.len;
        if (x.kind == .block and x.style.float == .none and !x.style.clips()) try gather(c, x, top, adjust, out);
        // Nothing in it to cut by, or nothing that may be cut: it goes whole.
        if (out.items.len == before and x.h > 0) try out.append(c.arena, .{ .top = top + adjust, .bottom = top + x.h + adjust });
    }
}

fn gatherLines(c: *Ctx, b: *Box, oy: f32, out: *std.ArrayList(Piece)) Error!void {
    var last: f32 = -1e9;
    var k: ?*Box = b;
    while (k) |x| : (k = nextInline(x, b)) {
        for (x.runs) |*r| {
            if (r.line_top == last) continue;
            last = r.line_top;
            try out.append(c.arena, .{ .top = oy + r.line_top, .bottom = oy + r.line_top + r.line_h });
        }
    }
}

/// The inline boxes of an inline root, in order.
fn nextInline(x: *Box, root: *Box) ?*Box {
    if (x.first_child) |k| if (x == root or x.kind == .inline_box) {
        var at: ?*Box = k;
        while (at) |y| : (at = y.next) if (y.kind == .inline_box) return y;
    };
    var at: *Box = x;
    while (at != root) {
        var s = at.next;
        while (s) |y| : (s = y.next) if (y.kind == .inline_box) return y;
        at = at.parent orelse return null;
    }
    return null;
}

/// How far a piece at flow position `y` moves, across and up.
fn moveFor(cuts: []const Cut, sh: Shape, y: f32) [2]f32 {
    var i: usize = 0;
    while (i + 1 < cuts.len and y >= cuts[i + 1].from - 0.01) i += 1;
    const col: f32 = @floatFromInt(i);
    return .{ col * (sh.width + sh.gap), cuts[0].from - cuts[i].from };
}

fn moveInto(b: *Box, cuts: []const Cut, sh: Shape, tb: f32) Error!void {
    if (b.lay.inline_root) return moveRuns(b, cuts, sh, 0, 0, -tb);
    var k = b.first_child;
    while (k) |x| : (k = x.next) moveBox(x, cuts, sh, 0, 0, -tb);
}

/// Moves `x`, whose parent moved by `pdx`, `pdy`: `oy` turns its parent's
/// coordinates into the flow's.
fn moveBox(x: *Box, cuts: []const Cut, sh: Shape, pdx: f32, pdy: f32, oy: f32) void {
    if (x.style.isOutOfFlow()) return;
    const flow_top = x.y + oy;
    const m = moveFor(cuts, sh, flow_top);
    x.x += m[0] - pdx;
    x.y += m[1] - pdy;
    const inner_oy = flow_top;
    if (x.lay.inline_root) {
        moveRuns(x, cuts, sh, m[0], m[1], flow_top);
        return;
    }
    if (x.kind == .block and !x.style.clips()) {
        var k = x.first_child;
        while (k) |y| : (k = y.next) moveBox(y, cuts, sh, m[0], m[1], inner_oy);
    }
}

/// Moves each line of an inline root to its column: `oy` turns its coordinates into
/// the flow's, and what's in it is relative to it, which moved by `dx`, `dy`.
fn moveRuns(b: *Box, cuts: []const Cut, sh: Shape, dx: f32, dy: f32, oy: f32) void {
    moveLines(b, cuts, sh, dx, dy, oy);
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.kind == .inline_box) {
            moveInlineBox(x, cuts, sh, dx, dy, oy);
        } else if (!x.style.isOutOfFlow()) {
            const m = moveFor(cuts, sh, x.y + oy);
            x.x += m[0] - dx;
            x.y += m[1] - dy;
        }
    }
}

fn moveLines(b: *Box, cuts: []const Cut, sh: Shape, dx: f32, dy: f32, oy: f32) void {
    const runs: []box.TextRun = @constCast(b.runs);
    for (runs) |*r| {
        const m = moveFor(cuts, sh, r.line_top + oy);
        r.x += m[0] - dx;
        r.baseline += m[1] - dy;
        r.line_top += m[1] - dy;
    }
}

fn moveInlineBox(x: *Box, cuts: []const Cut, sh: Shape, dx: f32, dy: f32, oy: f32) void {
    moveLines(x, cuts, sh, dx, dy, oy);
    const frags: []box.Rect = @constCast(x.frags);
    var moved = false;
    for (frags) |*r| {
        const m = moveFor(cuts, sh, r.y + oy);
        r.x += m[0] - dx;
        r.y += m[1] - dy;
        if (!moved) {
            x.x = r.x;
            x.y = r.y;
            moved = true;
        }
    }
    var k = x.first_child;
    while (k) |y| : (k = y.next) {
        if (y.kind == .inline_box) {
            moveInlineBox(y, cuts, sh, dx, dy, oy);
        } else if (!y.style.isOutOfFlow()) {
            const m = moveFor(cuts, sh, y.y + oy);
            y.x += m[0] - dx;
            y.y += m[1] - dy;
        }
    }
}
