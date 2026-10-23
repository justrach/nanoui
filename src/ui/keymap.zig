//! Emacs's and Vim's keys for a text field (`textField`'s `keys`), for
//! those whose fingers know them: `keymap_emacs.zig` and `keymap_vim.zig`.
//! What they share is here: the kill ring (Emacs's, and Vim's unnamed
//! register), undo, and words, lines and text objects.
const std = @import("std");
const ctx_mod = @import("context.zig");
const tf = @import("textfield.zig");
const Context = ctx_mod.Context;
const EditState = ctx_mod.EditState;
const Command = @import("input.zig").Command;

pub const Keymap = enum { system, emacs, vim };

/// What the keymap used of this event: its text (not to be typed) and its
/// key (not to be handled as usual).
pub const Took = struct { text: bool = false, key: bool = false };

pub fn handle(c: *Context, b: *tf.TextBuffer, e: *EditState, opts: tf.Options, r: *tf.Result) Took {
    return switch (opts.keys) {
        .system => .{},
        .emacs => @import("keymap_emacs.zig").handle(c, b, e, opts, r),
        .vim => @import("keymap_vim.zig").handle(c, b, e, opts, r),
    };
}

pub fn run(c: *Context, b: *tf.TextBuffer, e: *EditState, opts: tf.Options, r: *tf.Result, cmd: Command) void {
    tf.apply(b, e, .{ .command = cmd }, opts, c.clipboard, r);
}

/// Takes the event's key combination, so neither the app nor the field
/// handles it again.
pub fn take(c: *Context) void {
    c.shortcut_taken = true;
    c.input.shortcut = null;
    c.changed = true;
}

/// The caret to `at`, the selection gone (or kept from `anchor`).
pub fn moveTo(e: *EditState, at: usize, anchor: ?usize) void {
    e.caret = at;
    e.anchor = anchor orelse at;
}

// The kill ring.

fn ringPush(k: *@import("input.zig").KeyState, s: []const u8) void {
    var i: usize = k.ring.len - 1;
    while (i > 0) : (i -= 1) {
        k.ring[i] = k.ring[i - 1];
        k.ring_len[i] = k.ring_len[i - 1];
    }
    const n = @min(s.len, k.ring[0].len);
    @memcpy(k.ring[0][0..n], s[0..n]);
    k.ring_len[0] = @intCast(n);
    k.ring_count = @min(k.ring_count + 1, k.ring.len);
}

/// Keeps `s` for putting back; joined to the last kill when `join` (the
/// command before was a kill too: C-k C-k), before it when `back` (C-w C-w).
pub fn keep(e: *EditState, s: []const u8, join: bool, back: bool) void {
    const k = &e.keys;
    if (join and k.ring_count > 0) {
        var buf: [256]u8 = undefined;
        const old = k.ring[0][0..k.ring_len[0]];
        const both = if (back)
            std.fmt.bufPrint(&buf, "{s}{s}", .{ s, old }) catch return
        else
            std.fmt.bufPrint(&buf, "{s}{s}", .{ old, s }) catch return;
        @memcpy(k.ring[0][0..both.len], both);
        k.ring_len[0] = @intCast(both.len);
    } else ringPush(k, s);
    k.last_kill = true;
}

/// Removes [from, to), keeping it to put back.
pub fn kill(b: *tf.TextBuffer, e: *EditState, from: usize, to: usize, r: *tf.Result, join: bool) void {
    if (to <= from) return;
    keep(e, b.text()[from..to], join, to <= e.caret and from < e.caret);
    b.remove(from, to);
    moveTo(e, from, null);
    r.changed = true;
}

/// Puts back ring entry `i` at `at`, the caret after it.
pub fn put(b: *tf.TextBuffer, e: *EditState, at: usize, i: u8, r: *tf.Result) void {
    const k = &e.keys;
    if (i >= k.ring_count) return;
    const n = b.insert(at, k.ring[i][0..k.ring_len[i]]);
    moveTo(e, at + n, null);
    k.yanked = .{ at, at + n };
    k.yank_at = i;
    r.changed = true;
}

/// Replaces [from, to) with `s`, the caret at `caret` (clamped).
pub fn replace(b: *tf.TextBuffer, e: *EditState, from: usize, to: usize, s: []const u8, caret: usize, r: *tf.Result) void {
    _ = b.replace(from, to, s);
    moveTo(e, @min(caret, b.text().len), null);
    r.changed = true;
}

/// Undo or redo: the text and caret as they were.
pub fn undoStep(b: *tf.TextBuffer, e: *EditState, r: *tf.Result, redo: bool) void {
    const snap = (if (redo) e.undo.redo() else e.undo.undo()) orelse return;
    _ = b.replace(0, b.text().len, snap.text());
    moveTo(e, @min(snap.caret, b.text().len), null);
    r.changed = true;
}

// Words and lines.

pub fn word(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

pub fn blank(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n';
}

/// Which kind of character: blank, word, other (Vim's word classes); one
/// class for everything but blanks with `big` (WORD).
fn class(ch: u8, big: bool) u2 {
    if (blank(ch)) return 0;
    if (big or word(ch)) return 1;
    return 2;
}

/// Where the word before `i` starts (Emacs's M-b, readline's ^W).
pub fn wordStart(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and !word(s[j - 1])) j -= 1;
    while (j > 0 and word(s[j - 1])) j -= 1;
    return j;
}

