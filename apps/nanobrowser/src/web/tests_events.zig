//! Events: dispatch, propagation, handlers, and what the pointer and keys send.
const std = @import("std");
const nanoui = @import("nanoui");
const util = @import("tests_util.zig");
const testing = std.testing;
const Run = util.Run;

test "dispatch: capture, target, bubble, and the ways to stop it" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><div id=o><div id=i><button id=b>Press</button></div></div>");
    _ = try r.eval(
        \\var o = document.getElementById('o'), i = document.getElementById('i'), b = document.getElementById('b');
        \\var log = [];
        \\var note = (s) => (e) => log.push(s + ':' + e.eventPhase + ':' + (e.currentTarget.id || e.currentTarget === window && 'w' || 'd'));
        \\window.addEventListener('x', note('wc'), true);
        \\document.addEventListener('x', note('dc'), true);
        \\o.addEventListener('x', note('oc'), {capture: true});
        \\i.addEventListener('x', note('ib'));
        \\b.addEventListener('x', note('bb'));
        \\b.addEventListener('x', note('bc'), true);
        \\o.addEventListener('x', note('ob'));
        \\document.addEventListener('x', note('db'));
        \\window.addEventListener('x', note('wb'));
        \\var ev = new Event('x', {bubbles: true, cancelable: true});
    );
    try util.table(&r, &.{
        .{ .js = "b.dispatchEvent(ev)", .want = "true" },
        .{ .js = "log.join(' ')", .want = "wc:1:w dc:1:d oc:1:o bb:2:b bc:2:b ib:3:i ob:3:o db:3:d wb:3:w" },
        .{ .js = "ev.target === b && ev.currentTarget === null && ev.eventPhase", .want = "0" },
        .{ .js = "log = []; b.dispatchEvent(new Event('x')); log.join(' ')", .want = "wc:1:w dc:1:d oc:1:o bb:2:b bc:2:b" },
        .{ .js = "var c = new Event('c', {cancelable: true}); b.addEventListener('c', e => e.preventDefault()); [b.dispatchEvent(c), c.defaultPrevented].join()", .want = "false,true" },
        .{ .js = "var nc = new Event('c'); b.dispatchEvent(nc) + ',' + nc.defaultPrevented", .want = "true,false" },
        .{ .js = "log = []; b.addEventListener('s', e => { log.push(1); e.stopPropagation() }); b.addEventListener('s', e => log.push(2)); i.addEventListener('s', e => log.push(3)); b.dispatchEvent(new Event('s', {bubbles: true})); log.join()", .want = "1,2" },
        .{ .js = "log = []; b.addEventListener('t', e => { log.push(1); e.stopImmediatePropagation() }); b.addEventListener('t', e => log.push(2)); b.dispatchEvent(new Event('t')); log.join()", .want = "1" },
        .{ .js = "log = []; b.addEventListener('o', e => log.push('once'), {once: true}); b.dispatchEvent(new Event('o')); b.dispatchEvent(new Event('o')); log.join()", .want = "once" },
        .{ .js = "var pe = new Event('p', {cancelable: true}); b.addEventListener('p', e => { e.preventDefault() }, {passive: true}); b.dispatchEvent(pe) + ',' + pe.defaultPrevented", .want = "true,false" },
        .{ .js = "var ac = new AbortController(); log = []; b.addEventListener('a', e => log.push('hit'), {signal: ac.signal}); b.dispatchEvent(new Event('a')); ac.abort(); b.dispatchEvent(new Event('a')); log.join()", .want = "hit" },
        .{ .js = "log = []; var h = {handleEvent(e) { log.push(this === h && e.type) }}; b.addEventListener('h', h); b.dispatchEvent(new Event('h')); log.join()", .want = "h" },
        .{ .js = "log = []; var f = () => log.push('f'); b.addEventListener('d', f); b.addEventListener('d', f); b.dispatchEvent(new Event('d')); b.removeEventListener('d', f); b.dispatchEvent(new Event('d')); log.join()", .want = "f" },
        .{ .js = "var path; b.addEventListener('q', e => path = e.composedPath()); b.dispatchEvent(new Event('q', {bubbles: true})); [path[0] === b, path[path.length - 1] === window, path.length].join()", .want = "true,true,7" },
        .{ .js = "try { b.dispatchEvent({}) } catch (e) { e.name }", .want = "TypeError" },
        .{ .js = "var again = new Event('r'); b.addEventListener('r', () => { try { b.dispatchEvent(again) } catch (e) { window.nested = e.name } }); b.dispatchEvent(again); nested", .want = "InvalidStateError" },
        .{ .js = "var t = new EventTarget(); var got = 0; t.addEventListener('z', e => got = e.detail); t.dispatchEvent(new CustomEvent('z', {detail: 5})); got", .want = "5" },
        .{ .js = "class T extends EventTarget { go() { this.dispatchEvent(new Event('y')) } }; var tt = new T(); var n = 0; tt.addEventListener('y', () => n++); tt.go(); n", .want = "1" },
        .{ .js = "var ie = document.createEvent('Event'); ie.initEvent('legacy', true, true); var saw = 0; b.addEventListener('legacy', () => saw++); b.dispatchEvent(ie); saw", .want = "1" },
        .{ .js = "var me = new MouseEvent('m', {clientX: 3, clientY: 4, button: 2, ctrlKey: true, bubbles: true}); me.clientX + me.clientY + me.button + String(me.ctrlKey) + me.which", .want = "9true3" },
        .{ .js = "new KeyboardEvent('k', {key: 'a', code: 'KeyA'}).key + new KeyboardEvent('k', {keyCode: 65}).which", .want = "a65" },
        .{ .js = "new PointerEvent('p').pointerType + new FocusEvent('f').relatedTarget + new InputEvent('i', {data: 'x'}).data + new UIEvent('u').detail", .want = "mousenullx0" },
        .{ .js = "new CustomEvent('c').detail", .want = "null" },
        .{ .js = "new MouseEvent('m') instanceof UIEvent && new UIEvent('u') instanceof Event && new PointerEvent('m') instanceof MouseEvent", .want = "true" },
        .{ .js = "new Event('e').isTrusted", .want = "false" },
        .{ .js = "new DOMException('m', 'NotFoundError').code + new DOMException('m', 'NotFoundError').name + (new DOMException('m') instanceof Error)", .want = "8NotFoundErrortrue" },
    });
    try r.expectNoErrors();
}

