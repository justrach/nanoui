//! Frames: documents in `<iframe>`s, what scripts see across them, and the top layer.
const std = @import("std");
const testing = std.testing;
const u = @import("tests_util.zig");
const frames = @import("../frames.zig");
const Run = u.Run;

test "an iframe shows its srcdoc in its box, with its own world and a load event" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body style="margin:0"><script>var loads = 0;</script>
        \\<iframe id=f style="border:0;width:200px;height:100px" onload="loads++"
        \\ srcdoc="<!doctype html><body style='margin:0'><p id=p style='margin:0'>inside the frame</p><script>var mine = innerWidth + 'x' + innerHeight;</script>"></iframe>
    );
    r.spin(0.05);
    try testing.expect(r.t.hasText("inside the frame"));
    try r.waitJs("loads");
    try u.table(&r, &.{
        .{ .js = "f.contentDocument.getElementById('p').textContent", .want = "inside the frame" },
        .{ .js = "f.contentWindow.mine", .want = "200x100" },
        .{ .js = "f.contentWindow.parent === window && f.contentWindow.top === window", .want = "true" },
        .{ .js = "f.contentWindow.document.body.firstChild.getBoundingClientRect().width", .want = "200" },
        .{ .js = "window.mine", .want = "undefined" },
        .{ .js = "window.length + ',' + (frames[0] === f.contentWindow)", .want = "1,true" },
        .{ .js = "f.contentWindow.frameElement === f", .want = "true" },
    });
    try r.expectNoErrors();
}

test "a script can write into a frame it just made" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><div id=d></div>");
    try u.table(&r, &.{
        .{ .js = "var fr = document.createElement('iframe'); d.append(fr); fr.contentWindow !== null", .want = "true" },
        .{ .js = "var fd = fr.contentDocument; fd.open(); fd.write('<body><b id=w>written</b></body>'); fd.close(); fd.getElementById('w').textContent", .want = "written" },
        .{ .js = "fd.body.tagName", .want = "BODY" },
    });
    r.spin(0.02);
    try testing.expect(r.t.hasText("written"));
    try r.expectJs("d.removeChild(fr); fr.contentWindow", "null");
    r.spin(0.01);
    try testing.expect(!r.t.hasText("written"));
}

test "another origin's frame is walled off but for messages" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><script>var got = []; addEventListener('message', (e) => got.push(e.data.n + ':' + e.origin + ':' + (e.source === x.contentWindow)));</script>
        \\<iframe id=x src="data:text/html,<script>addEventListener('message',(e)=>{e.source.postMessage({n:e.data.n+1},'*')});parent.postMessage({n:1},'*');</script>"></iframe>
    );
    r.spin(0.05);
    try r.waitJs("got.length");
    try r.expectJs("got[0]", "1:null:true");
    try u.table(&r, &.{
        .{ .js = "x.contentDocument", .want = "null" },
        .{ .js = "try { x.contentWindow.document } catch (e) { e.name }", .want = "SecurityError" },
        .{ .js = "try { x.contentWindow.foo } catch (e) { e.name }", .want = "SecurityError" },
        .{ .js = "x.contentWindow.postMessage({n:40},'*'); 0", .want = "0" },
    });
    try r.waitJs("got.length >= 2");
    try r.expectJs("got[1]", "41:null:true");
}

test "a click reaches the page in the frame, not the one around it" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><script>var outer = 0; document.addEventListener('click', () => outer++);</script>
        \\<iframe id=f srcdoc="<!doctype html><body><p id=b onclick='hits++'>press here</p><script>var hits=0;</script>"></iframe>
    );
    r.spin(0.05);
    try r.t.clickText("press here");
    r.spin(0.01);
    try u.table(&r, &.{
        .{ .js = "f.contentWindow.hits", .want = "1" },
        .{ .js = "outer", .want = "0" },
    });
}

