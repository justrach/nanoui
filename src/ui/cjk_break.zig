//! Line breaks in ideographic text: any two CJK characters may part, but a
//! closing mark never begins a line and an opening mark never ends one, the
//! basic rule of Chinese and Japanese line breaking (kinsoku).
const std = @import("std");

/// The code point of one UTF-8 sequence; U+FFFD for a malformed one.
/// `utf8Decode` asserts that the lead byte matches the length, so a stray
/// continuation byte or a cut-off sequence is caught before it.
pub fn codepoint(s: []const u8) u21 {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0xFFFD;
    if (n != s.len) return 0xFFFD;
    return std.unicode.utf8Decode(s) catch 0xFFFD;
}

/// Whether a line may end between `before` and `after`.
pub fn between(before: u21, after: u21) bool {
    if (!wide(before) and !wide(after)) return false;
    return !closing(after) and !opening(before);
}

fn wide(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F, // Hangul Jamo
        0x2E80...0x303E, // radicals, CJK symbols and punctuation
        0x3040...0x33FF, // kana, Bopomofo, compatibility
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xA960...0xA97F,
        0xAC00...0xD7A3,
        0xF900...0xFAFF,
        0xFE30...0xFE4F, // vertical and compatibility forms
        0xFF00...0xFFEF, // full- and half-width forms
        0x20000...0x3FFFD,
        => true,
        else => false,
    };
}

/// Marks that never begin a line: closing brackets and quotes, sentence
/// punctuation, small kana, the prolonged sound mark and iteration marks.
const closing_marks = ")]}.,:;!?%’”‥…、。々〉》」』】〕〗〙〛〞〟ぁぃぅぇぉっゃゅょゎゝゞァィゥェォッャュョヮヵヶ・ーヽヾ！％），．：；？］｝｡｣､";
/// Marks that never end a line: opening brackets and quotes.
const opening_marks = "([{‘“〈《「『【〔〖〘〚〝（［｛｢";

fn closing(cp: u21) bool {
    return listed(closing_marks, cp);
}

fn opening(cp: u21) bool {
    return listed(opening_marks, cp);
}

fn listed(marks: []const u8, cp: u21) bool {
    var it = std.unicode.Utf8View.initUnchecked(marks).iterator();
    while (it.nextCodepoint()) |m| if (m == cp) return true;
    return false;
}

test "ideographs part anywhere but around their punctuation" {
    try std.testing.expect(between(codepoint("中"), codepoint("文")));
    try std.testing.expect(between('t', codepoint("或")));
    try std.testing.expect(between(codepoint("。"), codepoint("中")));
    try std.testing.expect(!between(codepoint("面"), codepoint("。")));
    try std.testing.expect(!between(codepoint("的"), codepoint("，")));
    try std.testing.expect(!between(codepoint("「"), codepoint("名")));
    try std.testing.expect(!between(codepoint("器"), ')'));
    try std.testing.expect(!between('a', 'b'));
    try std.testing.expect(!between(codepoint("ト"), codepoint("ー")));
    try std.testing.expect(!between(codepoint("ち"), codepoint("ゃ")));
}

test "malformed sequences decode as U+FFFD" {
    for ([_][]const u8{ "\x80", "\xbf\x80", "\xe2\x86", "\xc3\x28", "\xff" }) |s| try std.testing.expectEqual(@as(u21, 0xFFFD), codepoint(s));
    try std.testing.expectEqual(@as(u21, 0x4E2D), codepoint("中"));
}
