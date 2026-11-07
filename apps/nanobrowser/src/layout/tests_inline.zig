//! Inline formatting: line breaking, whitespace, alignment, inline boxes and
//! atoms, worked out by hand with 8px characters and 16px lines.
const std = @import("std");
const u = @import("tests_util.zig");
const box = @import("box.zig");
const T = u.T;
const px = u.px;
const pct = u.pct;
const css = @import("../css/style.zig");

const eq = u.eqText;

test "greedy breaking at spaces, trailing space hanging" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(80) });
    const tx = try t.text(p, "aaaa bbbb cccc");
    try t.run(800, 600);
    const b = t.boxOf(p);
    try std.testing.expectEqual(@as(usize, 2), b.runs.len);
    try eq("aaaa bbbb", b.runs[0].text);
    try eq("cccc", b.runs[1].text);
    try u.close(0, b.runs[0].x, "x");
    try u.close(72, b.runs[0].w, "w");
    try u.close(12.8, b.runs[0].baseline, "first baseline");
    try u.close(28.8, b.runs[1].baseline, "second baseline");
    try u.close(16, b.runs[1].line_top, "line top");
    try u.close(16, b.runs[1].line_h, "line height");
    try u.close(32, b.h, "two lines");
    try std.testing.expect(b.runs[0].node == tx);
    try std.testing.expectEqual(@as(?u32, 0), b.runs[0].start);
    try std.testing.expectEqual(@as(?u32, 10), b.runs[1].start);
}

test "exact fit stays on the line" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(72) });
    _ = try t.text(p, "aaaa bbbb cc");
    try t.run(800, 600);
    const b = t.boxOf(p);
    try eq("aaaa bbbb", b.runs[0].text);
    try eq("cc", b.runs[1].text);
}

test "a word too long overflows on its own line" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(40) });
    _ = try t.text(p, "aa bbbbbbbbbbbb cc");
    try t.run(800, 600);
    const b = t.boxOf(p);
    try eq("aa", b.runs[0].text);
    try eq("bbbbbbbbbbbb", b.runs[1].text);
    try eq("cc", b.runs[2].text);
    try u.close(48, b.h, "three lines");
}

test "breaks after hyphens and around CJK characters" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(48) });
    _ = try t.text(p, "well-known");
    const q = try t.div(t.body, .{ .width = px(48) });
    // Three bytes each: 24 wide at the test measurer's rate. Two a line.
    _ = try t.text(q, "\u{4E00}\u{4E8C}\u{4E09}");
    try t.run(800, 600);
    try eq("well-", t.boxOf(p).runs[0].text);
    try eq("known", t.boxOf(p).runs[1].text);
    try eq("\u{4E00}\u{4E8C}", t.boxOf(q).runs[0].text);
    try eq("\u{4E09}", t.boxOf(q).runs[1].text);
}

test "whitespace collapses across inline boundaries" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "  aa  ");
    const s = try t.span(p, .{});
    _ = try t.text(s, "  bb\n\t cc ");
    _ = try t.text(p, " dd  ");
    try t.run(800, 600);
    const bp = t.boxOf(p);
    const bs = t.boxOf(s);
    // Runs break where the characters are no longer a plain slice of the text.
    try eq("aa", bp.runs[0].text);
    try u.close(0, bp.runs[0].x, "aa at the start, leading space gone");
    try eq("bb", bs.runs[0].text);
    try u.close(24, bs.runs[0].x, "after aa and one space");
    try eq("cc ", bs.runs[1].text);
    try u.close(48, bs.runs[1].x, "after bb and one space");
    try eq("dd", bp.runs[1].text);
    try u.close(72, bp.runs[1].x, "the space after cc, no other");
    try std.testing.expectEqual(@as(?u32, 7), bs.runs[1].start);
}

test "white-space modes" {
    var t = try T.init();
    defer t.deinit();
    const pre = try t.div(t.body, .{ .white_space = .pre, .width = px(16) });
    _ = try t.text(pre, "a  b\nc");
    const nowrap = try t.div(t.body, .{ .white_space = .nowrap, .width = px(16) });
    _ = try t.text(nowrap, "aaa   bbb");
    const pl = try t.div(t.body, .{ .white_space = .pre_line });
    _ = try t.text(pl, "a   b\nc");
    const pw = try t.div(t.body, .{ .white_space = .pre_wrap, .width = px(40) });
    _ = try t.text(pw, "aa  bbbb");
    try t.run(800, 600);
    try eq("a  b", t.boxOf(pre).runs[0].text);
    try eq("c", t.boxOf(pre).runs[1].text);
    try u.close(32, t.boxOf(pre).h, "the newline is kept");
    try u.close(16, t.boxOf(nowrap).h, "one line");
    try u.close(32, t.boxOf(nowrap).runs[1].x, "aaa, one space, then bbb");
    try u.close(32, t.boxOf(pl).h, "pre-line keeps the newline only");
    try eq("aa", t.boxOf(pw).runs[0].text);
    try eq("bbbb", t.boxOf(pw).runs[1].text);
}

