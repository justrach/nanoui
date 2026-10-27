//! Font weight must affect a field's drawing and its editing geometry alike.
const std = @import("std");
const ui = @import("ui.zig");

const State = struct {
    buffer: ui.TextBuffer = .{},
    multiline: bool,
    caret: usize = 0,
};

fn view(s: *State, c: *ui.Context) void {
    s.caret = ui.textField(c, &s.buffer, .{
        .size = 14,
        .weight = .medium,
        .bare = true,
        .multiline = s.multiline,
        .width = .{ .px = 320 },
    }).caret;
}

test "weighted text fields draw and edit the same face in single and multiline mode" {
    for ([_]bool{ false, true }) |multiline| {
        var s: State = .{ .multiline = multiline };
        s.buffer.set("iiiiiiii WWWWWWWW");
        var t: ui.Tester = undefined;
        try t.init(std.testing.allocator, .init(&s, view), .{ .width = 400, .height = 160 });
        defer t.deinit();
        const rect = t.findText(s.buffer.text()) orelse return error.MissingFieldText;
        const prefix = "iiiiiiii";
        const width = t.text.width(prefix, .{ .size = 14, .weight = .medium });
        t.click(rect.x + width, rect.y + rect.h / 2);
        t.settle(0.1);
        try std.testing.expectEqual(prefix.len, s.caret);
        t.typeText("X");
        try std.testing.expectEqualStrings("iiiiiiiiX WWWWWWWW", s.buffer.text());
        const weight = for (t.ctx.nodes.items) |node| {
            if (node.content == .text and std.mem.eql(u8, node.content.text.str, s.buffer.text()))
                break node.content.text.style.weight;
        } else return error.MissingEditedText;
        try std.testing.expectEqual(ui.Weight.medium, weight);
    }
}
