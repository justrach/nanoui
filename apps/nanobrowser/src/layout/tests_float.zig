//! Floats and positioned boxes, every case by hand.
const std = @import("std");
const u = @import("tests_util.zig");
const T = u.T;
const px = u.px;
const pct = u.pct;
const css = @import("../css/style.zig");
const layout = @import("layout.zig");
const eq = u.eqText;

test "lines shorten beside a float" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(100) });
    const f = try t.div(p, .{ .float = .left, .width = px(36), .height = px(20) });
    const q = try t.div(p, .{});
    _ = try t.text(q, "aaaa bbbb cccc");
    try t.run(800, 600);
    try t.rect(f, 0, 0, 36, 20);
    const r = t.boxOf(q).runs;
    // 64 beside the float: aaaa bbbb is 72, so one word on each of the first
    // two lines (16 and 32 are the line tops; the float ends at 20).
    try eq("aaaa", r[0].text);
    try u.close(36, r[0].x, "first line beside");
    try eq("bbbb", r[1].text);
    try u.close(36, r[1].x, "second line still overlaps it");
    try eq("cccc", r[2].text);
    try u.close(0, r[2].x, "third is clear");
}

test "right float, and text-align right within what is left" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(100), .text_align = .right });
    const f = try t.div(p, .{ .float = .right, .width = px(30), .height = px(20) });
    const q = try t.div(p, .{ .text_align = .right });
    _ = try t.text(q, "aa");
    try t.run(800, 600);
    try t.rect(f, 70, 0, 30, 20);
    try u.close(54, t.boxOf(q).runs[0].x, "70 - 16");
}

test "floats stack, wrap and clear" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(100) });
    const a = try t.div(p, .{ .float = .left, .width = px(60), .height = px(10), .margin_right = px(2) });
    const b = try t.div(p, .{ .float = .left, .width = px(30), .height = px(20) });
    const c = try t.div(p, .{ .float = .left, .width = px(30), .height = px(5) });
    const d = try t.div(p, .{ .float = .right, .width = px(10), .height = px(5), .clear = .both });
    try t.run(800, 600);
    try t.rect(a, 0, 0, 60, 10);
    try t.rect(b, 62, 0, 30, 20);
    // No room at 0 (92 + 30), and it may not go left of b while b lasts.
    try t.rect(c, 0, 20, 30, 5);
    // Clears everything so far: c's bottom.
    try t.rect(d, 90, 25, 10, 5);
}

test "a float's margin box counts" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, .{ .float = .left, .width = px(10), .height = px(10), .margin_left = px(5), .margin_top = px(7), .margin_right = px(3), .margin_bottom = px(2) });
    const q = try t.div(t.body, .{});
    _ = try t.text(q, "a");
    try t.run(800, 600);
    try t.rect(f, 5, 7, 10, 10);
    try u.close(18, t.boxOf(q).runs[0].x, "5 + 10 + 3");
}

test "a float's auto width is shrink-to-fit" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, .{ .float = .left, .width = .auto });
    _ = try t.text(f, "aaaa bb");
    const g = try t.div(t.body, .{ .float = .right, .width = .auto, .max_width = px(40) });
    _ = try t.text(g, "aaaa bb");
    try t.run(800, 600);
    try t.rect(f, 0, 0, 56, 16);
    try t.rect(g, 760, 0, 40, 32);
}

test "formatting context roots contain floats and avoid them" {
    var t = try T.init();
    defer t.deinit();
    const holder = try t.div(t.body, .{ .flow_root = true });
    _ = try t.div(holder, .{ .float = .left, .width = px(50), .height = px(60) });
    // A plain block doesn't contain its float.
    const plain = try t.div(t.body, .{});
    _ = try t.div(plain, .{ .float = .left, .width = px(50), .height = px(60) });
    // A root beside it fits what is left; a fixed one that doesn't fit goes down.
    const fits = try t.div(t.body, .{ .overflow_x = .hidden, .overflow_y = .hidden, .height = px(10) });
    const fixed = try t.div(t.body, .{ .overflow_x = .hidden, .overflow_y = .hidden, .width = px(780), .height = px(10) });
    try t.run(800, 600);
    try u.close(60, t.boxOf(holder).h, "contains it");
    try u.close(0, t.boxOf(plain).h, "doesn't");
    try t.rect(fits, 50, 60, 750, 10);
    try t.rect(fixed, 0, 120, 780, 10);
}

