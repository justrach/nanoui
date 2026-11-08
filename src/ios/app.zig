//! The application on iOS: UIKit's lifecycle around nanoui's windows.
//!
//! `App.run` hands the main thread to `UIApplicationMain`, which never
//! returns. Windows made before it are shown once UIKit is up: the first
//! fills the screen, later ones cover it (`arrange`). With a scene
//! manifest in Info.plist (as `tools/ios/bundle.zig` writes it) a scene
//! delegate gets the screen; without one the app delegate does, as before
//! iOS 13. Headless runs (`--nanoui-snapshot`) render offscreen and never
//! start UIKit.
const std = @import("std");
const objc = @import("../objc.zig");
const dev = @import("../dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("../menu_accel.zig");
const ui = @import("../ui/ui.zig");
const scenes = @import("scenes.zig");
const tsgen = @import("../tsgen.zig");
const ipc = @import("../ipc.zig").ipc(Window, App);
const Window = window_mod.Window;

extern "c" fn UIApplicationMain(argc: c_int, argv: [*]?[*:0]u8, principal: ?objc.Object, delegate: ?objc.Object) c_int;
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*]?[*:0]u8;
extern "c" fn CFRunLoopGetMain() *anyopaque;
extern "c" fn CFRunLoopPerformBlock(loop: *anyopaque, mode: *const anyopaque, block: *anyopaque) void;
extern "c" fn CFRunLoopWakeUp(loop: *anyopaque) void;
extern "c" const kCFRunLoopCommonModes: *const anyopaque;

pub const Options = struct {
    name: []const u8 = "nanoui",
    /// Kept for the desktop's sake: iOS apps never quit themselves.
    quit_on_last_window_closed: bool = true,
};

