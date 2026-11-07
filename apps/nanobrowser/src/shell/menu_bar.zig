//! The Mac's menu bar. AppKit offers a key to the menus before any view hears it, so
//! the framework's default "Close Window" on ⌘W closed the whole browser, however
//! many tabs it had. Here ⌘W is the tab's, as in other browsers.
const nanoui = @import("nanoui");
const Browser = @import("browser.zig").Browser;

const MenuItem = nanoui.MenuItem;

pub const close_tab_key = "CmdOrCtrl+W";

fn newTab(b: *Browser, _: *nanoui.menu.Item) void {
    b.newTab(null) catch {};
    Browser.redrawn(b);
}

fn closeTab(b: *Browser, _: *nanoui.menu.Item) void {
    b.closeCurrentTab();
    Browser.redrawn(b);
}

pub fn fileItems(b: *Browser) [4]MenuItem {
    return .{
        .{ .label = "New Tab", .accelerator = "CmdOrCtrl+T", .click = .of(b, newTab) },
        .{ .label = "Close Tab", .accelerator = close_tab_key, .click = .of(b, closeTab) },
        .{ .is_separator = true },
        .{ .role = .close, .accelerator = "CmdOrCtrl+Shift+W" },
    };
}

/// `.window_menu` isn't used: it holds the Close Window on ⌘W this is here to replace.
pub fn install(app: *nanoui.App, b: *Browser) !void {
    const file = fileItems(b);
    const window = [_]MenuItem{ .{ .role = .minimize }, .{ .role = .zoom }, .{ .is_separator = true }, .{ .role = .front } };
    try app.setMenu(&.{
        .{ .role = .app_menu },
        .{ .label = "File", .submenu = &file },
        .{ .role = .edit_menu },
        .{ .role = .view_menu },
        .{ .label = "Window", .submenu = &window },
    });
}
