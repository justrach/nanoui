//! Windows: an NSWindow showing either a web page (WKWebView) or native UI
//! drawn by nanoui with Metal.
const std = @import("std");
const objc = @import("objc.zig");
const App = @import("app.zig").App;
const Page = @import("page_webkit.zig").Page;
const ui = @import("ui/ui.zig");
const Surface = @import("ui/surface.zig").Surface;
const Lights = @import("window_lights.zig").Lights;

const window_types = @import("window_types.zig");
pub const Asset = window_types.Asset;
pub const PageOptions = window_types.PageOptions;
pub const Content = window_types.Content;
pub const TitleBar = window_types.TitleBar;
pub const Callback = window_types.Callback(Window);
pub const ShouldClose = window_types.ShouldClose(Window);
pub const Options = window_types.Options(Window);
pub const NativeView = window_types.NativeView;
pub const Level = window_types.Level;
const screen_list = @import("screens.zig");

/// The Dock icon, from ICNS or PNG bytes.
fn setAppIcon(icon: []const u8) void {
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ icon.ptr, icon.len });
    const image = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSImage"), "alloc", .{}), "initWithData:", .{data});
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, app, "setApplicationIconImage:", .{image});
    objc.release(image);
}

pub const Window = struct {
    app: *App,
    nswindow: objc.Object,
    delegate: objc.Object,
    page: ?*Page = null,
    /// Pages docked in a native-UI window's views (`dockPage`).
    docked: std.ArrayList(*Page) = .empty,
    surface: ?*Surface = null,
    title_bar: TitleBar = .default,
    on_close: ?Callback = null,
    on_resize: ?Callback = null,
    on_move: ?Callback = null,
    on_fullscreen: ?Callback = null,
    on_key: ?Callback = null,
    should_close: ?ShouldClose = null,
    /// The traffic lights kept where `Options.traffic_lights` put them.
    lights: ?Lights = null,
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
        if (options.non_activating) style |= 1 << 7;
        if (options.kind == .panel and options.utility and !popover) style |= 1 << 4; // NSWindowStyleMaskUtilityWindow
        // No title bar, no frame, no resizing edges (`decorations`): the
        // app draws it and moves it (`window_drag`). Only the panel's
        // non-activating bit stays.
        const borderless = !options.decorations and !popover;
        if (borderless) style &= 1 << 7;
        const rect: objc.CGRect = .{ .size = .{ .width = options.width, .height = options.height } };
        // A borderless window or panel takes keys only if its class says it can.
        const window_class = if (popover) objc.defineClass(.{ .name = "NanoUIPopover", .superclass = "NSPanel", .methods = &.{
            .{ .name = "canBecomeKeyWindow", .imp = &yes, .types = "B@:" },
        } }) else if (borderless and options.kind == .panel)
            objc.defineClass(.{ .name = "NanoUIBorderlessPanel", .superclass = "NSPanel", .methods = &borderless_methods })
        else if (borderless)
            objc.defineClass(.{ .name = "NanoUIBorderlessWindow", .superclass = "NSWindow", .methods = &borderless_methods })
        else if (options.kind == .panel) objc.class("NSPanel") else objc.class("NSWindow");
        const nswindow = objc.msg(objc.Object, objc.msg(objc.Object, window_class, "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{
            rect, style, @as(objc.NSUInteger, 2), objc.NO,
        });
        // The Dock's icon: a bundled .app's own wins, so this is for a binary
        // run from a checkout or a tarball.
        if (options.icon) |icon| setAppIcon(icon);
        if (options.tabbing_disallowed) objc.msg(void, nswindow, "setTabbingMode:", .{@as(objc.NSInteger, 2)}); // NSWindowTabbingModeDisallowed
        var behavior: objc.NSUInteger = 0;
        // NSWindowCollectionBehaviorCanJoinAllSpaces | FullScreenAuxiliary.
        if (options.all_spaces) behavior |= (1 << 0) | (1 << 8);
        // The Mac has no taskbar, and the Dock and Command-Tab list apps, not
        // windows: what a window can leave is Command-` and the Window menu.
        if (options.skip_taskbar) behavior |= 1 << 6; // IgnoresCycle
        if (behavior != 0) objc.msg(void, nswindow, "setCollectionBehavior:", .{behavior});
        if (options.skip_taskbar) objc.msg(void, nswindow, "setExcludedFromWindowsMenu:", .{objc.YES});
        objc.msg(void, nswindow, "setReleasedWhenClosed:", .{objc.NO});
        objc.msg(void, nswindow, "setTitle:", .{objc.nsString(options.title)});
        objc.msg(void, nswindow, "setContentMinSize:", .{objc.CGSize{ .width = options.min_width, .height = options.min_height }});
        if (options.title_bar == .hidden and !borderless) {
            objc.msg(void, nswindow, "setTitlebarAppearsTransparent:", .{objc.YES});
            objc.msg(void, nswindow, "setTitleVisibility:", .{@as(objc.NSInteger, 1)});
        }

        const delegate_class = objc.defineClass(.{
            .name = "NanoUIWindowDelegate",
            .protocols = &.{"NSWindowDelegate"},
            .methods = &.{
                .{ .name = "windowWillClose:", .imp = &windowWillClose, .types = "v@:@" },
                .{ .name = "windowDidChangeOcclusionState:", .imp = &occlusionChanged, .types = "v@:@" },
                .{ .name = "windowDidChangeScreen:", .imp = &screenChanged, .types = "v@:@" },
                .{ .name = "windowDidResize:", .imp = &didResize, .types = "v@:@" },
                .{ .name = "windowDidMove:", .imp = &didMove, .types = "v@:@" },
                .{ .name = "windowWillEnterFullScreen:", .imp = &willFullScreen, .types = "v@:@" },
                .{ .name = "windowDidEnterFullScreen:", .imp = &fullScreenChanged, .types = "v@:@" },
                .{ .name = "windowWillExitFullScreen:", .imp = &willFullScreen, .types = "v@:@" },
                .{ .name = "windowDidExitFullScreen:", .imp = &fullScreenChanged, .types = "v@:@" },
                .{ .name = "windowDidBecomeKey:", .imp = &keyChanged, .types = "v@:@" },
                .{ .name = "windowDidResignKey:", .imp = &keyChanged, .types = "v@:@" },
                .{ .name = "windowShouldClose:", .imp = &shouldClose, .types = "c@:@" },
                .{ .name = "lightsMoved:", .imp = &lightsMoved, .types = "v@:@" },
            },
        });
        const delegate = objc.msg(objc.Object, delegate_class, "new", .{});
        objc.setZig(delegate, self);
        objc.msg(void, nswindow, "setDelegate:", .{delegate});

        self.* = .{
            .app = app,
            .nswindow = nswindow,
            .delegate = delegate,
            .title_bar = options.title_bar,
            .on_close = options.on_close,
            .on_resize = options.on_resize,
            .on_move = options.on_move,
            .on_fullscreen = options.on_fullscreen,
            .on_key = options.on_key,
            .should_close = options.should_close,
        };

        switch (options.content) {
            .page => |p| self.page = try Page.create(self, p),
            .view => |v| self.surface = try Surface.create(self, v, options.theme),
        }
        if (options.traffic_lights) |p| if (options.title_bar == .hidden and !borderless) {
            self.lights = Lights.init(nswindow, p.x, p.y);
            Lights.observe(nswindow, delegate);
            self.lights.?.place(nswindow);
        };
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

        if (options.screen) |id| if (screen_list.byId(id)) |sc| {
            // On that screen: from its top left, else centered on it.
            const x = sc.frame.x + (options.x orelse @max(0, (sc.frame.width - options.width) / 2));
            const y = sc.frame.y + (options.y orelse @max(0, (sc.frame.height - options.height) / 2));
            self.setPosition(x, y);
        } else self.placeDefault(options) else self.placeDefault(options);
        if (options.frame_autosave) |name| {
            // A frame kept under the name wins over the one asked for.
            _ = objc.msg(objc.BOOL, nswindow, "setFrameUsingName:", .{objc.nsString(name)});
            _ = objc.msg(objc.BOOL, nswindow, "setFrameAutosaveName:", .{objc.nsString(name)});
        }
        if (options.always_on_top or options.floating) self.setAlwaysOnTop(true);
        if (options.kind == .panel and !popover and !options.hides_on_deactivate)
            objc.msg(void, nswindow, "setHidesOnDeactivate:", .{objc.NO});
        if (options.level) |lv| self.setLevel(lv);
        if (options.ignores_mouse) self.setIgnoresMouse(true);
        if (options.opacity < 1) self.setOpacity(options.opacity);
        // Opened quietly by an update's restart: behind, not key, until the
        // updater puts it back as it was (update_auto.zig).
        if (!app.flags.hidden and options.visible) {
            if (app.quiet) objc.msg(void, nswindow, "orderBack:", .{@as(?objc.Object, null)}) else objc.msg(void, nswindow, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
        }
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

    fn placeDefault(self: *Window, options: Options) void {
        if (options.x != null and options.y != null) self.setPosition(options.x.?, options.y.?) else objc.msg(void, self.nswindow, "center", .{});
    }

    /// Stacks the window at `level` (above the menu bar at `.status`).
    pub fn setLevel(self: *Window, lv: Level) void {
        objc.msg(void, self.nswindow, "setLevel:", .{@as(objc.NSInteger, @intFromEnum(lv))});
    }

    pub fn level(self: *Window) Level {
        return @enumFromInt(@as(i32, @intCast(objc.msg(objc.NSInteger, self.nswindow, "level", .{}))));
    }

    /// Lets clicks and the pointer through to what is behind the window.
    pub fn setIgnoresMouse(self: *Window, on: bool) void {
        objc.msg(void, self.nswindow, "setIgnoresMouseEvents:", .{on});
    }

    /// Moves and sizes the window's frame (points from the primary
    /// screen's top left, as `frame` reads it): a borderless window over a
    /// whole screen is `setFrame(screen.frame)`.
    pub fn setFrame(self: *Window, f: Frame) void {
        const r: objc.CGRect = .{ .origin = .{ .x = f.x, .y = primaryHeight() - f.y - f.height }, .size = .{ .width = f.width, .height = f.height } };
        objc.msg(void, self.nswindow, "setFrame:display:animate:", .{ r, objc.YES, objc.NO });
    }

    /// The screen the window is mostly on (`App.screens`' id), if any.
    pub fn screenId(self: *Window) ?u32 {
        const sc = objc.msg(?objc.Object, self.nswindow, "screen", .{}) orelse return null;
        const desc = objc.msg(objc.Object, sc, "deviceDescription", .{});
        const num = objc.msg(?objc.Object, desc, "objectForKey:", .{objc.nsString("NSScreenNumber")}) orelse return null;
        return objc.msg(c_uint, num, "unsignedIntValue", .{});
    }

    /// The window's opacity, 0 to 1 (NSWindow's alpha value).
    pub fn setOpacity(self: *Window, opacity: f64) void {
        objc.msg(void, self.nswindow, "setAlphaValue:", .{std.math.clamp(opacity, 0, 1)});
    }

    /// The visible frame of the screen the window is on, in points: the menu
    /// bar and the Dock left out, so it is the room there is for a window.
    pub fn monitorSize(self: *Window) [2]f64 {
        const screen = objc.msg(?objc.Object, self.nswindow, "screen", .{}) orelse objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return .{ 0, 0 };
        const f = objc.msg(objc.CGRect, screen, "visibleFrame", .{});
        return .{ f.size.width, f.size.height };
    }

    pub fn isFullScreen(self: *Window) bool {
        return objc.msg(objc.NSUInteger, self.nswindow, "styleMask", .{}) & (1 << 14) != 0;
    }

    pub fn setFullScreen(self: *Window, on: bool) void {
        if (on != self.isFullScreen()) objc.msg(void, self.nswindow, "toggleFullScreen:", .{@as(?objc.Object, null)});
    }

    pub fn show(self: *Window) void {
        objc.msg(void, self.nswindow, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
        if (self.surface) |s| s.occlusionChanged();
    }

    pub fn hide(self: *Window) void {
        objc.msg(void, self.nswindow, "orderOut:", .{@as(?objc.Object, null)});
        if (self.surface) |s| s.is_visible = false;
        self.app.wentAway();
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

    /// `redraw` from any thread (a decoder's): lock-free, coalesced, drawn
    /// at the display's next refresh. Only while the window is open: stop
    /// the thread before closing it.
    pub fn redrawFromAnyThread(self: *Window) void {
        if (self.surface) |s| s.requestFrameFromAnyThread();
    }

    /// A web page docked in `options.parent`, an NSView of this window
    /// (a native-UI window's region): its own bridge, the app's services,
    /// freed with the window. Place it with `Page.setFrame`.
    pub fn dockPage(self: *Window, options: PageOptions) !*Page {
        if (options.parent == null) return error.NoParent;
        const p = try Page.create(self, options);
        errdefer p.destroy();
        try self.docked.append(self.app.gpa, p);
        return p;
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.nswindow, "setTitle:", .{objc.nsString(title)});
    }

    /// Points a page's window at `url`: a path from the app's assets, or an
    /// absolute `http(s)://` one. No effect on a native-UI window.
    pub fn setPageUrl(self: *Window, url: []const u8) void {
        if (self.page) |p| p.load(url);
    }

    /// Shows entry `i` of `PageOptions.pages` (the bar's buttons).
    pub fn showPage(self: *Window, i: usize) void {
        const p = self.page orelse return;
        if (i >= p.queue.options.pages.len) return;
        p.load(p.queue.options.pages[i].url);
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
        for (self.docked.items) |p| p.destroy();
        self.docked.deinit(self.app.gpa);
        if (self.surface) |s| s.destroy();
        self.page = null;
        self.surface = null;
        if (self.lights != null) Lights.stopObserving(self.delegate);
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
    if (objc.msg(objc.NSUInteger, w.nswindow, "occlusionState", .{}) & 2 == 0) w.app.wentAway();
}

fn screenChanged(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.surface) |s| s.screenChanged();
}

/// The title bar's views moved, or are about to be left where AppKit put them.
fn lightsMoved(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    const l = if (w.lights) |*l| l else return;
    if (l.placing or l.pending) return;
    l.pending = true;
    l.place(w.nswindow);
    // Frame notifications can arrive halfway through AppKit's layout; its
    // remaining writes can undo the synchronous placement of the last button.
    // Retain the delegate, not Window: teardown clears its Zig pointer.
    _ = objc.retain(self_obj);
    objc.dispatchMain(self_obj, finishLightsLayout);
}

fn finishLightsLayout(ctx: ?*anyopaque) callconv(.c) void {
    const delegate: objc.Object = @ptrCast(ctx orelse return);
    defer objc.release(delegate);
    const w = objc.getZig(Window, delegate) orelse return;
    if (w.lights) |*l| {
        l.pending = false;
        l.place(w.nswindow);
    }
}

fn didResize(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.lights) |*l| l.place(w.nswindow);
    if (w.on_resize) |cb| cb.func(cb.ctx, w);
}

fn didMove(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.on_move) |cb| cb.func(cb.ctx, w);
}

