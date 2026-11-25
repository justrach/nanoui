//! A page in WebKitGTK, end to end: served from the app's assets, calling a
//! bound service, hearing an event and closing its window. They need a display
//! and a WebKitGTK (CI has both, under Xvfb), and skip without one. Whichever
//! GTK this process loaded is the one tested; `NANOUI_GTK=3` tests the other.
const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const gtk = @import("gtk.zig");
const wk = @import("webkit.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const ipc = @import("../ipc.zig").ipc(Window, App);
const notice = @import("page_notice.zig");
const clock = @import("../ui/clock.zig");
const runFor = @import("../platform.zig").runFor;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const Ping = ipc.Event("ping", struct { n: u32 });

/// What the page told Zig, in order.
const Report = struct {
    gpa: std.mem.Allocator,
    said: std.ArrayList([]u8) = .empty,

    pub const nanoui_params = .{ .say = .{"what"} };

    pub fn say(self: *Report, what: []const u8) !void {
        try self.said.append(self.gpa, try self.gpa.dupe(u8, what));
    }

    fn saw(self: *const Report, what: []const u8) bool {
        for (self.said.items) |s| if (std.mem.eql(u8, s, what)) return true;
        return false;
    }

    fn deinit(self: *Report) void {
        for (self.said.items) |s| self.gpa.free(s);
        self.said.deinit(self.gpa);
    }
};

const html =
    \\<!doctype html><title>t</title><script type="module" src="/main.js"></script>
;

// A module: it needs the scheme to be CORS-enabled, as an app's frontend does.
const main_js =
    \\import { Report, onPing } from "/nanoui.js";
    \\await Report.say("called " + nanoui.platform);
    \\await Report.say("crypto " + (window.isSecureContext && !!crypto.subtle));
    \\await Report.say("missing " + (await fetch("/nothing")).status);
    \\await Report.say("unicode " + (await (await fetch("/text.txt")).text()));
    \\await Report.say("bar " + !!document.getElementById("__nanoui_bar"));
    \\try { await nanoui.call("Report.nope"); } catch (e) { await Report.say("error " + e.message); }
    \\onPing(async ({ n }) => {
    \\  await Report.say("ping " + n);
    \\  nanoui.window.close();
    \\});
    \\await Report.say("listening");
;

const assets = [_]@import("../window_types.zig").Asset{
    .{ .path = "/index.html", .data = html },
    .{ .path = "/main.js", .data = main_js },
    .{ .path = "/text.txt", .data = "héllo", .mime = "text/plain; charset=utf-8" },
};

/// An app with GTK up, or a skip where there is no GTK or no display.
fn makeApp(gpa: std.mem.Allocator) !*App {
    if (!gtk.ready()) return error.SkipZigTest;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = testing.io,
        .options = .{ .name = "nanoui-tests", .quit_on_last_window_closed = false },
        // Hidden: no window on anyone's screen, and an ephemeral profile.
        .flags = .{ .hidden = true },
        .gui = true,
        .cpu_only = true,
    };
    return app;
}

/// Runs the loop until `done`, 60 seconds at most: a web process starting on
/// a slow machine takes a while, and one that never does is a failure.
fn until(ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
    const end = clock.now() + 60;
    while (!done(ctx)) {
        if (clock.now() > end) return error.Timeout;
        runFor(0.01);
    }
}

test "a page is served, calls Zig, hears an event, and closes its window" {
    // A test's page is its own, and not every machine that runs tests can
    // start WebKitGTK's sandbox.
    _ = setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", 1);
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    if (!wk.load()) return error.SkipZigTest;

    var report: Report = .{ .gpa = gpa };
    defer report.deinit();
    try app.bind(&report);
    try app.registerEvent(Ping);
    const window = try app.newWindow(.{ .title = "page", .content = .{ .page = .{
        .url = "/",
        .assets = &assets,
        .pages = &.{ .{ .title = "One", .url = "/" }, .{ .title = "Two", .url = "/two" } },
    } } });
    try testing.expect(window.page != null);
    // Nothing on the screen in a hidden run, page or not.
    try testing.expect(!window.isVisible());

    try until(&report, struct {
        fn done(r: *Report) bool {
            return r.saw("listening");
        }
    }.done);
    try testing.expect(report.saw("called linux"));
    try testing.expect(report.saw("crypto true"));
    try testing.expect(report.saw("missing 404"));
    try testing.expect(report.saw("unicode héllo"));
    try testing.expect(report.saw("bar true"));
    try testing.expect(report.saw("error Report.nope: UnknownMethod"));

    // An event from another thread's path, then the page closes its window:
    // the view goes from under its own message without anything crashing.
    Ping.emit(window, .{ .n = 7 });
    try until(app, struct {
        fn done(a: *App) bool {
            return a.windows.items.len == 0;
        }
    }.done);
    try testing.expect(report.saw("ping 7"));
}

