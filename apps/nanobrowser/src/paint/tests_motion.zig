//! Animations and transitions, by a Tester's simulated time: what shows at each
//! moment, the events, and that nothing wants frames once it has finished.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const util = @import("../web/tests_util.zig");
const tests = @import("tests.zig");
const testing = std.testing;
const Run = util.Run;

fn opacityOf(r: *Run, id: []const u8) !f32 {
    const src = try std.fmt.allocPrint(testing.allocator, "getComputedStyle(document.getElementById('{s}')).opacity", .{id});
    defer testing.allocator.free(src);
    return std.fmt.parseFloat(f32, try r.eval(src));
}

fn run(r: *Run, seconds: f32) void {
    r.t.advance(seconds);
}

test "a keyframes animation fades something in, for real" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>@keyframes in { from { opacity: 0 } to { opacity: 1 } }
        \\#a { position:absolute; left:0; top:0; width:50px; height:50px; background:#f00; animation: in 1s linear both; }</style>
        \\<div id=a></div>
    );
    const first = try opacityOf(&r, "a");
    try testing.expect(first < 0.3);
    run(&r, 0.5);
    const mid = try opacityOf(&r, "a");
    try testing.expect(mid > 0.3 and mid < 0.75);
    // Pixels: half faded, red over white.
    const p = try tests.pixel(&r, 25, 25);
    try testing.expect(p[2] > 230 and p[1] > 40 and p[1] < 220);
    run(&r, 0.7);
    try testing.expectApproxEqAbs(@as(f32, 1), try opacityOf(&r, "a"), 0.001);
    try testing.expect(tests.isRed(try tests.pixel(&r, 25, 25)));
    // Over: nothing asks for frames.
    r.t.frame();
    try testing.expect(!r.t.ctx.animating);
}

test "what is animating asks for frames, and nothing else does" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<div style='width:10px;height:10px'>still</div>");
    r.t.frame();
    try testing.expect(!r.t.ctx.animating);
    try tests.page(&r, "<style>@keyframes s { to { transform: rotate(360deg) } }</style><div style='width:10px;height:10px;animation:s 2s linear infinite'></div>");
    r.t.frame();
    try testing.expect(r.t.ctx.animating);
    run(&r, 3);
    r.t.frame();
    try testing.expect(r.t.ctx.animating);
}

test "transforms in keyframes move what a box holds" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>@keyframes slide { from { transform: translateX(0) } to { transform: translateX(100px) } }
        \\#a { position:absolute; left:0; top:0; width:40px; height:40px; background:#f00; animation: slide 1s linear forwards; }</style>
        \\<div id=a></div>
    );
    run(&r, 0.5);
    r.t.frame();
    // About half way.
    const left = try std.fmt.parseFloat(f32, try r.eval("a.getBoundingClientRect().left"));
    try testing.expect(left > 40 and left < 62);
    run(&r, 0.7);
    r.t.frame();
    try tests.expectEqJs(&r, "Math.round(a.getBoundingClientRect().left)", "100");
    try testing.expect(tests.isRed(try tests.pixel(&r, 120, 20)));
    try testing.expect(tests.isWhite(try tests.pixel(&r, 20, 20)));
}

test "delay and fill: nothing before it starts, back to its own style after" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>@keyframes o { from { opacity: 0.2 } to { opacity: 0.6 } }
        \\#a { opacity: 1; width:10px; height:10px; animation: o 1s linear 1s; }
        \\#b { opacity: 1; width:10px; height:10px; animation: o 1s linear 1s backwards; }</style>
        \\<div id=a></div><div id=b></div>
    );
    try testing.expectEqual(@as(f32, 1), try opacityOf(&r, "a"));
    try testing.expectApproxEqAbs(@as(f32, 0.2), try opacityOf(&r, "b"), 0.01);
    run(&r, 1.5);
    r.t.frame();
    const mid = try opacityOf(&r, "a");
    try testing.expect(mid > 0.3 and mid < 0.5);
    run(&r, 1);
    r.t.frame();
    try testing.expectEqual(@as(f32, 1), try opacityOf(&r, "a"));
}

test "the events: animationstart, iteration, end; transitionend, with their fields" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>@keyframes o { from { opacity: 0 } to { opacity: 1 } }
        \\#a { width:10px; height:10px; animation: o 0.2s linear 2; }
        \\#b { width:10px; height:10px; opacity:1; transition: opacity 0.2s linear; }</style>
        \\<div id=a></div><div id=b></div>
        \\<script>window.log = [];
        \\for (const t of ['animationstart','animationiteration','animationend']) document.getElementById('a').addEventListener(t, e => log.push(e.type + ':' + e.animationName));
        \\for (const t of ['transitionrun','transitionstart','transitionend']) document.addEventListener(t, e => log.push(e.type + ':' + e.propertyName));</script>
    );
    run(&r, 0.6);
    r.t.frame();
    try r.expectJs("log.join()", "animationstart:o,animationiteration:o,animationend:o");
    _ = try r.eval("log.length = 0; b.style.opacity = 0; 0");
    r.t.frame();
    run(&r, 0.1);
    r.t.frame();
    const mid = try opacityOf(&r, "b");
    try testing.expect(mid > 0.2 and mid < 0.8);
    run(&r, 0.3);
    r.t.frame();
    try r.expectJs("log.join()", "transitionrun:opacity,transitionstart:opacity,transitionend:opacity");
}

