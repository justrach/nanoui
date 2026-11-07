//! The keys a text field reads itself, where no input method sends the
//! editing commands and neither the keys nor the typed text have passed
//! through text editing: a window on Linux or Windows, and tests. The Mac
//! gets these from AppKit (`textinput.zig`, `textfield.zig`'s commands), so
//! they have to mean the same: Control (Option, as on the Mac) with ←, →,
//! Delete and Backspace works a word at a time, and Shift extends the
//! selection.
const types = @import("types.zig");
const tf = @import("textfield.zig");
const ctx_mod = @import("context.zig");
const lines_mod = @import("textfield_lines.zig");

const Context = ctx_mod.Context;

/// The command a key with its modifiers means: Control or Option works a
/// word at a time (←, →, Delete, Backspace), Shift extends the selection.
/// Null for the keys the field reads itself (↑ ↓ Home End Tab Return
/// Escape).
pub fn commandOf(k: ctx_mod.Key, shift: bool, word: bool) ?ctx_mod.Command {
    return switch (k) {
        .backspace => if (word) .delete_word_backward else .delete_backward,
        .delete => if (word) .delete_word_forward else .delete_forward,
        .left => if (word) (if (shift) .select_word_left else .move_word_left) else (if (shift) .select_left else .move_left),
        .right => if (word) (if (shift) .select_word_right else .move_word_right) else (if (shift) .select_right else .move_right),
        else => null,
    };
}

/// The field, and what this event already gave it.
pub const Field = struct {
    buffer: *tf.TextBuffer,
    edit: *ctx_mod.EditState,
    opts: tf.Options,
    result: *tf.Result,
    /// A multiline field: ↑ and ↓ move between its lines.
    multi: bool,
    style: types.TextStyle,
    wrap_w: f32,
    /// The keymap (Emacs, Vim) took this event's text or key already.
    text_taken: bool = false,
    key_taken: bool = false,
};

/// Applies the event's typed text and key to the field.
pub fn handle(c: *Context, f: Field) void {
    const e = f.edit;
    if (c.input.chars.len > 0 and !f.text_taken) tf.apply(f.buffer, e, .{ .insert = c.input.chars }, f.opts, c.clipboard, f.result);
    if (f.key_taken) return;
    const k = c.input.key orelse return;
    if (commandOf(k, c.input.shift, c.input.ctrl or c.input.alt)) |cmd| {
        tf.apply(f.buffer, e, .{ .command = cmd }, f.opts, c.clipboard, f.result);
        return;
    }
    switch (k) {
        .up, .down => if (f.multi) {
            e.caret = lines_mod.vertical(c, f.buffer.text(), f.style, lines_mod.layout(c, f.buffer.text(), f.style, f.wrap_w), e.caret, if (k == .up) -1 else 1);
            if (!c.input.shift) e.anchor = e.caret;
        } else tf.apply(f.buffer, e, .{ .command = if (k == .up) .move_line_start else .move_line_end }, f.opts, c.clipboard, f.result),
        .home => tf.apply(f.buffer, e, .{ .command = .move_line_start }, f.opts, c.clipboard, f.result),
        .end => tf.apply(f.buffer, e, .{ .command = .move_line_end }, f.opts, c.clipboard, f.result),
        .tab => c.focusCycle(c.input.shift),
        .enter => if (f.multi and (c.input.shift or c.input.alt)) {
            tf.apply(f.buffer, e, .{ .command = .insert_line_break }, f.opts, c.clipboard, f.result);
        } else {
            f.result.submitted = true;
        },
        .escape => c.focus = 0,
        else => {},
    }
}
