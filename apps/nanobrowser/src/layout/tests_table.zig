//! Tables: anonymous parts, column widths, spans, heights, old attributes, and
//! a page shaped like Hacker News's.
const std = @import("std");
const u = @import("tests_util.zig");
const T = u.T;
const px = u.px;
const pct = u.pct;
const css = @import("../css/style.zig");
const Style = css.Style;
const Node = u.Node;

const table_s: Style = .{ .display = .table, .border_spacing = 0, .border_spacing_y = 0 };
const cell_s: Style = .{ .display = .table_cell };
const row_s: Style = .{ .display = .table_row };
const group_s: Style = .{ .display = .table_row_group };

fn table(t: *T, parent: *Node, s: Style) !*Node {
    return t.el(parent, "table", s);
}

fn tr(t: *T, parent: *Node) !*Node {
    return t.el(parent, "tr", row_s);
}

fn td(t: *T, parent: *Node, s: Style) !*Node {
    var st = s;
    st.display = .table_cell;
    return t.el(parent, "td", st);
}

test "auto width shrinks to its columns' max-content" {
    var t = try T.init();
    defer t.deinit();
    const b = try table(&t, t.body, table_s);
    const r = try tr(&t, b);
    const c1 = try td(&t, r, .{});
    _ = try t.text(c1, "aaaa");
    const c2 = try td(&t, r, .{});
    _ = try t.text(c2, "bbbbbbbb");
    try t.run(800, 600);
    try t.rect(b, 0, 0, 96, 16);
    try t.rect(c1, 0, 0, 32, 16);
    try t.rect(c2, 32, 0, 64, 16);
}

test "a narrower container squeezes columns to min-content, by what they can give" {
    var t = try T.init();
    defer t.deinit();
    const holder = try t.div(t.body, .{ .width = px(100) });
    const b = try table(&t, holder, table_s);
    const r = try tr(&t, b);
    const c1 = try td(&t, r, .{});
    _ = try t.text(c1, "aaaa aaaa aaaa"); // Max 112, min 32.
    const c2 = try td(&t, r, .{});
    _ = try t.text(c2, "bbbb"); // 32 both.
    try t.run(800, 600);
    try u.close(100, t.boxOf(b).w, "fills the container");
    try u.close(68, t.boxOf(c1).w, "the rest after the fixed word");
    try u.close(32, t.boxOf(c2).w, "can't give");
    try u.close(48, t.boxOf(c1).h, "three lines: two words would take 72");
}

test "width: extra goes to auto columns by their max widths" {
    var t = try T.init();
    defer t.deinit();
    var s = table_s;
    s.width = px(300);
    const b = try table(&t, t.body, s);
    const r = try tr(&t, b);
    const c1 = try td(&t, r, .{});
    _ = try t.text(c1, "aaaaa"); // 40
    const c2 = try td(&t, r, .{});
    _ = try t.text(c2, "aaaaaaaaaaaaaaa"); // 120
    try t.run(800, 600);
    // 140 spare, 1:3: 40 + 35 = 75; 120 + 105 = 225.
    try u.close(75, t.boxOf(c1).w, "first");
    try u.close(225, t.boxOf(c2).w, "second");
}

test "percent and fixed cells" {
    var t = try T.init();
    defer t.deinit();
    var s = table_s;
    s.width = px(400);
    const b = try table(&t, t.body, s);
    const r = try tr(&t, b);
    const c1 = try td(&t, r, .{ .width = pct(50) });
    const c2 = try td(&t, r, .{ .width = px(50) });
    const c3 = try td(&t, r, .{});
    _ = try t.text(c3, "aa");
    try t.run(800, 600);
    // 200, 50, and the auto column takes what's left.
    try u.close(200, t.boxOf(c1).w, "percent");
    try u.close(50, t.boxOf(c2).w, "fixed");
    try u.close(150, t.boxOf(c3).w, "auto");
}

test "a percent column makes an auto table ask for more" {
    var t = try T.init();
    defer t.deinit();
    const b = try table(&t, t.body, table_s);
    const r = try tr(&t, b);
    const c1 = try td(&t, r, .{ .width = pct(50) });
    _ = try t.text(c1, "aaaaaaaaaaaa"); // 96 is 50%: 192 in all.
    const c2 = try td(&t, r, .{});
    _ = try t.text(c2, "bb");
    try t.run(800, 600);
    try u.close(192, t.boxOf(b).w, "table");
    try u.close(96, t.boxOf(c1).w, "percent column");
    try u.close(96, t.boxOf(c2).w, "the rest");
}

