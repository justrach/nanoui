//! The application on Linux: GTK's main loop, windows, menus' accelerators
//! and timers. Headless runs (`--nanoui-snapshot`, `--nanoui-generate`)
//! need no display and never start GTK. Otherwise GTK starts with the first
//! window: which GTK depends on whether it shows a page (`webkit.zig`).
const std = @import("std");
const gtk = @import("gtk.zig");
const dev = @import("../dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("../menu_accel.zig");
const ui = @import("../ui/ui.zig");
const tsgen = @import("../tsgen.zig");
const ipc = @import("../ipc.zig").ipc(window_mod.Window, App);
const Window = window_mod.Window;

pub const Options = struct {
    name: []const u8 = "nanoui",
    /// Quit when the last window closes.
    quit_on_last_window_closed: bool = true,
    // The macOS app's hooks, accepted here and not called yet.
    ctx: ?*anyopaque = null,
    on_open_urls: ?*const fn (ctx: ?*anyopaque, urls: []const []const u8) void = null,
    on_reopen: ?*const fn (ctx: ?*anyopaque) void = null,
    dock_menu: ?[]const menu_mod.MenuItem = null,
    on_terminate: ?*const fn (ctx: ?*anyopaque) void = null,
    on_continue_activity: ?*const fn (ctx: ?*anyopaque, url: []const u8) void = null,
    on_active: ?*const fn (ctx: ?*anyopaque, active: bool) void = null,
};

/// GTK 4's main loop, while it runs.
var main_loop: ?*anyopaque = null;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    windows: std.ArrayList(*Window) = .empty,
    main_menu: ?*menu_mod.Menu = null,
    flags: dev.Flags = .{},
    /// The services pages call (`bind`) and the events they listen for.
    services: std.StringHashMapUnmanaged(ipc.Service) = .empty,
    events: std.ArrayList(tsgen.Service) = .empty,
    /// `/nanoui.js`, made once and kept.
    client_js: ?[]u8 = null,
    /// The WebKitWebContext every page shares, and 6.0's network session.
    web_context: ?*anyopaque = null,
    web_session: ?*anyopaque = null,
    /// A run that needs no display: GTK never starts.
    headless: bool = false,
    /// GTK runs: windows show on a display.
    gui: bool = false,
    running: bool = false,
    stopping: bool = false,
    debug: bool = false,
    /// `NANOUI_RENDERER=cpu`: draw native UI on the CPU even where OpenGL is.
    cpu_only: bool = false,

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
            .headless = flags.snapshot != null or flags.generate_dir != null,
        };
        const headless = self.headless;
        // `kv.standard()` kept between launches, in the app's data
        // directory; never for headless runs (tests, snapshots).
        if (!headless and !flags.hidden) if (@import("desktop.zig").path(gpa, .data, options.name)) |dir| {
            defer gpa.free(dir);
            @import("../basics/kv.zig").attach(init.io, dir);
        } else |_| {};
        return self;
    }

    /// Brings GTK up, once, for a window that is about to be made. A page
    /// needs the GTK its WebKitGTK is built for, so it has the first say.
    pub fn startGtk(self: *App, for_page: bool) !void {
        if (self.gui or self.headless) return;
        if (for_page) @import("webkit.zig").prepare();
        if (!gtk.load()) return error.GtkMissing;
        if (!gtk.ready()) return error.NoDisplay;
        if (self.debug) std.debug.print("nanoui: GTK {d}\n", .{@as(u8, if (gtk.v4) 4 else 3)});
        self.gui = true;
    }

    pub fn destroy(self: *App) void {
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].close();
        self.windows.deinit(self.gpa);
        if (self.main_menu) |m| m.destroy();
        self.services.deinit(self.gpa);
        self.events.deinit(self.gpa);
        if (self.client_js) |js| self.gpa.free(js);
        if (self.web_session) |s| gtk.api.g_object_unref(s);
        if (self.web_context) |c| gtk.api.g_object_unref(c);
        self.gpa.destroy(self);
    }

    /// Makes a service's methods callable from pages.
    pub fn bind(self: *App, service: anytype) !void {
        const T = @typeInfo(@TypeOf(service)).pointer.child;
        const svc = ipc.service(T, service);
        try self.services.put(self.gpa, svc.name, svc);
        if (self.client_js) |js| self.gpa.free(js);
        self.client_js = null;
    }

    pub fn registerEvent(self: *App, comptime E: type) !void {
        try self.events.append(self.gpa, E.client);
        if (self.client_js) |js| self.gpa.free(js);
        self.client_js = null;
    }

    /// `/nanoui.js`: the client of every service and event, made once.
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

    /// `--nanoui-generate=DIR`: `nanoui.js` and `nanoui.d.ts` for a frontend.
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

    pub fn newWindow(self: *App, options: window_mod.Options) !*Window {
        const w = try Window.create(self, options);
        errdefer w.close();
        try self.windows.append(self.gpa, w);
        return w;
    }

    pub fn removeWindow(self: *App, w: *Window) void {
        for (self.windows.items, 0..) |item, i| if (item == w) {
            _ = self.windows.orderedRemove(i);
            break;
        };
        if (self.windows.items.len == 0 and self.options.quit_on_last_window_closed and self.running) self.quit();
    }

    pub fn run(self: *App) !void {
        if (self.flags.generate_dir) |dir| return self.writeClient(dir);
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        try self.startGtk(false);
        if (self.stopping or !self.gui) return;
        // `--nanoui-eval` drives the page rather than waiting on anyone: the
        // loop runs while the web process answers, then the app quits.
        if (self.flags.eval != null) {
            const seconds = if (self.flags.wait > 0) self.flags.wait else 5;
            after(@intFromFloat(seconds * 1000), self, quitNow);
        }
        self.running = true;
        if (gtk.v4) {
            // GTK 4 has no gtk_main: GLib's loop, quit by `quit`.
            const loop = gtk.api.g_main_loop_new(null, 0);
            main_loop = loop;
            gtk.api.g_main_loop_run(loop);
            main_loop = null;
            gtk.api.g_main_loop_unref(loop);
        } else gtk.v3.gtk_main();
        self.running = false;
    }

    pub fn quit(self: *App) void {
        if (self.stopping) return;
        self.stopping = true;
        if (!self.running) return;
        if (gtk.v4) {
            if (main_loop) |loop| gtk.api.g_main_loop_quit(loop);
        } else gtk.v3.gtk_main_quit();
    }

    fn quitNow(ctx: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.quit();
    }

    /// From any thread: calls `func(ctx)` on the main thread soon (GLib's
    /// main context takes sources from any thread).
    pub fn onMain(ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        after(0, ctx, func);
    }

    /// iPad's New Window (`ios/scenes.zig`): the system doesn't ask for windows here.
    pub fn onNewWindow(_: *App, _: *anyopaque, _: *const fn (ctx: *anyopaque, app: *App) void) void {}

    /// Files the system asks the app to open: on macOS only; here a file
    /// is named on the command line, which the app reads itself.
    pub fn onOpenFiles(_: *App, _: *anyopaque, _: *const fn (ctx: *anyopaque, paths: []const []const u8) void) void {}

    /// Calls `func(ctx)` on the main thread after `ms` milliseconds.
    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        const Timer = struct {
            ctx: ?*anyopaque,
            func: *const fn (?*anyopaque) callconv(.c) void,
            fn fire(data: ?*anyopaque) callconv(.c) c_int {
                const t: *@This() = @ptrCast(@alignCast(data));
                t.func(t.ctx);
                std.heap.c_allocator.destroy(t);
                return 0;
            }
        };
        if (!gtk.load()) return;
        const t = std.heap.c_allocator.create(Timer) catch return;
        t.* = .{ .ctx = ctx, .func = func };
        _ = gtk.api.g_timeout_add(@intCast(ms), Timer.fire, t);
    }

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
                if (self.windows.items.len > 0) self.windows.items[0].close();
                return true;
            },
            // Text editing goes to the focused field.
            .copy, .cut, .paste, .select_all, .undo, .redo, .delete => return false,
            else => {},
        };
        menu_mod.Menu.activate(it);
        return true;
    }
};
