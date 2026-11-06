//! The menu bar's part in ⌘W: AppKit offers keys to the menus first, so what's there
//! decides, whatever the view would have done.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("browser.zig").Browser;
const menu_bar = @import("menu_bar.zig");
const testing = std.testing;

test "⌘W is the tab's in the menu bar, and leaves the browser open" {
    var b: Browser = .{ .gpa = testing.allocator };
    try b.init();
    defer b.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, ui.View.init(&b, Browser.view), .{ .width = 900, .height = 600 });
    defer t.deinit();
    t.frame();
    const items = menu_bar.fileItems(&b);
    var item: nanoui.menu.Item = undefined;
    for (items) |it| {
        if (it.role == .close) try testing.expect(!std.mem.eql(u8, it.accelerator, menu_bar.close_tab_key));
    }
    try testing.expectEqualStrings("New Tab", items[0].label);
    items[0].click.?.func(items[0].click.?.ctx, &item);
    try testing.expectEqual(@as(usize, 2), b.tabs.items.len);
    try testing.expectEqualStrings(menu_bar.close_tab_key, items[1].accelerator);
    items[1].click.?.func(items[1].click.?.ctx, &item);
    try testing.expectEqual(@as(usize, 1), b.tabs.items.len);
    // The last tab goes to an empty one, not away.
    items[1].click.?.func(items[1].click.?.ctx, &item);
    try testing.expectEqual(@as(usize, 1), b.tabs.items.len);
    try testing.expect(b.tabs.items[0].isEmpty());
    t.frame();
}
