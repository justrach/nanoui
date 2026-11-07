//! The DOM's classes, the tree and attributes, as scripts see them.
const std = @import("std");
const util = @import("tests_util.zig");
const testing = std.testing;
const Run = util.Run;

test "classes have the right chains and instanceof" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><title>T</title><body><div id=a class='x y'>t<b>u</b></div><a id=l href='/p?q=1#h'>L</a><svg id=s></svg><!--c--><script></script>");
    try util.table(&r, &.{
        .{ .js = "document instanceof Document && document instanceof Node && document instanceof EventTarget", .want = "true" },
        .{ .js = "document.body instanceof HTMLBodyElement && document.body instanceof HTMLElement && document.body instanceof Element", .want = "true" },
        .{ .js = "a.constructor === HTMLDivElement", .want = "true" },
        .{ .js = "document.createElement('a') instanceof HTMLAnchorElement", .want = "true" },
        .{ .js = "document.createElement('img') instanceof HTMLImageElement", .want = "true" },
        .{ .js = "document.createElement('input') instanceof HTMLInputElement", .want = "true" },
        .{ .js = "document.createElement('nosuchtag') instanceof HTMLUnknownElement", .want = "true" },
        .{ .js = "document.createElement('section').constructor === HTMLElement", .want = "true" },
        .{ .js = "document.getElementById('s') instanceof SVGElement", .want = "true" },
        .{ .js = "document.createTextNode('x') instanceof Text && document.createTextNode('x') instanceof CharacterData", .want = "true" },
        .{ .js = "document.createComment('x') instanceof Comment", .want = "true" },
        .{ .js = "document.createDocumentFragment() instanceof DocumentFragment", .want = "true" },
        .{ .js = "window instanceof EventTarget", .want = "true" },
        .{ .js = "window instanceof Window", .want = "true" },
        .{ .js = "new Text('hi').data", .want = "hi" },
        .{ .js = "new Comment('hi').data", .want = "hi" },
        .{ .js = "new DocumentFragment().nodeType", .want = "11" },
        .{ .js = "try { new Node() } catch (e) { e.name }", .want = "TypeError" },
        .{ .js = "try { new HTMLDivElement() } catch (e) { e.name }", .want = "TypeError" },
        .{ .js = "try { Node.prototype.firstChild } catch (e) { e.name }", .want = "TypeError" },
        .{ .js = "Node.ELEMENT_NODE + Node.TEXT_NODE + document.DOCUMENT_NODE", .want = "13" },
        .{ .js = "Object.getPrototypeOf(HTMLDivElement.prototype) === HTMLElement.prototype", .want = "true" },
        .{ .js = "a === document.getElementById('a') && a === document.querySelector('.x')", .want = "true" },
        .{ .js = "a.expando = 7; document.querySelector('#a').expando", .want = "7" },
        .{ .js = "delete window.l; typeof window.l + l.tagName + ('l' in window) + ('nothing_here' in window) + typeof nothing_here", .want = "objectAtruefalseundefined" },
        .{ .js = "addEventListener === EventTarget.prototype.addEventListener", .want = "true" },
        .{ .js = "[a, document, document.createTextNode(''), window, new Event('x'), a.classList].map(x => Object.prototype.toString.call(x).slice(8, -1)).join()", .want = "HTMLDivElement,HTMLDocument,Text,Window,Event,DOMTokenList" },
    });
    try r.expectNoErrors();
}

