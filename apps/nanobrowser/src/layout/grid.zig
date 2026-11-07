//! CSS Grid: expanding the templates, placing items on lines (explicit, then
//! auto-placement, `dense` going back for holes), and setting them out once
//! `grid_tracks.zig` has sized the tracks.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const sizing = @import("sizing.zig");
const intrinsic_mod = @import("intrinsic.zig");
const tracks = @import("grid_tracks.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;
const Allocator = ctx.Allocator;

/// Lines further out than this are pulled in: browsers cap them too.
const line_cap: i32 = 1000;

pub const Placed = struct {
    b: *Box,
    /// Zero-based tracks: `c0` up to but not including `c1`.
    c0: i32 = 0,
    c1: i32 = 1,
    r0: i32 = 0,
    r1: i32 = 1,
};

pub const Layout = struct {
    items: []Placed,
    cols: []tracks.Track,
    rows: []tracks.Track,
};

/// A template with its auto-repeat expanded to fit `avail`.
fn expand(a: Allocator, list: css.TrackList, avail: ?f32, gap: f32, sub: ?[]const f32) Error!struct { tracks: []css.Track, from: i32, to: i32 } {
    var out: std.ArrayList(css.Track) = .empty;
    // A subgrid's tracks are its parent's, sized or about to be.
    if (sub) |sizes| {
        for (sizes) |v| try out.append(a, if (v < 0) .{} else .{ .kind = .fixed, .px = v });
        return .{ .tracks = out.items, .from = -1, .to = -1 };
    }
    if (list.auto_repeat < 0 or list.auto_repeat >= list.tracks.len) {
        try out.appendSlice(a, list.tracks);
        return .{ .tracks = out.items, .from = -1, .to = -1 };
    }
    const at: usize = @intCast(list.auto_repeat);
    const end: usize = @min(list.tracks.len, at + @max(list.repeat_len, 1));
    const group = list.tracks[at..end];
    var fixed: f32 = 0;
    for (list.tracks, 0..) |t, i| if (i < at or i >= end) {
        fixed += fixedSize(t, avail) + gap;
    };
    var one: f32 = 0;
    for (group) |t| one += fixedSize(t, avail) + gap;
    var count: i32 = 1;
    if (avail) |room| if (one > gap * @as(f32, @floatFromInt(group.len))) {
        const v = (room - fixed + gap) / one;
        count = @intFromFloat(std.math.clamp(@floor(v), 1, @as(f32, @floatFromInt(line_cap))));
    };
    try out.appendSlice(a, list.tracks[0..at]);
    var n: i32 = 0;
    while (n < count) : (n += 1) try out.appendSlice(a, group);
    try out.appendSlice(a, list.tracks[end..]);
    const added = count * @as(i32, @intCast(group.len));
    return .{ .tracks = out.items, .from = @intCast(at), .to = @as(i32, @intCast(at)) + added };
}

fn fixedSize(t: css.Track, avail: ?f32) f32 {
    return switch (t.kind) {
        .fixed, .minmax => @max(0, tracks.least(t, avail orelse 0)),
        else => 0,
    };
}

/// A `grid-column`/`grid-row` as tracks; null start when it has no definite one.
fn resolveLines(p: css.GridPlace, explicit: i32) struct { start: ?i32, end: ?i32, span: i32 } {
    const span: i32 = @max(1, @min(@as(i32, p.span), line_cap));
    var s: ?i32 = null;
    var e: ?i32 = null;
    if (p.start != 0) s = lineIndex(p.start, explicit);
    if (p.end != 0) e = lineIndex(p.end, explicit);
    if (s != null and e != null) {
        if (e.? == s.?) e = s.? + 1;
        if (e.? < s.?) {
            const t = s;
            s = e;
            e = t;
        }
    }
    return .{ .start = s, .end = e, .span = span };
}

/// The line a name means on one axis: an area's edge, `x-start` or `x-end`
/// of an area or of named lines, or a line named outright. Lines after an
/// auto-repeat move by `shift`, what the repeat added.
fn namedLine(st: *const css.Style, list: css.TrackList, name: []const u8, is_start: bool, is_col: bool, shift: i32, repeat_at: i32) ?i16 {
    const areaEdge = struct {
        fn f(a: css.GridArea, start: bool, col: bool) i16 {
            return if (col) (if (start) a.col0 else a.col1) else (if (start) a.row0 else a.row1);
        }
    }.f;
    for (st.grid_areas) |a| if (std.mem.eql(u8, a.name, name)) return areaEdge(a, is_start, is_col);
    const suffix: []const u8 = if (is_start) "-start" else "-end";
    if (std.mem.endsWith(u8, name, "-start") or std.mem.endsWith(u8, name, "-end")) {
        const starts = std.mem.endsWith(u8, name, "-start");
        const stem = name[0 .. name.len - (if (starts) "-start".len else "-end".len)];
        for (st.grid_areas) |a| if (std.mem.eql(u8, a.name, stem)) return areaEdge(a, starts, is_col);
    }
    const moved = struct {
        fn f(l: css.LineName, s: i32, at: i32) i16 {
            const v: i32 = if (at >= 0 and l.line > at + 1) @as(i32, l.line) + s else l.line;
            return @intCast(std.math.clamp(v, -30000, 30000));
        }
    }.f;
    for (list.names) |l| {
        if (l.name.len == name.len + suffix.len and std.mem.startsWith(u8, l.name, name) and std.mem.endsWith(u8, l.name, suffix)) return moved(l, shift, repeat_at);
    }
    for (list.names) |l| if (std.mem.eql(u8, l.name, name)) return moved(l, shift, repeat_at);
    return null;
}

/// `p` with its names worked out to line numbers; a name nothing answers is `auto`.
fn withLines(st: *const css.Style, list: css.TrackList, p: css.GridPlace, is_col: bool, shift: i32, repeat_at: i32) css.GridPlace {
    var out = p;
    if (p.start_name.len > 0) out.start = namedLine(st, list, p.start_name, true, is_col, shift, repeat_at) orelse 0;
    if (p.end_name.len > 0) out.end = namedLine(st, list, p.end_name, false, is_col, shift, repeat_at) orelse 0;
    return out;
}

fn lineIndex(line: i16, explicit: i32) i32 {
    const v: i32 = if (line > 0) @as(i32, line) - 1 else explicit + 1 + @as(i32, line);
    return std.math.clamp(v, -line_cap, line_cap);
}

/// Which cells are taken: major tracks grow as needed, minor ones are fixed.
const Occupied = struct {
    a: Allocator,
    minor: i32,
    cells: std.ArrayList(bool) = .empty,

    fn ensure(o: *Occupied, major_end: i32) Error!void {
        const want: usize = @intCast(@max(major_end, 0) * o.minor);
        while (o.cells.items.len < want) try o.cells.append(o.a, false);
    }

    fn free(o: *Occupied, maj: i32, min: i32, maj_n: i32, min_n: i32) Error!bool {
        try o.ensure(maj + maj_n);
        var r = maj;
        while (r < maj + maj_n) : (r += 1) {
            var q = min;
            while (q < min + min_n) : (q += 1) {
                if (o.cells.items[@intCast(r * o.minor + q)]) return false;
            }
        }
        return true;
    }

    fn mark(o: *Occupied, maj: i32, min: i32, maj_n: i32, min_n: i32) Error!void {
        try o.ensure(maj + maj_n);
        var r = maj;
        while (r < maj + maj_n) : (r += 1) {
            var q = min;
            while (q < min + min_n) : (q += 1) o.cells.items[@intCast(r * o.minor + q)] = true;
        }
    }
};

/// One axis's resolved position, in the major and minor terms of the flow.
const Span = struct { start: ?i32, n: i32 };

fn spanOf(p: css.GridPlace, explicit: i32) Span {
    const l = resolveLines(p, explicit);
    if (l.start != null and l.end != null) return .{ .start = l.start, .n = l.end.? - l.start.? };
    if (l.start) |v| return .{ .start = v, .n = l.span };
    if (l.end) |v| return .{ .start = v - l.span, .n = l.span };
    return .{ .start = null, .n = l.span };
}

fn colGap(b: *const Box, avail: f32) f32 {
    if (b.lay.sub_cols != null and b.style.column_gap.kind != .length) return b.lay.sub_col_gap;
    return @max(0, ctx.len(b.style.column_gap, avail));
}

fn rowGap(b: *const Box, avail: f32) f32 {
    if (b.lay.sub_rows != null and isZeroLen(b.style.row_gap)) return b.lay.sub_row_gap;
    return @max(0, ctx.len(b.style.row_gap, avail));
}

fn isZeroLen(l: css.Len) bool {
    return l.kind == .length and l.px == 0 and !l.hasPct();
}

fn placeholder(a: Allocator, n: i32) Error![]const f32 {
    const out = try a.alloc(f32, @intCast(@max(n, 0)));
    @memset(out, -1);
    return out;
}

/// Tells the subgrids among `items` how many tracks they span, before they're sized.
fn markSubgrids(c: *Ctx, items: []const Placed, col_gap: f32, row_gap: f32) Error!void {
    for (items) |*it| {
        const n = &it.b.lay;
        if (it.b.kind != .grid) continue;
        if (it.b.style.grid_template_columns.subgrid and n.sub_cols == null) {
            n.sub_cols = try placeholder(c.arena, it.c1 - it.c0);
            n.sub_col_gap = col_gap;
        }
        if (it.b.style.grid_template_rows.subgrid and n.sub_rows == null) {
            n.sub_rows = try placeholder(c.arena, it.r1 - it.r0);
            n.sub_row_gap = row_gap;
        }
    }
}

/// What the tracks `from`..`to` come to for what's inside an item that spans them:
/// the end tracks give up what the item's own edges take.
fn subSizes(c: *Ctx, list: []const tracks.Track, from: i32, to: i32, start_edge: f32, end_edge: f32) Error![]const f32 {
    const out = try c.arena.alloc(f32, @intCast(@max(to - from, 0)));
    for (out, 0..) |*v, i| {
        const at: usize = @intCast(from + @as(i32, @intCast(i)));
        v.* = if (at < list.len) list[at].base else 0;
    }
    if (out.len > 0) {
        out[0] = @max(0, out[0] - start_edge);
        out[out.len - 1] = @max(0, out[out.len - 1] - end_edge);
    }
    return out;
}

/// A subgrid now knows its tracks; what it had made of them no longer holds.
fn settleSub(b: *Box) void {
    b.lay.state_valid = false;
    b.lay.measure_valid = false;
    b.lay.intrinsic_known = false;
}

/// Where every item of a subgrid goes in tracks of the grid around it, for that
/// grid to size them by: `b`'s placement with its own tracks not sized yet.
pub fn subPlacement(c: *Ctx, b: *Box) Error![]Placed {
    return (try placeItems(c, b, null, null)).items;
}

/// Works out where every item goes and sizes the track lists to match.
fn placeItems(c: *Ctx, b: *Box, avail_w: ?f32, avail_h: ?f32) Error!Layout {
    const a = c.arena;
    const st = b.style;
    const col_gap = colGap(b, avail_w orelse 0);
    const row_gap = rowGap(b, avail_h orelse 0);
    const col_t = try expand(a, st.grid_template_columns, avail_w, col_gap, if (st.grid_template_columns.subgrid) b.lay.sub_cols else null);
    const row_t = try expand(a, st.grid_template_rows, avail_h, row_gap, if (st.grid_template_rows.subgrid) b.lay.sub_rows else null);
    const ncols: i32 = @intCast(col_t.tracks.len);
    const nrows: i32 = @intCast(row_t.tracks.len);
    const column_flow = st.grid_auto_flow_column;

    var items: std.ArrayList(Placed) = .empty;
    var spans: std.ArrayList([2]Span) = .empty;
    var min_c: i32 = 0;
    var min_r: i32 = 0;
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.style.isOutOfFlow()) continue;
        const col_shift = col_t.to - col_t.from - @as(i32, @max(st.grid_template_columns.repeat_len, 1));
        const row_shift = row_t.to - row_t.from - @as(i32, @max(st.grid_template_rows.repeat_len, 1));
        const sc = spanOf(withLines(st, st.grid_template_columns, x.style.grid_column, true, col_shift, col_t.from), ncols);
        const sr = spanOf(withLines(st, st.grid_template_rows, x.style.grid_row, false, row_shift, row_t.from), nrows);
        if (sc.start) |v| min_c = @min(min_c, v);
        if (sr.start) |v| min_r = @min(min_r, v);
        try items.append(a, .{ .b = x });
        try spans.append(a, .{ sc, sr });
    }
    // Implicit tracks before the first line shift everything along.
    for (spans.items) |*s| {
        if (s[0].start) |*v| v.* -= min_c;
        if (s[1].start) |*v| v.* -= min_r;
    }
    const major_i: usize = if (column_flow) 0 else 1;
    const minor_i: usize = 1 - major_i;
    var minor_n: i32 = (if (column_flow) nrows - min_r else ncols - min_c);
    var major_n: i32 = (if (column_flow) ncols - min_c else nrows - min_r);
    for (spans.items) |s| {
        const m = s[minor_i];
        minor_n = @max(minor_n, (m.start orelse 0) + m.n);
        const j = s[major_i];
        if (j.start) |v| major_n = @max(major_n, v + j.n);
    }
    minor_n = @max(minor_n, 1);

    var occ: Occupied = .{ .a = a, .minor = minor_n };
    // Everything with a definite major line goes first, in order.
    for (spans.items) |*s| {
        const j = s[major_i];
        if (j.start == null) continue;
        const m = &s[minor_i];
        if (m.start == null) {
            var q: i32 = 0;
            while (q + m.n <= minor_n and !(try occ.free(j.start.?, q, j.n, m.n))) q += 1;
            if (q + m.n > minor_n) q = 0;
            m.start = q;
        }
        try occ.mark(j.start.?, m.start.?, j.n, m.n);
    }
    // Then the rest, with one cursor: no going back, as without `dense`.
    var cur_maj: i32 = 0;
    var cur_min: i32 = 0;
    for (spans.items) |*s| {
        const j = &s[major_i];
        if (j.start != null) continue;
        const m = &s[minor_i];
        if (st.grid_auto_flow_dense) {
            cur_maj = 0;
            cur_min = 0;
        }
        if (m.start) |at| {
            if (st.grid_auto_flow_dense) cur_min = at;
            if (at < cur_min) cur_maj += 1;
            cur_min = at;
            while (!(try occ.free(cur_maj, cur_min, j.n, m.n))) cur_maj += 1;
        } else {
            while (true) {
                if (cur_min + m.n > minor_n) {
                    cur_min = 0;
                    cur_maj += 1;
                    if (m.n > minor_n) break;
                }
                if (try occ.free(cur_maj, cur_min, j.n, @min(m.n, minor_n))) break;
                cur_min += 1;
            }
            m.start = cur_min;
        }
        j.start = cur_maj;
        try occ.mark(cur_maj, m.start.?, j.n, m.n);
        major_n = @max(major_n, cur_maj + j.n);
        cur_min = m.start.? + m.n;
    }
    for (items.items, spans.items) |*it, s| {
        it.c0 = s[0].start orelse 0;
        it.c1 = it.c0 + s[0].n;
        it.r0 = s[1].start orelse 0;
        it.r1 = it.r0 + s[1].n;
    }
    const total_c = if (column_flow) major_n else minor_n;
    const total_r = if (column_flow) minor_n else major_n;
    const cols = try tracks.make(a, col_t.tracks, st.grid_auto_columns, -min_c, total_c);
    const rows = try tracks.make(a, row_t.tracks, st.grid_auto_rows, -min_r, total_r);
    if (st.grid_template_columns.auto_fit and col_t.from >= 0) collapseEmpty(cols, items.items, col_t.from - min_c, col_t.to - min_c, true);
    if (st.grid_template_rows.auto_fit and row_t.from >= 0) collapseEmpty(rows, items.items, row_t.from - min_r, row_t.to - min_r, false);
    try markSubgrids(c, items.items, col_gap, row_gap);
    return .{ .items = items.items, .cols = cols, .rows = rows };
}

