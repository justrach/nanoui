//! The app's end of the socket: accepts agents' connections on the main
//! thread (a dispatch source on macOS, the GTK loop on Linux; nothing
//! polls), splits what they send into lines for the hub, and writes the
//! hub's answers back. A connection is a number to the hub, so an answer
//! for one that closed is dropped. Not on Windows yet.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const mcp = @import("mcp.zig");

pub const supported = builtin.os.tag == .macos or (builtin.os.tag == .linux and !builtin.abi.isAndroid());
const fdwatch = nanoui.fdwatch;

extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn signal(sig: c_int, handler: usize) usize;
const af_unix = 1;
const sock_stream = 1;
const sigpipe = 13;

/// Lines out of a stream of bytes; a line longer than `max` closes it.
pub const Lines = struct {
    pub const max = 32 << 20;
    buf: std.ArrayList(u8) = .empty,

    /// Calls `f(ctx, line)` for each whole line in what came; false if a
    /// line grew too long.
    pub fn feed(l: *Lines, gpa: std.mem.Allocator, bytes: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8) void) bool {
        l.buf.appendSlice(gpa, bytes) catch return false;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, l.buf.items, start, '\n')) |nl| {
            f(ctx, std.mem.trimEnd(u8, l.buf.items[start..nl], "\r"));
            start = nl + 1;
        }
        const rest = l.buf.items.len - start;
        std.mem.copyForwards(u8, l.buf.items[0..rest], l.buf.items[start..]);
        l.buf.shrinkRetainingCapacity(rest);
        return rest <= max;
    }

    pub fn deinit(l: *Lines, gpa: std.mem.Allocator) void {
        l.buf.deinit(gpa);
    }
};

const Conn = struct {
    server: *Server,
    id: u64,
    fd: c_int,
    watch: ?fdwatch.Watch = null,
    lines: Lines = .{},
    /// It uses the switches, so it isn't an agent.
    control: bool = false,

    fn readable(ctx: ?*anyopaque) callconv(.c) void {
        if (comptime !supported) return;
        const c: *Conn = @ptrCast(@alignCast(ctx));
        var buf: [64 * 1024]u8 = undefined;
        const n = std.c.read(c.fd, &buf, buf.len);
        if (n <= 0) return c.server.drop(c.id);
        if (!c.lines.feed(c.server.gpa, buf[0..@intCast(n)], c, line)) c.server.drop(c.id);
    }

    fn line(c: *Conn, l: []const u8) void {
        c.server.hub.handle(c.id, l);
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    hub: *mcp.Hub,
    fd: c_int = -1,
    watch: ?fdwatch.Watch = null,
    conns: std.AutoArrayHashMapUnmanaged(u64, *Conn) = .empty,
    next_id: u64 = 1,
    path: ?[:0]const u8 = null,

    pub fn sink(s: *Server) mcp.Sink {
        return .{ .ptr = s, .send = send };
    }

    /// Listens at `path`; error.AlreadyRunning if another nanocua answers there.
    pub fn listen(s: *Server, path: [:0]const u8) !void {
        if (!supported) return error.Unsupported;
        _ = signal(sigpipe, 1); // SIG_IGN: a closed agent is a failed write
        var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);
        const probe = socket(af_unix, sock_stream, 0);
        if (probe >= 0) {
            defer _ = close(probe);
            if (std.c.connect(probe, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) == 0) return error.AlreadyRunning;
        }
        _ = std.c.unlink(path);
        const fd = socket(af_unix, sock_stream, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = close(fd);
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.Bind;
        _ = chmod(path, 0o600);
        if (std.c.listen(fd, 8) != 0) return error.Listen;
        s.watch = try fdwatch.readable(fd, s, accepted);
        s.fd = fd;
        s.path = try s.gpa.dupeSentinel(u8, path, 0);
    }

    fn accepted(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        const fd = std.c.accept(s.fd, null, null);
        if (fd < 0) return;
        _ = s.adopt(fd) catch {
            _ = close(fd);
        };
    }

    /// Serves an open stream (an accepted socket; a socket pair in tests).
    pub fn adopt(s: *Server, fd: c_int) !u64 {
        const c = try s.gpa.create(Conn);
        errdefer s.gpa.destroy(c);
        c.* = .{ .server = s, .id = s.next_id, .fd = fd };
        try s.conns.put(s.gpa, c.id, c);
        errdefer _ = s.conns.swapRemove(c.id);
        c.watch = try fdwatch.readable(fd, c, Conn.readable);
        s.next_id += 1;
        s.changed();
        return c.id;
    }

    /// Agents connected.
    pub fn clients(s: *const Server) usize {
        var n: usize = 0;
        for (s.conns.values()) |c| n += @intFromBool(!c.control);
        return n;
    }

    pub fn markControl(s: *Server, id: u64) void {
        if (s.conns.get(id)) |c| c.control = true;
    }

    fn changed(s: *Server) void {
        if (s.hub.changed) |c| c.func(c.ptr);
    }

    fn send(ptr: *anyopaque, id: u64, line: []const u8) void {
        const s: *Server = @ptrCast(@alignCast(ptr));
        const c = s.conns.get(id) orelse return;
        if (!writeAll(c.fd, line) or !writeAll(c.fd, "\n")) s.drop(id);
    }

    fn drop(s: *Server, id: u64) void {
        const kv = s.conns.fetchSwapRemove(id) orelse return;
        const c = kv.value;
        s.hub.closed(id);
        if (c.watch) |w| w.cancel();
        _ = close(c.fd);
        c.lines.deinit(s.gpa);
        s.gpa.destroy(c);
        s.changed();
    }

    pub fn deinit(s: *Server) void {
        while (s.conns.count() > 0) s.drop(s.conns.keys()[0]);
        s.conns.deinit(s.gpa);
        if (s.watch) |w| w.cancel();
        if (s.fd >= 0) _ = close(s.fd);
        if (s.path) |p| {
            _ = std.c.unlink(p);
            s.gpa.free(p);
        }
    }
};

/// Writes all of `bytes`, waiting for a slow reader; false once it's gone.
pub fn writeAll(fd: c_int, bytes: []const u8) bool {
    if (comptime !supported) return false;
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
        if (n <= 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
}

test "lines split across reads, with CRLF, and too long" {
    const gpa = std.testing.allocator;
    var l: Lines = .{};
    defer l.deinit(gpa);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    const Ctx = struct {
        got: *std.ArrayList(u8),
        fn f(c: @This(), s: []const u8) void {
            c.got.print(std.testing.allocator, "<{s}>", .{s}) catch {};
        }
    };
    const ctx: Ctx = .{ .got = &got };
    try std.testing.expect(l.feed(gpa, "{\"a\":1}\n{\"b\"", ctx, Ctx.f));
    try std.testing.expect(l.feed(gpa, ":2}\r\n\n", ctx, Ctx.f));
    try std.testing.expectEqualStrings("<{\"a\":1}><{\"b\":2}><>", got.items);
    try std.testing.expectEqual(@as(usize, 0), l.buf.items.len);
}
