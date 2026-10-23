//! Text without a size limit, selection and focus asked by the app, and
//! the text area: tested through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

test "100 KB set keeps every byte" {
    const big = try testing.allocator.alloc(u8, 100 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));
    var buf: ui.TextBuffer = .{};
    defer buf.deinit();
    buf.set(big);
    try testing.expectEqualSlices(u8, big, buf.text());
    _ = buf.insert(50 * 1024, "middle");
    try testing.expectEqual(big.len + 6, buf.text().len);
    try testing.expectEqualStrings("middle", buf.text()[50 * 1024 ..][0..6]);
    try testing.expectEqualSlices(u8, big[50 * 1024 ..], buf.text()[50 * 1024 + 6 ..]);
    // Set from a part of itself (an address trimmed in place).
    buf.set(buf.text()[50 * 1024 ..][0..6]);
    try testing.expectEqualStrings("middle", buf.text());
}

const Field = struct {
    buf: ui.TextBuffer = .{},
    other: ui.TextBuffer = .{},
    focus: ?bool = null,
    fn view(s: *Field, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        _ = ui.textField(c, &s.other, .{ .placeholder = "Other" });
        if (s.focus) |all| c.focusNext(all);
        s.focus = null;
        _ = ui.textField(c, &s.buf, .{ .placeholder = "Address", .width = .{ .px = 300 } });
    }
    fn deinit(s: *Field) void {
        s.buf.deinit();
        s.other.deinit();
    }
};

fn selected(t: *ui.Tester) []const u8 {
    const f = t.ctx.focused_text.?;
    return f.text[@min(f.caret, f.anchor)..@max(f.caret, f.anchor)];
}

test "want_selection selects range" {
    var s: Field = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Address");
    s.buf.set("github.com");
    s.buf.want_selection = .{ 2, 10 };
    t.frame();
    const f = t.ctx.focused_text.?;
    try testing.expectEqual(@as(usize, 2), f.anchor);
    try testing.expectEqual(@as(usize, 10), f.caret);
    // Typing replaces what is selected.
    t.typeText("x");
    try testing.expectEqualStrings("gix", s.buf.text());
}

test "focusNext focuses field" {
    var s: Field = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    s.buf.set("kea.app");
    t.frame();
    try testing.expect(t.ctx.focused_text == null);
    s.focus = true;
    t.frame();
    try testing.expectEqualStrings("kea.app", t.ctx.focused_text.?.text);
    try testing.expectEqualStrings("kea.app", selected(&t));
    // Without select-all, the caret stays where it was.
    t.typeText("/x");
    s.focus = false;
    t.frame();
    try testing.expectEqualStrings("/x", s.buf.text());
    try testing.expectEqualStrings("", selected(&t));
}

const Composer = struct {
    buf: ui.TextBuffer = .{},
    sent: u32 = 0,
    max: u8 = 8,
    fn view(s: *Composer, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .width = .fill });
        defer ui.end(c);
        if (ui.textArea(c, &s.buf, .{ .placeholder = "Ask", .max_lines = s.max }).submitted) s.sent += 1;
    }
};

test "shift-return inserts newline" {
    var s: Composer = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Composer.view), .{});
    defer t.deinit();
    try t.clickText("Ask");
    t.typeText("a");
    t.ctx.input.shift = true;
    t.key(.enter);
    t.ctx.input.shift = false;
    t.typeText("b");
    // ⌥Return through the input system breaks the line too.
    t.ctx.input.alt = true;
    t.textOps(&.{.{ .command = .insert_newline }});
    t.ctx.input.alt = false;
    try testing.expectEqualStrings("a\nb\n", s.buf.text());
    try testing.expectEqual(@as(u32, 0), s.sent);
}

test "return submits" {
    var s: Composer = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Composer.view), .{});
    defer t.deinit();
    try t.clickText("Ask");
    t.typeText("hello");
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.sent);
    t.textOps(&.{.{ .command = .insert_newline }});
    try testing.expectEqual(@as(u32, 2), s.sent);
    try testing.expectEqualStrings("hello", s.buf.text());
}

