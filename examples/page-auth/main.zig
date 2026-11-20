//! Deferred startup navigation and authenticated initial document request
//! example on top of a local loopback server (test credentials only).
const std = @import("std");
const nanoui = @import("nanoui");

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    srv: std.Io.net.Server,
    port: u16,
    window: *nanoui.Window = undefined,
    stop: std.atomic.Value(bool) = .init(false),
    requests: std.atomic.Value(u32) = .init(0),
    unauthenticated: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    fn serve(self: *State) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.srv.accept(self.io) catch break;
            self.handle(stream);
        }
    }

    fn handle(self: *State, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);
        if (self.stop.load(.acquire)) return;
        var buf: [4096]u8 = undefined;
        var used: usize = 0;
        while (used < buf.len) {
            var vecs = [1][]u8{buf[used..]};
            const res = stream.readWithControl(self.io, &vecs, &.{}) catch break;
            if (res.data_len == 0) break;
            used += res.data_len;
            if (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") != null) break;
        }
        const raw = buf[0..used];
        if (raw.len == 0 or std.mem.indexOf(u8, raw, "GET /favicon.ico ") != null) return;
        const count = self.requests.fetchAdd(1, .acq_rel) + 1;
        const has_auth = hasBearerAuth(raw);
        if (!has_auth) _ = self.unauthenticated.fetchAdd(1, .acq_rel);

        var body: [256]u8 = undefined;
        const html = std.fmt.bufPrint(&body, "<!doctype html><html><body><h1>Deferred Page</h1><p>request #{d}, auth={}</p></body></html>", .{ count, has_auth }) catch return;
        var wbuf: [512]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        w.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ html.len, html }) catch return;
        w.interface.flush() catch {};
    }

    fn hasBearerAuth(raw: []const u8) bool {
        var it = std.mem.splitSequence(u8, raw, "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "authorization")) continue;
            return std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), "Bearer placeholder-token");
        }
        return false;
    }

    fn shutdown(self: *State) void {
        self.stop.store(true, .release);
        var wake: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (wake.connect(self.io, .{ .mode = .stream })) |st| st.close(self.io) else |_| {}
        if (self.thread) |t| t.join();
        self.srv.deinit(self.io);
    }
};

fn onCredentialsReady(ctx: ?*anyopaque) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(ctx));
    var url_buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/app", .{s.port}) catch return;
    s.window.loadPageRequest(.{
        .url = url,
        .headers = &.{.{ .name = "Authorization", .value = "Bearer placeholder-token" }},
    }) catch |err| {
        std.log.err("loadPageRequest failed: {s}", .{@errorName(err)});
    };
}

fn onLoadError(_: ?*anyopaque, url: []const u8, msg: []const u8) void {
    std.log.warn("page navigation error ({s}): {s}", .{ url, msg });
}

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Page Auth" });
    defer app.destroy();

    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var s: State = .{
        .gpa = init.gpa,
        .io = init.io,
        .srv = try addr.listen(init.io, .{ .reuse_address = true }),
        .port = 0,
    };
    s.port = s.srv.socket.address.getPort();
    s.thread = try std.Thread.spawn(.{}, State.serve, .{&s});
    defer s.shutdown();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/app", .{s.port});
    s.window = try app.newWindow(.{
        .title = "Page Auth",
        .width = 640,
        .height = 420,
        .content = .{ .page = .{
            .url = url,
            .defer_initial_load = true,
            .private = true,
            .on_load_error = onLoadError,
        } },
    });
    nanoui.App.after(20, &s, onCredentialsReady);
    try app.run();
}
