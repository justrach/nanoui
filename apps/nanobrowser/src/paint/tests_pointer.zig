//! What a pointer costs: hover that changes a color doesn't lay the page out, and
//! a page scrolling under a still pointer doesn't restyle what passes beneath it.
const std = @import("std");
const util = @import("../web/tests_util.zig");
const tests = @import("tests.zig");
const testing = std.testing;
const Run = util.Run;

const rows =
    \\<style>.r{height:100px;background:#fff} .r:hover{background:#f00}</style>
    \\<div class=r id=a></div><div class=r id=b></div><div class=r id=c></div>
    \\<div class=r></div><div class=r></div><div class=r></div><div class=r></div>
    \\<div class=r></div><div class=r></div><div class=r></div><div class=r></div>
    \\<div class=r></div><div class=r></div><div class=r></div><div class=r></div>
;

test "a :hover that changes a color doesn't lay the page out" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, rows);
    const p = r.page();
    const laid = p.layouts;
    r.t.moveTo(p.origin[0] + 50, p.origin[1] + 50);
    r.t.frame();
    try testing.expect(tests.isRed(try tests.pixel(&r, 50, 50)));
    try testing.expectEqual(laid, p.layouts);
}

test "hover waits for a scroll to stop, then finds what's there" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, rows);
    const p = r.page();
    const x = p.origin[0] + 50;
    const y = p.origin[1] + 50;
    r.t.moveTo(x, y);
    r.t.frame();
    const first = p.doc.hover orelse return error.NoHover;
    r.t.ctx.input.precise = true;
    r.t.scroll(x, y, -150);
    r.t.frame();
    try testing.expect(p.doc.hover == first);
    r.t.advance(0.2);
    r.t.frame();
    try testing.expect(p.doc.hover != null and p.doc.hover != first);
    try testing.expect(tests.isRed(try tests.pixel(&r, 50, 50)));
}

test "a click during a scroll goes to what's under the pointer now" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, rows ++ "<script>var got='';addEventListener('click',function(e){got=e.target.id})</script>");
    const p = r.page();
    const x = p.origin[0] + 50;
    const y = p.origin[1] + 50;
    r.t.moveTo(x, y);
    r.t.frame();
    r.t.ctx.input.precise = true;
    r.t.scroll(x, y, -150);
    r.t.click(x, y);
    // 50 down the window, scrolled by 150: the third row.
    try tests.expectEqJs(&r, "got", "c");
}
