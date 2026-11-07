//! What a new window size costs: no restyle unless a style depends on the size, and
//! during a drag no layout more often than the page can afford.
const std = @import("std");
const util = @import("../web/tests_util.zig");
const tests = @import("tests.zig");
const resize = @import("../page_resize.zig");
const testing = std.testing;
const Run = util.Run;

fn generationAfterResize(r: *Run) !u32 {
    const p = r.page();
    r.t.frame();
    const before = p.engine.generation;
    r.t.resize(r.t.size.w - 200, r.t.size.h);
    r.t.frame();
    return p.engine.generation - before;
}

test "a new size restyles nothing when no style depends on it" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<style>#a{width:50%;height:20px}</style><div id=a></div>");
    const laid = r.page().layouts;
    try testing.expectEqual(@as(u32, 0), try generationAfterResize(&r));
    try testing.expect(r.page().layouts > laid);
    try r.expectJs("document.getElementById('a').getBoundingClientRect().width", "350");
}

test "viewport units and media queries that flip do restyle" {
    {
        var r: Run = undefined;
        try r.start();
        defer r.stop();
        try tests.page(&r, "<style>#a{width:50vw;height:20px}</style><div id=a></div>");
        try testing.expect(try generationAfterResize(&r) > 0);
        try r.expectJs("document.getElementById('a').getBoundingClientRect().width", "350");
    }
    {
        var r: Run = undefined;
        try r.start();
        defer r.stop();
        try tests.page(&r, "<style>#a{width:10px;height:20px}@media (max-width:800px){#a{width:30px}}</style><div id=a></div>");
        try testing.expect(try generationAfterResize(&r) > 0);
        try r.expectJs("document.getElementById('a').getBoundingClientRect().width", "30");
    }
}

test "a viewport unit in a custom property counts" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<style>:root{--w:50vw}#a{width:var(--w);height:20px}</style><div id=a></div>");
    try testing.expect(try generationAfterResize(&r) > 0);
    try r.expectJs("document.getElementById('a').getBoundingClientRect().width", "350");
}

test "a media query that stays as it was doesn't restyle" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<style>#a{height:20px}@media (max-width:100px){#a{width:30px}}</style><div id=a></div>");
    try testing.expectEqual(@as(u32, 0), try generationAfterResize(&r));
}

test "the resize event still comes" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<div></div><script>var n=0;addEventListener('resize',function(){n++})</script>");
    _ = try generationAfterResize(&r);
    r.t.frame();
    try tests.expectEqJs(&r, "n", "1");
}

test "a dear layout waits during a drag, and a drag's end lays out at once" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<div style='width:50%;height:20px' id=a></div>");
    const p = r.page();
    const w = r.t.size.w;
    r.t.ctx.live_resizing = true;
    p.resize_cost = 0.1;
    p.resized_at = resize.now();
    const laid = p.layouts;
    const wide = p.viewport_w;
    r.t.resize(w - 200, r.t.size.h);
    try testing.expectEqual(laid, p.layouts);
    try testing.expectEqual(wide, p.viewport_w);
    try testing.expect(r.t.ctx.frame_in != null);
    r.t.ctx.live_resizing = false;
    r.t.frame();
    try testing.expect(p.layouts > laid);
    try testing.expectEqual(wide - 200, p.viewport_w);
}

test "a cheap layout runs at every change of a drag" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<div style='width:50%;height:20px'></div>");
    const p = r.page();
    r.t.ctx.live_resizing = true;
    p.resize_cost = 0;
    const laid = p.layouts;
    r.t.resize(r.t.size.w - 100, r.t.size.h);
    try testing.expect(p.layouts > laid);
    r.t.ctx.live_resizing = false;
}

test "once a dear layout's wait is over the drag catches up" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<div style='width:50%;height:20px'></div>");
    const p = r.page();
    r.t.ctx.live_resizing = true;
    p.resize_cost = 0.01;
    p.resized_at = resize.now() - 1;
    const laid = p.layouts;
    r.t.resize(r.t.size.w - 100, r.t.size.h);
    try testing.expect(p.layouts > laid);
    r.t.ctx.live_resizing = false;
}
