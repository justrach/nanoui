//! Events keep their identity and dispatch state across same-origin realms.
const u = @import("tests_util.zig");
const testing = @import("std").testing;

test "cross-frame navigation discards the previous document queued load" {
    var r: u.Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body>");
    _ = try r.eval("var loads = 0; var f = document.createElement('iframe'); document.body.append(f); f.onload = () => loads++; f.srcdoc = '<body>new document</body>'; 0");
    r.spin(0.03);
    try r.expectJs("loads", "1");
    try r.expectNoErrors();
}

test "cross-frame access while fetching must not consume document load" {
    var r: u.Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body>");
    const p = try @import("../page.zig").Page.create(testing.allocator, r.page().host);
    defer p.destroy();
    p.icon_asked = true; // The fixture has no network resources.
    const w = @import("web.zig").ensureWorld(p).?;
    try testing.expect(!w.runner.load_fired);
    p.documentArrived(200, "<!doctype html><script>var loaded = 0; addEventListener('load', () => loaded++);</script>", "", "text/html", "");
    w.enter();
    defer w.leave();
    const got = try w.vm.eval("loaded + ':' + document.readyState", "test");
    try testing.expectEqualStrings("1:complete", try w.vm.toStringSlice(got));
}

test "cross-frame painting never requests an iframe src as an image" {
    var r: u.Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><script>var loads = 0;</script>
        \\<iframe id=f src="data:text/plain,not-an-image" srcdoc="<body>frame</body>" onload="loads++"></iframe>
    );
    r.spin(0.03);
    try r.expectJs("loads", "1");
    const node = r.page().frames.list.items[0].node;
    try testing.expectEqual(@as(usize, 0), node.image_key.len);
    try testing.expect(!r.page().pictures.map.contains("data:text/plain,not-an-image"));
    try r.expectNoErrors();
}

test "cross-frame events retain cancellation propagation and identity" {
    var r: u.Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><iframe id=f></iframe>");
    try u.table(&r, &.{
        .{ .js = "var child = f.contentWindow, doc = f.contentDocument; var input = doc.createElement('input'); doc.body.append(input); var seen = []; child.seen = seen; child.input = input; child.eval(\"input.addEventListener('keydown', e => { seen.push(e.key, e.target === input, e.composedPath()[0] === input); e.preventDefault(); e.stopImmediatePropagation(); }); input.addEventListener('keydown', () => seen.push('second')); document.body.addEventListener('keydown', () => seen.push('bubble'));\"); var ev = new KeyboardEvent('keydown', {key:'Enter',bubbles:true,cancelable:true}); input.dispatchEvent(ev)", .want = "false" },
        .{ .js = "seen.join(',')", .want = "Enter,true,true" },
        .{ .js = "ev.defaultPrevented && ev.target === input && ev.currentTarget === null && ev.eventPhase === 0 && ev.composedPath().length === 0", .want = "true" },
        .{ .js = "child.ev = ev; child.eval(\"ev instanceof Event\")", .want = "false" },
        .{ .js = "var foreign = new child.CustomEvent('probe', {cancelable:true,detail:{answer:42}}); var same = false; document.body.addEventListener('probe', e => { same = e === foreign && e.detail.answer === 42; e.preventDefault(); }); document.body.dispatchEvent(foreign) + ',' + same + ',' + foreign.defaultPrevented", .want = "false,true,true" },
        .{ .js = "child.eval(\"input.addEventListener('passive', e => e.preventDefault(), {passive:true})\"); var passive = new Event('passive', {cancelable:true}); input.dispatchEvent(passive) + ',' + passive.defaultPrevented", .want = "true,false" },
        .{ .js = "child.eval(\"input.addEventListener('recursive', e => { try { parent.document.body.dispatchEvent(e); } catch (x) { seen.push(x.message.includes('already being dispatched')); } })\"); input.dispatchEvent(new Event('recursive')); seen[seen.length-1]", .want = "true" },
        .{ .js = "var rejected = 0; for (var fake of [null, {}, Object.create(Event.prototype), new Proxy(new Event('x'), {})]) { try { document.body.dispatchEvent(fake); } catch(e) { if(e instanceof TypeError) rejected++; } } rejected", .want = "4" },
        .{ .js = "try { input.dispatchEvent({type:'keydown'}); false } catch(e) { e.message.includes('not of type') }", .want = "true" },
    });
    try r.expectNoErrors();
}
