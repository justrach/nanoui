//! A text field, edited through AppKit's text input: typing, accents and
//! input methods (composition shown underlined), the system's key bindings,
//! selection with the keyboard and the mouse, the clipboard. One line that
//! scrolls sideways to keep the caret in view, or (`multiline`) lines that
//! wrap and grow, then scroll (textfield_lines.zig).
const std = @import("std");
const keymap = @import("keymap.zig");
const types = @import("types.zig");
const utf8 = @import("utf8.zig");
const ctx_mod = @import("context.zig");
const lines_mod = @import("textfield_lines.zig");
const Context = ctx_mod.Context;
const EditState = ctx_mod.EditState;

/// The text a field edits, kept by the app. Its bytes are on the C heap,
/// as long as they grow: `deinit` frees them.
pub const TextBuffer = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Where the caret goes in the next frame, after the app set the text.
    want_caret: ?usize = null,
    /// The selection (anchor, caret) the next frame applies, as `want_caret`.
    want_selection: ?[2]usize = null,
    /// The box id this buffer was last built under, so focus, caret and undo
    /// survive when a parent container is added or removed around the field.
    last_id: u64 = 0,
    const gpa = std.heap.c_allocator;

    pub fn deinit(b: *TextBuffer) void {
        b.buf.deinit(gpa);
        b.* = .{};
    }

    pub fn text(b: *const TextBuffer) []const u8 {
        return b.buf.items;
    }

    /// Replaces the text; the caret goes to its end.
    pub fn set(b: *TextBuffer, s: []const u8) void {
        const items = b.buf.items;
        // A part of its own text (trimmed): moved to the front, in place.
        if (s.len > 0 and @intFromPtr(s.ptr) >= @intFromPtr(items.ptr) and @intFromPtr(s.ptr) < @intFromPtr(items.ptr) + items.len) {
            std.mem.copyForwards(u8, items[0..s.len], s);
            b.buf.shrinkRetainingCapacity(s.len);
        } else _ = b.replace(0, items.len, s);
        b.want_caret = b.buf.items.len;
    }

    pub fn clear(b: *TextBuffer) void {
        b.buf.clearRetainingCapacity();
        b.want_caret = 0;
    }

    /// Inserts `s` at byte `at`; returns how many bytes went in.
    pub fn insert(b: *TextBuffer, at: usize, s: []const u8) usize {
        return b.replace(at, at, s);
    }

    pub fn remove(b: *TextBuffer, from: usize, to: usize) void {
        _ = b.replace(from, to, "");
    }

    /// Replaces bytes [from, to) with `s`; returns the bytes inserted:
    /// all of them, or none (and nothing changes) when memory runs out.
    pub fn replace(b: *TextBuffer, from: usize, to: usize, s: []const u8) usize {
        b.buf.replaceRange(gpa, from, to - from, s) catch return 0;
        return s.len;
    }
};

fn prevBoundary(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and (s[j] & 0xc0) == 0x80) j -= 1;
    return j;
}

fn nextBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    return @min(s.len, i + utf8.seqLen(s[i]));
}

const textedit = @import("textedit.zig");
const prevWord = textedit.prevWord;
const nextWord = textedit.nextWord;

pub const Options = struct {
    placeholder: []const u8 = "",
    width: types.Length = .{ .px = 240 },
    size: f32 = 14,
    /// Shows bullets instead of the text, and keeps it off the clipboard.
    password: bool = false,
    /// Text that would follow what is typed, drawn faintly after it, as a
    /// shell's autosuggestion: → (or End) at the end of the text takes it.
    suggestion: []const u8 = "",
    /// No box of its own (border, fill, focus ring): for a field inside a
    /// larger frame, as a chat composer.
    bare: bool = false,
    /// The editing keys: the system's, Emacs's or Vim's (keymap.zig).
    keys: keymap.Keymap = .system,
    /// The selection's fill (the accent at .28 when null) and the caret's
    /// color (the accent).
    selection_color: ?types.Color = null,
    caret_color: ?types.Color = null,
    /// The typed text's color (the theme's text when null).
    color: ?types.Color = null,
    /// Gaining the focus selects all the text, as an address field.
    select_all_on_focus: bool = false,
    /// Wraps, and grows to `max_lines` before it scrolls; Shift-Return
    /// (or Option-Return) starts a new line, Return still submits.
    multiline: bool = false,
    max_lines: u16 = 8,
};

