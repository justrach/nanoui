//! Flexbox, with the numbers from the spec's algorithm by hand.
const std = @import("std");
const u = @import("tests_util.zig");
const T = u.T;
const px = u.px;
const pct = u.pct;
const css = @import("../css/style.zig");
const Style = css.Style;

const flex_row: Style = .{ .display = .flex, .width = px(300) };

test "grow shares free space by factor" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, flex_row);
    const a = try t.div(f, .{ .width = px(50), .flex_grow = 1, .height = px(10) });
    const b = try t.div(f, .{ .width = px(50), .flex_grow = 3, .height = px(10) });
    try t.run(800, 600);
    // 200 free: 50 and 150.
    try t.rect(a, 0, 0, 100, 10);
    try t.rect(b, 100, 0, 200, 10);
}

test "shrink is weighted by base size" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, flex_row);
    const a = try t.div(f, .{ .width = px(200), .min_width = px(0), .height = px(10) });
    const b = try t.div(f, .{ .width = px(400), .min_width = px(0), .height = px(10) });
    try t.run(800, 600);
    // 300 over: a gives 100, b gives 200.
    try t.rect(a, 0, 0, 100, 10);
    try t.rect(b, 100, 0, 200, 10);
}

test "max and min clamp in the freeze loop" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, flex_row);
    const a = try t.div(f, .{ .flex_basis = px(0), .flex_grow = 1, .max_width = px(50), .height = px(1) });
    const b = try t.div(f, .{ .flex_basis = px(0), .flex_grow = 1, .height = px(1) });
    const c = try t.div(f, .{ .flex_basis = px(0), .flex_grow = 1, .height = px(1) });
    try t.run(800, 600);
    // A freezes at 50; the others split 250.
    try t.rect(a, 0, 0, 50, 1);
    try t.rect(b, 50, 0, 125, 1);
    try t.rect(c, 175, 0, 125, 1);
}

test "a flex factor under one doesn't take all the room" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, flex_row);
    const a = try t.div(f, .{ .flex_basis = px(100), .flex_grow = 0.5, .height = px(1) });
    try t.run(800, 600);
    // 200 free, half used.
    try t.rect(a, 0, 0, 200, 1);
}

test "the auto minimum stops shrinking at min-content" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, .{ .display = .flex, .width = px(50) });
    const a = try t.div(f, .{ .width = px(100) });
    _ = try t.text(a, "aaaaaaaa");
    const b = try t.div(f, .{ .width = px(100), .overflow_x = .hidden, .overflow_y = .hidden, .height = px(1) });
    try t.run(800, 600);
    // Items want 200 in 50. a stops at its word, 64. b has no auto minimum.
    try u.close(64, t.boxOf(a).w, "word");
    try u.close(0, t.boxOf(b).w, "clipped");
}

test "content sized basis and shrink to a percentage" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, flex_row);
    const a = try t.div(f, .{});
    _ = try t.text(a, "aa");
    const b = try t.div(f, .{ .width = pct(50), .height = px(1) });
    try t.run(800, 600);
    try t.rect(a, 0, 0, 16, 16);
    try t.rect(b, 16, 0, 150, 1);
}

test "justify-content table" {
    const J = struct { j: css.Justify, x0: f32, x1: f32 };
    for ([_]J{
        .{ .j = .normal, .x0 = 0, .x1 = 50 },
        .{ .j = .start, .x0 = 0, .x1 = 50 },
        .{ .j = .end, .x0 = 200, .x1 = 250 },
        .{ .j = .center, .x0 = 100, .x1 = 150 },
        .{ .j = .space_between, .x0 = 0, .x1 = 250 },
        .{ .j = .space_around, .x0 = 50, .x1 = 200 },
        .{ .j = .space_evenly, .x0 = 200.0 / 3.0, .x1 = 50 + 400.0 / 3.0 },
    }) |k| {
        var t = try T.init();
        defer t.deinit();
        var s = flex_row;
        s.justify_content = k.j;
        const f = try t.div(t.body, s);
        const a = try t.div(f, .{ .width = px(50), .height = px(1) });
        const b = try t.div(f, .{ .width = px(50), .height = px(1) });
        try t.run(800, 600);
        try u.close(k.x0, t.boxOf(a).x, "first");
        try u.close(k.x1, t.boxOf(b).x, "second");
    }
}

test "direction: reverse and column" {
    var t = try T.init();
    defer t.deinit();
    var s = flex_row;
    s.flex_direction = .row_reverse;
    const f = try t.div(t.body, s);
    const a = try t.div(f, .{ .width = px(50), .height = px(1) });
    const b = try t.div(f, .{ .width = px(50), .height = px(1) });
    const col = try t.div(t.body, .{ .display = .flex, .flex_direction = .column, .height = px(100), .width = px(40) });
    const c = try t.div(col, .{ .height = px(10) });
    const d = try t.div(col, .{ .flex_grow = 1 });
    const rev = try t.div(t.body, .{ .display = .flex, .flex_direction = .column_reverse, .height = px(100), .width = px(40) });
    const e = try t.div(rev, .{ .height = px(10) });
    try t.run(800, 600);
    try t.rect(a, 250, 0, 50, 1);
    try t.rect(b, 200, 0, 50, 1);
    try t.rect(c, 0, 1, 40, 10);
    // Stretch across the column, and grows along it.
    try t.rect(d, 0, 11, 40, 90);
    try t.rect(e, 0, 191, 40, 10);
}

