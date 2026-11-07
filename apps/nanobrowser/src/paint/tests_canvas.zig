//! A `<canvas>` shows what its context gives it, at its CSS size.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const util = @import("../web/tests_util.zig");
const tests = @import("tests.zig");
const testing = std.testing;
const Run = util.Run;

const Red = struct {
    px: [16]u8 = .{ 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255 },
    asked: u32 = 0,
    fn pixels(ctx: *anyopaque) ?ui.Texture {
        const s: *Red = @ptrCast(@alignCast(ctx));
        s.asked += 1;
        return .{ .width = 2, .height = 2, .bgra = &s.px };
    }
};

const page =
    \\<canvas id=c width=2 height=2 style='position:absolute;left:0;top:0;width:60px;height:60px'></canvas>
    \\<div style='height:4000px'></div>
;

test "a canvas shows its source's pixels at its CSS size" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, page);
    var red: Red = .{};
    const p = r.page();
    const node = p.doc.getElementById("c").?;
    try p.canvases.set(testing.allocator, node, .{ .ctx = &red, .pixels = Red.pixels });
    r.t.frame();
    try testing.expect(tests.isRed(try tests.pixel(&r, 30, 30)));
    try testing.expect(tests.isWhite(try tests.pixel(&r, 90, 30)));
}

test "a canvas out of view isn't asked for its pixels" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, page);
    var red: Red = .{};
    const p = r.page();
    try p.canvases.set(testing.allocator, p.doc.getElementById("c").?, .{ .ctx = &red, .pixels = Red.pixels });
    _ = try r.eval("scrollTo(0, 2000); 0");
    r.t.frame();
    r.t.frame();
    const before = red.asked;
    r.t.frame();
    try testing.expectEqual(before, red.asked);
}

test "without a source a canvas is what it was: empty, and the right size" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<canvas id=c></canvas>");
    try r.expectJs("document.getElementById('c').getBoundingClientRect().width", "300");
    try testing.expect(tests.isWhite(try tests.pixel(&r, 30, 30)));
}
