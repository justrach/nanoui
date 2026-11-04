//! `nanocua ctl`: the switches from a command line, for `graff computer` and
//! Harness. It reads the state and turns things off at once. `allow` only asks:
//! the question appears in nanocua's window and this waits for the click.
const std = @import("std");
const control = @import("control.zig");
const proxy = @import("proxy.zig");
const server = @import("server.zig");
const sockpath = @import("sockpath.zig");

extern "c" fn close(fd: c_int) c_int;

pub const usage =
    \\usage: nanocua ctl <command> [--json] [--from=NAME]
    \\  status                     what's on, and what macOS has granted
    \\  stop                       refuse every call, at once
    \\  off <input|whole_screen>   turn a switch off, at once
    \\  allow <input|whole_screen|resume>   ask; you answer in nanocua's window
    \\  grant <accessibility|screen>   open macOS's prompt for a permission
    \\  open                       bring nanocua's window forward
    \\
;

/// How long `allow` waits for the click: a little past the question's own end.
const answer_ms: i32 = @intFromFloat((control.lifetime + 5) * 1000);
const reply_ms: i32 = 5_000;

pub const Command = struct {
    method: []const u8,
    /// Its `params`, as JSON.
    params: []const u8 = "{}",
    /// Starts the app if it isn't running; else there's nothing to do.
    opens_app: bool = false,
    wait_ms: i32 = reply_ms,
};

/// What a command line asks for; null if it makes no sense.
pub fn parse(a: std.mem.Allocator, args: []const []const u8, from: []const u8) !?Command {
    if (args.len == 0) return null;
    const verb = args[0];
    const object = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, verb, "status") and args.len == 1) return .{ .method = "nanocua/status" };
    if (std.mem.eql(u8, verb, "stop") and args.len == 1) return .{ .method = "nanocua/stop" };
    if (std.mem.eql(u8, verb, "open") and args.len == 1) return .{ .method = "nanocua/open", .opens_app = true };
    if (args.len != 2) return null;
    if (std.mem.eql(u8, verb, "off")) {
        const w = control.Want.parse(object) orelse return null;
        if (w == .@"resume") return null;
        return .{ .method = "nanocua/off", .params = try paramsJson(a, .{ .what = object }) };
    }
    if (std.mem.eql(u8, verb, "allow")) {
        _ = control.Want.parse(object) orelse return null;
        return .{ .method = "nanocua/ask", .params = try paramsJson(a, .{ .what = object, .from = from }), .opens_app = true, .wait_ms = answer_ms };
    }
    if (std.mem.eql(u8, verb, "grant")) {
        if (!std.mem.eql(u8, object, "accessibility") and !std.mem.eql(u8, object, "screen")) return null;
        return .{ .method = "nanocua/grant", .params = try paramsJson(a, .{ .which = object }), .opens_app = true };
    }
    return null;
}

fn paramsJson(a: std.mem.Allocator, v: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}

/// The status as a person reads it.
pub fn describe(a: std.mem.Allocator, s: control.Status) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    if (s.outcome) |o| {
        const line: ?[]const u8 = if (std.mem.eql(u8, o, "allowed"))
            "Allowed."
        else if (std.mem.eql(u8, o, "denied"))
            "Denied in nanocua's window."
        else if (std.mem.eql(u8, o, "expired"))
            "Nobody answered in nanocua's window."
        else if (std.mem.eql(u8, o, "busy"))
            "nanocua's window is already waiting for an answer."
        else if (std.mem.eql(u8, o, "quiet"))
            "Just denied: try again in a few seconds."
        else if (std.mem.eql(u8, o, "unreachable"))
            "Couldn't reach nanocua: open nanocua.app."
        else if (std.mem.eql(u8, o, "already_on"))
            "It's already on: there's nothing to answer."
        else if (std.mem.eql(u8, o, "already_allowed"))
            "macOS already allows it."
        else if (std.mem.eql(u8, o, "opened"))
            "macOS's prompt or its settings should be open: turn nanocua on there."
        else
            null;
        if (line) |l| try w.print("{s}\n", .{l});
    }
    if (!s.running) {
        try w.writeAll("nanocua isn't running.\n");
        return aw.written();
    }
    const state = if (s.stopped) "stopped" else if (s.input) "acting" else "looking only";
    try w.print("nanocua: {s}, whole screen {s}, {d} agent{s}, {d} call{s}\n", .{ state, if (s.wholeScreen) "on" else "off", s.agents, if (s.agents == 1) "" else "s", s.calls, if (s.calls == 1) "" else "s" });
    try w.print("macOS: Accessibility {s}, Screen Recording {s}\n", .{ if (s.accessibility) "allowed" else "not allowed", if (s.screenRecording) "allowed" else "not allowed" });
    if (s.pending) |p| try w.print("Waiting in nanocua's window: {s}\n", .{p});
    return aw.written();
}

