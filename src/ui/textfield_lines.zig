//! A multiline text field's lines, as Harness's composer has them: the
//! text broken at its newlines and wrapped at the field's width, the caret
//! moved between them (up, down, a click), and the field drawn growing with
//! them up to its most lines, then scrolling inside.
const std = @import("std");
const types = @import("types.zig");
const Context = @import("context.zig").Context;
const EditState = @import("context.zig").EditState;

/// One line as drawn: bytes [start, end) shown, and the caret positions up
/// to `stop` (the next line's start, or the newline) belonging to it.
pub const Line = struct { start: usize, end: usize, stop: usize };

/// `s` in lines no wider than `width`, in the frame's memory.
pub fn layout(c: *Context, s: []const u8, style: types.TextStyle, width: f32) []const Line {
    var out: std.ArrayList(Line) = .empty;
    var p: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, s, p, '\n') orelse s.len;
        const wrapped = c.text.wrap(s[p..nl], style, width);
        for (wrapped, 0..) |l, k| {
            const stop = if (k + 1 < wrapped.len) p + wrapped[k + 1].start else nl;
            out.append(c.alloc(), .{ .start = p + l.start, .end = p + l.end, .stop = stop }) catch break;
        }
        if (wrapped.len == 0) out.append(c.alloc(), .{ .start = p, .end = p, .stop = nl }) catch {};
        if (nl == s.len) break;
        p = nl + 1;
    }
    return out.items;
}

/// The line the caret at byte `at` is drawn on: at a wrap, the next one.
pub fn lineOf(lines: []const Line, at: usize) usize {
    var k: usize = 0;
    while (k + 1 < lines.len and lines[k + 1].start <= at) k += 1;
    return k;
}

/// The caret's x in its line. A line's `end` leaves its trailing spaces out
/// (nothing of them is drawn), but the caret can sit among and after them, up
/// to `stop`: measure through them to it.
pub fn caretX(c: *Context, s: []const u8, style: types.TextStyle, l: Line, at: usize) f32 {
    const to = @min(@max(at, l.start), l.stop);
    return c.text.caretX(s[l.start..to], style, to - l.start);
}

/// The byte nearest to `x` on line `l`.
pub fn indexAt(c: *Context, s: []const u8, style: types.TextStyle, l: Line, x: f32) usize {
    return l.start + c.text.indexAt(s[l.start..l.end], style, x);
}

/// Where the caret goes a line up (`dir` -1) or down (1), keeping its x;
/// before the first line, the text's start; past the last, its end.
pub fn vertical(c: *Context, s: []const u8, style: types.TextStyle, lines: []const Line, at: usize, dir: i2) usize {
    const k = lineOf(lines, at);
    const x = caretX(c, s, style, lines[k], at);
    if (dir < 0) return if (k == 0) 0 else indexAt(c, s, style, lines[k - 1], x);
    return if (k + 1 >= lines.len) s.len else indexAt(c, s, style, lines[k + 1], x);
}

/// The byte under a point of the field's content (scroll included).
pub fn indexAtPoint(c: *Context, s: []const u8, style: types.TextStyle, lines: []const Line, x: f32, y: f32, lh: f32) usize {
    const row: usize = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(lines.len - 1)), @floor(y / lh))));
    return indexAt(c, s, style, lines[row], x);
}

pub const Drawn = struct {
    /// The caret's place in the field's content, scrolled.
    caret: types.Point,
    line: usize,
    lines: usize,
};

/// Draws `s` in `lines` into the open field, a scrolling box (absolute
/// boxes from its content's corner, which layout moves by `e.scroll_y`,
/// over a spacer as tall as the lines): selection, text, composition and
/// caret. When `follow` (the caret moved, the text changed), scrolled to
/// keep the caret in view within `view_h`; else where the wheel left it.
pub fn draw(c: *Context, s: []const u8, e: *EditState, style: types.TextStyle, lines: []const Line, view_h: f32, focused: bool, follow: bool, block: bool, placeholder: []const u8, placeholder_color: types.Color, suggestion: []const u8) Drawn {
    const th = c.theme;
    const lh = c.text.lineHeight(style);
    const k = lineOf(lines, e.caret);
    const cx = caretX(c, s, style, lines[k], e.caret);
    const cy = @as(f32, @floatFromInt(k)) * lh;
    if (focused and follow) {
        if (cy - e.scroll_y < 0) e.scroll_y = cy;
        if (cy + lh - e.scroll_y > view_h) e.scroll_y = cy + lh - view_h;
    }
    const total = @as(f32, @floatFromInt(lines.len)) * lh;
    e.scroll_y = @max(0, @min(e.scroll_y, total - view_h));
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = total } }, .none, null);
    const lo = @min(e.caret, e.anchor);
    const hi = @max(e.caret, e.anchor);
    for (lines, 0..) |l, row| {
        const y = @as(f32, @floatFromInt(row)) * lh;
        if (y + lh < e.scroll_y or y > e.scroll_y + view_h) continue;
        if (focused and hi > lo and hi >= l.start and lo <= l.stop) {
            const x0 = caretX(c, s, style, l, @max(lo, l.start));
            // A selection across the line's end covers a space's width past it.
            const past: f32 = if (hi > l.stop or (hi == l.stop and l.stop < s.len)) 4 else 0;
            const x1 = caretX(c, s, style, l, @min(hi, l.end)) + past;
            if (x1 > x0) _ = c.leaf(.{ .absolute = true, .width = .{ .px = x1 - x0 }, .height = .{ .px = lh }, .radius = 2, .background = th.accent.alpha(0.3), .offset = .{ .x = x0, .y = y } }, .none, null);
        }
        if (l.end > l.start) _ = c.leaf(.{ .absolute = true, .offset = .{ .y = y } }, .{ .text = .{ .str = s[l.start..l.end], .style = style, .color = th.text } }, null);
        if (focused) if (e.marked) |m| if (m[1] > l.start and m[0] < l.stop) {
            const x0 = caretX(c, s, style, l, @max(m[0], l.start));
            const x1 = caretX(c, s, style, l, @min(m[1], l.end));
            _ = c.leaf(.{ .absolute = true, .width = .{ .px = x1 - x0 }, .height = .{ .px = 1.5 }, .background = th.text, .offset = .{ .x = x0, .y = y + lh - 1 } }, .none, null);
        };
    }
    if (s.len == 0) _ = c.leaf(.{ .absolute = true }, .{ .text = .{ .str = placeholder, .style = style, .color = placeholder_color } }, null);
    if (suggestion.len > 0 and focused and e.caret == s.len)
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = cx, .y = cy } }, .{ .text = .{ .str = suggestion, .style = style, .color = th.muted.alpha(0.8) } }, null);
    if (focused and hi == lo) {
        const l = lines[k];
        const w: f32 = if (!block) 1.5 else if (e.caret < l.end) @max(4, caretX(c, s, style, l, e.caret + 1) - cx) else c.text.width("m", style);
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = w }, .height = .{ .px = lh }, .background = if (block) th.accent.alpha(0.45) else th.accent, .offset = .{ .x = cx, .y = cy } }, .none, null);
    }
    return .{ .caret = .{ .x = cx, .y = cy - e.scroll_y }, .line = k, .lines = lines.len };
}
