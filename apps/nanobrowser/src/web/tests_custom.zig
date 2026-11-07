//! Custom elements, observers, shadow roots and templates.
const std = @import("std");
const util = @import("tests_util.zig");
const testing = std.testing;
const Run = util.Run;

test "custom elements: upgrade, lifecycle, attributes, and new" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><x-early id=e a=1>light</x-early><script>
        \\var log = [];
        \\class XEarly extends HTMLElement {
        \\  static get observedAttributes() { return ['a', 'b']; }
        \\  constructor() { super(); log.push('ctor:' + (this instanceof XEarly) + ':' + this.tagName); this.made = true; }
        \\  connectedCallback() { log.push('conn:' + this.isConnected); }
        \\  disconnectedCallback() { log.push('disc'); }
        \\  attributeChangedCallback(n, o, v) { log.push('attr:' + n + ':' + o + ':' + v); }
        \\  hello() { return 'hello ' + this.id; }
        \\}
        \\var before = document.getElementById('e');
        \\var wasUpgraded = before instanceof XEarly;
        \\customElements.define('x-early', XEarly);
        \\</script>
    );
    try util.table(&r, &.{
        .{ .js = "wasUpgraded", .want = "false" },
        .{ .js = "before instanceof XEarly && before instanceof HTMLElement && before.made", .want = "true" },
        .{ .js = "before === document.getElementById('e') && before.hello()", .want = "hello e" },
        .{ .js = "log.join()", .want = "ctor:true:X-EARLY,attr:a:null:1,conn:true" },
        .{ .js = "log = []; before.setAttribute('b', '2'); before.setAttribute('unwatched', '3'); before.removeAttribute('a'); log.join()", .want = "attr:b:null:2,attr:a:1:null" },
        .{ .js = "log = []; before.remove(); log.join()", .want = "disc" },
        .{ .js = "log = []; document.body.appendChild(before); log.join()", .want = "conn:true" },
        .{ .js = "log = []; var made = document.createElement('x-early'); made instanceof XEarly && made.made && log.join()", .want = "ctor:true:X-EARLY" },
        .{ .js = "log = []; document.body.appendChild(made); log.join()", .want = "conn:true" },
        .{ .js = "log = []; var viaNew = new XEarly(); [viaNew.localName, viaNew.isConnected, viaNew.made, log.join()].join()", .want = "x-early,false,true,ctor:true:X-EARLY" },
        .{ .js = "log = []; var holder = document.createElement('div'); holder.innerHTML = '<x-early id=q></x-early>'; var q = holder.firstChild; var pre = q instanceof XEarly; document.body.appendChild(holder); [pre, q instanceof XEarly, log.join()].join()", .want = "false,true,ctor:true:X-EARLY,conn:true" },
        .{ .js = "customElements.get('x-early') === XEarly && customElements.get('x-none') === undefined", .want = "true" },
        .{ .js = "try { customElements.define('x-early', XEarly) } catch (e) { e.name }", .want = "NotSupportedError" },
        .{ .js = "try { customElements.define('nodash', XEarly) } catch (e) { e.name }", .want = "SyntaxError" },
        .{ .js = "try { new (class extends HTMLElement {})() } catch (e) { e.name }", .want = "TypeError" },
        .{ .js = "var waited = customElements.whenDefined('x-later'); var res; waited.then(c => res = c.name); customElements.define('x-later', class XLater extends HTMLElement {}); 1", .want = "1" },
    });
    r.spin(0.005);
    try r.expectJs("res", "XLater");
    try r.expectNoErrors();
}

test "a custom element's content is drawn, through its shadow root too" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><my-card>light child</my-card><script>
        \\customElements.define('my-card', class extends HTMLElement {
        \\  constructor() { super(); this.root = this.attachShadow({mode: 'open'}); }
        \\  connectedCallback() { this.root.innerHTML = '<b>shadow words</b>'; }
        \\});
        \\var c = document.querySelector('my-card');
        \\</script>
    );
    try testing.expect(r.t.hasText("shadow words"));
    // With no `<slot>`, the light children don't show.
    try testing.expect(!r.t.containsText("light child"));
    try util.table(&r, &.{
        .{ .js = "c.shadowRoot === c.root && c.root instanceof ShadowRoot && c.root instanceof DocumentFragment && c.root.host === c", .want = "true" },
        .{ .js = "c.root.nodeType + c.root.nodeName + c.root.parentNode", .want = "11#document-fragmentnull" },
        .{ .js = "c.childNodes.length + c.firstChild.data + c.textContent + c.children.length", .want = "1light childlight child0" },
        .{ .js = "c.root.firstChild.parentNode === c.root && c.root.firstChild.parentElement === null", .want = "true" },
        .{ .js = "c.root.querySelector('b').getRootNode() === c.root && c.root.querySelector('b').getRootNode({composed: true}) === document", .want = "true" },
        .{ .js = "c.innerHTML = 'changed'; c.shadowRoot === c.root && c.childNodes.length + c.innerHTML", .want = "1changed" },
        .{ .js = "try { c.attachShadow({mode: 'open'}) } catch (e) { e.name }", .want = "NotSupportedError" },
        .{ .js = "var cl = document.createElement('div').attachShadow({mode: 'closed'}); cl.host.shadowRoot", .want = "null" },
    });
    r.t.frame();
    try testing.expect(r.t.hasText("shadow words"));
    try r.expectNoErrors();
}