test "the generated client lists what is bound" {
    const gpa = testing.allocator;
    const app = try gpa.create(App);
    app.* = .{ .gpa = gpa, .io = testing.io, .options = .{}, .headless = true };
    defer app.destroy();
    var report: Report = .{ .gpa = gpa };
    try app.bind(&report);
    try app.registerEvent(Ping);
    const js = try app.clientJs();
    try testing.expect(std.mem.indexOf(u8, js, "Report") != null);
    try testing.expect(std.mem.indexOf(u8, js, "onPing") != null);
    const dts = try app.clientDts(gpa);
    defer gpa.free(dts);
    try testing.expect(std.mem.indexOf(u8, dts, "\"linux\"") != null);
}

test "a headless run makes a page's window without GTK" {
    const gpa = testing.allocator;
    const app = try gpa.create(App);
    app.* = .{ .gpa = gpa, .io = testing.io, .options = .{ .quit_on_last_window_closed = false }, .headless = true };
    defer app.destroy();
    const window = try app.newWindow(.{ .content = .{ .page = .{ .url = "/" } } });
    try testing.expect(window.gtkwindow == null and window.page == null);
    try testing.expect(window.nativeView() == null);
}

test "without a WebKitGTK the window says what to install" {
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, notice.missingView(), .{ .width = 320, .height = 300 });
    defer t.deinit();
    t.frame();
    try testing.expect(t.hasText("This app needs WebKitGTK"));
    // Wrapped, not cut off by a window much narrower than the sentence.
    for ([_][]const u8{ "This app needs WebKitGTK", notice.explanation }) |s| {
        const r = t.findText(s) orelse return error.NoText;
        try testing.expect(r.x >= 0 and r.x + r.w <= 320);
    }
    try testing.expect(std.mem.indexOf(u8, notice.package(true), "libwebkitgtk-6.0") != null);
    try testing.expect(std.mem.indexOf(u8, notice.package(false), "libwebkit2gtk-4.1") != null);
}

test "where 6.0's sandbox can't start the window says so, whole" {
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, notice.sandboxView(), .{ .width = 320, .height = 340 });
    defer t.deinit();
    t.frame();
    for ([_][]const u8{ "This app can't start WebKitGTK", notice.sandbox_explanation, notice.sandbox_fix }) |s| {
        const r = t.findText(s) orelse return error.NoText;
        try testing.expect(r.x >= 0 and r.x + r.w <= 320);
    }
}

test "bubblewrap's refusal counts, its absence says nothing" {
    try testing.expect(wk.refuses("false"));
    try testing.expect(!wk.refuses("true"));
    try testing.expect(!wk.refuses("nanoui-no-such-program"));
}

