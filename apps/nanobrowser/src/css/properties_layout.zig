//! Flexbox, grid and alignment properties.
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");
const values = @import("values.zig");

const Prop = prop.Prop;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;
const Len = style.Len;
const Track = style.Track;
const TrackList = style.TrackList;
const GridPlace = style.GridPlace;

pub fn apply(ctx: *Ctx, p: Prop, t: []const Token) ?bool {
    const s = ctx.style;
    return switch (p) {
        .flex => flex(ctx, t),
        .flex_direction => {
            s.flex_direction = values.keywordOf(style.FlexDirection, t) orelse return false;
            return true;
        },
        .flex_wrap => {
            s.flex_wrap = values.keywordOf(style.FlexWrap, t) orelse return false;
            return true;
        },
        .flex_flow => flexFlow(s, t),
        .flex_grow => number(ctx, &s.flex_grow, t),
        .flex_shrink => number(ctx, &s.flex_shrink, t),
        .flex_basis => flexBasis(ctx, t),
        .order => {
            const n = values.numberOf(ctx, t) orelse return false;
            s.order = @intFromFloat(std.math.clamp(n, -1e9, 1e9));
            return true;
        },
        .justify_content => justifyValue(&s.justify_content, t),
        .justify_items => alignValue(&s.justify_items, t),
        .justify_self => alignValue(&s.justify_self, t),
        .align_items => alignValue(&s.align_items, t),
        .align_self => alignValue(&s.align_self, t),
        .align_content => alignValue(&s.align_content, t),
        .place_items => placePair(&s.align_items, &s.justify_items, t),
        .place_self => placePair(&s.align_self, &s.justify_self, t),
        .place_content => placeContent(s, t),
        .gap, .grid_gap => gap(ctx, t),
        .row_gap, .grid_row_gap => {
            if (!gap1(ctx, &s.row_gap, t)) return false;
            if (s.row_gap.kind == .auto) s.row_gap = Len.zero;
            return true;
        },
        .column_gap, .grid_column_gap => gap1(ctx, &s.column_gap, t),
        .grid_template_columns => template(ctx, &s.grid_template_columns, t),
        .grid_template_rows => template(ctx, &s.grid_template_rows, t),
        .grid_template, .grid => gridTemplate(ctx, t),
        .grid_template_areas => templateAreas(ctx, t),
        .grid_auto_rows => autoTrack(ctx, &s.grid_auto_rows, t),
        .grid_auto_columns => autoTrack(ctx, &s.grid_auto_columns, t),
        .grid_auto_flow => autoFlow(s, t),
        .grid_column => gridSpan(&s.grid_column, t),
        .grid_row => gridSpan(&s.grid_row, t),
        .grid_column_start => gridLine(&s.grid_column, t, true),
        .grid_column_end => gridLine(&s.grid_column, t, false),
        .grid_row_start => gridLine(&s.grid_row, t, true),
        .grid_row_end => gridLine(&s.grid_row, t, false),
        .grid_area => gridArea(ctx, t),
        else => null,
    };
}

fn number(ctx: *Ctx, field: *f32, t: []const Token) bool {
    const n = values.numberOf(ctx, t) orelse return false;
    if (n < 0) return false;
    field.* = n;
    return true;
}

fn flex(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    if (values.ident(t)) |w| {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(w, "none")) {
            s.flex_grow = 0;
            s.flex_shrink = 0;
            s.flex_basis = Len.auto;
            return true;
        }
        if (eq(w, "auto") or eq(w, "content")) {
            s.flex_grow = 1;
            s.flex_shrink = 1;
            s.flex_basis = Len.auto;
            return true;
        }
    }
    var c = Cur.of(t);
    var grow: ?f32 = null;
    var shrink: ?f32 = null;
    var basis: ?Len = null;
    while (!c.atEnd()) {
        if (grow == null or shrink == null) {
            const k = c.peek().?;
            if (k.kind == .number or k.isFunction("calc")) {
                const save = c.i;
                if (values.numberAt(ctx, &c)) |n| {
                    if (grow == null) {
                        grow = n;
                    } else {
                        shrink = n;
                    }
                    continue;
                }
                c.i = save;
            }
        }
        if (basis == null) {
            if (c.takeIdent("content")) {
                basis = Len.auto;
                continue;
            }
            // The last bare 0 of `flex: 1 1 0` is a basis.
            if (values.sizeAt(ctx, &c)) |l| {
                if (l.kind == .none) return false;
                basis = l;
                continue;
            }
        }
        return false;
    }
    if (grow == null and basis == null) return false;
    s.flex_grow = grow orelse 1;
    s.flex_shrink = shrink orelse 1;
    s.flex_basis = basis orelse Len.of(0);
    return true;
}