test "slots: light children go where the shadow says" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><x-s id=h><span slot=two>second part</span><b>default part</b></x-s><script>
        \\customElements.define('x-s', class extends HTMLElement { connectedCallback() {
        \\  this.attachShadow({mode: 'open'}).innerHTML = '<i>head</i><slot name=two></slot><u>mid</u><slot></slot><slot name=none>fallback words</slot>';
        \\} });
        \\</script>
    );
    r.t.frame();
    try testing.expect(r.t.hasText("second part"));
    try testing.expect(r.t.hasText("default part"));
    try testing.expect(r.t.hasText("fallback words"));
    const mid = r.t.findText("mid").?;
    try testing.expect(r.t.findText("second part").?.x < mid.x);
    try testing.expect(r.t.findText("default part").?.x > mid.x);
    try r.expectJs("h.shadowRoot.querySelector('slot').assignedNodes()[0].textContent", "second part");
    try r.expectNoErrors();
}

test "templates hold their content apart" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><template id=t><p class=in>tpl</p><script>window.ranTpl = 1</script></template>");
    try testing.expect(!r.t.hasText("tpl"));
    try util.table(&r, &.{
        .{ .js = "t.content instanceof DocumentFragment && t.content.firstChild.textContent", .want = "tpl" },
        .{ .js = "t.childNodes.length + t.innerHTML.slice(0, 15)", .want = "0<p class=\"in\">t" },
        .{ .js = "document.querySelector('.in')", .want = "null" },
        .{ .js = "var c = t.content.cloneNode(true); document.body.appendChild(c); document.querySelector('.in').textContent", .want = "tpl" },
        .{ .js = "typeof ranTpl", .want = "number" },
        .{ .js = "t.innerHTML = '<i>next</i>'; t.content.firstChild.tagName", .want = "I" },
        .{ .js = "var t2 = t.cloneNode(true); t2.content.firstChild.tagName", .want = "I" },
    });
    r.t.frame();
    try testing.expect(r.t.hasText("tpl"));
    try r.expectNoErrors();
}

test "MutationObserver: what changed, as a microtask" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><div id=a x=1>text<span id=s>in</span></div>");
    _ = try r.eval(
        \\var a = document.getElementById('a'), s = document.getElementById('s');
        \\var got = [];
        \\var mo = new MutationObserver((list, o) => { got.push(list.map(m => m.type + ':' + (m.attributeName || '') + ':' + m.addedNodes.length + ':' + m.removedNodes.length + ':' + m.oldValue).join('|') + (o === mo)); });
        \\mo.observe(a, {childList: true, attributes: true, characterData: true, subtree: true, attributeOldValue: true, characterDataOldValue: true});
        \\0
    );
    _ = try r.eval("a.setAttribute('x', '2'); a.appendChild(document.createElement('i')); a.firstChild.data = 'new'; s.remove(); window.syncCount = got.length; 0");
    try r.expectJs("syncCount", "0");
    try r.expectJs("got.length + got[0]", "1attributes:x:0:0:1|childList::1:0:null|characterData::0:0:text|childList::0:1:nulltrue");
    try util.table(&r, &.{
        .{ .js = "got = []; mo.disconnect(); a.setAttribute('x', '3'); 1", .want = "1" },
        .{ .js = "got.length", .want = "0" },
        .{ .js = "mo.observe(a, {attributes: true, attributeFilter: ['y']}); a.setAttribute('x', '4'); a.setAttribute('y', '5'); 1", .want = "1" },
        .{ .js = "got[0]", .want = "attributes:y:0:0:nulltrue" },
        .{ .js = "got = []; mo.disconnect(); mo.observe(a, {childList: true}); a.innerHTML = '<u>1</u><u>2</u>'; mo.takeRecords()[0].addedNodes.length", .want = "2" },
        .{ .js = "got.length", .want = "0" },
        .{ .js = "mo.disconnect(); mo.observe(a, {childList: true}); a.textContent = 'x'; 1", .want = "1" },
        .{ .js = "got[0]", .want = "childList::1:2:nulltrue" },
        .{ .js = "try { mo.observe(a, {}) } catch (e) { e.name }", .want = "TypeError" },
        .{ .js = "mo.disconnect(); got = []; var mo2 = new MutationObserver(l => { got.push('c:' + l[0].target.nodeName) }); mo2.observe(a, {attributes: true}); a.classList.add('n'); a.style.color = 'red'; 1", .want = "1" },
        .{ .js = "got.length + got[0]", .want = "1c:DIV" },
    });
    try r.expectNoErrors();
}