test "tabs go to the next stop" {
    var t = try T.init();
    defer t.deinit();
    const pre = try t.div(t.body, .{ .white_space = .pre, .tab_size = 4 });
    _ = try t.text(pre, "a\tb");
    try t.run(800, 600);
    const b = t.boxOf(pre);
    try eq("a", b.runs[0].text);
    try eq("b", b.runs[1].text);
    try u.close(32, b.runs[1].x, "4 characters of 8");
}

test "line-break: anywhere breaks a long word, and doesn't wait for one that fits a line" {
    var t = try T.init();
    defer t.deinit();
    const a = try t.div(t.body, .{ .line_break_anywhere = true, .width = px(40) });
    _ = try t.text(a, "xx aaaaaaaaaaaa");
    try t.run(800, 600);
    const ra = t.boxOf(a).runs;
    try eq("xx aa", ra[0].text);
    try eq("aaaaa", ra[1].text);
    try eq("aaaaa", ra[2].text);
}

test "long words break when asked" {
    var t = try T.init();
    defer t.deinit();
    const a = try t.div(t.body, .{ .overflow_wrap_anywhere = true, .width = px(40) });
    _ = try t.text(a, "aaaaaaaaaaaa");
    const b = try t.div(t.body, .{ .word_break_all = true, .width = px(40) });
    _ = try t.text(b, "xx yyyyyyyy");
    try t.run(800, 600);
    const ra = t.boxOf(a).runs;
    try eq("aaaaa", ra[0].text);
    try eq("aaaaa", ra[1].text);
    try eq("aa", ra[2].text);
    try std.testing.expectEqual(@as(?u32, 5), ra[1].start);
    const rb = t.boxOf(b).runs;
    try eq("xx yy", rb[0].text);
    try eq("yyyyy", rb[1].text);
    try eq("y", rb[2].text);
}

test "text-align table" {
    const Case = struct { a: css.TextAlign, rtl: bool = false, x: f32 };
    for ([_]Case{
        .{ .a = .start, .x = 0 },
        .{ .a = .left, .x = 0 },
        .{ .a = .end, .x = 160 - 16 },
        .{ .a = .right, .x = 144 },
        .{ .a = .center, .x = 72 },
        .{ .a = .start, .rtl = true, .x = 144 },
        .{ .a = .end, .rtl = true, .x = 0 },
    }) |k| {
        var t = try T.init();
        defer t.deinit();
        const p = try t.div(t.body, .{ .width = px(160), .text_align = k.a, .rtl = k.rtl });
        _ = try t.text(p, "aa");
        try t.run(800, 600);
        try u.close(k.x, t.boxOf(p).runs[0].x, "x");
    }
}

test "justify spreads spaces, and not on the last line" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(80), .text_align = .justify });
    _ = try t.text(p, "aa bb cc dd");
    try t.run(800, 600);
    const r = t.boxOf(p).runs;
    // "aa bb cc" is 64: 16 over two spaces.
    try eq("aa bb cc", r[0].text);
    try u.close(8, r[0].word_spacing, "word spacing");
    try u.close(80, r[0].w, "fills the line");
    try u.close(0, r[1].word_spacing, "last line");
}

