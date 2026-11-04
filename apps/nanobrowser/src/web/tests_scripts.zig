//! Script order, as the HTML spec has it: classic, `defer`, `async`, modules,
//! `readyState`, `DOMContentLoaded` and `load`, `document.write`, `currentScript`.
const std = @import("std");
const util = @import("tests_util.zig");
const testing = std.testing;
const Run = util.Run;

test "classic, defer, module and events in order" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><head><script>
        \\var log = []; log.push('head:' + document.readyState);
        \\document.addEventListener('readystatechange', () => log.push('rsc:' + document.readyState));
        \\document.addEventListener('DOMContentLoaded', () => log.push('dcl:' + document.readyState));
        \\addEventListener('load', () => log.push('load:' + document.readyState));
        \\</script>
        \\<script src="data:text/javascript,log.push('external')"></script>
        \\<script defer src="data:text/javascript,log.push('defer1')"></script>
        \\<script type=module>log.push('module');</script>
        \\<script defer src="data:text/javascript,log.push('defer2')"></script>
        \\<script nomodule>log.push('nomodule!');</script>
        \\<script type="application/json" id=data>{"a":1}</script>
        \\<script type="text/template">log.push('template!');</script>
        \\</head><body><script>log.push('body');</script></body>
    );
    try r.waitJs("document.readyState === 'complete'");
    try r.expectJs("log.join()", "head:loading,external,body,rsc:interactive,defer1,module,defer2,dcl:interactive,rsc:complete,load:complete");
    try r.expectJs("JSON.parse(document.getElementById('data').textContent).a", "1");
    try r.expectNoErrors();
}

test "async scripts run as they arrive and hold up load" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><script>var log = []; addEventListener('load', () => log.push('load'));</script>
        \\<script async src="data:text/javascript,log.push('async')"></script>
        \\<script>log.push('inline');</script>
    );
    try r.waitJs("document.readyState === 'complete'");
    try r.expectJs("log[0]", "inline");
    try r.expectJs("log.indexOf('async') < log.indexOf('load') && log.indexOf('async') > 0", "true");
    try r.expectNoErrors();
}

test "currentScript, and scripts added by scripts run once when connected" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><script id=me>window.cur = document.currentScript.id; window.count = 0;</script>
        \\<script>
        \\var s = document.createElement('script');
        \\s.textContent = 'count++; window.inner = document.currentScript === s';
        \\window.before = count;
        \\document.body.appendChild(s);
        \\window.after = count;
        \\s.remove(); document.body.appendChild(s);
        \\window.again = count;
        \\var d = document.createElement('script');
        \\d.src = "data:text/javascript,window.fromSrc = 1";
        \\window.loaded = 0;
        \\d.onload = () => { loaded = 1 };
        \\window.isAsync = d.async;
        \\document.head.appendChild(d);
        \\window.stillUnset = typeof fromSrc;
        \\var o1 = document.createElement('script'); o1.async = false; o1.src = "data:text/javascript,(window.order=window.order||[]).push(1)";
        \\var o2 = document.createElement('script'); o2.async = false; o2.src = "data:text/javascript,(window.order=window.order||[]).push(2)";
        \\document.head.append(o1, o2);
        \\var bad = document.createElement('script'); bad.src = 'data:text/javascript,'; bad.type = 'text/nope'; document.head.appendChild(bad);
        \\var neverRan = document.createElement('div'); neverRan.innerHTML = '<script>window.fromInner = 1</scr' + 'ipt>'; document.body.appendChild(neverRan);
        \\</script>
    );
    try r.waitJs("loaded === 1 && window.order && order.length === 2");
    try util.table(&r, &.{
        .{ .js = "cur", .want = "me" },
        .{ .js = "before + ',' + after + ',' + again", .want = "0,1,1" },
        .{ .js = "inner", .want = "true" },
        .{ .js = "isAsync", .want = "true" },
        .{ .js = "stillUnset", .want = "undefined" },
        .{ .js = "fromSrc", .want = "1" },
        .{ .js = "order.join()", .want = "1,2" },
        .{ .js = "typeof fromInner", .want = "undefined" },
        .{ .js = "document.currentScript", .want = "null" },
    });
    try r.expectNoErrors();
}

test "document.write, while parsing and after" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><div id=a>A</div><script id=w>
        \\document.write('<p id=w1>written</p>');
        \\document.write('<p id=w2>second</p><scr' + 'ipt>window.ranWritten = document.getElementById("after") !== null;</scr' + 'ipt>');
        \\</script><div id=after>after</div>
    );
    try r.waitJs("document.readyState === 'complete'");
    try util.table(&r, &.{
        .{ .js = "document.getElementById('w').nextElementSibling.id", .want = "w1" },
        .{ .js = "document.getElementById('w1').nextElementSibling.id", .want = "w2" },
        .{ .js = "document.getElementById('after').previousElementSibling.tagName", .want = "SCRIPT" },
        .{ .js = "ranWritten", .want = "true" },
        .{ .js = "var before = document.body.children.length; document.write('<i>late</i>'); document.body.children.length === before", .want = "true" },
    });
    try testing.expect(r.t.hasText("written"));
    try r.expectNoErrors();
}

test "modules import each other, with maps, meta and dynamic import" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    const gpa = testing.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    const leaf = "data:text/javascript,export const leaf = 'L'; export default function hello() { return 'hi' }";
    try b.appendSlice(gpa, "<!doctype html><script type=importmap>{\"imports\":{\"leafy\":\"");
    try b.appendSlice(gpa, leaf);
    try b.appendSlice(gpa, "\"}}</script><script type=module>\nimport hello, {leaf} from 'leafy';\nwindow.got = hello() + leaf;\nwindow.meta = typeof import.meta.url;\nwindow.tla = await Promise.resolve('top');\nimport('leafy').then(m => { window.dyn = m.leaf + m.default() });\nimport('nosuchbare').catch(e => { window.dynFail = e.name });\n</script>");
    try r.html(b.items);
    try r.waitJs("window.dyn && window.dynFail");
    try util.table(&r, &.{
        .{ .js = "got", .want = "hiL" },
        .{ .js = "meta", .want = "string" },
        .{ .js = "tla", .want = "top" },
        .{ .js = "dyn", .want = "Lhi" },
        .{ .js = "dynFail", .want = "TypeError" },
    });
    try r.expectNoErrors();
}

test "a page with no scripts has no world" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open("data:text/html,<!doctype html><p>plain");
    try testing.expect(r.page().js == null);
}

test "a script's failure doesn't stop the next, and errors reach window.onerror" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><script>window.errs = []; window.onerror = function (m, f, l, c, e) { errs.push(String(m)); return true; };
        \\addEventListener('error', e => errs.push('ev:' + e.error.message));
        \\addEventListener('unhandledrejection', e => { e.preventDefault(); errs.push('rej:' + e.reason) });</script>
        \\<script>throw new Error('boom');</script>
        \\<script>this will not parse</script>
        \\<script>window.after = 1; Promise.reject('nope');</script>
    );
    try r.waitJs("document.readyState === 'complete'");
    try r.expectJs("after", "1");
    try r.expectJs("errs.includes('Error: boom') && errs.includes('ev:boom')", "true");
    try r.expectJs("errs.includes('rej:nope')", "true");
    try r.expectJs("errs.some(x => x.includes('SyntaxError'))", "true");
    // Unhandled, it lands in the console.
    _ = try r.eval("window.onerror = null; setTimeout(() => { throw new TypeError('later') }, 0)");
    r.spin(0.02);
    try testing.expect(r.world().consoleHas("later"));
}
