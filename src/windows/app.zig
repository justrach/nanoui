//! The application on Windows: the message loop, windows, menus'
//! accelerators and timers. Headless runs (`--nanoui-snapshot`) open no
//! window.
const std = @import("std");
const w = @import("win32.zig");
const dev = @import("../dev.zig");
const window_mod = @import("window.zig");
const menu_mod = @import("../menu_accel.zig");
const ui = @import("../ui/ui.zig");
const tsgen = @import("../tsgen.zig");
const ipc = @import("../ipc.zig").ipc(window_mod.Window, App);
const Window = window_mod.Window;

// `CoInitializeEx`: COM's apartment, which WebView2 needs on the thread that
// makes it. `COINIT_APARTMENTTHREADED` is what a windowed UI wants.
extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
const coinit_apartment_threaded: u32 = 0x2;

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
    /// `%LOCALAPPDATA%`, where WebView2 keeps its profile (`page_webview2.zig`).
    local_appdata: ?[]const u8 = null,
    /// The services pages call (`bind`) and the events they listen for.
    services: std.StringHashMapUnmanaged(ipc.Service) = .empty,
    events: std.ArrayList(tsgen.Service) = .empty,
    /// `/nanoui.js`, made once and kept.
    client_js: ?[]u8 = null,
    /// `NANOUI_WEBVIEW_PROFILE`: a user data folder of one's own, for tests
    /// that must not share one with the app's.
    webview_profile: ?[]const u8 = null,
    /// Whether this thread holds a COM apartment (`CoInitializeEx`).
    com: bool = false,
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
        if (init.environ_map.get("LOCALAPPDATA")) |v| self.local_appdata = v;
        if (init.environ_map.get("NANOUI_WEBVIEW_PROFILE")) |v| self.webview_profile = v;
        self.gui = flags.snapshot == null and flags.generate_dir == null;
        // A GUI app (pages, dialogs, the shell) calls COM: the main thread's
        // apartment is made here, before any window asks for it.
        if (self.gui) {
            _ = CoInitializeEx(null, coinit_apartment_threaded);
            self.com = true;
        }
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
        self.services.deinit(self.gpa);
        self.events.deinit(self.gpa);
        if (self.client_js) |js| self.gpa.free(js);
        if (self.com) CoUninitialize();
        self.gpa.destroy(self);
    }

    pub fn bind(self: *App, service: anytype) !void {
        try self.bindService(service);
    }

    /// `bind`, for the services an app makes: kept by name for the pages.
    fn bindService(self: *App, service: anytype) !void {
        const T = @typeInfo(@TypeOf(service)).pointer.child;
        const svc = ipc.service(T, service);
        try self.services.put(self.gpa, svc.name, svc);
        self.client_js = null;
    }

    pub fn registerEvent(self: *App, comptime E: type) !void {
        try self.events.append(self.gpa, E.client);
        self.client_js = null;
    }

    pub fn newWindow(self: *App, options: window_mod.Options) !*Window {
        const win = try Window.create(self, options);
        errdefer win.close();
        try self.windows.append(self.gpa, win);
        // A window made while the loop runs starts its page's WebView2 here:
        // `run` only started the windows that existed before it.
        if (self.running) if (win.page) |p| p.start();
        return win;
    }

    /// `/nanoui.js`: the bridge's JavaScript plus the client of every
    /// service and event, made once.
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
            try aw.writer.print("\n{s}", .{p.dts});
            try aw.writer.print("{s}", .{p.js});
        }
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

    pub fn removeWindow(self: *App, win: *Window) void {
        for (self.windows.items, 0..) |item, i| if (item == win) {
            _ = self.windows.orderedRemove(i);
            break;
        };
        if (self.windows.items.len == 0 and self.options.quit_on_last_window_closed and self.running) self.quit();
    }

    pub fn run(self: *App) !void {
        if (self.flags.generate_dir) |dir| return self.writeClient(dir);
        if (self.flags.snapshot) |path| return dev.snapshot(self, path);
        // `--nanoui-eval`: the page is driven, not watched. The loop runs
        // while WebView2's asynchronous calls land, then the app quits.
        if (self.flags.eval) |_| {
            const seconds = if (self.flags.wait > 0) self.flags.wait else 5;
            return self.runSeconds(seconds);
        }
        if (self.stopping or !self.gui) return;
        self.running = true;
        var msg: w.MSG = undefined;
        // A page's WebView2 is asked for now, with a loop to hear its answer.
        for (self.windows.items) |win| if (win.page) |p| p.start();
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

    /// Runs the loop until `app.quit`, a page's `nanoui.window.close` on the
    /// last window, or `seconds` pass (0: no deadline). `--nanoui-eval`'s
    /// mode: the messages the webview's asynchronous calls land as still
    /// arrive, and nothing is drawn to the screen.
    pub fn runSeconds(self: *App, seconds: f64) !void {
        self.running = true;
        for (self.windows.items) |win| if (win.page) |p| p.start();
        const clock = @import("../ui/clock.zig");
        const start = clock.now();
        var msg: w.MSG = undefined;
        while (!self.stopping) {
            while (w.PeekMessageW(&msg, null, 0, 0, 1) != 0) {
                if (msg.message == w.WM_QUIT) {
                    self.stopping = true;
                    break;
                }
                _ = w.TranslateMessage(&msg);
                _ = w.DispatchMessageW(&msg);
            }
            if (self.stopping) break;
            if (seconds > 0 and clock.now() - start > seconds) break;
            _ = w.MsgWaitForMultipleObjects(0, null, 0, 10, w.QS_ALLINPUT);
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
