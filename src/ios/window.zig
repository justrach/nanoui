//! Windows on iOS: a view controller showing native UI drawn by nanoui.
//! The first window fills the screen; windows shown after it cover it,
//! full screen too, until `close` or `hide` (`App.arrange`). Not page
//! sheets: their swipe to dismiss would take every drag down from the
//! view, which scrolls itself. What a desktop window has and a screen
//! hasn't (a position, a size, minimizing) is accepted and ignored. Pages
//! (WKWebView) are not supported yet.
const std = @import("std");
const objc = @import("../objc.zig");
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

/// The class of windows' controllers: `App.arrange` knows its own by it.
pub fn controllerClass() objc.Class {
    return objc.defineClass(.{ .name = "NanoUIViewController", .superclass = "UIViewController", .methods = &.{} });
}

pub const Window = struct {
    app: *App,
    /// Made once UIKit runs (`realize`): before, the window is its options.
    controller: ?objc.Object = null,
    surface: ?*Surface = null,
    view: ui.View,
    theme: ?ui.Theme = null,
    full_bleed: bool = false,
    /// What a snapshot draws when there is no screen: the size asked for.
    width: f64 = 0,
    height: f64 = 0,
    title_bar: TitleBar = .default,
    on_close: ?Callback = null,
    /// Shown when UIKit is up (`visible` in the options, then show/hide).
    wanted: bool = true,
    /// Where it stacks: windows shown later cover those shown before.
    order: u64 = 0,
    /// On screen: the root of the UIWindow, or presented over it.
    shown: bool = false,
    closed: bool = false,
    title: [256:0]u8 = @splat(0),

    pub fn create(app: *App, options: Options) !*Window {
        const view = switch (options.content) {
            .page => return error.PagesUnsupported,
            .view => |v| v,
        };
        const self = try app.gpa.create(Window);
        self.* = .{
            .app = app,
            .view = view,
            .theme = options.theme,
            .full_bleed = options.full_bleed,
            .width = options.width,
            .height = options.height,
            .title_bar = options.title_bar,
            .on_close = options.on_close,
            .wanted = options.visible and !app.flags.hidden,
            .order = app.nextOrder(),
        };
        self.setTitle(options.title);
        return self;
    }

    /// UIKit runs: make the controller and its view (`App.arrange` puts
    /// them on screen).
    pub fn realize(self: *Window) void {
        if (self.controller != null or self.closed) return;
        const vc = objc.msg(objc.Object, objc.msg(objc.Object, controllerClass(), "alloc", .{}), "init", .{});
        objc.setZig(vc, self);
        self.controller = vc;
        objc.msg(void, vc, "setModalPresentationStyle:", .{@as(objc.NSInteger, 0)}); // full screen
        objc.msg(void, vc, "setTitle:", .{objc.nsString(std.mem.sliceTo(&self.title, 0))});
        self.surface = Surface.create(self, self.view, self.theme, self.full_bleed) catch |err| {
            std.log.err("nanoui: window: {s}", .{@errorName(err)});
            return;
        };
        objc.msg(void, vc, "setView:", .{self.surface.?.uiview});
    }

    /// Off the screen, its owner told, and freed.
    pub fn close(self: *Window) void {
        if (self.closed) return;
        // Closed before the screen changes: a frame UIKit runs meanwhile
        // (of the window under it, showing again) may close it too.
        self.closed = true;
        self.wanted = false;
        self.app.arrange();
        if (self.on_close) |cb| cb.func(cb.ctx, self);
        if (self.surface) |s| s.destroy();
        self.surface = null;
        if (self.controller) |vc| {
            objc.setZig(vc, null);
            objc.release(vc);
        }
        const app = self.app;
        app.removeWindow(self);
        app.gpa.destroy(self);
        app.refocus();
    }

    /// On screen, over the windows shown before it (or as the screen's own,
    /// with none).
    pub fn show(self: *Window) void {
        if (!self.wanted) {
            self.wanted = true;
            self.order = self.app.nextOrder();
        }
        self.app.arrange();
    }

    /// Off screen; the windows it covered show again.
    pub fn hide(self: *Window) void {
        self.wanted = false;
        self.app.arrange();
    }

    pub fn minimize(_: *Window) void {}
    pub fn zoom(_: *Window) void {}

    pub fn frame(self: *Window) Frame {
        if (self.surface) |s| return .{ .x = 0, .y = 0, .width = s.size.w, .height = s.size.h };
        return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
    }

    pub fn contentSize(self: *Window) [2]f64 {
        const f = self.frame();
        return .{ f.width, f.height };
    }

    // A screen's size and place are the system's.
    pub fn setSize(_: *Window, _: f64, _: f64) void {}
    pub fn setPosition(_: *Window, _: f64, _: f64) void {}
    pub fn center(_: *Window) void {}
    pub fn setMinSize(_: *Window, _: f64, _: f64) void {}
    pub fn setResizable(_: *Window, _: bool) void {}
    pub fn setAlwaysOnTop(_: *Window, _: bool) void {}
    pub fn setOpacity(_: *Window, _: f64) void {}

    /// The window is the screen.
    pub fn monitorSize(self: *Window) [2]f64 {
        return self.contentSize();
    }

    pub fn isFullScreen(_: *Window) bool {
        return true;
    }

    pub fn setFullScreen(_: *Window, _: bool) void {}

    pub fn justHidden(_: *Window) bool {
        return false;
    }

    /// On screen and still wanted there (a window hidden is not, though
    /// it may still be on its way out).
    pub fn isVisible(self: *Window) bool {
        return self.shown and self.wanted;
    }

    pub fn focus(self: *Window) void {
        self.show();
    }

    pub fn isFocused(self: *Window) bool {
        if (!self.shown or !self.app.active) return false;
        return self.app.topController() == self.controller;
    }

    pub fn redraw(self: *Window) void {
        if (self.surface) |s| s.requestFrame();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const n = @min(title.len, self.title.len - 1);
        @memcpy(self.title[0..n], title[0..n]);
        self.title[n] = 0;
        if (self.controller) |vc| objc.msg(void, vc, "setTitle:", .{objc.nsString(title)});
    }

    /// What `--nanoui-snapshot` draws of this window.
    pub fn nativeView(self: *Window) ?NativeView {
        if (self.surface) |s| if (s.size.w > 0) return .{ .view = self.view, .width = s.size.w, .height = s.size.h, .scale = s.scale, .theme = self.theme };
        return .{ .view = self.view, .width = @floatCast(self.width), .height = @floatCast(self.height), .scale = 3, .theme = self.theme };
    }

    pub fn logFrame(self: *Window) void {
        const f = self.frame();
        std.debug.print("nanoui: window {x} frame {d} {d} {d} {d}\n", .{ @intFromPtr(self), f.x, f.y, f.width, f.height });
    }
};
