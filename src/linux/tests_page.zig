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