fn willFullScreen(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.surface) |s| {
        s.updateGeometry();
        s.frame();
    }
}

fn fullScreenChanged(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.on_fullscreen) |cb| cb.func(cb.ctx, w);
    const w2 = objc.getZig(Window, self_obj) orelse return;
    if (w2.lights) |*l| l.place(w2.nswindow);
    if (w2.surface) |s| {
        s.updateGeometry();
        s.frame();
    }
}

fn keyChanged(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    if (w.lights) |*l| l.place(w.nswindow);
    if (w.title_bar == .popover and !w.isFocused()) {
        w.hide();
        w.resigned_at = CACurrentMediaTime();
    }
    if (w.on_key) |cb| cb.func(cb.ctx, w);
    const w2 = objc.getZig(Window, self_obj) orelse return;
    if (w2.surface) |s| if (s.visible()) s.requestFrame() else s.frame();
}

fn shouldClose(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.BOOL {
    const w = objc.getZig(Window, self_obj) orelse return objc.YES;
    const ask = w.should_close orelse return objc.YES;
    return if (ask.func(ask.ctx, w)) objc.YES else objc.NO;
}

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) bool {
    return true;
}

/// A borderless NSWindow can't become key or main unless its class says
/// so, and then it would take no keys.
const borderless_methods = [_]objc.Method{
    .{ .name = "canBecomeKeyWindow", .imp = &yes, .types = "B@:" },
    .{ .name = "canBecomeMainWindow", .imp = &yes, .types = "B@:" },
};

extern "c" fn CACurrentMediaTime() f64;

fn windowWillClose(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Window, self_obj) orelse return;
    w.teardown();
}
