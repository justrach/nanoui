//! Widgets tested through `Tester`: real frames, simulated input, and
//! pixels rendered offscreen by the Metal renderer.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Counter = struct {
    n: i32 = 0,
    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 12 });
        defer ui.end(c);
        ui.textf(c, .{ .size = 40, .weight = .bold }, "{d}", .{s.n});
        if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.n += 1;
    }
};

test "a click changes state, and the same frame shows it" {
    var s: Counter = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Counter.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("0"));
    try t.clickText("Increment");
    try t.clickText("Increment");
    try testing.expectEqual(@as(i32, 2), s.n);
    try testing.expect(t.hasText("2"));
}

test "a press that leaves the button before release is no click" {
    var s: Counter = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Counter.view), .{});
    defer t.deinit();
    const r = t.findText("Increment").?;
    t.drag(r.x + r.w / 2, r.y + r.h / 2, 5, 5);
    try testing.expectEqual(@as(i32, 0), s.n);
}

const Form = struct {
    on: bool = false,
    checked: bool = false,
    volume: f32 = 0,
    name: ui.TextBuffer = .{},
    submitted: u32 = 0,
    fn view(s: *Form, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        _ = ui.toggle(c, "Wi-Fi", &s.on);
        _ = ui.checkbox(c, "Agree", &s.checked);
        _ = ui.slider(c, &s.volume, .{ .width = .{ .px = 200 } });
        if (ui.textField(c, &s.name, .{ .placeholder = "Name" }).submitted) s.submitted += 1;
    }
};

test "toggle, checkbox, slider and text field" {
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();

    try t.clickText("Wi-Fi");
    try testing.expect(s.on);
    try t.clickText("Agree");
    try testing.expect(s.checked);
    try t.clickText("Agree");
    try testing.expect(!s.checked);

    // The slider spans x 20..220; its knob is 18 wide.
    const y = t.findText("Name").?.y - 22;
    t.drag(29, y, 220, y);
    try testing.expectEqual(@as(f32, 1), s.volume);
    t.drag(211, y, 120, y);
    try testing.expect(s.volume > 0.4 and s.volume < 0.6);

    try t.clickText("Name");
    t.typeText("Zig");
    t.typeText(" 0.17");
    try testing.expectEqualStrings("Zig 0.17", s.name.text());
    t.key(.backspace);
    t.key(.left);
    t.typeText("!");
    try testing.expectEqualStrings("Zig 0.!1", s.name.text());
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.submitted);
    // A press elsewhere drops the focus: typing goes nowhere.
    t.click(400, 330);
    t.typeText("x");
    try testing.expectEqualStrings("Zig 0.!1", s.name.text());
}

test "animations ease toward their target and settle" {
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();
    try t.clickText("Wi-Fi");
    try testing.expect(t.ctx.animating);
    t.settle(2);
    try testing.expect(!t.ctx.animating);
}

const List = struct {
    fn view(_: *List, c: *ui.Context) void {
        ui.scroll(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 10 });
        defer ui.end(c);
        for (0..40) |i| ui.textf(c, .{}, "Row {d}", .{i});
    }
};

test "scrolling moves content and stops at the end" {
    var s: List = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, List.view), .{ .height = 200 });
    defer t.deinit();
    const before = t.findText("Row 5").?.y;
    t.scroll(100, 100, -50);
    try testing.expectEqual(before - 50, t.findText("Row 5").?.y);
    t.scroll(100, 100, -100000);
    const last = t.findText("Row 39").?;
    try testing.expectApproxEqAbs(@as(f32, 190), last.y + last.h, 0.5);
}