test "sandbox without allow-scripts runs nothing" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body>
        \\<iframe id=s sandbox srcdoc="<!doctype html><p>sandboxed words</p><script>parent.bad = 1;</script>"></iframe>
    );
    r.spin(0.05);
    try testing.expect(r.t.hasText("sandboxed words"));
    try u.table(&r, &.{
        .{ .js = "window.bad", .want = "undefined" },
        .{ .js = "s.contentDocument", .want = "null" },
    });
}

test "sandbox with allow-same-origin alone can be reached into, and runs nothing" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><iframe id=s sandbox=allow-same-origin></iframe>");
    try u.table(&r, &.{
        .{ .js = "typeof s.contentWindow.history", .want = "object" },
        .{ .js = "s.contentDocument.body.tagName", .want = "BODY" },
        .{ .js = "var sc = s.contentDocument.createElement('script'); sc.textContent = 'parent.bad = 1'; s.contentDocument.body.append(sc); window.bad", .want = "undefined" },
    });
}

test "frames far from the viewport wait, and nesting has a limit" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "<!doctype html><body style=margin:0><div style=height:6000px></div>");
    for (0..60) |_| try src.appendSlice(testing.allocator, "<iframe src='data:text/html,ad'></iframe>");
    try r.html(src.items);
    r.spin(0.03);
    var live: usize = 0;
    for (r.page().frames.list.items) |f| {
        if (f.page != null) live += 1;
    }
    try testing.expectEqual(@as(usize, 60), r.page().frames.list.items.len);
    try testing.expectEqual(@as(usize, 0), live);
    // A page that frames itself in srcdoc goes on only so far.
    var nest: std.ArrayList(u8) = .empty;
    defer nest.deinit(testing.allocator);
    try r.html("<!doctype html><script>function nest(doc, n) { var f = doc.createElement('iframe'); doc.body.append(f); return f.contentWindow ? nest(f.contentDocument, n + 1) : n; } var depth = 0;</script><body>");
    const got = try r.eval("nest(document, 0)");
    try testing.expectEqualStrings("5", got);
}

test "a modal dialog and a popover go in the top layer" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body style="margin:0"><div style="transform:translateX(0);height:10px"><dialog id=d style="width:100px;height:50px;padding:0;border:0">in</dialog></div>
        \\<div id=p popover style="width:40px;height:40px;padding:0;border:0">pop</div><button id=b popovertarget=p>toggle it</button>
        \\<details name=g id=a><summary>A</summary>aa</details><details name=g id=z open><summary>Z</summary>zz</details>
    );
    try u.table(&r, &.{
        .{ .js = "d.showModal(); d.matches(':modal') && d.open", .want = "true" },
        // Centered in the viewport, whatever holds it.
        .{ .js = "var q = d.getBoundingClientRect(); q.left + ',' + (q.top === (innerHeight - 50) / 2)", .want = "400,true" },
        .{ .js = "d.close(); d.open || d.matches(':modal')", .want = "false" },
        .{ .js = "p.matches(':popover-open')", .want = "false" },
        .{ .js = "p.getBoundingClientRect().width", .want = "0" },
        .{ .js = "p.showPopover(); p.matches(':popover-open') + ',' + p.getBoundingClientRect().width", .want = "true,40" },
        .{ .js = "p.togglePopover(); p.matches(':popover-open')", .want = "false" },
        .{ .js = "a.open = true; a.open + ',' + z.open", .want = "true,false" },
    });
    try r.t.clickText("toggle it");
    r.spin(0.005);
    try r.expectJs("p.matches(':popover-open')", "true");
}

test "navigator says what the user agent claims" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body>");
    try u.table(&r, &.{
        .{ .js = "navigator.webdriver", .want = "false" },
        .{ .js = "navigator.userAgentData.brands.some((b) => b.brand === 'Chromium')", .want = "true" },
        .{ .js = "navigator.userAgent.includes('Chrome/' + navigator.userAgentData.brands[0].version + '.0.0.0')", .want = "true" },
        .{ .js = "navigator.userAgent.endsWith(' Safari/537.36')", .want = "true" },
        .{ .js = "typeof window.chrome", .want = "object" },
    });
}