test "clearing a float in another block of the same context" {
    var t = try T.init();
    defer t.deinit();
    const a = try t.div(t.body, .{});
    _ = try t.div(a, .{ .float = .left, .width = px(50), .height = px(60) });
    const c = try t.div(t.body, .{ .clear = .both, .height = px(5) });
    try t.run(800, 600);
    try t.rect(c, 0, 60, 800, 5);
}

test "a float inside text goes at the line's start, and below when it doesn't fit" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(100) });
    _ = try t.text(p, "aaaaaaaa");
    const f = try t.div(p, .{ .float = .left, .width = px(50), .height = px(20) });
    _ = try t.text(p, " bbbbb");
    try t.run(800, 600);
    // 64 + 50 is over 100: the float waits for the line's end.
    try t.rect(f, 0, 16, 50, 20);
    const r = t.boxOf(p).runs;
    try eq("aaaaaaaa", r[0].text);
    try eq("bbbbb", r[1].text);
    try u.close(50, r[1].x, "beside it");
}

test "relative: offset applied, flow unchanged" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .height = px(200) });
    const a = try t.div(p, .{ .position = .relative, .left = px(10), .top = px(20), .height = px(30) });
    const b = try t.div(p, .{ .position = .relative, .right = px(10), .bottom = px(5), .height = px(30) });
    const c = try t.div(p, .{ .position = .relative, .left = pct(50), .top = pct(50), .height = px(30) });
    const inner = try t.div(a, .{ .height = px(1) });
    const next = try t.div(p, .{ .height = px(1) });
    try t.run(800, 600);
    try t.rect(a, 10, 20, 800, 30);
    try t.rect(inner, 10, 20, 800, 1);
    try t.rect(b, -10, 25, 800, 30);
    try t.rect(c, 400, 160, 800, 30);
    try t.rect(next, 0, 90, 800, 1);
}

test "relative inline box moves its fragments and runs" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    const s = try t.span(p, .{ .position = .relative, .left = px(3), .top = px(4) });
    _ = try t.text(s, "aa");
    try t.run(800, 600);
    const b = t.boxOf(s);
    try u.close(3, b.frags[0].x, "frag x");
    try u.close(4, b.frags[0].y, "frag y");
    try u.close(3, b.runs[0].x, "run x");
    try u.close(16.8, b.runs[0].baseline, "baseline");
    try u.close(3, b.x, "union x");
}

const Abs = struct { s: css.Style, x: f32, y: f32, w: f32, h: f32 };

