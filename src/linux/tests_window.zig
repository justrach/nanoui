//! The GTK window's own tests: what `Options` asks of GTK, read back from
//! the GtkWindow. They need a display (CI runs them under Xvfb) and skip
//! without one. Drawn on the CPU, so no GL context is needed either.

const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const gtk = @import("gtk.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;

const Page = struct {
    fn view(_: *Page, c: *ui.Context) void {
        ui.text(c, "window", .{});
    }
};

/// An app with GTK up, or a skip where there is no GTK or no display.
fn makeApp(gpa: std.mem.Allocator) !*App {
    if (!gtk.load()) return error.SkipZigTest;
    const ok = if (gtk.v4) gtk.v4api.gtk_init_check() else gtk.v3.gtk_init_check(null, null);
    if (ok == 0) return error.SkipZigTest;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = testing.io,
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
        .cpu_only = true,
    };
    return app;
}

test "decorations, skip_taskbar and opacity reach the GtkWindow" {
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    var p: Page = .{};
    const plain = try app.newWindow(.{ .title = "plain", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&p, Page.view) } });
    const bare = try app.newWindow(.{ .title = "bare", .width = 200, .height = 120, .visible = false, .decorations = false, .skip_taskbar = true, .opacity = 0.5, .content = .{ .view = .init(&p, Page.view) } });
    const g = &gtk.api;

    try testing.expect(g.gtk_window_get_decorated(plain.gtkwindow.?) != 0);
    try testing.expect(g.gtk_window_get_decorated(bare.gtkwindow.?) == 0);
    // GTK keeps opacity in 8 bits.
    try testing.expectApproxEqAbs(@as(f64, 0.5), g.gtk_widget_get_opacity(bare.gtkwindow.?), 0.01);
    bare.setOpacity(0.25);
    try testing.expectApproxEqAbs(@as(f64, 0.25), g.gtk_widget_get_opacity(bare.gtkwindow.?), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1), g.gtk_widget_get_opacity(plain.gtkwindow.?), 0.01);
    // GTK 4 has no taskbar hint to read; GTK 3 does.
    if (!gtk.v4) {
        try testing.expect(gtk.v3.gtk_window_get_skip_taskbar_hint(bare.gtkwindow.?) != 0);
        try testing.expect(gtk.v3.gtk_window_get_skip_taskbar_hint(plain.gtkwindow.?) == 0);
    }
    const m = bare.monitorSize();
    try testing.expect(m[0] > 0 and m[1] > 0);
}

const Themed = struct {
    chosen: ?ui.Theme = null,
    seen: ?ui.Theme = null,
    fn view(self: *Themed, c: *ui.Context) void {
        c.theme_chosen = self.chosen;
        self.seen = c.theme;
        ui.text(c, "themed", .{});
    }
};

test "the view's theme choice draws that theme" {
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    var p: Themed = .{ .chosen = ui.Theme.dark_theme };
    const w = try app.newWindow(.{ .title = "themed", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&p, Themed.view) } });
    const s = w.surface.?;
    // A hidden GtkWindow is never allocated: give the frame a size.
    s.size = .{ .w = 200, .h = 120 };
    s.frame();
    try testing.expect(p.seen.?.dark);

    p.chosen = ui.Theme.light;
    s.frame();
    try testing.expect(!p.seen.?.dark);

    p.chosen = null;
    s.frame();
    try testing.expect(p.seen != null);
}

test "should_close keeps window up until allowed and destroyNow tears down" {
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    const Gate = struct {
        allow: bool = false,
        asked: u32 = 0,
        closed: u32 = 0,
        fn should(ctx: *anyopaque, _: *Window) bool {
            const g: *@This() = @ptrCast(@alignCast(ctx));
            g.asked += 1;
            return g.allow;
        }
        fn onClose(ctx: *anyopaque, _: *Window) void {
            const g: *@This() = @ptrCast(@alignCast(ctx));
            g.closed += 1;
        }
        fn view(_: *@This(), c: *ui.Context) void {
            ui.text(c, "veto", .{});
        }
    };
    var g: Gate = .{};
    const w = try app.newWindow(.{
        .title = "veto",
        .width = 160,
        .height = 100,
        .visible = false,
        .should_close = .{ .ctx = &g, .func = Gate.should },
        .on_close = .{ .ctx = &g, .func = Gate.onClose },
        .content = .{ .view = .init(&g, Gate.view) },
    });
    w.close();
    try testing.expectEqual(@as(u32, 1), g.asked);
    try testing.expectEqual(@as(u32, 0), g.closed);
    try testing.expectEqual(@as(usize, 1), app.windows.items.len);
    // Final teardown via app.destroy uses destroyNow and bypasses the close veto.
    const w2 = try app.newWindow(.{
        .title = "veto-teardown",
        .width = 160,
        .height = 100,
        .visible = false,
        .should_close = .{ .ctx = &g, .func = Gate.should },
        .on_close = .{ .ctx = &g, .func = Gate.onClose },
        .content = .{ .view = .init(&g, Gate.view) },
    });
    g.allow = true;
    w.close();
    try testing.expectEqual(@as(u32, 2), g.asked);
    try testing.expectEqual(@as(u32, 1), g.closed);
    try testing.expectEqual(@as(usize, 1), app.windows.items.len);
    g.allow = false;
    _ = w2;
}

test "should_terminate keeps app running until allowed" {
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    const Gate = struct {
        allow: bool = false,
        asked: u32 = 0,
        fn should(ctx: ?*anyopaque) bool {
            const g: *@This() = @ptrCast(@alignCast(ctx.?));
            g.asked += 1;
            return g.allow;
        }
    };
    var g: Gate = .{};
    app.options.ctx = &g;
    app.options.should_terminate = Gate.should;
    app.quit();
    try testing.expectEqual(@as(u32, 1), g.asked);
    try testing.expect(!app.stopping);
    g.allow = true;
    app.quit();
    try testing.expectEqual(@as(u32, 2), g.asked);
    try testing.expect(app.stopping);
    app.quit();
    try testing.expectEqual(@as(u32, 2), g.asked);
}
