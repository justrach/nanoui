//! Text on macOS: breaking a paragraph at shaped glyph positions, as GPUI
//! does (`TextSystem.wrap_rule = .glyph_positions`).
const std = @import("std");
const cf = @import("cf.zig");
const types = @import("types.zig");
const utf8 = @import("utf8.zig");
const text_mac = @import("text_mac.zig");
const rich = text_mac.rich;
const TextSystem = text_mac.TextSystem;
const Line = text_mac.Line;

/// `s` broken as GPUI breaks it, each newline-delimited paragraph alone.
pub fn breakAtGlyphs(self: *TextSystem, s: []const u8, style: types.TextStyle, spans: []const types.Span, max_width: f32) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(self.gpa);
    var a: usize = 0;
    while (true) {
        const b = std.mem.indexOfScalarPos(u8, s, a, '\n') orelse s.len;
        try breakParagraph(self, &lines, s, a, b, style, spans, max_width);
        if (b >= s.len) break;
        a = b + 1;
    }
    return lines.toOwnedSlice(self.gpa);
}

fn breakParagraph(self: *TextSystem, lines: *std.ArrayList(Line), s: []const u8, a: usize, b: usize, style: types.TextStyle, spans: []const types.Span, max_width: f32) !void {
    const seg = std.mem.trimEnd(u8, s[a..b], "\r");
    if (seg.len == 0) return lines.append(self.gpa, .{ .start = a, .end = a, .width = 0 });
    const attr = if (rich.styled(spans)) rich.attributed(self, seg, style, spans, a) else cf.attributed(seg, self.font(style).ref);
    defer cf.CFRelease(attr);
    const ln = cf.CTLineCreateWithAttributedString(attr).?;
    defer cf.CFRelease(ln);
    // Each character's start and x, then the paragraph's end. Decode
    // defensively: a streaming chunk can end inside a UTF-8 sequence.
    var marks: std.ArrayList(struct { at: usize, x: f32, c: u21 }) = .empty;
    defer marks.deinit(self.gpa);
    var at: usize = 0;
    while (at < seg.len) {
        const n = @min(utf8.seqLen(seg[at]), seg.len - at);
        const c = std.unicode.utf8Decode(seg[at .. at + n]) catch 0xfffd;
        const x: f32 = @floatCast(cf.CTLineGetOffsetForStringIndex(ln, cf.utf16Offset(seg, at), null));
        try marks.append(self.gpa, .{ .at = at, .x = x + @as(f32, @floatFromInt(marks.items.len)) * style.tracking, .c = c });
        at += n;
    }
    const total = @as(f32, @floatCast(cf.CTLineGetTypographicBounds(ln, null, null, null))) + @as(f32, @floatFromInt(marks.items.len)) * style.tracking;
    var first_non_ws = false;
    var candidate: ?usize = null;
    var line_start: usize = 0;
    var prev: u21 = 0;
    const items = marks.items;
    for (items, 0..) |m, i| {
        if (isWordChar(m.c)) {
            if (prev == ' ' and first_non_ws) candidate = i;
        } else if (m.c != ' ' and !isWordChar(prev) and first_non_ws) candidate = i;
        if (m.c != ' ') first_non_ws = true;
        const x_end = if (i + 1 < items.len) items[i + 1].x else total;
        if (x_end - items[line_start].x > @max(1, max_width) and i > line_start) {
            const cut = if (candidate) |cnd| (if (cnd > line_start) cnd else i) else i;
            candidate = null;
            try appendLine(self, lines, seg, a, items, line_start, cut, total);
            line_start = cut;
        }
        prev = m.c;
    }
    try appendLine(self, lines, seg, a, items, line_start, items.len, total);
}

/// Characters `from` to `to`, without trailing spaces or tabs.
fn appendLine(self: *TextSystem, lines: *std.ArrayList(Line), seg: []const u8, a: usize, items: anytype, from: usize, to: usize, total: f32) !void {
    var end = to;
    while (end > from and (items[end - 1].c == ' ' or items[end - 1].c == '\t')) end -= 1;
    const end_b = if (end < items.len) items[end].at else seg.len;
    const x_end = if (end < items.len) items[end].x else total;
    try lines.append(self.gpa, .{ .start = a + items[from].at, .end = a + end_b, .width = x_end - items[from].x });
}

/// A character GPUI's `LineWrapper::is_word_char` holds in a word.
pub fn isWordChar(c: u21) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        0xC0...0xFF, 0x100...0x17F, 0x180...0x24F, 0x400...0x4FF, 0x1E00...0x1EFF, 0x300...0x36F, 0x980...0x9FF => true,
        '-', '_', '.', '\'', 0x2019, 0x2018, '$', '%', '@', '#', '^', '~', ',', '=', ':', ';' => true,
        0x22EF, 0x202F, 0xA0, 0x2011 => true,
        else => false,
    };
}