test "absolute table, in a relative box of 400 by 300 at (10, 20)" {
    const base: css.Style = .{ .position = .absolute, .display = .block };
    var cases = [_]Abs{
        // Insets from the padding box, which starts 2 inside the border.
        .{ .s = .{ .left = px(5), .top = px(6), .width = px(50), .height = px(40) }, .x = 17, .y = 28, .w = 50, .h = 40 },
        .{ .s = .{ .right = px(5), .bottom = px(6), .width = px(50), .height = px(40) }, .x = 357, .y = 276, .w = 50, .h = 40 },
        // Stretched between insets.
        .{ .s = .{ .left = px(10), .right = px(10), .top = px(10), .bottom = px(10) }, .x = 22, .y = 32, .w = 380, .h = 280 },
        // Percent of the padding box.
        .{ .s = .{ .left = pct(50), .top = pct(50), .width = pct(25), .height = pct(10) }, .x = 212, .y = 172, .w = 100, .h = 30 },
        // Auto margins center between insets.
        .{ .s = .{ .left = px(0), .right = px(0), .top = px(0), .bottom = px(0), .width = px(100), .height = px(100), .margin_left = .auto, .margin_right = .auto, .margin_top = .auto, .margin_bottom = .auto }, .x = 162, .y = 122, .w = 100, .h = 100 },
        // Shrink to fit: no width, one inset: "aa bb" is 40.
        .{ .s = .{ .left = px(0), .top = px(0) }, .x = 12, .y = 22, .w = 40, .h = 16 },
        // Shrink to fit from the right.
        .{ .s = .{ .right = px(0), .top = px(0) }, .x = 372, .y = 22, .w = 40, .h = 16 },
        // Margins on top of an inset.
        .{ .s = .{ .left = px(5), .top = px(5), .margin_left = px(3), .margin_top = px(4), .width = px(1), .height = px(1) }, .x = 20, .y = 31, .w = 1, .h = 1 },
        // Static position when insets are auto: where it would have been, under the first child.
        .{ .s = .{ .width = px(1), .height = px(1) }, .x = 12, .y = 32, .w = 1, .h = 1 },
    };
    for (&cases) |*k| {
        var t = try T.init();
        defer t.deinit();
        const border: css.Border = .{ .width = 2, .style = .solid };
        const cb = try t.div(t.body, .{ .position = .relative, .left = px(10), .top = px(20), .width = px(400), .height = px(300), .border_top = border, .border_left = border, .border_right = border, .border_bottom = border });
        _ = try t.div(cb, .{ .height = px(10) });
        var s = k.s;
        s.position = base.position;
        s.display = .block;
        const d = try t.div(cb, s);
        _ = try t.text(d, "aa bb");
        try t.run(800, 600);
        try t.rect(d, k.x, k.y, k.w, k.h);
    }
}

test "absolute with no positioned ancestor uses the viewport, and fixed always" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .margin_left = px(50), .margin_top = px(60), .height = px(5) });
    const a = try t.div(p, .{ .position = .absolute, .right = px(0), .bottom = px(0), .width = px(10), .height = px(10) });
    const rel = try t.div(t.body, .{ .position = .relative, .margin_left = px(5) });
    const f = try t.div(rel, .{ .position = .fixed, .left = px(1), .top = px(2), .width = pct(50), .height = pct(50) });
    try t.run(800, 600);
    try t.rect(a, 790, 590, 10, 10);
    try t.rect(f, 1, 2, 400, 300);
}

test "a fixed box does not stretch the page; an absolute one does" {
    var t = try T.init();
    defer t.deinit();
    _ = try t.div(t.body, .{ .position = .fixed, .left = px(5000), .top = px(5000), .width = px(10), .height = px(10) });
    try t.run(800, 600);
    try u.close(800, t.tree.doc_w, "fixed");
    var q = try T.init();
    defer q.deinit();
    _ = try q.div(q.body, .{ .position = .absolute, .left = px(5000), .top = px(4000), .width = px(10), .height = px(10) });
    try q.run(800, 600);
    try u.close(5010, q.tree.doc_w, "absolute");
    try u.close(4010, q.tree.doc_h, "absolute");
}

test "an absolute child of a clipping box overflows it when its containing block is that box" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .position = .relative, .width = px(50), .height = px(50), .overflow_x = .auto, .overflow_y = .auto });
    _ = try t.div(p, .{ .position = .absolute, .left = px(200), .top = px(300), .width = px(10), .height = px(10) });
    try t.run(800, 600);
    try u.close(210, t.boxOf(p).content_w, "its width");
    try u.close(310, t.boxOf(p).content_h, "its height");
    try u.close(800, t.tree.doc_w, "the page is not touched");
}

test "static position inside text" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "aa");
    const a = try t.div(p, .{ .position = .absolute, .width = px(5), .height = px(5) });
    _ = try t.text(p, "bb");
    try t.run(800, 600);
    try t.rect(a, 16, 0, 5, 5);
}

