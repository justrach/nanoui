//! The application on Windows: the message loop, windows, menus'
//! accelerators and timers. Headless runs (`--nanoui-snapshot`) open no
//! window.
const std = @import("std");
const w = @import("win32.zig");
const dev = @import("../dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("../menu_accel.zig");
const ui = @import("../ui/ui.zig");
const Window = window_mod.Window;

pub const Options = struct {
    name: []const u8 = "nanoui",
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

const Timer = struct { id: usize, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void };
var timers: [64]?Timer = @splat(null);

fn onTimer(_: ?w.HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    _ = w.KillTimer(null, id);
    for (&timers) |*slot| if (slot.*) |t| if (t.id == id) {
        slot.* = null;
        t.func(t.ctx);
        return;
    };
}

/// Kills every timer still waiting, so none fires into a torn-down app.
fn clearTimers() void {
    for (&timers) |*slot| if (slot.*) |t| {
        _ = w.KillTimer(null, t.id);
        slot.* = null;
    };
}

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    windows: std.ArrayList(*Window) = .empty,
    main_menu: ?*menu_mod.Menu = null,
    flags: dev.Flags = .{},
    gui: bool = false,
    running: bool = false,
    stopping: bool = false,
    debug: bool = false,

    pub fn create(init: std.process.Init, options: Options) !*App {
        const gpa = init.gpa;
        const self = try gpa.create(App);
        errdefer gpa.destroy(self);
        const flags = try dev.Flags.parse(init);
        self.* = .{ .gpa = gpa, .io = init.io, .options = options, .flags = flags, .debug = init.environ_map.get("NANOUI_DEBUG") != null };
        self.gui = flags.snapshot == null and flags.generate_dir == null;
        // Pixels, not stretched bitmaps: nanoui draws at the monitor's DPI,
        // per monitor — a window carried to another screen hears about it
        // (`WM_DPICHANGED`) and rescales. Before Windows 10 1607 there is no
        // such call: system awareness, the oldest way, is the fallback.
        if (self.gui) {
            if (w.SetProcessDpiAwarenessContext(-4) == 0) _ = w.SetProcessDPIAware();
        }
        // Where other threads' calls for the main thread arrive (`onMain`).
        @import("fdwatch.zig").prepare() catch {};
        return self;
    }

    pub fn destroy(self: *App) void {
        // No timer outlives the app: one that fired after this would call its
        // function with a context that is already gone.
        clearTimers();
        // `destroyNow`, not `close`: `close` only posts the request and waits for
        // a message loop that is not running any more, so this drained nothing
        // and spun forever.
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].destroyNow();
        self.windows.deinit(self.gpa);
        if (self.main_menu) |m| m.destroy();
        self.gpa.destroy(self);
    }

    pub fn bind(self: *App, service: anytype) !void {
        _ = self;
        _ = service;
    }

    pub fn registerEvent(self: *App, comptime E: type) !void {
        _ = self;
        _ = E;
    }

    pub fn newWindow(self: *App, options: window_mod.Options) !*Window {
        const win = try Window.create(self, options);
        errdefer win.close();
        try self.windows.append(self.gpa, win);
        return win;
    }

    pub fn removeWindow(self: *App, win: *Window) void {
        for (self.windows.items, 0..) |item, i| if (item == win) {
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
        var msg: w.MSG = undefined;
        // A modal dialog (a message box, a file dialog) pumps its own loop
        // while it is up: a quit asked for inside one is consumed there, and
        // this loop hears of it when the dialog is gone — the usual Windows
        // arithmetic, and one more reason `close` defers.
        while (w.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        self.running = false;
    }

    pub fn quit(self: *App) void {
        if (self.stopping) return;
        self.stopping = true;
        if (self.running) w.PostQuitMessage(0);
    }

    /// Files the system asks the app to open: on macOS only; here a file
    /// is named on the command line, which the app reads itself.
    pub fn onOpenFiles(_: *App, _: *anyopaque, _: *const fn (ctx: *anyopaque, paths: []const []const u8) void) void {}

    /// From any thread: calls `func(ctx)` on the main thread soon.
    pub fn onMain(ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        _ = @import("fdwatch.zig").post(ctx, func);
    }

    pub fn after(ms: u64, ctx: ?*anyopaque, func: *const fn (?*anyopaque) callconv(.c) void) void {
        // A slot first: a timer with nowhere to be remembered would fire once
        // into nothing, its callback silently dropped.
        var slot: ?*?Timer = null;
        for (&timers) |*t| if (t.* == null) {
            slot = t;
            break;
        };
        const s = slot orelse {
            std.log.warn("nanoui: more than {d} timers pending; one for {d} ms is dropped", .{ timers.len, ms });
            return;
        };
        const id = w.SetTimer(null, 0, @intCast(@max(1, ms)), onTimer);
        if (id == 0) return;
        s.* = .{ .id = id, .ctx = ctx, .func = func };
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

    pub fn accelerator(self: *App, sc: ui.Shortcut) bool {
        const m = self.main_menu orelse return false;
        const it = m.match(sc) orelse return false;
        if (it.role) |role| switch (role) {
            .quit => {
                self.quit();
                return true;
            },
            .close => {
                // The window that has the keyboard, not just the first one made.
                for (self.windows.items) |win| if (win.isFocused()) {
                    win.close();
                    return true;
                };
                if (self.windows.items.len > 0) self.windows.items[0].close();
                return true;
            },
            .copy, .cut, .paste, .select_all, .undo, .redo, .delete => return false,
            else => {},
        };
        menu_mod.Menu.activate(it);
        return true;
    }
};