test "colspan widens over the columns under it" {
    var t = try T.init();
    defer t.deinit();
    const b = try table(&t, t.body, table_s);
    const r1 = try tr(&t, b);
    const wide = try td(&t, r1, .{});
    try wide.setAttr("colspan", "2");
    _ = try t.text(wide, "aaaaaaaaaaaaaaaaaaaaaaaa"); // 192.
    const r2 = try tr(&t, b);
    const c1 = try td(&t, r2, .{});
    _ = try t.text(c1, "aaaa"); // 32
    const c2 = try td(&t, r2, .{});
    _ = try t.text(c2, "aaaaaaaaaaaa"); // 96
    try t.run(800, 600);
    // 64 over 128: shared by the widths they asked for: +16, +48.
    try t.rect(wide, 0, 0, 192, 16);
    try u.close(48, t.boxOf(c1).w, "first");
    try u.close(144, t.boxOf(c2).w, "second");
    try u.close(16, t.boxOf(r2).y, "second row");
}

test "rowspan occupies slots, and short rows share what it needs" {
    var t = try T.init();
    defer t.deinit();
    const b = try table(&t, t.body, table_s);
    const r1 = try tr(&t, b);
    const tall = try td(&t, r1, .{ .width = px(10), .height = px(100) });
    try tall.setAttr("rowspan", "2");
    const a = try td(&t, r1, .{ .width = px(20) });
    _ = try t.text(a, "a");
    const r2 = try tr(&t, b);
    const c = try td(&t, r2, .{ .width = px(20) });
    _ = try t.text(c, "a");
    try t.run(800, 600);
    try u.close(100, t.boxOf(tall).h, "two rows");
    // Rows of 16 and 16, 68 over: 34 each: 50, 50.
    try u.close(10, t.boxOf(c).x, "the second row's cell is in the second column");
    try u.close(50, t.boxOf(c).y, "second row");
    try u.close(50, t.boxOf(a).h, "cells fill the row");
}

test "border-spacing, and cell padding" {
    var t = try T.init();
    defer t.deinit();
    var s = table_s;
    s.border_spacing = 4;
    s.border_spacing_y = 6;
    const b = try table(&t, t.body, s);
    const r = try tr(&t, b);
    const c1 = try td(&t, r, .{ .padding_left = px(2), .padding_top = px(1) });
    _ = try t.text(c1, "aa");
    const c2 = try td(&t, r, .{});
    _ = try t.text(c2, "bb");
    try t.run(800, 600);
    try t.rect(b, 0, 0, 4 + 18 + 4 + 16 + 4, 6 + 17 + 6);
    try t.rect(c1, 4, 6, 18, 17);
    try t.rect(c2, 26, 6, 16, 17);
    try u.close(2 + 4, t.boxOf(c1).runs[0].x, "text inside its padding");
}

test "thead goes first and tfoot last, whatever their source order" {
    var t = try T.init();
    defer t.deinit();
    const b = try table(&t, t.body, table_s);
    const foot = try t.el(b, "tfoot", .{ .display = .table_footer_group });
    const fr_ = try tr(&t, foot);
    const fc = try td(&t, fr_, .{ .height = px(10) });
    const body = try t.el(b, "tbody", group_s);
    const br = try tr(&t, body);
    const bc = try td(&t, br, .{ .height = px(20) });
    const head = try t.el(b, "thead", .{ .display = .table_header_group });
    const hr = try tr(&t, head);
    const hc = try td(&t, hr, .{ .height = px(30) });
    try t.run(800, 600);
    try u.close(0, t.boxOf(hc).y, "head");
    try u.close(30, t.boxOf(bc).y, "body");
    try u.close(50, t.boxOf(fc).y, "foot");
    try u.close(60, t.boxOf(b).h, "all");
}

test "caption top and bottom" {
    var t = try T.init();
    defer t.deinit();
    var s = table_s;
    s.width = px(100);
    const b = try table(&t, t.body, s);
    const cap = try t.el(b, "caption", .{ .display = .table_caption });
    _ = try t.text(cap, "aa");
    const below = try t.el(b, "caption", .{ .display = .table_caption, .caption_bottom = true });
    _ = try t.text(below, "aa");
    const r = try tr(&t, b);
    const c = try td(&t, r, .{ .height = px(10) });
    try t.run(800, 600);
    try t.rect(cap, 0, 0, 100, 16);
    try t.rect(c, 0, 16, 100, 10);
    try t.rect(below, 0, 26, 100, 16);
    try u.close(42, t.boxOf(b).h, "with captions");
}

test "cell vertical-align" {
    const V = struct { v: css.VerticalAlign, base: f32 };
    for ([_]V{
        .{ .v = .top, .base = 12.8 },
        .{ .v = .middle, .base = 42 + 12.8 },
        .{ .v = .bottom, .base = 84 + 12.8 },
    }) |k| {
        var t = try T.init();
        defer t.deinit();
        const b = try table(&t, t.body, table_s);
        const r = try tr(&t, b);
        const tall = try td(&t, r, .{ .height = px(100) });
        const c = try td(&t, r, .{ .vertical_align = k.v });
        _ = try t.text(c, "aa");
        _ = tall;
        try t.run(800, 600);
        try u.close(k.base, t.boxOf(c).runs[0].baseline, "baseline");
        try u.close(100, t.boxOf(c).h, "the cell fills the row");
    }
}