fn flexFlow(s: *style.Style, t: []const Token) bool {
    var c = Cur.of(t);
    var dir = style.FlexDirection.row;
    var wrap = style.FlexWrap.nowrap;
    var any = false;
    while (c.next()) |k| {
        if (k.kind != .ident) return false;
        if (values.keyword(style.FlexDirection, k.text)) |d| {
            dir = d;
        } else if (values.keyword(style.FlexWrap, k.text)) |w| {
            wrap = w;
        } else return false;
        any = true;
    }
    if (!any) return false;
    s.flex_direction = dir;
    s.flex_wrap = wrap;
    return true;
}

fn flexBasis(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| if (std.ascii.eqlIgnoreCase(w, "content")) {
        ctx.style.flex_basis = Len.auto;
        return true;
    };
    var c = Cur.of(t);
    const l = values.sizeAt(ctx, &c) orelse return false;
    if (l.kind == .none or !c.atEnd()) return false;
    ctx.style.flex_basis = l;
    return true;
}

/// The word with `safe`, `unsafe`, `first`, `last` taken off the front.
fn alignWord(c: *Cur) ?[]const u8 {
    const eq = std.ascii.eqlIgnoreCase;
    var t = c.next() orelse return null;
    if (t.kind != .ident) return null;
    if (eq(t.text, "safe") or eq(t.text, "unsafe") or eq(t.text, "first") or eq(t.text, "last")) {
        t = c.next() orelse return null;
        if (t.kind != .ident) return null;
    }
    if (eq(t.text, "legacy")) {
        if (c.peek()) |n| if (n.kind == .ident) {
            c.i += 1;
            return n.text;
        };
        return "normal";
    }
    return t.text;
}

fn alignOf(w: []const u8) ?style.Align {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(w, "flex-start") or eq(w, "self-start") or eq(w, "left")) return .start;
    if (eq(w, "flex-end") or eq(w, "self-end") or eq(w, "right")) return .end;
    return values.keyword(style.Align, w);
}

fn justifyOf(w: []const u8) ?style.Justify {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(w, "flex-start") or eq(w, "self-start") or eq(w, "left")) return .start;
    if (eq(w, "flex-end") or eq(w, "self-end") or eq(w, "right")) return .end;
    return values.keyword(style.Justify, w);
}

fn alignValue(field: *style.Align, t: []const Token) bool {
    var c = Cur.of(t);
    const w = alignWord(&c) orelse return false;
    if (!c.atEnd()) return false;
    field.* = alignOf(w) orelse return false;
    return true;
}

fn justifyValue(field: *style.Justify, t: []const Token) bool {
    var c = Cur.of(t);
    const w = alignWord(&c) orelse return false;
    if (!c.atEnd()) return false;
    field.* = justifyOf(w) orelse return false;
    return true;
}

fn placePair(a: *style.Align, b: *style.Align, t: []const Token) bool {
    var c = Cur.of(t);
    const first = alignOf(alignWord(&c) orelse return false) orelse return false;
    var second = first;
    if (!c.atEnd()) second = alignOf(alignWord(&c) orelse return false) orelse return false;
    if (!c.atEnd()) return false;
    a.* = first;
    b.* = second;
    return true;
}

fn placeContent(s: *style.Style, t: []const Token) bool {
    var c = Cur.of(t);
    const first = alignWord(&c) orelse return false;
    var second = first;
    if (!c.atEnd()) second = alignWord(&c) orelse return false;
    if (!c.atEnd()) return false;
    s.align_content = alignOf(first) orelse return false;
    s.justify_content = justifyOf(second) orelse return false;
    return true;
}

fn gapValue(ctx: *Ctx, c: *Cur) ?Len {
    if (c.takeIdent("normal")) return Len.auto;
    return values.lengthAt(ctx, c);
}

fn gap(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    const a = gapValue(ctx, &c) orelse return false;
    var b = a;
    if (!c.atEnd()) b = gapValue(ctx, &c) orelse return false;
    if (!c.atEnd()) return false;
    ctx.style.row_gap = if (a.kind == .auto) Len.zero else a;
    ctx.style.column_gap = b;
    return true;
}

