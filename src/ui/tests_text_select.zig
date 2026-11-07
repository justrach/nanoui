//! A selection set from outside a field (`TextOp.select`): iOS's text
//! input sets it, then replaces it, for autocorrect and dictation.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Field = struct {
    buf: ui.TextBuffer = .{},
    fn view(s: *Field, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20) });
        defer ui.end(c);
        _ = ui.textField(c, &s.buf, .{ .placeholder = "Type", .width = .{ .px = 200 } });
    }
};

test "a selection set from outside is replaced by what is typed next" {
    var s: Field = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");
    t.textOps(&.{.{ .insert = "teh cat" }});
    // Autocorrect: select "teh", then type its correction over it.
    t.textOps(&.{ .{ .select = .{ .anchor = 0, .caret = 3 } }, .{ .insert = "the" } });
    try testing.expectEqualStrings("the cat", s.buf.text());
    const f = t.ctx.focused_text.?;
    try testing.expectEqual(@as(usize, 3), f.caret);
    try testing.expectEqual(f.caret, f.anchor);
    // Past the end, it stops at the end.
    t.textOps(&.{.{ .select = .{ .anchor = 99, .caret = 99 } }});
    try testing.expectEqual(@as(usize, 7), t.ctx.focused_text.?.caret);
}

test "pinyin composes in marked text, then commits its characters" {
    var s: Field = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");
    t.textOps(&.{.{ .insert = "说" }});
    // What iOS's pinyin keyboard sends for n, i, h, a, o, then 你好.
    for ([_][]const u8{ "n", "ni", "ni h", "ni ha", "ni hao" }) |m|
        t.textOps(&.{.{ .set_marked = .{ .text = m, .sel_start = m.len, .sel_len = 0 } }});
    const f = t.ctx.focused_text.?;
    try testing.expectEqualStrings("说ni hao", f.text);
    try testing.expectEqual([2]usize{ 3, 9 }, f.marked.?);
    t.textOps(&.{.{ .insert = "你好" }});
    try testing.expectEqualStrings("说你好", s.buf.text());
    try testing.expect(t.ctx.focused_text.?.marked == null);
}

const Tall = struct {
    buf: ui.TextBuffer = .{},
    /// What the keyboard covers: the page above it shrinks, as iOS's does.
    kb: f32 = 0,
    fn view(s: *Tall, c: *ui.Context) void {
        _ = c.open(.{ .direction = .column, .width = .fill, .height = .fill, .padding = .{ .bottom = s.kb } }, null);
        defer ui.end(c);
        _ = c.open(.{ .scroll = true, .direction = .column, .width = .fill, .height = .fill }, "page");
        defer ui.end(c);
        _ = c.open(.{ .height = .{ .px = 500 } }, null);
        ui.end(c);
        _ = ui.textField(c, &s.buf, .{ .placeholder = "Type", .width = .{ .px = 200 } });
    }
};

test "the keyboard coming up scrolls the field's caret above it" {
    var s: Tall = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Tall.view), .{ .width = 300, .height = 600 });
    defer t.deinit();
    try t.clickText("Type");
    // A keyboard over the bottom 300 points: the caret moves above y 300.
    s.kb = 300;
    t.frame();
    try testing.expect(@import("scroll.zig").revealCaret(&t.ctx, 300));
    // The caret's place comes from the frame before's layout.
    t.frame();
    t.frame();
    const r = t.ctx.focused_text.?.caret_rect;
    try testing.expect(r.y + r.h <= 300 and r.y > 0);
    // Already above it: nothing to do.
    try testing.expect(!@import("scroll.zig").revealCaret(&t.ctx, 300));
}
