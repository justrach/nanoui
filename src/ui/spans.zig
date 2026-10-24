//! What spans of rich text share on every platform: which change the
//! font, the style of a span's text, and a hash of the spans' fonts.
const std = @import("std");
const types = @import("types.zig");

/// Inline code beside proportional text: the monospaced font looks
/// larger at the same size.
pub const mono_scale = 0.9;

pub fn styled(spans: []const types.Span) bool {
    for (spans) |s| if (s.styled()) return true;
    return false;
}

/// The style of a span's text in a paragraph of `base`.
pub fn spanStyle(base: types.TextStyle, s: types.Span) types.TextStyle {
    var st = base;
    if (s.weight) |w| st.weight = w;
    if (s.italic) st.italic = true;
    if (s.mono and !base.mono) {
        st.mono = true;
        st.size = base.size * base.mono_scale;
    }
    return st;
}

/// A hash of the spans' fonts over bytes [start, end), relative to start.
pub fn spansHash(spans: []const types.Span, start: usize, end: usize) u64 {
    var h = std.hash.Wyhash.init(0x5eed);
    for (spans) |s| {
        if (!s.styled() or s.end <= start or s.start >= end) continue;
        const a: u32 = @intCast(@max(s.start, start) - start);
        const b: u32 = @intCast(@min(s.end, end) - start);
        h.update(std.mem.asBytes(&a));
        h.update(std.mem.asBytes(&b));
        h.update(&.{ if (s.weight) |w| @as(u8, @backingInt(w)) + 1 else 0, @intFromBool(s.italic), @intFromBool(s.mono) });
    }
    return h.final();
}
