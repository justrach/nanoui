//! How a page scrolls: a wheel's notches and keys glide, a trackpad goes straight
//! through, and what animates out of sight costs nothing.
const std = @import("std");
const util = @import("../web/tests_util.zig");
const tests = @import("tests.zig");
const testing = std.testing;
const Run = util.Run;

const tall = "<div style='height:4000px'></div>";

test "a wheel's notch glides there and lands" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, tall);
    const p = r.page();
    r.t.ctx.input.precise = false;
    r.t.scroll(p.origin[0] + 50, p.origin[1] + 50, -120);
    const first = p.scrollY();
    try testing.expect(first > 0 and first < 120);
    r.t.scroll(p.origin[0] + 50, p.origin[1] + 50, -120);
    r.t.advance(1);
    try testing.expectApproxEqAbs(@as(f32, 240), p.scrollY(), 0.01);
    try testing.expect(p.glide == null);
}

test "a glide stops at the end of the page" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, tall);
    const p = r.page();
    r.t.ctx.input.precise = false;
    r.t.scroll(p.origin[0] + 50, p.origin[1] + 50, 500);
    try testing.expectEqual(@as(f32, 0), p.scrollY());
    try testing.expect(p.glide == null);
}

test "a trackpad goes straight through, and takes over from a glide" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, tall);
    const p = r.page();
    r.t.ctx.input.precise = true;
    r.t.scroll(p.origin[0] + 50, p.origin[1] + 50, -100);
    try testing.expectEqual(@as(f32, 100), p.scrollY());
    r.t.ctx.input.precise = false;
    r.t.scroll(p.origin[0] + 50, p.origin[1] + 50, -300);
    try testing.expect(p.glide != null);
    r.t.ctx.input.precise = true;
    const at = p.scrollY();
    r.t.scroll(p.origin[0] + 50, p.origin[1] + 50, -1);
    try testing.expect(p.glide == null);
    try testing.expectEqual(at + 1, p.scrollY());
}

test "keys glide, and a script's scroll takes over" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, tall);
    const p = r.page();
    r.t.ctx.input.mouse = .{ .x = p.origin[0] + 50, .y = p.origin[1] + 50 };
    r.t.key(.page_down);
    r.t.ctx.input.key = null;
    try testing.expect(p.glide != null and p.scrollY() > 0);
    _ = try r.eval("scrollTo(0, 700); 0");
    try testing.expect(p.glide == null);
    r.t.advance(0.5);
    try testing.expectEqual(@as(f32, 700), p.scrollY());
}

const below =
    \\<style>@keyframes o { from { opacity: 0 } to { opacity: 1 } }
    \\#a { position:absolute; left:0; top:3000px; width:50px; height:50px; background:#f00; animation: o 0.4s linear alternate infinite }
    \\</style><div style='height:4000px'></div><div id=a></div>
;

test "an animation far out of sight doesn't rebuild the list or ask for every frame" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, below);
    const p = r.page();
    r.t.frame();
    const lists = p.lists;
    r.t.advance(0.3);
    r.t.frame();
    try testing.expectEqual(lists, p.lists);
    try testing.expect(p.motion_unseen);
    try testing.expect(!r.t.ctx.animating);
    try testing.expect(r.t.ctx.frame_in != null);
}

test "it starts drawing again before it comes into view" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, below);
    const p = r.page();
    r.t.frame();
    const lists = p.lists;
    _ = try r.eval("scrollTo(0, 2960); 0");
    r.t.frame();
    r.t.frame();
    try testing.expect(!p.motion_unseen);
    try testing.expect(p.lists > lists);
    try testing.expect(r.t.ctx.animating);
}

test "an animation that ended out of sight shows how it ended" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>@keyframes c { from { background:#f00 } to { background:#00f } }
        \\#a { position:absolute; left:0; top:3000px; width:50px; height:50px; background:#f00; animation: c 0.3s linear forwards }
        \\</style><div style='height:4000px'></div><div id=a></div>
    );
    r.t.advance(1);
    r.t.frame();
    _ = try r.eval("scrollTo(0, 3000); 0");
    r.t.frame();
    r.t.frame();
    try testing.expect(tests.isBlue(try tests.pixel(&r, 10, 10)));
}

