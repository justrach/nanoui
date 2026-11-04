//! Odd input must not crash or hang, and big documents must stay fast.
const std = @import("std");
const u = @import("tests_util.zig");
const box = @import("box.zig");
const T = u.T;
const px = u.px;
const pct = u.pct;
const css = @import("../css/style.zig");
const Style = css.Style;

fn deep(t: *T, depth: usize, s: Style) !*u.Node {
    var at = t.body;
    for (0..depth) |_| at = try t.el(at, "div", s);
    return at;
}

test "deep nesting is capped, and deeper content is dropped" {
    for ([_]Style{
        .{ .display = .block },
        .{ .display = .flex },
        .{ .display = .flex, .flex_direction = .column },
        .{ .display = .grid },
        .{ .display = .inline_block },
        .{ .display = .inline_ },
        .{ .display = .block, .float = .left },
        .{ .display = .block, .position = .absolute },
        .{ .display = .table_cell },
    }) |s| {
        var t = try T.init();
        defer t.deinit();
        const leaf = try deep(&t, 5000, s);
        _ = try t.text(leaf, "aa");
        try t.run(800, 600);
        try std.testing.expect(leaf.box == null);
    }
}

test "nested tables to the depth cap" {
    var t = try T.init();
    defer t.deinit();
    var at = t.body;
    for (0..2000) |_| {
        const b = try t.el(at, "table", .{ .display = .table });
        const r = try t.el(b, "tr", .{ .display = .table_row });
        at = try t.el(r, "td", .{ .display = .table_cell });
    }
    _ = try t.text(at, "aa");
    try t.run(800, 600);
}

test "garbage sizes" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const big: f32 = 1e30;
    const styles = [_]Style{
        .{ .display = .block, .width = px(nan), .height = px(inf), .margin_left = px(-big), .padding_top = px(big) },
        .{ .display = .block, .width = px(-100), .height = px(-100), .padding_left = px(-5), .min_width = px(big), .max_width = px(-big) },
        .{ .display = .block, .font_size = 1e30, .line_height = 1e30, .letter_spacing = 1e30, .word_spacing = -1e30 },
        .{ .display = .block, .font_size = 0, .line_height = 0 },
        .{ .display = .flex, .flex_grow = inf, .flex_shrink = nan, .flex_basis = px(nan), .column_gap = px(big) },
        .{ .display = .flex, .flex_wrap = .wrap, .width = px(0), .height = px(0) },
        .{ .display = .grid, .width = pct(1e30), .row_gap = px(big) },
        .{ .display = .inline_block, .width = pct(nan), .height = pct(inf), .aspect_ratio = nan },
        .{ .display = .inline_block, .aspect_ratio = 1e-30 },
        .{ .display = .block, .aspect_ratio = -3 },
        .{ .display = .table, .border_spacing = big, .border_spacing_y = nan },
        .{ .display = .block, .position = .absolute, .left = px(nan), .right = px(big), .top = px(inf), .bottom = px(-big) },
        .{ .display = .block, .float = .left, .width = px(big), .height = px(big) },
        .{ .display = .list_item, .list_style = .decimal, .font_size = nan },
    };
    for (styles) |s| {
        var t = try T.init();
        defer t.deinit();
        const a = try t.el(t.body, "div", s);
        _ = try t.text(a, "some words and more words");
        const b = try t.el(a, "div", s);
        _ = try t.text(b, "x");
        _ = try t.el(a, "span", .{});
        _ = try t.el(t.body, "div", s);
        try t.run(800, 600);
        try allFinite(t.tree.root);
        try std.testing.expect(std.math.isFinite(t.tree.doc_w) and std.math.isFinite(t.tree.doc_h));
    }
}

fn allFinite(b: *box.Box) anyerror!void {
    const fin = std.math.isFinite;
    try std.testing.expect(fin(b.x) and fin(b.y) and fin(b.w) and fin(b.h));
    try std.testing.expect(fin(b.content_w) and fin(b.content_h));
    for (b.runs) |r| try std.testing.expect(fin(r.x) and fin(r.baseline) and fin(r.w) and fin(r.line_top));
    for (b.frags) |r| try std.testing.expect(fin(r.x) and fin(r.y) and fin(r.w) and fin(r.h));
    var k = b.first_child;
    while (k) |x| : (k = x.next) try allFinite(x);
}

test "viewport of nothing, odd table spans, empty parts" {
    var t = try T.init();
    defer t.deinit();
    const b = try t.el(t.body, "table", .{ .display = .table, .width = pct(100) });
    const g = try t.el(b, "tbody", .{ .display = .table_row_group });
    _ = try t.el(b, "tbody", .{ .display = .table_row_group });
    const r = try t.el(g, "tr", .{ .display = .table_row });
    const c = try t.el(r, "td", .{ .display = .table_cell });
    try c.setAttr("colspan", "99999");
    try c.setAttr("rowspan", "0");
    const d = try t.el(r, "td", .{ .display = .table_cell });
    try d.setAttr("colspan", "junk");
    try d.setAttr("rowspan", "-1");
    _ = try t.el(t.body, "table", .{ .display = .table });
    try t.run(0, 0);
    try t.run(1, 1);
}

test "a zero-width container with text, floats and a long word" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(0), .overflow_wrap_anywhere = true });
    _ = try t.div(p, .{ .float = .left, .width = px(50), .height = px(10) });
    _ = try t.text(p, "aaaaaaaa bbbbbbbbb");
    const q = try t.div(t.body, .{ .width = px(1), .word_break_all = true });
    _ = try t.text(q, "aaaaaaaa");
    try t.run(800, 600);
    try std.testing.expect(t.boxOf(q).h > 0);
}

