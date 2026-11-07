//! The Mac's accessibility elements (`a11y.zig`): their payloads, and the
//! roles AppKit is told for the shared tree's elements.
const std = @import("std");
const a11y = @import("a11y.zig");
const access = @import("access.zig");
const ui = @import("ui.zig");
const testing = std.testing;

test "label longer than 128 bytes survives" {
    const gpa = testing.allocator;
    var p: a11y.Payload = .{ .surface = undefined, .id = 1 };
    defer p.deinit(gpa);
    const long = "A page title that goes on and on, as titles of news articles and documentation pages do, well past what a fixed buffer of 128 bytes kept";
    try testing.expect(long.len > 128);
    p.update(gpa, .{ .id = 1, .role = .row, .label = long, .value = "v", .hint = "Opens it", .rect = .{} });
    try testing.expectEqualStrings(long, p.label);
    try testing.expectEqualStrings("v", p.value);
    try testing.expectEqualStrings("Opens it", p.hint);
    try testing.expectEqual(.row, p.role);
    // Updated in place, the old copies freed (the allocator checks).
    p.update(gpa, .{ .id = 1, .role = .row, .label = "short", .rect = .{} });
    try testing.expectEqualStrings("short", p.label);
    try testing.expectEqualStrings("", p.value);
}

const Page = struct {
    on: bool = false,
    fn view(s: *Page, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 8 });
        defer ui.end(c);
        ui.text(c, "Settings", .{ .size = 24 });
        ui.text(c, "Changes save as you go.", .{});
        _ = ui.checkbox(c, "Wi-Fi", &s.on);
        const card = ui.div(c).px(8).py(4).control();
        _ = card.clicked();
        ui.text(c, "Open the stop", .{});
        card.end();
    }
};

test "the Mac reads the same tree as iOS: headings, text, boxes that take clicks" {
    var s: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Page.view), .{});
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var list: std.ArrayList(access.Element) = .empty;
    try access.tree(&t.ctx, arena.allocator(), &list);
    var roles: std.ArrayList(u8) = .empty;
    for (list.items) |e| {
        try roles.appendSlice(arena.allocator(), a11y.roleName(e.role, e.header));
        try roles.appendSlice(arena.allocator(), " ");
    }
    try testing.expectEqualStrings("AXHeading AXStaticText AXCheckBox AXButton ", roles.items);
    try testing.expectEqualStrings("Open the stop", list.items[3].label);
}

test "input methods read the field's text by UTF-16 range" {
    const ti = @import("textinput.zig");
    const t = "ni 你好 ok";
    // "你好" is UTF-16 3..5, bytes 3..9.
    try testing.expectEqual([2]usize{ 3, 9 }, ti.clampRange(t, .{ .location = 3, .length = 2 }).?);
    // Past the end, cut to it.
    try testing.expectEqual([2]usize{ 10, 12 }, ti.clampRange(t, .{ .location = 6, .length = 99 }).?);
    try testing.expect(ti.clampRange(t, .{ .location = 10, .length = 1 }) == null);
}
