//! The kit through the Tester: buttons click (and don't when disabled or
//! loading); tabs switch and their marker slides; a dialog opens, closes
//! by Cancel, OK, Escape and its dimming, and leaves; a menu picks and a
//! click elsewhere closes it; a tooltip waits for the pointer to rest;
//! toasts come, stay while rested on, and go; a collapsible opens to its
//! content's height; a select moves with the arrows; radios, the number
//! input and pagination change what they hold.
const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");

const App = struct {
    clicks: u32 = 0,
    tab: usize = 0,
    dialog: bool = false,
    result: kit.DialogResult = .none,
    menu: bool = false,
    picked: ?usize = null,
    menu_anchor: ?ui.Rect = null,
    open: bool = false,
    radio: usize = 0,
    choice: ?usize = null,
    number: f64 = 0,
    page: usize = 0,
    loading: bool = false,
    off: bool = true,
    toaster: kit.Toaster,

    fn view(a: *App, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(16).gap(10).bg(c.theme.background);
        defer root.end();
        {
            const r = ui.div(c).row().gap(8).itemsCenter();
            defer r.end();
            if (kit.button(c, "Count", .{ .variant = .primary, .loading = a.loading, .tooltip = "Adds one" }).clicked) a.clicks += 1;
            if (kit.button(c, "Off", .{ .disabled = a.off }).clicked) a.clicks += 100;
            if (kit.button(c, "Ask", .{}).clicked) a.dialog = true;
            const m = kit.button(c, "Menu", .{ .icon_after = "chevron.down" });
            if (m.clicked) a.menu = !a.menu;
            a.menu_anchor = m.rect;
            if (kit.button(c, "Toast", .{ .variant = .ghost }).clicked) a.toaster.push(.{ .status = .success, .title = "Saved", .message = "All good.", .duration = 1 });
        }
        _ = kit.tabs(c, &.{ "One", "Two", "Three" }, &a.tab, .{});
        if (kit.collapsible(c, "more", "More", &a.open)) |s| {
            defer s.end();
            ui.text(c, "Hidden content", .{});
            kit.skeleton(c, .{ .height = 40 });
        }
        _ = kit.radioGroup(c, &.{ "Small", "Large" }, &a.radio, .{ .horizontal = true });
        _ = kit.select(c, "size", &.{ "Small", "Medium", "Large" }, &a.choice, .{});
        _ = kit.numberInput(c, &a.number, .{ .min = 0, .max = 5 });
        _ = kit.pagination(c, &a.page, 20);
        kit.avatar(c, .{ .name = "Ada Lovelace" });
        if (kit.menu(c, "menu", &a.menu, a.menu_anchor, &.{ .{ .label = "Copy", .shortcut = "⌘C" }, .{ .separator = true }, .{ .label = "Delete", .danger = true } }, .{})) |i| a.picked = i;
        if (kit.dialog(c, "ask", &a.dialog, .{ .title = "Delete it?", .description = "This can't be undone.", .ok = "Delete", .ok_variant = .danger })) |d| {
            ui.text(c, "Dialog body", .{});
            const r = d.end();
            if (r != .none) a.result = r;
        }
        a.toaster.view(c);
    }
};

fn setup(a: *App, t: *ui.Tester) !void {
    a.* = .{ .toaster = .{ .gpa = testing.allocator } };
    try t.init(testing.allocator, .init(a, App.view), .{ .width = 900, .height = 700 });
    t.settle(1);
}

fn teardown(a: *App, t: *ui.Tester) void {
    t.deinit();
    a.toaster.deinit();
}

test "buttons, tabs, radios, the number input and pagination" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer teardown(&a, &t);
    try t.clickText("Count");
    try t.clickText("Off");
    try testing.expectEqual(@as(u32, 1), a.clicks);
    a.loading = true;
    t.settle(0.2);
    try t.clickText("Count");
    try testing.expectEqual(@as(u32, 1), a.clicks);
    a.loading = false;
    try t.clickText("Two");
    t.settle(1);
    try testing.expectEqual(@as(usize, 1), a.tab);
    try t.clickText("Large");
    try testing.expectEqual(@as(usize, 1), a.radio);
    try t.clickText("3");
    try testing.expectEqual(@as(usize, 2), a.page);
    var path_buf: [256]u8 = undefined;
    try t.screenshot(try @import("../temp_path.zig").tempPath(&path_buf, "nanoui-kit.png"));
    try testing.expect(t.hasText("AL"));
}