test "text-indent, letter and word spacing, transform" {
    var t = try T.init();
    defer t.deinit();
    const a = try t.div(t.body, .{ .text_indent = px(20), .width = px(80) });
    _ = try t.text(a, "aaaaaaaa bb");
    const b = try t.div(t.body, .{ .letter_spacing = 2 });
    _ = try t.text(b, "aa");
    const c = try t.div(t.body, .{ .word_spacing = 3 });
    _ = try t.text(c, "a b");
    const d = try t.div(t.body, .{ .text_transform = .uppercase });
    _ = try t.text(d, "aA");
    const e = try t.div(t.body, .{ .text_transform = .capitalize });
    _ = try t.text(e, "hello world");
    try t.run(800, 600);
    try u.close(20, t.boxOf(a).runs[0].x, "indent, first line");
    try u.close(0, t.boxOf(a).runs[1].x, "not the second");
    try u.close(20, t.boxOf(b).runs[0].w, "16 + 2 letters of 2");
    try u.close(2, t.boxOf(b).runs[0].spacing, "for paint");
    try u.close(27, t.boxOf(c).runs[0].w, "24 + 3");
    try u.close(3, t.boxOf(c).runs[0].word_spacing, "for paint");
    try eq("AA", t.boxOf(d).runs[0].text);
    try std.testing.expect(t.boxOf(d).runs[0].start == null);
    try eq("Hello World", t.boxOf(e).runs[0].text);
}

test "inline boxes: padding, borders, margins, a fragment for each line" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(80) });
    _ = try t.text(p, "aa ");
    const s = try t.span(p, .{ .padding_left = px(4), .padding_right = px(6), .margin_left = px(2), .margin_right = px(3), .padding_top = px(1), .border_top = .{ .width = 1, .style = .solid } });
    _ = try t.text(s, "bbbb cccc");
    _ = try t.text(p, " dd");
    try t.run(800, 600);
    const b = t.boxOf(s);
    try std.testing.expectEqual(@as(usize, 2), b.frags.len);
    // aa + space = 24; margin 2; border box at 26; padding 4, text at 30.
    try u.close(26, b.frags[0].x, "first fragment");
    try eq("bbbb", b.runs[0].text);
    try u.close(30, b.runs[0].x, "text after its left padding");
    // On to the line's right edge: the word is 32 wide, ends at 62.
    try u.close(36, b.frags[0].w, "4 + 32");
    // Fragment's top: baseline 12.8 - ascent 12.8 - padding 1 - border 1.
    try u.close(-2, b.frags[0].y, "over the line's top");
    try u.close(18, b.frags[0].h, "content + 2");
    // Second line: no left edges, the right ones.
    try u.close(0, b.frags[1].x, "line start");
    try u.close(38, b.frags[1].w, "32 + 6");
    try u.close(0, b.runs[1].x, "no left padding");
    const bp = t.boxOf(p);
    // cccc 32, padding 6, margin 3: its space and dd at 41.
    try eq(" dd", bp.runs[1].text);
    try u.close(41, bp.runs[1].x, "the space and dd");
    // The union.
    try u.close(0, b.x, "union x");
    try u.close(62, b.w, "union w");
}

test "line height, half-leading, baselines" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .line_height = 30 });
    _ = try t.text(p, "aa");
    try t.run(800, 600);
    const b = t.boxOf(p);
    try u.close(30, b.h, "the line");
    // (30-16)/2 = 7 above the content area; baseline at 7 + 12.8.
    try u.close(19.8, b.runs[0].baseline, "baseline");
}

test "vertical-align table for an inline box of half the font" {
    // Parent 16px: A 12.8, D 3.2. Child 8px: ascent 6.4, descent 1.6, height 8.
    const Case = struct { v: css.VerticalAlign, raise: f32, h: f32 };
    for ([_]Case{
        .{ .v = .baseline, .raise = 0, .h = 16 },
        // A fifth of the parent's size and a pixel down: 4.2; 1.6 + 4.2 = 5.8 is under 3.2.
        .{ .v = .sub, .raise = -4.2, .h = 12.8 + 5.8 },
        // A third of it and a pixel up: 6.33; 6.4 + 6.33 = 12.73, under 12.8.
        .{ .v = .super, .raise = 16.0 / 3.0 + 1, .h = 16 },
        // Its top at the parent's: raise = 12.8 - 6.4.
        .{ .v = .text_top, .raise = 6.4, .h = 16 },
        // Its bottom at the parent's: raise = -3.2 + 1.6.
        .{ .v = .text_bottom, .raise = -1.6, .h = 16 },
        // Middle at half an x-height (0.25em = 4) up; (6.4-1.6)/2 = 2.4 off that.
        .{ .v = .middle, .raise = 1.6, .h = 16 },
    }) |k| {
        var t = try T.init();
        defer t.deinit();
        const p = try t.div(t.body, .{});
        _ = try t.text(p, "aa");
        const s = try t.span(p, .{ .font_size = 8, .vertical_align = k.v });
        _ = try t.text(s, "bb");
        try t.run(800, 600);
        const base = t.boxOf(p).runs[0].baseline;
        try u.close(k.raise, base - t.boxOf(s).runs[0].baseline, "raise");
        try u.close(k.h, t.boxOf(p).h, "line");
    }
}