/// `auto-fit`: the repeated tracks nothing landed in.
fn collapseEmpty(list: []tracks.Track, items: []const Placed, from: i32, to: i32, is_col: bool) void {
    var i = from;
    while (i < to and i < list.len) : (i += 1) {
        var used = false;
        for (items) |*it| {
            const s = if (is_col) it.c0 else it.r0;
            const e = if (is_col) it.c1 else it.r1;
            if (s <= i and i < e) used = true;
        }
        if (!used) list[@intCast(i)].collapsed = true;
    }
}

fn selfOf(s: css.Align, parent: css.Align, replaced: bool) css.Align {
    const v = if (s != .auto) s else parent;
    return switch (v) {
        .auto, .normal => if (replaced) .start else .stretch,
        .space_between, .space_around, .space_evenly, .baseline => .start,
        else => v,
    };
}

/// An item's width in a grid area.
fn itemWidth(c: *Ctx, k: *Box, area: f32, self_align: css.Align) Error!f32 {
    const bp = ctx.bpH(k);
    var w = try ctx.specW(c, k, k.style.width, area, bp);
    if (w == null and k.kind == .replaced) w = (try @import("replaced.zig").size(c, k, area, null)).w;
    const auto_margin = k.style.margin_left.kind == .auto or k.style.margin_right.kind == .auto;
    const used = w orelse if (self_align == .stretch and !auto_margin) @max(bp, area - k.margin.horizontal()) else try sizing.shrinkToFit(c, k, area - k.margin.horizontal());
    return ctx.clampW(c, k, used, area, bp);
}

