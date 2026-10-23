//! The application on Linux: GTK's main loop, windows, menus' accelerators
//! and timers. Headless runs (`--nanoui-snapshot`, `--nanoui-generate`)
//! need no display and never start GTK.
const std = @import("std");
const gtk = @import("gtk.zig");
const dev = @import("../dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("../menu_accel.zig");
const ui = @import("../ui/ui.zig");
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
        };
        const headless = flags.snapshot != null or flags.generate_dir != null;
        if (!headless) {
            if (!gtk.load()) return error.GtkMissing;
            const ok = if (gtk.v4) gtk.v4api.gtk_init_check() else gtk.v3.gtk_init_check(null, null);
            if (ok == 0) return error.NoDisplay;
            if (self.debug) std.debug.print("nanoui: GTK {d}\n", .{@as(u8, if (gtk.v4) 4 else 3)});
            self.gui = true;
        }
        return self;
    }

    pub fn destroy(self: *App) void {
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].close();
        self.windows.deinit(self.gpa);
        if (self.main_menu) |m| m.destroy();
        self.gpa.destroy(self);
    }

    /// Pages are not supported on Linux yet: services have no caller.
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
        if (self.flags.generate_dir != null) return error.PagesUnsupported;
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        if (self.stopping or !self.gui) return;
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

    /// From any thread: calls `func(ctx)` on the main thread soon (GLib's
    /// main context takes sources from any thread).
    pub fn onMain(ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        after(0, ctx, func);
    }

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