test "the tree, walked and edited" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><ul id=u><li id=a>one</li><li id=b>two</li><li id=c>three</li></ul><p id=p>x<em>y</em>z</p>");
    try util.table(&r, &.{
        .{ .js = "u.nodeType + u.nodeName", .want = "1UL" },
        .{ .js = "document.nodeName + document.nodeType", .want = "#document9" },
        .{ .js = "u.firstChild === a && u.lastChild === c && a.nextSibling === b && b.previousSibling === a", .want = "true" },
        .{ .js = "a.parentNode === u && a.parentElement === u && document.documentElement.parentElement === null", .want = "true" },
        .{ .js = "document.documentElement.parentNode === document", .want = "true" },
        .{ .js = "a.ownerDocument === document && document.ownerDocument === null", .want = "true" },
        .{ .js = "a.isConnected + ',' + document.createElement('b').isConnected", .want = "true,false" },
        .{ .js = "u.childNodes.length + ',' + u.children.length + ',' + u.childElementCount", .want = "3,3,3" },
        .{ .js = "u.childNodes === u.childNodes && u.children === u.children", .want = "true" },
        .{ .js = "u.childNodes[1] === b && u.childNodes.item(2) === c && u.children[0] === a", .want = "true" },
        .{ .js = "u.childNodes[9] === undefined && u.children.item(9) === null", .want = "true" },
        .{ .js = "[...u.children].map(x => x.id).join()", .want = "a,b,c" },
        .{ .js = "Array.from(u.childNodes).length + Array.prototype.slice.call(u.children).length", .want = "6" },
        .{ .js = "var seen = []; u.childNodes.forEach(n => seen.push(n.id)); seen.join()", .want = "a,b,c" },
        .{ .js = "u.children.a === a && u.children.namedItem('b') === b", .want = "true" },
        .{ .js = "u.firstElementChild === a && u.lastElementChild === c && a.nextElementSibling === b && c.previousElementSibling === b", .want = "true" },
        .{ .js = "var live = u.children; var n = document.createElement('li'); n.id='d'; u.appendChild(n); live.length", .want = "4" },
        .{ .js = "n.remove(); live.length", .want = "3" },
        .{ .js = "u.insertBefore(n, b) === n", .want = "true" },
        .{ .js = "[...u.children].map(x => x.id).join()", .want = "a,d,b,c" },
        .{ .js = "u.replaceChild(n, c) === c", .want = "true" },
        .{ .js = "[...u.children].map(x => x.id).join()", .want = "a,b,d" },
        .{ .js = "u.removeChild(n) === n && n.parentNode", .want = "null" },
        .{ .js = "u.appendChild(c); u.children.length", .want = "3" },
        .{ .js = "try { u.removeChild(p) } catch (e) { e.name + e.code }", .want = "NotFoundError8" },
        .{ .js = "try { a.appendChild(u) } catch (e) { e.name }", .want = "HierarchyRequestError" },
        .{ .js = "try { document.createTextNode('x').appendChild(a) } catch (e) { e.name }", .want = "HierarchyRequestError" },
        .{ .js = "e = document.createElement('p'); try { u.insertBefore(e, p) } catch (x) { x.name }", .want = "NotFoundError" },
        .{ .js = "var f = document.createDocumentFragment(); f.append('a', document.createElement('i')); f.childNodes.length", .want = "2" },
        .{ .js = "p.appendChild(f); f.childNodes.length + ',' + p.childNodes.length", .want = "0,5" },
        .{ .js = "p.textContent", .want = "xyza" },
        .{ .js = "p.firstChild.nodeValue", .want = "x" },
        .{ .js = "p.nodeValue", .want = "null" },
        .{ .js = "var t = p.firstChild; t.data = 'XX'; t.length + p.textContent", .want = "2XXyza" },
        .{ .js = "t.appendData('!'); t.insertData(0,'>'); t.deleteData(1,1); t.replaceData(0,1,'_'); t.data", .want = "_X!" },
        .{ .js = "t.substringData(1,1)", .want = "X" },
        .{ .js = "var s = t.splitText(1); t.data + '|' + s.data + '|' + (t.nextSibling === s)", .want = "_|X!|true" },
        .{ .js = "s.wholeText", .want = "_X!" },
        .{ .js = "p.normalize(); p.firstChild.data + p.childNodes.length", .want = "_X!4" },
        .{ .js = "p.contains(p.firstChild) && !p.contains(u) && p.contains(p)", .want = "true" },
        .{ .js = "p.hasChildNodes() && !document.createElement('b').hasChildNodes()", .want = "true" },
        .{ .js = "a.compareDocumentPosition(b) === 4 && b.compareDocumentPosition(a) === 2", .want = "true" },
        .{ .js = "u.compareDocumentPosition(a) === 20 && a.compareDocumentPosition(u) === 10", .want = "true" },
        .{ .js = "a.compareDocumentPosition(a)", .want = "0" },
        .{ .js = "(a.compareDocumentPosition(document.createElement('b')) & 1) === 1", .want = "true" },
        .{ .js = "a.getRootNode() === document && document.createElement('b').getRootNode().nodeName", .want = "B" },
        .{ .js = "var c2 = u.cloneNode(true); c2.children.length + c2.id + (c2 !== u) + c2.isConnected", .want = "3utruefalse" },
        .{ .js = "u.cloneNode(false).childNodes.length", .want = "0" },
        .{ .js = "u.isEqualNode(u.cloneNode(true)) && !u.isEqualNode(u.cloneNode(false)) && u.isSameNode(u)", .want = "true" },
        .{ .js = "p.prepend('first'); p.firstChild.data", .want = "first" },
        .{ .js = "p.replaceChildren('only', document.createElement('u')); p.innerHTML", .want = "only<u></u>" },
        .{ .js = "p.firstElementChild.before('b4'); p.firstElementChild.after('aft'); p.textContent", .want = "onlyb4aft" },
        .{ .js = "p.firstElementChild.replaceWith('new'); p.textContent", .want = "onlyb4newaft" },
        .{ .js = "p.textContent = ''; p.childNodes.length", .want = "0" },
    });
    try r.expectNoErrors();
}

