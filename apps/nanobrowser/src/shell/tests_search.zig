//! The address field as a search box, through the browser in a Tester. Nothing here
//! reaches an engine: searches go to `data:` addresses, suggestions are handed over.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("browser.zig").Browser;
const Suggest = @import("suggest.zig").Suggest;
const testing = std.testing;

const Run = struct {
    b: Browser,
    t: ui.Tester = undefined,

    fn start(r: *Run) !void {
        r.b = .{ .gpa = testing.allocator, .search_base = "data:text/html,found-" };
        try r.b.init();
        try r.t.init(testing.allocator, ui.View.init(&r.b, Browser.view), .{ .width = 900, .height = 600 });
    }

    fn stop(r: *Run) void {
        var waited: u32 = 0;
        while (waited < 300) : (waited += 1) {
            r.t.frame();
            nanoui.runFor(0.002);
            const busy = if (r.b.tabs.items[0].page) |p| p.pending > 0 else false;
            if (!busy and waited >= 8) break;
        }
        r.t.deinit();
        r.b.deinit();
    }

    fn settle(r: *Run) void {
        var i: u32 = 0;
        while (i < 200) : (i += 1) {
            r.t.frame();
            nanoui.runFor(0.002);
            if (r.b.tabs.items[0].page) |p| if (!p.isLoading() and i > 8) break;
        }
    }

    fn url(r: *Run) []const u8 {
        return r.b.tabs.items[0].page.?.url();
    }
};

test "what isn't an address is searched for; Google first" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try testing.expectEqual(.google, r.b.engine);
    r.t.frame();
    r.t.typeText("not an address");
    r.t.key(.enter);
    r.settle();
    try testing.expectEqualStrings("data:text/html,found-not+an+address", r.url());
    try testing.expect(!r.b.box.refused);
}

test "nothing typed goes nowhere" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.t.frame();
    r.t.typeText("   ");
    r.t.key(.enter);
    r.t.frame();
    try testing.expect(r.b.tabs.items[0].isEmpty());
    try testing.expect(r.b.box.refused);
}

test "either engine can be picked in the field, and it says so" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.t.frame();
    try testing.expect(r.t.hasText("Search Google or enter an address"));
    try r.t.clickText("DuckDuckGo");
    r.t.frame();
    try testing.expectEqual(.duckduckgo, r.b.engine);
    try testing.expect(r.t.hasText("Search DuckDuckGo or enter an address"));
    try r.t.clickText("Google");
    r.t.frame();
    try testing.expectEqual(.google, r.b.engine);
    // A click on the choice doesn't lose the field.
    r.t.typeText("still typing");
    r.t.frame();
    try testing.expectEqualStrings("still typing", r.b.box.field.text());
}

test "suggestions show, the arrows reach them, and one is searched as it reads" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.b.suggest = try Suggest.create(testing.allocator, &r.b, Browser.redrawn);
    // Handed over as they'd come, with nothing to ask yet.
    r.t.frame();
    r.b.suggest.?.text.appendSlice(testing.allocator, "node") catch unreachable;
    r.b.box.field.set("node");
    r.b.suggest.?.take("[\"node\",[\"node.js\",\"node version\"]]");
    r.t.frame();
    try testing.expect(r.t.hasText("node.js"));
    try testing.expect(r.t.hasText("node version"));
    _ = r.t.shortcut(.{ .key = ui.Shortcut.down });
    r.t.key(.enter);
    r.settle();
    // It looks like an address, but a suggestion is a search.
    try testing.expectEqualStrings("data:text/html,found-node.js", r.url());
}

test "a suggestion the same as what's typed isn't offered twice" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.b.suggest = try Suggest.create(testing.allocator, &r.b, Browser.redrawn);
    r.t.frame();
    r.b.suggest.?.text.appendSlice(testing.allocator, "Bird") catch unreachable;
    r.b.box.field.set("Bird");
    r.b.suggest.?.take("[\"Bird\",[\"bird\",\"birdsong\"]]");
    var buf: [8]@import("omnibox.zig").Offer = undefined;
    const offers = r.b.currentOffers(&r.t.ctx, &buf);
    try testing.expectEqual(@as(usize, 1), offers.len);
    try testing.expectEqualStrings("birdsong", offers[0].url);
    try testing.expect(offers[0].search);
}