test "handlers: properties, attributes, their scope and return value" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body onhashchange="1"><button id=b onclick="window.got = [this.id, event.type, tagName].join(); return false">B</button>
        \\<form id=f name=fm><input id=i name=q value=v onclick="window.val = value + ':' + form.id"></form>
        \\<div id=d onclick="noSuch.thing()"></div><div id=bad onclick="this will not compile"></div>
        \\<a id=l href="#x" onclick="return false">x</a>
    );
    _ = try r.eval("var b = document.getElementById('b'), i = document.getElementById('i'), d = document.getElementById('d'), bad = document.getElementById('bad');");
    try util.table(&r, &.{
        .{ .js = "var c = new MouseEvent('click', {cancelable: true, bubbles: true}); b.dispatchEvent(c) + ',' + got", .want = "false,b,click,BUTTON" },
        .{ .js = "i.click(); val", .want = "v:f" },
        .{ .js = "typeof b.onclick", .want = "function" },
        .{ .js = "var order = []; var p = document.createElement('p'); p.onclick = () => order.push('prop'); p.addEventListener('click', () => order.push('listener')); p.dispatchEvent(new Event('click')); order.join()", .want = "prop,listener" },
        .{ .js = "p.onclick = null; order = []; p.dispatchEvent(new Event('click')); order.join()", .want = "listener" },
        .{ .js = "p.onclick", .want = "null" },
        .{ .js = "p.onfoo = 1; p.setAttribute('onclick', 'window.attr1 = 1'); p.dispatchEvent(new Event('click')); attr1", .want = "1" },
        .{ .js = "window.onmessage = null; window.onmessage", .want = "null" },
        .{ .js = "document.onclick = () => { window.docHit = 1 }; b.click(); docHit", .want = "1" },
        .{ .js = "document.onclick = null; window.onclick = () => { window.winHit = 1 }; b.click(); winHit", .want = "1" },
        .{ .js = "window.onclick = null; var s = window.onerror = () => true; d.click(); bad.click(); 1", .want = "1" },
    });
    try r.expectNoErrors();
}

