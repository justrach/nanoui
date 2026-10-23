//! A text area: text in several lines, wrapped to its width, edited as the
//! text field is (`textfield.apply`, the input system, the clipboard). It
//! grows with its lines to `max_lines`, then scrolls with the caret kept in
//! view. Return submits (a chat's composer); ⇧Return and ⌥Return break the
//! line.
const std = @import("std");
const types = @import("types.zig");
const tf = @import("textfield.zig");
const textedit = @import("textedit.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const EditState = ctx_mod.EditState;
pub const AreaOptions = struct {
    placeholder: []const u8 = "",
    width: types.Length = .fill,
    size: f32 = 13,
    min_lines: u8 = 1,
    max_lines: u8 = 8,
    /// Return submits; with Shift or Option it breaks the line.
    submit_on_return: bool = true,
    /// No box of its own: for an area inside a larger frame.
    bare: bool = true,
    selection_color: ?types.Color = null,
    caret_color: ?types.Color = null,
    /// The typed text's color (the theme's text when null).
    color: ?types.Color = null,
};

/// A visual line: bytes [start, end) of the text, without its newline.
const Line = struct { start: usize, end: usize };

/// The visual lines of `s` in `w` points: each paragraph wrapped.
fn linesOf(c: *Context, s: []const u8, style: types.TextStyle, w: f32) []const Line {
    var out: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, s, start, '\n') orelse s.len;
        // The text system's lines are its cache's: copied before it wraps again.
        const wrapped = c.text.wrap(s[start..nl], style, w);
        for (wrapped, 0..) |l, i| {
            const end = if (i + 1 < wrapped.len) start + wrapped[i + 1].start else nl;
            out.append(c.alloc(), .{ .start = start + l.start, .end = end }) catch break;
        }
        if (wrapped.len == 0) out.append(c.alloc(), .{ .start = start, .end = nl }) catch {};
        if (nl == s.len) break;
        start = nl + 1;
    }
    return out.items;
}

/// The line the caret at `pos` is on.
fn lineAt(lines: []const Line, pos: usize) usize {
    var i: usize = 0;
    while (i + 1 < lines.len and lines[i + 1].start <= pos) i += 1;
    return i;
}

fn caretX(c: *Context, s: []const u8, style: types.TextStyle, l: Line, pos: usize) f32 {
    return c.text.caretX(s[l.start..l.end], style, @min(pos, l.end) -| l.start);
}

/// The byte under `x` on line `i`.
fn indexOn(c: *Context, s: []const u8, style: types.TextStyle, lines: []const Line, i: usize, x: f32) usize {
    const l = lines[@min(i, lines.len - 1)];
    return l.start + c.text.indexAt(s[l.start..l.end], style, x);
}

/// ↑ or ↓: the caret to the line above or below, at about the same x.
fn vertical(c: *Context, s: []const u8, style: types.TextStyle, w: f32, e: *EditState, down: bool, extend: bool) void {
    const lines = linesOf(c, s, style, w);
    const i = lineAt(lines, e.caret);
    const x = caretX(c, s, style, lines[i], e.caret);
    const to = if (down) (if (i + 1 < lines.len) indexOn(c, s, style, lines, i + 1, x) else s.len) else if (i > 0) indexOn(c, s, style, lines, i - 1, x) else 0;
    e.caret = to;
    if (!extend) e.anchor = to;
}

/// Fills bytes [lo, hi) line by line: the selection, the composition's underline.
fn spanRects(c: *Context, s: []const u8, style: types.TextStyle, lines: []const Line, lo: usize, hi: usize, lh: f32, scroll: f32, color: types.Color, under: bool) void {
    for (lines, 0..) |l, i| {
        if (hi <= l.start or lo > l.end or (lo == l.end and hi > lo and i + 1 < lines.len and lines[i + 1].start == l.end)) continue;
        const x0 = caretX(c, s, style, l, @max(lo, l.start));
        // Past the end of the line: its newline is selected too.
        const x1 = caretX(c, s, style, l, hi) + @as(f32, if (hi > l.end and !under) 4 else 0);
        const y = @as(f32, @floatFromInt(i)) * lh - scroll;
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = @max(0, x1 - x0) }, .height = .{ .px = if (under) 1.5 else lh }, .radius = if (under) 0 else 2, .background = color, .offset = .{ .x = x0, .y = if (under) y + lh - 1 else y } }, .none, null);
    }
}

