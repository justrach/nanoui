//! What must not bring the browser down: a script that never ends, a page dying
//! with timers and requests outstanding, the collector running across many tasks.
const std = @import("std");
const nanoui = @import("nanoui");
const util = @import("tests_util.zig");
const World = @import("world.zig").World;
const testing = std.testing;
const Run = util.Run;

test "a runaway loop is ended, and the page still works" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><p id=p>before</p><script>window.early = 1</script>");
    const w = r.world();
    // Short deadlines for the test: the same path as the task's.
    w.enter();
    w.vm.setDeadline(40 * std.time.ns_per_ms);
    _ = w.vm.eval("while (true) {}", "runaway") catch |e| {
        try testing.expectEqual(error.Terminated, e);
        w.report(e);
    };
    w.leave();
    try testing.expect(w.consoleHas("ran too long"));
    _ = try r.eval("document.getElementById('p').textContent = 'after the loop'; 0");
    r.t.frame();
    try testing.expect(r.t.hasText("after the loop"));
    // A loop in a timer's task: the same, and timers go on.
    _ = try r.eval("window.later = 0; setTimeout(() => { later = 1 }, 1); 0");
    r.spin(0.02);
    try r.expectJs("later", "1");
}

test "a runaway in a page's own script, timer and handler: each ends, the page goes on" {
    const world_mod = @import("world.zig");
    const saved = world_mod.task_deadline_ns;
    world_mod.task_deadline_ns = 30 * std.time.ns_per_ms;
    defer world_mod.task_deadline_ns = saved;
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><p id=p>start</p>
        \\<script>window.before = 1; while (true) {} window.never = 1;</script>
        \\<script>window.second = 1; setTimeout(() => { while (true) {} }, 0); setTimeout(() => { window.third = 1 }, 1);
        \\document.addEventListener('click', () => { while (true) {} });
        \\Promise.resolve().then(() => { window.micro = 1 });</script>
    );
    r.spin(0.08);
    try util.table(&r, &.{
        .{ .js = "before + second + third + micro", .want = "4" },
        .{ .js = "typeof never", .want = "undefined" },
    });
    try testing.expect(r.world().consoleHas("ran too long"));
    // A click whose handler never ends: the deadline ends it; the frame goes on.
    try r.t.clickText("start");
    r.settle();
    _ = try r.eval("document.getElementById('p').textContent = 'still alive'; 0");
    r.t.frame();
    try testing.expect(r.t.hasText("still alive"));
}

test "a page dies with timers, frames and requests outstanding" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><script>
        \\window.t1 = setTimeout(() => { window.fired = 1 }, 5);
        \\window.t2 = setInterval(() => {}, 2);
        \\window.t3 = setTimeout(() => {}, 100000);
        \\requestAnimationFrame(() => {});
        \\new MutationObserver(() => {}).observe(document, {childList: true});
        \\new ResizeObserver(() => {}).observe(document.body);
        \\fetch('data:text/plain,x').then(r => r.text()).then(t => { window.got = t });
        \\var x = new XMLHttpRequest(); x.open('GET', 'data:text/plain,y'); x.send();
        \\</script>
    );
    // Before the answers have come, off it goes.
    r.b.tabs.items[0].go("data:text/html,<p>next one");
    for (0..30) |_| {
        nanoui.runFor(0.002);
        r.t.frame();
    }
    try testing.expect(r.t.hasText("next one"));
    // And a page torn down right after its scripts asked for things, with the
    // window gone too (the test allocator would say if anything leaks).
    r.b.tabs.items[0].go("data:text/html,<script>setTimeout(()=>{},1);fetch('data:text/plain,z')</script>");
}

test "scripts navigating away in the middle of things" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><script>location.href = 'data:text/html,<p>went away'; window.afterAssign = 1; setTimeout(() => {}, 1);</script><p>first");
    r.settle();
    try testing.expect(r.t.hasText("went away"));
    try r.html("<!doctype html><body><button onclick=\"location.href='data:text/html,<p>clicked away'\">go</button>");
    try r.t.clickText("go");
    r.settle();
    try testing.expect(r.t.hasText("clicked away"));
    try r.html("<!doctype html><body><script>setTimeout(() => { location.assign('data:text/html,<p>from timer') }, 1)</script>");
    r.spin(0.01);
    r.settle();
    try testing.expect(r.t.hasText("from timer"));
    try r.html("<!doctype html><body><script>requestAnimationFrame(() => { location.replace('data:text/html,<p>from frame') })</script>");
    r.t.frame();
    r.settle();
    try testing.expect(r.t.hasText("from frame"));
}

test "the collector across many tasks: wrappers, expandos and listeners stay" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><div id=root></div><script>
        \\var root = document.getElementById('root'), hits = 0, kept = [];
        \\function churn(i) {
        \\  var el = document.createElement('div');
        \\  el.expando = {i, junk: new Array(50).fill(i)};
        \\  el.addEventListener('ping', e => { hits += e.target.expando.i === i ? 1 : 0; });
        \\  root.appendChild(el);
        \\  if (i % 7) root.removeChild(el);
        \\  kept.push(el);
        \\  var junk = []; for (var j = 0; j < 200; j++) junk.push({j, s: 'x'.repeat(20)});
        \\  return junk.length;
        \\}
        \\</script>
    );
    const w = r.world();
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        var buf: [64]u8 = undefined;
        _ = try r.eval(try std.fmt.bufPrint(&buf, "churn({d}); 0", .{i}));
        w.vm.collect();
    }
    try r.expectJs("kept.every(k => k.expando && k.expando.junk.length === 50)", "true");
    _ = try r.eval("kept.forEach(k => k.dispatchEvent(new Event('ping'))); 0");
    w.vm.collect();
    try r.expectJs("hits", "60");
    try r.expectJs("root.children.length", "9");
    try r.expectJs("root.children === root.children && root.children[0].expando.i === 0", "true");
    // Timers and observers across collections.
    _ = try r.eval("window.tick = 0; window.iv = setInterval(() => { var o = {}; tick++; }, 1); window.obs = 0; new MutationObserver(() => obs++).observe(root, {childList: true}); root.textContent = ''; 0");
    w.vm.collect();
    r.spin(0.01);
    w.vm.collect();
    r.spin(0.01);
    try r.expectJs("clearInterval(iv); tick > 0 && obs", "1");
    // The world's own threshold, on the task path.
    w.gc_next = 0;
    _ = try r.eval("0");
    try r.expectNoErrors();
}