fn gap1(ctx: *Ctx, field: *Len, t: []const Token) bool {
    var c = Cur.of(t);
    const v = gapValue(ctx, &c) orelse return false;
    if (!c.atEnd()) return false;
    field.* = v;
    return true;
}

/// One track size at `c`; null if `c` is not at one.
fn trackAt(ctx: *Ctx, c: *Cur) ?Track {
    const t = c.peek() orelse return null;
    switch (t.kind) {
        .ident => {
            const out: Track = if (t.isIdent("auto"))
                .{ .kind = .auto }
            else if (t.isIdent("min-content"))
                .{ .kind = .min_content }
            else if (t.isIdent("max-content"))
                .{ .kind = .max_content }
            else
                return null;
            c.i += 1;
            return out;
        },
        .dimension => {
            if (std.ascii.eqlIgnoreCase(t.text, "fr")) {
                c.i += 1;
                return .{ .kind = .fr, .fr = t.num };
            }
        },
        .function => {
            if (t.isFunction("minmax")) {
                c.i += 1;
                return minmax(ctx, c.body());
            }
            if (t.isFunction("fit-content")) {
                // As `auto`, with its most capped at the limit.
                c.i += 1;
                var a = Cur.of(c.body());
                const limit = values.lengthAt(ctx, &a) orelse return null;
                return .{ .kind = .auto, .fit = true, .max_px = limit.px, .max_pct = limit.pct, .max_math = limit.math };
            }
        },
        else => {},
    }
    const l = values.lengthAt(ctx, c) orelse return null;
    return .{ .kind = .fixed, .px = l.px, .pct = l.pct, .math = l.math };
}

fn minmax(ctx: *Ctx, args: []const Token) ?Track {
    var c = Cur.of(args);
    var lo = Cur.of(c.untilComma());
    var hi = Cur.of(c.untilComma());
    const low = trackAt(ctx, &lo) orelse return null;
    const high = trackAt(ctx, &hi) orelse return null;
    var out: Track = .{ .kind = .minmax };
    if (low.kind == .fixed) {
        out.px = low.px;
        out.pct = low.pct;
        out.math = low.math;
    } else out.min_auto = true;
    switch (high.kind) {
        .fr => out.fr = high.fr,
        // `auto` as the most grows like a share.
        .auto, .max_content, .min_content => out.fr = 1,
        .fixed => {
            out.max_px = high.px;
            out.max_pct = high.pct;
            out.max_math = high.math;
        },
        .minmax => {},
    }
    return out;
}

/// Passes `[a b]` groups, noting their names for the line `line` when `out` is given.
fn lineNames(ctx: *Ctx, c: *Cur, line: usize, out: ?*std.ArrayList(style.LineName)) void {
    while (true) {
        const t = c.peek() orelse return;
        if (t.kind != .lbracket) return;
        while (c.next()) |k| {
            if (k.kind == .rbracket) break;
            if (k.kind == .ident) if (out) |o| {
                o.append(ctx.arena, .{ .name = k.text, .line = @intCast(@min(line + 1, 32000)) }) catch {};
            };
        }
    }
}

fn trackList(ctx: *Ctx, t: []const Token) ?TrackList {
    return trackListDeep(ctx, t, 0);
}

