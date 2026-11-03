//! The application on Android: the activity's window shows the app's
//! windows, the one shown last on top (`arrange`), drawn with OpenGL ES 3
//! (or on the CPU where there is none) at the display's refresh while
//! something moves. The app's thread's loop (`activity.zig`) runs until
//! the app quits or the activity goes; quitting finishes the activity.
//! Headless runs (`--nanoui-snapshot`) render offscreen.
const std = @import("std");
const ndk = @import("ndk.zig");
const activity = @import("activity.zig");
const calls = @import("calls.zig");
const bars = @import("bars.zig");
const egl = @import("egl.zig");
const touch = @import("touch.zig");
const keys = @import("keys.zig");
const dev = @import("../dev.zig");
const clock = @import("../ui/clock.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("../menu_accel.zig");
const ui = @import("../ui/ui.zig");
const jni = @import("jni.zig");
const Window = window_mod.Window;
const Event = @import("event.zig").Event;

pub const Options = struct {
    name: []const u8 = "nanoui",
    /// Quit when the last window closes: the activity finishes.
    quit_on_last_window_closed: bool = true,
};

var current: ?*App = null;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    windows: std.ArrayList(*Window) = .empty,
    main_menu: ?*menu_mod.Menu = null,
    flags: dev.Flags = .{},
    /// No activity to show windows in (a snapshot): views draw offscreen.
    headless: bool = false,
    running: bool = false,
    stopping: bool = false,
    debug: bool = false,
    /// `NANOUI_RENDERER=cpu`: draw on the CPU even where OpenGL ES is.
    cpu_only: bool = false,
    /// OpenGL ES, made for the first window to draw in; null: the CPU draws.
    gl: ?egl.Gl = null,
    gl_tried: bool = false,
    /// The activity's window, while it has one, and its size in pixels.
    screen: ?*ndk.ANativeWindow = null,
    screen_w: i32 = 0,
    screen_h: i32 = 0,
    /// Pixels per point (the display's density over 160), and dark mode.
    scale: f32 = 2,
    dark: bool = false,
    /// Animations are off in the system's settings.
    reduced_motion: bool = false,
    next_order: u64 = 0,
    /// The window on top: the one that draws, and takes input.
    top: ?*Window = null,
    choreographer: ?*ndk.AChoreographer = null,
    /// A frame callback is posted for the display's next refresh; one
    /// later, due then (0: none).
    vsync_posted: bool = false,
    later_due: f64 = 0,
    /// Whether the bars' icons are dark, for a light view.
    bars_light: ?bool = null,

    /// Creates the app. Call from `main`.
    pub fn create(init: std.process.Init, options: Options) !*App {
        const gpa = init.gpa;
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);
        const flags = try dev.Flags.parse(init);
        self.* = .{
            .gpa = gpa,
            .io = init.io,
            .options = options,
            .flags = flags,
            .debug = init.environ_map.get("NANOUI_DEBUG") != null,
            .cpu_only = std.mem.eql(u8, init.environ_map.get("NANOUI_RENDERER") orelse "", "cpu"),
            .headless = flags.snapshot != null or flags.generate_dir != null or activity.activity == null,
        };
        current = self;
        // The activity went before the app was made: nothing to run.
        self.stopping = activity.destroying;
        if (self.headless) return self;
        self.readConfig();
        activity.listener = .{ .ctx = self, .command = onCommand, .takes = takes, .input = onInput };
        activity.on_frame = onFrame;
        self.choreographer = ndk.AChoreographer_getInstance();
        if (activity.window) |w| self.attachScreen(w);
        return self;
    }

    pub fn shared() ?*App {
        return current;
    }

    pub fn destroy(self: *App) void {
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].close();
        self.windows.deinit(self.gpa);
        if (self.main_menu) |m| m.destroy();
        if (self.gl) |*g| g.deinit();
        if (current == self) {
            current = null;
            activity.listener = null;
            activity.on_frame = null;
        }
        self.gpa.destroy(self);
    }

    /// Pages are not supported on Android yet: services have no caller.
    pub fn bind(self: *App, service: anytype) !void {
        _ = self;
        _ = service;
    }

    pub fn registerEvent(self: *App, comptime E: type) !void {
        _ = self;
        _ = E;
    }

    pub fn newWindow(self: *App, options: window_mod.Options) !*Window {
        const w = try Window.create(self, options);
        errdefer w.close();
        try self.windows.append(self.gpa, w);
        self.arrange();
        return w;
    }

    /// Where a window shown now stacks: over every other.
    pub fn nextOrder(self: *App) u64 {
        self.next_order += 1;
        return self.next_order;
    }

    pub fn removeWindow(self: *App, w: *Window) void {
        for (self.windows.items, 0..) |item, i| if (item == w) {
            _ = self.windows.orderedRemove(i);
            break;
        };
        if (self.windows.items.len == 0 and self.options.quit_on_last_window_closed and self.running) self.quit();
    }

    /// Runs the app's loop until it quits or the activity goes. With
    /// `--nanoui-snapshot` it renders the first window offscreen instead.
    pub fn run(self: *App) !void {
        if (self.flags.generate_dir != null) return error.PagesUnsupported;
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        if (self.stopping or self.headless) return;
        self.running = true;
        defer self.running = false;
        while (!self.stopping) activity.poll(-1);
    }

    /// Ends `run`, and the activity with it.
    pub fn quit(self: *App) void {
        if (self.stopping) return;
        self.stopping = true;
        activity.wake();
        activity.finish();
    }

    /// From any thread: calls `func(ctx)` on the app's thread soon.
    pub fn onMain(ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        calls.after(0, ctx, func);
    }

    /// Files the system opens with the app: not taken on Android yet.
    pub fn onOpenFiles(_: *App, _: *anyopaque, _: *const fn (ctx: *anyopaque, paths: []const []const u8) void) void {}

    /// Calls `func(ctx)` on the app's thread after `ms` milliseconds.
    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        calls.after(ms, ctx, func);
    }

    /// Menus become the accelerators of a hardware keyboard.
    pub fn setMenu(self: *App, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, template);
        if (self.main_menu) |old| old.destroy();
        self.main_menu = m;
    }

    pub fn menuItem(self: *App, id: []const u8) ?*menu_mod.Item {
        const m = self.main_menu orelse return null;
        return m.item(id);
    }

    pub fn newTray(self: *App, opts: anytype) !noreturn {
        _ = self;
        _ = opts;
        return error.TraysUnsupported;
    }

    /// Runs the menu item whose accelerator `sc` is; true if one was.
    pub fn accelerator(self: *App, sc: ui.Shortcut) bool {
        const m = self.main_menu orelse return false;
        const it = m.match(sc) orelse return false;
        if (it.role) |role| switch (role) {
            .quit => {
                self.quit();
                return true;
            },
            .close => {
                // The window on top goes; the last one stays.
                if (self.top) |w| if (self.shownCount() > 1) w.close();
                return true;
            },
            .copy, .cut, .paste, .select_all, .undo, .redo, .delete => return false,
            else => {},
        };
        menu_mod.Menu.activate(it);
        return true;
    }

    fn shownCount(self: *App) usize {
        var n: usize = 0;
        for (self.windows.items) |w| n += @intFromBool(w.wanted and !w.closed);
        return n;
    }

    /// The Back key or gesture: Escape for the top window's view first (a
    /// menu or a sheet closes), else the top window closes, unless it is
    /// the last; then the app goes to the background, as Android sends an
    /// app's first screen there.
    pub fn back(self: *App) void {
        const top = self.top orelse return;
        if (top.surface) |s| if (keys.escape(s)) return;
        if (!top.closed and self.shownCount() > 1) return top.close();
        const ToBack = struct {
            fn run(_: ?*anyopaque, env: jni.Env) void {
                const a = activity.activity orelse return;
                _ = jni.call(env, a.clazz, "moveTaskToBack", "(Z)Z", &.{jni.boolean(true)});
            }
        };
        _ = activity.onUiThread(null, ToBack.run);
    }

    /// The activity is in front and has the focus.
    pub fn focused(_: *App) bool {
        return activity.resumed and activity.focused;
    }

    /// Puts the window shown last on top of the screen.
    pub fn arrange(self: *App) void {
        var want: ?*Window = null;
        for (self.windows.items) |w| {
            if (!w.wanted or w.closed) continue;
            if (want == null or w.order > want.?.order) want = w;
        }
        if (want == self.top) return;
        if (self.top) |old| {
            old.shown = false;
            if (old.surface) |s| s.covered();
        }
        self.top = want;
        const w = want orelse return;
        w.shown = true;
        if (w.surface) |s| {
            s.updateGeometry();
            s.requestFrame();
        }
    }

    /// The configuration the activity last told: dark mode, the
    /// display's density, animations.
    fn readConfig(self: *App) void {
        const c = activity.config;
        self.dark = c.dark;
        self.scale = @max(1, @as(f32, @floatFromInt(c.density)) / 160);
        self.reduced_motion = c.animations_off;
        for (self.windows.items) |w| if (w.surface) |s| {
            s.ctx.reduced_motion = self.reduced_motion;
        };
    }

    fn attachScreen(self: *App, w: *ndk.ANativeWindow) void {
        self.screen = w;
        if (!self.gl_tried and !self.cpu_only) {
            self.gl_tried = true;
            self.gl = egl.Gl.init();
            if (self.gl == null) std.log.warn("nanoui: no OpenGL ES 3: drawing on the CPU", .{});
        }
        if (self.gl) |*g| if (!g.attach(w)) self.cpuFromNow();
        // The CPU's frames: four bytes a pixel, the window's size.
        if (self.gl == null) _ = ndk.ANativeWindow_setBuffersGeometry(w, 0, 0, ndk.WINDOW_FORMAT_RGBA_8888);
        if (self.debug) std.debug.print("nanoui: drawing with {s}\n", .{if (self.gl != null) "OpenGL ES" else "the CPU"});
        self.geometryChanged();
    }

    /// OpenGL ES failed: the CPU draws from now on. The renderers' objects
    /// go with the context.
    pub fn cpuFromNow(self: *App) void {
        std.log.warn("nanoui: OpenGL ES failed: drawing on the CPU", .{});
        for (self.windows.items) |w| if (w.surface) |s| {
            s.renderer = null;
            s.ctx.renderer = "CPU";
        };
        if (self.gl) |*g| g.deinit();
        self.gl = null;
        if (self.screen) |w| _ = ndk.ANativeWindow_setBuffersGeometry(w, 0, 0, ndk.WINDOW_FORMAT_RGBA_8888);
    }

    fn detachScreen(self: *App) void {
        if (self.gl) |*g| g.detach();
        self.screen = null;
        self.screen_w = 0;
        self.screen_h = 0;
    }

    /// The screen's size or insets changed: the top window takes them.
    fn geometryChanged(self: *App) void {
        if (self.screen) |w| {
            self.screen_w = ndk.ANativeWindow_getWidth(w);
            self.screen_h = ndk.ANativeWindow_getHeight(w);
        }
        const top = self.top orelse return;
        const s = top.surface orelse return;
        s.updateGeometry();
        s.requestFrame();
    }

    /// Makes the GL context current for a surface to draw or free its
    /// renderer; false without one.
    pub fn makeCurrent(self: *App) bool {
        const g = &(self.gl orelse return false);
        return g.makeCurrent();
    }

    /// Icons on the bars that show over the view's background.
    pub fn barsFor(self: *App, light: bool) void {
        if (self.bars_light == light) return;
        self.bars_light = light;
        const Set = struct {
            fn run(ctx: ?*anyopaque, env: jni.Env) void {
                const a = activity.activity orelse return;
                bars.setLight(env, a.clazz, a.sdkVersion, ctx != null);
            }
        };
        _ = activity.onUiThread(if (light) @ptrFromInt(1) else null, Set.run);
    }

    /// A frame for the top window at the display's next refresh.
    pub fn wantFrame(self: *App) void {
        if (self.vsync_posted) return;
        const c = self.choreographer orelse return;
        self.vsync_posted = true;
        ndk.AChoreographer_postFrameCallback64(c, onVsync, null);
    }

    /// A frame for the top window `seconds` from now.
    pub fn wantFrameIn(self: *App, seconds: f32) void {
        const c = self.choreographer orelse return;
        const due = clock.now() + seconds;
        if (self.later_due != 0 and self.later_due <= due + 0.001) return;
        self.later_due = due;
        ndk.AChoreographer_postFrameCallbackDelayed64(c, onVsync, null, @intFromFloat(@max(1, @ceil(seconds * 1000))));
    }

    fn onVsync(_: i64, _: ?*anyopaque) callconv(.c) void {
        // Inside the looper's callbacks: the frame runs once it returns.
        activity.frame_due = true;
    }

    fn onFrame() void {
        const self = current orelse return;
        self.vsync_posted = false;
        if (self.later_due != 0 and clock.now() >= self.later_due - 0.002) self.later_due = 0;
        const top = self.top orelse return;
        const s = top.surface orelse return;
        touch.fling(s);
        if (!s.dead) s.frame();
    }

    fn onCommand(ctx: *anyopaque, cmd: activity.Command) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        switch (cmd) {
            .window_created => |w| self.attachScreen(w),
            .window_resized => self.geometryChanged(),
            .insets => |i| {
                if (self.debug) std.debug.print("nanoui: insets {any}, keyboard {d}\n", .{ i.bars, i.keyboard });
                self.geometryChanged();
            },
            // The window shows once this returns: drawn first.
            .window_redraw => if (self.top) |w| if (w.surface) |s| s.frame(),
            .window_destroyed => self.detachScreen(),
            .start, .resume_ => self.geometryChanged(),
            .stop => if (self.top) |w| if (w.surface) |s| s.stopMotion(),
            .config => {
                self.readConfig();
                if (self.debug) std.debug.print("nanoui: configuration: dark {}, scale {d}\n", .{ self.dark, self.scale });
                self.geometryChanged();
            },
            .destroy => self.quit(),
            .pause, .focus, .input_created, .input_destroyed => {},
        }
    }

    fn takes(ctx: *anyopaque, e: *const Event) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        const top = self.top orelse return false;
        if (top.surface == null) return false;
        return switch (e.*) {
            .motion => true,
            .key => |k| keys.takes(k),
        };
    }

    fn onInput(ctx: *anyopaque, e: *const Event) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const top = self.top orelse return;
        const s = top.surface orelse return;
        switch (e.*) {
            .motion => |*m| touch.handle(s, m),
            .key => |k| keys.handle(s, k),
        }
    }
};
