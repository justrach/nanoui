//! A multiline text field, as Harness's composer: text wraps at the field's
//! width and the field grows with it, Shift-Return starts a line and
//! Return still submits, ↑ and ↓ move between the lines (an app takes them
//! on the first and last), a click lands on the line under it, and past
//! its most lines the field scrolls, by the caret and by the wheel.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");

const Composer = struct {
    buf: ui.TextBuffer = .{},
    last: ui.TextFieldResult = .{},
    submitted: u32 = 0,
    fn view(k: *@This(), c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10) });
        defer ui.end(c);
        c.focus = c.peekId(null);
        k.last = ui.textField(c, &k.buf, .{ .width = .{ .px = 220 }, .multiline = true, .max_lines = 4, .placeholder = "Ask anything" });
        if (k.last.submitted) k.submitted += 1;
    }
};

/// A field with no box of its own, as a chat composer's: its app draws the
/// frame, so its caret sits at the very edge of its content.
const Bare = struct {
    buf: ui.TextBuffer = .{},
    fn view(k: *@This(), c: *ui.Context) void {
        c.focus = c.peekId(null);
        _ = ui.textField(c, &k.buf, .{ .width = .{ .px = 220 }, .multiline = true, .max_lines = 4, .bare = true });
    }
};

/// The caret's quad: a thin, line-high rectangle. Text comes as glyphs, so
/// it is the only quad this narrow.
fn carets(t: *ui.Tester) usize {
    var n: usize = 0;
    for (t.instances.items) |inst| {
        if (inst.kind == gpu.Kind.quad and inst.rect[2] > 0 and inst.rect[2] <= 3 and inst.rect[3] > 5) n += 1;
    }
    return n;
}

fn fieldHeight(t: *ui.Tester) f32 {
    // The field: the column's first child.
    const root = t.ctx.nodes.items[0];
    return t.ctx.nodes.items[root.first_child].rect.h;
}

test "a multiline field wraps, grows, and takes Shift-Return as a new line" {
    var k: Composer = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Composer.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.settle(1);
    try testing.expect(t.hasText("Ask anything"));
    const one = fieldHeight(&t);
    t.typeText("the quick brown fox jumps over the lazy dog and keeps running");
    t.frame();
    try testing.expect(k.last.lines >= 2);
    try testing.expectEqual(k.last.lines - 1, k.last.line);
    try testing.expect(fieldHeight(&t) > one);
    // Shift-Return: a new line, not a submit; Return submits.
    t.ctx.input.shift = true;
    t.key(.enter);
    t.ctx.input.shift = false;
    try testing.expectEqual(@as(u32, 0), k.submitted);
    try testing.expect(std.mem.endsWith(u8, k.buf.text(), "running\n"));
    t.typeText("second");
    t.textOps(&.{.{ .command = .insert_line_break }});
    t.typeText("third");
    try testing.expect(std.mem.endsWith(u8, k.buf.text(), "\nsecond\nthird"));
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), k.submitted);
}

test "↑ and ↓ move between a multiline field's lines; a click lands on its line" {
    var k: Composer = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Composer.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.settle(1);
    t.typeText("first line\nsecond line\nthird");
    t.frame();
    try testing.expectEqual(@as(usize, 3), k.last.lines);
    try testing.expectEqual(@as(usize, 2), k.last.line);
    t.textOps(&.{.{ .command = .move_up }});
    t.frame();
    try testing.expectEqual(@as(usize, 1), k.last.line);
    // Kept its x: under the end of "third", in "second line".
    try testing.expect(k.last.caret > "first line\n".len and k.last.caret < "first line\nsecond line".len);
    t.key(.up);
    t.frame();
    try testing.expectEqual(@as(usize, 0), k.last.line);
    t.textOps(&.{.{ .command = .move_down }});
    t.textOps(&.{.{ .command = .move_down }});
    t.frame();
    try testing.expectEqual(@as(usize, 2), k.last.line);
    // ⌘← in a multiline field: its line's start.
    t.textOps(&.{.{ .command = .move_line_start }});
    try testing.expectEqual("first line\nsecond line\n".len, k.last.caret);
    // A click on the first line's text.
    const r = t.findText("first line") orelse return error.TextNotFound;
    t.click(r.x + 3, r.y + r.h / 2);
    t.frame();
    try testing.expectEqual(@as(usize, 0), k.last.line);
    try testing.expect(k.last.caret <= 1);
}