test "cell baselines line up across a row" {
    var t = try T.init();
    defer t.deinit();
    const b = try table(&t, t.body, table_s);
    const r = try tr(&t, b);
    const c1 = try td(&t, r, .{ .font_size = 32 });
    _ = try t.text(c1, "a");
    const c2 = try td(&t, r, .{});
    _ = try t.text(c2, "b");
    try t.run(800, 600);
    try u.close(25.6, t.boxOf(c1).runs[0].baseline, "large");
    try u.close(25.6, t.boxOf(c2).runs[0].baseline, "small comes down to it");
}

test "fixed table layout goes by the first row and col" {
    var t = try T.init();
    defer t.deinit();
    var s = table_s;
    s.table_fixed = true;
    s.width = px(300);
    const b = try table(&t, t.body, s);
    _ = try t.el(b, "col", .{ .display = .table_column, .width = px(40) });
    const r1 = try tr(&t, b);
    const a = try td(&t, r1, .{ .width = px(200) });
    const c = try td(&t, r1, .{ .width = px(60) });
    const d = try td(&t, r1, .{});
    const r2 = try tr(&t, b);
    const e = try td(&t, r2, .{});
    _ = try t.text(e, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try t.run(800, 600);
    // Col 40 beats the cell; 60; the rest 200.
    try u.close(40, t.boxOf(a).w, "by col");
    try u.close(60, t.boxOf(c).w, "by first row");
    try u.close(200, t.boxOf(d).w, "what is left");
    try u.close(40, t.boxOf(e).w, "content doesn't widen");
}

test "col widths in auto layout" {
    var t = try T.init();
    defer t.deinit();
    const b = try table(&t, t.body, table_s);
    const col = try t.el(b, "col", .{ .display = .table_column });
    try col.setAttr("width", "50");
    const r = try tr(&t, b);
    const a = try td(&t, r, .{});
    try t.run(800, 600);
    try u.close(50, t.boxOf(a).w, "from col");
}

test "border-collapse: no spacing, and each line's border shared by half" {
    var t = try T.init();
    defer t.deinit();
    var s = table_s;
    s.border_collapse = true;
    s.border_spacing = 5;
    s.border_spacing_y = 5;
    const b = try table(&t, t.body, s);
    const r = try tr(&t, b);
    const border: css.Border = .{ .width = 2, .style = .solid };
    const cs: Style = .{ .display = .table_cell, .border_left = border, .border_right = border, .border_top = border, .border_bottom = border, .border_collapse = true, .width = px(50), .height = px(10) };
    const a = try td(&t, r, cs);
    const c = try td(&t, r, cs);
    try t.run(800, 600);
    // Width 50 and half of each 2px line: 52. The table has half its outer line.
    const ba = t.boxOf(a);
    const bc = t.boxOf(c);
    try u.close(52, ba.w, "a's border box");
    try u.close(ba.x + 52, bc.x, "the next cell up against it");
    try u.close(1, ba.x - t.boxOf(b).x, "half of the outer line outside it");
}

test "anonymous parts: cells without rows, rows without tables, text in a table" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    const c1 = try t.div(p, .{ .display = .table_cell, .width = px(30) });
    _ = try t.text(p, "   ");
    const c2 = try t.div(p, .{ .display = .table_cell, .width = px(40) });
    const after = try t.div(p, .{ .height = px(5) });
    const rw = try t.div(t.body, .{ .display = .table_row });
    const c3 = try t.div(rw, .{ .display = .table_cell, .width = px(10), .height = px(10) });
    const tb = try table(&t, t.body, table_s);
    _ = try t.text(tb, "aa");
    try t.run(800, 600);
    try u.close(0, t.boxOf(c1).x, "first in an anonymous table");
    try u.close(30, t.boxOf(c2).x, "beside it: whitespace doesn't break the row");
    try u.close(5, t.boxOf(after).h, "a block after it");
    try u.close(10, t.boxOf(c3).w, "row in an anonymous table");
    try u.close(16, t.boxOf(tb).w, "text in an anonymous cell");
}

test "table margins center it, percent width, definite height spreads" {
    var t = try T.init();
    defer t.deinit();
    var s = table_s;
    s.width = pct(50);
    s.height = px(100);
    s.margin_left = .auto;
    s.margin_right = .auto;
    const b = try table(&t, t.body, s);
    const r1 = try tr(&t, b);
    const a = try td(&t, r1, .{ .height = px(10) });
    const r2 = try tr(&t, b);
    const c = try td(&t, r2, .{ .height = px(30) });
    try t.run(800, 600);
    try t.rect(b, 200, 0, 400, 100);
    // Rows 10 and 30 stretch to 100 keeping their share.
    try u.close(25, t.boxOf(a).h, "first");
    try u.close(25, t.boxOf(c).y, "second's top");
    try u.close(75, t.boxOf(c).h, "second");
}

