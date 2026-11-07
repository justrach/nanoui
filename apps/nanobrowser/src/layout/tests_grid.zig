//! Grid: templates, placement and track sizing, worked out by hand.
const std = @import("std");
const u = @import("tests_util.zig");
const T = u.T;
const px = u.px;
const pct = u.pct;
const css = @import("../css/style.zig");
const Style = css.Style;
const Track = css.Track;
const Place = css.GridPlace;

const fr1: Track = .{ .kind = .fr, .fr = 1 };
const fr2: Track = .{ .kind = .fr, .fr = 2 };
const auto: Track = .{};

fn fixed(v: f32) Track {
    return .{ .kind = .fixed, .px = v };
}

fn g(cols: []const Track) Style {
    return .{ .display = .grid, .width = px(300), .grid_template_columns = .{ .tracks = cols } };
}

test "fixed, percent and fr columns, and gaps" {
    var t = try T.init();
    defer t.deinit();
    var s = g(&.{ fixed(50), .{ .kind = .fixed, .pct = 10 }, fr1, fr2 });
    s.column_gap = px(10);
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{ .height = px(5) });
    const b = try t.div(c, .{ .height = px(5) });
    const d = try t.div(c, .{ .height = px(5) });
    const e = try t.div(c, .{ .height = px(5) });
    try t.run(800, 600);
    // 300 - 30 gaps - 50 - 30 = 190: 1fr is 63.33.
    try t.rect(a, 0, 0, 50, 5);
    try t.rect(b, 60, 0, 30, 5);
    try t.rect(d, 100, 0, 190.0 / 3.0, 5);
    try t.rect(e, 100 + 190.0 / 3.0 + 10, 0, 380.0 / 3.0, 5);
}

test "auto rows and implicit rows from grid-auto-rows, row gap" {
    var t = try T.init();
    defer t.deinit();
    var s = g(&.{ fr1, fr1 });
    s.row_gap = px(4);
    s.grid_auto_rows = fixed(30);
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{});
    _ = try t.div(c, .{});
    const e = try t.div(c, .{});
    try t.run(800, 600);
    try t.rect(a, 0, 0, 150, 30);
    try t.rect(e, 0, 34, 150, 30);
    try u.close(64, t.boxOf(c).h, "two rows and a gap");
}

test "an fr track's auto minimum holds its content" {
    var t = try T.init();
    defer t.deinit();
    const c = try t.div(t.body, g(&.{ fr1, fr1 }));
    const a = try t.div(c, .{});
    _ = try t.text(a, "aaaaaaaaaaaaaaaaaaaaaaaaa"); // 200.
    const b = try t.div(c, .{ .height = px(1) });
    try t.run(800, 600);
    // 300: the first track stays at 200; the other gets the 100 left.
    try u.close(200, t.boxOf(a).w, "first");
    try u.close(200, t.boxOf(b).x, "second's start");
    try u.close(100, t.boxOf(b).w, "second");
}

test "minmax(0, 1fr) lets go of the content" {
    var t = try T.init();
    defer t.deinit();
    const mm: Track = .{ .kind = .minmax, .fr = 1 };
    const c = try t.div(t.body, g(&.{ mm, mm }));
    const a = try t.div(c, .{});
    _ = try t.text(a, "aaaaaaaaaaaaaaaaaaaaaaaaa");
    try t.run(800, 600);
    try u.close(150, t.boxOf(a).w, "half");
}

test "auto tracks: max-content then stretch" {
    var t = try T.init();
    defer t.deinit();
    const c = try t.div(t.body, g(&.{ auto, auto }));
    const a = try t.div(c, .{});
    _ = try t.text(a, "aaaaaa"); // 48.
    const b = try t.div(c, .{});
    _ = try t.text(b, "bb"); // 16.
    try t.run(800, 600);
    // (300 - 64) / 2 = 118 on top of each.
    try u.close(166, t.boxOf(a).w, "first");
    try u.close(134, t.boxOf(b).w, "second");
}

test "auto tracks shrink toward min-content when squeezed" {
    var t = try T.init();
    defer t.deinit();
    var s = g(&.{ auto, auto });
    s.width = px(60);
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{});
    _ = try t.text(a, "aaa bbb"); // Max 56, min 24.
    const b = try t.div(c, .{});
    _ = try t.text(b, "ccc ddd");
    try t.run(800, 600);
    // Bases 24 + 24; limits 56 + 56; 12 free: 6 each.
    try u.close(30, t.boxOf(a).w, "first");
    try u.close(30, t.boxOf(b).w, "second");
}