pub const Result = struct {
    changed: bool = false,
    /// Return was pressed.
    submitted: bool = false,
    focused: bool = false,
    /// The suggestion was taken into the text.
    accepted: bool = false,
    /// The caret's byte offset after this frame's edits.
    caret: usize = 0,
    /// Vim's normal mode is on, and visual mode in it (for a mode indicator).
    vim_normal: bool = false,
    vim_visual: bool = false,
    /// Vim's j and k in normal mode: -1 back through history, 1 forward.
    history: i8 = 0,
    /// The caret's line as drawn, of how many (one, unless multiline): an
    /// app's ↑ on the first or ↓ on the last goes to its history.
    line: usize = 0,
    lines: usize = 1,
};

/// Applies one text input operation to the buffer and its editing state.
pub fn apply(buffer: *TextBuffer, e: *EditState, op: ctx_mod.TextOp, opts: Options, clip: ctx_mod.Clipboard, result: *Result) void {
    const password = opts.password;
    const s = buffer.text();
    // → or End at the end of the text takes the suggestion.
    if (op == .command and (op.command == .move_right or op.command == .move_line_end) and opts.suggestion.len > 0 and
        e.caret == s.len and e.anchor == s.len and e.marked == null and !result.accepted)
    {
        const n = buffer.insert(s.len, opts.suggestion);
        e.caret = buffer.text().len;
        e.anchor = e.caret;
        result.changed = n > 0;
        result.accepted = n > 0;
        return;
    }
    const lo = @min(e.caret, e.anchor);
    const hi = @max(e.caret, e.anchor);
    // A line's start and end: the text's, or in a multiline field the
    // caret's line's (between newlines).
    const line_start = if (opts.multiline) keymap.lineStart(s, e.caret) else 0;
    const line_end = if (opts.multiline) keymap.lineEnd(s, e.caret) else s.len;
    switch (op) {
        .insert => |t| {
            const range = e.marked orelse .{ lo, hi };
            const n = buffer.replace(range[0], range[1], t);
            e.caret = range[0] + n;
            e.anchor = e.caret;
            e.marked = null;
            result.changed = true;
        },
        .set_marked => |m| {
            const range = e.marked orelse .{ lo, hi };
            const n = buffer.replace(range[0], range[1], m.text);
            e.marked = if (n == 0) null else .{ range[0], range[0] + n };
            e.caret = range[0] + @min(m.sel_start + m.sel_len, n);
            e.anchor = range[0] + @min(m.sel_start, n);
            result.changed = true;
        },
        .unmark => e.marked = null,
        .command => |cmd| {
            const collapse = struct {
                fn to(st: *EditState, at: usize) void {
                    st.caret = at;
                    st.anchor = at;
                }
            }.to;
            switch (cmd) {
                .delete_backward, .delete_word_backward, .delete_to_line_start => {
                    if (hi > lo) {
                        buffer.remove(lo, hi);
                        collapse(e, lo);
                    } else if (e.caret > 0) {
                        const from = switch (cmd) {
                            .delete_word_backward => prevWord(s, e.caret),
                            .delete_to_line_start => if (line_start == e.caret and e.caret > 0) e.caret - 1 else line_start,
                            else => prevBoundary(s, e.caret),
                        };
                        buffer.remove(from, e.caret);
                        collapse(e, from);
                    } else return;
                    result.changed = true;
                },
                .delete_word_forward, .delete_to_line_end => {
                    if (hi > lo) {
                        buffer.remove(lo, hi);
                        collapse(e, lo);
                    } else if (e.caret < s.len) {
                        const to = if (cmd == .delete_word_forward) nextWord(s, e.caret) else if (line_end == e.caret) e.caret + 1 else line_end;
                        buffer.remove(e.caret, to);
                    } else return;
                    result.changed = true;
                },
                .delete_forward => {
                    if (hi > lo) {
                        buffer.remove(lo, hi);
                        collapse(e, lo);
                    } else if (e.caret < s.len) {
                        buffer.remove(e.caret, nextBoundary(s, e.caret));
                    } else return;
                    result.changed = true;
                },
                .move_left => collapse(e, if (hi > lo) lo else prevBoundary(s, e.caret)),
                .move_right => collapse(e, if (hi > lo) hi else nextBoundary(s, e.caret)),
                .move_word_left => collapse(e, prevWord(s, e.caret)),
                .move_word_right => collapse(e, nextWord(s, e.caret)),
                .move_line_start => collapse(e, line_start),
                .move_line_end => collapse(e, line_end),
                // A multiline field moves between lines itself (textField).
                .move_up => collapse(e, 0),
                .move_down => collapse(e, s.len),
                .select_up => e.caret = 0,
                .select_down => e.caret = s.len,
                .select_left => e.caret = prevBoundary(s, e.caret),
                .select_right => e.caret = nextBoundary(s, e.caret),
                .select_word_left => e.caret = prevWord(s, e.caret),
                .select_word_right => e.caret = nextWord(s, e.caret),
                .select_line_start => e.caret = line_start,
                .select_line_end => e.caret = line_end,
                .select_all => {
                    e.anchor = 0;
                    e.caret = s.len;
                },
                .insert_newline => result.submitted = true,
                .insert_line_break => if (opts.multiline) {
                    const n = buffer.replace(lo, hi, "\n");
                    collapse(e, lo + n);
                    result.changed = n > 0;
                } else {
                    result.submitted = true;
                },
                .insert_tab, .cancel => {},
                .copy, .cut => {
                    if (hi == lo or password) return;
                    clip.write(clip.ctx, s[lo..hi]);
                    if (cmd == .cut) {
                        buffer.remove(lo, hi);
                        collapse(e, lo);
                        result.changed = true;
                    }
                },
            }
        },
    }
}