test "the renderer draws what the view says" {
    var s: Counter = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Counter.view), .{ .width = 200, .height = 160, .scale = 1 });
    defer t.deinit();
    const pixels = try t.render(testing.allocator);
    defer pixels.deinit(testing.allocator);
    const at = struct {
        fn f(p: anytype, x: usize, y: usize) [3]u8 {
            const i = (y * p.width + x) * 4;
            return .{ p.bytes[i + 2], p.bytes[i + 1], p.bytes[i] }; // BGRA
        }
    }.f;
    // The background is the light theme's.
    try testing.expectEqual([3]u8{ 0xf5, 0xf5, 0xf7 }, at(pixels, 2, 2));
    // The button's corner is the accent blue (#0a84ff), away from its label.
    const r = t.findText("Increment").?;
    const b = at(pixels, @intFromFloat(r.x - 8), @intFromFloat(r.y + r.h / 2));
    try testing.expectEqual([3]u8{ 0x0a, 0x84, 0xff }, b);
    // The digit is drawn: some pixel of its box is dark.
    const d = t.findText("0").?;
    var darkest: u8 = 255;
    var y: usize = @intFromFloat(d.y);
    while (y < @as(usize, @intFromFloat(d.y + d.h))) : (y += 1) {
        var x: usize = @intFromFloat(d.x);
        while (x < @as(usize, @intFromFloat(d.x + d.w))) : (x += 1) darkest = @min(darkest, at(pixels, x, y)[0]);
    }
    try testing.expect(darkest < 0x40);
}

const Split = struct {
    fn view(_: *Split, c: *ui.Context) void {
        ui.row(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.column(c, .{ .width = .{ .px = 200 }, .height = .fill });
        ui.end(c);
        ui.column(c, .{ .grow = 1, .padding = .all(20) });
        defer ui.end(c);
        ui.text(c, "A paragraph long enough to wrap onto several lines in the room the row leaves it.", .{ .wrap = true });
    }
};

test "wrapped text fits the room a row gives it" {
    var s: Split = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Split.view), .{ .width = 420, .height = 300 });
    defer t.deinit();
    const r = t.findText("A paragraph long enough to wrap onto several lines in the room the row leaves it.").?;
    try testing.expectEqual(@as(f32, 220), r.x);
    try testing.expect(r.x + r.w <= 400.5);
    try testing.expect(r.h > 40); // more than two lines
}

const Bullets = struct {
    const long = "The first item, which wraps only beside its marker.";
    fn view(_: *Bullets, c: *ui.Context) void {
        // Room for the first item's text on one line, but not beside the
        // marker: the row measured at its whole width thought one line.
        const col = ui.div(c).column().w(c.text.width(long, .{}) + 10 + 20).gap(6).p(10);
        defer col.end();
        for ([_][]const u8{ long, "The second item." }) |line| {
            // A list's item: a marker of fixed width, the text beside it.
            const item = ui.div(c).row().wFull().gap(8);
            defer item.end();
            _ = c.leaf(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }, .none, null);
            const box = ui.div(c).column().grow();
            defer box.end();
            ui.text(c, line, .{ .wrap = true });
        }
    }
};

test "a row is as tall as its text wrapped beside a fixed box" {
    var s: Bullets = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Bullets.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    const first = t.findText(Bullets.long).?;
    const second = t.findText("The second item.").?;
    // It wraps in the room beside the marker, and the next item comes after.
    try testing.expect(first.h > 30);
    try testing.expect(second.y >= first.y + first.h + 6 - 0.5);
}

const Field = struct {
    buf: ui.TextBuffer = .{},
    fn view(s: *Field, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        _ = ui.textField(c, &s.buf, .{ .placeholder = "Type", .width = .{ .px = 160 } });
        ui.icon(c, "star.fill", .{ .size = 20 });
    }
};