const PageTestServer = struct {
    gpa: std.mem.Allocator,
    srv: std.Io.net.Server,
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    mu: std.Io.Mutex = .init,
    allowed_hits: usize = 0,
    blocked_hits: usize = 0,
    thread: ?std.Thread = null,

    fn init(gpa: std.mem.Allocator) !*PageTestServer {
        const s = try gpa.create(PageTestServer);
        errdefer gpa.destroy(s);
        var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const srv = try addr.listen(testing.io, .{ .reuse_address = true });
        s.* = .{ .gpa = gpa, .srv = srv, .port = srv.socket.address.getPort() };
        s.thread = try std.Thread.spawn(.{}, serveLoop, .{s});
        return s;
    }

    fn deinit(self: *PageTestServer) void {
        self.stop.store(true, .release);
        var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(testing.io, .{ .mode = .stream })) |st| st.close(testing.io) else |_| {}
        if (self.thread) |t| t.join();
        self.srv.deinit(testing.io);
        self.gpa.destroy(self);
    }

    fn serveLoop(self: *PageTestServer) void {
        while (!self.stop.load(.acquire)) {
            const st = self.srv.accept(testing.io) catch break;
            defer st.close(testing.io);
            if (self.stop.load(.acquire)) break;
            var rbuf: [2048]u8 = undefined;
            var used: usize = 0;
            while (used < rbuf.len) {
                var vecs = [1][]u8{rbuf[used..]};
                const res = st.readWithControl(testing.io, &vecs, &.{}) catch break;
                if (res.data_len == 0) break;
                used += res.data_len;
                if (std.mem.indexOf(u8, rbuf[0..used], "\r\n\r\n") != null) break;
            }
            const req = rbuf[0..used];
            if (req.len == 0) continue;
            const path = blk: {
                const sp1 = std.mem.indexOfScalar(u8, req, ' ') orelse break :blk "";
                const rest = req[sp1 + 1 ..];
                const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse break :blk rest;
                break :blk rest[0..sp2];
            };
            const body = self.bodyFor(path);
            var wbuf: [4096]u8 = undefined;
            var wr = st.writer(testing.io, &wbuf);
            wr.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch continue;
            wr.interface.flush() catch {};
        }
    }

    fn bodyFor(self: *PageTestServer, target: []const u8) []const u8 {
        const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const path = target[0..q];
        self.mu.lockUncancelable(testing.io);
        if (std.mem.eql(u8, path, "/allowed")) self.allowed_hits += 1;
        if (std.mem.eql(u8, path, "/blocked")) self.blocked_hits += 1;
        self.mu.unlock(testing.io);
        if (std.mem.eql(u8, path, "/set")) {
            return "<!doctype html><script>document.cookie='nanoui_priv=secret; path=/';localStorage.setItem('nanoui_ls','secret');var t=new URLSearchParams(location.search).get('t')||'s';window.nanoui.call('Report.say',t+':'+document.cookie+'|'+localStorage.getItem('nanoui_ls'));</script>";
        }
        if (std.mem.eql(u8, path, "/get")) {
            return "<!doctype html><script>var t=new URLSearchParams(location.search).get('t')||'g';window.nanoui.call('Report.say',t+':'+document.cookie+'|'+localStorage.getItem('nanoui_ls'));</script>";
        }
        if (std.mem.eql(u8, path, "/allowed")) {
            return "<!doctype html><script>window.nanoui.call('Report.say','allowed-loaded');</script><iframe src='/blocked'></iframe>";
        }
        return "<!doctype html><p>ok</p>";
    }
};

test "private pages isolate storage and cookies per WebKitGTK view" {
    _ = setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", 1);
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    if (!wk.load()) return error.SkipZigTest;

    const srv = try PageTestServer.init(gpa);
    defer srv.deinit();

    var report: Report = .{ .gpa = gpa };
    defer report.deinit();
    try app.bind(&report);

    var ubuf1: [96]u8 = undefined;
    var ubuf2: [96]u8 = undefined;
    var ubuf3: [96]u8 = undefined;
    var ubuf4: [96]u8 = undefined;
    var ubuf5: [96]u8 = undefined;
    const u_set1 = try std.fmt.bufPrint(&ubuf1, "http://127.0.0.1:{d}/set?t=p1", .{srv.port});
    const u_get2 = try std.fmt.bufPrint(&ubuf2, "http://127.0.0.1:{d}/get?t=p2", .{srv.port});
    const u_get3 = try std.fmt.bufPrint(&ubuf3, "http://127.0.0.1:{d}/get?t=p3", .{srv.port});
    const u_set3 = try std.fmt.bufPrint(&ubuf4, "http://127.0.0.1:{d}/set?t=s3", .{srv.port});
    const u_get4 = try std.fmt.bufPrint(&ubuf5, "http://127.0.0.1:{d}/get?t=p4", .{srv.port});

    const priv_assets = [_]@import("../window_types.zig").Asset{
        .{ .path = "/index.html", .data = "<!doctype html><script type='module'>import { Report } from '/nanoui.js'; await Report.say('priv-own');</script>" },
    };
    const w1 = try app.newWindow(.{ .title = "priv1", .content = .{ .page = .{ .url = "/", .assets = &priv_assets, .private = true } } });
    try until(&report, struct {
        fn done(r: *Report) bool {
            return r.saw("priv-own");
        }
    }.done);

    w1.setPageUrl(u_set1);
    try until(&report, struct {
        fn done(r: *Report) bool {
            return r.saw("p1:nanoui_priv=secret|secret");
        }
    }.done);

    _ = try app.newWindow(.{ .title = "priv2", .content = .{ .page = .{ .url = u_get2, .private = true } } });
    try until(&report, struct {
        fn done(r: *Report) bool {
            return r.saw("p2:|null");
        }
    }.done);

    const w3 = try app.newWindow(.{ .title = "shared", .content = .{ .page = .{ .url = u_get3, .private = false } } });
    try until(&report, struct {
        fn done(r: *Report) bool {
            return r.saw("p3:|null");
        }
    }.done);

    w3.setPageUrl(u_set3);
    try until(&report, struct {
        fn done(r: *Report) bool {
            return r.saw("s3:nanoui_priv=secret|secret");
        }
    }.done);

    _ = try app.newWindow(.{ .title = "priv4", .content = .{ .page = .{ .url = u_get4, .private = true } } });
    try until(&report, struct {
        fn done(r: *Report) bool {
            return r.saw("p4:|null");
        }
    }.done);
}