test "invalid UTF-8 and a very long word" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(50), .overflow_wrap_anywhere = true });
    _ = try t.text(p, "\xff\xfe\xc0abc\xe4\xb8");
    const q = try t.div(t.body, .{ .width = px(50), .word_break_all = true });
    const long = try t.a.alloc(u8, 200_000);
    @memset(long, 'x');
    _ = try t.text(q, long);
    try t.run(800, 600);
    // Six a line.
    try u.close(16 * @ceil(200000.0 / 6.0), t.boxOf(q).h, "every character placed");
}

fn nowMs() f64 {
    const io = std.testing.io;
    const ts = std.Io.Clock.awake.now(io);
    return @as(f64, @floatFromInt(ts.nanoseconds)) / 1e6;
}

/// A chain of nested containers of this display, with a few siblings at each
/// level: the case that goes exponential without the cache.
fn nestedChain(depth: usize, s: Style) !f64 {
    var t = try T.init();
    defer t.deinit();
    var at = t.body;
    for (0..depth) |_| {
        const side = try t.el(at, "div", .{ .display = .block });
        _ = try t.text(side, "some text in the side");
        at = try t.el(at, "div", s);
    }
    _ = try t.text(at, "the leaf");
    const start = nowMs();
    try t.run(1000, 800);
    return nowMs() - start;
}

test "deep flex and table layouts are near linear in depth" {
    for ([_]Style{
        .{ .display = .flex },
        .{ .display = .flex, .flex_direction = .column },
        .{ .display = .grid },
        .{ .display = .inline_block },
    }) |s| {
        const small = try nestedChain(100, s);
        const large = try nestedChain(500, s);
        std.debug.print("  {s}: depth 100 {d:.2} ms, depth 500 {d:.2} ms\n", .{ @tagName(s.display), small, large });
        // Generous for noise and quadratic walks of side lists; exponential
        // work would not finish at all.
        try std.testing.expect(large < 2000);
    }
    var t = try T.init();
    defer t.deinit();
    var at = t.body;
    for (0..500) |_| {
        const b = try t.el(at, "table", .{ .display = .table });
        const r = try t.el(b, "tr", .{ .display = .table_row });
        const left = try t.el(r, "td", .{ .display = .table_cell });
        _ = try t.text(left, "a cell");
        at = try t.el(r, "td", .{ .display = .table_cell });
    }
    _ = try t.text(at, "leaf");
    const start = nowMs();
    try t.run(1000, 800);
    const took = nowMs() - start;
    std.debug.print("  nested tables: depth 500 {d:.2} ms\n", .{took});
    try std.testing.expect(took < 2000);
}

/// A document the size of a long Wikipedia article.
pub fn articleDoc(t: *T, boxes: usize) !void {
    const p_style: Style = .{ .display = .block, .margin_top = px(14), .margin_bottom = px(14), .line_height = 22 };
    const link: Style = .{ .underline = true };
    const li_style: Style = .{ .display = .list_item, .list_style = .disc };
    const page = try t.el(t.body, "main", .{ .display = .block, .max_width = px(960), .margin_left = .auto, .margin_right = .auto, .padding_left = px(20), .padding_right = px(20) });
    var made: usize = 0;
    var sec: usize = 0;
    while (made < boxes) : (sec += 1) {
        const section = try t.el(page, "section", .{ .display = .block });
        const h = try t.el(section, "h2", .{ .display = .block, .font_size = 24, .margin_top = px(20) });
        _ = try t.text(h, "A section heading of the article");
        made += 2;
        if (sec % 3 == 0) {
            const side = try t.el(section, "aside", .{ .display = .block, .float = .right, .width = px(240) });
            const table = try t.el(side, "table", .{ .display = .table, .width = pct(100) });
            for (0..8) |_| {
                const r = try t.el(table, "tr", .{ .display = .table_row });
                const a = try t.el(r, "th", .{ .display = .table_cell });
                _ = try t.text(a, "Label");
                const b = try t.el(r, "td", .{ .display = .table_cell });
                _ = try t.text(b, "A value of some length");
                made += 3;
            }
        }
        for (0..4) |_| {
            const para = try t.el(section, "p", p_style);
            made += 1;
            for (0..6) |_| {
                _ = try t.text(para, "The quick brown fox jumps over the lazy dog, and then keeps running through the fields until it reaches ");
                const a = try t.el(para, "a", link);
                _ = try t.text(a, "a wiki link");
                made += 1;
            }
            _ = try t.text(para, ". The end of the paragraph.");
        }
        const ul = try t.el(section, "ul", .{ .display = .block, .padding_left = px(24) });
        for (0..5) |_| {
            const li = try t.el(ul, "li", li_style);
            _ = try t.text(li, "A list item with a few words in it");
            made += 1;
        }
    }
}

test "a 10 000 box article" {
    var t = try T.init();
    defer t.deinit();
    try articleDoc(&t, 10_000);
    var best: f64 = 1e9;
    var count: usize = 0;
    for (0..5) |_| {
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        const start = nowMs();
        const tree = try @import("layout.zig").run(scratch.allocator(), t.doc, .{ .width = 1200, .height = 800 }, u.measurer);
        best = @min(best, nowMs() - start);
        count = countBoxes(tree.root);
    }
    std.debug.print("  article: {d} boxes in {d:.2} ms\n", .{ count, best });
    try std.testing.expect(count >= 10_000);
}

fn countBoxes(b: *box.Box) usize {
    var n: usize = 1;
    var k = b.first_child;
    while (k) |x| : (k = x.next) n += countBoxes(x);
    return n;
}