test "text input: composition, selection, the clipboard, scrolling" {
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");
    try testing.expect(t.ctx.focused_text != null);

    // An input method composes, then commits.
    t.textOps(&.{.{ .set_marked = .{ .text = "にほ", .sel_start = 6, .sel_len = 0 } }});
    try testing.expect(t.ctx.focused_text.?.marked != null);
    t.textOps(&.{.{ .insert = "日本" }});
    try testing.expectEqualStrings("日本", s.buf.text());
    try testing.expect(t.ctx.focused_text.?.marked == null);

    // Selection, then copy and paste through the clipboard.
    t.textOps(&.{ .{ .insert = " and Zig" }, .{ .command = .select_word_left } });
    const f = t.ctx.focused_text.?;
    try testing.expectEqualStrings("Zig", f.text[@min(f.caret, f.anchor)..@max(f.caret, f.anchor)]);
    t.textOps(&.{ .{ .command = .cut }, .{ .command = .move_line_start }, .{ .insert = "x" } });
    try testing.expectEqualStrings("x日本 and ", s.buf.text());
    try testing.expectEqualStrings("Zig", t.clipboard.items);

    // Long text scrolls so the caret stays inside the field.
    t.textOps(&.{ .{ .command = .move_line_end }, .{ .insert = "a long tail that cannot fit in the field" } });
    const caret = t.ctx.focused_text.?.caret_rect;
    try testing.expect(caret.x <= 20 + 160 - 10 + 0.5);
    try testing.expect(caret.x >= 20);

    // Escape gives the focus up.
    t.textOps(&.{.{ .command = .cancel }});
    try testing.expect(t.ctx.focused_text == null);
}

test "icons are measured from their symbol" {
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    for (t.ctx.nodes.items) |n| if (n.content == .icon) {
        try testing.expect(n.rect.w > 15 and n.rect.w < 30);
        try testing.expect(n.rect.h > 15 and n.rect.h < 30);
        return;
    };
    return error.NoIcon;
}

const Big = struct {
    fn view(_: *Big, c: *ui.Context) void {
        var rows = ui.list(c, .{ .count = 100_000, .row_height = 28, .gap = 2 });
        while (rows.next()) |i| {
            ui.row(c, .{ .height = .{ .px = 28 }, .align_items = .center });
            defer ui.end(c);
            ui.textf(c, .{}, "Row {d}", .{i});
        }
        rows.end();
    }
};

test "a virtualized list builds only the rows in view" {
    var s: Big = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Big.view), .{ .height = 300 });
    defer t.deinit();
    try testing.expect(t.ctx.nodes.items.len < 60);
    try testing.expect(t.hasText("Row 0"));
    try testing.expect(!t.hasText("Row 50"));
    // Scroll to row 50 000: it shows where row 0 did.
    t.scroll(100, 100, -30 * 50_000);
    t.frame();
    const r = t.findText("Row 50000") orelse return error.RowNotBuilt;
    try testing.expectApproxEqAbs(@as(f32, 0), r.y, 6);
    try testing.expect(t.ctx.nodes.items.len < 60);
    // The end of the list: the last row's bottom meets the view's.
    t.scroll(100, 100, -1e9);
    t.frame();
    const last = t.findText("Row 99999") orelse return error.LastRowNotBuilt;
    try testing.expectApproxEqAbs(@as(f32, 300), last.y + 28 - (28 - last.h) / 2, 6);
}

const Fluent = struct {
    clicks: u32 = 0,
    fn view(s: *Fluent, c: *ui.Context) void {
        const th = c.theme;
        const page = ui.div(c).column().sizeFull().center().gap(8);
        defer page.end();
        const card = ui.div(c).row().p(16).gap(8).bg(th.surface).rounded(12).shadowMd().hover(th.surface_hover);
        defer card.end();
        if (card.clicked()) s.clicks += 1;
        ui.textf(c, .{}, "Clicked {d}", .{s.clicks});
    }
};

test "elements styled GPUI's way: fluent styles, hover, click" {
    var s: Fluent = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Fluent.view), .{});
    defer t.deinit();
    const r = t.findText("Clicked 0").?;
    // Centered in the 480 × 360 view, with 16 points of padding around.
    try testing.expectApproxEqAbs(@as(f32, 240), r.x + r.w / 2, 1);
    try t.clickText("Clicked 0");
    try testing.expectEqual(@as(u32, 1), s.clicks);
    try testing.expect(t.hasText("Clicked 1"));
    try testing.expect(t.ctx.cursor_hand);
}