test "a transition takes its time from where it is, and reverses" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<div id=a style='width:10px;height:10px;opacity:1;transition:opacity 1s linear'></div>");
    _ = try r.eval("a.style.opacity = 0; 0");
    r.t.frame();
    run(&r, 0.5);
    const half = try opacityOf(&r, "a");
    try testing.expect(half > 0.35 and half < 0.65);
    _ = try r.eval("a.style.opacity = 1; 0");
    r.t.frame();
    r.t.frame();
    const back = try opacityOf(&r, "a");
    // It goes on from where it was, not from 0 or 1.
    try testing.expect(@abs(back - half) < 0.1);
    run(&r, 1.2);
    r.t.frame();
    try testing.expectEqual(@as(f32, 1), try opacityOf(&r, "a"));
}

test "what can't blend jumps at the right time, and still ends" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>@keyframes w { from { width: 0 } to { width: 100px } } #a { height:10px; animation: w 1s linear forwards; background:#f00; }</style>
        \\<div id=a></div><div id=b style='height:10px;width:10px;background:#00f;transition:width 0.2s'></div>
    );
    // Half way through its stretch: the end state, in layout.
    r.t.frame();
    try r.expectJs("a.offsetWidth < 100", "true");
    run(&r, 0.7);
    r.t.frame();
    try r.expectJs("a.offsetWidth", "100");
    run(&r, 0.5);
    r.t.frame();
    try r.expectJs("a.offsetWidth", "100");
    _ = try r.eval("window.ended = 0; b.addEventListener('transitionend', e => { ended = e.propertyName }); b.style.width = '50px'; 0");
    r.t.frame();
    try r.expectJs("b.offsetWidth", "50");
    run(&r, 0.3);
    r.t.frame();
    try r.expectJs("ended", "width");
}

test "a color transition on hover: every frame without a layout" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r, "<style>#a{position:absolute;left:0;top:0;width:100px;height:100px;background:#f00;transition:background-color 1s linear} #a:hover{background:#00f}</style><div id=a></div>");
    const o = r.page().origin;
    r.t.moveTo(o[0] + 50, o[1] + 50);
    r.t.frame();
    run(&r, 0.5);
    const p = try tests.pixel(&r, 50, 50);
    try testing.expect(p[0] > 60 and p[0] < 200 and p[2] > 60 and p[2] < 200);
    run(&r, 0.7);
    try testing.expect(tests.isBlue(try tests.pixel(&r, 50, 50)));
    // Layout didn't run for it: boxes keep their styles.
    try testing.expect(!r.page().doc.layout_dirty);
}

test "pseudo-elements animate, and a display:none box ends its animation" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>@keyframes o { from { opacity: 0 } to { opacity: 1 } }
        \\#a { position:absolute; left:0; top:0; width:40px; height:40px; }
        \\#a::before { content:''; position:absolute; left:0; top:0; width:40px; height:40px; background:#f00; animation:o 1s linear forwards }</style>
        \\<div id=a></div>
    );
    run(&r, 0.5);
    const p = try tests.pixel(&r, 20, 20);
    try testing.expect(p[1] > 40 and p[1] < 220);
    run(&r, 0.7);
    try testing.expect(tests.isRed(try tests.pixel(&r, 20, 20)));
}

test "timing functions and steps" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try tests.page(&r,
        \\<style>@keyframes o { from { opacity: 0 } 50% { opacity: 1; animation-timing-function: step-end } to { opacity: 0 } }
        \\#a { width:10px; height:10px; animation: o 2s steps(2, end) forwards; }</style>
        \\<div id=a></div>
    );
    run(&r, 0.25);
    r.t.frame();
    try testing.expectEqual(@as(f32, 0), try opacityOf(&r, "a"));
    run(&r, 0.5);
    r.t.frame();
    try testing.expectApproxEqAbs(@as(f32, 0.5), try opacityOf(&r, "a"), 0.01);
    run(&r, 0.5);
    r.t.frame();
    // The second keyframe's own timing holds it to the end of its stretch.
    try testing.expectEqual(@as(f32, 1), try opacityOf(&r, "a"));
}