pub fn textArea(c: *Context, buffer: *tf.TextBuffer, opts: AreaOptions) tf.Result {
    const th = c.theme;
    const style: types.TextStyle = .{ .size = opts.size };
    const pad: types.Edges = if (opts.bare) .{} else .xy(10, 7);
    const lh = c.text.font(style).lineHeight();
    const i = c.open(.{
        .width = opts.width,
        .padding = pad,
        .radius = 8,
        .background = if (opts.bare) null else th.surface,
        .border = if (opts.bare) null else th.border,
        .clip = true,
    }, null);
    defer c.end();
    tf.rehome(c, buffer, c.node(i).id);
    const it = c.interact(i, .{ .focusable = true });
    c.addA11y(i, .text_field, opts.placeholder, buffer.text(), it.focused, true);
    if (it.hovered) {
        c.cursor_hand = false;
        c.cursor_text = true;
    }
    if (!opts.bare) {
        const focus_t = c.animate(it.id, 0, if (it.focused) 1 else 0, 20);
        const n = c.node(i);
        n.style.border = th.border.mix(th.accent, focus_t);
        n.style.border_width = 1 + focus_t;
    }
    var result: tf.Result = .{ .focused = it.focused };
    const e = tf.editState(c, it.id, buffer) orelse return result;
    // Wrapped in the width it had: none yet in its first frame, so another follows.
    const w: f32 = if (it.rect) |r| @max(1, r.w - pad.horizontal()) else 1e6;
    if (it.rect == null) c.animationFrame();
    const field: tf.Options = .{};

    if (it.right_clicked) c.text_menu = true;
    if (it.focused) {
        const prev_caret = e.caret;
        const was_focused = e.had_focus;
        if (it.rect) |r| {
            const lines = linesOf(c, buffer.text(), style, w);
            const x = c.input.mouse.x - r.x - pad.left;
            const row: usize = @intFromFloat(@max(0, (c.input.mouse.y - r.y - pad.top + e.scroll_y) / lh));
            if (c.input.pressed and c.input.button == .left and !c.input.ctrl and it.hovered) {
                const at = indexOn(c, buffer.text(), style, lines, row, x);
                textedit.pointerSelect(c, e, buffer.text(), at, true);
            } else if (e.selecting and c.input.down) {
                const at = indexOn(c, buffer.text(), style, lines, row, x);
                textedit.pointerDrag(c, e, buffer.text(), at, true);
            }
            if (!c.input.down) e.selecting = false;
        }
        tf.focusSelect(c, e, false, buffer.text().len);
        e.undo.begin(buffer.text(), e.caret);
        const took_undo = textedit.handleUndoShortcuts(c, buffer, e, &result);
        const newline = !opts.submit_on_return or c.input.shift or c.input.alt;
        for (c.input.ops) |op| {
            if (op == .command) switch (op.command) {
                .cancel => c.focus = 0,
                .copy, .cut => if (e.caret != e.anchor) {
                    c.copy_done = true;
                },
                .insert_newline, .insert_line_break => {
                    if (op.command == .insert_line_break or newline) tf.apply(buffer, e, .{ .insert = "\n" }, field, c.clipboard, &result) else result.submitted = true;
                    continue;
                },
                .move_up, .move_down, .select_up, .select_down => |m| {
                    vertical(c, buffer.text(), style, w, e, m == .move_down or m == .select_down, m == .select_up or m == .select_down);
                    continue;
                },
                else => {},
            };
            tf.apply(buffer, e, op, field, c.clipboard, &result);
        }
        // Without an input method (tests, synthetic input): keys and chars.
        if (c.input.chars.len > 0) tf.apply(buffer, e, .{ .insert = c.input.chars }, field, c.clipboard, &result);
        if (!took_undo) if (c.input.key) |k| switch (k) {
            .backspace => tf.apply(buffer, e, .{ .command = .delete_backward }, field, c.clipboard, &result),
            .delete => tf.apply(buffer, e, .{ .command = .delete_forward }, field, c.clipboard, &result),
            .left => tf.apply(buffer, e, .{ .command = if (c.input.shift) .select_left else .move_left }, field, c.clipboard, &result),
            .right => tf.apply(buffer, e, .{ .command = if (c.input.shift) .select_right else .move_right }, field, c.clipboard, &result),
            .up, .down => vertical(c, buffer.text(), style, w, e, k == .down, c.input.shift),
            .home => tf.apply(buffer, e, .{ .command = .move_line_start }, field, c.clipboard, &result),
            .end => tf.apply(buffer, e, .{ .command = .move_line_end }, field, c.clipboard, &result),
            .enter => if (newline) tf.apply(buffer, e, .{ .insert = "\n" }, field, c.clipboard, &result) else {
                result.submitted = true;
            },
            .escape => c.focus = 0,
            else => {},
        };
        textedit.commitUndo(c, buffer, e, &result, false, took_undo);
        textedit.updateCaretBlink(c, was_focused, result.changed, e.caret != prev_caret);
        if (result.changed or result.submitted) c.changed = true;
        if (c.focus != it.id) {
            c.changed = true;
            e.marked = null;
        }
    } else {
        e.marked = null;
        e.selecting = false;
        e.had_focus = false;
    }

    const focused = it.focused and c.focus == it.id;
    result.focused = focused;
    result.caret = e.caret;
    // A copy for the frame, as the text field's.
    const s = c.alloc().dupe(u8, buffer.text()) catch buffer.text();
    const lines = linesOf(c, s, style, w);
    const shown: f32 = @floatFromInt(std.math.clamp(lines.len, opts.min_lines, @max(opts.min_lines, opts.max_lines)));
    const view_h = shown * lh;
    c.node(i).style.height = .{ .px = view_h + pad.vertical() };
    const cl = lineAt(lines, e.caret);
    const caret_x = caretX(c, s, style, lines[cl], e.caret);
    const caret_y = @as(f32, @floatFromInt(cl)) * lh;
    // Keep the caret in view.
    if (focused) {
        if (caret_y < e.scroll_y) e.scroll_y = caret_y;
        if (caret_y + lh > e.scroll_y + view_h) e.scroll_y = caret_y + lh - view_h;
    }
    e.scroll_y = std.math.clamp(e.scroll_y, 0, @max(0, @as(f32, @floatFromInt(lines.len)) * lh - view_h));

    const lo = @min(e.caret, e.anchor);
    const hi = @max(e.caret, e.anchor);
    if (focused and hi > lo) spanRects(c, s, style, lines, lo, hi, lh, e.scroll_y, opts.selection_color orelse th.accent.alpha(0.28), false);
    if (s.len == 0) {
        _ = c.leaf(.{ .absolute = true }, .{ .text = .{ .str = opts.placeholder, .style = style, .color = th.muted } }, null);
    } else for (lines, 0..) |l, n| {
        const y = @as(f32, @floatFromInt(n)) * lh - e.scroll_y;
        if (y + lh < 0 or y > view_h or l.end == l.start) continue;
        _ = c.leaf(.{ .absolute = true, .offset = .{ .y = y } }, .{ .text = .{ .str = s[l.start..l.end], .style = style, .color = opts.color orelse th.text } }, null);
    }
    if (focused) if (e.marked) |m| spanRects(c, s, style, lines, m[0], m[1], lh, e.scroll_y, opts.color orelse th.text, true);
    if (focused and hi == lo and textedit.caretVisible(c))
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = 1.5 }, .height = .{ .px = lh }, .background = opts.caret_color orelse th.accent, .offset = .{ .x = caret_x, .y = caret_y - e.scroll_y } }, .none, null);
    if (focused) {
        c.focused_multiline = true;
        c.focused_password = false;
        const r = it.rect orelse types.Rect{};
        c.focused_text = .{
            .id = it.id,
            .text = s,
            .caret = e.caret,
            .anchor = e.anchor,
            .marked = e.marked,
            .caret_rect = .{ .x = r.x + pad.left + caret_x, .y = r.y + pad.top + caret_y - e.scroll_y, .w = 1.5, .h = lh },
        };
    }
    return result;
}
