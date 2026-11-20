//! Integration and contract tests for deferred initial page loading,
//! custom request headers, cross-origin redirect header stripping, and
//! load-error callbacks across WKWebView (macOS) and WebKitGTK (Linux).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const nanoui = @import("nanoui.zig");
const page_request = @import("page_request.zig");
const clock = @import("ui/clock.zig");
const platform = @import("platform.zig");

const mac = builtin.os.tag == .macos;
const linux = builtin.os.tag == .linux and !builtin.abi.isAndroid();
const App = if (mac) @import("app.zig").App else if (linux) @import("linux/app.zig").App else void;
const Window = if (mac) @import("window.zig").Window else if (linux) @import("linux/window.zig").Window else void;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const RecordedReq = struct {
    raw: []u8,

    fn path(self: RecordedReq) []const u8 {
        const sp1 = std.mem.indexOfScalar(u8, self.raw, ' ') orelse return "";
        const rest = self.raw[sp1 + 1 ..];
        const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return rest;
        return rest[0..sp2];
    }

    fn headerValue(self: RecordedReq, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, self.raw, "\r\n");
        _ = it.next();
        while (it.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        }
        return null;
    }
};

const LoopbackServer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    srv: std.Io.net.Server,
    port: u16,
    redirect_to: ?[]const u8 = null,
    stop: std.atomic.Value(bool) = .init(false),
    mu: std.Io.Mutex = .init,
    reqs: std.ArrayList(RecordedReq) = .empty,
    conns: std.ArrayList(std.Io.net.Stream) = .empty,
    workers: std.ArrayList(std.Thread) = .empty,
    thread: ?std.Thread = null,

    fn init(gpa: std.mem.Allocator, io: std.Io, redirect_to: ?[]const u8) !*LoopbackServer {
        const s = try gpa.create(LoopbackServer);
        errdefer gpa.destroy(s);
        var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const srv = try addr.listen(io, .{ .reuse_address = true });
        s.* = .{
            .gpa = gpa,
            .io = io,
            .srv = srv,
            .port = srv.socket.address.getPort(),
            .redirect_to = redirect_to,
        };
        s.thread = try std.Thread.spawn(.{}, serveLoop, .{s});
        return s;
    }

    fn deinit(self: *LoopbackServer) void {
        self.stop.store(true, .release);
        var wake_addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (wake_addr.connect(self.io, .{ .mode = .stream })) |st| {
            st.close(self.io);
        } else |_| {}
        if (self.thread) |t| t.join();
        self.mu.lockUncancelable(self.io);
        for (self.conns.items) |st| st.shutdown(self.io, .both) catch {};
        self.mu.unlock(self.io);
        for (self.workers.items) |t| t.join();
        self.workers.deinit(self.gpa);
        self.conns.deinit(self.gpa);
        self.srv.deinit(self.io);
        for (self.reqs.items) |r| self.gpa.free(r.raw);
        self.reqs.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn count(self: *LoopbackServer) usize {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.reqs.items.len;
    }

    fn getCopy(self: *LoopbackServer, idx: usize) ?[]u8 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (idx >= self.reqs.items.len) return null;
        return self.gpa.dupe(u8, self.reqs.items[idx].raw) catch null;
    }

    fn serveLoop(self: *LoopbackServer) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.srv.accept(self.io) catch break;
            if (self.stop.load(.acquire)) {
                stream.close(self.io);
                break;
            }
            const t = std.Thread.spawn(.{}, handleConn, .{ self, stream }) catch {
                self.handleConn(stream);
                continue;
            };
            self.mu.lockUncancelable(self.io);
            self.workers.append(self.gpa, t) catch {
                self.mu.unlock(self.io);
                t.join();
                continue;
            };
            self.mu.unlock(self.io);
        }
    }

    fn handleConn(self: *LoopbackServer, stream: std.Io.net.Stream) void {
        self.mu.lockUncancelable(self.io);
        self.conns.append(self.gpa, stream) catch {};
        self.mu.unlock(self.io);
        defer {
            self.mu.lockUncancelable(self.io);
            for (self.conns.items, 0..) |c, i| {
                if (c.socket.handle == stream.socket.handle) {
                    _ = self.conns.swapRemove(i);
                    break;
                }
            }
            self.mu.unlock(self.io);
            stream.close(self.io);
        }
        if (self.stop.load(.acquire)) return;
        var buf: [8192]u8 = undefined;
        var used: usize = 0;
        while (used < buf.len) {
            var vecs = [1][]u8{buf[used..]};
            const res = stream.readWithControl(self.io, &vecs, &.{}) catch break;
            if (res.data_len == 0) break;
            used += res.data_len;
            if (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") != null) break;
        }
        const raw = buf[0..used];
        if (raw.len == 0) return;

        const req: RecordedReq = .{ .raw = self.gpa.dupe(u8, raw) catch return };
        const req_path = req.path();
        if (!std.mem.eql(u8, req_path, "/favicon.ico")) {
            self.mu.lockUncancelable(self.io);
            self.reqs.append(self.gpa, req) catch self.gpa.free(req.raw);
            self.mu.unlock(self.io);
        } else {
            self.gpa.free(req.raw);
        }

        var wbuf: [1024]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        if (std.mem.startsWith(u8, req_path, "/redir")) {
            if (self.redirect_to) |loc| {
                w.interface.print("HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{loc}) catch return;
                w.interface.flush() catch {};
                return;
            }
        }
        const body = "<!doctype html><html><body>ok</body></html>";
        w.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
        w.interface.flush() catch {};
    }
};

fn pumpUntilCount(srv: *LoopbackServer, expected: usize, timeout_s: f64) !void {
    const end = clock.now() + timeout_s;
    while (srv.count() < expected) {
        if (clock.now() > end) return error.Timeout;
        platform.runFor(0.01);
    }
}

fn freeApp(app: *App) void {
    if (mac) {
        while (app.windows.items.len > 0) app.windows.items[app.windows.items.len - 1].close();
        platform.runFor(0.05);
        @import("ui/surface_wake.zig").sweep();
        app.windows.deinit(app.gpa);
        @import("objc.zig").release(app.delegate);
        app.gpa.destroy(app);
    } else if (linux) {
        app.destroy();
    }
}

fn makeHiddenApp(gpa: std.mem.Allocator) !*App {
    if (mac) {
        const objc = @import("objc.zig");
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .io = testing.io,
            .options = .{ .quit_on_last_window_closed = false },
            .nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{}),
            .delegate = objc.msg(objc.Object, objc.class("NSObject"), "new", .{}),
            .flags = .{ .hidden = true },
        };
        return app;
    } else if (linux) {
        const gtk = @import("linux/gtk.zig");
        const wk = @import("linux/webkit.zig");
        _ = setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", 1);
        if (!gtk.ready() or !wk.load()) return error.SkipZigTest;
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .io = testing.io,
            .options = .{ .name = "nanoui-tests", .quit_on_last_window_closed = false },
            .flags = .{ .hidden = true },
            .gui = true,
            .cpu_only = true,
        };
        return app;
    }
    return error.SkipZigTest;
}

