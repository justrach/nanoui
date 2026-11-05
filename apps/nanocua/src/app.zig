//! nanocua's state: the hub agents talk to, the socket it listens on, the
//! backend that runs the tools, the kill switch and its hot key, the switches
//! as graff and Harness see them (control.zig), and what the panel shows
//! (permissions, the command for agents, the log).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const mcp = @import("mcp.zig");
const server_mod = @import("server.zig");
const control = @import("control.zig");
const tools = @import("tools.zig");

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
    /// The user asked for Screen Recording: the panel says what's left to do.
    asked_screen: bool = false,
    /// The question a program asked, waiting in the panel.
    gate: control.Gate = .{},
    /// Whether the click being handled came from a person (none in tests:
    /// every click does). Turning something on needs one.
    real_pointer: ?*const fn () bool = null,
    /// Running under `--nanoui-hidden`: nothing comes forward, whoever asks.
    hidden: bool = false,
    /// Keeps the window above others while a question waits, or stops.
    raise: ?*const fn (window: *nanoui.Window, on: bool) void = null,
    /// A click that wasn't real was just ignored: the panel says so until then.
    ignored_until: f64 = 0,
    /// macOS's prompts open no more often than this.
    grant_after: f64 = 0,
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
        a.hub.control = .{ .ptr = a, .func = onControl };
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

    /// Turning something on from the panel: only a person's click counts.
    /// Turning it off always does.
    pub fn fromPanel(a: *App, want: control.Want, on: bool) void {
        if (on and !a.clickIsReal()) return;
        // nanoui's windows act on the click that brings them forward, so a click
        // meant only to focus this window can land here. This switch takes over
        // the real pointer, so it gets the card, and a second, deliberate click.
        if (on and want == .whole_screen) return a.askHere(want);
        switch (want) {
            .input => a.setInput(on),
            .whole_screen => a.setWholeScreen(on),
            .@"resume" => a.setStopped(!on),
        }
    }

    /// The user asking from this window: nobody's waiting, and a Deny of someone
    /// else's question doesn't hold them back.
    fn askHere(a: *App, want: control.Want) void {
        a.settleRequest();
        a.gate.quiet_until = 0;
        _ = a.gate.ask(want, "this window", 0, "", a.hub.clock());
        a.redraw();
    }

    fn clickIsReal(a: *App) bool {
        const real = if (a.real_pointer) |f| f() else true;
        if (!real) a.ignored_until = a.hub.clock() + 5;
        return real;
    }

    pub fn status(a: *App, outcome: ?[]const u8) control.Status {
        a.refreshPerms();
        const p = a.hub.policy;
        return .{
            .stopped = p.stopped,
            .input = p.allow_input,
            .wholeScreen = p.allow_whole_screen,
            .accessibility = a.perms.accessibility,
            .screenRecording = a.perms.screen,
            .agents = a.server.clients(),
            .calls = a.hub.log.calls,
            .stopKey = a.hotkey != null,
            .pending = if (a.gate.request) |r| @tagName(r.want) else null,
            .outcome = outcome,
        };
    }

    fn isOn(a: *const App, want: control.Want) bool {
        const p = a.hub.policy;
        return switch (want) {
            .input => p.allow_input,
            .whole_screen => p.allow_whole_screen,
            .@"resume" => !p.stopped,
        };
    }

    fn reply(a: *App, conn: u64, id: []const u8, outcome: ?[]const u8) void {
        const line = control.statusJson(a.gpa, a.status(outcome)) catch return;
        defer a.gpa.free(line);
        a.hub.sendResult(conn, id, line);
    }

    fn onControl(ptr: *anyopaque, conn: u64, id: []const u8, method: []const u8, params: ?std.json.Value) void {
        const a: *App = @ptrCast(@alignCast(ptr));
        a.server.markControl(conn);
        const args = tools.Args.of(params);
        const eql = std.mem.eql;
        const name = method["nanocua/".len..];
        if (eql(u8, name, "status")) {
            a.settleRequest();
            return a.reply(conn, id, null);
        }
        if (eql(u8, name, "stop")) {
            a.setStopped(true);
            return a.reply(conn, id, null);
        }
        if (eql(u8, name, "off")) {
            const what = control.Want.parse(args.string("what") orelse "") orelse .@"resume";
            switch (what) {
                .input => a.setInput(false),
                .whole_screen => a.setWholeScreen(false),
                // Off means off: nothing here can turn anything on.
                .@"resume" => return a.hub.sendError(conn, id, -32602, "Say input or whole_screen"),
            }
            return a.reply(conn, id, null);
        }
        if (eql(u8, name, "ask")) return a.onAsk(conn, id, args);
        if (eql(u8, name, "grant")) return a.onGrant(conn, id, args);
        if (eql(u8, name, "open")) {
            a.bringForward(false);
            return a.reply(conn, id, null);
        }
        a.hub.sendError(conn, id, -32601, "Method not found");
    }

    fn onAsk(a: *App, conn: u64, id: []const u8, args: tools.Args) void {
        const want = control.Want.parse(args.string("what") orelse "") orelse
            return a.hub.sendError(conn, id, -32602, "Say input, whole_screen or resume");
        if (a.isOn(want)) return a.reply(conn, id, "already_on");
        a.settleRequest();
        switch (a.gate.ask(want, args.string("from") orelse "", conn, id, a.hub.clock())) {
            .busy => a.reply(conn, id, "busy"),
            .quiet => a.reply(conn, id, "quiet"),
            // The answer comes when the user clicks (answer).
            .waiting => {
                a.bringForward(true);
                a.redraw();
            },
        }
    }

    fn onGrant(a: *App, conn: u64, id: []const u8, args: tools.Args) void {
        const which = args.string("which") orelse "";
        const ask_for: Ask = if (std.mem.eql(u8, which, "accessibility"))
            .accessibility
        else if (std.mem.eql(u8, which, "screen"))
            .screen
        else
            return a.hub.sendError(conn, id, -32602, "Say accessibility or screen");
        a.refreshPerms();
        const has = if (ask_for == .accessibility) a.perms.accessibility else a.perms.screen;
        if (has) return a.reply(conn, id, "already_allowed");
        const now = a.hub.clock();
        if (now < a.grant_after) return a.reply(conn, id, "quiet");
        a.grant_after = now + 5;
        a.request(ask_for);
        a.bringForward(false);
        a.reply(conn, id, "opened");
    }

    fn bringForward(a: *App, stay_above: bool) void {
        if (a.hidden) return;
        const w = a.window orelse return;
        if (a.raise) |f| f(w, true);
        w.focus();
        if (!stay_above) if (a.raise) |f| f(w, false);
    }

    /// The panel's Allow or Deny. Allow needs a person's click, and the question
    /// to have been on screen a moment.
    pub fn answer(a: *App, allow: bool) void {
        const now = a.hub.clock();
        if (allow) {
            if (!a.gate.armed(now) or !a.clickIsReal()) return;
            const r = a.gate.take() orelse return;
            switch (r.want) {
                .input => a.setInput(true),
                .whole_screen => a.setWholeScreen(true),
                .@"resume" => a.setStopped(false),
            }
            a.finishRequest(r, "allowed");
        } else {
            const r = a.gate.deny(now) orelse return;
            a.finishRequest(r, "denied");
        }
    }

    /// A question nobody answered goes away, and whoever asked is told.
    pub fn settleRequest(a: *App) void {
        if (!a.gate.expired(a.hub.clock())) return;
        const r = a.gate.take() orelse return;
        a.finishRequest(r, "expired");
    }

    fn finishRequest(a: *App, r: control.Request, outcome: []const u8) void {
        if (!a.hidden) if (a.window) |w| if (a.raise) |f| f(w, false);
        if (r.conn != 0) a.reply(r.conn, r.id(), outcome);
        a.redraw();
    }

    pub fn refreshPerms(a: *App) void {
        if (a.read_perms) |f| a.perms = f();
    }

    pub fn request(a: *App, which: Ask) void {
        if (which == .screen) a.asked_screen = true;
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
            a.real_pointer = @import("mac/pointer.zig").real;
            a.raise = backend_mod.raise;
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
