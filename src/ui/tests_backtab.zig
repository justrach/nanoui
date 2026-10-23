//! ⇧Tab in a focused text field reaches the view as a Tab shortcut with Shift.
const std = @import("std");
const ui = @import("ui.zig");
const input = @import("input.zig");
const testing = std.testing;

const Field = struct {
    buf: ui.TextBuffer = .{},
    back: u32 = 0,
    fn view(s: *Field, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20) });
        defer ui.end(c);
        _ = ui.textField(c, &s.buf, .{ .placeholder = "Address" });
        if (c.shortcut(.{ .key = '\t', .shift = true })) s.back += 1;
    }
};

test "shift-tab is offered as tab with shift" {
    try testing.expectEqual(@as(u21, '\t'), input.Shortcut.keyOf(0x19));
    try testing.expectEqual(@as(u21, 'a'), input.Shortcut.keyOf('A'));
    var s: Field = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Address");
    try testing.expect(!t.shortcut(.{ .key = '\t' }));
    try testing.expect(t.shortcut(.{ .key = input.Shortcut.keyOf(0x19), .shift = true }));
    try testing.expectEqual(@as(u32, 1), s.back);
}