test "attributes, classes, data and markup" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><div id=a class='x y' title=T data-foo-bar=1 data-q></div><svg id=s viewBox='0 0 1 1'><path d=M0/></svg><div id=h><b>bold</b> text</div>");
    try util.table(&r, &.{
        .{ .js = "a.getAttribute('ID') + a.id + a.title", .want = "aaT" },
        .{ .js = "a.getAttribute('nope')", .want = "null" },
        .{ .js = "a.hasAttribute('title') + ',' + a.hasAttribute('none')", .want = "true,false" },
        .{ .js = "a.setAttribute('X', 'y'); a.getAttribute('x') + a.hasAttribute('X')", .want = "ytrue" },
        .{ .js = "a.removeAttribute('x'); a.hasAttribute('x')", .want = "false" },
        .{ .js = "a.toggleAttribute('t') + ',' + a.toggleAttribute('t') + ',' + a.toggleAttribute('t', true) + ',' + a.toggleAttribute('t', true)", .want = "true,false,true,true" },
        .{ .js = "a.getAttributeNames().join()", .want = "id,class,title,data-foo-bar,data-q,t" },
        .{ .js = "a.removeAttribute('t'); a.attributes.length", .want = "5" },
        .{ .js = "a.attributes[0].name + '=' + a.attributes[0].value", .want = "id=a" },
        .{ .js = "a.attributes.getNamedItem('title').value + a.attributes.title.name", .want = "Ttitle" },
        .{ .js = "[...a.attributes].map(x => x.name).join()", .want = "id,class,title,data-foo-bar,data-q" },
        .{ .js = "try { a.setAttribute('a b','1') } catch (e) { e.name }", .want = "InvalidCharacterError" },
        .{ .js = "a.getAttributeNS(null, 'title') + a.hasAttributeNS(null, 'title')", .want = "Ttrue" },
        .{ .js = "a.setAttributeNS(null, 'k', 'v'); a.getAttribute('k')", .want = "v" },
        .{ .js = "a.removeAttributeNS(null, 'k'); a.hasAttribute('k')", .want = "false" },
        .{ .js = "s.getAttribute('viewBox') + s.tagName + s.namespaceURI", .want = "0 0 1 1svghttp://www.w3.org/2000/svg" },
        .{ .js = "a.namespaceURI", .want = "http://www.w3.org/1999/xhtml" },
        .{ .js = "a.tagName + a.localName", .want = "DIVdiv" },
        .{ .js = "a.className + a.classList.length + a.classList[1]", .want = "x y2y" },
        .{ .js = "a.classList.add('z', 'x'); a.className", .want = "x y z" },
        .{ .js = "a.classList.remove('y'); a.className", .want = "x z" },
        .{ .js = "a.classList.contains('x') + ',' + a.classList.contains('y')", .want = "true,false" },
        .{ .js = "a.classList.toggle('n') + ',' + a.classList.toggle('n') + ',' + a.classList.toggle('m', true) + ',' + a.classList.toggle('m', false)", .want = "true,false,true,false" },
        .{ .js = "a.classList.replace('x', 'w') + a.className", .want = "truew z" },
        .{ .js = "[...a.classList].join('+') + a.classList.value + String(a.classList)", .want = "w+zw zw z" },
        .{ .js = "a.classList.item(5)", .want = "null" },
        .{ .js = "try { a.classList.add('a b') } catch (e) { e.name }", .want = "InvalidCharacterError" },
        .{ .js = "try { a.classList.add('') } catch (e) { e.name }", .want = "SyntaxError" },
        .{ .js = "a.classList === a.classList", .want = "true" },
        .{ .js = "a.className = 'q'; a.getAttribute('class') + a.classList.length", .want = "q1" },
        .{ .js = "a.dataset.fooBar + a.dataset.q + a.dataset.none", .want = "1undefined" },
        .{ .js = "a.dataset.newThing = 5; a.getAttribute('data-new-thing')", .want = "5" },
        .{ .js = "delete a.dataset.newThing; a.hasAttribute('data-new-thing')", .want = "false" },
        .{ .js = "Object.keys(a.dataset).join()", .want = "fooBar,q" },
        .{ .js = "'fooBar' in a.dataset && !('xyz' in a.dataset)", .want = "true" },
        .{ .js = "h.innerHTML", .want = "<b>bold</b> text" },
        .{ .js = "h.outerHTML", .want = "<div id=\"h\"><b>bold</b> text</div>" },
        .{ .js = "h.innerHTML = '<i>new</i><script>window.ran = 1</scr' + 'ipt>'; h.firstChild.tagName + typeof ran", .want = "Iundefined" },
        .{ .js = "h.insertAdjacentHTML('beforeend', '<u>1</u>'); h.insertAdjacentHTML('afterbegin', '<s>0</s>'); h.children[0].tagName + h.lastChild.tagName", .want = "SU" },
        .{ .js = "h.insertAdjacentHTML('beforebegin', '<hr id=hb>'); h.previousElementSibling.id", .want = "hb" },
        .{ .js = "h.insertAdjacentHTML('afterend', '<hr id=ha>'); h.nextElementSibling.id", .want = "ha" },
        .{ .js = "try { h.insertAdjacentHTML('nope', 'x') } catch (e) { e.name }", .want = "SyntaxError" },
        .{ .js = "h.insertAdjacentElement('beforeend', document.createElement('tt')).tagName + h.lastChild.tagName", .want = "TTTT" },
        .{ .js = "h.insertAdjacentText('beforeend', 'txt'); h.lastChild.data", .want = "txt" },
        .{ .js = "h.outerHTML = '<p id=replaced>r</p>'; document.getElementById('replaced').tagName + h.isConnected", .want = "Pfalse" },
        .{ .js = "document.createElement('div').outerHTML", .want = "<div></div>" },
        .{ .js = "document.body.querySelector('path').getAttribute('d')", .want = "M0/" },
    });
    try r.expectNoErrors();
}