const Rich = struct {
    family: ?[]const u8 = null,
    fn view(_: *Rich, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12, .width = .fill });
        defer ui.end(c);
        const plain = "Run the build and read the log";
        ui.text(c, plain, .{ .size = 14 });
        // The same words, "build" bold and "log" as code.
        // Spans, as strings, must live until the frame is drawn.
        const spans = c.alloc().dupe(ui.Span, &.{
            .{ .start = 8, .end = 13, .weight = .bold },
            .{ .start = 27, .end = 30, .mono = true, .background = c.theme.border },
        }) catch return;
        ui.richText(c, plain, spans, .{ .size = 14 });
        ui.text(c, "airy", .{ .size = 14, .leading = 1.6 });
        ui.text(c, "tight", .{ .size = 14 });
        ui.richText(c, "A paragraph with **bold** words long enough to wrap onto lines in a narrow column.", &.{.{ .start = 17, .end = 25, .weight = .bold, .italic = true }}, .{ .size = 14, .wrap = true });
    }
};

test "rich text: bold and code runs, leading, wrapping, families" {
    var s: Rich = .{};
    var t: ui.Tester = undefined;
    var theme = ui.Theme.light;
    theme.font = "No Such Family";
    try t.init(testing.allocator, .init(&s, Rich.view), .{ .width = 300, .height = 400, .theme = theme });
    defer t.deinit();
    var rects: [2]ui.Rect = undefined;
    var n: usize = 0;
    for (t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "Run the build and read the log") and n < 2) {
            rects[n] = node.rect;
            n += 1;
        },
        else => {},
    };
    try testing.expect(n == 2 and rects[1].w > rects[0].w + 1);
    try testing.expect(t.findText("airy").?.h > t.findText("tight").?.h + 4);
    try testing.expect(t.findText("A paragraph with **bold** words long enough to wrap onto lines in a narrow column.").?.h > 40);
    try testing.expect(t.findText("tight").?.w > 20);
    try t.screenshot("/tmp/nanoui-rich.png");
}

const Zoomed = struct {
    zoom: f32 = 1,
    fn view(s: *Zoomed, c: *ui.Context) void {
        c.setZoom(s.zoom);
        ui.column(c, .{ .padding = .all(10), .gap = 8 });
        defer ui.end(c);
        ui.text(c, "Zoom me", .{ .size = 14 });
        ui.kbd(c, ui.keys.label("⌘P"));
    }
};

test "zoom scales text, key caps show the platform's keys" {
    var s: Zoomed = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Zoomed.view), .{});
    defer t.deinit();
    const w1 = t.findText("Zoom me").?.w;
    try testing.expect(t.hasText(if (ui.keys.mac) "⌘P" else "Ctrl+P"));
    const bad = "hello \xff\xfe\xf0\x9f";
    if (!@import("text.zig").portable) {
        const objc = @import("../objc.zig");
        const pool = objc.Pool.push();
        defer pool.pop();
        try testing.expect(objc.fromNSString(objc.nsString(bad)).len > 0);
    }
    _ = t.ctx.text.wrapAttributed(bad, .{ .size = 13 }, &.{.{ .start = 0, .end = bad.len, .weight = .bold }}, 40);
    const count_before = t.ctx.text.layouts.count();
    t.frame();
    try testing.expect(t.ctx.text.layouts.count() == count_before and t.ctx.text.previous.count() == 0);
    t.ctx.text.setZoom(1.5);
    try testing.expectEqual(@as(usize, 0), t.ctx.text.run_fonts.items.len);
    s.zoom = 2;
    t.frame();
    t.frame();
    const w2 = t.findText("Zoom me").?.w;
    try testing.expect(w2 > w1 * 1.8 and w2 < w1 * 2.1);
}

