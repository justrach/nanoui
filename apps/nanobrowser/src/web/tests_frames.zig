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
        .{ .js = "navigator.userAgent.includes('Chrome/' + navigator.userAgentData.brands[0].version)", .want = "true" },
        .{ .js = "typeof window.chrome", .want = "object" },
    });
}