test "a real click: the events, its default, and a prevented one" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body style='margin:0'><button id=b>Click me</button><a id=stop href="data:text/html,<p>elsewhere">Stopped link</a>
        \\<label><input id=c type=checkbox> Tick</label><div id=out>none</div>
        \\<script>
        \\var log = [], b = document.getElementById('b');
        \\for (const t of ['pointerdown','mousedown','pointerup','mouseup','click','focus','focusin']) b.addEventListener(t, e => log.push(t + (e.isTrusted ? '' : '?')));
        \\b.addEventListener('click', e => { document.getElementById('out').textContent = 'clicked ' + e.clientX + ' ' + (e.clientY > 0) + ' ' + e.detail });
        \\document.getElementById('stop').addEventListener('click', e => e.preventDefault());
        \\var changes = []; var c = document.getElementById('c');
        \\c.addEventListener('input', e => changes.push('input' + c.checked)); c.addEventListener('change', e => changes.push('change' + c.checked));
        \\</script>
    );
    try r.t.clickText("Click me");
    r.settle();
    try testing.expect(r.t.containsText("clicked"));
    try r.expectJs("log.join()", "pointerdown,mousedown,focus,focusin,pointerup,mouseup,click");
    const url = try testing.allocator.dupe(u8, r.page().url());
    defer testing.allocator.free(url);
    try r.t.clickText("Stopped link");
    r.settle();
    try testing.expectEqualStrings(url, r.page().url());
    try testing.expect(r.t.hasText("Stopped link"));
    try r.t.clickText(" Tick");
    r.settle();
    try r.expectJs("changes.join()", "inputtrue,changetrue");
    try r.expectNoErrors();
}

test "the pointer moving: over, out, enter, leave, move" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body style='margin:0'><div id=a style='height:100px'><div id=i style='height:50px'>inner</div></div><div id=z style='height:100px'>other</div>
        \\<script>
        \\var log = [];
        \\for (const id of ['a','i','z']) { const n = document.getElementById(id); for (const t of ['mouseenter','mouseleave']) n.addEventListener(t, e => log.push(t.slice(5) + id)); }
        \\document.addEventListener('mouseover', e => log.push('over' + e.target.id));
        \\document.addEventListener('mouseout', e => log.push('out' + e.target.id));
        \\var moves = 0; document.addEventListener('mousemove', e => { moves++; window.lastX = e.clientX; window.lastY = e.clientY; window.lastPageY = e.pageY; });
        \\var pointers = 0; document.addEventListener('pointermove', e => pointers++);
        \\</script>
    );
    const y = r.t.findText("inner").?.y;
    const top = y - 8;
    r.t.moveTo(20, y + 5);
    r.t.frame();
    try r.expectJs("log.includes('overi') && log.includes('entera') && log.includes('enteri') && log.indexOf('entera') < log.indexOf('enteri')", "true");
    _ = try r.eval("log.length = 0");
    r.t.moveTo(20, top + 130);
    r.t.frame();
    try r.expectJs("log.join()", "outi,leavei,leavea,overz,enterz");
    try r.expectJs("moves > 0 && pointers === moves", "true");
    try r.expectJs("lastX", "20");
    try r.expectNoErrors();
}