/// Lays out a grid container's items; gives back the height of its content box.
pub fn layout(c: *Ctx, b: *Box, cw: f32, ch: ?f32) Error!f32 {
    const st = b.style;
    b.runs = &.{};
    b.marker = null;
    b.lay.first_baseline = null;
    b.lay.last_baseline = null;
    const left = ctx.bpLeft(b);
    const top = ctx.bpTop(b);
    var k = b.first_child;
    while (k) |x| : (k = x.next) if (x.style.isOutOfFlow()) {
        x.x = left;
        x.y = top;
    };
    const g = try placeItems(c, b, cw, ch);
    const col_gap = colGap(b, cw);
    const row_gap = rowGap(b, ch orelse 0);
    for (g.items) |*it| ctx.setEdges(it.b, cw);

    try tracks.sizeColumns(c, g.cols, g.items, cw, col_gap, st.justify_content == .normal or st.justify_content == .stretch);
    const col_pos = try tracks.positions(c.arena, g.cols, cw, col_gap, justifyAsAlign(st.justify_content));
    for (g.items) |*it| {
        const x = it.b;
        if (x.kind != .grid or !x.style.grid_template_columns.subgrid) continue;
        x.lay.sub_cols = try subSizes(c, g.cols, it.c0, it.c1, x.margin.left + ctx.bpLeft(x), x.margin.right + x.border.right + x.padding.right);
        settleSub(x);
    }

    // Rows see each item at its column's width.
    const heights = try c.arena.alloc(f32, g.items.len);
    const widths = try c.arena.alloc(f32, g.items.len);
    for (g.items, 0..) |*it, i| {
        const self_j = selfOf(it.b.style.justify_self, st.justify_items, it.b.kind == .replaced);
        const area = tracks.areaSize(g.cols, it.c0, it.c1, col_gap);
        widths[i] = try itemWidth(c, it.b, area, self_j);
        // A subgrid asks through what's in it, track by track.
        heights[i] = if (it.b.kind == .grid and it.b.style.grid_template_rows.subgrid) 0 else try sizing.measureH(c, it.b, widths[i], null) + it.b.margin.vertical();
    }
    const extra = try subRowAsks(c, g.items, widths);
    try tracks.sizeRows(c.arena, g.rows, g.items, heights, extra, ch, row_gap, st.align_content == .normal or st.align_content == .stretch);
    for (g.items) |*it| {
        const x = it.b;
        if (x.kind != .grid or !x.style.grid_template_rows.subgrid) continue;
        x.lay.sub_rows = try subSizes(c, g.rows, it.r0, it.r1, x.margin.top + ctx.bpTop(x), x.margin.bottom + x.border.bottom + x.padding.bottom);
        settleSub(x);
    }
    const row_pos = try tracks.positions(c.arena, g.rows, ch orelse tracks.total(g.rows, row_gap), row_gap, st.align_content);

    for (g.items, 0..) |*it, i| {
        const x = it.b;
        const s = x.style;
        const self_j = selfOf(s.justify_self, st.justify_items, x.kind == .replaced);
        const self_a = selfOf(s.align_self, st.align_items, x.kind == .replaced);
        const area_w = tracks.areaSize(g.cols, it.c0, it.c1, col_gap);
        const area_h = tracks.areaSize(g.rows, it.r0, it.r1, row_gap);
        const auto_y = s.margin_top.kind == .auto or s.margin_bottom.kind == .auto;
        const stretch: ?f32 = if (self_a == .stretch and !auto_y and s.height.kind == .auto) @max(0, area_h - x.margin.vertical()) else null;
        _ = try sizing.place(c, x, widths[i], area_h, stretch);
        const dx = offset(self_j, area_w - x.w - x.margin.horizontal(), s.margin_left.kind == .auto, s.margin_right.kind == .auto);
        const dy = offset(self_a, area_h - x.h - x.margin.vertical(), s.margin_top.kind == .auto, s.margin_bottom.kind == .auto);
        x.x = left + col_pos[@intCast(it.c0)] + x.margin.left + dx;
        x.y = top + row_pos[@intCast(it.r0)] + x.margin.top + dy;
    }
    if (g.items.len > 0) {
        const f = g.items[0].b;
        const base = f.y + (f.lay.first_baseline orelse f.h);
        b.lay.first_baseline = base;
        b.lay.last_baseline = base;
    }
    return tracks.total(g.rows, row_gap);
}

