//! UTF-8 helpers every platform shares.

/// The length of the UTF-8 sequence starting with `b` (1 for a stray byte).
pub fn seqLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b >> 5 == 0b110) return 2;
    if (b >> 4 == 0b1110) return 3;
    if (b >> 3 == 0b11110) return 4;
    return 1;
}

/// Letter spacing (`TextStyle.tracking`): each glyph of `s` (anything with
/// `x` and a byte `index`) moved right by `t` for every character before
/// it; the width that adds.
// ponytail: counts from the start per glyph (O(n²)); tracked text is a short label.
pub fn track(glyphs: anytype, s: []const u8, t: f32) f32 {
    for (glyphs) |*g| g.x += t * @as(f32, @floatFromInt(chars(s[0..@min(g.index, s.len)])));
    return t * @as(f32, @floatFromInt(chars(s)));
}

fn chars(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i += seqLen(s[i]);
    return n;
}