test "a picture keeps its proportions, fits its room, and bad bytes draw nothing" {
    const Pic = struct {
        bytes: []const u8,
        ok: bool = false,
        bad: bool = true,
        fn view(p: *@This(), c: *ui.Context) void {
            ui.column(c, .{ .padding = .all(10), .gap = 6 });
            defer ui.end(c);
            p.ok = ui.image(c, .{ .key = "wide", .bytes = p.bytes, .max_width = 100 });
            p.bad = ui.image(c, .{ .key = "junk", .bytes = "not a picture" });
            _ = ui.image(c, .{ .key = "web", .bytes = p.bytes, .max_width = 1000, .scale = 1 });
        }
    };
    var px: [400 * 100 * 4]u8 = @splat(255);
    const bytes = try @import("png.zig").encode(testing.allocator, .{ .bytes = &px, .width = 400, .height = 100 });
    defer testing.allocator.free(bytes);
    var p: Pic = .{ .bytes = bytes };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Pic.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    t.settle(1);
    try testing.expect(p.ok and !p.bad);
    var sizes: [2][2]f32 = undefined;
    var k: usize = 0;
    for (t.ctx.nodes.items) |n| if (n.content == .image) {
        sizes[k] = .{ n.rect.w, n.rect.h };
        k += 1;
    };
    try testing.expect(k == 2 and std.meta.eql(sizes[0], .{ 100, 25 }) and std.meta.eql(sizes[1], .{ 400, 100 }));
}

test "a box that follows its end stays where the reader left it when content shrinks and grows" {
    const Log = struct {
        rows: usize = 40,
        id: u64 = 0,
        fn view(l: *@This(), c: *ui.Context) void {
            const box = c.open(.{ .direction = .column, .width = .fill, .height = .fill, .scroll = true, .follow_end = true }, null);
            defer c.end();
            l.id = c.node(box).id;
            for (0..l.rows) |i| {
                ui.key(c, c.print("row{d}", .{i}));
                ui.text(c, "a line of the log", .{ .size = 13 });
            }
        }
    };
    var l: Log = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&l, Log.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    t.settle(1);
    const end_of = struct {
        fn f(tt: *ui.Tester, id: u64) [2]f32 {
            return .{ tt.ctx.scroll.get(id) orelse 0, tt.ctx.scroll_max.get(id) orelse 0 };
        }
    }.f;
    try testing.expectEqual(end_of(&t, l.id)[1], end_of(&t, l.id)[0]);
    l.rows = 60;
    t.frame();
    t.frame();
    try testing.expectEqual(end_of(&t, l.id)[1], end_of(&t, l.id)[0]);
    t.scroll(100, 100, 600);
    t.settle(1);
    try testing.expect(end_of(&t, l.id)[0] < end_of(&t, l.id)[1] - 50);
    l.rows = 12;
    t.frame();
    t.frame();
    l.rows = 60;
    t.frame();
    t.frame();
    try testing.expect(end_of(&t, l.id)[0] < end_of(&t, l.id)[1] - 50);
}