/// The one app: UIKit makes its delegates itself, by class name.
var current: ?*App = null;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    windows: std.ArrayList(*Window) = .empty,
    main_menu: ?*menu_mod.Menu = null,
    /// What pages call (`ipc.zig`), and the client they load it through.
    services: std.StringHashMapUnmanaged(ipc.Service) = .empty,
    events: std.ArrayList(tsgen.Service) = .empty,
    client_js: ?[]u8 = null,
    /// Windows waiting for their own scene, and what makes one for the system's
    /// New Window (`scenes.zig`).
    pending_scenes: std.ArrayList(*Window) = .empty,
    on_new_window: ?struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, app: *App) void } = null,
    answering_scene: bool = false,
    flags: dev.Flags = .{},
    /// The UIWindow nanoui's windows show in, once UIKit made it.
    uiwindow: ?objc.Object = null,
    /// What the screen shows while no window of the app does.
    placeholder: ?objc.Object = null,
    /// In the foreground: frames are drawn (never in the background).
    active: bool = true,
    /// Where the next window shown stacks: over every other.
    next_order: u64 = 0,
    /// `arrange`'s state: a present or dismiss of its own under way (its
    /// completion arranges again); a transition awaited, or a timed try
    /// again; one running; a call made while it ran (UIKit ran a frame);
    /// one on the next turn; timed tries in a row, given up after a few.
    transitioning: bool = false,
    awaiting: bool = false,
    arranging: bool = false,
    arrange_again: bool = false,
    arrange_scheduled: bool = false,
    tries: u32 = 0,
    running: bool = false,
    stopping: bool = false,
    debug: bool = false,

    /// Creates the app. Call from `main`, on the main thread.
    pub fn create(init: std.process.Init, options: Options) !*App {
        if (!objc.isMainThread()) return error.NotMainThread;
        const gpa = init.gpa;
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = init.io,
            .options = options,
            .flags = try dev.Flags.parse(init),
            .debug = init.environ_map.get("NANOUI_DEBUG") != null,
        };
        current = self;
        return self;
    }

    /// The app, for what UIKit calls without one (dialogs, delegates).
    pub fn shared() ?*App {
        return current;
    }

    pub fn destroy(self: *App) void {
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].close();
        self.windows.deinit(self.gpa);
        self.pending_scenes.deinit(self.gpa);
        self.services.deinit(self.gpa);
        self.events.deinit(self.gpa);
        if (self.client_js) |js| self.gpa.free(js);
        if (self.main_menu) |m| m.destroy();
        if (self.placeholder) |p| objc.release(p);
        if (self.uiwindow) |w| objc.release(w);
        if (current == self) current = null;
        self.gpa.destroy(self);
    }

    /// Binds a service: pages call its methods as `Name.method(...)`
    /// through the generated client (`nanoui.js`).
    pub fn bind(self: *App, service: anytype) !void {
        const T = @typeInfo(@TypeOf(service)).pointer.child;
        const svc = ipc.service(T, service);
        try self.services.put(self.gpa, svc.name, svc);
    }

    /// Declares a typed event (`nanoui.Event(...)`) for the generated client.
    pub fn registerEvent(self: *App, comptime E: type) !void {
        try self.events.append(self.gpa, E.client);
    }

    /// The generated JavaScript client, served to pages at `/nanoui.js`.
    pub fn clientJs(self: *App) ![]const u8 {
        if (self.client_js) |js| return js;
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        try aw.writer.writeAll(tsgen.runtime_js);
        var it = self.services.valueIterator();
        while (it.next()) |svc| try aw.writer.writeAll(svc.client.js);
        for (self.events.items) |e| try aw.writer.writeAll(e.js);
        self.client_js = try aw.toOwnedSlice();
        return self.client_js.?;
    }

    pub fn newWindow(self: *App, options: window_mod.Options) !*Window {
        const w = try Window.create(self, options);
        errdefer w.close();
        try self.windows.append(self.gpa, w);
        if (w.own_scene) {
            // Not up yet: `attach` asks. Where there are no scenes to have, on the stack.
            if (self.uiwindow == null or scenes.request(self, w)) return w;
            w.own_scene = false;
        }
        if (self.uiwindow != null) {
            w.realize();
            self.arrange();
        }
        return w;
    }

    /// What makes a window when the system opens a new one of the app (iPad's New
    /// Window, a window restored): `func` calls `newWindow` with `.own_scene`.
    pub fn onNewWindow(self: *App, ctx: *anyopaque, func: *const fn (ctx: *anyopaque, app: *App) void) void {
        self.on_new_window = .{ .ctx = ctx, .func = func };
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
    }

    /// Runs UIKit: it never returns while the app runs. With
    /// `--nanoui-snapshot` it renders the first window offscreen instead.
    pub fn run(self: *App) !void {
        // The client is written from a Mac or a PC's build; a phone has no project to write it into.
        if (self.flags.generate_dir != null) return error.GenerateUnsupported;
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        if (self.stopping) return;
        self.running = true;
        if (self.flags.play) |steps| @import("../play.zig").start(self, steps);
        _ = scenes.defineClasses();
        const name = objc.nsString("NanoUIAppDelegate");
        _ = UIApplicationMain(_NSGetArgc().*, _NSGetArgv().*, null, name);
        self.running = false;
    }

    /// iOS apps don't quit themselves (the system ends them): before `run`,
    /// it keeps `run` from starting UIKit; after, it does nothing.
    pub fn quit(self: *App) void {
        self.stopping = true;
    }

    /// Calls `func(ctx)` on the main thread after `ms` milliseconds.
    /// From any thread: calls `func(ctx)` on the main thread soon. True
    /// when queued (GCD's main queue always takes it), as on the Mac.
    pub fn onMain(ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) bool {
        objc.dispatchMain(ctx, func);
        return true;
    }

    /// Files the system opens with the app: not taken on iOS yet.
    pub fn onOpenFiles(_: *App, _: *anyopaque, _: *const fn (ctx: *anyopaque, paths: []const []const u8) void) void {}

    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        objc.dispatchAfter(ms * std.time.ns_per_ms, ctx, func);
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
            .quit => return true,
            .close => {
                // The window on top goes; the screen's own stays.
                const top = self.topController() orelse return true;
                if (top == objc.msg(?objc.Object, self.uiwindow.?, "rootViewController", .{})) return true;
                for (self.windows.items) |w| if (w.controller == top) {
                    w.close();
                    break;
                };
                return true;
            },
            .copy, .cut, .paste, .select_all, .undo, .redo, .delete => return false,
            else => {},
        };
        menu_mod.Menu.activate(it);
        return true;
    }

    /// The controller everything is presented from: the topmost one.
    pub fn topController(self: *App) ?objc.Object {
        const win = self.uiwindow orelse return null;
        var vc = objc.msg(?objc.Object, win, "rootViewController", .{}) orelse return null;
        while (objc.msg(?objc.Object, vc, "presentedViewController", .{})) |next| {
            if (objc.msg(objc.BOOL, next, "isBeingDismissed", .{})) break;
            vc = next;
        }
        return vc;
    }

    /// `arrange` on the next turn of the run loop. Not a block on the main
    /// queue: a dialog opened by a frame it runs spins the run loop, and
    /// the main queue, which brings UIKit's animations to their ends,
    /// runs no other block until that one returns.
    pub fn scheduleArrange(self: *App) void {
        if (self.arrange_scheduled) return;
        self.arrange_scheduled = true;
        var block = objc.Block(App, &.{}).init(self, arrangeLater);
        const loop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, @ptrCast(&block));
        CFRunLoopWakeUp(loop);
    }

    fn arrangeLater(self: *App) void {
        self.arrange_scheduled = false;
        self.arrange();
    }

    /// Makes the screen show the windows wanted, in the order they were
    /// shown: the first is the UIWindow's root, each later one presented
    /// full screen over the one before. One present or dismiss runs at a
    /// time, never during another transition (UIKit queues or refuses
    /// those); each one's end arranges again. A dialog presented over the
    /// windows stays: what's under it changes once it is answered.
    pub fn arrange(self: *App) void {
        // Called again by a frame UIKit ran inside: once more after this.
        if (self.arranging) {
            self.arrange_again = true;
            return;
        }
        self.arranging = true;
        defer self.arranging = false;
        var passes: u32 = 0;
        while (passes < 8) : (passes += 1) {
            self.arrange_again = false;
            if (!self.arrangeStep() and !self.arrange_again) break;
        }
        if (self.arrange_again) self.scheduleArrange();
        self.markShown();
        if (!self.transitioning) self.refocus();
    }

    /// One change toward the windows wanted; true if the next can follow
    /// at once (the root changed).
    fn arrangeStep(self: *App) bool {
        if (self.transitioning or self.awaiting) return false;
        const win = self.uiwindow orelse return false;
        const root = objc.msg(?objc.Object, win, "rootViewController", .{}) orelse return false;
        if (self.awaitTransition(root)) return false;
        const want_root = if (self.nth(0)) |w| w.controller.? else self.placeholder.?;
        if (root != want_root) {
            // What the old root presents goes first, all at once; then the
            // root is swapped (a window it presented can become it).
            if (objc.msg(?objc.Object, root, "presentedViewController", .{})) |above| {
                if (!owned(above)) return false;
                self.dismiss(root, false);
                return false;
            }
            objc.msg(void, win, "setRootViewController:", .{want_root});
            self.tries = 0;
            return true;
        }
        var vc = root;
        var i: usize = 1;
        while (objc.msg(?objc.Object, vc, "presentedViewController", .{})) |next| : (i += 1) {
            const want = self.nth(i);
            if (want != null and want.?.controller.? == next) {
                vc = next;
                continue;
            }
            // A window that must go (and every one over it), unless a
            // dialog is up there: then once it is answered.
            if (owned(next)) self.dismiss(vc, true);
            return false;
        }
        if (self.nth(i)) |w| self.present(w.controller.?, vc) else self.tries = 0;
        return false;
    }

    /// The `i`th window from the bottom of those wanted on screen.
    fn nth(self: *App, i: usize) ?*Window {
        var last: ?*Window = null;
        for (0..i + 1) |_| {
            var best: ?*Window = null;
            for (self.windows.items) |w| {
                if (!w.wanted or w.closed or w.controller == null or w.own_scene) continue;
                if (last) |l| if (w.order <= l.order) continue;
                if (best == null or w.order < best.?.order) best = w;
            }
            last = best orelse return null;
        }
        return last;
    }

    /// Whether `vc` and every controller presented over it are windows'
    /// (open or closed), none a dialog's.
    fn owned(vc: objc.Object) bool {
        const cls = window_mod.controllerClass();
        var it: ?objc.Object = vc;
        while (it) |v| : (it = objc.msg(?objc.Object, v, "presentedViewController", .{})) {
            if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{cls})) return false;
        }
        return true;
    }

    /// A controller presented or dismissed now: UIKit queues a present or
    /// dismiss asked of it (or of one under it) until that ends.
    pub fn moving(vc: objc.Object) bool {
        return objc.msg(?objc.Object, vc, "transitionCoordinator", .{}) != null or
            objc.msg(objc.BOOL, vc, "isBeingPresented", .{}) or
            objc.msg(objc.BOOL, vc, "isBeingDismissed", .{});
    }

    /// A transition running in the chain from `root`: arranges again once
    /// it ends, and true.
    fn awaitTransition(self: *App, root: objc.Object) bool {
        var it: ?objc.Object = root;
        while (it) |v| : (it = objc.msg(?objc.Object, v, "presentedViewController", .{})) {
            if (!moving(v)) continue;
            if (objc.msg(?objc.Object, v, "transitionCoordinator", .{})) |c| {
                self.awaiting = true;
                var done = objc.Block(App, &.{?objc.Object}).init(self, transitionEnded);
                _ = objc.msg(objc.BOOL, c, "animateAlongsideTransition:completion:", .{ @as(?*anyopaque, null), @as(*anyopaque, @ptrCast(&done)) });
            } else self.tryLater(50); // a transition ending, its coordinator gone
            return true;
        }
        return false;
    }

    // Each end arranges on the next turn, not inside UIKit's own ending
    // of the transition (where a present would be queued again).
    fn transitionEnded(self: *App, _: ?objc.Object) void {
        self.awaiting = false;
        self.scheduleArrange();
    }

    fn transitionDone(self: *App) void {
        self.transitioning = false;
        self.scheduleArrange();
    }

    fn triedAgain(ptr: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(ptr));
        self.awaiting = false;
        self.scheduleArrange();
    }

    /// Arranges again in `ms`, a few times in a row at most: then waits
    /// for the next change (a window shown or closed, a dialog answered).
    fn tryLater(self: *App, ms: u64) void {
        if (self.tries == 20) {
            std.log.warn("nanoui: UIKit won't change the windows on screen; waiting for the next change", .{});
            self.tries = 0;
            return;
        }
        self.tries += 1;
        self.awaiting = true;
        objc.dispatchAfter(ms * std.time.ns_per_ms, self, triedAgain);
    }

    /// Presents `vc` over `from`; its end arranges again.
    fn present(self: *App, vc: objc.Object, from: objc.Object) void {
        self.transitioning = true;
        var done = objc.Block(App, &.{}).init(self, transitionDone);
        objc.msg(void, from, "presentViewController:animated:completion:", .{ vc, objc.YES, @as(*anyopaque, @ptrCast(&done)) });
        if (objc.msg(?objc.Object, from, "presentedViewController", .{}) == vc) {
            self.tries = 0;
        } else self.notTaken(from);
    }

    /// Dismisses what `from` presents, and everything over it.
    fn dismiss(self: *App, from: objc.Object, animated: bool) void {
        self.transitioning = true;
        var done = objc.Block(App, &.{}).init(self, transitionDone);
        objc.msg(void, from, "dismissViewControllerAnimated:completion:", .{ animated, @as(*anyopaque, @ptrCast(&done)) });
        const above = objc.msg(?objc.Object, from, "presentedViewController", .{});
        if (above == null or objc.msg(objc.BOOL, above.?, "isBeingDismissed", .{})) {
            self.tries = 0;
        } else self.notTaken(from);
    }

    /// A present or dismiss UIKit didn't start: queued behind a transition
    /// (its completion still comes), or refused (UIKit logged why).
    fn notTaken(self: *App, from: objc.Object) void {
        if (moving(from)) return;
        self.transitioning = false;
        self.tryLater(250);
    }

    /// Which windows the screen shows now: the root and those presented
    /// over it, not on their way out.
    fn markShown(self: *App) void {
        for (self.windows.items) |w| {
            if (!w.own_scene) w.shown = false;
        }
        const win = self.uiwindow orelse return;
        var it = objc.msg(?objc.Object, win, "rootViewController", .{});
        while (it) |v| : (it = objc.msg(?objc.Object, v, "presentedViewController", .{})) {
            if (objc.msg(objc.BOOL, v, "isBeingDismissed", .{})) break;
            for (self.windows.items) |w| if (w.controller == v) {
                w.shown = true;
            };
        }
    }

    /// A window went: a keyboard's keys go to the one now on top.
    pub fn refocus(self: *App) void {
        const top = self.topController() orelse return;
        for (self.windows.items) |w| if (w.controller == top) {
            if (w.surface) |s| @import("keys.zig").takeKeys(s);
            return;
        };
    }

    /// UIKit made the window the app shows in: nanoui's windows go in it.
    pub fn attach(self: *App, uiwindow: objc.Object) void {
        self.uiwindow = objc.retain(uiwindow);
        self.placeholder = objc.new("UIViewController");
        // Made now, or kept from a scene that went. The first takes the
        // screen at once; the others go over it once it is on screen.
        for (self.windows.items) |w| {
            if (!w.own_scene) w.realize();
        }
        const root = if (self.nth(0)) |w| w.controller.? else self.placeholder.?;
        // Its first frame may show or close windows: `arrange` waits.
        self.arranging = true;
        objc.msg(void, uiwindow, "setRootViewController:", .{root});
        objc.msg(void, uiwindow, "makeKeyAndVisible", .{});
        self.arranging = false;
        self.markShown();
        self.scheduleArrange();
        // Windows made before UIKit ran that asked for a scene of their own.
        const early = self.gpa.dupe(*Window, self.windows.items) catch return;
        defer self.gpa.free(early);
        for (early) |w| if (w.own_scene and w.controller == null and !scenes.request(self, w)) {
            w.own_scene = false;
            w.realize();
            self.arrange();
        };
    }

    /// Foreground and background: frames stop in the background, where
    /// the GPU is not the app's, and the one waiting runs on return.
    pub fn setActive(self: *App, on: bool) void {
        if (self.active == on) return;
        self.active = on;
        // A frame waiting may close a window: go through a copy, skipping
        // the windows gone since.
        const list = self.gpa.dupe(*Window, self.windows.items) catch return;
        defer self.gpa.free(list);
        for (list) |w| {
            if (std.mem.indexOfScalar(*Window, self.windows.items, w) == null) continue;
            if (w.surface) |s| s.activeChanged(on);
        }
    }

    /// The system let the scene go (it may connect a new one later): the
    /// windows leave its UIWindow, free to go in the next one's.
    pub fn detach(self: *App) void {
        const win = self.uiwindow orelse return;
        // A dialog up goes with it, unanswered: its wait ends.
        @import("dialog.zig").scene_gone +%= 1;
        if (objc.msg(?objc.Object, win, "rootViewController", .{})) |root| {
            objc.msg(void, root, "dismissViewControllerAnimated:completion:", .{ objc.NO, @as(?*anyopaque, null) });
        }
        objc.msg(void, win, "setRootViewController:", .{@as(?objc.Object, null)});
        objc.release(win);
        if (self.placeholder) |p| objc.release(p);
        self.placeholder = null;
        self.uiwindow = null;
        self.transitioning = false;
        self.awaiting = false;
        self.markShown();
    }
};
