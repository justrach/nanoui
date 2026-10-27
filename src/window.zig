//! Windows: an NSWindow showing either a web page (WKWebView) or native UI
//! drawn by nanoui with Metal.
const std = @import("std");
const objc = @import("objc.zig");
const App = @import("app.zig").App;
const Page = @import("page.zig").Page;
const ui = @import("ui/ui.zig");
const Surface = @import("ui/surface.zig").Surface;

const window_types = @import("window_types.zig");
pub const Asset = window_types.Asset;
pub const PageOptions = window_types.PageOptions;
pub const Content = window_types.Content;
pub const TitleBar = window_types.TitleBar;
pub const Callback = window_types.Callback(Window);
pub const Options = window_types.Options(Window);
pub const NativeView = window_types.NativeView;

pub const Window = struct {
    app: *App,
    nswindow: objc.Object,
    delegate: objc.Object,
    page: ?*Page = null,
    surface: ?*Surface = null,
    title_bar: TitleBar = .default,
    on_close: ?Callback = null,
    closed: bool = false,
    /// When a popover last hid itself, losing the keys.
    resigned_at: f64 = 0,

    pub fn create(app: *App, options: Options) !*Window {
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try app.gpa.create(Window);
        errdefer app.gpa.destroy(self);

        const popover = options.title_bar == .popover;
        var style: objc.NSUInteger = 1 | 2 | 4; // titled, closable, miniaturizable
        if (options.resizable) style |= 8;
        if (options.title_bar == .hidden) style |= 1 << 15; // full size content view
        if (popover) style = 1 << 7; // borderless, non-activating panel
        const rect: objc.CGRect = .{ .size = .{ .width = options.width, .height = options.height } };
        // A borderless panel takes keys only if its class says it can.
        const window_class = if (popover) objc.defineClass(.{ .name = "NanoUIPopover", .superclass = "NSPanel", .methods = &.{
            .{ .name = "canBecomeKeyWindow", .imp = &yes, .types = "B@:" },
        } }) else objc.class("NSWindow");
        const nswindow = objc.msg(objc.Object, objc.msg(objc.Object, window_class, "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{
            rect, style, @as(objc.NSUInteger, 2), objc.NO,
        });
        objc.msg(void, nswindow, "setReleasedWhenClosed:", .{objc.NO});
        objc.msg(void, nswindow, "setTitle:", .{objc.nsString(options.title)});
        objc.msg(void, nswindow, "setContentMinSize:", .{objc.CGSize{ .width = options.min_width, .height = options.min_height }});
        if (options.title_bar == .hidden) {
            objc.msg(void, nswindow, "setTitlebarAppearsTransparent:", .{objc.YES});
            objc.msg(void, nswindow, "setTitleVisibility:", .{@as(objc.NSInteger, 1)});
        }

        const delegate_class = objc.defineClass(.{
            .name = "NanoUIWindowDelegate",
            .protocols = &.{"NSWindowDelegate"},
            .methods = &.{
                .{ .name = "windowWillClose:", .imp = &windowWillClose, .types = "v@:@" },
                .{ .name = "windowDidChangeOcclusionState:", .imp = &occlusionChanged, .types = "v@:@" },
                .{ .name = "windowDidResignKey:", .imp = &resignedKey, .types = "v@:@" },
                .{ .name = "windowDidBecomeKey:", .imp = &becameKey, .types = "v@:@" },
            },
        });
        const delegate = objc.msg(objc.Object, delegate_class, "new", .{});
        objc.setZig(delegate, self);
        objc.msg(void, nswindow, "setDelegate:", .{delegate});

        self.* = .{ .app = app, .nswindow = nswindow, .delegate = delegate, .title_bar = options.title_bar, .on_close = options.on_close };

        switch (options.content) {
            .page => |p| self.page = try Page.create(self, p),
            .view => |v| self.surface = try Surface.create(self, v, options.theme),
        }
        if (popover) {
            objc.msg(void, nswindow, "setOpaque:", .{objc.NO});
            objc.msg(void, nswindow, "setBackgroundColor:", .{objc.msg(objc.Object, objc.class("NSColor"), "clearColor", .{})});
            objc.msg(void, nswindow, "setHasShadow:", .{objc.YES});
            objc.msg(void, nswindow, "setLevel:", .{@as(objc.NSInteger, 101)}); // NSPopUpMenuWindowLevel
            objc.msg(void, nswindow, "setHidesOnDeactivate:", .{objc.NO});
            // On every space, over full screen apps, out of Exposé.
            objc.msg(void, nswindow, "setCollectionBehavior:", .{@as(objc.NSUInteger, (1 << 0) | (1 << 3) | (1 << 8))});
            const content = objc.msg(objc.Object, nswindow, "contentView", .{});
            objc.msg(void, content, "setWantsLayer:", .{objc.YES});
            if (objc.msg(?objc.Object, content, "layer", .{})) |layer| {
                objc.msg(void, layer, "setCornerRadius:", .{@as(f64, 12)});
                objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
            }
        }

        if (options.x != null and options.y != null) self.setPosition(options.x.?, options.y.?) else objc.msg(void, nswindow, "center", .{});
        if (options.always_on_top) self.setAlwaysOnTop(true);
        if (!app.flags.hidden and options.visible) objc.msg(void, nswindow, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
        if (app.debug) self.logFrame();
        return self;
    }

    /// Logs the window's number and frame in screen points, top left origin.
    pub fn logFrame(self: *Window) void {
        const f = objc.msg(objc.CGRect, self.nswindow, "frame", .{});
        const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
        const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        const sh = objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
        const num = objc.msg(objc.NSInteger, self.nswindow, "windowNumber", .{});
        std.debug.print("nanoui: window id={d} frame={d:.0},{d:.0},{d:.0},{d:.0}\n", .{
            num, f.origin.x, sh - f.origin.y - f.size.height, f.size.width, f.size.height,
        });
    }

    /// Closes the window; it is freed once AppKit is done with it.
    pub fn close(self: *Window) void {
        if (self.closed) return;
        objc.msg(void, self.nswindow, "close", .{});
    }

    pub fn minimize(self: *Window) void {
        objc.msg(void, self.nswindow, "miniaturize:", .{@as(?objc.Object, null)});
    }

    pub fn zoom(self: *Window) void {
        objc.msg(void, self.nswindow, "zoom:", .{@as(?objc.Object, null)});
    }

    pub const Frame = struct { x: f64, y: f64, width: f64, height: f64 };

    /// The window's frame in screen points from the primary screen's top left.
    pub fn frame(self: *Window) Frame {
        const f = objc.msg(objc.CGRect, self.nswindow, "frame", .{});
        return .{ .x = f.origin.x, .y = primaryHeight() - f.origin.y - f.size.height, .width = f.size.width, .height = f.size.height };
    }

    /// The size of the window's content, without its title bar.
    pub fn contentSize(self: *Window) [2]f64 {
        const v = objc.msg(objc.Object, self.nswindow, "contentView", .{});
        const b = objc.msg(objc.CGRect, v, "bounds", .{});
        return .{ b.size.width, b.size.height };
    }

    /// Resizes the content to `width` × `height` points, keeping the top left.
    pub fn setSize(self: *Window, width: f64, height: f64) void {
        const f = objc.msg(objc.CGRect, self.nswindow, "frame", .{});
        const content = objc.msg(objc.CGRect, self.nswindow, "contentRectForFrameRect:", .{f});
        const want = objc.msg(objc.CGRect, self.nswindow, "frameRectForContentRect:", .{objc.CGRect{ .origin = content.origin, .size = .{ .width = width, .height = height } }});
        const top = f.origin.y + f.size.height;
        const r: objc.CGRect = .{ .origin = .{ .x = f.origin.x, .y = top - want.size.height }, .size = want.size };
        objc.msg(void, self.nswindow, "setFrame:display:animate:", .{ r, objc.YES, objc.NO });
    }

    /// Moves the window's top left to `x`, `y` (points from the primary screen's top left).
    pub fn setPosition(self: *Window, x: f64, y: f64) void {
        objc.msg(void, self.nswindow, "setFrameTopLeftPoint:", .{objc.CGPoint{ .x = x, .y = primaryHeight() - y }});
    }

    pub fn center(self: *Window) void {
        objc.msg(void, self.nswindow, "center", .{});
    }

    pub fn setMinSize(self: *Window, width: f64, height: f64) void {
        objc.msg(void, self.nswindow, "setContentMinSize:", .{objc.CGSize{ .width = width, .height = height }});
    }

    pub fn setResizable(self: *Window, on: bool) void {
        var mask = objc.msg(objc.NSUInteger, self.nswindow, "styleMask", .{});
        mask = if (on) mask | 8 else mask & ~@as(objc.NSUInteger, 8);
        objc.msg(void, self.nswindow, "setStyleMask:", .{mask});
    }

    /// Keeps the window above other apps' windows.
    pub fn setAlwaysOnTop(self: *Window, on: bool) void {
        objc.msg(void, self.nswindow, "setLevel:", .{@as(objc.NSInteger, if (on) 3 else 0)}); // NSFloatingWindowLevel
    }

    pub fn isFullScreen(self: *Window) bool {
        return objc.msg(objc.NSUInteger, self.nswindow, "styleMask", .{}) & (1 << 14) != 0;
    }

    pub fn setFullScreen(self: *Window, on: bool) void {
        if (on != self.isFullScreen()) objc.msg(void, self.nswindow, "toggleFullScreen:", .{@as(?objc.Object, null)});
    }

    pub fn show(self: *Window) void {
        objc.msg(void, self.nswindow, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
    }

    pub fn hide(self: *Window) void {
        objc.msg(void, self.nswindow, "orderOut:", .{@as(?objc.Object, null)});
    }

    /// Whether a popover just hid itself (a click on what opens it, which
    /// took its keys, should leave it closed, not open it again).
    pub fn justHidden(self: *Window) bool {
        return CACurrentMediaTime() - self.resigned_at < 0.3;
    }

    pub fn isVisible(self: *Window) bool {
        return objc.msg(objc.BOOL, self.nswindow, "isVisible", .{});
    }

    /// Brings the window and its app to the front.
    pub fn focus(self: *Window) void {
        objc.msg(void, self.app.nsapp, "activateIgnoringOtherApps:", .{objc.YES});
        self.show();
    }

    pub fn isFocused(self: *Window) bool {
        return objc.msg(objc.BOOL, self.nswindow, "isKeyWindow", .{});
    }

    /// Draws native UI again at the next refresh, for state changed from
    /// outside its events (a timer, a process's output). Main thread.
    /// What `--nanoui-snapshot` draws of this window, if it shows native UI.
    pub fn nativeView(self: *Window) ?NativeView {
        const s = self.surface orelse return null;
        return .{ .view = s.view, .width = s.size.w, .height = s.size.h, .scale = s.scale, .theme = s.theme_override };
    }

    pub fn redraw(self: *Window) void {
        if (self.surface) |s| s.requestFrame();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.nswindow, "setTitle:", .{objc.nsString(title)});
    }

    /// Queues an encoded message for the page and takes ownership of it.
    /// Safe from any thread.
    pub fn sendOwned(self: *Window, msg: []u8) void {
        if (objc.isMainThread()) {
            defer self.app.gpa.free(msg);
            if (self.page) |p| p.enqueue(msg, true);
            return;
        }
        const job = self.app.gpa.create(Job) catch return self.app.gpa.free(msg);
        job.* = .{ .window = self, .msg = msg };
        objc.dispatchMain(job, Job.run);
    }

    const Job = struct {
        window: *Window,
        msg: []u8,
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const job: *Job = @ptrCast(@alignCast(ctx));
            const w = job.window;
            const gpa = w.app.gpa;
            defer gpa.destroy(job);
            // The window may have closed meanwhile.
            for (w.app.windows.items) |live| if (live == w) return w.sendOwned(job.msg);
            gpa.free(job.msg);
        }
    };

    fn teardown(self: *Window) void {
        self.closed = true;
        if (self.on_close) |cb| cb.func(cb.ctx, self);
        if (self.page) |p| p.destroy();
        if (self.surface) |s| s.destroy();
        self.page = null;
        self.surface = null;
        objc.setZig(self.delegate, null);
        objc.msg(void, self.nswindow, "setDelegate:", .{@as(?objc.Object, null)});
        // AppKit still uses both while closing.
        objc.autorelease(self.delegate);
        objc.autorelease(self.nswindow);
        const app = self.app;
        app.removeWindow(self);
        app.gpa.destroy(self);
    }
};

fn primaryHeight() f64 {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    if (objc.msg(objc.NSUInteger, screens, "count", .{}) == 0) return 0;
    const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    return objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
}

fn occlusionChanged(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.surface) |s| s.occlusionChanged();
}

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) bool {
    return true;
}

fn becameKey(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.surface) |s| s.requestFrame();
}

fn resignedKey(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.surface) |s| s.requestFrame();
    if (w.title_bar != .popover) return;
    w.hide();
    w.resigned_at = CACurrentMediaTime();
}

extern "c" fn CACurrentMediaTime() f64;

fn windowWillClose(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    w.teardown();
}
