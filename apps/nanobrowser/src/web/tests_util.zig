//! What the web tests share: the whole browser through `ui.Tester`, pages from
//! `data:` addresses, and frames and the event loop until a condition holds. No
//! network unless a test asks for its loopback server; no window; nothing outside
//! the process.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../shell/browser.zig").Browser;
const Page = @import("../page.zig").Page;
const World = @import("world.zig").World;
const js = @import("../js/js.zig");
const testing = std.testing;

pub const Run = struct {
    b: Browser,
    t: ui.Tester = undefined,

    pub fn start(r: *Run) !void {
        r.b = .{ .gpa = testing.allocator };
        try r.b.init();
        try r.t.init(testing.allocator, ui.View.init(&r.b, Browser.view), .{ .width = 900, .height = 600, .scale = 1 });
    }

    pub fn stop(r: *Run) void {
        // What's on its way must land, or it holds its page past the test.
        var waited: u32 = 0;
        while (waited < 1000) : (waited += 1) {
            r.t.frame();
            var busy = false;
            for (r.b.tabs.items) |t| if (t.page) |p| {
                if (p.pending > 0) busy = true;
            };
            if (!busy and waited >= 8) break;
            nanoui.runFor(0.002);
        }
        r.t.frame();
        r.t.deinit();
        r.b.deinit();
    }

    fn anyLoading(r: *Run) bool {
        for (r.b.tabs.items) |t| if (t.loading()) return true;
        return false;
    }

    /// Frames and the event loop until nothing is on its way.
    pub fn settle(r: *Run) void {
        var waited: u32 = 0;
        while (waited < 800) : (waited += 1) {
            r.t.frame();
            if (!r.anyLoading()) break;
            nanoui.runFor(0.002);
        }
        r.t.frame();
    }

    /// Frames and the event loop for a while: timers fire.
    pub fn spin(r: *Run, seconds: f64) void {
        var waited: f64 = 0;
        while (waited < seconds) : (waited += 0.002) {
            nanoui.runFor(0.002);
            r.t.frame();
        }
        r.t.frame();
    }

    /// Opens a page of `html`, percent-encoded into a `data:` address.
    pub fn html(r: *Run, source: []const u8) !void {
        const gpa = testing.allocator;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, "data:text/html;charset=utf-8,");
        try appendEncoded(gpa, &out, source);
        r.b.tabs.items[r.b.current].go(out.items);
        r.settle();
        // Elements by their ids, for the tests' short expressions.
        _ = try r.eval("for (const e of document.querySelectorAll('[id]')) if (!Object.hasOwn(window, e.id) && !(e.id in EventTarget.prototype)) window[e.id] = e; 0");
    }

    pub fn open(r: *Run, url: []const u8) void {
        r.b.tabs.items[r.b.current].go(url);
        r.settle();
    }

    pub fn page(r: *Run) *Page {
        return r.b.tabs.items[r.b.current].page.?;
    }

    pub fn world(r: *Run) *World {
        const p = r.page();
        return p.js orelse blk: {
            const w = World.create(p) catch @panic("no world");
            w.runner.phase = .complete;
            w.runner.dom_ready = true;
            w.runner.load_fired = true;
            break :blk w;
        };
    }

    /// Evaluates JS on the page as a task of its own and gives its value as text.
    pub fn eval(r: *Run, source: []const u8) ![]const u8 {
        const w = r.world();
        const vm = w.vm;
        w.enter();
        defer w.leave();
        const v = vm.eval(source, "test") catch |e| {
            if (e == error.Thrown) std.debug.print("\nthrew: {s}\nin: {s}\n", .{ vm.exceptionString(), source });
            return e;
        };
        return vm.toStringSlice(v);
    }

    pub fn expectJs(r: *Run, source: []const u8, want: []const u8) !void {
        const got = r.eval(source) catch |e| {
            std.debug.print("\nFAILED: {s}\n  error: {s}\n", .{ source, @errorName(e) });
            return e;
        };
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("\nFAILED: {s}\n  want: {s}\n  got:  {s}\n", .{ source, want, got });
            dumpConsole(r);
            return error.TestFailed;
        }
    }

    /// Spins until the expression is truthy, then fails if it never is.
    pub fn waitJs(r: *Run, source: []const u8) !void {
        var waited: u32 = 0;
        while (waited < 2000) : (waited += 1) {
            const got = try r.eval(source);
            const falsy = [_][]const u8{ "false", "0", "", "undefined", "null", "NaN" };
            var truthy = true;
            for (falsy) |x| if (std.mem.eql(u8, got, x)) {
                truthy = false;
            };
            if (truthy) return;
            nanoui.runFor(0.002);
            r.t.frame();
        }
        std.debug.print("\nNEVER TRUE: {s}\n", .{source});
        dumpConsole(r);
        return error.TestFailed;
    }

    pub fn expectNoErrors(r: *Run) !void {
        const w = r.page().js orelse return;
        for (w.console.items) |l| if (l.level == 3) {
            std.debug.print("\nconsole error: {s}\n", .{l.text});
            return error.TestFailed;
        };
    }
};

pub fn dumpConsole(r: *Run) void {
    const w = r.page().js orelse return;
    for (w.console.items) |l| std.debug.print("  console[{d}]: {s}\n", .{ l.level, l.text });
}

pub fn appendEncoded(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.~", c) != null) {
            try out.append(gpa, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(gpa, &.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
}

/// A page's table of expressions, each with the text it should evaluate to.
pub const Case = struct { js: []const u8, want: []const u8 };

pub fn table(r: *Run, cases: []const Case) !void {
    var failed: usize = 0;
    for (cases) |c| {
        r.expectJs(c.js, c.want) catch {
            failed += 1;
        };
    }
    if (failed != 0) {
        std.debug.print("{d} of {d} cases failed\n", .{ failed, cases.len });
        return error.TestFailed;
    }
}
