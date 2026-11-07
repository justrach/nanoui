//! A selection's handles (`handles.zig`), and how text selects under a finger:
//! a press doesn't select, since it may be a scroll; two taps do.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const handles = @import("handles.zig");
const gpu = @import("gpu.zig");

const Field = struct {
    buf: ui.TextBuffer = .{},
    multiline: bool = false,
    fn view(k: *@This(), c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10) });
        defer ui.end(c);
        c.focus = c.peekId(null);
        _ = ui.textField(c, &k.buf, .{ .width = .{ .px = 220 }, .multiline = k.multiline });
    }
};

const Page = struct {
    fn view(_: *@This(), c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10), .selectable = true, .width = .fill });
        defer ui.end(c);
        ui.text(c, "first words here", .{});
        ui.text(c, "second words there", .{});
    }
};

fn fieldWith(t: *ui.Tester, f: *Field, text: []const u8, anchor: usize, caret: usize) !void {
    try t.init(testing.allocator, .init(f, Field.view), .{ .width = 300, .height = 200 });
    _ = f.buf.replace(0, 0, text);
    f.buf.want_selection = .{ anchor, caret };
    t.frame();
    t.frame();
}

test "a field's selection has both ends, in order, wherever its caret is" {
    var f: Field = .{};
    defer f.buf.deinit();
    var t: ui.Tester = undefined;
    try fieldWith(&t, &f, "hello world", 11, 6);
    defer t.deinit();
    const e = handles.ends(&t.ctx).?;
    try testing.expect(e.start.?.x < e.end.?.x);
    try testing.expectEqual(e.start.?.y, e.end.?.y);
    try testing.expect(e.start.?.h > 0);
    // No selection, no handles.
    f.buf.want_selection = .{ 3, 3 };
    t.frame();
    t.frame();
    try testing.expect(handles.ends(&t.ctx) == null);
}

test "a multiline field's ends are on their own lines" {
    var f: Field = .{ .multiline = true };
    defer f.buf.deinit();
    var t: ui.Tester = undefined;
    try fieldWith(&t, &f, "one\ntwo\nthree", 1, 10);
    defer t.deinit();
    const e = handles.ends(&t.ctx).?;
    try testing.expect(e.end.?.y > e.start.?.y);
    try testing.expectEqual(@as(f32, 2) * e.start.?.h, e.end.?.y - e.start.?.y);
}

test "a finger takes the handle it's nearest, within Apple's target" {
    const e: handles.Ends = .{ .start = .{ .x = 100, .y = 50, .w = 0, .h = 20 }, .end = .{ .x = 130, .y = 50, .w = 0, .h = 20 } };
    try testing.expectEqual(handles.Which.start, handles.at(e, .{ .x = 110, .y = 60 }).?);
    try testing.expectEqual(handles.Which.end, handles.at(e, .{ .x = 120, .y = 60 }).?);
    try testing.expectEqual(handles.Which.start, handles.at(e, .{ .x = 80, .y = 40 }).?);
    try testing.expect(handles.at(e, .{ .x = 170, .y = 60 }) == null);
    try testing.expect(handles.at(e, .{ .x = 100, .y = 100 }) == null);
    // The grip is the line's middle, wherever the finger landed on it.
    try testing.expectEqual(types_y(handles.grip(e, .end).?), 60);
    // An end scrolled out of view can't be taken.
    try testing.expect(handles.at(.{ .end = e.end }, .{ .x = 100, .y = 60 }) == null);
}

fn types_y(p: anytype) f32 {
    return p.y;
}

test "the handles are painted: a bar and a knob at each end" {
    var f: Field = .{};
    defer f.buf.deinit();
    var t: ui.Tester = undefined;
    try fieldWith(&t, &f, "hello world", 0, 5);
    defer t.deinit();
    var out: std.ArrayList(gpu.Instance) = .empty;
    defer out.deinit(testing.allocator);
    handles.paint(testing.allocator, &out, &t.ctx);
    try testing.expectEqual(@as(usize, 4), out.items.len);
}

test "under a finger a press doesn't select, and two taps do" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    t.ctx.selection.touch = true;
    const at = t.findText("first words here").?;
    t.click(at.x + at.w / 2, at.y + at.h / 2);
    t.frame();
    try testing.expect(handles.ends(&t.ctx) == null);
    t.doubleClick(at.x + at.w / 2, at.y + at.h / 2);
    t.frame();
    const e = handles.ends(&t.ctx).?;
    try testing.expect(e.end.?.x > e.start.?.x);
    try testing.expectEqualStrings("words", t.ctx.selection.text.items);
    // Scrolling and other presses leave it; the platform lets it go on a tap.
    t.click(at.x + at.w / 2, at.y + at.h / 2);
    t.frame();
    try testing.expectEqualStrings("words", t.ctx.selection.text.items);
}

test "a finger still down doesn't pull a word's end back under it" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    t.ctx.selection.touch = true;
    const at = t.findText("first words here").?;
    t.moveTo(at.x + at.w / 2, at.y + at.h / 2);
    t.ctx.input.click_count = 2;
    t.ctx.pointerDown();
    t.frame();
    t.frame();
    t.frame();
    try testing.expectEqualStrings("words", t.ctx.selection.text.items);
    t.ctx.pointerUp();
    t.frame();
}

test "with a pointer, a press still starts a selection" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    const at = t.findText("first words here").?;
    t.drag(at.x + 1, at.y + at.h / 2, at.x + at.w / 2, at.y + at.h / 2);
    t.frame();
    try testing.expect(t.ctx.selection.text.items.len > 0);
}

test "a selection across texts has its ends in both" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 300, .height = 200 });
    defer t.deinit();
    const a = t.findText("first words here").?;
    const b = t.findText("second words there").?;
    t.drag(a.x + a.w / 2, a.y + a.h / 2, b.x + b.w / 2, b.y + b.h / 2);
    t.frame();
    const e = handles.ends(&t.ctx).?;
    try testing.expect(e.end.?.y > e.start.?.y);
}
