//! A text field's caret shape and color (`TextFieldOptions.caret`,
//! `caret_color`), in single-line and multiline fields alike.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Styled = struct {
    text: ui.TextBuffer = .{},
    multiline: bool = false,

    fn view(s: *Styled, c: *ui.Context) void {
        c.focus = c.peekId(null);
        _ = ui.textField(c, &s.text, .{ .multiline = s.multiline, .line_height = 22, .caret_color = .{ .r = 1 }, .caret = .{ .width = 3, .inset = 2, .radius = 1.5 } });
    }
};

test "a styled caret is a rounded bar inset from the line box, in its own color" {
    for ([_]bool{ false, true }) |multiline| {
        var s: Styled = .{ .multiline = multiline };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Styled.view), .{});
        defer t.deinit();
        var found = false;
        for (t.ctx.nodes.items) |n| {
            if (n.content != .none or !n.style.absolute or n.style.width != .px or n.style.width.px != 3) continue;
            try testing.expectEqual(@as(f32, 22 - 4), n.style.height.px);
            try testing.expectEqual(@as(f32, 1.5), n.style.radius);
            try testing.expectEqual(@as(f32, 2), n.style.offset.y);
            try testing.expectEqual(@as(f32, 1), n.style.background.?.r);
            found = true;
        }
        try testing.expect(found);
        try testing.expectEqual(@as(f32, 3), t.ctx.focused_text.?.caret_rect.w);
    }
}

test "the default caret stays a 1.5-point line in the accent" {
    var s: struct {
        text: ui.TextBuffer = .{},
        fn view(x: *@This(), c: *ui.Context) void {
            c.focus = c.peekId(null);
            _ = ui.textField(c, &x.text, .{});
        }
    } = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, @TypeOf(s).view), .{});
    defer t.deinit();
    var found = false;
    for (t.ctx.nodes.items) |n| {
        if (n.content == .none and n.style.absolute and n.style.width == .px and n.style.width.px == 1.5 and n.style.radius == 0) found = true;
    }
    try testing.expect(found);
}