test "past its most lines a multiline field scrolls, by the caret and the wheel" {
    var k: Composer = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Composer.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.settle(1);
    t.typeText("one\ntwo\nthree\nfour");
    t.frame();
    const four = fieldHeight(&t);
    t.typeText("\nfive\nsix\nseven");
    t.frame();
    // No taller than four lines, and the caret's line in view.
    try testing.expectEqual(four, fieldHeight(&t));
    try testing.expectEqual(@as(usize, 7), k.last.lines);
    try testing.expect(t.findText("seven") != null);
    const field = t.ctx.nodes.items[t.ctx.nodes.items[0].first_child].rect;
    const seven = t.findText("seven").?;
    try testing.expect(seven.y + seven.h <= field.y + field.h + 0.5);
    // The wheel scrolls it back up; the caret didn't move, so it stays.
    t.scroll(field.x + 20, field.y + 10, 400);
    t.frame();
    const one = t.findText("one").?;
    try testing.expect(one.y >= field.y - 0.5);
    try testing.expectEqual(@as(usize, 6), k.last.line);
}

test "trailing spaces have editable caret and hit-test positions before a newline" {
    var k: Composer = .{};
    k.buf.set("draft  \nnext  ");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Composer.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    const lines = @import("textfield_lines.zig");
    const style: ui.TextStyle = .{ .size = 14 };
    const laid = lines.layout(&t.ctx, k.buf.text(), style, 200);
    try testing.expectEqual(@as(usize, 2), laid.len);
    for (laid) |l| {
        const before = lines.caretX(&t.ctx, k.buf.text(), style, l, l.stop - 2);
        const one = lines.caretX(&t.ctx, k.buf.text(), style, l, l.stop - 1);
        const two = lines.caretX(&t.ctx, k.buf.text(), style, l, l.stop);
        try testing.expect(one > before + 2);
        try testing.expect(two > one + 2);
        try testing.expectEqual(l.stop, lines.indexAt(&t.ctx, k.buf.text(), style, l, two));
    }
}

test "a selection containing only trailing spaces is visible" {
    var k: Composer = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Composer.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.textOps(&.{.{ .insert = "draft  " }});
    t.textOps(&.{ .{ .command = .select_left }, .{ .command = .select_left } });
    var selected = false;
    for (t.ctx.nodes.items) |n| {
        if (n.style.background) |color| {
            if (n.style.absolute and color.a == t.ctx.theme.accent.alpha(0.3).a and n.rect.w > 4)
                selected = true;
        }
    }
    try testing.expect(selected);
}

test "a bare multiline field clips nothing, so its caret shows whole" {
    var k: Bare = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Bare.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.frame();
    try testing.expectEqual(@as(usize, 1), carets(&t));
    for (t.instances.items) |inst| {
        if (inst.kind == gpu.Kind.quad and inst.rect[2] > 0 and inst.rect[2] <= 3 and inst.rect[3] > 5)
            try testing.expectEqual(@as(f32, 0), inst.clip_round);
    }
}

test "a multiline field's caret blinks while it has focus" {
    var k: Composer = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Composer.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.typeText("x");
    t.frame();
    try testing.expectEqual(@as(usize, 1), carets(&t));
    t.advance(0.6);
    try testing.expectEqual(@as(usize, 0), carets(&t));
    t.advance(0.5);
    try testing.expectEqual(@as(usize, 1), carets(&t));
}
