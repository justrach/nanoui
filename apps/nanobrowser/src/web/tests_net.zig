//! `fetch`, XHR, external scripts and cookies over a loopback server, and `data:`.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const util = @import("tests_util.zig");
const cookies = @import("cookies.zig");
const testing = std.testing;
const Io = std.Io;
const Run = util.Run;

/// Answers what the tests ask, on 127.0.0.1, until told to stop.
const Server = struct {
    server: Io.net.Server,
    io: Io,
    port: u16 = 0,
    stopping: std.atomic.Value(bool) = .init(false),
    seen_cookie: std.atomic.Value(bool) = .init(false),

    fn run(s: *Server) void {
        while (!s.stopping.load(.acquire)) {
            var stream = s.server.accept(s.io) catch return;
            defer stream.close(s.io);
            if (s.stopping.load(.acquire)) return;
            s.answer(&stream) catch {};
        }
    }

    fn answer(s: *Server, stream: *Io.net.Stream) !void {
        var in_buf: [4096]u8 = undefined;
        var reader = stream.reader(s.io, &in_buf);
        var head: [8192]u8 = undefined;
        var at: usize = 0;
        while (std.mem.indexOf(u8, head[0..at], "\r\n\r\n") == null and at < head.len) {
            head[at] = try reader.interface.takeByte();
            at += 1;
        }
        const req = head[0..at];
        var length: usize = 0;
        var lines = std.mem.splitSequence(u8, req, "\r\n");
        while (lines.next()) |l| {
            if (std.ascii.startsWithIgnoreCase(l, "content-length:")) length = std.fmt.parseInt(usize, std.mem.trim(u8, l[15..], " "), 10) catch 0;
            if (std.ascii.startsWithIgnoreCase(l, "cookie:")) {
                if (std.mem.indexOf(u8, l, "fromjar=1") != null) s.seen_cookie.store(true, .release);
            }
        }
        var body: [4096]u8 = undefined;
        for (0..@min(length, body.len)) |i| body[i] = try reader.interface.takeByte();
        const sent = body[0..@min(length, body.len)];
        var out_buf: [8192]u8 = undefined;
        var writer = stream.writer(s.io, &out_buf);
        const w = &writer.interface;
        const line_end = std.mem.indexOf(u8, req, "\r\n") orelse req.len;
        const first = req[0..line_end];
        const has = struct {
            fn f(l: []const u8, path: []const u8) bool {
                return std.mem.indexOf(u8, l, path) != null;
            }
        }.f;
        const send = struct {
            fn f(out: *Io.Writer, status: []const u8, ctype: []const u8, extra: []const u8, text: []const u8) !void {
                try out.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, ctype, extra, text.len, text });
            }
        }.f;
        if (has(first, " /json")) {
            try send(w, "200 OK", "application/json", "X-Custom: hello\r\n", "{\"a\":[1,2,3]}");
        } else if (has(first, " /missing")) {
            try send(w, "404 Not Found", "text/plain", "", "no such thing");
        } else if (has(first, " /echo")) {
            var tmp: [4200]u8 = undefined;
            const text = try std.fmt.bufPrint(&tmp, "{s}|{s}", .{ first[0 .. std.mem.indexOfScalar(u8, first, ' ') orelse 0], sent });
            try send(w, "200 OK", "text/plain", "", text);
        } else if (has(first, " /headers")) {
            const lower = std.mem.indexOf(u8, req, "x-mine: yes") != null or std.mem.indexOf(u8, req, "X-Mine: yes") != null;
            try send(w, "200 OK", "text/plain", "", if (lower) "had it" else "without");
        } else if (has(first, " /redirect")) {
            try w.print("HTTP/1.1 302 Found\r\nLocation: /json\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
        } else if (has(first, " /slow.js")) {
            s.io.sleep(.fromMilliseconds(40), .awake) catch {};
            try send(w, "200 OK", "text/javascript", "", "log.push('slow');");
        } else if (has(first, " /fast.js")) {
            try send(w, "200 OK", "text/javascript", "", "log.push('fast');");
        } else if (has(first, " /gone.js")) {
            try send(w, "404 Not Found", "text/plain", "", "");
        } else if (has(first, " /mod.js")) {
            try send(w, "200 OK", "text/javascript", "", "import {dep} from './dep.js'; export const v = 'mod+' + dep; window.fromMod = v;");
        } else if (has(first, " /dep.js")) {
            try send(w, "200 OK", "text/javascript", "", "export const dep = 'dep';");
        } else if (has(first, " /cors-any")) {
            try send(w, "200 OK", "text/plain", "Access-Control-Allow-Origin: *\r\n", "open to all");
        } else if (has(first, " /setcookie")) {
            try send(w, "200 OK", "text/plain", "Set-Cookie: fromjar=1; Path=/\r\n", "ok");
        } else if (has(first, " /page")) {
            try send(w, "200 OK", "text/html", "",
                \\<!doctype html><title>Loop</title><body><script>
                \\var log = [];
                \\</script><script src="/slow.js"></script><script src="/fast.js"></script><script src="/gone.js" onerror="log.push('goneerror')"></script><script>log.push('inline');</script>
                \\<script type=module src="/mod.js"></script>
            );
        } else {
            try send(w, "200 OK", "text/plain", "", "root");
        }
        try w.flush();
    }

    fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        // Wake its accept with one last connection.
        const any = Io.net.IpAddress.parse("127.0.0.1", s.port) catch return;
        var c = any.connect(s.io, .{ .mode = .stream }) catch return;
        c.close(s.io);
    }
};

