//! The first thing that has to work: scripts run and the page changes.
const std = @import("std");
const util = @import("tests_util.zig");
const testing = std.testing;
const Run = util.Run;

test "a script runs and what it writes is drawn" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><p id=a>before</p><script>document.getElementById('a').textContent='after js';</script>");
    try r.expectNoErrors();
    try testing.expect(r.t.hasText("after js"));
    try testing.expect(!r.t.hasText("before"));
}
