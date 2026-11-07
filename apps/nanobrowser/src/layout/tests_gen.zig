//! Box generation: what gets a box, anonymous blocks, generated content, list
//! markers, replaced elements and controls.
const std = @import("std");
const u = @import("tests_util.zig");
const box = @import("box.zig");
const T = u.T;
const px = u.px;
const pct = u.pct;
const css = @import("../css/style.zig");
const eq = u.eqText;

test "display none is skipped, contents splices its children" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .display = .flex, .width = px(100) });
    const none = try t.div(p, .{ .display = .none, .width = px(50) });
    const contents = try t.div(p, .{ .display = .contents });
    const a = try t.div(contents, .{ .width = px(10), .height = px(10) });
    const b = try t.div(contents, .{ .width = px(10), .height = px(10) });
    try t.run(800, 600);
    try std.testing.expect(none.box == null);
    try std.testing.expect(contents.box == null);
    try t.rect(a, 0, 0, 10, 10);
    try t.rect(b, 10, 0, 10, 10);
}

test "anonymous blocks wrap inline runs beside blocks; whitespace between goes" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    _ = try t.text(p, "aa");
    const d = try t.div(p, .{ .height = px(10) });
    _ = try t.text(p, "\n   ");
    const e = try t.div(p, .{ .height = px(10) });
    _ = try t.text(p, "bb");
    try t.run(800, 600);
    const bp = t.boxOf(p);
    try u.close(16, t.boxOf(d).y, "after the anonymous line");
    try u.close(26, t.boxOf(e).y, "no line for the whitespace");
    try u.close(52, bp.h, "16 + 10 + 10 + 16");
    try std.testing.expect(bp.first_child.?.node == null);
    try eq("aa", bp.first_child.?.runs[0].text);
    try eq("bb", bp.last_child.?.runs[0].text);
}

test "a block inside an inline closes the line, and the line goes on after" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    const s = try t.span(p, .{});
    _ = try t.text(s, "aa");
    const d = try t.div(s, .{ .height = px(10) });
    _ = try t.text(s, "bb");
    const a = try t.span(p, .{});
    const only = try t.div(a, .{ .height = px(5) });
    try t.run(800, 600);
    try u.close(16, t.boxOf(d).y, "under aa");
    try u.close(800, t.boxOf(d).w, "as wide as a block");
    try u.close(47, t.boxOf(p).h, "16 + 10 + 16 + 5");
    try std.testing.expect(t.boxOf(s).kind == .inline_box);
    // An inline holding only a block answers with the block.
    try u.close(42, t.boxOf(a).y, "the block's rect");
    try u.close(42, t.boxOf(only).y, "its place");
}

test "::before and ::after are inline boxes with generated text" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    const before = try t.a.create(css.Style);
    before.* = .{ .content = "[[" };
    const after = try t.a.create(css.Style);
    after.* = .{ .content = "]]", .display = .block };
    p.before = before;
    p.after = after;
    _ = try t.text(p, "aa");
    try t.run(800, 600);
    const bp = t.boxOf(p);
    // The ::after is a block: the before and the text are in an anonymous box.
    const anon = bp.first_child.?;
    const inner = anon.first_child.?;
    try std.testing.expect(inner.pseudo);
    try eq("[[", inner.runs[0].text);
    try std.testing.expect(inner.runs[0].node == null);
    try eq("aa", anon.runs[0].text);
    try u.close(16, anon.runs[0].x, "after the generated text");
    const af = bp.last_child.?;
    try std.testing.expect(af.pseudo);
    try eq("]]", af.runs[0].text);
    try u.close(32, bp.h, "two lines");
}

test "list markers: bullets are rects, counters are runs" {
    var t = try T.init();
    defer t.deinit();
    const ul = try t.el(t.body, "ul", .{ .display = .block, .padding_left = px(40) });
    const li = try t.el(ul, "li", .{ .display = .list_item, .list_style = .disc });
    _ = try t.text(li, "aa");
    const none = try t.el(ul, "li", .{ .display = .list_item, .list_style = .none });
    _ = try t.text(none, "aa");
    try t.run(800, 600);
    const b = t.boxOf(li);
    const m = b.marker.?;
    const size: f32 = 16 * 0.35;
    try u.close(size, m.w, "bullet");
    try u.close(40 - size - 8, m.x, "left of the content");
    try u.close(12.8 - 6.4 - size / 2, m.y, "by the line's middle");
    try std.testing.expect(t.boxOf(none).marker == null);
}