fn show(a: std.mem.Allocator, s: control.Status, json: bool) !void {
    const text = if (json) blk: {
        const line = try control.statusJson(a, s);
        break :blk try std.fmt.allocPrint(a, "{s}\n", .{line});
    } else try describe(a, s);
    _ = server.writeAll(1, text);
}

pub fn run(init: std.process.Init, args: []const [:0]const u8) !u8 {
    const a = init.arena.allocator();
    var json = false;
    var from: []const u8 = "nanocua ctl";
    var words: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.startsWith(u8, arg, "--from=")) {
            from = arg["--from=".len..];
        } else try words.append(a, arg);
    }
    const cmd = try parse(a, words.items, from) orelse {
        _ = server.writeAll(2, usage);
        return 2;
    };
    var buf: [512]u8 = undefined;
    const path = try sockpath.path(&buf, init.environ_map, sockpath.realHome());
    const fd = (if (cmd.opens_app) proxy.connectOrOpen(path) else proxy.connect(path)) orelse {
        try show(a, .{ .running = false, .outcome = if (cmd.opens_app) "unreachable" else "not_running" }, json);
        return 0;
    };
    defer _ = close(fd);
    const line = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}\n", .{ cmd.method, cmd.params });
    if (!server.writeAll(fd, line)) return unreachableApp(a, json);
    const reply = readLine(a, fd, cmd.wait_ms) catch return unreachableApp(a, json);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, reply, .{}) catch return unreachableApp(a, json);
    const result = (if (parsed == .object) parsed.object.get("result") else null) orelse return unreachableApp(a, json);
    if (json) {
        const text = try std.json.Stringify.valueAlloc(a, result, .{});
        _ = server.writeAll(1, text);
        _ = server.writeAll(1, "\n");
        return 0;
    }
    const s = try std.json.parseFromValueLeaky(control.Status, a, result, .{ .ignore_unknown_fields = true });
    try show(a, s, false);
    return 0;
}

fn unreachableApp(a: std.mem.Allocator, json: bool) !u8 {
    try show(a, .{ .running = false, .outcome = "unreachable" }, json);
    return 0;
}

fn readLine(a: std.mem.Allocator, fd: c_int, wait_ms: i32) ![]const u8 {
    var got: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, wait_ms) == 0) return error.TimedOut;
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n <= 0) return error.Closed;
        try got.appendSlice(a, chunk[0..@intCast(n)]);
        if (std.mem.indexOfScalar(u8, got.items, '\n')) |nl| return got.items[0..nl];
    }
}

test "command lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = struct {
        fn f(al: std.mem.Allocator, args: []const []const u8) !?Command {
            return parse(al, args, "graff");
        }
    }.f;
    try std.testing.expectEqualStrings("nanocua/status", (try p(a, &.{"status"})).?.method);
    try std.testing.expect(!(try p(a, &.{"stop"})).?.opens_app);
    const allow = (try p(a, &.{ "allow", "whole_screen" })).?;
    try std.testing.expect(allow.opens_app and allow.wait_ms > 60_000);
    try std.testing.expectEqualStrings("{\"what\":\"whole_screen\",\"from\":\"graff\"}", allow.params);
    try std.testing.expectEqualStrings("{\"which\":\"screen\"}", (try p(a, &.{ "grant", "screen" })).?.params);
    try std.testing.expect((try p(a, &.{ "off", "resume" })) == null);
    try std.testing.expect((try p(a, &.{ "allow", "everything" })) == null);
    try std.testing.expect((try p(a, &.{ "grant", "camera" })) == null);
    try std.testing.expect((try p(a, &.{ "stop", "now" })) == null);
    try std.testing.expect((try p(a, &.{})) == null);
}

test "what a person reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("nanocua isn't running.\n", try describe(a, .{ .running = false, .outcome = "not_running" }));
    const on = try describe(a, .{ .input = true, .agents = 1, .calls = 2, .accessibility = true, .outcome = "allowed", .pending = "resume" });
    try std.testing.expect(std.mem.startsWith(u8, on, "Allowed.\nnanocua: acting, whole screen off, 1 agent, 2 calls\n"));
    try std.testing.expect(std.mem.indexOf(u8, on, "Accessibility allowed, Screen Recording not allowed") != null);
    try std.testing.expect(std.mem.endsWith(u8, on, "Waiting in nanocua's window: resume\n"));
    try std.testing.expect(std.mem.indexOf(u8, try describe(a, .{ .stopped = true }), "nanocua: stopped") != null);
    try std.testing.expect(std.mem.startsWith(u8, try describe(a, .{ .outcome = "already_on" }), "It's already on"));
}