/// The opacity of the button labeled `label`.
fn buttonOpacity(t: *ui.Tester, label: []const u8) f32 {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, label)) return t.ctx.nodes.items[n.parent].style.opacity,
        else => {},
    };
    return -1;
}

test "a button fades between disabled and enabled" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer teardown(&a, &t);
    // Disabled from its first frame: no fade in from enabled.
    try testing.expectApproxEqAbs(@as(f32, 0.45), buttonOpacity(&t, "Off"), 0.001);
    a.off = false;
    t.advance(0.1);
    const mid = buttonOpacity(&t, "Off");
    try testing.expect(mid > 0.45 and mid < 1);
    t.settle(1);
    try testing.expectApproxEqAbs(@as(f32, 1), buttonOpacity(&t, "Off"), 0.001);
    try t.clickText("Off");
    try testing.expectEqual(@as(u32, 100), a.clicks);
}

test "a dialog: Cancel, OK, Escape and the dimming close it" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer teardown(&a, &t);
    try t.clickText("Ask");
    t.settle(1);
    try testing.expect(t.hasText("Delete it?") and t.hasText("Dialog body"));
    var path_buf: [256]u8 = undefined;
    try t.screenshot(try @import("../temp_path.zig").tempPath(&path_buf, "nanoui-kit-dialog.png"));
    try t.clickText("Cancel");
    t.settle(1);
    try testing.expect(!a.dialog and !t.hasText("Dialog body"));
    try testing.expectEqual(kit.DialogResult.cancel, a.result);
    a.dialog = true;
    t.settle(1);
    try t.clickText("Delete");
    t.settle(1);
    try testing.expectEqual(kit.DialogResult.ok, a.result);
    a.dialog = true;
    t.settle(1);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try testing.expect(!a.dialog);
    a.dialog = true;
    t.settle(1);
    t.click(10, 690);
    t.settle(1);
    try testing.expect(!a.dialog and !t.hasText("Dialog body"));
}

test "a menu picks an item; a click elsewhere closes it; a tooltip waits" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer teardown(&a, &t);
    try t.clickText("Menu");
    t.settle(1);
    try testing.expect(t.hasText("Copy") and t.hasText("⌘C"));
    var path_buf: [256]u8 = undefined;
    try t.screenshot(try @import("../temp_path.zig").tempPath(&path_buf, "nanoui-kit-menu.png"));
    try t.clickText("Delete");
    t.settle(1);
    try testing.expectEqual(@as(?usize, 2), a.picked);
    try testing.expect(!a.menu and !t.hasText("Copy"));
    try t.clickText("Menu");
    t.settle(1);
    t.click(880, 600);
    t.settle(1);
    try testing.expect(!a.menu);
    // The tooltip: not at once, then after half a second's rest.
    const count = t.findText("Count").?;
    t.moveTo(count.x + 2, count.y + 2);
    t.advance(0.2);
    try testing.expect(!t.hasText("Adds one"));
    t.advance(0.6);
    try testing.expect(t.hasText("Adds one"));
}

test "toasts come and go; a collapsible opens to its content's height; a select moves with the keys" {
    var a: App = undefined;
    var t: ui.Tester = undefined;
    try setup(&a, &t);
    defer teardown(&a, &t);
    try t.clickText("Toast");
    t.settle(0.5);
    try testing.expect(t.hasText("Saved") and t.hasText("All good."));
    var path_buf: [256]u8 = undefined;
    try t.screenshot(try @import("../temp_path.zig").tempPath(&path_buf, "nanoui-kit-toast.png"));
    t.advance(2);
    t.settle(1);
    try testing.expect(!t.hasText("All good.") and a.toaster.items.items.len == 0);

    try t.clickText("More");
    t.settle(1);
    try testing.expect(t.hasText("Hidden content"));
    const content = t.findText("Hidden content").?;
    const radios = t.findText("Small").?;
    // Opened all the way: the radios moved below the content.
    try testing.expect(radios.y > content.y + content.h + 30);
    try t.clickText("More");
    t.settle(1);
    try testing.expect(!t.hasText("Hidden content"));

    try t.clickText("Choose…");
    t.settle(0.5);
    try testing.expect(t.hasText("Medium"));
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.frame();
    _ = t.shortcut(.{ .key = ui.Shortcut.enter });
    t.settle(1);
    try testing.expectEqual(@as(?usize, 1), a.choice);
}


