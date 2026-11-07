//! A multiline text field, as Harness's composer: text wraps at the field's
//! width and the field grows with it, Shift-Return starts a line and
//! Return still submits, ↑ and ↓ move between the lines (an app takes them
//! on the first and last), a click lands on the line under it, and past
//! its most lines the field scrolls, by the caret and by the wheel.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

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

test "the caret moves as a space is typed, and the next character after it" {
    var k: Composer = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Composer.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    t.settle(1);
    t.typeText("ab");
    const two = t.ctx.focused_text.?.caret_rect.x;
    t.typeText(" ");
    // A trailing space isn't drawn, but the caret still moves past it.
    const spaced = t.ctx.focused_text.?.caret_rect.x;
    try testing.expect(spaced > two + 1);
    t.typeText("c");
    const three = t.ctx.focused_text.?.caret_rect.x;
    try testing.expect(three > spaced + 1);
    try testing.expectEqualStrings("ab c", k.buf.text());
}
