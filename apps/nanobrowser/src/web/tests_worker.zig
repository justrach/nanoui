//! Workers: what a page and its worker see of each other, and that an `<iframe>`'s
//! old attributes do what they say (reCAPTCHA's box leans on all of it).
const std = @import("std");
const u = @import("tests_util.zig");
const Run = u.Run;

fn start(r: *Run, worker: []const u8) !void {
    try r.start();
    errdefer r.stop();
    var buf: [2048]u8 = undefined;
    const page = try std.fmt.bufPrint(&buf,
        \\<!doctype html><body><script>
        \\var got = [], errs = [];
        \\var w = new Worker(URL.createObjectURL(new Blob([`{s}`])));
        \\w.onmessage = e => got.push(e.data);
        \\w.onerror = e => errs.push(e.message);
        \\</script>
    , .{worker});
    try r.html(page);
}

test "a message goes there and back as a copy, and held ones aren't lost" {
    var r: Run = undefined;
    try start(&r, "onmessage = e => postMessage(e.data.n * 2);");
    defer r.stop();
    _ = try r.eval("w.postMessage({n: 21}); w.postMessage({n: 4}); 0");
    try r.waitJs("got.length === 2");
    try r.expectJs("got.join()", "42,8");
    try r.expectNoErrors();
}

test "typed arrays, dates, maps and undefined cross; functions don't" {
    var r: Run = undefined;
    try start(&r, "onmessage = e => postMessage(e.data);");
    defer r.stop();
    _ = try r.eval("w.postMessage({a: new Uint8Array([1,2,250]), d: new Date(5), m: new Map([[1,'x']]), s: new Set([3]), b: new Uint16Array([9]).buffer, f: new Float64Array([0.5]), u: undefined, n: NaN}); 0");
    try r.waitJs("got.length === 1");
    try r.expectJs("var o = got[0]; o.a instanceof Uint8Array && o.a.join()", "1,2,250");
    try r.expectJs("got[0].d.getTime() + got[0].m.get(1) + got[0].s.has(3)", "5xtrue");
    try r.expectJs("new Uint16Array(got[0].b)[0] + ',' + got[0].f[0]", "9,0.5");
    try r.expectJs("'u' in got[0] && got[0].u === undefined && Number.isNaN(got[0].n)", "true");
    try r.expectJs("try { w.postMessage(() => 1); 'sent' } catch (e) { e.name }", "DataCloneError");
    try r.expectJs("var c = {}; c.c = c; try { w.postMessage(c); 'sent' } catch (e) { e.name }", "DataCloneError");
}

test "its global is a worker's: no window, no document, and the page isn't reachable" {
    var r: Run = undefined;
    try start(&r,
        \\postMessage([typeof window, typeof document, typeof self, typeof importScripts, self === globalThis, self instanceof WorkerGlobalScope].join());
        \\postMessage([typeof setTimeout, typeof fetch, typeof crypto.getRandomValues, typeof location.href, typeof navigator.userAgent, typeof TextEncoder].join());
    );
    defer r.stop();
    try r.waitJs("got.length === 2");
    try r.expectJs("got[0]", "undefined,undefined,object,function,true,true");
    try r.expectJs("got[1]", "function,function,function,string,string,function");
    try r.expectNoErrors();
}

test "timers run in it, addEventListener hears, and it can be stopped" {
    var r: Run = undefined;
    try start(&r,
        \\addEventListener("message", e => setTimeout(() => postMessage("late " + e.data), 1));
        \\let n = 0; setInterval(() => postMessage(++n), 2);
    );
    defer r.stop();
    _ = try r.eval("w.postMessage('hi'); 0");
    try r.waitJs("got.includes('late hi')");
    try r.waitJs("got.some(x => x > 1)");
    _ = try r.eval("w.terminate(); got.length = 0; 0");
    r.spin(0.05);
    try r.expectJs("got.length", "0");
}

test "close() from inside ends it; what it throws reaches the page's onerror" {
    var r: Run = undefined;
    try start(&r,
        \\onmessage = e => { if (e.data === "boom") throw new Error("kaboom"); postMessage("closing"); close(); };
    );
    defer r.stop();
    _ = try r.eval("w.postMessage('boom'); 0");
    try r.waitJs("errs.length === 1");
    try r.expectJs("errs[0].includes('kaboom')", "true");
    _ = try r.eval("w.postMessage('x'); 0");
    try r.waitJs("got.length === 1");
    r.spin(0.02);
    _ = try r.eval("w.postMessage('y'); 0");
    r.spin(0.02);
    try r.expectJs("got.length", "1");
}

