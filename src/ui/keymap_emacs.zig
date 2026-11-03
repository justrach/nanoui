//! Emacs's keys, as Emacs and readline have them:
//!
//!   C-a C-e  line start, end        M-< M->  start, end of the text
//!   C-b C-f  a character            M-b M-f  a word
//!   C-d C-h  delete a character     M-d      kill a word forward
//!   C-k      kill to the line's end (C-k C-k joins them)
//!   C-u      kill to the line's start  C-w  kill the region, else a word back
//!   C-y      yank                    M-y      the kill before (after a yank)
//!   C-SPC    set the mark            C-g      drop it    M-w  copy the region
//!   C-t M-t  transpose characters, words
//!   M-u M-l M-c  upcase, downcase, capitalize a word
//!   C-_ C-/  undo                    M-_      redo
const std = @import("std");
const km = @import("keymap.zig");
const ctx_mod = @import("context.zig");
const tf = @import("textfield.zig");
const Context = ctx_mod.Context;
const EditState = ctx_mod.EditState;

pub fn handle(c: *Context, b: *tf.TextBuffer, e: *EditState, opts: tf.Options, r: *tf.Result) km.Took {
    const k = &e.keys;
    // Typing or anything else that isn't Emacs's: the mark goes, and the
    // next kill starts afresh.
    const sc = c.input.shortcut orelse {
        if (c.input.chars.len > 0 or c.input.ops.len > 0) {
            k.mark = null;
            k.last_kill = false;
            k.yanked = null;
            e.anchor = e.caret;
        }
        return .{};
    };
    if (sc.cmd or !(sc.ctrl != sc.alt)) return .{};
    const joining = k.last_kill;
    const yanked = k.yanked;
    k.last_kill = false;
    k.yanked = null;
    const s = b.text();
    const mark = k.mark;
    if (sc.ctrl) switch (sc.key) {
        'a' => km.moveTo(e, km.lineStart(s, e.caret), mark),
        'e' => km.moveTo(e, km.lineEnd(s, e.caret), mark),
        'b' => km.moveTo(e, prev(s, e.caret), mark),
        'f' => km.moveTo(e, next(s, e.caret), mark),
        'd' => {
            drop(e);
            km.run(c, b, e, opts, r, .delete_forward);
        },
        'h' => {
            drop(e);
            km.run(c, b, e, opts, r, .delete_backward);
        },
        'k' => {
            drop(e);
            const end = km.lineEnd(s, e.caret);
            // At the line's end: the newline.
            km.kill(b, e, e.caret, if (end == e.caret and end < s.len) end + 1 else end, r, joining);
        },
        'u' => {
            drop(e);
            km.kill(b, e, km.lineStart(s, e.caret), e.caret, r, joining);
        },
        'w' => if (mark) |m| {
            drop(e);
            km.kill(b, e, @min(m, e.caret), @max(m, e.caret), r, joining);
        } else km.kill(b, e, km.wordStart(s, e.caret), e.caret, r, joining),
        'y' => {
            drop(e);
            km.put(b, e, e.caret, 0, r);
        },
        't' => transposeChars(b, e, r),
        ' ' => {
            k.mark = e.caret;
            e.anchor = e.caret;
        },
        'g' => drop(e),
        '/', '_' => km.undoStep(b, e, r, false),
        '-' => if (sc.shift) km.undoStep(b, e, r, false) else return .{},
        else => return .{},
    } else switch (sc.key) {
        'b' => km.moveTo(e, km.wordStart(s, e.caret), mark),
        'f' => km.moveTo(e, km.wordEnd(s, e.caret), mark),
        '<' => km.moveTo(e, 0, mark),
        '>' => km.moveTo(e, s.len, mark),
        ',' => if (sc.shift) km.moveTo(e, 0, mark) else return .{},
        '.' => if (sc.shift) km.moveTo(e, s.len, mark) else return .{},
        'd' => {
            drop(e);
            km.kill(b, e, e.caret, km.wordEnd(s, e.caret), r, joining);
        },
        'w' => if (mark) |m| {
            km.keep(e, s[@min(m, e.caret)..@max(m, e.caret)], false, false);
            k.last_kill = false;
            drop(e);
        },
        'y' => if (yanked) |y| {
            // The kill before the one just yanked, in its place.
            const i: u8 = @intCast((k.yank_at + 1) % @max(k.ring_count, 1));
            b.remove(y[0], y[1]);
            km.put(b, e, y[0], i, r);
        },
        'u', 'l', 'c' => caseWord(b, e, r, @intCast(sc.key)),
        't' => transposeWords(b, e, r),
        '_' => km.undoStep(b, e, r, true),
        '-' => if (sc.shift) km.undoStep(b, e, r, true) else return .{},
        else => return .{},
    }
    km.take(c);
    return .{ .key = true };
}

/// The mark gone, the selection with it.
fn drop(e: *EditState) void {
    e.keys.mark = null;
    e.anchor = e.caret;
}

fn prev(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and (s[j] & 0xc0) == 0x80) j -= 1;
    return j;
}

fn next(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i + 1;
    while (j < s.len and (s[j] & 0xc0) == 0x80) j += 1;
    return j;
}

/// C-t: the characters before and at the caret swapped, the caret past
/// them; at the line's end, the two before it.
fn transposeChars(b: *tf.TextBuffer, e: *EditState, r: *tf.Result) void {
    drop(e);
    const s = b.text();
    if (s.len < 2 or e.caret == 0) return;
    const at = if (e.caret >= s.len or s[e.caret] == '\n') e.caret - 1 else e.caret;
    if (at == 0) return;
    const pair = [2]u8{ s[at], s[at - 1] };
    km.replace(b, e, at - 1, at + 1, &pair, at + 1, r);
}

/// M-t: the word before the caret and the one after swapped.
fn transposeWords(b: *tf.TextBuffer, e: *EditState, r: *tf.Result) void {
    drop(e);
    const s = b.text();
    const w2_end = km.wordEnd(s, e.caret);
    const w2_start = km.wordStart(s, w2_end);
    const w1_start = km.wordStart(s, w2_start);
    const w1_end = km.wordEnd(s, w1_start);
    if (w2_start == w2_end or w1_start == w1_end or w1_end > w2_start) return;
    var buf: [1024]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ s[w2_start..w2_end], s[w1_end..w2_start], s[w1_start..w1_end] }) catch return;
    km.replace(b, e, w1_start, w2_end, out, w2_end, r);
}

/// M-u M-l M-c on the word at or after the caret, the caret after it.
fn caseWord(b: *tf.TextBuffer, e: *EditState, r: *tf.Result, how: u8) void {
    drop(e);
    const s = b.text();
    const end = km.wordEnd(s, e.caret);
    var first = true;
    for (b.buf.items[e.caret..end]) |*ch| {
        if (!km.word(ch.*)) continue;
        ch.* = switch (how) {
            'u' => std.ascii.toUpper(ch.*),
            'l' => std.ascii.toLower(ch.*),
            else => if (first) std.ascii.toUpper(ch.*) else std.ascii.toLower(ch.*),
        };
        first = false;
    }
    km.moveTo(e, end, null);
    r.changed = true;
}