test "min-content and max-content tracks" {
    var t = try T.init();
    defer t.deinit();
    var s = g(&.{ .{ .kind = .min_content }, .{ .kind = .max_content }, fr1 });
    s.justify_content = .start;
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{});
    _ = try t.text(a, "aaa bbb");
    const b = try t.div(c, .{});
    _ = try t.text(b, "aaa bbb");
    const d = try t.div(c, .{ .height = px(1) });
    try t.run(800, 600);
    try u.close(24, t.boxOf(a).w, "min-content");
    try u.close(56, t.boxOf(b).w, "max-content");
    try u.close(220, t.boxOf(d).w, "fr has the rest");
}

test "repeat(auto-fill) fits as many as it can" {
    var t = try T.init();
    defer t.deinit();
    var s: Style = .{ .display = .grid, .width = px(330), .column_gap = px(10) };
    s.grid_template_columns = .{ .tracks = &.{.{ .kind = .fixed, .px = 100 }}, .auto_repeat = 0 };
    const c = try t.div(t.body, s);
    var last: *u.Node = undefined;
    for (0..4) |_| last = try t.div(c, .{ .height = px(5) });
    try t.run(800, 600);
    // (330 + 10) / 110 = 3 a row; the fourth starts the next row.
    try t.rect(last, 0, 5, 100, 5);
}

test "repeat(auto-fill, minmax(100px, 1fr)) stretches the tracks" {
    var t = try T.init();
    defer t.deinit();
    var s: Style = .{ .display = .grid, .width = px(330) };
    s.grid_template_columns = .{ .tracks = &.{.{ .kind = .minmax, .px = 100, .fr = 1 }}, .auto_repeat = 0 };
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{ .height = px(5) });
    try t.run(800, 600);
    // Three tracks of 110, whether or not there is an item for each.
    try u.close(110, t.boxOf(a).w, "a third");
}

test "repeat(auto-fit) collapses the empty ones" {
    var t = try T.init();
    defer t.deinit();
    var s: Style = .{ .display = .grid, .width = px(330) };
    s.grid_template_columns = .{ .tracks = &.{.{ .kind = .minmax, .px = 100, .fr = 1 }}, .auto_repeat = 0, .auto_fit = true };
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{ .height = px(5) });
    try t.run(800, 600);
    try u.close(330, t.boxOf(a).w, "all of it");
}

test "explicit lines, spans and negative lines" {
    var t = try T.init();
    defer t.deinit();
    const c = try t.div(t.body, g(&.{ fixed(100), fixed(100), fixed(100) }));
    const a = try t.div(c, .{ .height = px(10), .grid_column = .{ .start = 2, .end = 4 } });
    const b = try t.div(c, .{ .height = px(10), .grid_column = .{ .start = 1, .span = 2 }, .grid_row = .{ .start = 2 } });
    const d = try t.div(c, .{ .height = px(10), .grid_column = .{ .start = -2, .end = -1 }, .grid_row = .{ .start = 2 } });
    const e = try t.div(c, .{ .height = px(10), .grid_column = .{ .start = 1 }, .grid_row = .{ .start = 1 } });
    try t.run(800, 600);
    try t.rect(a, 100, 0, 200, 10);
    try t.rect(b, 0, 10, 200, 10);
    try t.rect(d, 200, 10, 100, 10);
    try t.rect(e, 0, 0, 100, 10);
}

test "auto-placement goes around what is placed, without going back" {
    var t = try T.init();
    defer t.deinit();
    const c = try t.div(t.body, g(&.{ fixed(100), fixed(100) }));
    const locked = try t.div(c, .{ .height = px(10), .grid_column = .{ .start = 1 }, .grid_row = .{ .start = 1 } });
    const a = try t.div(c, .{ .height = px(10) });
    const wide = try t.div(c, .{ .height = px(10), .grid_column = .{ .span = 2 } });
    const b = try t.div(c, .{ .height = px(10) });
    try t.run(800, 600);
    try t.rect(locked, 0, 0, 100, 10);
    try t.rect(a, 100, 0, 100, 10);
    try t.rect(wide, 0, 10, 200, 10);
    try t.rect(b, 0, 20, 100, 10);
}

test "column auto flow" {
    var t = try T.init();
    defer t.deinit();
    var s: Style = .{ .display = .grid, .width = px(300), .grid_auto_flow_column = true, .justify_content = .start };
    s.grid_template_rows = .{ .tracks = &.{ fixed(10), fixed(10) } };
    s.grid_auto_columns = fixed(40);
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{});
    const b = try t.div(c, .{});
    const d = try t.div(c, .{});
    try t.run(800, 600);
    try t.rect(a, 0, 0, 40, 10);
    try t.rect(b, 0, 10, 40, 10);
    try t.rect(d, 40, 0, 40, 10);
}