test "abs inside an inline box's containing block" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "aa");
    const s = try t.span(p, .{ .position = .relative });
    _ = try t.text(s, "bb");
    const a = try t.div(s, .{ .position = .absolute, .left = px(1), .top = px(1), .width = px(5), .height = px(5) });
    try t.run(800, 600);
    try t.rect(a, 17, 1, 5, 5);
}

test "rectOf and offsetParent" {
    var t = try T.init();
    defer t.deinit();
    const rel = try t.div(t.body, .{ .position = .relative, .margin_left = px(5) });
    const k = try t.div(rel, .{ .height = px(5) });
    const gone = try t.div(rel, .{ .display = .none });
    try t.run(800, 600);
    const r = layout.rectOf(k).?;
    try u.close(5, r.x, "x");
    try std.testing.expect(layout.rectOf(gone) == null);
    try std.testing.expect(layout.offsetParent(k) == rel);
    try std.testing.expect(layout.offsetParent(rel) == t.body);
    // Nothing stale once the tree changes.
    k.remove();
    try std.testing.expect(layout.rectOf(k) == null);
    t.doc.layout_dirty = false;
    try std.testing.expect(layout.rectOf(k) == null);
}

test "sticky stays where the flow put it: a frame moves it as the page scrolls" {
    var t = try T.init();
    defer t.deinit();
    const a = try t.div(t.body, .{ .position = .sticky, .top = px(4), .height = px(10) });
    const k = try t.div(a, .{ .position = .absolute, .left = px(1), .top = px(1), .width = px(1), .height = px(1) });
    try t.run(800, 600);
    try t.rect(a, 0, 0, 800, 10);
    try t.rect(k, 1, 1, 1, 1);
}

test "a clearfix after floats makes the parent hold them" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.div(p, .{ .float = .left, .width = px(50), .height = px(60) });
    var after: css.Style = .{ .display = .table, .clear = .both };
    p.after = &after;
    try t.run(800, 600);
    try u.close(60, t.boxOf(p).h, "by a ::after table");
    var q = try T.init();
    defer q.deinit();
    const r = try q.div(q.body, .{});
    _ = try q.div(r, .{ .float = .left, .width = px(50), .height = px(60) });
    var block: css.Style = .{ .display = .block, .clear = .both };
    r.after = &block;
    try q.run(800, 600);
    try u.close(60, q.boxOf(r).h, "by a ::after block");
}

test "margins of a block after a float still collapse with its sibling" {
    var t = try T.init();
    defer t.deinit();
    _ = try t.div(t.body, .{ .height = px(10), .margin_bottom = px(20) });
    const f = try t.div(t.body, .{ .float = .left, .width = px(5), .height = px(5) });
    const b = try t.div(t.body, .{ .height = px(10), .margin_top = px(30) });
    try t.run(800, 600);
    // The float sits where the margins so far put it: 10 + 20.
    try t.rect(f, 0, 30, 5, 5);
    try u.close(40, t.boxOf(b).y, "10 + the larger of 20 and 30");
}

test "percent inline-block, and text-align moves atoms with text" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(200), .text_align = .center });
    const ib = try t.el(p, "b", .{ .display = .inline_block, .width = pct(25), .height = px(10) });
    _ = try t.text(p, "aa");
    try t.run(800, 600);
    // 50 + 16 centered in 200.
    try u.close(67, t.boxOf(ib).x, "atom");
    try u.close(117, t.boxOf(p).runs[0].x, "text");
}

test "inline-table in a line" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "aa");
    const tb = try t.el(p, "table", .{ .display = .inline_table, .border_spacing = 0, .border_spacing_y = 0 });
    const r = try t.el(tb, "tr", .{ .display = .table_row });
    const c = try t.el(r, "td", .{ .display = .table_cell });
    _ = try t.text(c, "bb");
    try t.run(800, 600);
    try t.rect(tb, 16, 0, 16, 16);
    try u.close(12.8, t.boxOf(c).runs[0].baseline, "on the line's baseline");
}