fn trackListDeep(ctx: *Ctx, t: []const Token, depth: u32) ?TrackList {
    if (depth > 4) return null;
    var out: std.ArrayList(Track) = .empty;
    var auto_repeat: i16 = -1;
    var repeat_len: u16 = 1;
    var auto_fit = false;
    var names: std.ArrayList(style.LineName) = .empty;
    var c = Cur.of(t);
    while (true) {
        lineNames(ctx, &c, out.items.len, &names);
        const k = c.peek() orelse break;
        if (k.kind == .string) {
            c.i += 1;
            continue;
        }
        if (k.isFunction("repeat")) {
            c.i += 1;
            var a = Cur.of(c.body());
            var head = Cur.of(a.untilComma());
            const count = head.next() orelse return null;
            const is_auto = count.isIdent("auto-fill") or count.isIdent("auto-fit");
            if (!is_auto and (count.kind != .number or count.num < 1)) return null;
            const inner = a.t[a.i..];
            const list = trackListDeep(ctx, inner, depth + 1) orelse return null;
            if (list.tracks.len == 0) return null;
            if (is_auto) {
                auto_repeat = @intCast(@min(out.items.len, 32000));
                auto_fit = count.isIdent("auto-fit");
                repeat_len = @intCast(@min(list.tracks.len, 1000));
                for (list.names) |nm| names.append(ctx.arena, .{ .name = nm.name, .line = @intCast(@min(@as(i32, nm.line) + @as(i32, auto_repeat), 32000)) }) catch return null;
                out.appendSlice(ctx.arena, list.tracks) catch return null;
            } else {
                const times: usize = @intFromFloat(@min(count.num, 1000));
                for (0..times) |_| {
                    const base: i32 = @intCast(@min(out.items.len, 32000));
                    if (out.items.len < 32000) for (list.names) |nm| names.append(ctx.arena, .{ .name = nm.name, .line = @intCast(@min(@as(i32, nm.line) + base, 32000)) }) catch return null;
                    out.appendSlice(ctx.arena, list.tracks) catch return null;
                }
            }
            continue;
        }
        const tr = trackAt(ctx, &c) orelse return null;
        out.append(ctx.arena, tr) catch return null;
    }
    return .{ .tracks = out.items, .auto_repeat = auto_repeat, .repeat_len = repeat_len, .auto_fit = auto_fit, .names = names.items };
}

fn template(ctx: *Ctx, field: *TrackList, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (std.ascii.eqlIgnoreCase(w, "none") or std.ascii.eqlIgnoreCase(w, "masonry")) {
            field.* = .{};
            return true;
        }
        if (std.ascii.eqlIgnoreCase(w, "subgrid")) {
            field.* = .{ .subgrid = true };
            return true;
        }
    }
    field.* = trackList(ctx, t) orelse return false;
    return true;
}

fn gridTemplate(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    if (values.ident(t)) |w| if (std.ascii.eqlIgnoreCase(w, "none")) {
        s.grid_template_columns = .{};
        s.grid_template_rows = .{};
        s.grid_areas = &.{};
        return true;
    };
    // `grid`'s other forms set `grid-auto-*`, not templates: those start
    // with one of these words and are left alone.
    var c0 = Cur.of(t);
    if (c0.peek()) |h| if (h.isIdent("auto-flow")) return true;
    var slash: ?usize = null;
    var depth: u32 = 0;
    for (t, 0..) |k, i| switch (k.kind) {
        .function, .lparen, .lbracket => depth += 1,
        .rparen, .rbracket => depth -|= 1,
        .delim => if (depth == 0 and k.delim == '/') {
            slash = i;
            break;
        },
        else => {},
    };
    const rows_part = t[0 .. slash orelse t.len];
    const rows = trackList(ctx, rows_part) orelse return false;
    var cols: TrackList = .{};
    if (slash) |i| {
        var cc = Cur.of(t[i + 1 ..]);
        if (cc.peek()) |h| if (!h.isIdent("auto-flow")) {
            cols = trackList(ctx, t[i + 1 ..]) orelse return false;
        };
    }
    s.grid_template_rows = rows;
    s.grid_template_columns = cols;
    s.grid_areas = areasOf(ctx, rows_part) orelse &.{};
    return true;
}

/// `grid-auto-flow`: the axis, and whether it goes back to fill holes.
fn autoFlow(s: *style.Style, t: []const Token) bool {
    s.grid_auto_flow_column = false;
    s.grid_auto_flow_dense = false;
    for (t) |k| {
        if (k.isIdent("column")) s.grid_auto_flow_column = true;
        if (k.isIdent("dense")) s.grid_auto_flow_dense = true;
    }
    return true;
}

fn templateAreas(ctx: *Ctx, t: []const Token) bool {
    ctx.style.grid_areas = &.{};
    if (values.ident(t)) |w| if (std.ascii.eqlIgnoreCase(w, "none")) return true;
    ctx.style.grid_areas = areasOf(ctx, t) orelse return false;
    return true;
}