test "a hidden element's animation is out of sight wherever its box would be" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>@keyframes o { from { opacity: 0 } to { opacity: 1 } }
        \\#a { width:50px; height:50px; animation: o 0.4s linear alternate infinite }
        \\</style><div style='display:none'><div id=a></div></div><div style='width:50px;height:50px;background:#0f0'></div>
    );
    const p = r.page();
    r.t.frame();
    try testing.expect(!r.t.ctx.animating);
    try testing.expect(p.engine.anim.states.count() == 0 or p.motion_unseen);
}

fn wheelAt(r: *Run, x: f32, y: f32, dx: f32, dy: f32) void {
    const p = r.page();
    r.t.ctx.input.mouse = .{ .x = p.origin[0] + x, .y = p.origin[1] + y };
    r.t.ctx.input.precise = true;
    r.t.ctx.input.scroll = .{ .x = dx, .y = dy };
    r.t.frame();
    r.t.ctx.input.scroll = .{};
    r.t.frame();
}

test "a root with overflow of its own leaves the body's alone, and the page scrolls" {
    // DuckDuckGo's: `hidden` on the body isn't the viewport's beside a root that said anything.
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><style>html{overflow:hidden;overflow-y:auto}body{overflow:hidden;height:auto;margin:0}</style><div style='height:4000px'></div>");
    r.settle();
    r.t.frame();
    wheelAt(&r, 50, 50, 0, -100);
    try testing.expectEqual(@as(f32, 100), r.page().scrollY());
}

test "overflow hidden on the root or the body alone still holds the page" {
    for ([_][]const u8{ "html{overflow:hidden}", "body{overflow:hidden}" }) |rule| {
        var r: Run = undefined;
        try r.start();
        defer r.stop();
        const src = try std.fmt.allocPrint(testing.allocator, "<!doctype html><style>{s}body{{margin:0}}</style><div style='height:4000px'></div>", .{rule});
        defer testing.allocator.free(src);
        try r.html(src);
        r.settle();
        r.t.frame();
        wheelAt(&r, 50, 50, 0, -100);
        try testing.expectEqual(@as(f32, 0), r.page().scrollY());
    }
}

const carousel =
    \\<div id=row style='overflow-x:auto;overflow-y:hidden;height:100px;white-space:nowrap'><div style='display:inline-block;width:3000px;height:300px'></div></div>
    \\<div style='height:4000px'></div>
;

test "a scroll down over a sideways carousel moves the page" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, carousel);
    wheelAt(&r, 50, 50, 0, -100);
    try testing.expectEqual(@as(f32, 100), r.page().scrollY());
    try r.expectJs("document.getElementById('row').scrollTop", "0");
    // A trackpad is never quite straight: a little sideways doesn't take it.
    wheelAt(&r, 50, 10, -3, -100);
    try testing.expectEqual(@as(f32, 200), r.page().scrollY());
}

test "a scroll sideways over a carousel moves the carousel" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, carousel);
    wheelAt(&r, 50, 50, -100, -3);
    try r.expectJs("document.getElementById('row').scrollLeft", "100");
    try testing.expectEqual(@as(f32, 0), r.page().scrollY());
}

test "a list at its end hands the scroll to the page" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<div id=l style='overflow:auto;height:100px'><div style='height:150px'></div></div><div style='height:4000px'></div>");
    wheelAt(&r, 50, 50, 0, -30);
    try r.expectJs("document.getElementById('l').scrollTop", "30");
    try testing.expectEqual(@as(f32, 0), r.page().scrollY());
    wheelAt(&r, 50, 50, 0, -40);
    wheelAt(&r, 50, 20, 0, -40);
    try testing.expect(r.page().scrollY() > 0);
}