const ErrorCapture = struct {
    called: bool = false,

    fn onError(ctx: ?*anyopaque, _: []const u8, _: []const u8) void {
        const self: *ErrorCapture = @ptrCast(@alignCast(ctx));
        self.called = true;
    }
};

test "deferred initial load sends 0 requests idle, scoped headers on loadPageRequest, stripped on setPageUrl and cross-origin redirect" {
    if (!mac and !linux) return error.SkipZigTest;
    const pool = if (mac) @import("objc.zig").Pool.push() else {};
    defer if (mac) pool.pop();

    const gpa = testing.allocator;
    const srv_b = try LoopbackServer.init(gpa, testing.io, null);
    defer srv_b.deinit();

    var redir_target: [128]u8 = undefined;
    const url_landed = try std.fmt.bufPrint(&redir_target, "http://127.0.0.1:{d}/landed", .{srv_b.port});
    const srv_a = try LoopbackServer.init(gpa, testing.io, url_landed);
    defer srv_a.deinit();

    const app = try makeHiddenApp(gpa);
    defer freeApp(app);

    var url_init_buf: [128]u8 = undefined;
    var url_auth_buf: [128]u8 = undefined;
    var url_plain_buf: [128]u8 = undefined;
    var url_redir_buf: [128]u8 = undefined;
    const url_init = try std.fmt.bufPrint(&url_init_buf, "http://127.0.0.1:{d}/initial", .{srv_a.port});
    const url_auth = try std.fmt.bufPrint(&url_auth_buf, "http://127.0.0.1:{d}/auth", .{srv_a.port});
    const url_plain = try std.fmt.bufPrint(&url_plain_buf, "http://127.0.0.1:{d}/plain", .{srv_a.port});
    const url_redir = try std.fmt.bufPrint(&url_redir_buf, "http://127.0.0.1:{d}/redir", .{srv_a.port});

    var err_cap: ErrorCapture = .{};
    const win = try app.newWindow(.{
        .title = "req-test",
        .content = .{ .page = .{
            .url = url_init,
            .private = true,
            .defer_initial_load = true,
            .on_load_error = ErrorCapture.onError,
            .on_load_error_ctx = &err_cap,
        } },
    });

    // 1. Validation rejects invalid requests before sending anything.
    try testing.expectError(error.InvalidUrl, win.loadPageRequest(.{ .url = "javascript:alert(1)" }));
    try testing.expectError(error.InvalidHeaderName, win.loadPageRequest(.{
        .url = url_auth,
        .headers = &.{.{ .name = "Bad Header", .value = "x" }},
    }));
    try testing.expectError(error.InvalidHeaderValue, win.loadPageRequest(.{
        .url = url_auth,
        .headers = &.{.{ .name = "Authorization", .value = "a\r\nb" }},
    }));

    // 2. Idle deferred window sends 0 document requests.
    platform.runFor(0.25);
    try testing.expectEqual(@as(usize, 0), srv_a.count());

    // 3. Explicit authenticated initial navigation sends headers once.
    try win.loadPageRequest(.{
        .url = url_auth,
        .headers = &.{
            .{ .name = "Authorization", .value = "Bearer test-token-123" },
            .{ .name = "X-App-Scope", .value = "initial" },
        },
    });
    try pumpUntilCount(srv_a, 1, 15.0);
    const req1 = srv_a.getCopy(0).?;
    defer gpa.free(req1);
    const r1: RecordedReq = .{ .raw = req1 };
    try testing.expectEqualStrings("/auth", r1.path());
    try testing.expectEqualStrings("Bearer test-token-123", r1.headerValue("authorization") orelse "");
    try testing.expectEqualStrings("initial", r1.headerValue("x-app-scope") orelse "");

    // 4. Subsequent plain setPageUrl carries neither custom header.
    win.setPageUrl(url_plain);
    try pumpUntilCount(srv_a, 2, 15.0);
    const req2 = srv_a.getCopy(1).?;
    defer gpa.free(req2);
    const r2: RecordedReq = .{ .raw = req2 };
    try testing.expectEqualStrings("/plain", r2.path());
    try testing.expectEqual(@as(?[]const u8, null), r2.headerValue("authorization"));
    try testing.expectEqual(@as(?[]const u8, null), r2.headerValue("x-app-scope"));

    // 5. Cross-origin 302 redirect (A -> B) strips both custom headers.
    try win.loadPageRequest(.{
        .url = url_redir,
        .headers = &.{
            .{ .name = "Authorization", .value = "Bearer redir-secret" },
            .{ .name = "X-App-Scope", .value = "redir" },
        },
    });
    try pumpUntilCount(srv_a, 3, 15.0);
    try pumpUntilCount(srv_b, 1, 15.0);
    const req_b = srv_b.getCopy(0).?;
    defer gpa.free(req_b);
    const rb: RecordedReq = .{ .raw = req_b };
    try testing.expectEqualStrings("/landed", rb.path());
    try testing.expectEqual(@as(?[]const u8, null), rb.headerValue("authorization"));
    try testing.expectEqual(@as(?[]const u8, null), rb.headerValue("x-app-scope"));

    // 6. Unreachable port delivers on_load_error.
    var dead_addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var dead_srv = try dead_addr.listen(testing.io, .{});
    const dead_port = dead_srv.socket.address.getPort();
    dead_srv.deinit(testing.io);
    var url_dead_buf: [128]u8 = undefined;
    const url_dead = try std.fmt.bufPrint(&url_dead_buf, "http://127.0.0.1:{d}/fail", .{dead_port});
    try win.loadPageRequest(.{ .url = url_dead });
    const end = clock.now() + 10.0;
    while (!err_cap.called and clock.now() < end) platform.runFor(0.02);
    try testing.expect(err_cap.called);
}