/// What the items of row subgrids ask of the rows they fall in.
fn subRowAsks(c: *Ctx, items: []const Placed, widths: []const f32) Error![]const tracks.Contribution {
    var out: std.ArrayList(tracks.Contribution) = .empty;
    for (items, widths) |*it, w| {
        const x = it.b;
        if (x.kind != .grid or !x.style.grid_template_rows.subgrid) continue;
        const inner_w = @max(0, w - ctx.bpH(x));
        const g = try placeItems(c, x, inner_w, null);
        for (g.items) |*sub| ctx.setEdges(sub.b, inner_w);
        const gap = colGap(x, inner_w);
        try tracks.sizeColumns(c, g.cols, g.items, inner_w, gap, true);
        for (g.items) |*sub| {
            const area = tracks.areaSize(g.cols, sub.c0, sub.c1, gap);
            const self_j = selfOf(sub.b.style.justify_self, x.style.justify_items, sub.b.kind == .replaced);
            const sw = try itemWidth(c, sub.b, area, self_j);
            const sh = try sizing.measureH(c, sub.b, sw, null) + sub.b.margin.vertical();
            try out.append(c.arena, .{ .lo = sh, .hi = sh, .from = it.r0 + sub.r0, .to = it.r0 + sub.r1 });
        }
    }
    return out.items;
}

fn offset(a: css.Align, free: f32, start_auto: bool, end_auto: bool) f32 {
    if (start_auto or end_auto) {
        if (free <= 0) return 0;
        if (start_auto and end_auto) return free / 2;
        return if (start_auto) free else 0;
    }
    return switch (a) {
        .end => free,
        .center => free / 2,
        else => 0,
    };
}

fn justifyAsAlign(j: css.Justify) css.Align {
    return switch (j) {
        .normal => .normal,
        .start => .start,
        .end => .end,
        .center => .center,
        .space_between => .space_between,
        .space_around => .space_around,
        .space_evenly => .space_evenly,
        .stretch => .stretch,
    };
}

/// Content-box widths: the column tracks sized with no width to fill.
pub fn intrinsic(c: *Ctx, b: *Box) Error!intrinsic_mod.Sizes {
    const g = try placeItems(c, b, null, null);
    const gap = colGap(b, 0);
    const lo = try tracks.intrinsicColumns(c, g.cols, g.items, gap, false);
    const hi = try tracks.intrinsicColumns(c, g.cols, g.items, gap, true);
    return .{ .min = lo, .max = @max(lo, hi) };
}
