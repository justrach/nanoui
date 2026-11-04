//! `nanocua mcp`: what an agent runs as its MCP server. Handshakes and the
//! tool list are answered here, so adding nanocua to an agent starts nothing
//! and shows nothing. The first tools/call connects to the app, opening it (in
//! the background, through Launch Services) if it isn't running; from then on
//! calls go to its socket and its answers come back. The app does the work, so
//! macOS asks once for nanocua's permissions, not for each terminal or agent.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const sockpath = @import("sockpath.zig");
const server = @import("server.zig");
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");

extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn usleep(us: c_uint) c_int;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

const stdout = 1;

pub fn run(init: std.process.Init) !u8 {
    var buf: [512]u8 = undefined;
    var p: Proxy = .{
        .gpa = init.gpa,
        .path = try sockpath.path(&buf, init.environ_map, sockpath.realHome()),
        .hub = .{
            .gpa = init.gpa,
            .sink = .{ .ptr = undefined, .send = toStdout },
            .backend = .{ .ptr = undefined, .call = unreachableCall },
            .clock = zero,
        },
    };
    defer p.deinit();
    p.pump();
    return 0;
}

fn zero() f64 {
    return 0;
}

fn toStdout(_: *anyopaque, _: u64, line: []const u8) void {
    _ = server.writeAll(stdout, line);
    _ = server.writeAll(stdout, "\n");
}

/// Every tools/call goes to the app (Proxy.line): the hub here never runs one.
fn unreachableCall(_: *anyopaque, _: tools.Tool, _: tools.Args, reply: *mcp.Reply) void {
    reply.fail("nanocua mcp can't run tools itself");
}

/// Whether a line needs the app: only a tools/call does.
pub fn needsApp(gpa: std.mem.Allocator, line: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const msg = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return false;
    if (msg != .object) return false;
    const method = msg.object.get("method") orelse return false;
    return method == .string and std.mem.eql(u8, method.string, "tools/call");
}

/// The answer to a tools/call when the app can't be reached.
pub fn unreachableLine(a: std.mem.Allocator, line: []const u8, why: []const u8) ![]const u8 {
    const msg = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    const id = try std.json.Stringify.valueAlloc(a, msg.object.get("id") orelse .null, .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    try mcp.writeResult(&aw.writer, id, &.{.{ .text = why }}, true);
    return aw.written();
}

const not_running = "nanocua isn't running and couldn't be opened. Ask the user to open nanocua.app.";
const not_listening = "nanocua didn't start listening. Ask the user to open nanocua.app and check its window.";

const Proxy = struct {
    gpa: std.mem.Allocator,
    path: [:0]const u8,
    hub: mcp.Hub,
    /// The app's socket, once a call has needed it.
    fd: ?c_int = null,
    lines: server.Lines = .{},
    /// stdin ended or the app went away.
    done: bool = false,

    fn deinit(p: *Proxy) void {
        p.lines.deinit(p.gpa);
        if (p.fd) |fd| _ = close(fd);
    }

    /// stdin to the hub or the socket, the socket to stdout, until either ends.
    fn pump(p: *Proxy) void {
        var buf: [64 * 1024]u8 = undefined;
        while (!p.done) {
            var fds = [_]std.posix.pollfd{
                .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 },
                // A negative fd is ignored.
                .{ .fd = p.fd orelse -1, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = std.posix.poll(&fds, -1) catch return;
            if (fds[1].revents != 0) {
                const n = std.c.read(fds[1].fd, &buf, buf.len);
                // The app quit. Exiting closes the agent's end, so it can
                // start this again, rather than wait for answers forever.
                if (n <= 0 or !server.writeAll(stdout, buf[0..@intCast(n)])) return;
            }
            if (fds[0].revents != 0) {
                const n = std.c.read(0, &buf, buf.len);
                if (n <= 0 or !p.lines.feed(p.gpa, buf[0..@intCast(n)], p, line)) return;
            }
        }
    }

    fn line(p: *Proxy, l: []const u8) void {
        if (!needsApp(p.gpa, l)) return p.hub.handle(0, l);
        const fd = p.fd orelse p.open(l) orelse return;
        if (!server.writeAll(fd, l) or !server.writeAll(fd, "\n")) p.done = true;
    }

    /// Connects to the app, opening it if need be. On failure answers the
    /// call that wanted it and returns null: the next call tries again.
    fn open(p: *Proxy, l: []const u8) ?c_int {
        if (connect(p.path)) |fd| return p.keep(fd);
        if (!launch()) {
            p.answer(l, not_running);
            return null;
        }
        // The app starts in well under this; its first launch may ask the
        // user something first.
        for (0..100) |_| {
            _ = usleep(100_000);
            if (connect(p.path)) |fd| return p.keep(fd);
        }
        p.answer(l, not_listening);
        return null;
    }

    fn keep(p: *Proxy, fd: c_int) c_int {
        p.fd = fd;
        return fd;
    }

    fn answer(p: *Proxy, l: []const u8, why: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const reply = unreachableLine(arena.allocator(), l, why) catch return;
        toStdout(undefined, 0, reply);
    }
};

/// The app's socket, opening the app if it isn't running; null if it can't.
pub fn connectOrOpen(path: [:0]const u8) ?c_int {
    if (connect(path)) |fd| return fd;
    if (!launch()) return null;
    // The app starts in well under this; its first launch may ask the user
    // something first.
    for (0..100) |_| {
        _ = usleep(100_000);
        if (connect(path)) |fd| return fd;
    }
    return null;
}

pub fn connect(path: [:0]const u8) ?c_int {
    var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..path.len], path);
    const fd = socket(1, 1, 0);
    if (fd < 0) return null;
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) {
        _ = close(fd);
        return null;
    }
    return fd;
}

/// Opens nanocua.app if this program is inside it.
fn launch() bool {
    if (builtin.os.tag != .macos) return false;
    var buf: [1024]u8 = undefined;
    var size: u32 = buf.len;
    if (_NSGetExecutablePath(&buf, &size) != 0) return false;
    const exe = std.mem.sliceTo(&buf, 0);
    const end = std.mem.indexOf(u8, exe, ".app/Contents/MacOS/") orelse return false;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(exe[0 .. end + 4])});
    const config = objc.msg(objc.Object, objc.class("NSWorkspaceOpenConfiguration"), "configuration", .{});
    // Not in front of what the user is doing.
    objc.msg(void, config, "setActivates:", .{false});
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    objc.msg(void, ws, "openApplicationAtURL:configuration:completionHandler:", .{ url, config, @as(?*anyopaque, null) });
    return true;
}

test "only a tools/call needs the app" {
    const gpa = std.testing.allocator;
    try std.testing.expect(needsApp(gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"click\"}}"));
    try std.testing.expect(!needsApp(gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"));
    try std.testing.expect(!needsApp(gpa, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"));
    try std.testing.expect(!needsApp(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"));
    try std.testing.expect(!needsApp(gpa, "{nope"));
}

test "a call the app can't take is answered as the tool's error, with its id" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const out = try unreachableLine(arena.allocator(), "{\"id\":\"a\",\"method\":\"tools/call\"}", "open it");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"isError\":true") != null);
}