test "importScripts runs what the script names first; a name it can't know throws" {
    var r: Run = undefined;
    try start(&r,
        \\importScripts("data:text/javascript,self.lib=7");
        \\postMessage(self.lib);
        \\let dyn = "data:text/javascript,self.other=1";
        \\try { importScripts(dyn); postMessage("imported"); } catch (e) { postMessage(e.name); }
    );
    defer r.stop();
    try r.waitJs("got.length === 2");
    try r.expectJs("got.join()", "7,NetworkError");
}

test "another origin's script is refused, and a page going away takes its workers" {
    var r: Run = undefined;
    try start(&r, "postMessage(1);");
    defer r.stop();
    try r.expectJs("location.protocol", "data:");
    try r.expectJs("try { new Worker('https://other.test/w.js'); 'made' } catch (e) { e.name }", "SecurityError");
    try r.waitJs("got.length === 1");
    try r.html("<!doctype html><body><script>var still = 1;</script>");
    r.spin(0.02);
    try r.expectJs("still", "1");
}

test "a port goes to a worker and back, both ways, and what's sent early still arrives" {
    var r: Run = undefined;
    try start(&r,
        \\onmessage = e => { const p = e.ports[0]; p.onmessage = m => p.postMessage("got " + m.data); p.postMessage("hello"); };
        \\const c = new MessageChannel(); postMessage("from the worker", [c.port2]);
        \\c.port1.onmessage = e => { c.port1.postMessage(e.data + " back"); };
    );
    defer r.stop();
    _ = try r.eval(
        \\var c = new MessageChannel(), heard = [], early = [];
        \\c.port1.onmessage = e => heard.push(e.data);
        \\c.port1.postMessage("sent early");
        \\w.postMessage(null, [c.port2]);
        \\w.addEventListener("message", e => { const p = e.ports[0]; p.onmessage = m => early.push(m.data); p.postMessage("ping"); });
        \\0
    );
    try r.waitJs("heard.length === 2");
    try r.expectJs("heard.sort().join('|')", "got sent early|hello");
    try r.waitJs("early.length === 1");
    try r.expectJs("early[0]", "ping back");
    try r.expectNoErrors();
}

test "a port in a window's message, in a frame of this origin and of another" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    const inner = "<script>addEventListener('message', e => { const p = e.ports[0]; p.onmessage = m => p.postMessage(m.data + ' from ' + location.protocol + ' ' + e.data.who); })</script>";
    try r.html("<!doctype html><body><iframe id=same srcdoc=\"" ++ inner ++ "\"></iframe><iframe id=other src=\"data:text/html," ++ inner ++ "\"></iframe><script>var heard = [];</script>");
    r.spin(0.05);
    _ = try r.eval(
        \\for (const [f, who] of [[same, 'same'], [other, 'other']]) {
        \\  const c = new MessageChannel();
        \\  c.port1.onmessage = e => heard.push(e.data);
        \\  f.contentWindow.postMessage({who}, '*', [c.port2]);
        \\  c.port1.postMessage('hi');
        \\}
        \\0
    );
    try r.waitJs("heard.length === 2");
    try r.expectJs("heard.includes('hi from about: same')", "true");
    try r.expectJs("heard.includes('hi from data: other')", "true");
    try r.expectNoErrors();
}

test "an iframe's frameborder and scrolling attributes" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body style="margin:0">
        \\<iframe id=plain style="width:100px;height:50px"></iframe>
        \\<iframe id=none frameborder=0 style="width:100px;height:50px"></iframe>
        \\<iframe id=no frameborder=no style="width:100px;height:50px"></iframe>
        \\<iframe id=one frameborder=1 style="width:100px;height:50px"></iframe>
        \\<iframe id=css frameborder=0 style="border:3px solid red;width:100px;height:50px"></iframe>
    );
    try u.table(&r, &.{
        .{ .js = "plain.offsetWidth", .want = "104" },
        .{ .js = "none.offsetWidth", .want = "100" },
        .{ .js = "no.offsetWidth", .want = "100" },
        .{ .js = "one.offsetWidth", .want = "104" },
        .{ .js = "css.offsetWidth", .want = "106" },
    });
}
