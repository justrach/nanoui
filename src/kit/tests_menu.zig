//! Submenus and the safe triangle, through the Tester: a diagonal move
//! from Share toward its submenu keeps Share on the default, opens Move
//! to when the flag is off, and falls through after the idle timeout.
const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");

const share_sub = [_]kit.MenuItem{
    .{ .label = "Twitter", .id = "twitter" },
    .{ .label = "Instagram", .id = "instagram" },
    .{ .label = "Copy link", .id = "copy-link" },
    .{ .label = "Email", .id = "email" },
};

const move_sub = [_]kit.MenuItem{
    .{ .label = "Documents", .id = "documents" },
    .{ .label = "Desktop", .id = "desktop" },
    .{ .label = "Downloads", .id = "downloads" },
};

const items = [_]kit.MenuItem{
    .{ .label = "Share", .icon = "square.and.arrow.up", .submenu = &share_sub },
    .{ .label = "Move to", .icon = "folder", .submenu = &move_sub },
    .{ .separator = true },
    .{ .label = "Duplicate", .shortcut = "⌘D" },
    .{ .label = "Delete", .icon = "trash", .danger = true },
};

const App = struct {
    menu: bool = true,
    menu_at: ?ui.Rect = .{ .x = 48, .y = 72, .w = 120, .h = 28 },
    /// `null` uses `MenuOptions.safe_triangle`'s default (on).
    safe: ?bool = null,
    debug: bool = false,
    picked: ?usize = null,
    chosen_id: []const u8 = "",

    fn view(a: *App, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(24).gap(12).bg(c.theme.background);
        defer root.end();
        ui.text(c, "Context menu", .{ .size = 18, .weight = .semibold });
        const on = a.safe orelse true;
        ui.text(c, if (on) "Safe triangle on" else "Safe triangle off", .{ .color = c.theme.muted });
        var opts: kit.MenuOptions = .{
            .placement = .bottom_start,
            .width = 200,
            .debug = a.debug,
            .chosen_id = &a.chosen_id,
        };
        if (a.safe) |v| opts.safe_triangle = v;
        if (kit.menu(c, "menu", &a.menu, a.menu_at, &items, opts)) |i| a.picked = i;
    }
};

fn setup(a: *App, t: *ui.Tester, dark: bool) !void {
    a.* = .{ .safe = a.safe, .debug = a.debug };
    try t.init(testing.allocator, .init(a, App.view), .{ .width = 720, .height = 420, .dark = dark });
    t.settle(1);
}

fn teardown(_: *App, t: *ui.Tester) void {
    t.deinit();
}

fn openShare(t: *ui.Tester) !void {
    try t.hoverText("Share");
    t.settle(0.6);
    try testing.expect(t.hasText("Twitter"));
}

/// Walk from Share toward the submenu, landing on Move to (still left of
/// the submenu) so a hold keeps Share and a release opens Move to.
fn diagonalAcrossMoveTo(t: *ui.Tester) !void {
    try openShare(t);
    const share = t.findText("Share").?;
    const move = t.findText("Move to").?;
    const twitter = t.findText("Twitter") orelse return error.SubmenuNotOpen;
    const x0 = share.x + share.w * 0.8;
    const y0 = share.y + share.h / 2;
    const x1 = @min(move.x + move.w + 36, twitter.x - 8);
    const y1 = move.y + move.h / 2;
    const steps: f32 = 10;
    var i: f32 = 1;
    while (i <= steps) : (i += 1) {
        t.move(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps);
    }
}

test "a submenu opens on hover; a leaf pick closes the menu" {
    var a: App = .{};
    var t: ui.Tester = undefined;
    try setup(&a, &t, false);
    defer teardown(&a, &t);
    try testing.expect(t.hasText("Share") and t.hasText("Move to"));
    try openShare(&t);
    try testing.expect(t.hasText("Email"));
    try t.clickText("Twitter");
    t.settle(1);
    try testing.expectEqualStrings("twitter", a.chosen_id);
    try testing.expect(!a.menu);
    try testing.expect(!t.hasText("Twitter"));
}

test "MenuOptions.safe_triangle defaults on; debug stays off" {
    const opts: kit.MenuOptions = .{};
    try testing.expect(opts.safe_triangle);
    try testing.expect(!opts.debug);
}

