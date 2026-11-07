//! Sheets that arrive one by one: applied together, and never hidden from a script.
const std = @import("std");
const util = @import("../web/tests_util.zig");
const testing = std.testing;
const Run = util.Run;

test "sheets that come together restyle the page once" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><link rel=stylesheet href="data:text/css,%23a{color:rgb(1,0,0)}">
        \\<link rel=stylesheet href="data:text/css,%23b{color:rgb(2,0,0)}">
        \\<link rel=stylesheet href="data:text/css,%23c{color:rgb(3,0,0)}">
        \\<link rel=stylesheet href="data:text/css,%23d{color:rgb(4,0,0)}">
        \\<p id=a>a<p id=b>b<p id=c>c<p id=d>d
    );
    r.settle();
    r.t.frame();
    try r.expectJs("getComputedStyle(document.getElementById('a')).color", "rgb(1, 0, 0)");
    try r.expectJs("getComputedStyle(document.getElementById('d')).color", "rgb(4, 0, 0)");
    // Once before they came, once for them, and one more if they fell apart.
    try testing.expect(r.page().engine.generation <= 3);
}

test "a link's load event sees its sheet while another is coming" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><p id=a>a<script>
        \\var one=document.createElement('link');one.rel='stylesheet';
        \\one.href='data:text/css,%23a{color:rgb(9,8,7)}';
        \\one.onload=function(){window.got=getComputedStyle(document.getElementById('a')).color};
        \\document.head.appendChild(one);
        \\var two=document.createElement('link');two.rel='stylesheet';two.href='data:text/css,b{}';
        \\document.head.appendChild(two);
        \\</script>
    );
    try r.waitJs("window.got");
    try r.expectJs("window.got", "rgb(9, 8, 7)");
}

test "sheets held in a frame's page are given to it when they're due" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><iframe srcdoc=\"<!doctype html><p>x\"></iframe>");
    r.settle();
    r.t.frame();
    const child = r.page().frames.list.items[0].page orelse return error.NoPage;
    const s = &child.sheets;
    s.held = true;
    s.asked = 1;
    s.due = child.engine.now + 0.1;
    r.t.frame();
    try testing.expect(s.held);
    r.t.advance(0.3);
    r.t.frame();
    try testing.expect(!s.held);
}
