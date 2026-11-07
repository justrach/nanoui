//! Block formatting: widths by CSS 2 §10.3, heights, and every case of margin
//! collapsing, with the geometry worked out by hand.
const std = @import("std");
const u = @import("tests_util.zig");
const T = u.T;
const px = u.px;
const pct = u.pct;
const css = @import("../css/style.zig");

test "width fills, with margins, padding and borders inside" {
    var t = try T.init();
    defer t.deinit();
    const border: css.Border = .{ .width = 2, .style = .solid };
    const d = try t.div(t.body, .{
        .margin_left = px(10),
        .margin_right = px(20),
        .padding_left = px(5),
        .padding_right = px(5),
        .border_left = border,
        .border_right = border,
        .height = px(40),
    });
    try t.run(800, 600);
    try t.rect(d, 10, 0, 770, 40);
    const c = t.boxOf(d).contentRect();
    try u.close(17, c.x, "content x");
    try u.close(756, c.w, "content w");
}

test "width table: auto margins, percent, box-sizing, min, max" {
    const Case = struct { s: css.Style, x: f32, w: f32 };
    const cases = [_]Case{
        // Centered: (800-200)/2.
        .{ .s = .{ .width = px(200), .margin_left = .auto, .margin_right = .auto }, .x = 300, .w = 200 },
        // One auto margin takes all that is left.
        .{ .s = .{ .width = px(200), .margin_left = .auto }, .x = 600, .w = 200 },
        .{ .s = .{ .width = px(200), .margin_right = .auto }, .x = 0, .w = 200 },
        // Too wide: auto margins count as zero, and it overflows to the right.
        .{ .s = .{ .width = px(1000), .margin_left = .auto, .margin_right = .auto }, .x = 0, .w = 1000 },
        // Percent of the container.
        .{ .s = .{ .width = pct(50) }, .x = 0, .w = 400 },
        .{ .s = .{ .margin_left = pct(10) }, .x = 80, .w = 720 },
        // Content box: padding on top of width. Border box: within.
        .{ .s = .{ .width = px(100), .padding_left = px(10) }, .x = 0, .w = 110 },
        .{ .s = .{ .width = px(100), .padding_left = px(10), .box_sizing = .border_box }, .x = 0, .w = 100 },
        // A max-width centered by auto margins (the common page wrapper).
        .{ .s = .{ .max_width = px(600), .margin_left = .auto, .margin_right = .auto }, .x = 100, .w = 600 },
        .{ .s = .{ .width = px(100), .min_width = px(300) }, .x = 0, .w = 300 },
        // Calc: 100% - 20px.
        .{ .s = .{ .width = .{ .px = -20, .pct = 100 } }, .x = 0, .w = 780 },
        // Negative margin widens an auto box.
        .{ .s = .{ .margin_left = px(-10), .margin_right = px(-10) }, .x = -10, .w = 820 },
    };
    for (cases) |k| {
        var t = try T.init();
        defer t.deinit();
        var s = k.s;
        s.height = px(10);
        const d = try t.div(t.body, s);
        try t.run(800, 600);
        try t.rect(d, k.x, 0, k.w, 10);
    }
}

test "heights: auto from content, percent of definite, not of auto" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .height = px(200) });
    const half = try t.div(p, .{ .height = pct(50) });
    const q = try t.div(t.body, .{});
    const stays = try t.div(q, .{ .height = pct(50) });
    const inner = try t.div(stays, .{ .height = px(30) });
    try t.run(800, 600);
    try t.rect(half, 0, 0, 800, 100);
    // Percent of an auto height behaves as auto.
    try t.rect(stays, 0, 200, 800, 30);
    try t.rect(inner, 0, 200, 800, 30);
    try t.rect(q, 0, 200, 800, 30);
}