test "external scripts in order, fetch, XHR, cookies over loopback" {
    cookies.clear();
    defer cookies.clear();
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const any = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var s: Server = .{ .server = try any.listen(io, .{ .reuse_address = true }), .io = io };
    s.port = s.server.socket.address.getPort();
    defer s.server.deinit(io);
    const thread = try std.Thread.spawn(.{}, Server.run, .{&s});
    defer thread.join();
    defer s.stop();

    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var buf: [64]u8 = undefined;
    r.open(try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/page", .{s.port}));
    try r.waitJs("document.readyState === 'complete' && window.fromMod");
    try r.expectJs("log.join()", "slow,fast,goneerror,inline");
    try r.expectJs("fromMod", "mod+dep");
    try r.expectJs("location.host.startsWith('127.0.0.1') && location.protocol + location.pathname", "http:/page");

    _ = try r.eval(
        \\var out = {};
        \\fetch('/json').then(async res => {
        \\  out.status = res.status; out.ok = res.ok; out.custom = res.headers.get('x-custom');
        \\  out.url = res.url.endsWith('/json'); out.ctype = res.headers.get('content-type');
        \\  const copy = res.clone();
        \\  out.json = (await res.json()).a.length;
        \\  out.used = res.bodyUsed;
        \\  out.text = await copy.text();
        \\  try { await res.text() } catch (e) { out.twice = e.name }
        \\  out.done1 = true;
        \\});
        \\fetch('/missing').then(res => { out.missing = res.status + ':' + res.ok; out.done2 = true; });
        \\fetch('/echo', {method: 'POST', body: 'payload', headers: {'x-mine': 'yes'}}).then(r => r.text()).then(t => { out.echo = t; out.done3 = true; });
        \\fetch('/headers', {headers: {'x-mine': 'yes'}}).then(r => r.text()).then(t => { out.hdr = t; out.done4 = true; });
        \\fetch('/redirect').then(res => { out.redirected = res.redirected + ':' + res.url.endsWith('/json'); out.done5 = true; });
        \\fetch('/json').then(r => r.arrayBuffer()).then(b => { out.ab = b.byteLength + ':' + (b instanceof ArrayBuffer); out.done6 = true; });
        \\fetch('/json').then(r => r.blob()).then(async b => { out.blob = b.size + b.type + (await b.text()).length; out.done7 = true; });
        \\fetch('http://127.0.0.1:1/refused').catch(e => { out.refused = e.name; out.done8 = true; });
        \\const ac = new AbortController(); fetch('/slow.js', {signal: ac.signal}).catch(e => { out.aborted = e.name; out.done9 = true; }); ac.abort();
        \\fetch('data:text/plain,inline').then(r => r.text()).then(t => { out.data = t; out.done10 = true; });
        \\fetch(new Request('/echo', {method: 'PUT', body: 'x'})).then(r => r.text()).then(t => { out.req = t; out.done11 = true; });
        \\fetch('/echo', {method: 'POST', body: new URLSearchParams({a: 'b c'})}).then(r => r.text()).then(t => { out.form = t; out.done12 = true; });
        \\0
    );
    try r.waitJs("out.done1 && out.done2 && out.done3 && out.done4 && out.done5 && out.done6 && out.done7 && out.done8 && out.done9 && out.done10 && out.done11 && out.done12");
    try util.table(&r, &.{
        .{ .js = "[out.status, out.ok, out.custom, out.url, out.ctype].join()", .want = "200,true,hello,true,application/json" },
        .{ .js = "[out.json, out.used, out.text, out.twice].join()", .want = "3,true,{\"a\":[1,2,3]},TypeError" },
        .{ .js = "out.missing", .want = "404:false" },
        .{ .js = "out.echo", .want = "POST|payload" },
        .{ .js = "out.hdr", .want = "had it" },
        .{ .js = "out.redirected", .want = "true:true" },
        .{ .js = "out.ab", .want = "13:true" },
        .{ .js = "out.blob", .want = "13application/json13" },
        .{ .js = "out.refused", .want = "TypeError" },
        .{ .js = "out.aborted", .want = "AbortError" },
        .{ .js = "out.data", .want = "inline" },
        .{ .js = "out.req", .want = "PUT|x" },
        .{ .js = "out.form", .want = "POST|a=b+c" },
        .{ .js = "new Response('x', {status: 201}).status + new Response('{}').headers.get('content-type') + Response.json({a: 1}).status + Response.error().status", .want = "201text/plain;charset=UTF-82000" },
        .{ .js = "try { new Response('', {status: 99}) } catch (e) { e.name }", .want = "RangeError" },
        .{ .js = "try { new Request('/x', {body: 'y'}) } catch (e) { e.name }", .want = "TypeError" },
    });

    _ = try r.eval(
        \\var x = new XMLHttpRequest(); var states = [], events = [];
        \\x.onreadystatechange = () => states.push(x.readyState);
        \\for (const t of ['loadstart', 'progress', 'load', 'loadend']) x.addEventListener(t, () => events.push(t));
        \\x.open('GET', '/json'); x.setRequestHeader('x-mine', 'yes'); x.send();
        \\var j = new XMLHttpRequest(); j.responseType = 'json'; j.onload = () => { window.jsonLen = j.response.a.length }; j.open('GET', '/json'); j.send();
        \\var a = new XMLHttpRequest(); a.responseType = 'arraybuffer'; a.onload = () => { window.abLen = a.response.byteLength }; a.open('GET', '/json'); a.send();
        \\var p = new XMLHttpRequest(); p.onload = () => { window.post = p.responseText }; p.open('POST', '/echo'); p.send('body!');
        \\var e = new XMLHttpRequest(); e.onerror = () => { window.xhrErr = e.status + ':' + e.readyState }; e.open('GET', 'http://127.0.0.1:1/x'); e.send();
        \\var ab = new XMLHttpRequest(); ab.onabort = () => { window.xhrAbort = 1 }; ab.open('GET', '/slow.js'); ab.send(); ab.abort();
        \\0
    );
    try r.waitJs("events.includes('loadend') && window.jsonLen && window.abLen && window.post && window.xhrErr && window.xhrAbort");
    try util.table(&r, &.{
        .{ .js = "states.join()", .want = "1,2,3,4" },
        .{ .js = "events.join()", .want = "loadstart,progress,load,loadend" },
        .{ .js = "x.status + x.statusText + x.responseText.length + x.getResponseHeader('X-Custom') + x.responseURL.endsWith('/json')", .want = "200OK13hellotrue" },
        .{ .js = "x.getAllResponseHeaders().includes('x-custom: hello')", .want = "true" },
        .{ .js = "jsonLen + ',' + abLen + ',' + post", .want = "3,13,POST|body!" },
        .{ .js = "xhrErr", .want = "0:4" },
        .{ .js = "XMLHttpRequest.DONE + new XMLHttpRequest().readyState", .want = "4" },
        .{ .js = "try { var y = new XMLHttpRequest(); y.open('GET', '/x', false) } catch (e) { e.name }", .want = "NotSupportedError" },
        .{ .js = "try { new XMLHttpRequest().send() } catch (e) { e.name }", .want = "InvalidStateError" },
    });

    // Another origin's answers: only what its headers let through.
    var cross_buf: [256]u8 = undefined;
    _ = try r.eval(try std.fmt.bufPrint(&cross_buf,
        \\var cross = {{}};
        \\fetch('http://localhost:{d}/json').then(() => {{ cross.a = 'read' }}, e => {{ cross.a = e.name }});
        \\fetch('http://localhost:{d}/cors-any').then(r => r.text()).then(t => {{ cross.b = t }}, e => {{ cross.b = e.name }});
        \\0
    , .{ s.port, s.port }));
    try r.waitJs("cross.a && cross.b");
    try r.expectJs("cross.a + ',' + cross.b", "TypeError,open to all");
    _ = try r.eval("var noFile = 0; fetch('file:///etc/hosts').catch(e => { noFile = e.name }); 0");
    try r.waitJs("noFile");
    try r.expectJs("noFile", "TypeError");

    // Cookies from scripts, and on Linux and Windows from and to the network.
    _ = try r.eval("document.cookie = 'a=1'; document.cookie = 'b=2; path=/; max-age=100'; document.cookie = 'c=3; domain=other.example'; 0");
    try r.expectJs("document.cookie", "a=1; b=2");
    _ = try r.eval("document.cookie = 'a=; max-age=0'; 0");
    try r.expectJs("document.cookie", "b=2");
    if (builtin.os.tag != .macos and builtin.os.tag != .ios) {
        _ = try r.eval("fetch('/setcookie').then(() => fetch('/json')).then(() => { window.cookieDone = 1 }); 0");
        try r.waitJs("window.cookieDone");
        try testing.expect(s.seen_cookie.load(.acquire));
    }
    try r.expectNoErrors();
}
