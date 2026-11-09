//! A text field's own keys: the ones no input method sends, where Control
//! (Option, as on the Mac) with ←, →, Delete and Backspace works a word at a
//! time and Shift extends the selection (`textfield_keys.zig`).
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Field = struct {
    name: ui.TextBuffer = .{},
    fn view(s: *Field, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        _ = ui.textField(c, &s.name, .{ .placeholder = "Name" });
    }
};

test "Control works a word at a time, in a text field" {
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();

    try t.clickText("Name");
    t.typeText("hello brave world");
    // A plain Backspace is still one letter.
    t.key(.backspace);
    try testing.expectEqualStrings("hello brave worl", s.name.text());

    t.setMods(.{ .ctrl = true });
    t.key(.backspace); // the word before the caret
    try testing.expectEqualStrings("hello brave ", s.name.text());
    t.key(.backspace);
    try testing.expectEqualStrings("hello ", s.name.text());

    // ← goes a word back, and → a word forward; Shift extends the selection.
    t.key(.left);
    try testing.expectEqual(@as(usize, 0), t.ctx.focused_text.?.caret);
    t.key(.right);
    t.key(.right);
    try testing.expectEqual(@as(usize, 6), t.ctx.focused_text.?.caret);
    t.key(.left);
    t.setMods(.{ .ctrl = true, .shift = true });
    t.key(.right);
    try testing.expectEqual(@as(usize, 0), t.ctx.focused_text.?.anchor);
    try testing.expectEqual(@as(usize, 5), t.ctx.focused_text.?.caret);

    // Delete goes forward a word, over the selection when there is one.
    t.setMods(.{ .ctrl = true });
    t.key(.delete); // "hello " cut to nothing, the selection first
    try testing.expectEqualStrings(" ", s.name.text());
    t.setMods(.{});

    // Option (Alt) means the same, as it does on the Mac.
    s.name.set("one two");
    t.frame();
    t.setMods(.{ .alt = true });
    t.key(.backspace);
    try testing.expectEqualStrings("one ", s.name.text());
    t.setMods(.{});
}