test "counter styles, ol start, li value, reversed" {
    var t = try T.init();
    defer t.deinit();
    const ol = try t.el(t.body, "ol", .{ .display = .block, .padding_left = px(40) });
    try ol.setAttr("start", "4");
    const a = try t.el(ol, "li", .{ .display = .list_item, .list_style = .decimal });
    _ = try t.text(a, "aa");
    const b = try t.el(ol, "li", .{ .display = .list_item, .list_style = .decimal });
    _ = try t.text(b, "bb");
    const c = try t.el(ol, "li", .{ .display = .list_item, .list_style = .upper_roman });
    try c.setAttr("value", "9");
    _ = try t.text(c, "cc");
    const d = try t.el(ol, "li", .{ .display = .list_item, .list_style = .lower_alpha });
    _ = try t.text(d, "dd");
    const rev = try t.el(t.body, "ol", .{ .display = .block });
    try rev.setAttr("reversed", "");
    const r1 = try t.el(rev, "li", .{ .display = .list_item, .list_style = .decimal });
    _ = try t.el(rev, "li", .{ .display = .list_item, .list_style = .decimal });
    try t.run(800, 600);
    const run = t.boxOf(a).runs[0];
    try eq("4.", run.text);
    try std.testing.expect(run.node == null);
    try u.close(40 - 16 - 8, run.x, "outside, right aligned, with a gap");
    try u.close(12.8, run.baseline, "on the first line's baseline");
    try eq("5.", t.boxOf(b).runs[0].text);
    try eq("IX.", t.boxOf(c).runs[0].text);
    try eq("j.", t.boxOf(d).runs[0].text);
    try eq("2.", t.boxOf(r1).runs[0].text);
    try u.close(16, t.boxOf(r1).h, "an empty item holds a line for its marker, as in a browser");
}

test "marker inside takes room on the line" {
    var t = try T.init();
    defer t.deinit();
    const ol = try t.el(t.body, "ol", .{ .display = .block });
    const a = try t.el(ol, "li", .{ .display = .list_item, .list_style = .decimal, .list_inside = true });
    _ = try t.text(a, "aa");
    const ul = try t.el(t.body, "ul", .{ .display = .block });
    const b = try t.el(ul, "li", .{ .display = .list_item, .list_style = .square, .list_inside = true });
    _ = try t.text(b, "aa");
    try t.run(800, 600);
    try eq("1. ", t.boxOf(a).runs[0].text);
    try u.close(24, t.boxOf(a).runs[1].x, "after it");
    const m = t.boxOf(b).marker.?;
    try u.close(0, m.x, "at the start");
    try u.close(13.6, t.boxOf(b).runs[0].x, "0.85em on");
}

test "images: natural size, attributes, ratio kept, max-width" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{ .width = px(100) });
    const nat = try t.el(p, "img", .{ .display = .block });
    try nat.setAttr("data-w", "60");
    try nat.setAttr("data-h", "30");
    const scaled = try t.el(p, "img", .{ .display = .block, .width = px(30) });
    try scaled.setAttr("data-w", "60");
    try scaled.setAttr("data-h", "30");
    const by_h = try t.el(p, "img", .{ .display = .block, .height = px(10) });
    try by_h.setAttr("data-w", "60");
    try by_h.setAttr("data-h", "30");
    const limited = try t.el(p, "img", .{ .display = .block, .max_width = pct(100) });
    try limited.setAttr("data-w", "400");
    try limited.setAttr("data-h", "200");
    const attr = try t.el(p, "img", .{ .display = .block });
    try attr.setAttr("width", "20");
    try attr.setAttr("height", "40");
    const attr_limited = try t.el(p, "img", .{ .display = .block, .max_width = pct(100) });
    try attr_limited.setAttr("width", "400");
    try attr_limited.setAttr("height", "100");
    const half = try t.el(p, "img", .{ .display = .block, .width = pct(50) });
    try half.setAttr("data-w", "60");
    try half.setAttr("data-h", "30");
    try t.run(800, 600);
    try u.close(60, t.boxOf(nat).w, "natural w");
    try u.close(30, t.boxOf(nat).h, "natural h");
    try u.close(15, t.boxOf(scaled).h, "by ratio");
    try u.close(20, t.boxOf(by_h).w, "by ratio");
    try u.close(100, t.boxOf(limited).w, "max-width: 100%");
    try u.close(50, t.boxOf(limited).h, "ratio kept");
    try u.close(20, t.boxOf(attr).w, "attribute");
    try u.close(40, t.boxOf(attr).h, "attribute");
    try u.close(100, t.boxOf(attr_limited).w, "limited");
    try u.close(25, t.boxOf(attr_limited).h, "ratio of its attributes");
    try u.close(50, t.boxOf(half).w, "percent");
    try u.close(25, t.boxOf(half).h, "ratio");
}

test "a broken image shows its alt text; without words it is nothing" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    const a = try t.el(p, "img", .{});
    try a.setAttr("alt", "aa");
    const b = try t.el(p, "img", .{});
    try t.run(800, 600);
    try std.testing.expect(t.boxOf(a).kind == .inline_box);
    try eq("aa", t.boxOf(a).runs[0].text);
    try std.testing.expect(t.boxOf(b).kind == .replaced);
    try u.close(0, t.boxOf(b).w, "no size");
}