const DockView = struct {
    fn view(_: *DockView, c: *nanoui.ui.Context) void {
        nanoui.ui.text(c, "host", .{});
    }
};

test "macOS docked page supports deferred startup and loadRequest" {
    if (!mac) return error.SkipZigTest;
    const pool = @import("objc.zig").Pool.push();
    defer pool.pop();

    const gpa = testing.allocator;
    const srv = try LoopbackServer.init(gpa, testing.io, null);
    defer srv.deinit();

    const app = try makeHiddenApp(gpa);
    defer freeApp(app);

    var dock_state: DockView = .{};
    const win = try app.newWindow(.{
        .width = 400,
        .height = 300,
        .content = .{ .view = nanoui.ui.View.init(&dock_state, DockView.view) },
    });

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/docked", .{srv.port});
    const pg = try win.dockPage(.{
        .parent = win.surface.?.nativeHandle(),
        .url = url,
        .private = true,
        .defer_initial_load = true,
    });
    platform.runFor(0.25);
    try testing.expectEqual(@as(usize, 0), srv.count());

    try pg.loadRequest(.{
        .url = url,
        .headers = &.{.{ .name = "Authorization", .value = "Bearer docked-tok" }},
    });
    try pumpUntilCount(srv, 1, 15.0);
    const req = srv.getCopy(0).?;
    defer gpa.free(req);
    const r: RecordedReq = .{ .raw = req };
    try testing.expectEqualStrings("/docked", r.path());
    try testing.expectEqualStrings("Bearer docked-tok", r.headerValue("authorization") orelse "");
}
