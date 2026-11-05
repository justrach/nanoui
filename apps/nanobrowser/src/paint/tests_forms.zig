//! Form controls: what the author draws and what is left native.
const std = @import("std");
const util = @import("../web/tests_util.zig");
const tests = @import("tests.zig");
const testing = std.testing;
const Run = util.Run;

test "appearance:none leaves a control to the author's CSS: a round radio" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<input type=radio checked style='position:absolute;left:0;top:0;margin:0;width:40px;height:40px;appearance:none;-webkit-appearance:none;border-radius:50%;background:#f00;border:0'>");
    try testing.expect(tests.isRed(try tests.pixel(&r, 20, 20)));
    try testing.expect(tests.isWhite(try tests.pixel(&r, 2, 2)));
    // No native mark in its middle.
    try testing.expect(tests.isRed(try tests.pixel(&r, 21, 21)));
}

test "a radio is round, and takes accent-color when checked" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<input type=radio checked style='position:absolute;left:0;top:0;margin:0;width:40px;height:40px;accent-color:#f00'>");
    try testing.expect(tests.isWhite(try tests.pixel(&r, 2, 2)));
    try testing.expect(tests.isRed(try tests.pixel(&r, 1, 20)));
    try tests.page(&r, "<input type=checkbox checked style='position:absolute;left:0;top:0;margin:0;width:40px;height:40px;accent-color:#00f'>");
    try testing.expect(tests.isBlue(try tests.pixel(&r, 5, 20)));
}

test "a text field and a button are drawn thin and rounded as Chromium's, until the author says" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<input style='position:absolute;left:0;top:0;margin:0;width:100px;height:30px'>");
    // A thin line: gray at the very edge, white right inside it.
    const edge = try tests.pixel(&r, 50, 0);
    try testing.expect(edge[1] < 170);
    try testing.expect(tests.isWhite(try tests.pixel(&r, 50, 2)));
    try tests.page(&r, "<input style='position:absolute;left:0;top:0;margin:0;width:100px;height:30px;border:4px solid #f00'>");
    try testing.expect(tests.isRed(try tests.pixel(&r, 50, 2)));
}

test "::placeholder's color reaches the field, and vendor pseudo-elements do no harm" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>input::placeholder { color: #f00 } input::-webkit-search-cancel-button { display:none } input::-moz-focus-inner { border:0 }
        \\input::-webkit-outer-spin-button, input::-webkit-inner-spin-button { margin:0 }</style>
        \\<input id=a placeholder=WWWW style='position:absolute;left:0;top:0;margin:0;width:200px;height:40px;font-size:24px;border:0;padding:0'>
    );
    var red: u32 = 0;
    var y: f32 = 0;
    while (y < 40) : (y += 1) {
        var x: f32 = 0;
        while (x < 100) : (x += 1) {
            if (tests.isRed(try tests.pixel(&r, x, y))) red += 1;
        }
    }
    try testing.expect(red > 5);
}