test "grows to max_lines then scrolls" {
    var s: Composer = .{ .max = 3 };
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Composer.view), .{});
    defer t.deinit();
    try t.clickText("Ask");
    t.typeText("1");
    const lh = t.ctx.focused_text.?.caret_rect.h;
    // The column: 20 of padding above and below the area.
    try testing.expectApproxEqAbs(40 + lh, t.ctx.nodes.items[1].rect.h, 0.5);
    for ("2345", 0..) |ch, i| {
        t.ctx.input.shift = true;
        t.key(.enter);
        t.ctx.input.shift = false;
        t.typeText(&.{ch});
        const lines: f32 = @floatFromInt(@min(i + 2, 3));
        try testing.expectApproxEqAbs(40 + lines * lh, t.ctx.nodes.items[1].rect.h, 0.5);
    }
    try testing.expectEqualStrings("1\n2\n3\n4\n5", s.buf.text());
    // Five lines in three: the caret's, the last, in view at the bottom.
    const caret = t.ctx.focused_text.?.caret_rect;
    try testing.expectApproxEqAbs(20 + 2 * lh, caret.y, 0.5);
    try testing.expectApproxEqAbs(caret.y, t.findText("5").?.y, 0.5);
    // ↑ walks back to the first line, which scrolls into view.
    for (0..4) |_| t.key(.up);
    try testing.expect(t.ctx.focused_text.?.caret <= 1);
    try testing.expectApproxEqAbs(@as(f32, 20), t.ctx.focused_text.?.caret_rect.y, 0.5);
}

test "system undo and redo with Cmd+Z and Cmd+Shift+Z" {
    var s: Field = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Address");
    t.typeText("hello");
    t.typeText(" world");
    try testing.expectEqualStrings("hello world", s.buf.text());
    // Consecutive typing is grouped into one undo step.
    try testing.expect(t.shortcut(.{ .key = 'z', .cmd = true }));
    try testing.expectEqualStrings("", s.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'z', .cmd = true, .shift = true }));
    try testing.expectEqualStrings("hello world", s.buf.text());
    // Backspace breaks the typing group and records its own step.
    t.key(.backspace);
    try testing.expectEqualStrings("hello worl", s.buf.text());
    t.typeText("d!");
    try testing.expectEqualStrings("hello world!", s.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'z', .cmd = true }));
    try testing.expectEqualStrings("hello worl", s.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'z', .cmd = true }));
    try testing.expectEqualStrings("hello world", s.buf.text());
}

test "triple-click selects line or field and Tab cycles between fields" {
    var s: Field = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    s.other.set("first");
    s.buf.set("second");
    t.frame();
    try t.clickText("first");
    try testing.expectEqualStrings("first", t.ctx.focused_text.?.text);
    // Tab moves focus to the second field and selects all.
    t.key(.tab);
    try testing.expectEqualStrings("second", t.ctx.focused_text.?.text);
    try testing.expectEqualStrings("second", selected(&t));
    // Shift+Tab cycles back to the first field.
    t.ctx.input.shift = true;
    t.key(.tab);
    t.ctx.input.shift = false;
    try testing.expectEqualStrings("first", t.ctx.focused_text.?.text);
    // Triple-click in textArea selects the clicked line.
    var comp: Composer = .{};
    defer comp.buf.deinit();
    var tc: ui.Tester = undefined;
    try tc.init(testing.allocator, .init(&comp, Composer.view), .{});
    defer tc.deinit();
    comp.buf.set("alpha\nbeta\ngamma");
    tc.frame();
    const r = tc.findText("beta").?;
    tc.moveTo(r.x + 4, r.y + r.h / 2);
    tc.ctx.input.click_count = 3;
    tc.ctx.pointerDown();
    tc.frame();
    tc.ctx.pointerUp();
    tc.frame();
    try testing.expectEqualStrings("beta", selected(&tc));
}

const ThreeFields = struct {
    a: ui.TextBuffer = .{},
    b: ui.TextBuffer = .{},
    c: ui.TextBuffer = .{},
    fn view(s: *ThreeFields, cx: *ui.Context) void {
        ui.column(cx, .{ .padding = .all(12), .gap = 8 });
        defer ui.end(cx);
        _ = ui.textField(cx, &s.a, .{ .placeholder = "One" });
        _ = ui.textField(cx, &s.b, .{ .placeholder = "Two" });
        _ = ui.textField(cx, &s.c, .{ .placeholder = "Three" });
    }
    fn deinit(s: *ThreeFields) void {
        s.a.deinit();
        s.b.deinit();
        s.c.deinit();
    }
};

test "Tab and Shift+Tab cycle through three fields in order" {
    var s: ThreeFields = .{};
    defer s.deinit();
    s.a.set("alpha");
    s.b.set("beta");
    s.c.set("gamma");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, ThreeFields.view), .{});
    defer t.deinit();
    try t.clickText("alpha");
    try testing.expectEqualStrings("alpha", t.ctx.focused_text.?.text);
    t.key(.tab);
    try testing.expectEqualStrings("beta", t.ctx.focused_text.?.text);
    t.key(.tab);
    try testing.expectEqualStrings("gamma", t.ctx.focused_text.?.text);
    t.ctx.input.shift = true;
    t.key(.tab);
    t.ctx.input.shift = false;
    try testing.expectEqualStrings("beta", t.ctx.focused_text.?.text);
}

