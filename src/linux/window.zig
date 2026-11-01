//! Windows on Linux: a GtkWindow (GTK 4's, else GTK 3's) showing native UI
//! drawn by nanoui. GTK 4 doesn't place windows (Wayland leaves that to
//! the compositor): positions are GTK 3's. Pages (WebKitGTK) are not
//! supported yet.
const std = @import("std");
const gtk = @import("gtk.zig");
const App = @import("app.zig").App;
const Surface = @import("surface.zig").Surface;
const window_types = @import("../window_types.zig");
const ui = @import("../ui/ui.zig");

pub const Asset = window_types.Asset;
pub const PageOptions = window_types.PageOptions;
pub const Content = window_types.Content;
pub const TitleBar = window_types.TitleBar;
pub const Callback = window_types.Callback(Window);
pub const Options = window_types.Options(Window);

pub const NativeView = window_types.NativeView;

pub const Frame = struct { x: f64, y: f64, width: f64, height: f64 };

pub const Window = struct {
    app: *App,
    /// Null when headless (snapshots without a display).
    gtkwindow: ?*gtk.Widget,
    surface: ?*Surface = null,
    /// What a snapshot draws: the view, the window's size, its colors.
    view: ?ui.View = null,
    width: f64 = 0,
    height: f64 = 0,
    theme: ?ui.Theme = null,
    title_bar: TitleBar = .default,
    on_close: ?Callback = null,
    closed: bool = false,
    full_screen: bool = false,
    title: [256:0]u8 = @splat(0),

    pub fn create(app: *App, options: Options) !*Window {
        const g = &gtk.api;
        const self = try app.gpa.create(Window);
        errdefer app.gpa.destroy(self);
        self.* = .{ .app = app, .gtkwindow = null, .title_bar = options.title_bar, .on_close = options.on_close, .width = options.width, .height = options.height, .theme = options.theme };
        switch (options.content) {
            .page => return error.PagesUnsupported,
            .view => |v| self.view = v,
        }
        if (!app.gui) return self;
        const win = if (gtk.v4) gtk.v4api.gtk_window_new() else gtk.v3.gtk_window_new(0);
        self.gtkwindow = win;
        self.setTitle(options.title);
        g.gtk_window_set_default_size(win, @intFromFloat(options.width), @intFromFloat(options.height));
        g.gtk_window_set_resizable(win, @intFromBool(options.resizable));
        if (!options.decorations) g.gtk_window_set_decorated(win, 0);
        // Out of the taskbar and the pager. GTK 4 dropped both hints (on
        // Wayland, a window can't ask), so there it is a no-op.
        if (options.skip_taskbar and !gtk.v4) {
            gtk.v3.gtk_window_set_skip_taskbar_hint(win, 1);
            gtk.v3.gtk_window_set_skip_pager_hint(win, 1);
        }
        gtk.connect(win, "destroy", @ptrCast(&onDestroy), self);
        self.surface = try Surface.create(self, self.view.?, options.theme);
        if (options.x != null and options.y != null) self.setPosition(options.x.?, options.y.?) else self.center();
        if (options.always_on_top) self.setAlwaysOnTop(true);
        if (options.opacity < 1) self.setOpacity(options.opacity);
        if (!app.flags.hidden and options.visible) self.show();
        return self;
    }

    fn onDestroy(_: *gtk.Widget, data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        self.finish();
    }

    /// The window is gone: tell its owner, free what it showed.
    fn finish(self: *Window) void {
        if (self.closed) return;
        self.closed = true;
        if (self.on_close) |cb| cb.func(cb.ctx, self);
        if (self.surface) |s| s.destroy();
        self.surface = null;
        const app = self.app;
        app.removeWindow(self);
        app.gpa.destroy(self);
    }

    pub fn close(self: *Window) void {
        // Destroying it calls `finish`, which frees it.
        if (self.gtkwindow) |win| {
            if (gtk.v4) gtk.v4api.gtk_window_destroy(win) else gtk.v3.gtk_widget_destroy(win);
        } else self.finish();
    }

    pub fn minimize(self: *Window) void {
        const win = self.gtkwindow orelse return;
        if (gtk.v4) gtk.v4api.gtk_window_minimize(win) else gtk.v3.gtk_window_iconify(win);
    }

    pub fn zoom(self: *Window) void {
        const g = &gtk.api;
        const win = self.gtkwindow orelse return;
        if (g.gtk_window_is_maximized(win) != 0) g.gtk_window_unmaximize(win) else g.gtk_window_maximize(win);
    }

    pub fn frame(self: *Window) Frame {
        var x: c_int = 0;
        var y: c_int = 0;
        var w: c_int = 0;
        var h: c_int = 0;
        const win = self.gtkwindow orelse return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
        if (gtk.v4) {
            w = gtk.api.gtk_widget_get_allocated_width(win);
            h = gtk.api.gtk_widget_get_allocated_height(win);
            if (w <= 0 or h <= 0) gtk.v4api.gtk_window_get_default_size(win, &w, &h);
        } else {
            gtk.v3.gtk_window_get_position(win, &x, &y);
            gtk.v3.gtk_window_get_size(win, &w, &h);
        }
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) };
    }

    pub fn contentSize(self: *Window) [2]f64 {
        const f = self.frame();
        return .{ f.width, f.height };
    }

    pub fn setSize(self: *Window, width: f64, height: f64) void {
        const win = self.gtkwindow orelse return;
        if (gtk.v4) gtk.api.gtk_window_set_default_size(win, @intFromFloat(width), @intFromFloat(height)) else gtk.v3.gtk_window_resize(win, @intFromFloat(width), @intFromFloat(height));
    }

    pub fn setPosition(self: *Window, x: f64, y: f64) void {
        const win = self.gtkwindow orelse return;
        if (!gtk.v4) gtk.v3.gtk_window_move(win, @intFromFloat(x), @intFromFloat(y));
    }

    pub fn center(self: *Window) void {
        const win = self.gtkwindow orelse return;
        if (!gtk.v4) gtk.v3.gtk_window_set_position(win, 1);
    }

    pub fn setMinSize(self: *Window, width: f64, height: f64) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_widget_set_size_request(win, @intFromFloat(width), @intFromFloat(height));
    }

    pub fn setResizable(self: *Window, on: bool) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_set_resizable(win, @intFromBool(on));
    }

    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        const win = self.gtkwindow orelse return;
        if (!gtk.v4) gtk.v3.gtk_window_set_keep_above(win, @intFromBool(on));
    }

    /// The window's opacity, 0 to 1; it shows where a compositor runs.
    pub fn setOpacity(self: *Window, opacity: f64) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_widget_set_opacity(win, std.math.clamp(opacity, 0, 1));
    }

    /// The screen's size in points. GTK 4 doesn't say (nor, there, where a
    /// window is), so it is the window's own size.
    pub fn monitorSize(self: *Window) [2]f64 {
        if (!gtk.v4) if (gtk.v3.gdk_screen_get_default()) |s| {
            return .{ @floatFromInt(gtk.v3.gdk_screen_get_width(s)), @floatFromInt(gtk.v3.gdk_screen_get_height(s)) };
        };
        return self.contentSize();
    }

    pub fn isFullScreen(self: *Window) bool {
        return self.full_screen;
    }

    pub fn setFullScreen(self: *Window, on: bool) void {
        self.full_screen = on;
        const win = self.gtkwindow orelse return;
        if (on) gtk.api.gtk_window_fullscreen(win) else gtk.api.gtk_window_unfullscreen(win);
    }

    pub fn show(self: *Window) void {
        const win = self.gtkwindow orelse return;
        if (gtk.v4) gtk.v4api.gtk_widget_set_visible(win, 1) else gtk.v3.gtk_widget_show_all(win);
        gtk.api.gtk_window_present(win);
        if (self.surface) |s| gtk.api.gtk_widget_grab_focus(s.area);
    }

    pub fn hide(self: *Window) void {
        const win = self.gtkwindow orelse return;
        if (gtk.v4) gtk.v4api.gtk_widget_set_visible(win, 0) else gtk.v3.gtk_widget_hide(win);
    }

    /// Popovers are macOS's: none hides itself here.
    pub fn justHidden(_: *Window) bool {
        return false;
    }

    pub fn isVisible(self: *Window) bool {
        const win = self.gtkwindow orelse return false;
        return gtk.api.gtk_widget_is_visible(win) != 0;
    }

    pub fn focus(self: *Window) void {
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_present(win);
    }

    pub fn isFocused(self: *Window) bool {
        const win = self.gtkwindow orelse return false;
        return gtk.api.gtk_window_is_active(win) != 0;
    }

    pub fn redraw(self: *Window) void {
        if (self.surface) |s| s.requestFrame();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const n = @min(title.len, self.title.len - 1);
        @memcpy(self.title[0..n], title[0..n]);
        self.title[n] = 0;
        const win = self.gtkwindow orelse return;
        gtk.api.gtk_window_set_title(win, &self.title);
    }

    /// What `--nanoui-snapshot` draws of this window, if it shows native UI.
    pub fn nativeView(self: *Window) ?NativeView {
        const v = self.view orelse return null;
        if (self.surface) |s| if (s.size.w > 0) return .{ .view = v, .width = s.size.w, .height = s.size.h, .scale = @max(2, s.scale), .theme = self.theme };
        return .{ .view = v, .width = @floatCast(self.width), .height = @floatCast(self.height), .scale = 2, .theme = self.theme };
    }

    pub fn logFrame(self: *Window) void {
        const f = self.frame();
        std.debug.print("nanoui: window {x} frame {d} {d} {d} {d}\n", .{ @intFromPtr(self), f.x, f.y, f.width, f.height });
    }
};