const bullets = "••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••";

pub fn textField(c: *Context, buffer: *TextBuffer, opts: Options) Result {
    const th = c.theme;
    const style: types.TextStyle = .{ .size = opts.size };
    const pad_x: f32 = if (opts.bare) 0 else 10;
    const pad_y: f32 = if (opts.bare) 2 else 7;
    const multi = opts.multiline and !opts.password;
    const i = c.open(.{
        .direction = if (multi) .column else .row,
        .width = opts.width,
        .padding = .xy(pad_x, pad_y),
        .radius = 8,
        .background = if (opts.bare) null else th.surface,
        .border = if (opts.bare) null else th.border,
        .align_items = if (multi) .start else .center,
        .clip = true,
    }, null);
    defer c.end();
    rehome(c, buffer, c.node(i).id);
    const it = c.interact(i, .{ .focusable = true });
    c.addA11y(i, .text_field, opts.placeholder, buffer.text(), it.focused, true);
    if (it.hovered) {
        c.cursor_hand = false;
        c.cursor_text = true;
    }
    const focus_t = c.animate(it.id, 0, if (it.focused) 1 else 0, 20);
    const n = c.node(i);
    if (!opts.bare) {
        n.style.border = th.border.mix(th.accent, focus_t);
        n.style.border_width = 1 + focus_t;
        if (focus_t > 0.01) n.style.shadow = .{ .color = th.accent.alpha(0.25 * focus_t), .blur = 6, .y = 0 };
    }

    var result: Result = .{ .focused = it.focused };
    const e = editState(c, it.id, buffer) orelse return result;
    // A multiline field wraps at last frame's width (unknown at first).
    const wrap_w: f32 = if (it.rect) |r| @max(1, r.w - 2 * pad_x) else 1e6;
    const lh_ = c.text.font(style).lineHeight();
    // Where the wheel scrolled a multiline field; the caret before edits.
    if (multi) if (c.scroll.get(it.id)) |v| {
        e.scroll_y = v;
    };
    const caret_before = .{ e.caret, e.anchor, buffer.text().len };

    // What is drawn: bullets for passwords, one per character.
    const shownOf = struct {
        fn f(s: []const u8, password: bool, buf: []const u8) []const u8 {
            if (!password) return s;
            const count = std.unicode.utf8CountCodepoints(s) catch s.len;
            return buf[0..@min(count * 3, buf.len)];
        }
    }.f;
    const shownIndex = struct {
        fn f(s: []const u8, password: bool, i_: usize) usize {
            if (!password) return i_;
            return (std.unicode.utf8CountCodepoints(s[0..i_]) catch i_) * 3;
        }
    }.f;

    if (it.right_clicked) c.text_menu = true;
    if (it.focused) {
        const prev_caret = e.caret;
        const was_focused = e.had_focus;
        if (it.rect) |r| {
            const local_x = c.input.mouse.x - r.x - pad_x + e.scroll_x;
            const local_y = c.input.mouse.y - r.y - pad_y + e.scroll_y;
            if (multi and ((c.input.pressed and c.input.button == .left and !c.input.ctrl and it.hovered) or (e.selecting and c.input.down))) {
                const at = lines_mod.indexAtPoint(c, buffer.text(), style, lines_mod.layout(c, buffer.text(), style, wrap_w), c.input.mouse.x - r.x - pad_x, local_y, lh_);
                e.caret = at;
                if (c.input.pressed) {
                    if (!c.input.shift) e.anchor = at;
                    if (c.input.click_count >= 2) {
                        e.anchor = prevWord(buffer.text(), at);
                        e.caret = nextWord(buffer.text(), at);
                    }
                    e.marked = null;
                    c.selection.blocked = true;
                    e.selecting = true;
                }
            } else if (c.input.pressed and c.input.button == .left and !c.input.ctrl and it.hovered) {
                const idx = c.text.indexAt(shownOf(buffer.text(), opts.password, bullets), style, local_x);
                const at = if (opts.password) byteOfCodepoint(buffer.text(), idx / 3) else idx;
                textedit.pointerSelect(c, e, buffer.text(), at, false);
            } else if (e.selecting and c.input.down) {
                const idx = c.text.indexAt(shownOf(buffer.text(), opts.password, bullets), style, local_x);
                const at = if (opts.password) byteOfCodepoint(buffer.text(), idx / 3) else idx;
                textedit.pointerDrag(c, e, buffer.text(), at, false);
            }
            if (!c.input.down) e.selecting = false;
        }
        focusSelect(c, e, opts.select_all_on_focus, buffer.text().len);
        e.undo.begin(buffer.text(), e.caret);
        var took: keymap.Took = if (opts.keys != .system) keymap.handle(c, buffer, e, opts, &result) else .{};
        if (!took.key and textedit.handleUndoShortcuts(c, buffer, e, &result)) took.key = true;
        for (c.input.ops) |op_in| {
            if (took.text and op_in == .insert) continue;
            var op = op_in;
            if (multi and op == .command) switch (op.command) {
                // Shift-Return: a new line; ↑ and ↓ between the lines.
                .insert_newline => if (c.input.shift) {
                    op = .{ .command = .insert_line_break };
                },
                .move_up, .move_down, .select_up, .select_down => {
                    const cmd = op.command;
                    const at = lines_mod.vertical(c, buffer.text(), style, lines_mod.layout(c, buffer.text(), style, wrap_w), e.caret, if (cmd == .move_up or cmd == .select_up) -1 else 1);
                    e.caret = at;
                    if (cmd == .move_up or cmd == .move_down) e.anchor = at;
                    e.marked = null;
                    continue;
                },
                else => {},
            };
            if (op == .command and op.command == .cancel) c.focus = 0;
            if (op == .command and op.command == .insert_tab) {
                c.focusCycle(c.input.shift);
                continue;
            }
            // Copy with a selection here is the field's; else the page's.
            if (op == .command and (op.command == .copy or op.command == .cut) and e.caret != e.anchor) c.copy_done = true;
            apply(buffer, e, op, opts, c.clipboard, &result);
        }
        // Without an input method (tests, synthetic input): keys and chars.
        if (c.input.chars.len > 0 and !took.text) apply(buffer, e, .{ .insert = c.input.chars }, opts, c.clipboard, &result);
        if (!took.key) if (c.input.key) |k| switch (k) {
            .backspace => apply(buffer, e, .{ .command = .delete_backward }, opts, c.clipboard, &result),
            .delete => apply(buffer, e, .{ .command = .delete_forward }, opts, c.clipboard, &result),
            .left => apply(buffer, e, .{ .command = if (c.input.shift) .select_left else .move_left }, opts, c.clipboard, &result),
            .right => apply(buffer, e, .{ .command = if (c.input.shift) .select_right else .move_right }, opts, c.clipboard, &result),
            .up, .down => if (multi) {
                e.caret = lines_mod.vertical(c, buffer.text(), style, lines_mod.layout(c, buffer.text(), style, wrap_w), e.caret, if (k == .up) -1 else 1);
                if (!c.input.shift) e.anchor = e.caret;
            } else apply(buffer, e, .{ .command = if (k == .up) .move_line_start else .move_line_end }, opts, c.clipboard, &result),
            .home => apply(buffer, e, .{ .command = .move_line_start }, opts, c.clipboard, &result),
            .end => apply(buffer, e, .{ .command = .move_line_end }, opts, c.clipboard, &result),
            .tab => c.focusCycle(c.input.shift),
            .enter => if (multi and (c.input.shift or c.input.alt)) {
                apply(buffer, e, .{ .command = .insert_line_break }, opts, c.clipboard, &result);
            } else {
                result.submitted = true;
            },
            .escape => c.focus = 0,
            else => {},
        };
        textedit.commitUndo(c, buffer, e, &result, took.text, took.key);
        textedit.updateCaretBlink(c, was_focused, result.changed, e.caret != prev_caret);
        if (result.changed or result.submitted) c.changed = true;
        // Escape gave the focus up during this build.
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
    result.vim_normal = opts.keys == .vim and e.keys.vim_normal;
    result.vim_visual = result.vim_normal and e.keys.vim_visual;
    // A copy for the frame: the app may set the buffer (moving it) before
    // the frame is painted, or the input method asks about it.
    const s = c.alloc().dupe(u8, buffer.text()) catch buffer.text();
    if (multi) {
        const lines = lines_mod.layout(c, s, style, wrap_w);
        const rows: f32 = @floatFromInt(@max(1, @min(lines.len, opts.max_lines)));
        const view_h = rows * lh_;
        c.node(i).style.height = .{ .px = view_h + 2 * pad_y };
        // Past its most lines it scrolls: the wheel's, and a scrollbar.
        c.node(i).style.scroll = lines.len > opts.max_lines;
        const follow = result.changed or e.caret != caret_before[0] or e.anchor != caret_before[1] or s.len != caret_before[2];
        const d = lines_mod.draw(c, s, e, style, lines, view_h, focused, follow, result.vim_normal, opts.placeholder, opts.suggestion);
        c.scroll.put(c.gpa, it.id, e.scroll_y) catch {};
        result.line = d.line;
        result.lines = d.lines;
        if (focused) {
            c.focused_multiline = true;
            const r = it.rect orelse types.Rect{};
            c.focused_text = .{
                .id = it.id,
                .text = s,
                .caret = e.caret,
                .anchor = e.anchor,
                .marked = e.marked,
                .caret_rect = .{ .x = r.x + pad_x + d.caret.x, .y = r.y + pad_y + d.caret.y, .w = 1.5, .h = lh_ },
            };
        }
        return result;
    }
    const shown = shownOf(s, opts.password, bullets);
    const lh = c.text.font(style).lineHeight();
    const caret_x = c.text.caretX(shown, style, shownIndex(s, opts.password, e.caret));
    // Keep the caret in view.
    const view_w = if (it.rect) |r| @max(0, r.w - 2 * pad_x) else 0;
    if (focused and view_w > 0) {
        if (caret_x - e.scroll_x > view_w - 2) e.scroll_x = caret_x - view_w + 2;
        if (caret_x - e.scroll_x < 0) e.scroll_x = caret_x;
    }
    e.scroll_x = @max(0, @min(e.scroll_x, @max(0, c.text.width(shown, style) - view_w + 2)));

    const lo = @min(e.caret, e.anchor);
    const hi = @max(e.caret, e.anchor);
    if (focused and hi > lo) {
        const x0 = c.text.caretX(shown, style, shownIndex(s, opts.password, lo));
        const x1 = c.text.caretX(shown, style, shownIndex(s, opts.password, hi));
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = x1 - x0 }, .height = .{ .px = lh }, .radius = 2, .background = opts.selection_color orelse th.accent.alpha(0.28), .offset = .{ .x = x0 - e.scroll_x } }, .none, null);
    }
    if (s.len == 0) {
        _ = c.leaf(.{ .offset = .{ .x = -e.scroll_x } }, .{ .text = .{ .str = opts.placeholder, .style = style, .color = th.muted } }, null);
    } else {
        _ = c.leaf(.{ .offset = .{ .x = -e.scroll_x } }, .{ .text = .{ .str = shown, .style = style, .color = opts.color orelse th.text } }, null);
        if (opts.suggestion.len > 0 and !opts.password and focused and e.caret == s.len)
            _ = c.leaf(.{ .offset = .{ .x = -e.scroll_x } }, .{ .text = .{ .str = opts.suggestion, .style = style, .color = th.muted.alpha(0.8) } }, null);
    }
    if (focused) if (e.marked) |m| {
        const x0 = c.text.caretX(shown, style, shownIndex(s, opts.password, m[0]));
        const x1 = c.text.caretX(shown, style, shownIndex(s, opts.password, m[1]));
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = x1 - x0 }, .height = .{ .px = 1.5 }, .background = opts.color orelse th.text, .offset = .{ .x = x0 - e.scroll_x, .y = lh - 1 } }, .none, null);
    };
    if (focused and hi == lo and (result.vim_normal or textedit.caretVisible(c))) {
        // Vim's normal mode: a block over the character under the caret.
        const block = result.vim_normal;
        const w: f32 = if (!block) 1.5 else if (e.caret < s.len) @max(4, c.text.caretX(shown, style, shownIndex(s, opts.password, @min(s.len, e.caret + 1))) - caret_x) else c.text.width("m", style);
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = w }, .height = .{ .px = lh }, .background = if (block) th.accent.alpha(0.45) else opts.caret_color orelse th.accent, .offset = .{ .x = caret_x - e.scroll_x } }, .none, null);
    }
    if (focused) {
        c.focused_password = opts.password;
        c.focused_multiline = false;
        const r = it.rect orelse types.Rect{};
        c.focused_text = .{
            .id = it.id,
            .text = s,
            .caret = e.caret,
            .anchor = e.anchor,
            .marked = e.marked,
            .caret_rect = .{ .x = r.x + pad_x + caret_x - e.scroll_x, .y = r.y + (r.h - lh) / 2, .w = 1.5, .h = lh },
        };
    }
    return result;
}