const WrappedField = struct {
    buf: ui.TextBuffer = .{},
    wrapped: bool = false,
    fn view(s: *WrappedField, cx: *ui.Context) void {
        ui.column(cx, .{ .padding = .all(12) });
        defer ui.end(cx);
        if (s.wrapped) ui.row(cx, .{});
        _ = ui.textField(cx, &s.buf, .{ .placeholder = "Name" });
        if (s.wrapped) ui.end(cx);
    }
};

test "focused textField keeps focus, caret, and undo when wrapped in a row" {
    var s: WrappedField = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, WrappedField.view), .{});
    defer t.deinit();
    try t.clickText("Name");
    t.typeText("hello");
    t.key(.left);
    t.key(.left);
    try testing.expectEqual(@as(usize, 3), t.ctx.focused_text.?.caret);

    // Wrap the field in an extra ui.row on the next frame.
    s.wrapped = true;
    t.frame();
    try testing.expect(t.ctx.focused_text != null);
    try testing.expectEqual(@as(usize, 3), t.ctx.focused_text.?.caret);

    // Typing continues at the preserved caret position, and undo still works.
    t.typeText("X");
    try testing.expectEqualStrings("helXlo", s.buf.text());
    try testing.expectEqual(@as(usize, 4), t.ctx.focused_text.?.caret);
    try testing.expect(t.shortcut(.{ .key = 'z', .cmd = true }));
    try testing.expectEqualStrings("hello", s.buf.text());
}

test "stale focus dropped when field vanishes" {
    const Vanish = struct {
        buf: ui.TextBuffer = .{},
        show: bool = true,
        fn view(s: *@This(), cx: *ui.Context) void {
            ui.column(cx, .{ .padding = .all(12) });
            defer ui.end(cx);
            if (s.show) _ = ui.textField(cx, &s.buf, .{ .placeholder = "Name" });
        }
    };
    var s: Vanish = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Vanish.view), .{});
    defer t.deinit();
    try t.clickText("Name");
    try testing.expect(t.ctx.focus != 0);
    s.show = false;
    t.frame();
    try testing.expectEqual(@as(u64, 0), t.ctx.focus);
}

test "double-click selects a word in a selectable box and copies even when a textField is focused" {
    const Page = struct {
        buf: ui.TextBuffer = .{},
        fn view(s: *@This(), cx: *ui.Context) void {
            const d = ui.div(cx).column().sizeFull().p(12).gap(12);
            defer d.end();
            {
                const sel = ui.div(cx).column();
                cx.node(sel.index).style.selectable = true;
                defer sel.end();
                ui.text(cx, "alpine parrot habitat", .{ .size = 13 });
            }
            _ = ui.textField(cx, &s.buf, .{ .placeholder = "Ask" });
        }
    };
    var p: Page = .{};
    defer p.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 320, .height = 200 });
    defer t.deinit();
    t.settle(1);
    const r = t.findText("alpine parrot habitat").?;
    const x_parrot = r.x + t.ctx.text.caretX("alpine parrot habitat", .{ .size = 13 }, 9);
    t.doubleClick(x_parrot, r.y + r.h / 2);
    t.settle(1);
    try testing.expectEqualStrings("parrot", t.ctx.selection.text.items);
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("parrot", t.clipboard.items);
}

test "multiline textArea preserves newlines on paste" {
    const Area = struct {
        buf: ui.TextBuffer = .{},
        fn view(s: *@This(), cx: *ui.Context) void {
            ui.column(cx, .{ .padding = .all(12), .width = .fill });
            defer ui.end(cx);
            _ = ui.textArea(cx, &s.buf, .{ .min_lines = 1, .max_lines = 6 });
        }
    };
    var a: Area = .{};
    defer a.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, Area.view), .{ .width = 320, .height = 200 });
    defer t.deinit();
    t.settle(1);
    t.click(20, 20);
    t.textOps(&.{.{ .insert = "line one\nline two\nline three" }});
    t.settle(1);
    try testing.expectEqualStrings("line one\nline two\nline three", a.buf.text());
}

test {
    _ = @import("textedit.zig");
    _ = @import("scroll.zig");
}