test "allow_request blocks disallowed main-frame and iframe navigations before reaching the network" {
    _ = setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", 1);
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    if (!wk.load() or !wk.has_request_api) return error.SkipZigTest;

    const srv = try PageTestServer.init(gpa);
    defer srv.deinit();

    var report: Report = .{ .gpa = gpa };
    defer report.deinit();
    try app.bind(&report);

    const Filter = struct {
        blocked_seen: usize = 0,
        allowed_seen: usize = 0,
        own_seen: usize = 0,
        fn allow(ctx: ?*anyopaque, url: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (std.mem.startsWith(u8, url, "nanoui://")) self.own_seen += 1;
            if (std.mem.endsWith(u8, url, "/blocked")) {
                self.blocked_seen += 1;
                return false;
            }
            if (std.mem.endsWith(u8, url, "/allowed")) {
                self.allowed_seen += 1;
                return true;
            }
            return false;
        }
    };
    var filter: Filter = .{};

    const own_assets = [_]@import("../window_types.zig").Asset{
        .{ .path = "/index.html", .data = "<!doctype html><script type='module'>import { Report } from '/nanoui.js'; await Report.say('ready');</script>" },
    };
    const win = try app.newWindow(.{ .title = "filter", .content = .{ .page = .{
        .url = "/",
        .assets = &own_assets,
        .allow_request = Filter.allow,
        .allow_request_ctx = &filter,
    } } });
    try until(&report, struct {
        fn done(r: *Report) bool {
            return r.saw("ready");
        }
    }.done);
    try testing.expectEqual(@as(usize, 0), filter.own_seen);

    var bbuf: [96]u8 = undefined;
    var abuf: [96]u8 = undefined;
    const u_blocked = try std.fmt.bufPrint(&bbuf, "http://127.0.0.1:{d}/blocked", .{srv.port});
    const u_allowed = try std.fmt.bufPrint(&abuf, "http://127.0.0.1:{d}/allowed", .{srv.port});

    win.setPageUrl(u_blocked);
    try until(&filter, struct {
        fn done(f: *Filter) bool {
            return f.blocked_seen >= 1;
        }
    }.done);

    win.setPageUrl(u_allowed);
    try until(&report, struct {
        fn done(r: *Report) bool {
            return r.saw("allowed-loaded");
        }
    }.done);
    try until(&filter, struct {
        fn done(f: *Filter) bool {
            return f.blocked_seen >= 2;
        }
    }.done);

    srv.mu.lockUncancelable(testing.io);
    const allowed_hits = srv.allowed_hits;
    const blocked_hits = srv.blocked_hits;
    srv.mu.unlock(testing.io);
    try testing.expectEqual(@as(usize, 1), allowed_hits);
    try testing.expectEqual(@as(usize, 0), blocked_hits);
    try testing.expect(filter.allowed_seen >= 1);
}