fn byteOfCodepoint(s: []const u8, n: usize) usize {
    var i: usize = 0;
    var k: usize = 0;
    while (i < s.len and k < n) : (k += 1) i += utf8.seqLen(s[i]);
    return @min(i, s.len);
}

pub const rehome = textedit.rehome;
pub const editState = textedit.editState;
pub const focusSelect = textedit.focusSelect;

test "buffer edits" {
    var b: TextBuffer = .{};
    defer b.deinit();
    b.set("hllo");
    _ = b.insert(1, "e");
    try std.testing.expectEqualStrings("hello", b.text());
    b.remove(0, 1);
    try std.testing.expectEqualStrings("ello", b.text());
    _ = b.replace(1, 3, "XYZ");
    try std.testing.expectEqualStrings("eXYZo", b.text());
    b.set("añb");
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(b.text(), 3));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(b.text(), 1));
    try std.testing.expectEqual(@as(usize, 0), prevWord("foo bar", 3));
    try std.testing.expectEqual(@as(usize, 7), nextWord("foo bar", 3));
}

fn noClip(_: ?*anyopaque, _: []const u8) void {}

test "composition, selection, commands" {
    var b: TextBuffer = .{};
    defer b.deinit();
    var e: EditState = .{};
    var r: Result = .{};
    apply(&b, &e, .{ .insert = "hello world" }, .{}, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .command = .select_word_left }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqual(@as(usize, 6), @min(e.caret, e.anchor));
    apply(&b, &e, .{ .insert = "Zig" }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("hello Zig", b.text());
    // An input method composes "日本", then commits it.
    apply(&b, &e, .{ .set_marked = .{ .text = "に", .sel_start = 3, .sel_len = 0 } }, .{}, .{ .write = noClip }, &r);
    try std.testing.expect(e.marked != null);
    apply(&b, &e, .{ .set_marked = .{ .text = "日本", .sel_start = 6, .sel_len = 0 } }, .{}, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .insert = "日本" }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("hello Zig日本", b.text());
    try std.testing.expect(e.marked == null);
    apply(&b, &e, .{ .command = .delete_word_backward }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("hello ", b.text());
    apply(&b, &e, .{ .command = .select_all }, .{}, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .command = .delete_backward }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("", b.text());
}

test "a suggestion is taken with → at the end" {
    var b: TextBuffer = .{};
    defer b.deinit();
    var e: EditState = .{};
    var r: Result = .{};
    const opts: Options = .{ .suggestion = "status" };
    apply(&b, &e, .{ .insert = "git " }, opts, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .command = .move_left }, opts, .{ .write = noClip }, &r);
    // Not at the end: → only moves.
    apply(&b, &e, .{ .command = .move_right }, opts, .{ .write = noClip }, &r);
    try std.testing.expect(!r.accepted);
    try std.testing.expectEqualStrings("git ", b.text());
    apply(&b, &e, .{ .command = .move_right }, opts, .{ .write = noClip }, &r);
    try std.testing.expect(r.accepted);
    try std.testing.expectEqualStrings("git status", b.text());
    try std.testing.expectEqual(@as(usize, 10), e.caret);
}