test "selectors from scripts" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><div id=a class=k><span class=k name=n1>1</span><span>2</span></div><form name=f><input name=x></form>");
    try util.table(&r, &.{
        .{ .js = "document.querySelector('span').textContent", .want = "1" },
        .{ .js = "document.querySelector('nope')", .want = "null" },
        .{ .js = "document.querySelectorAll('.k').length", .want = "2" },
        .{ .js = "a.querySelector('span:last-child').textContent", .want = "2" },
        .{ .js = "a.querySelectorAll('span').length + a.querySelectorAll(':scope > span').length", .want = "4" },
        .{ .js = "try { document.querySelector('[[') } catch (e) { e.name + e.code }", .want = "SyntaxError12" },
        .{ .js = "a.matches('div.k') + ',' + a.matches('span')", .want = "true,false" },
        .{ .js = "a.firstChild.closest('div') === a && a.closest('nope') === null", .want = "true" },
        .{ .js = "var by = document.getElementsByTagName('span'); by.length", .want = "2" },
        .{ .js = "a.appendChild(document.createElement('span')); by.length", .want = "3" },
        .{ .js = "document.getElementsByClassName('k').length + a.getElementsByClassName('k').length", .want = "3" },
        .{ .js = "document.getElementsByTagName('*').length > 5", .want = "true" },
        .{ .js = "document.getElementsByName('x').length", .want = "1" },
        .{ .js = "var list = document.querySelectorAll('span'); a.lastChild.remove(); list.length", .want = "3" },
        .{ .js = "document.forms.length + document.forms[0].getAttribute('name')", .want = "1f" },
        .{ .js = "document.head.tagName + document.body.tagName + document.documentElement.tagName", .want = "HEADBODYHTML" },
    });
    try r.expectNoErrors();
}

test "the page shows what scripts did to it" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><body><div id=host>start</div><script>var host = document.getElementById('host'); host.textContent = 'made by js'; var x = document.createElement('p'); x.textContent = 'added para'; document.body.appendChild(x);</script>");
    try testing.expect(r.t.hasText("made by js"));
    try testing.expect(r.t.hasText("added para"));
    _ = try r.eval("host.remove(); x.textContent = 'changed para'; document.title = 'New title'");
    r.t.frame();
    try testing.expect(!r.t.hasText("made by js"));
    try testing.expect(r.t.hasText("changed para"));
    try testing.expectEqualStrings("New title", r.page().title());
    _ = try r.eval("x.style.display = 'none'");
    r.t.frame();
    try testing.expect(!r.t.hasText("changed para"));
    _ = try r.eval("x.style.removeProperty('display'); x.innerHTML = '<b>rich</b>'");
    r.t.frame();
    try testing.expect(r.t.hasText("rich"));
}
