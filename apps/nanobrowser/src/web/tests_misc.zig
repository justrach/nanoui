//! The rest of the platform's small things: `javascript:` addresses, `window.open`,
//! `postMessage`, the console, idle callbacks, walking the tree, body handlers.
const std = @import("std");
const nanoui = @import("nanoui");
const util = @import("tests_util.zig");
const web = @import("web.zig");
const world_mod = @import("world.zig");
const testing = std.testing;
const Run = util.Run;

test "a javascript: link runs, on a page with no scripts" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open("data:text/html,<!doctype html><a href=\"javascript:document.body.append('ran%20it')\">Go</a>");
    try testing.expect(r.page().js == null);
    try r.t.clickText("Go");
    r.settle();
    r.t.frame();
    try testing.expect(r.t.containsText("ran it"));
    try r.expectJs("document.readyState", "complete");
}

test "window.open opens a tab; el.click() follows a link" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><title>First</title><a id=l href='data:text/html,<p>by a click'>x</a>");
    _ = try r.eval("open('data:text/html,<p>from open'); 0");
    r.settle();
    try testing.expectEqual(@as(usize, 2), r.b.tabs.items.len);
    try testing.expect(r.t.hasText("from open"));
    r.b.current = 0;
    r.t.frame();
    _ = try r.eval("l.click(); 0");
    r.settle();
    try testing.expect(r.t.hasText("by a click"));
}

test "postMessage, idle callbacks, the console" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body onload="window.bodyLoaded = 1"><script>
        \\var got = []; addEventListener('message', e => { got.push(e.data.n + ':' + (e.source === window) + ':' + e.isTrusted) });
        \\var obj = {n: 1}; postMessage(obj, '*'); obj.n = 2; got.push('sync');
        \\requestIdleCallback(d => { window.idle = typeof d.timeRemaining() + d.didTimeout });
        \\var c = cancelIdleCallback(requestIdleCallback(() => { window.badIdle = 1 }));
        \\console.log('hello %s %d', 'there', 5, {a: [1]});
        \\console.warn('careful'); console.error('broken', new Error('x'));
        \\console.group('G'); console.info('inside'); console.groupEnd(); console.debug('dbg');
        \\console.table([1]); console.time('t'); console.timeEnd('t'); console.assert(false, 'no'); console.assert(true, 'yes'); console.count(); console.trace('tr');
        \\</script>
    );
    try r.waitJs("window.idle && got.length === 2 && window.bodyLoaded");
    try r.expectJs("got.join() + idle + typeof badIdle", "sync,1:true:truenumberfalseundefined");
    const w = r.world();
    try testing.expect(w.consoleHas("hello there 5 {a: [1]}"));
    try testing.expect(w.consoleHas("careful"));
    try testing.expect(w.consoleHas("  inside"));
    try testing.expect(w.consoleHas("Assertion failed: no"));
    try testing.expect(!w.consoleHas("Assertion failed: yes"));
    try testing.expect(w.consoleHas("default: 1"));
    const lines = web.consoleLines(r.page());
    try testing.expect(lines.len > 5);
    // The list is capped: it can't grow without bound.
    _ = try r.eval("for (let i = 0; i < 1500; i++) console.log('line ' + i); 0");
    try testing.expectEqual(world_mod.max_console, w.console.items.len);
    try testing.expect(w.consoleHas("line 1499"));
    try testing.expect(!w.consoleHas("hello there"));
}

test "walking the tree, ranges and the selection's little" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><div id=t>a<b>c<i>d</i></b><!--n-->e</div>");
    try util.table(&r, &.{
        .{ .js = "var w = document.createTreeWalker(t, NodeFilter.SHOW_TEXT); var out = []; while (w.nextNode()) out.push(w.currentNode.data); out.join()", .want = "a,c,d,e" },
        .{ .js = "var e = document.createTreeWalker(t, NodeFilter.SHOW_ELEMENT); e.nextNode().tagName + e.nextNode().tagName + e.parentNode().tagName + e.firstChild().tagName", .want = "BIBI" },
        .{ .js = "var f = document.createTreeWalker(t, NodeFilter.SHOW_ALL, {acceptNode: n => n.nodeType === 8 ? 1 : 3}); f.nextNode().data", .want = "n" },
        .{ .js = "var it = document.createNodeIterator(t, NodeFilter.SHOW_COMMENT); it.nextNode().data", .want = "n" },
        .{ .js = "var g = document.createRange(); g.selectNodeContents(t); [g.startContainer === t, g.startOffset, g.endOffset, g.collapsed].join()", .want = "true,0,4,false" },
        .{ .js = "g.collapse(true); g.collapsed", .want = "true" },
        .{ .js = "g.createContextualFragment('<u>x</u>').firstChild.tagName", .want = "U" },
        .{ .js = "getSelection().rangeCount + getSelection().toString() + getSelection().type", .want = "0None" },
        .{ .js = "var s = document.createElement('script'); s.type + s.async + s.src + s.defer", .want = "truefalse" },
        .{ .js = "var a = document.createElement('a'); a.href = 'http://x.example:81/p/q?r=1#s'; [a.protocol, a.host, a.hostname, a.port, a.pathname, a.search, a.hash, a.origin].join()", .want = "http:,x.example:81,x.example,81,/p/q,?r=1,#s,http://x.example:81" },
        .{ .js = "a.search = 'z=2'; a.hash = ''; a.pathname = 'k'; a.href", .want = "http://x.example:81/k?z=2" },
        .{ .js = "String(a) === a.href", .want = "true" },
        .{ .js = "var c = document.createElement('canvas'); typeof c.getContext('2d').fillRect + c.getContext('webgl') + c.width", .want = "functionnull300" },
        .{ .js = "var v = document.createElement('video'); v.paused + typeof v.play + v.canPlayType('video/mp4')", .want = "truefunction" },
        .{ .js = "document.createElement('iframe').contentWindow", .want = "null" },
        .{ .js = "var h = document.createElement('p'); h.hidden = true; h.title = 'x'; h.lang = 'en'; h.dir = 'ltr'; h.tabIndex = 2; h.getAttribute('hidden') + h.getAttribute('title') + h.lang + h.dir + h.tabIndex", .want = "xenltr2" },
        .{ .js = "h.setAttribute('aria-label', 'q'); h.ariaLabel", .want = "q" },
        .{ .js = "CSS.escape('a.b') + CSS.supports('display', 'flex') + CSS.supports('(color: red)')", .want = "a\\.btruetrue" },
    });
    try r.expectNoErrors();
}

test "assigning to style sets its text" {
    var r: util.Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><div id=a></div><svg id=b></svg>");
    try r.expectJs("a.style = 'color: red'; a.getAttribute('style')", "color: red");
    try r.expectJs("a.style.color", "red");
    try r.expectJs("b.style = 'fill: blue'; b.style.fill", "blue");
    try r.expectJs("a.style = ''; a.hasAttribute('style')", "false");
}
