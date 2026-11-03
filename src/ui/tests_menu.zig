//! Menus built and rebuilt without the app running (macOS): lazy
//! submenus, filled when they open.
const std = @import("std");
const objc = @import("../objc.zig");
const menu = @import("../menu.zig");
const testing = std.testing;

fn titleAt(m: objc.Object, i: usize) []const u8 {
    const it = objc.msg(objc.Object, m, "itemAtIndex:", .{@as(objc.NSInteger, @intCast(i))});
    return objc.fromNSString(objc.msg(?objc.Object, it, "title", .{}));
}

fn count(m: objc.Object) usize {
    return @intCast(objc.msg(objc.NSInteger, m, "numberOfItems", .{}));
}

test "setSubmenu replaces children" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const m = try menu.Menu.create(testing.allocator, "Test", &.{
        .{ .label = "Bookmarks", .id = "marks", .submenu = &.{
            .{ .label = "A", .id = "a" },
            .{ .label = "Folder", .id = "folder", .submenu = &.{.{ .label = "Deep", .id = "deep" }} },
        } },
        .{ .label = "Other", .id = "other" },
    });
    defer m.destroy();
    const marks = m.item("marks").?;
    try testing.expect(m.item("deep") != null);
    try marks.setSubmenu(&.{ .{ .label = "C", .id = "c" }, .separator, .{ .label = "D", .id = "d", .image_symbol = "star" } });
    const sub = marks.submenu.?;
    try testing.expectEqual(@as(usize, 3), count(sub));
    try testing.expectEqualStrings("C", titleAt(sub, 0));
    try testing.expectEqualStrings("D", titleAt(sub, 2));
    // The old items are gone, however deep; the others stay.
    try testing.expect(m.item("a") == null and m.item("folder") == null and m.item("deep") == null);
    try testing.expect(m.item("c") != null and m.item("other") != null);
    try testing.expectEqual(@as(usize, 4), m.items.items.len); // marks, other, c, d
}

const Opened = struct {
    n: u32 = 0,
    fn fill(s: *Opened, it: *menu.Item) void {
        s.n += 1;
        it.setSubmenu(&.{.{ .label = "Recent", .id = "recent" }}) catch {};
    }
};

test "on_open fills the submenu before it shows" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var opened: Opened = .{};
    const m = try menu.Menu.create(testing.allocator, "Test", &.{
        .{ .label = "History", .id = "history", .submenu = &.{}, .on_open = .of(&opened, Opened.fill) },
    });
    defer m.destroy();
    const sub = m.item("history").?.submenu.?;
    // AppKit asks the menu's delegate as it opens.
    const delegate = objc.msg(objc.Object, sub, "delegate", .{});
    objc.msg(void, delegate, "menuNeedsUpdate:", .{sub});
    try testing.expectEqual(@as(u32, 1), opened.n);
    try testing.expectEqualStrings("Recent", titleAt(sub, 0));
    m.item("recent").?.setAccelerator("Cmd+Shift+H");
    const ns = m.item("recent").?.ns;
    try testing.expectEqualStrings("h", objc.fromNSString(objc.msg(?objc.Object, ns, "keyEquivalent", .{})));
}