test "vertical-align top and bottom against the line" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "aa");
    const top = try t.el(p, "b", .{ .display = .inline_block, .width = px(10), .height = px(40), .vertical_align = .top });
    const bot = try t.el(p, "b", .{ .display = .inline_block, .width = px(10), .height = px(5), .vertical_align = .bottom });
    try t.run(800, 600);
    try u.close(40, t.boxOf(p).h, "as tall as the tallest aligned");
    try u.close(0, t.boxOf(top).y, "top");
    try u.close(35, t.boxOf(bot).y, "bottom");
}

test "inline-block sits on the baseline by its last line" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "aa");
    const ib = try t.el(p, "b", .{ .display = .inline_block, .width = px(16), .padding_top = px(10) });
    _ = try t.text(ib, "bb cc");
    try t.run(800, 600);
    const b = t.boxOf(ib);
    // Width 16: two lines. Its last baseline: 10 + 16 + 12.8.
    try u.close(26, b.h + 0 - 16, "10 + 16");
    try u.close(42, b.h, "10 + 32");
    const base = t.boxOf(p).runs[0].baseline;
    try u.close(base - 38.8, b.y, "its last baseline meets the line's");
    try u.close(0, b.y, "and the line starts at its top");
    try u.close(16, b.x, "after aa");
}

test "inline-block without lines sits on its margin edge" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "aa");
    const ib = try t.el(p, "b", .{ .display = .inline_block, .width = px(10), .height = px(30), .margin_bottom = px(5) });
    try t.run(800, 600);
    // Baseline: 35 down the margin box, above 12.8: 35 up + 3.2 down.
    try u.close(38.2, t.boxOf(p).h, "line");
    try u.close(0, t.boxOf(ib).y, "top");
    try u.close(35, t.boxOf(p).runs[0].baseline, "baseline at its margin bottom");
}

test "br breaks, and an empty line has a height" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "a");
    _ = try t.el(p, "br", .{});
    _ = try t.el(p, "br", .{});
    _ = try t.text(p, "b");
    try t.run(800, 600);
    const b = t.boxOf(p);
    try u.close(48, b.h, "a, nothing, b");
    try u.close(44.8, b.runs[1].baseline, "b's baseline");
}

test "wbr offers a break" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(32) });
    _ = try t.text(p, "aaaa");
    _ = try t.el(p, "wbr", .{});
    _ = try t.text(p, "bbbb");
    try t.run(800, 600);
    const b = t.boxOf(p);
    try eq("aaaa", b.runs[0].text);
    try eq("bbbb", b.runs[1].text);
    try u.close(16, b.runs[1].line_top, "next line");
}

test "ellipsis cuts the last run" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(48), .white_space = .nowrap, .overflow_x = .hidden, .overflow_y = .hidden, .text_overflow_ellipsis = true });
    _ = try t.text(p, "aaaaaaaaaaaaaaaaaa");
    try t.run(800, 600);
    const r = t.boxOf(p).runs;
    // "…" is 3 bytes here: 24 wide. 24 left for 3 characters.
    try eq("aaa\u{2026}", r[0].text);
    try std.testing.expect(r[0].start == null);
}

test "a whitespace-only block has no lines and collapses through" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .margin_top = px(10), .margin_bottom = px(10) });
    _ = try t.text(p, "   \n  ");
    const q = try t.div(t.body, .{ .height = px(5) });
    try t.run(800, 600);
    try u.close(0, t.boxOf(p).h, "no line");
    try u.close(10, t.boxOf(q).y, "margins through");
}

test "quirks mode: a picture alone in a line sets its height" {
    var t = try T.init();
    defer t.deinit();
    t.doc.quirks = true;
    const p = try t.div(t.body, .{});
    const img = try t.el(p, "img", .{ .width = px(14), .height = px(1) });
    const q = try t.div(t.body, .{});
    _ = try t.text(q, "aa");
    try t.run(800, 600);
    try t.rect(img, 0, 0, 14, 1);
    try u.close(1, t.boxOf(p).h, "no strut");
    try u.close(16, t.boxOf(q).h, "text has its line");
}

test "standards mode: the strut holds the line open under a picture" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.el(p, "img", .{ .width = px(14), .height = px(1) });
    try t.run(800, 600);
    try u.close(16, t.boxOf(p).h, "the strut");
}
