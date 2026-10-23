//! The application: lifecycle, the menu bar, tray icons, bound services, timers.
const std = @import("std");
const objc = @import("objc.zig");
const ipc = @import("ipc.zig");
const tsgen = @import("tsgen.zig");
const dev = @import("dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("menu.zig");
const tray_mod = @import("tray.zig");
const Window = window_mod.Window;

pub const Options = struct {
    name: []const u8 = "nanoui",
    /// Quit when the last window closes.
    quit_on_last_window_closed: bool = true,
    /// Given to the hooks below.
    ctx: ?*anyopaque = null,
    /// Links the system asks the app to open (the default browser's).
    on_open_urls: ?*const fn (ctx: ?*anyopaque, urls: []const []const u8) void = null,
    /// The Dock icon was clicked with no window showing.
    on_reopen: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The Dock icon's menu, above the system's items.
    dock_menu: ?[]const menu_mod.MenuItem = null,
    /// The app is about to quit (⌘Q, its last window, `quit`): save what must be saved.
    on_terminate: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Handoff from another device: the page's address.
    on_continue_activity: ?*const fn (ctx: ?*anyopaque, url: []const u8) void = null,
    /// The app became active (true) or stopped being active.
    on_active: ?*const fn (ctx: ?*anyopaque, active: bool) void = null,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    nsapp: objc.Object,
    delegate: objc.Object,
    windows: std.ArrayList(*Window) = .empty,
    services: std.StringHashMapUnmanaged(ipc.Service) = .empty,
    events: std.ArrayList(tsgen.Service) = .empty,
    main_menu: ?*menu_mod.Menu = null,
    dock_menu: ?*menu_mod.Menu = null,
    trays: std.ArrayList(*tray_mod.Tray) = .empty,
    /// The generated client, built once on first request.
    client_js: ?[]u8 = null,
    flags: dev.Flags = .{},
    running: bool = false,
    stopping: bool = false,
    /// `NANOUI_DEBUG=1`: log windows' ids and frames, for tools and tests.
    debug: bool = false,
    /// Files the system asks the app to open (Finder's Open With, `open -a`,
    /// a file named when it was launched); without it they're ignored.
    open_files: ?OpenFiles = null,

    pub const OpenFiles = struct {
        ctx: *anyopaque,
        /// The files' paths, valid for the call.
        func: *const fn (ctx: *anyopaque, paths: []const []const u8) void,
    };

    /// Takes the files the system asks the app to open.
    pub fn onOpenFiles(self: *App, ctx: *anyopaque, func: *const fn (ctx: *anyopaque, paths: []const []const u8) void) void {
        self.open_files = .{ .ctx = ctx, .func = func };
    }

    /// Creates the app. Call from `main`, on the main thread.
    pub fn create(init: std.process.Init, options: Options) !*App {
        if (!objc.isMainThread()) return error.NotMainThread;
        const gpa = init.gpa;
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);

        const flags = try dev.Flags.parse(init);

        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        const delegate_class = objc.defineClass(.{
            .name = "NanoUIAppDelegate",
            .protocols = &.{"NSApplicationDelegate"},
            .methods = &.{
                .{ .name = "applicationDidFinishLaunching:", .imp = &didFinishLaunching, .types = "v@:@" },
                .{ .name = "applicationShouldTerminate:", .imp = &shouldTerminate, .types = "Q@:@" },
                .{ .name = "applicationShouldHandleReopen:hasVisibleWindows:", .imp = &shouldReopen, .types = "c@:@c" },
                .{ .name = "application:openURLs:", .imp = &openURLs, .types = "v@:@@" },
                .{ .name = "applicationDockMenu:", .imp = &dockMenu, .types = "@@:@" },
                .{ .name = "application:continueUserActivity:restorationHandler:", .imp = &continueActivity, .types = "c@:@@@?" },
                .{ .name = "applicationDidBecomeActive:", .imp = &becameActive, .types = "v@:@" },
                .{ .name = "applicationDidResignActive:", .imp = &resignedActive, .types = "v@:@" },
            },
        });
        const delegate = objc.msg(objc.Object, delegate_class, "new", .{});
        objc.setZig(delegate, self);

        self.* = .{
            .gpa = gpa,
            .io = init.io,
            .options = options,
            .nsapp = nsapp,
            .delegate = delegate,
            .flags = flags,
            .debug = init.environ_map.get("NANOUI_DEBUG") != null,
        };
        // A plain binary (not an .app bundle) still gets a Dock icon and
        // menus; hidden runs (tests, snapshots) get neither, nor focus.
        const policy: objc.NSInteger = if (flags.hidden) 2 else 0;
        _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{policy});
        objc.msg(void, nsapp, "setDelegate:", .{delegate});
        try self.setMenu(&default_menu);
        return self;
    }

    pub fn destroy(self: *App) void {
        while (self.windows.items.len > 0) {
            const w = self.windows.items[self.windows.items.len - 1];
            w.close();
        }
        self.windows.deinit(self.gpa);
        self.services.deinit(self.gpa);
        self.events.deinit(self.gpa);
        for (self.trays.items) |t| t.destroy();
        self.trays.deinit(self.gpa);
        if (self.main_menu) |m| m.destroy();
        if (self.dock_menu) |m| m.destroy();
        if (self.client_js) |js| self.gpa.free(js);
        objc.setZig(self.delegate, null);
        objc.msg(void, self.nsapp, "setDelegate:", .{@as(?objc.Object, null)});
        objc.release(self.delegate);
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

    pub fn newWindow(self: *App, options: window_mod.Options) !*Window {
        const w = try Window.create(self, options);
        errdefer w.close();
        try self.windows.append(self.gpa, w);
        return w;
    }

    pub fn removeWindow(self: *App, w: *Window) void {
        for (self.windows.items, 0..) |item, i| {
            if (item == w) {
                _ = self.windows.orderedRemove(i);
                break;
            }
        }
        if (self.windows.items.len == 0 and self.options.quit_on_last_window_closed and self.running) self.quit();
    }

    /// Runs the event loop until the app quits. With
    /// `--nanoui-generate=<dir>` it writes the client instead and returns.
    pub fn run(self: *App) !void {
        if (self.flags.generate_dir) |dir| return self.writeClient(dir);
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        // Quit before the loop started: nothing to run.
        if (self.stopping) return;
        self.running = true;
        if (self.flags.play) |steps| @import("play.zig").start(self, steps);
        objc.msg(void, self.nsapp, "run", .{});
        self.running = false;
    }

    /// Stops the event loop; `run` returns once the current event is handled.
    pub fn quit(self: *App) void {
        if (self.stopping) return;
        self.stopping = true;
        if (self.options.on_terminate) |f| f(self.options.ctx);
        if (!self.running) return;
        objc.msg(void, self.nsapp, "stop:", .{@as(?objc.Object, null)});
        // `stop:` takes effect after the next event: post one.
        const ev = objc.msg(objc.Object, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
            @as(objc.NSUInteger, 15), objc.CGPoint{}, @as(objc.NSUInteger, 0), @as(f64, 0), @as(objc.NSInteger, 0), @as(?objc.Object, null), @as(i16, 0), @as(objc.NSInteger, 0), @as(objc.NSInteger, 0),
        });
        objc.msg(void, self.nsapp, "postEvent:atStart:", .{ ev, objc.YES });
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

    /// The generated declarations of the client (`nanoui.d.ts`).
    pub fn clientDts(self: *App, gpa: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.writeAll(tsgen.runtime_dts);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        var parts: std.ArrayList(tsgen.Service) = .empty;
        defer parts.deinit(gpa);
        // Services sorted by name, so the output is stable.
        var it = self.services.valueIterator();
        while (it.next()) |svc| try parts.append(gpa, svc.client);
        std.mem.sort(tsgen.Service, parts.items, {}, struct {
            fn lt(_: void, x: tsgen.Service, y: tsgen.Service) bool {
                return std.mem.lessThan(u8, x.dts, y.dts);
            }
        }.lt);
        try parts.appendSlice(gpa, self.events.items);
        for (parts.items) |p| {
            for (p.decls) |d| {
                if ((try seen.getOrPut(gpa, d.name)).found_existing) continue;
                try aw.writer.print("\n{s}\n", .{d.source});
            }
        }
        for (parts.items) |p| try aw.writer.print("\n{s}", .{p.dts});
        return aw.toOwnedSlice();
    }

    fn writeClient(self: *App, dir_path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, dir_path);
        var dir = try cwd.openDir(self.io, dir_path, .{});
        defer dir.close(self.io);
        const dts = try self.clientDts(self.gpa);
        defer self.gpa.free(dts);
        try dir.writeFile(self.io, .{ .sub_path = "nanoui.d.ts", .data = dts });
        try dir.writeFile(self.io, .{ .sub_path = "nanoui.js", .data = try self.clientJs() });
        std.log.info("nanoui: wrote {s}/nanoui.js and nanoui.d.ts", .{dir_path});
    }

    /// From any thread: calls `func(ctx)` on the main thread soon.
    pub fn onMain(ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        objc.dispatchMain(ctx, func);
    }

    /// Calls `func(ctx)` on the main thread after `ms` milliseconds.
    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        objc.dispatchAfter(ms * std.time.ns_per_ms, ctx, func);
    }

    /// Replaces the menu bar with one built from `template`.
    pub fn setMenu(self: *App, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, self.options.name, template);
        objc.msg(void, self.nsapp, "setMainMenu:", .{m.ns});
        if (m.windows_menu) |w| objc.msg(void, self.nsapp, "setWindowsMenu:", .{w});
        if (self.main_menu) |old| old.destroy();
        self.main_menu = m;
    }

    /// The menu bar's item whose template had `id`.
    pub fn menuItem(self: *App, id: []const u8) ?*menu_mod.Item {
        const m = self.main_menu orelse return null;
        return m.item(id);
    }

    /// Adds an icon to the menu bar's status area; it lives until removed
    /// with `Tray.destroy` or the app ends. Not when the app runs hidden.
    pub fn newTray(self: *App, opts: tray_mod.Options) !*tray_mod.Tray {
        // Headless runs (snapshots, scripts, tests) keep out of the menu bar.
        if (self.flags.hidden) return error.Hidden;
        const t = try tray_mod.Tray.create(self.gpa, self.options.name, opts);
        errdefer t.destroy();
        try self.trays.append(self.gpa, t);
        return t;
    }

    /// The menu every app starts with: the app menu, Edit, View, Window.
    pub const default_menu = [_]menu_mod.MenuItem{
        .{ .role = .app_menu },
        .{ .role = .edit_menu },
        .{ .role = .view_menu },
        .{ .role = .window_menu },
    };
};

