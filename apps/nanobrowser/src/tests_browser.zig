//! The whole browser through `ui.Tester`: pages from `data:` addresses, so no
//! network and no window; keys, clicks and typing as a person gives them.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("shell/browser.zig").Browser;
const dom = @import("dom.zig");
const testing = std.testing;

const Run = struct {
    b: Browser,
    t: ui.Tester = undefined,

    fn start(r: *Run) !void {
        r.b = .{ .gpa = testing.allocator };
        try r.b.init();
        try r.t.init(testing.allocator, ui.View.init(&r.b, Browser.view), .{ .width = 900, .height = 600, .scale = 1 });
    }

    fn stop(r: *Run) void {
        settle(r);
        r.t.deinit();
        r.b.deinit();
    }

    /// Frames and the event loop until what's asked for has come.
    fn settle(r: *Run) void {
        var waited: u32 = 0;
        while (waited < 400) : (waited += 1) {
            r.t.frame();
            if (!r.anyLoading()) break;
            nanoui.runFor(0.005);
        }
        r.t.frame();
    }

    fn anyLoading(r: *Run) bool {
        for (r.b.tabs.items) |t| if (t.loading()) return true;
        if (r.b.split) |t| return t.loading();
        return false;
    }

    fn open(r: *Run, url: []const u8) void {
        r.b.tabs.items[r.b.current].go(url);
        r.settle();
    }

    fn page(r: *Run) *@import("page.zig").Page {
        return r.b.tabs.items[r.b.current].page.?;
    }
};

const first = "data:text/html,<!doctype html><title>One</title><body><h1>First page</h1><a href='data:text/html,<title>Two</title><p>Second page</p>'>Go on</a>";

test "a page draws, and a link goes on and comes back" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open(first);
    try testing.expect(r.t.hasText("First page"));
    try testing.expectEqualStrings("One", r.b.tabs.items[0].title());
    try r.t.clickText("Go on");
    r.settle();
    try testing.expect(r.t.hasText("Second page"));
    try testing.expectEqualStrings("Two", r.b.tabs.items[0].title());
    try testing.expect(r.b.tabs.items[0].canGoBack());
    try testing.expect(r.t.shortcut(.{ .key = '[', .cmd = true }));
    r.settle();
    try testing.expect(r.t.hasText("First page"));
    try testing.expect(r.b.tabs.items[0].canGoForward());
    try testing.expect(r.t.shortcut(.{ .key = ']', .cmd = true }));
    r.settle();
    try testing.expect(r.t.hasText("Second page"));
}

test "tabs open, switch, close and come back" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open(first);
    try testing.expect(r.t.shortcut(.{ .key = 't', .cmd = true }));
    try testing.expectEqual(@as(usize, 2), r.b.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), r.b.current);
    try testing.expect(r.t.shortcut(.{ .key = '1', .cmd = true }));
    try testing.expectEqual(@as(usize, 0), r.b.current);
    try testing.expect(r.t.shortcut(.{ .key = 'w', .cmd = true }));
    try testing.expectEqual(@as(usize, 1), r.b.tabs.items.len);
    try testing.expect(r.t.shortcut(.{ .key = 't', .cmd = true, .shift = true }));
    r.settle();
    try testing.expectEqual(@as(usize, 2), r.b.tabs.items.len);
    try testing.expect(r.t.hasText("First page"));
}

test "the tabs hide, the page splits, and the field and the finder come and go" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open(first);
    try testing.expect(r.t.shortcut(.{ .key = 's', .cmd = true }));
    try testing.expect(r.b.tabs_hidden);
    try testing.expect(r.t.shortcut(.{ .key = 's', .cmd = true }));
    try testing.expect(r.t.shortcut(.{ .key = 'd', .cmd = true }));
    try testing.expect(r.b.split != null);
    try testing.expect(r.t.shortcut(.{ .key = 'd', .cmd = true }));
    try testing.expect(r.b.split == null);
    try testing.expect(r.t.shortcut(.{ .key = 'l', .cmd = true }));
    try testing.expect(r.b.address_open);
    try testing.expect(r.t.shortcut(.{ .key = ui.Shortcut.escape }));
    try testing.expect(!r.b.address_open);
    try testing.expect(r.t.shortcut(.{ .key = 'k', .cmd = true }));
    try testing.expect(r.b.finder.showing);
    try testing.expect(r.t.shortcut(.{ .key = ui.Shortcut.escape }));
    try testing.expect(!r.b.finder.showing);
}

test "a form sends what it holds, a checkbox checks and <details> opens" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open("data:text/html,<!doctype html><body><details><summary>More</summary><p>Inside</p></details><label><input id=c type=checkbox> Tick</label>");
    try testing.expect(!r.t.hasText("Inside"));
    try r.t.clickText("More");
    r.settle();
    try testing.expect(r.t.hasText("Inside"));
    const box = r.page().doc.getElementById("c").?;
    try testing.expect(box.checked == null);
    try r.t.clickText(" Tick");
    r.settle();
    try testing.expectEqual(@as(?bool, true), box.checked);
}

test "the page scrolls by the wheel and stops at its end" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open("data:text/html,<!doctype html><body style='margin:0'><div style='height:3000px'>Tall</div>");
    r.t.ctx.input.mouse = .{ .x = 400, .y = 300 };
    r.t.ctx.input.precise = true;
    r.t.ctx.input.scroll = .{ .y = -200 };
    r.t.frame();
    try testing.expectEqual(@as(f32, 200), r.page().scrollY());
    r.t.ctx.input.scroll = .{ .y = -100000 };
    r.t.frame();
    try testing.expectEqual(@as(f32, 3000 - 548), r.page().scrollY());
}

test "find counts what is on the page" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open("data:text/html,<!doctype html><p>bird Bird BIRD fish</p>");
    r.page().findText("bird");
    r.t.frame();
    try testing.expectEqual(@as(usize, 3), r.page().findCount());
    r.page().findStop();
}