test "a window held across a navigation is the same window, and one whose frame went answers with nothing" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><iframe id=f></iframe><script>
        \\var held = f.contentWindow, got = [];
        \\addEventListener("message", e => got.push(e.data + ":" + (e.source === held) + ":" + (e.source === f.contentWindow)));
        \\</script>
    );
    try r.expectJs("typeof held.document", "object");
    // To another origin: the same object, which now only takes messages.
    _ = try r.eval("f.src = \"data:text/html,<script>parent.postMessage('hi', '*'); addEventListener('message', e => e.source.postMessage('back ' + e.data, '*'))</script>\"; 0");
    try r.waitJs("got.length === 1");
    try r.expectJs("got[0]", "hi:true:true");
    try r.expectJs("held === f.contentWindow", "true");
    try r.expectJs("try { held.document; 'read' } catch (e) { e.name }", "SecurityError");
    _ = try r.eval("held.postMessage('x', '*'); 0");
    try r.waitJs("got.length === 2");
    try r.expectJs("got[1]", "back x:true:true");
    // Gone: no errors, as in other browsers.
    _ = try r.eval("f.remove(); 0");
    r.spin(0.02);
    try r.expectJs("held.closed", "true");
    try r.expectJs("typeof held.document + held.postMessage('x', '*') + Object.keys(held).length", "undefinedundefined0");
    try r.expectNoErrors();
}

test "a native read off an iframe that's then removed still binds and runs, as Sentry's does" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><script>
        \\var f = document.createElement('iframe'); f.hidden = true; document.head.appendChild(f);
        \\var w = f.contentWindow, st = w.setTimeout, at = w.btoa;
        \\document.head.removeChild(f);
        \\var bound = st.bind(window), fired = 0; bound(() => fired++, 0);
        \\</script>
    );
    try r.waitJs("fired === 1");
    try r.expectJs("typeof st + ',' + at.call(window, 'hi')", "function,aGk=");
    try r.expectNoErrors();
}

test "frame arrays keep their brand, iterator and message clone" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><iframe id=f srcdoc=\"<script>var entries = [[1, 2]];</script>\"></iframe>");
    try r.waitJs("f.contentWindow.entries !== undefined");
    try r.expectJs("Array.isArray(f.contentWindow.entries)", "true");
    try r.expectJs("new Map(f.contentWindow.entries).get(1)", "2");
    try r.expectJs("JSON.stringify(structuredClone(f.contentWindow.entries))", "[[1,2]]");
    try r.expectJs("var ch = new MessageChannel(), cloned; ch.port1.onmessage = e => cloned = e.data; ch.port2.postMessage({tT:f.contentWindow.entries}); 0", "0");
    try r.waitJs("cloned !== undefined");
    try r.expectJs("new Map(cloned.tT).get(1)", "2");
    try r.expectNoErrors();
}

test "a frame's message port can be transferred by its parent" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><iframe id=f></iframe>");
    _ = try r.eval(
        \\var foreign = new f.contentWindow.MessageChannel(), ports, answer;
        \\addEventListener('message', e => ports = e.ports);
        \\postMessage('port', '*', [foreign.port2]);
    );
    try r.waitJs("ports !== undefined");
    try r.expectJs("ports.length", "1");
    _ = try r.eval("ports[0].onmessage = e => answer = e.data; foreign.port1.postMessage('hello')");
    try r.waitJs("answer !== undefined");
    try r.expectJs("answer", "hello");
    try r.expectNoErrors();
}

test "postMessage's second argument as an array transfers nothing; as options it does" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><script>
        \\var got = [];
        \\addEventListener('message', (e) => got.push(e.data + ':' + e.ports.length));
        \\var a = new MessageChannel(), b = new MessageChannel(), c = new MessageChannel();
        \\postMessage('array', [a.port2]);
        \\postMessage('options', { transfer: [b.port2] });
        \\postMessage('third', '*', [c.port2]);
        \\var options = []; options.transfer = [new MessageChannel().port2];
        \\postMessage('array-options', options);
        \\</script>
    );
    try r.waitJs("got.length === 4");
    try r.expectJs("got.join()", "array:0,options:1,third:1,array-options:1");
}