test "min-height and max-height" {
    var t = try T.init();
    defer t.deinit();
    const a = try t.div(t.body, .{ .min_height = px(50) });
    const b = try t.div(t.body, .{ .max_height = px(20) });
    _ = try t.div(b, .{ .height = px(100) });
    const after = try t.div(t.body, .{ .height = px(1) });
    try t.run(800, 600);
    try t.rect(a, 0, 0, 800, 50);
    try t.rect(b, 0, 50, 800, 20);
    try t.rect(after, 0, 70, 800, 1);
}

test "sibling margins collapse to the largest" {
    const Case = struct { bottom: f32, top: f32, gap: f32 };
    for ([_]Case{
        .{ .bottom = 20, .top = 30, .gap = 30 },
        .{ .bottom = 30, .top = 20, .gap = 30 },
        .{ .bottom = 20, .top = -10, .gap = 10 },
        .{ .bottom = -20, .top = -10, .gap = -20 },
    }) |k| {
        var t = try T.init();
        defer t.deinit();
        _ = try t.div(t.body, .{ .height = px(10), .margin_bottom = px(k.bottom) });
        const b = try t.div(t.body, .{ .height = px(10), .margin_top = px(k.top) });
        try t.run(800, 600);
        try u.close(10 + k.gap, t.boxOf(b).y, "second's top");
    }
}

test "parent and first child collapse" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .margin_top = px(10) });
    const k = try t.div(p, .{ .margin_top = px(30), .height = px(50) });
    try t.run(800, 600);
    // The larger margin, on both, and the parent's top is where the child's is.
    try t.rect(p, 0, 30, 800, 50);
    try t.rect(k, 0, 30, 800, 50);
}

test "padding or a border on the parent keeps margins apart" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .margin_top = px(10), .padding_top = px(1), .padding_bottom = px(1) });
    const k = try t.div(p, .{ .margin_top = px(30), .margin_bottom = px(40), .height = px(50) });
    const next = try t.div(t.body, .{ .height = px(5) });
    try t.run(800, 600);
    try u.close(10, t.boxOf(p).y, "parent's top");
    try u.close(41, t.boxOf(k).y, "child's top: 10 + 1 + 30");
    // 1 + 30 + 50 + 40 + 1.
    try u.close(122, t.boxOf(p).h, "parent's height");
    try u.close(132, t.boxOf(next).y, "next");
}

test "parent and last child collapse when height is auto" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .margin_bottom = px(10) });
    _ = try t.div(p, .{ .height = px(50), .margin_bottom = px(40) });
    const next = try t.div(t.body, .{ .height = px(5), .margin_top = px(5) });
    try t.run(800, 600);
    try u.close(50, t.boxOf(p).h, "the parent ends with its child");
    try u.close(90, t.boxOf(next).y, "50 + the largest of 10, 40, 5");
}

test "a definite height stops the last child's margin" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .height = px(100), .margin_bottom = px(10) });
    _ = try t.div(p, .{ .height = px(50), .margin_bottom = px(200) });
    const next = try t.div(t.body, .{ .height = px(5) });
    try t.run(800, 600);
    try u.close(110, t.boxOf(next).y, "100 + 10");
}

test "empty boxes collapse through" {
    var t = try T.init();
    defer t.deinit();
    _ = try t.div(t.body, .{ .height = px(10), .margin_bottom = px(5) });
    const empty = try t.div(t.body, .{ .margin_top = px(10), .margin_bottom = px(20) });
    const next = try t.div(t.body, .{ .height = px(10), .margin_top = px(5) });
    try t.run(800, 600);
    try u.close(0, t.boxOf(empty).h, "nothing in it");
    try u.close(30, t.boxOf(next).y, "10 + the largest of 5, 10, 20, 5");
}

test "a formatting context root keeps its children's margins in" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .overflow_x = .hidden, .overflow_y = .hidden });
    const k = try t.div(p, .{ .height = px(10), .margin_top = px(30), .margin_bottom = px(40) });
    const next = try t.div(t.body, .{ .height = px(5) });
    try t.run(800, 600);
    try t.rect(p, 0, 0, 800, 80);
    try t.rect(k, 0, 30, 800, 10);
    try t.rect(next, 0, 80, 800, 5);
}