test "wrap breaks lines and align-content distributes them" {
    var t = try T.init();
    defer t.deinit();
    var s = flex_row;
    s.flex_wrap = .wrap;
    s.height = px(100);
    s.column_gap = px(10);
    s.row_gap = px(20);
    const f = try t.div(t.body, s);
    const a = try t.div(f, .{ .width = px(150), .height = px(10) });
    const b = try t.div(f, .{ .width = px(140), .height = px(20) });
    const c = try t.div(f, .{ .width = px(160), .height = px(30), .flex_grow = 1 });
    try t.run(800, 600);
    // Line 1: 150 + 10 + 140 = 300 fits. Line 2: c alone, grown to 300.
    // Lines 20 and 30, gap 20: 70; 30 over, 15 to each by stretch: lines of 35 and 45.
    // Definite heights: not stretched themselves.
    try t.rect(a, 0, 0, 150, 10);
    try t.rect(b, 160, 0, 140, 20);
    try t.rect(c, 0, 55, 300, 30);
}

test "wrap-reverse stacks lines upward" {
    var t = try T.init();
    defer t.deinit();
    var s = flex_row;
    s.flex_wrap = .wrap_reverse;
    s.align_content = .start;
    s.height = px(100);
    const f = try t.div(t.body, s);
    const a = try t.div(f, .{ .width = px(200), .height = px(10) });
    const b = try t.div(f, .{ .width = px(200), .height = px(20) });
    try t.run(800, 600);
    try t.rect(b, 0, 0, 200, 20);
    try t.rect(a, 0, 20, 200, 10);
}

test "align-items, align-self table" {
    const A = struct { a: css.Align, y: f32, h: f32 };
    for ([_]A{
        .{ .a = .normal, .y = 0, .h = 100 },
        .{ .a = .stretch, .y = 0, .h = 100 },
        .{ .a = .start, .y = 0, .h = 16 },
        .{ .a = .end, .y = 84, .h = 16 },
        .{ .a = .center, .y = 42, .h = 16 },
    }) |k| {
        var t = try T.init();
        defer t.deinit();
        var s = flex_row;
        s.height = px(100);
        s.align_items = k.a;
        const f = try t.div(t.body, s);
        const a = try t.div(f, .{});
        _ = try t.text(a, "aa");
        // align-self wins.
        const b = try t.div(f, .{ .align_self = k.a });
        _ = try t.text(b, "bb");
        try t.run(800, 600);
        try t.rect(a, 0, k.y, 16, k.h);
        try t.rect(b, 16, k.y, 16, k.h);
    }
}

test "baseline alignment lines baselines up" {
    var t = try T.init();
    defer t.deinit();
    var s = flex_row;
    s.align_items = .baseline;
    const f = try t.div(t.body, s);
    const a = try t.div(f, .{ .font_size = 32 });
    _ = try t.text(a, "a");
    const b = try t.div(f, .{});
    _ = try t.text(b, "b");
    try t.run(800, 600);
    // a's baseline 25.6, b's 12.8: b moves down by 12.8.
    try u.close(0, t.boxOf(a).y, "a");
    try u.close(12.8, t.boxOf(b).y, "b");
    try u.close(32, t.boxOf(f).h, "the larger above and below: 25.6 + 6.4");
}

test "auto margins take free space on both axes" {
    var t = try T.init();
    defer t.deinit();
    var s = flex_row;
    s.height = px(100);
    const f = try t.div(t.body, s);
    const a = try t.div(f, .{ .width = px(50), .height = px(10), .margin_left = .auto, .margin_right = .auto, .margin_top = .auto, .margin_bottom = .auto });
    var t2 = s;
    t2.justify_content = .center;
    const g = try t.div(t.body, t2);
    _ = try t.div(g, .{ .width = px(50), .height = px(10) });
    const pushed = try t.div(g, .{ .width = px(50), .height = px(10), .margin_left = .auto });
    try t.run(800, 600);
    try t.rect(a, 125, 45, 50, 10);
    // Auto margins come before justify-content.
    try t.rect(pushed, 250, 100, 50, 10);
}

test "order and gaps" {
    var t = try T.init();
    defer t.deinit();
    var s = flex_row;
    s.column_gap = px(10);
    const f = try t.div(t.body, s);
    const a = try t.div(f, .{ .order = 2, .width = px(50), .height = px(1) });
    const b = try t.div(f, .{ .order = 1, .width = px(50), .height = px(1) });
    try t.run(800, 600);
    try t.rect(b, 0, 0, 50, 1);
    try t.rect(a, 60, 0, 50, 1);
}