test "text in a selectable box is selected by a drag and copied, and the drag is not a click" {
    const Page = struct {
        clicks: usize = 0,
        fn view(p: *@This(), c: *ui.Context) void {
            const d = ui.div(c).column().sizeFull().p(10).gap(4);
            c.node(d.index).style.selectable = true;
            defer d.end();
            ui.text(c, "first line of output", .{ .size = 13 });
            ui.text(c, "second line here", .{ .size = 13 });
            // A clickable box around a third line.
            const b = ui.div(c).row();
            defer b.end();
            if (b.clicked()) p.clicks += 1;
            ui.text(c, "third clickable line", .{ .size = 13 });
        }
    };
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    t.settle(1);
    const a = t.findText("first line of output").?;
    const b = t.findText("second line here").?;
    // From the start of "line" in the first to just after "second".
    const x0 = a.x + t.ctx.text.caretX("first line of output", .{ .size = 13 }, 6);
    const x1 = b.x + t.ctx.text.caretX("second line here", .{ .size = 13 }, 6);
    t.drag(x0, a.y + a.h / 2, x1, b.y + b.h / 2);
    t.settle(1);
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("line of output\nsecond", t.clipboard.items);
    // A drag inside the clickable line selects; it doesn't click.
    const c3 = t.findText("third clickable line").?;
    t.drag(c3.x + 2, c3.y + c3.h / 2, c3.x + 60, c3.y + c3.h / 2);
    t.settle(1);
    try testing.expectEqual(@as(usize, 0), p.clicks);
    t.click(c3.x + 20, c3.y + c3.h / 2);
    try testing.expectEqual(@as(usize, 1), p.clicks);
}

test "over text that selects, the pointer is the text cursor" {
    const Page = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const d = ui.div(c).column().sizeFull().p(10).gap(30);
            defer d.end();
            {
                const sel = ui.div(c).column();
                c.node(sel.index).style.selectable = true;
                defer sel.end();
                ui.text(c, "output you can copy", .{ .size = 13 });
            }
            ui.text(c, "a label you can't", .{ .size = 13 });
        }
    };
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    t.settle(1);
    const a = t.findText("output you can copy").?;
    t.moveTo(a.x + 10, a.y + a.h / 2);
    try testing.expect(t.ctx.cursor_text);
    const b = t.findText("a label you can't").?;
    t.moveTo(b.x + 10, b.y + b.h / 2);
    try testing.expect(!t.ctx.cursor_text);
    // Between frames (a move inside one box draws none), the same answer.
    t.ctx.input.mouse = .{ .x = a.x + 30, .y = a.y + a.h / 2 };
    try testing.expect(t.ctx.pointerOverText());
    t.ctx.input.mouse = .{ .x = b.x + 30, .y = b.y + b.h / 2 };
    try testing.expect(!t.ctx.pointerOverText());
}

test "a double click is two clicks, the second a double click" {
    const Rows = struct {
        clicks: u32 = 0,
        doubles: u32 = 0,
        fn view(r: *@This(), c: *ui.Context) void {
            const row = ui.div(c).row().wFull().h(30).px(10).itemsCenter();
            defer row.end();
            const it = row.interaction();
            if (it.clicked) r.clicks += 1;
            if (it.double_clicked) r.doubles += 1;
            ui.text(c, "Safari", .{});
        }
    };
    var r: Rows = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Rows.view), .{});
    defer t.deinit();
    const at = t.findText("Safari").?;
    t.click(at.x, at.y + 4);
    try testing.expectEqual(@as(u32, 0), r.doubles);
    t.doubleClick(at.x, at.y + 4);
    try testing.expectEqual(@as(u32, 3), r.clicks);
    try testing.expectEqual(@as(u32, 1), r.doubles);
}

test "a scrolling box with a greatest height is as tall as its content, then scrolls" {
    const Page = struct {
        lines: usize = 2,
        fn view(p: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull();
            defer root.end();
            const s = ui.div(c).column().wFull().maxH(100).scrollY();
            defer s.end();
            for (0..p.lines) |_| ui.text(c, "a line of an answer", .{ .size = 13 });
        }
    };
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 300, .height = 400 });
    defer t.deinit();
    t.settle(1);
    try testing.expect(scrollBox(&t).h > 20 and scrollBox(&t).h < 60);
    p.lines = 30;
    t.settle(1);
    try testing.expectEqual(@as(f32, 100), scrollBox(&t).h);
}

fn scrollBox(t: *ui.Tester) ui.Rect {
    for (t.ctx.nodes.items) |n| if (n.style.scroll) return n.rect;
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}