test "the root element's margins do not collapse with body's" {
    var t = try T.init();
    defer t.deinit();
    var s = t.body.computed.?.*;
    s.margin_top = px(8);
    s.margin_bottom = px(8);
    s.margin_left = px(8);
    s.margin_right = px(8);
    t.body.computed = &s;
    _ = try t.div(t.body, .{ .height = px(100) });
    try t.run(800, 600);
    try t.rect(t.html, 0, 0, 800, 116);
    try t.rect(t.body, 8, 8, 784, 100);
    try u.close(600, t.tree.doc_h, "the page fits the viewport");
    try u.close(800, t.tree.doc_w, "and its width");
}

test "clearance puts a block below floats and drops its margin" {
    var t = try T.init();
    defer t.deinit();
    const f = try t.div(t.body, .{ .float = .left, .width = px(100), .height = px(50) });
    const c = try t.div(t.body, .{ .clear = .left, .margin_top = px(20), .height = px(10) });
    try t.run(800, 600);
    try t.rect(f, 0, 0, 100, 50);
    try t.rect(c, 0, 50, 800, 10);
}

test "clear does nothing when the margin already goes below" {
    var t = try T.init();
    defer t.deinit();
    _ = try t.div(t.body, .{ .float = .left, .width = px(100), .height = px(50) });
    const c = try t.div(t.body, .{ .clear = .left, .margin_top = px(60), .height = px(10) });
    try t.run(800, 600);
    try u.close(60, t.boxOf(c).y, "own margin");
}

test "nested coordinates are final page coordinates" {
    var t = try T.init();
    defer t.deinit();
    const a = try t.div(t.body, .{ .margin_left = px(10), .padding_top = px(5) });
    const b = try t.div(a, .{ .margin_left = px(20), .padding_left = px(1), .padding_top = px(3) });
    const c = try t.div(b, .{ .height = px(10) });
    try t.run(800, 600);
    try t.rect(a, 10, 0, 790, 18);
    try t.rect(b, 30, 5, 770, 13);
    try t.rect(c, 31, 8, 769, 10);
}

test "scrollable overflow is measured" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(100), .height = px(100), .overflow_y = .scroll, .overflow_x = .scroll, .padding_bottom = px(4) });
    _ = try t.div(p, .{ .width = px(300), .height = px(400) });
    try t.run(800, 600);
    const b = t.boxOf(p);
    try u.close(300, b.content_w, "wide");
    try u.close(404, b.content_h, "tall, and the padding after it");
}

test "overflow of what does not clip bubbles up to the page" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .height = px(10) });
    _ = try t.div(p, .{ .width = px(2000), .height = px(3000) });
    try t.run(800, 600);
    try u.close(2000, t.tree.doc_w, "page width");
    try u.close(3000, t.tree.doc_h, "page height");
}

test "aspect-ratio gives a plain block its height, or its width" {
    var t = try T.init();
    defer t.deinit();
    const a = try t.div(t.body, .{ .width = px(160), .aspect_ratio = 16.0 / 9.0 });
    const b = try t.div(t.body, .{ .height = px(50), .aspect_ratio = 2 });
    try t.run(800, 600);
    try t.rect(a, 0, 0, 160, 90);
    try t.rect(b, 0, 90, 100, 50);
}

test "canvas color from the root, else body" {
    var t = try T.init();
    defer t.deinit();
    var s = t.body.computed.?.*;
    s.background = .{ .r = 1, .a = 1 };
    t.body.computed = &s;
    try t.run(800, 600);
    try u.close(1, t.tree.canvas.r, "body's");
    var r = t.html.computed.?.*;
    r.background = .{ .g = 1, .a = 1 };
    t.html.computed = &r;
    try t.run(800, 600);
    try u.close(1, t.tree.canvas.g, "root's");
}