test "a nested flex column gets a definite height from stretch" {
    var t = try T.init();
    defer t.deinit();
    var s = flex_row;
    s.height = px(200);
    const f = try t.div(t.body, s);
    const col = try t.div(f, .{ .display = .flex, .flex_direction = .column, .width = px(50) });
    const grow = try t.div(col, .{ .flex_grow = 1 });
    const pct_kid = try t.div(grow, .{ .height = pct(50) });
    const foot = try t.div(col, .{ .height = px(20) });
    try t.run(800, 600);
    try t.rect(grow, 0, 0, 50, 180);
    try t.rect(pct_kid, 0, 0, 50, 90);
    try t.rect(foot, 0, 180, 50, 20);
}

test "nested row in column in row: widths and heights resolve" {
    var t = try T.init();
    defer t.deinit();
    const outer = try t.div(t.body, .{ .display = .flex, .width = px(400) });
    const side = try t.div(outer, .{ .flex_basis = px(100), .flex_shrink = 0 });
    _ = try t.text(side, "aa");
    const main = try t.div(outer, .{ .display = .flex, .flex_direction = .column, .flex_grow = 1, .min_width = px(0) });
    const row = try t.div(main, .{ .display = .flex });
    const c1 = try t.div(row, .{ .flex_grow = 1 });
    _ = try t.text(c1, "bb");
    const c2 = try t.div(row, .{ .flex_grow = 1 });
    _ = try t.text(c2, "bb");
    try t.run(800, 600);
    try t.rect(side, 0, 0, 100, 16);
    try t.rect(main, 100, 0, 300, 16);
    try t.rect(row, 100, 0, 300, 16);
    try t.rect(c1, 100, 0, 150, 16);
    try t.rect(c2, 250, 0, 150, 16);
}

test "min-height on a flex container makes centering work" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, .{ .display = .flex, .min_height = px(100), .align_items = .center, .justify_content = .center, .width = px(100) });
    const k = try t.div(f, .{ .width = px(10), .height = px(10) });
    try t.run(800, 600);
    try t.rect(f, 0, 0, 100, 100);
    try t.rect(k, 45, 45, 10, 10);
}

test "inline-flex is shrink-to-fit and sits on the baseline" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "aa");
    const f = try t.el(p, "b", .{ .display = .inline_flex, .padding_left = px(4) });
    const k = try t.div(f, .{});
    _ = try t.text(k, "bb");
    try t.run(800, 600);
    try t.rect(f, 16, 0, 20, 16);
    try t.rect(k, 20, 0, 16, 16);
}

test "text directly in a flex container is an anonymous item" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, flex_row);
    _ = try t.text(f, "  aa  ");
    const k = try t.div(f, .{ .width = px(10), .height = px(10) });
    _ = try t.text(f, "   ");
    try t.run(800, 600);
    try t.rect(k, 16, 0, 10, 10);
    try u.close(16, t.boxOf(f).h, "the text's line");
}

test "an absolute child is out of the flex flow, at the content's start" {
    var t = try T.init();
    defer t.deinit();
    var s = flex_row;
    s.padding_left = px(7);
    const f = try t.div(t.body, s);
    const a = try t.div(f, .{ .position = .absolute, .width = px(5), .height = px(5) });
    const k = try t.div(f, .{ .width = px(10), .height = px(10) });
    try t.run(800, 600);
    try t.rect(a, 7, 0, 5, 5);
    try t.rect(k, 7, 0, 10, 10);
}

test "a column with align-items center shrinks items to their text, and auto margins too" {
    var t = try T.init();
    defer t.deinit();
    const col = try t.div(t.body, .{ .display = .flex, .flex_direction = .column, .align_items = .center, .width = px(100) });
    const a = try t.div(col, .{});
    _ = try t.text(a, "aa");
    const b = try t.div(col, .{});
    // Too long for one line: as wide as there is room, and two lines.
    _ = try t.text(b, "aaaaaaaa aaaaaaaaaa");
    const wrap = try t.div(t.body, .{ .display = .flex, .flex_direction = .column, .width = px(100) });
    const c = try t.div(wrap, .{ .width = px(20), .height = px(5), .margin_left = .auto, .margin_right = .auto });
    try t.run(800, 600);
    try t.rect(a, 42, 0, 16, 16);
    try t.rect(b, 0, 16, 100, 32);
    try t.rect(c, 40, 48, 20, 5);
}

test "a table and a picture as flex items" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, .{ .display = .flex, .width = px(300), .align_items = .start });
    const tb = try t.el(f, "table", .{ .display = .table, .border_spacing = 0, .border_spacing_y = 0 });
    const r = try t.el(tb, "tr", .{ .display = .table_row });
    const c = try t.el(r, "td", .{ .display = .table_cell });
    _ = try t.text(c, "aaaa");
    const img = try t.el(f, "img", .{ .display = .block });
    try img.setAttr("data-w", "100");
    try img.setAttr("data-h", "50");
    const shrink = try t.el(f, "img", .{ .display = .block, .width = pct(10) });
    try shrink.setAttr("data-w", "100");
    try shrink.setAttr("data-h", "50");
    try t.run(800, 600);
    try t.rect(tb, 0, 0, 32, 16);
    try t.rect(img, 32, 0, 100, 50);
    try t.rect(shrink, 132, 0, 30, 15);
}