test "replaced defaults: svg, canvas, video, iframe" {
    for ([_][]const u8{ "svg", "canvas", "video", "iframe" }) |tag| {
        var t = try T.init();
        defer t.deinit();
        const n = if (std.mem.eql(u8, tag, "svg")) try t.doc.createElementNs("svg", .svg) else try t.doc.createElement(tag);
        var s: css.Style = .{};
        n.computed = &s;
        t.body.appendChild(n);
        try t.run(800, 600);
        try u.close(300, t.boxOf(n).w, "w");
        try u.close(150, t.boxOf(n).h, "h");
    }
}

test "an svg keeps its viewBox's shape" {
    var t = try T.init();
    defer t.deinit();
    const n = try t.doc.createElementNs("svg", .svg);
    var s: css.Style = .{ .display = .block, .width = px(100) };
    n.computed = &s;
    try n.setAttr("viewBox", "0 0 24 12");
    t.body.appendChild(n);
    try t.run(800, 600);
    try u.close(50, t.boxOf(n).h, "by the box");
}

test "controls by their font" {
    const mk = struct {
        fn f(t: *T, tag: []const u8, attrs: []const [2][]const u8) !*u.Node {
            const n = try t.el(t.body, tag, .{ .display = .inline_block });
            for (attrs) |a| try n.setAttr(a[0], a[1]);
            return n;
        }
    }.f;
    var t = try T.init();
    defer t.deinit();
    const text = try mk(&t, "input", &.{});
    const sized = try mk(&t, "input", &.{.{ "size", "5" }});
    const check = try mk(&t, "input", &.{.{ "type", "checkbox" }});
    const radio = try mk(&t, "input", &.{.{ "type", "radio" }});
    const area = try mk(&t, "textarea", &.{ .{ "cols", "10" }, .{ "rows", "3" } });
    const select = try mk(&t, "select", &.{});
    const o1 = try t.el(select, "option", .{ .display = .none });
    _ = try t.text(o1, "aa");
    const o2 = try t.el(select, "option", .{ .display = .none });
    _ = try t.text(o2, "aaaaaaaa");
    const prog = try mk(&t, "progress", &.{});
    const meter = try mk(&t, "meter", &.{});
    const hidden = try mk(&t, "input", &.{.{ "type", "hidden" }});
    try t.run(800, 600);
    try u.close(160, t.boxOf(text).w, "20 characters");
    try u.close(16, t.boxOf(text).h, "one line");
    try u.close(40, t.boxOf(sized).w, "5 characters");
    try u.close(13, t.boxOf(check).w, "checkbox");
    try u.close(13, t.boxOf(radio).h, "radio");
    try u.close(80, t.boxOf(area).w, "cols");
    try u.close(48, t.boxOf(area).h, "rows");
    try u.close(64 + 22, t.boxOf(select).w, "longest option and the chevron");
    try u.close(160, t.boxOf(prog).w, "progress");
    try u.close(16, t.boxOf(prog).h, "progress");
    try u.close(80, t.boxOf(meter).w, "meter");
    try std.testing.expect(hidden.box == null);
    try std.testing.expect(t.boxOf(text).kind == .control);
}

test "buttons are inline-blocks; an input button's value is centered text" {
    var t = try T.init();
    defer t.deinit();
    const b = try t.el(t.body, "button", .{ .display = .inline_block, .padding_left = px(6), .padding_right = px(6), .height = px(40), .text_align = .center });
    _ = try t.text(b, "aa");
    const sub = try t.el(t.body, "input", .{ .display = .inline_block, .width = px(100) });
    try sub.setAttr("type", "submit");
    try sub.setAttr("value", "go");
    const dflt = try t.el(t.body, "input", .{ .display = .inline_block });
    try dflt.setAttr("type", "reset");
    const block_btn = try t.div(t.body, .{});
    const wide = try t.el(block_btn, "button", .{ .display = .block });
    _ = try t.text(wide, "aa");
    try t.run(800, 600);
    try u.close(28, t.boxOf(b).w, "shrink to fit");
    const run = t.boxOf(b).runs[0];
    try u.close(12 + 12.8, run.baseline - t.boxOf(b).y, "centered in its height");
    try std.testing.expect(t.boxOf(sub).kind == .block);
    try eq("go", t.boxOf(sub).runs[0].text);
    try std.testing.expect(t.boxOf(sub).runs[0].node == null);
    try u.close(t.boxOf(sub).x + 42, t.boxOf(sub).runs[0].x, "centered");
    try eq("Reset", t.boxOf(dflt).runs[0].text);
    try u.close(16, t.boxOf(wide).w, "a block button still fits its content");
}

test "pseudo boxes and text keep the flow of an inline formatting context" {
    var t = try T.init();
    defer t.deinit();
    const p = try t.div(t.body, .{});
    const a = try t.el(p, "a", .{});
    const inner = try t.div(a, .{ .height = px(5) });
    try t.run(800, 600);
    try t.rect(inner, 0, 0, 800, 5);
}
