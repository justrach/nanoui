//! A context menu that knows where the mouse is heading: the submenu
//! "safe triangle". Toggle it to see a diagonal from Share toward its
//! submenu pass over Move to — with the triangle off, Move to opens; with
//! it on, Share stays until the pointer lands in the submenu.
//!
//!     zig build run-menu
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;

const share_sub = [_]kit.MenuItem{
    .{ .label = "Twitter", .icon = "globe" },
    .{ .label = "Instagram", .icon = "photo" },
    .{ .label = "Copy link", .icon = "paperclip" },
    .{ .label = "Email", .icon = "paperclip" },
};

const move_sub = [_]kit.MenuItem{
    .{ .label = "Documents", .icon = "folder" },
    .{ .label = "Desktop", .icon = "desktopcomputer" },
    .{ .label = "Downloads", .icon = "internaldrive" },
};

const items = [_]kit.MenuItem{
    .{ .label = "Share", .icon = "square.and.arrow.up", .submenu = &share_sub },
    .{ .label = "Move to", .icon = "folder", .submenu = &move_sub },
    .{ .separator = true },
    .{ .label = "Duplicate", .shortcut = "⌘D" },
    .{ .label = "Delete", .icon = "trash", .danger = true },
};

const Demo = struct {
    menu: bool = true,
    menu_at: ?ui.Rect = .{ .x = 56, .y = 168, .w = 220, .h = 36 },
    safe: bool = true,
    debug: bool = false,
    dark: bool = false,
    chosen: []const u8 = "",

    fn view(d: *Demo, c: *ui.Context) void {
        c.theme_chosen = if (d.dark) ui.Theme.dark_theme else ui.Theme.light;
        const th = c.theme;
        const root = ui.div(c).column().sizeFull().p(28).gap(16).bg(th.background);
        defer root.end();
        ui.text(c, "Safe triangle", .{ .size = 22, .weight = .bold });
        ui.text(c, "A context menu that knows where your mouse is heading.", .{ .size = 13, .color = th.muted, .wrap = true });
        {
            const r = ui.div(c).row().gap(20).itemsCenter();
            defer r.end();
            if (ui.toggle(c, "Safe triangle", &d.safe)) c.changed = true;
            if (ui.toggle(c, "Debug overlay", &d.debug)) c.changed = true;
            if (ui.toggle(c, "Dark", &d.dark)) c.changed = true;
        }
        ui.text(c, if (d.safe)
            "On: Share stays open while you aim at its submenu. Rest 300ms on a row to switch."
        else
            "Off: a diagonal over Move to closes Share and opens the wrong menu.", .{ .size = 12.5, .color = th.muted, .wrap = true });
        {
            const file = ui.div(c).row().gap(10).itemsCenter().px(12).h(36).w(220).rounded(8).bg(th.surface).border(th.border).control();
            defer file.end();
            ui.icon(c, "doc", .{ .size = 14, .color = th.muted });
            ui.text(c, "Quarterly.pdf", .{ .size = 13 });
            d.menu_at = file.interaction().rect;
            if (file.secondaryClicked() or file.clicked()) {
                d.menu = true;
                c.changed = true;
            }
        }
        if (d.chosen.len > 0) ui.text(c, c.print("Chose {s}", .{d.chosen}), .{ .size = 12.5, .color = th.muted });
        var chosen: []const u8 = d.chosen;
        if (kit.menu(c, "menu", &d.menu, d.menu_at, &items, .{
            .placement = .bottom_start,
            .width = 200,
            .safe_triangle = d.safe,
            .debug = d.debug,
            .chosen_id = &chosen,
        })) |_| {}
        if (chosen.len > 0) d.chosen = chosen;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Menu" });
    defer app.destroy();
    var state: Demo = .{};
    _ = try app.newWindow(.{
        .title = "Safe triangle",
        .width = 720,
        .height = 420,
        .theme = ui.Theme.light,
        .content = .{ .view = .init(&state, Demo.view) },
    });
    try app.run();
}
