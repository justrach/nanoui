//! nanocua's state: the hub agents talk to, the socket it listens on, the
//! backend that runs the tools, the kill switch and its hot key, and what
//! the panel shows (permissions, the command for agents, the log).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const mcp = @import("mcp.zig");
const server_mod = @import("server.zig");

pub const mac = builtin.os.tag == .macos;
const backend_mod = if (mac) @import("mac/backend.zig") else @import("backend_none.zig");
const HotKey = if (mac) @import("mac/hotkey.zig").HotKey else void;

pub const Perms = struct {
    accessibility: bool = false,
    screen: bool = false,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    hub: mcp.Hub,
    server: server_mod.Server,
    /// The kill switch where the backend's queue reads it.
    stop_flag: ?*std.atomic.Value(bool) = null,
    /// The whole-screen switch where the backend's queue reads it.
    whole_flag: ?*std.atomic.Value(bool) = null,
    hotkey: ?HotKey = null,
    window: ?*nanoui.Window = null,
    /// Why the socket isn't open, if it isn't.
    listen_error: ?[]const u8 = null,
    socket_buf: [512]u8 = undefined,
    socket_path: []const u8 = "",
    /// What an agent's MCP settings run.
    command_buf: [1024]u8 = undefined,
    command: []const u8 = "nanocua mcp",
    /// The permissions as last read; how to read them (none in tests).
    perms: Perms = .{},
    read_perms: ?*const fn () Perms = null,
    ask: ?*const fn (which: Ask) void = null,
    /// "Copied" shows for a while after copying the command.
    copied_until: f64 = 0,
    /// Light or dark, fixed (tests); else as the system is.
    dark: ?bool = null,

    pub const Ask = enum { accessibility, screen };

    /// Sets `a` up in place: the hub writes through `a.server`.
    pub fn init(a: *App, gpa: std.mem.Allocator, backend: mcp.Backend) void {
        a.* = .{
            .gpa = gpa,
            .server = .{ .gpa = gpa, .hub = &a.hub },
            .hub = .{ .gpa = gpa, .sink = undefined, .backend = backend, .clock = nanoui.ui.clock.now },
        };
        a.hub.sink = a.server.sink();
        a.hub.changed = .{ .ptr = a, .func = changed };
    }

    pub fn deinit(a: *App) void {
        if (comptime mac) if (a.hotkey) |*h| h.deinit();
        a.server.deinit();
    }

    /// Opens the socket at `path`; on failure the panel says why.
    pub fn listen(a: *App, path: [:0]const u8) void {
        a.socket_path = std.fmt.bufPrint(&a.socket_buf, "{s}", .{path}) catch "";
        if (!server_mod.supported) {
            a.listen_error = "Agents can't connect on this system yet.";
            return;
        }
        @import("sockpath.zig").makeDir(path);
        a.server.listen(path) catch |e| {
            a.listen_error = switch (e) {
                error.AlreadyRunning => "Another nanocua is already serving agents.",
                else => "Couldn't open the socket for agents.",
            };
        };
    }

    /// The command agents run, from this program's path.
    pub fn setCommand(a: *App, exe: []const u8) void {
        a.command = std.fmt.bufPrint(&a.command_buf, "{s} mcp", .{exe}) catch a.command;
    }

    /// The kill switch, also on ⌃⌥⌘. (macOS).
    pub fn stopKey(a: *App) void {
        if (comptime !mac) return;
        a.hotkey = .{ .ctx = a, .func = stopPressed };
        if (!a.hotkey.?.register()) a.hotkey = null;
    }

    fn stopPressed(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.setStopped(true);
    }

    pub fn setStopped(a: *App, stopped: bool) void {
        a.hub.policy.stopped = stopped;
        if (a.stop_flag) |f| f.store(stopped, .release);
        a.redraw();
    }

    pub fn setInput(a: *App, on: bool) void {
        a.hub.policy.allow_input = on;
        a.redraw();
    }

    pub fn setWholeScreen(a: *App, on: bool) void {
        a.hub.policy.allow_whole_screen = on;
        if (a.whole_flag) |f| f.store(on, .release);
        a.redraw();
    }

    pub fn refreshPerms(a: *App) void {
        if (a.read_perms) |f| a.perms = f();
    }

    pub fn request(a: *App, which: Ask) void {
        if (a.ask) |f| f(which);
    }

    fn changed(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.redraw();
    }

    fn redraw(a: *App) void {
        if (a.window) |w| w.redraw();
    }
};

/// The platform's backend and permissions, for main.
pub const Platform = struct {
    impl: if (mac) backend_mod.Mac else backend_mod.None,

    pub fn init(gpa: std.mem.Allocator) Platform {
        return .{ .impl = if (mac) backend_mod.Mac.init(gpa) else .{} };
    }

    /// Wires the backend into `a` (after `a.init`).
    pub fn attach(p: *Platform, a: *App) void {
        a.hub.backend = p.impl.backend();
        if (comptime mac) {
            a.stop_flag = &p.impl.stopped;
            a.whole_flag = &p.impl.whole_screen;
            a.read_perms = readPerms;
            a.ask = ask;
        }
    }

    fn readPerms() Perms {
        return .{ .accessibility = backend_mod.accessibility(), .screen = backend_mod.screenRecording() };
    }

    fn ask(which: App.Ask) void {
        backend_mod.request(switch (which) {
            .accessibility => .accessibility,
            .screen => .screen,
        });
    }
};