/// The rectangles the strings among `t` draw, one string to a row. Null if
/// there are no strings. A name drawn in several places takes the box round them.
fn areasOf(ctx: *Ctx, t: []const Token) ?[]const style.GridArea {
    var out: std.ArrayList(style.GridArea) = .empty;
    var row: i16 = 1;
    for (t) |k| {
        if (k.kind != .string) continue;
        var col: i16 = 1;
        var cells = std.mem.tokenizeAny(u8, k.text, " \t\r\n\x0c");
        while (cells.next()) |cell| : (col +|= 1) {
            if (cell[0] == '.') continue;
            var known = false;
            for (out.items) |*a| if (std.mem.eql(u8, a.name, cell)) {
                a.col0 = @min(a.col0, col);
                a.col1 = @max(a.col1, col + 1);
                a.row0 = @min(a.row0, row);
                a.row1 = @max(a.row1, row + 1);
                known = true;
            };
            if (!known) out.append(ctx.arena, .{ .name = cell, .col0 = col, .col1 = col + 1, .row0 = row, .row1 = row + 1 }) catch return null;
        }
        row +|= 1;
    }
    return if (row == 1) null else out.items;
}

fn autoTrack(ctx: *Ctx, field: *Track, t: []const Token) bool {
    var c = Cur.of(t);
    field.* = trackAt(ctx, &c) orelse return false;
    return true;
}

const Line = struct { value: i16 = 0, span: u16 = 0, name: []const u8 = "" };

fn clampLine(n: f32) i16 {
    return @intFromFloat(std.math.clamp(n, -10000, 10000));
}

/// A grid line: `auto`, `3`, `span 2`, or a name.
fn lineAt(t: []const Token) ?Line {
    var c = Cur.of(t);
    var out: Line = .{};
    var saw_span = false;
    var any = false;
    while (c.next()) |k| {
        any = true;
        if (k.isIdent("span")) {
            saw_span = true;
        } else if (k.isIdent("auto")) {
            // The default.
        } else if (k.kind == .number) {
            if (saw_span) {
                out.span = @intFromFloat(std.math.clamp(k.num, 1, 10000));
            } else {
                out.value = clampLine(k.num);
            }
        } else if (k.kind == .ident) {
            out.name = k.text;
        } else {
            return null;
        }
    }
    if (!any) return null;
    if (saw_span and out.span == 0) out.span = 1;
    return out;
}

fn splitSlash(t: []const Token, out: *[4][]const Token) usize {
    var n: usize = 0;
    var start: usize = 0;
    for (t, 0..) |k, i| if (k.isDelim('/') and n < 3) {
        out[n] = t[start..i];
        n += 1;
        start = i + 1;
    };
    out[n] = t[start..];
    return n + 1;
}

fn placeFrom(a: Line, b: ?Line) GridPlace {
    var p: GridPlace = .{ .start = a.value, .span = if (a.span > 0) a.span else 1, .start_name = a.name };
    if (b) |e| {
        p.end = e.value;
        p.end_name = e.name;
        if (e.span > 0) p.span = e.span;
    } else p.end_name = a.name; // A lone name is the area's both ends.
    return p;
}

fn gridSpan(field: *GridPlace, t: []const Token) bool {
    var parts: [4][]const Token = undefined;
    const n = splitSlash(t, &parts);
    if (n > 2) return false;
    const a = lineAt(parts[0]) orelse return false;
    const b: ?Line = if (n == 2) lineAt(parts[1]) orelse return false else null;
    field.* = placeFrom(a, b);
    return true;
}

fn gridLine(field: *GridPlace, t: []const Token, is_start: bool) bool {
    const l = lineAt(t) orelse return false;
    if (is_start) {
        field.start = l.value;
        field.start_name = l.name;
    } else {
        field.end = l.value;
        field.end_name = l.name;
    }
    if (l.span > 0) field.span = l.span;
    return true;
}

fn gridArea(ctx: *Ctx, t: []const Token) bool {
    var parts: [4][]const Token = undefined;
    const n = splitSlash(t, &parts);
    const s = ctx.style;
    const row_start = lineAt(parts[0]) orelse return false;
    const col_start = if (n > 1) lineAt(parts[1]) orelse return false else Line{};
    const row_end: ?Line = if (n > 2) lineAt(parts[2]) orelse return false else null;
    // Left out, a name stands for the row's and then the start's.
    const col_end: ?Line = if (n > 3) lineAt(parts[3]) orelse return false else null;
    s.grid_row = placeFrom(row_start, row_end);
    if (n == 1) {
        s.grid_column = .{ .start_name = row_start.name, .end_name = row_start.name };
    } else s.grid_column = placeFrom(col_start, col_end);
    return true;
}