test "without the safe triangle a diagonal move opens the wrong submenu" {
    var a: App = .{ .safe = false };
    var t: ui.Tester = undefined;
    try setup(&a, &t, false);
    defer teardown(&a, &t);
    try diagonalAcrossMoveTo(&t);
    try testing.expect(t.hasText("Documents"));
    try testing.expect(!t.hasText("Twitter"));
}

test "the default keeps Share open on a diagonal move" {
    var a: App = .{};
    var t: ui.Tester = undefined;
    try setup(&a, &t, false);
    defer teardown(&a, &t);
    try diagonalAcrossMoveTo(&t);
    try testing.expect(t.hasText("Twitter"));
    try testing.expect(!t.hasText("Documents"));
}

test "idling in the triangle falls through to the row under the pointer" {
    var a: App = .{};
    var t: ui.Tester = undefined;
    try setup(&a, &t, false);
    defer teardown(&a, &t);
    try diagonalAcrossMoveTo(&t);
    try testing.expect(t.hasText("Twitter"));
    t.advance(0.35);
    t.frame();
    try testing.expect(t.hasText("Documents"));
    try testing.expect(!t.hasText("Twitter"));
}

test "no submenu opens without a hover" {
    var a: App = .{};
    var t: ui.Tester = undefined;
    try setup(&a, &t, false);
    defer teardown(&a, &t);
    try testing.expect(t.hasText("Share"));
    try testing.expect(!t.hasText("Twitter") and !t.hasText("Documents"));
}

fn shot(t: *ui.Tester, name: []const u8) !void {
    var tmp: [256]u8 = undefined;
    try t.screenshot(try @import("../temp_path.zig").tempPath(&tmp, name));
    var art: [256]u8 = undefined;
    const dest = std.fmt.bufPrint(&art, "/opt/cursor/artifacts/{s}", .{name}) catch return;
    t.screenshot(dest) catch {};
}

test "screenshots: before and after, light and dark, overlay on" {
    var a: App = .{};
    var t: ui.Tester = undefined;

    a.safe = false;
    a.debug = false;
    try setup(&a, &t, false);
    try diagonalAcrossMoveTo(&t);
    t.settle(0.5);
    try shot(&t, "menu-off-light.png");
    t.deinit();

    a = .{ .safe = false, .debug = false };
    try t.init(testing.allocator, .init(&a, App.view), .{ .width = 720, .height = 420, .dark = true });
    t.settle(1);
    try diagonalAcrossMoveTo(&t);
    t.settle(0.5);
    try shot(&t, "menu-off-dark.png");
    t.deinit();

    a = .{};
    try t.init(testing.allocator, .init(&a, App.view), .{ .width = 720, .height = 420, .dark = false });
    t.settle(1);
    try diagonalAcrossMoveTo(&t);
    try shot(&t, "menu-on-light.png");
    t.deinit();

    a = .{};
    try t.init(testing.allocator, .init(&a, App.view), .{ .width = 720, .height = 420, .dark = true });
    t.settle(1);
    try diagonalAcrossMoveTo(&t);
    try shot(&t, "menu-on-dark.png");
    t.deinit();

    a = .{ .debug = true };
    try t.init(testing.allocator, .init(&a, App.view), .{ .width = 720, .height = 420, .dark = false });
    t.settle(1);
    try diagonalAcrossMoveTo(&t);
    try shot(&t, "menu-on-debug-light.png");
    t.deinit();

    a = .{ .debug = true };
    try t.init(testing.allocator, .init(&a, App.view), .{ .width = 720, .height = 420, .dark = true });
    t.settle(1);
    try diagonalAcrossMoveTo(&t);
    try shot(&t, "menu-on-debug-dark.png");
    t.deinit();
}

test "frame sequence of a diagonal move with the overlay on" {
    var a: App = .{ .debug = true };
    var t: ui.Tester = undefined;
    try setup(&a, &t, false);
    defer teardown(&a, &t);
    try openShare(&t);
    const share = t.findText("Share").?;
    const email = t.findText("Email").?;
    const x0 = share.x + share.w / 2;
    const y0 = share.y + share.h / 2;
    const x1 = email.x + email.w / 2;
    const y1 = email.y + email.h / 2;
    try shot(&t, "menu-diag-0.png");
    const marks = [_]f32{ 0.25, 0.5, 0.75, 1.0 };
    for (marks, 1..) |u, i| {
        t.move(x0 + (x1 - x0) * u, y0 + (y1 - y0) * u);
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "menu-diag-{d}.png", .{i});
        try shot(&t, name);
    }
    try testing.expect(t.hasText("Twitter"));
}
