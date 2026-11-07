//! The GTK window's own tests: what `Options` asks of GTK, read back from
//! the GtkWindow. They need a display (CI runs them under Xvfb) and skip
//! without one. Drawn on the CPU, so no GL context is needed either.

const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const gtk = @import("gtk.zig");
const App = @import("app.zig").App;

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