test "keys go to the focused element or the body" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><div id=t tabindex=0>box</div><div style='height:3000px'></div>
        \\<script>
        \\var log = []; document.addEventListener('keydown', e => log.push(e.type + ':' + e.key + ':' + e.target.tagName + ':' + e.code + ':' + e.keyCode));
        \\document.addEventListener('keyup', e => log.push(e.type + ':' + e.key));
        \\document.addEventListener('keypress', e => log.push(e.type + ':' + e.key));
        \\</script>
    );
    r.t.key(.escape);
    r.t.ctx.input.key = null;
    try r.expectJs("log.join()", "keydown:Escape:BODY:Escape:27,keyup:Escape");
    _ = try r.eval("log.length = 0; document.getElementById('t').focus()");
    try r.expectJs("document.activeElement.id", "t");
    r.t.typeText("q");
    r.t.ctx.input.chars = "";
    try r.expectJs("log.join()", "keydown:q:DIV:KeyQ:81,keypress:q,keyup:q");
    // A prevented key doesn't scroll the page.
    _ = try r.eval("document.getElementById('t').blur(); document.addEventListener('keydown', e => { if (e.key === 'ArrowDown') e.preventDefault() }); 0");
    try r.expectJs("document.activeElement === document.body", "true");
    r.t.ctx.input.mouse = .{ .x = 300, .y = 300 };
    r.t.key(.down);
    r.t.ctx.input.key = null;
    try testing.expectEqual(@as(f32, 0), r.page().scrollY());
    r.t.key(.page_down);
    r.t.ctx.input.key = null;
    try testing.expect(r.page().scrollY() > 0);
    try r.expectNoErrors();
}

test "scroll and wheel events" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body style='margin:0'><div id=s style='height:100px;overflow:auto'><div style='height:900px'>inner</div></div><div style='height:3000px'>tall</div>
        \\<script>
        \\var scrolls = 0, boxScrolls = 0, wheels = 0, lastDelta = 0;
        \\addEventListener('scroll', () => scrolls++);
        \\document.getElementById('s').addEventListener('scroll', () => boxScrolls++);
        \\addEventListener('wheel', e => { wheels++; lastDelta = e.deltaY });
        \\</script>
    );
    _ = try r.eval("scrollTo(0, 300); scrollBy(0, 50); 0");
    r.t.frame();
    try r.expectJs("scrollY + ',' + pageYOffset + ',' + document.documentElement.scrollTop", "350,350,350");
    try r.expectJs("scrolls", "1");
    _ = try r.eval("document.getElementById('s').scrollTop = 40; 0");
    r.t.frame();
    try r.expectJs("document.getElementById('s').scrollTop + ',' + boxScrolls", "40,1");
    _ = try r.eval("scrollTo(0, 0); 0");
    r.t.frame();
    r.t.ctx.input.mouse = .{ .x = 400, .y = 400 };
    r.t.ctx.input.precise = true;
    r.t.ctx.input.scroll = .{ .y = -120 };
    r.t.frame();
    r.t.ctx.input.scroll = .{ .y = 0 };
    r.t.frame();
    try r.expectJs("wheels + ',' + lastDelta + ',' + scrollY", "1,120,120");
    _ = try r.eval("addEventListener('wheel', e => e.preventDefault()); 0");
    r.t.ctx.input.scroll = .{ .y = -120 };
    r.t.frame();
    r.t.ctx.input.scroll = .{ .y = 0 };
    r.t.frame();
    try r.expectJs("scrollY", "120");
    try r.expectNoErrors();
}

