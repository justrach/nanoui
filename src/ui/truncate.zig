//! One line of text cut to fit its box (`TextStyle.truncate`, or
//! `truncate_middle`): measured at its whole width but flexible, so a row
//! shrinks it; once arranged narrower, its string is the longest prefix
//! that fits, then "…" — or a head and a tail around "…".
const std = @import("std");
const types = @import("types.zig");
const Context = @import("context.zig").Context;

pub const ellipsis = "…";

/// Cuts text box `index` to `w` points (its padding included) if it is wider.
pub fn fit(c: *Context, index: u32, w: f32) void {
    const n = c.node(index);
    const t = &n.content.text;
    const room = w - n.style.padding.horizontal();
    if (c.text.width(t.str, t.style) <= room + 0.5) return;
    t.str = if (t.style.truncate_middle) cutMiddle(c, t.str, t.style, room) else cut(c, t.str, t.style, room);
}

/// The longest prefix of `s` no wider than `avail`, as a byte length.
fn prefix(c: *Context, s: []const u8, style: types.TextStyle, avail: f32) usize {
    var i: usize = if (avail <= 0) 0 else c.text.indexAt(s, style, avail);
    // The nearest caret may be past the room: step back a character at a time.
    while (i > 0 and c.text.width(s[0..i], style) > avail) {
        i -= 1;
        while (i > 0 and s[i] & 0xC0 == 0x80) i -= 1;
    }
    return i;
}

/// The longest prefix of `s` that fits `room` with "…" after it, in the frame's memory.
pub fn cut(c: *Context, s: []const u8, style: types.TextStyle, room: f32) []const u8 {
    const i = prefix(c, s, style, room - c.text.width(ellipsis, style));
    const out = c.alloc().alloc(u8, i + ellipsis.len) catch return s;
    @memcpy(out[0..i], s[0..i]);
    @memcpy(out[i..], ellipsis);
    return out;
}

/// Half the room's head of `s`, "…", and the longest tail that fits the rest.
pub fn cutMiddle(c: *Context, s: []const u8, style: types.TextStyle, room: f32) []const u8 {
    const avail = room - c.text.width(ellipsis, style);
    const head = prefix(c, s, style, avail / 2);
    const left = avail - c.text.width(s[0..head], style);
    // The tail starts as late as it must: forward a character while too wide.
    var tail = head;
    while (tail < s.len and c.text.width(s[tail..], style) > left) {
        tail += 1;
        while (tail < s.len and s[tail] & 0xC0 == 0x80) tail += 1;
    }
    const a = c.alloc();
    const out = a.alloc(u8, head + ellipsis.len + (s.len - tail)) catch return s;
    @memcpy(out[0..head], s[0..head]);
    @memcpy(out[head..][0..ellipsis.len], ellipsis);
    @memcpy(out[head + ellipsis.len ..], s[tail..]);
    return out;
}

/// Wrapped text box `index` cut to `TextStyle.max_lines` (its lines are
/// already, by `measure`): if text was dropped, its last line ends in "…",
/// cut to fit `w` points (its padding included).
pub fn fitLines(c: *Context, index: u32, w: f32) void {
    const n = c.node(index);
    const t = &n.content.text;
    if (!t.style.wrap or t.lines.len == 0) return;
    const last = t.lines[t.lines.len - 1];
    if (std.mem.trim(u8, t.str[last.end..], " \t\r\n").len == 0) return;
    const tail = cut(c, t.str[last.start..last.end], t.style, w - n.style.padding.horizontal());
    const a = c.alloc();
    const str = a.alloc(u8, last.start + tail.len) catch return;
    const lines = a.dupe(@TypeOf(last), t.lines) catch return;
    @memcpy(str[0..last.start], t.str[0..last.start]);
    @memcpy(str[last.start..], tail);
    lines[lines.len - 1] = .{ .start = last.start, .end = str.len, .width = c.text.width(tail, t.style) };
    t.str = str;
    t.lines = lines;
}