test "row spans share a tall item's height" {
    var t = try T.init();
    defer t.deinit();
    const c = try t.div(t.body, g(&.{ fixed(100), fixed(100) }));
    const tall = try t.div(c, .{ .height = px(100), .grid_row = .{ .span = 2 } });
    const a = try t.div(c, .{ .height = px(10) });
    const b = try t.div(c, .{ .height = px(10) });
    try t.run(800, 600);
    try t.rect(tall, 0, 0, 100, 100);
    // 100 for two rows of 10: 40 more each.
    try t.rect(a, 100, 0, 100, 10);
    try t.rect(b, 100, 50, 100, 10);
}

test "a spanning item widens auto tracks" {
    var t = try T.init();
    defer t.deinit();
    var s = g(&.{ auto, auto });
    s.justify_content = .start;
    const c = try t.div(t.body, s);
    const w = try t.div(c, .{ .width = px(100), .height = px(1), .grid_column = .{ .span = 2 } });
    const a = try t.div(c, .{ .height = px(1) });
    try t.run(800, 600);
    try t.rect(w, 0, 0, 100, 1);
    try u.close(50, t.boxOf(a).w, "half of what it asked for");
}

test "justify-items, align-items, and self" {
    var t = try T.init();
    defer t.deinit();
    var s = g(&.{ fixed(100), fixed(100) });
    s.grid_template_rows = .{ .tracks = &.{fixed(100)} };
    s.justify_items = .center;
    s.align_items = .end;
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{ .width = px(20), .height = px(10) });
    const b = try t.div(c, .{ .width = px(20), .height = px(10), .justify_self = .end, .align_self = .start });
    try t.run(800, 600);
    try t.rect(a, 40, 90, 20, 10);
    try t.rect(b, 180, 0, 20, 10);
}

test "items stretch by default, and auto margins center" {
    var t = try T.init();
    defer t.deinit();
    var s = g(&.{ fixed(100), fixed(100) });
    s.grid_template_rows = .{ .tracks = &.{fixed(100)} };
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{});
    const b = try t.div(c, .{ .width = px(20), .height = px(10), .margin_left = .auto, .margin_right = .auto, .margin_top = .auto, .margin_bottom = .auto });
    try t.run(800, 600);
    try t.rect(a, 0, 0, 100, 100);
    try t.rect(b, 140, 45, 20, 10);
}

test "justify-content and align-content move the tracks" {
    var t = try T.init();
    defer t.deinit();
    var s = g(&.{ fixed(100), fixed(100) });
    s.height = px(100);
    s.grid_template_rows = .{ .tracks = &.{ fixed(10), fixed(10) } };
    s.justify_content = .space_between;
    s.align_content = .center;
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{});
    const b = try t.div(c, .{});
    const d = try t.div(c, .{});
    try t.run(800, 600);
    try t.rect(a, 0, 40, 100, 10);
    try t.rect(b, 200, 40, 100, 10);
    try t.rect(d, 0, 50, 100, 10);
}

test "percent height inside a stretched row" {
    var t = try T.init();
    defer t.deinit();
    var s = g(&.{fr1});
    s.grid_template_rows = .{ .tracks = &.{fixed(100)} };
    const c = try t.div(t.body, s);
    const a = try t.div(c, .{});
    const k = try t.div(a, .{ .height = pct(50) });
    try t.run(800, 600);
    try t.rect(k, 0, 0, 300, 50);
}

test "an inline-grid's width comes from its tracks" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    var s: Style = .{ .display = .inline_grid, .column_gap = px(10) };
    s.grid_template_columns = .{ .tracks = &.{ fixed(30), auto } };
    const c = try t.el(p, "b", s);
    _ = try t.div(c, .{ .height = px(1) });
    const k = try t.div(c, .{ .height = px(1) });
    _ = try t.text(k, "aa");
    try t.run(800, 600);
    try u.close(56, t.boxOf(c).w, "30 + 10 + 16");
}

test "huge line numbers don't blow up" {
    var t = try T.init();
    defer t.deinit();
    const c = try t.div(t.body, g(&.{fr1}));
    _ = try t.div(c, .{ .grid_column = .{ .start = 32000, .end = -32000 }, .grid_row = .{ .start = -32000, .span = 60000 } });
    try t.run(800, 600);
}