test "forms: controls, focus, submit, reset" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><form id=f action="/go" method=post><input id=t name=t value=dflt><input id=c name=c type=checkbox checked><input id=r1 name=r type=radio value=1 checked><input id=r2 name=r type=radio value=2>
        \\<textarea id=a name=a>texty</textarea><select id=s name=s><option value=1>One<option value=2 selected>Two<option>Three</select><button id=b type=button>x</button><input id=sub type=submit value=Go></form>
        \\<script>for (const id of ['t','c','r1','r2','a','s','b','f','sub']) window['$' + id] = document.getElementById(id);</script>
    );
    try util.table(&r, &.{
        .{ .js = "$t.value + $t.defaultValue + $t.type + $t.name", .want = "dfltdflttextt" },
        .{ .js = "$t.value = 'x'; $t.value + $t.defaultValue + $t.getAttribute('value')", .want = "xdfltdflt" },
        .{ .js = "$c.checked + ',' + $c.defaultChecked + ',' + $c.value", .want = "true,true,on" },
        .{ .js = "$c.checked = false; $c.checked + ',' + $c.defaultChecked", .want = "false,true" },
        .{ .js = "$r2.checked = true; $r1.checked + ',' + $r2.checked", .want = "false,true" },
        .{ .js = "$a.value + $a.defaultValue + $a.type", .want = "textytextytextarea" },
        .{ .js = "$a.value = 'new'; $a.value + $a.textContent", .want = "newtexty" },
        .{ .js = "$s.value + $s.selectedIndex + $s.options.length + $s.options[1].text + $s.type", .want = "213Twoselect-one" },
        .{ .js = "$s.value = '1'; $s.selectedIndex + ',' + $s.options[0].selected + ',' + $s.options[1].selected", .want = "0,true,false" },
        .{ .js = "$s.selectedIndex = 2; $s.value + $s.options[2].value", .want = "ThreeThree" },
        .{ .js = "$s.options[1].selected = true; $s.value", .want = "2" },
        .{ .js = "$s.value = 'none'; $s.selectedIndex", .want = "0" },
        .{ .js = "$b.type + $sub.type + $b.form.id + $t.form.id", .want = "buttonsubmitff" },
        .{ .js = "$f.elements.length + $f.elements.t.id + $f.elements[0].id + $f.length", .want = "8tt8" },
        .{ .js = "$f.method + $f.action.endsWith('/go')", .want = "posttrue" },
        .{ .js = "$t.disabled + ',' + ($t.disabled = true) + ',' + $t.hasAttribute('disabled')", .want = "false,true,true" },
        .{ .js = "$t.disabled = false; $t.placeholder = 'pp'; $t.getAttribute('placeholder')", .want = "pp" },
        .{ .js = "var o = new Option('Four', '4', false, true); $s.add(o); $s.value + o.index", .want = "43" },
        .{ .js = "o.remove(); $s.options.length", .want = "3" },
        .{ .js = "var fd = new FormData($f); [fd.get('t'), fd.get('r'), fd.get('a'), fd.has('c'), fd.get('sub')].join()", .want = "x,2,new,false," },
        .{ .js = "var submits = 0; $f.addEventListener('submit', e => { submits++; e.preventDefault() }); $sub.click(); submits", .want = "1" },
        .{ .js = "$f.requestSubmit(); submits", .want = "2" },
        .{ .js = "var resets = 0; $f.addEventListener('reset', () => resets++); $f.reset(); resets + $t.value + $c.checked + $a.value", .want = "1dflttruetexty" },
        .{ .js = "$t.focus(); document.activeElement.id", .want = "t" },
        .{ .js = "$t.blur(); document.activeElement.tagName", .want = "BODY" },
        .{ .js = "var fo = []; $c.addEventListener('focus', () => fo.push('f')); $c.addEventListener('blur', () => fo.push('b')); $c.focus(); $c.blur(); fo.join()", .want = "f,b" },
        .{ .js = "$t.value = 'abc'; $t.setSelectionRange(1,2); $t.selectionStart + ',' + $t.selectionEnd", .want = "1,2" },
    });
    try r.expectNoErrors();
}

test "typing in a field: input events, and the value scripts read" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><input id=t autofocus><div id=out>-</div><script>
        \\var t = document.getElementById('t'), out = document.getElementById('out'), seen = [];
        \\t.addEventListener('input', e => { seen.push(e.constructor.name + ':' + t.value); out.textContent = 'typed ' + t.value; });
        \\t.value = 'pre';
        \\t.focus();
        \\</script>
    );
    r.t.frame();
    r.t.frame();
    r.t.typeText("x");
    r.t.ctx.input.chars = "";
    r.t.frame();
    r.t.frame();
    try r.expectJs("t.value", "prex");
    try r.expectJs("seen.join()", "InputEvent:prex");
    try testing.expect(r.t.containsText("typed prex"));
    try r.expectNoErrors();
}