test "old attributes: width, height, cellpadding, cellspacing, border, align, valign" {
    var t = try T.init();
    defer t.deinit();
    const b = try t.el(t.body, "table", .{ .display = .table, .border_spacing = 2, .border_spacing_y = 2 });
    try b.setAttr("width", "200");
    try b.setAttr("cellpadding", "3");
    try b.setAttr("cellspacing", "1");
    const r = try tr(&t, b);
    try r.setAttr("height", "40");
    const a = try t.el(r, "td", .{ .display = .table_cell, .padding_top = px(1), .padding_right = px(1), .padding_bottom = px(1), .padding_left = px(1), .vertical_align = .middle });
    try a.setAttr("width", "50%");
    try a.setAttr("valign", "top");
    try a.setAttr("align", "right");
    _ = try t.text(a, "aa");
    const c = try t.el(r, "td", .{ .display = .table_cell });
    _ = try t.text(c, "bb");
    try t.run(800, 600);
    try u.close(200, t.boxOf(b).w, "width attribute");
    // Spacing 1 around: 197 for the columns; 50% of that.
    try u.close(1, t.boxOf(a).x, "cellspacing");
    try u.close(98.5, t.boxOf(a).w, "percent attribute");
    try u.close(40, t.boxOf(a).h, "row's height");
    const run = t.boxOf(a).runs[0];
    try u.close(1 + 3 + 12.8, run.baseline, "valign top, with cellpadding");
    try u.close(1 + 98.5 - 3 - 16, run.x, "align right");
}

test "a page shaped like Hacker News: center, nested tables, spacers, quirks" {
    var t = try T.init();
    defer t.deinit();
    t.doc.quirks = true;
    const center = try t.el(t.body, "center", .{ .display = .block, .text_align = .center });
    const main = try t.el(center, "table", .{ .display = .table, .border_spacing = 0, .border_spacing_y = 0 });
    try main.setAttr("width", "85%");
    const tb = try t.el(main, "tbody", group_s);
    const head = try tr(&t, tb);
    const hc = try td(&t, head, .{});
    const inner = try t.el(hc, "table", .{ .display = .table, .border_spacing = 0, .border_spacing_y = 0, .width = pct(100) });
    const ibody = try t.el(inner, "tbody", group_s);
    const ir = try tr(&t, ibody);
    const logo = try td(&t, ir, .{ .width = px(18), .padding_right = px(4), .vertical_align = .middle });
    const img = try t.el(logo, "img", .{});
    try img.setAttr("width", "18");
    try img.setAttr("height", "18");
    const nav = try td(&t, ir, .{ .vertical_align = .middle });
    _ = try t.text(nav, "Hacker News");
    const spacer_row = try tr(&t, tb);
    try spacer_row.setAttr("height", "10");
    _ = try td(&t, spacer_row, .{});
    const story_row = try tr(&t, tb);
    const story = try td(&t, story_row, .{});
    const st = try t.el(story, "table", .{ .display = .table, .border_spacing = 0, .border_spacing_y = 0 });
    const sb = try t.el(st, "tbody", group_s);
    const sr = try tr(&t, sb);
    const rank = try td(&t, sr, .{ .vertical_align = .top });
    _ = try t.text(rank, "1.");
    const vote = try td(&t, sr, .{ .vertical_align = .top });
    const spacer = try t.el(vote, "img", .{});
    try spacer.setAttr("width", "14");
    try spacer.setAttr("height", "1");
    const title = try td(&t, sr, .{});
    _ = try t.text(title, "A story about something rather interesting indeed");
    try t.run(1000, 800);

    // 85% of 1000 and centered by <center>.
    try t.rect(main, 75, 0, 850, t.boxOf(main).h);
    // The logo cell: 18 + 4 of padding; the nav gets the rest of 850.
    try u.close(22, t.boxOf(logo).w, "logo cell");
    try u.close(828, t.boxOf(nav).w, "nav");
    try t.rect(img, 75, 0, 18, 18);
    // The row's height in quirks: a picture alone sets no strut.
    try u.close(18, t.boxOf(head).h, "header row");
    try u.close(10, t.boxOf(spacer_row).h, "spacer row");
    try u.close(28, t.boxOf(story_row).y, "under the spacer");
    try u.close(14, t.boxOf(spacer).w, "spacer image");
    try u.close(16, t.boxOf(rank).w, "1.");
    try u.close(75 + 16 + 14, t.boxOf(title).x, "title after rank and vote");
}
