//! Shared text-editing helpers for `textField` and `textArea`: word and
//! line selection by click count and drag granularity, `.system` undo/redo
//! shortcuts, and caret blink timing.
const std = @import("std");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const EditState = ctx_mod.EditState;
const tf = @import("textfield.zig");
const keymap = @import("keymap.zig");

pub const Granularity = enum { char, word, line };
pub const UndoOp = enum { none, undo, redo };

pub fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

pub fn prevWord(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and !isWordByte(s[j - 1])) j -= 1;
    while (j > 0 and isWordByte(s[j - 1])) j -= 1;
    return j;
}

pub fn nextWord(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and !isWordByte(s[j])) j += 1;
    while (j < s.len and isWordByte(s[j])) j += 1;
    return j;
}

pub fn lineStart(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j > 0 and s[j - 1] != '\n') j -= 1;
    return j;
}

pub fn lineEnd(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j < s.len and s[j] != '\n') j += 1;
    return j;
}

pub fn pointerSelect(c: *Context, e: *EditState, s: []const u8, at: usize, multiline: bool) void {
    e.undo.group = false;
    c.caret_moved_at = c.time;
    if (c.input.click_count >= 3) {
        c.select_granularity = .line;
        const lo: usize = if (multiline) lineStart(s, at) else 0;
        const hi: usize = if (multiline) lineEnd(s, at) else s.len;
        e.anchor = lo;
        e.caret = hi;
        c.select_origin = .{ lo, hi };
    } else if (c.input.click_count == 2) {
        c.select_granularity = .word;
        const lo = prevWord(s, at);
        const hi = nextWord(s, at);
        e.anchor = lo;
        e.caret = hi;
        c.select_origin = .{ lo, hi };
    } else {
        c.select_granularity = .char;
        e.caret = at;
        if (!c.input.shift) e.anchor = at;
        c.select_origin = .{ e.anchor, e.anchor };
    }
    e.marked = null;
    c.selection.blocked = true;
    e.selecting = true;
}

pub fn pointerDrag(c: *Context, e: *EditState, s: []const u8, at: usize, multiline: bool) void {
    const orig0 = @min(c.select_origin[0], s.len);
    const orig1 = @min(c.select_origin[1], s.len);
    switch (c.select_granularity) {
        .char => e.caret = at,
        .word => if (at >= orig0) {
            e.anchor = orig0;
            e.caret = @max(orig1, nextWord(s, at));
        } else {
            e.anchor = orig1;
            e.caret = prevWord(s, at);
        },
        .line => if (!multiline) {
            e.anchor = 0;
            e.caret = s.len;
        } else if (at >= orig0) {
            e.anchor = orig0;
            e.caret = @max(orig1, lineEnd(s, at));
        } else {
            e.anchor = orig1;
            e.caret = lineStart(s, at);
        },
    }
    c.caret_moved_at = c.time;
}

pub fn handleUndoShortcuts(c: *Context, b: *tf.TextBuffer, e: *EditState, r: *tf.Result) bool {
    if (c.undo_op != .none) {
        const redo = c.undo_op == .redo;
        c.undo_op = .none;
        keymap.undoStep(b, e, r, redo);
        c.changed = true;
        return true;
    }
    if (c.shortcut(.{ .key = 'z', .cmd = true, .shift = true }) or c.shortcut(.{ .key = 'y', .cmd = true })) {
        keymap.undoStep(b, e, r, true);
        return true;
    }
    if (c.shortcut(.{ .key = 'z', .cmd = true })) {
        keymap.undoStep(b, e, r, false);
        return true;
    }
    return false;
}

pub fn commitUndo(c: *Context, b: *tf.TextBuffer, e: *EditState, r: *const tf.Result, took_text: bool, took_key: bool) void {
    if (c.paste_op) e.undo.group = false;
    var typing = !c.paste_op and !took_text and !took_key and c.input.key == null and (c.input.chars.len > 0 or c.input.ops.len > 0);
    // An input method's composition is typing too: each update of the
    // marked text joins the run, so undo after 日本 does not bring back
    // the kana it was composed from (NSTextView: one step).
    for (c.input.ops) |op| typing = typing and (op == .insert or op == .set_marked or op == .unmark);
    e.undo.commit(b.text(), e.caret, r.changed, typing);
}

pub fn updateCaretBlink(c: *Context, was_focused: bool, changed: bool, moved: bool) void {
    if (!was_focused or changed or moved or c.input.pressed) c.caret_moved_at = c.time;
}

pub fn caretShown(c: *Context, e: *EditState, focused: bool, edited: bool, solid: bool) bool {
    const f = e.blink.step(c.time, focused and c.input.window_active and c.window_focused, e.caret != e.anchor, solid or e.marked != null, edited);
    if (f.next) |wait| c.frameIn(wait);
    return f.visible;
}

pub fn caretVisible(c: *Context) bool {
    const e = c.edits.getPtr(c.focus) orelse return false;
    return caretShown(c, e, true, c.caret_moved_at == c.time, false);
}

pub fn rehome(c: *Context, buffer: *tf.TextBuffer, id: u64) void {
    if (buffer.last_id != 0 and buffer.last_id != id and c.focus == buffer.last_id) {
        c.focus = id;
        if (c.edits.fetchRemove(buffer.last_id)) |kv| c.edits.put(c.gpa, id, kv.value) catch {};
    }
    buffer.last_id = id;
}

pub fn editState(c: *Context, id: u64, buffer: *tf.TextBuffer) ?*EditState {
    const len = buffer.text().len;
    const entry = c.edits.getOrPut(c.gpa, id) catch return null;
    if (!entry.found_existing) entry.value_ptr.* = .{ .caret = len, .anchor = len };
    const e = entry.value_ptr;
    if (c.focus != id or !c.input.window_active or !c.window_focused or e.caret != e.anchor) e.blink = .{};
    if (buffer.want_caret) |at| {
        e.caret = at;
        e.anchor = at;
        e.marked = null;
        buffer.want_caret = null;
    }
    if (buffer.want_selection) |sel| {
        e.anchor = sel[0];
        e.caret = sel[1];
        e.marked = null;
        buffer.want_selection = null;
    }
    e.caret = @min(e.caret, len);
    e.anchor = @min(e.anchor, len);
    return e;
}

pub fn focusSelect(c: *Context, e: *EditState, on_focus: bool, len: usize) void {
    if ((on_focus and !e.had_focus) or c.focus_select_all) {
        e.anchor = 0;
        e.caret = len;
        e.selecting = false;
        c.focus_select_all = false;
    }
    e.had_focus = true;
}
