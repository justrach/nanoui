//! A text field's undo history (Vim's u and ^R, Emacs's C-_ and C-/):
//! snapshots of the text and caret, the last `depth` of them. A run of
//! typing is one step, as both editors have it (in Vim, one insert
//! session, with the command that began it); text the app sets between
//! events is a step of its own, so undo never loses it silently.
const std = @import("std");

pub const depth = 12;
// ponytail: snapshots hold 1 KiB; longer text keeps no history (heap snaps if it matters).
const capacity = 1024;

const Snap = struct {
    buf: [capacity]u8 = undefined,
    len: u16 = 0,
    caret: u16 = 0,

    pub fn text(s: *const Snap) []const u8 {
        return s.buf[0..s.len];
    }
};

pub const History = struct {
    snaps: [depth]Snap = undefined,
    /// The ring's oldest state, how many there are, and which is current
    /// (counted from the oldest).
    first: usize = 0,
    count: usize = 0,
    at: usize = 0,
    /// The last change was typing: more typing joins it.
    group: bool = false,
    /// Undo or redo ran in this event: nothing to record after it.
    restored: bool = false,

    fn slot(h: *History, i: usize) *Snap {
        return &h.snaps[(h.first + i) % depth];
    }

    fn store(s: *Snap, text: []const u8, caret: usize) void {
        const n = @min(text.len, capacity);
        @memcpy(s.buf[0..n], text[0..n]);
        s.len = @intCast(n);
        s.caret = @intCast(@min(caret, n));
    }

    /// A new state after the current one; what was undone is dropped, and
    /// the oldest when full.
    fn push(h: *History, text: []const u8, caret: usize) void {
        // Too long to keep: no undo, rather than undo to a cut copy.
        if (text.len > capacity) {
            h.count = 0;
            h.at = 0;
            return;
        }
        if (h.count > 0) h.count = h.at + 1;
        if (h.count == depth) {
            h.first = (h.first + 1) % depth;
            h.count -= 1;
        }
        store(h.slot(h.count), text, caret);
        h.at = h.count;
        h.count += 1;
    }

    /// Before an event: the text as it is now is a state (the first, or one
    /// the app set since).
    pub fn begin(h: *History, text: []const u8, caret: usize) void {
        h.restored = false;
        if (h.count == 0 or !std.mem.eql(u8, h.slot(h.at).text(), text)) {
            h.push(text, caret);
            h.group = false;
        }
    }

    /// After an event: records the change, joining a run of typing.
    pub fn commit(h: *History, text: []const u8, caret: usize, changed: bool, typing: bool) void {
        if (h.restored) return;
        if (!changed) {
            if (h.count > 0 and caret != h.slot(h.at).caret) h.group = false;
            return;
        }
        if (h.count == 0 or std.mem.eql(u8, h.slot(h.at).text(), text)) return;
        if (typing and h.group and h.at > 0 and text.len <= capacity) store(h.slot(h.at), text, caret) else h.push(text, caret);
        h.group = typing;
    }

    /// The next typing joins the change just made (Vim's c, s, o: one step).
    pub fn join(h: *History) void {
        h.group = true;
    }

    /// The state before the current one, or null at the oldest.
    pub fn undo(h: *History) ?*const Snap {
        if (h.count == 0 or h.at == 0) return null;
        h.at -= 1;
        h.group = false;
        h.restored = true;
        return h.slot(h.at);
    }

    pub fn redo(h: *History) ?*const Snap {
        if (h.at + 1 >= h.count) return null;
        h.at += 1;
        h.group = false;
        h.restored = true;
        return h.slot(h.at);
    }
};

test "typing is one step; undo and redo walk the states; a new change drops redo" {
    var h: History = .{};
    h.begin("", 0);
    h.commit("a", 1, true, true);
    h.begin("a", 1);
    h.commit("ab", 2, true, true);
    h.begin("ab", 2);
    h.commit("", 0, true, false); // a kill
    try std.testing.expectEqualStrings("ab", h.undo().?.text());
    try std.testing.expectEqualStrings("", h.undo().?.text());
    try std.testing.expect(h.undo() == null);
    try std.testing.expectEqualStrings("ab", h.redo().?.text());
    h.begin("ab", 2);
    h.commit("abc", 3, true, true);
    try std.testing.expect(h.redo() == null);
    // Text the app set is a state of its own.
    h.begin("ls -la", 6);
    try std.testing.expectEqualStrings("abc", h.undo().?.text());
}

test "the oldest states go when it is full" {
    var h: History = .{};
    var buf: [4]u8 = undefined;
    h.begin("", 0);
    for (0..depth + 5) |i| {
        const t = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        h.commit(t, t.len, true, false);
        h.begin(t, t.len);
    }
    var n: usize = 0;
    while (h.undo() != null) n += 1;
    try std.testing.expectEqual(@as(usize, depth - 1), n);
}