/// Where the word at or after `i` ends (Emacs's M-f, M-d).
pub fn wordEnd(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and !word(s[j])) j += 1;
    while (j < s.len and word(s[j])) j += 1;
    return j;
}

/// Vim's w: past this word (a run of one class), then past the blanks.
pub fn nextStart(s: []const u8, i: usize, big: bool) usize {
    var j = i;
    if (j < s.len and !blank(s[j])) {
        const k = class(s[j], big);
        while (j < s.len and class(s[j], big) == k) j += 1;
    }
    while (j < s.len and blank(s[j])) j += 1;
    return j;
}

/// Vim's e: the last character of this word or the next.
pub fn endOf(s: []const u8, i: usize, big: bool) usize {
    if (s.len == 0) return 0;
    var j = @min(i + 1, s.len - 1);
    while (j < s.len - 1 and blank(s[j])) j += 1;
    const k = class(s[j], big);
    while (j + 1 < s.len and class(s[j + 1], big) == k) j += 1;
    return j;
}

/// Vim's b: the start of this word or the one before.
pub fn prevStart(s: []const u8, i: usize, big: bool) usize {
    var j = i;
    while (j > 0 and blank(s[j - 1])) j -= 1;
    if (j == 0) return 0;
    const k = class(s[j - 1], big);
    while (j > 0 and class(s[j - 1], big) == k) j -= 1;
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

/// Vim's ^: the line's first character that isn't blank.
pub fn firstNonBlank(s: []const u8, i: usize) usize {
    var j = lineStart(s, i);
    const end = lineEnd(s, i);
    while (j < end and (s[j] == ' ' or s[j] == '\t')) j += 1;
    return j;
}

/// A text object at `i` (Vim's iw aw i" a" i( a( …): its range, or null.
pub fn object(s: []const u8, i: usize, inner: bool, kind: u8) ?[2]usize {
    if (s.len == 0) return null;
    const at = @min(i, s.len - 1);
    switch (kind) {
        'w', 'W' => {
            const big = kind == 'W';
            const k = class(s[at], big);
            var from = at;
            var to = at + 1;
            while (from > 0 and class(s[from - 1], big) == k) from -= 1;
            while (to < s.len and class(s[to], big) == k) to += 1;
            if (!inner) {
                // With the blanks after it, or before it at the end.
                const t0 = to;
                while (to < s.len and blank(s[to])) to += 1;
                if (to == t0) while (from > 0 and blank(s[from - 1])) {
                    from -= 1;
                };
            }
            return .{ from, to };
        },
        '"', '\'', '`' => {
            // The pair of quotes around the caret (or the next pair on its line).
            const ls = lineStart(s, at);
            const le = lineEnd(s, at);
            var open: ?usize = null;
            var j = ls;
            while (j < le) : (j += 1) if (s[j] == kind) {
                if (open) |o| {
                    if (at <= j) return if (inner) .{ o + 1, j } else .{ o, j + 1 };
                    open = null;
                } else open = j;
            };
            return null;
        },
        '(', ')', 'b', '[', ']', '{', '}', 'B', '<', '>' => {
            const pair: [2]u8 = switch (kind) {
                '(', ')', 'b' => .{ '(', ')' },
                '[', ']' => .{ '[', ']' },
                '<', '>' => .{ '<', '>' },
                else => .{ '{', '}' },
            };
            var depth_: usize = 0;
            var o: usize = at + 1;
            const open = while (o > 0) {
                o -= 1;
                if (s[o] == pair[1] and o != at) depth_ += 1;
                if (s[o] == pair[0]) {
                    if (depth_ == 0) break o;
                    depth_ -= 1;
                }
            } else return null;
            depth_ = 0;
            var cl = open + 1;
            while (cl < s.len) : (cl += 1) {
                if (s[cl] == pair[0]) depth_ += 1;
                if (s[cl] == pair[1]) {
                    if (depth_ == 0) return if (inner) .{ open + 1, cl } else .{ open, cl + 1 };
                    depth_ -= 1;
                }
            }
            return null;
        },
        else => return null,
    }
}

test "words, WORDs and text objects" {
    const s = "git commit -m \"fix (the) bug\"";
    try std.testing.expectEqual(@as(usize, 4), nextStart(s, 0, false));
    try std.testing.expectEqual(@as(usize, 11), nextStart(s, 4, false));
    try std.testing.expectEqual(@as(usize, 9), endOf(s, 4, false));
    try std.testing.expectEqual(@as(usize, 4), prevStart(s, 9, false));
    try std.testing.expectEqual([2]usize{ 15, 28 }, object(s, 20, true, '"').?);
    try std.testing.expectEqual([2]usize{ 20, 23 }, object(s, 21, true, '(').?);
    try std.testing.expectEqual([2]usize{ 19, 24 }, object(s, 21, false, 'b').?);
    try std.testing.expectEqual([2]usize{ 4, 11 }, object(s, 6, false, 'w').?);
    try std.testing.expectEqual(@as(usize, 11), nextStart(s, 4, true));
}