test "ResizeObserver and IntersectionObserver, after layout in a frame" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body style='margin:0'><div id=a style='width:100px;height:50px'>a</div><div style='height:2000px'></div><div id=far style='height:10px'>far</div>
        \\<script>
        \\var rs = [], is = [];
        \\var ro = new ResizeObserver(list => { for (const e of list) rs.push(e.target.id + ':' + e.contentRect.width + ':' + e.borderBoxSize[0].blockSize); });
        \\ro.observe(document.getElementById('a'));
        \\var io = new IntersectionObserver(list => { for (const e of list) is.push(e.target.id + ':' + e.isIntersecting + ':' + (e.intersectionRatio > 0)); });
        \\io.observe(document.getElementById('a')); io.observe(document.getElementById('far'));
        \\</script>
    );
    r.t.frame();
    try r.expectJs("rs.join()", "a:100:50");
    try r.expectJs("is.join()", "a:true:true,far:false:false");
    _ = try r.eval("document.getElementById('a').style.width = '70px'; 0");
    r.t.frame();
    try r.expectJs("rs.join()", "a:100:50,a:70:50");
    _ = try r.eval("scrollTo(0, 2000); 0");
    r.t.frame();
    try r.expectJs("is.join()", "a:true:true,far:false:false,a:false:false,far:true:true");
    _ = try r.eval("ro.disconnect(); io.disconnect(); rs = []; is = []; scrollTo(0, 0); document.getElementById('a').style.width = '20px'; 0");
    r.t.frame();
    r.t.frame();
    try r.expectJs("rs.length + is.length", "0");
    try testing.expect(!r.world().frame_observers);
    try r.expectNoErrors();
}

test "message channels deliver a task apart" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><script>
        \\var mc = new MessageChannel(), got = [];
        \\mc.port1.onmessage = e => got.push(e.data);
        \\mc.port2.postMessage('one'); got.push('sync');
        \\var b1 = new BroadcastChannel('x'), b2 = new BroadcastChannel('x'); b2.onmessage = e => got.push(e.data); b1.postMessage('bc');
        \\</script>
    );
    try r.waitJs("got.length === 3");
    try r.expectJs("got[0] + (got.includes('one') && got.includes('bc'))", "synctrue");
    try r.expectNoErrors();
}

test "matchMedia and resize follow the viewport" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><script>
        \\var mq = matchMedia('(min-width: 800px)'), seen = [], resizes = 0;
        \\mq.addEventListener('change', e => seen.push(e.matches));
        \\addEventListener('resize', () => resizes++);
        \\</script>
    );
    r.t.frame();
    try r.expectJs("mq.matches + ',' + resizes", "true,0");
    r.t.resize(600, 500);
    r.t.frame();
    r.t.frame();
    try r.expectJs("mq.matches + ',' + seen.join() + ',' + resizes + ',' + innerWidth", "false,false,1,600");
    try r.expectNoErrors();
}

test "::slotted reaches what a slot forwards from another shadow tree" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html(
        \\<!doctype html><body><x-outer><ul id=u><li>one</li></ul></x-outer><script>
        \\customElements.define('x-inner', class extends HTMLElement { constructor() { super();
        \\  this.attachShadow({mode: 'open'}).innerHTML = '<style>::slotted(:not([slot])) { display: grid; margin: 7px }</style><div><slot></slot></div>'; } });
        \\customElements.define('x-outer', class extends HTMLElement { constructor() { super();
        \\  this.attachShadow({mode: 'open'}).innerHTML = '<x-inner><slot></slot></x-inner>'; } });
        \\</script>
    );
    try r.expectJs("getComputedStyle(u).display + getComputedStyle(u).marginTop", "grid7px");
    try r.expectNoErrors();
}