fn didFinishLaunching(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    if (objc.getZig(App, self_obj)) |app| if (app.flags.hidden) return;
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, nsapp, "activateIgnoringOtherApps:", .{objc.YES});
}

fn shouldTerminate(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.NSUInteger {
    // AppKit would call exit(); stop the loop instead so `App.run` returns.
    if (objc.getZig(App, self_obj)) |app| app.quit();
    return 0; // NSTerminateCancel
}

fn shouldReopen(self_obj: objc.Object, _: objc.SEL, _: objc.Object, visible: objc.BOOL) callconv(.c) objc.BOOL {
    const app = objc.getZig(App, self_obj) orelse return !visible;
    if (!visible) if (app.options.on_reopen) |f| {
        f(app.options.ctx);
        return objc.NO;
    };
    return !visible;
}

fn openURLs(self_obj: objc.Object, _: objc.SEL, _: objc.Object, urls: objc.Object) callconv(.c) void {
    const app = objc.getZig(App, self_obj) orelse return;
    if (app.open_files) |handler| {
        const pool = objc.Pool.push();
        defer pool.pop();
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(app.gpa);
        const n = objc.msg(objc.NSUInteger, urls, "count", .{});
        var i: objc.NSUInteger = 0;
        while (i < n) : (i += 1) {
            const url = objc.msg(objc.Object, urls, "objectAtIndex:", .{i});
            if (objc.msg(objc.BOOL, url, "isFileURL", .{}) == objc.NO) continue;
            const path = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
            if (path.len > 0) paths.append(app.gpa, path) catch {};
        }
        if (paths.items.len > 0) handler.func(handler.ctx, paths.items);
    }
    const f = app.options.on_open_urls orelse return;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const n = objc.msg(objc.NSUInteger, urls, "count", .{});
    const list = arena.allocator().alloc([]const u8, n) catch return;
    for (list, 0..) |*s, i| {
        const url = objc.msg(objc.Object, urls, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        s.* = arena.allocator().dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}))) catch "";
    }
    f(app.options.ctx, list);
}

fn dockMenu(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) ?objc.Object {
    const app = objc.getZig(App, self_obj) orelse return null;
    const template = app.options.dock_menu orelse return null;
    if (app.dock_menu == null) app.dock_menu = menu_mod.Menu.create(app.gpa, app.options.name, template) catch return null;
    return app.dock_menu.?.ns;
}

fn continueActivity(self_obj: objc.Object, _: objc.SEL, _: objc.Object, activity: objc.Object, _: ?*anyopaque) callconv(.c) objc.BOOL {
    const app = objc.getZig(App, self_obj) orelse return objc.NO;
    const f = app.options.on_continue_activity orelse return objc.NO;
    const url = objc.msg(?objc.Object, activity, "webpageURL", .{}) orelse return objc.NO;
    f(app.options.ctx, objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{})));
    return objc.YES;
}

fn becameActive(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const app = objc.getZig(App, self_obj) orelse return;
    if (app.options.on_active) |f| f(app.options.ctx, true);
}

fn resignedActive(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const app = objc.getZig(App, self_obj) orelse return;
    if (app.options.on_active) |f| f(app.options.ctx, false);
}
