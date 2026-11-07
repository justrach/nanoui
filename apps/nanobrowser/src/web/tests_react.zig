//! A small hand-written React, far enough to prove a real framework's way of
//! working through real rendered output: elements, a diffing render, state that
//! re-renders on a click, and what its event delegation and refs rely on.
const std = @import("std");
const util = @import("tests_util.zig");
const testing = std.testing;
const Run = util.Run;

const mini_react =
    \\const Mini = (() => {
    \\  const h = (type, props, ...children) => ({ type, props: props || {}, children: children.flat().filter(c => c !== null && c !== false && c !== undefined) });
    \\  let rootContainer, rootVnode, rootCurrent, hookIndex = 0, hooks = [], scheduled = false;
    \\  const isText = v => typeof v === 'string' || typeof v === 'number';
    \\  function setProp(el, name, value, old) {
    \\    if (name === 'key') return;
    \\    if (name.startsWith('on')) {
    \\      const t = name.slice(2).toLowerCase();
    \\      if (old) el.removeEventListener(t, old);
    \\      if (value) el.addEventListener(t, value);
    \\    } else if (name === 'style') {
    \\      Object.assign(el.style, value);
    \\    } else if (name === 'className') {
    \\      el.className = value;
    \\    } else if (name in el && name !== 'list') {
    \\      el[name] = value;
    \\    } else {
    \\      el.setAttribute(name, value);
    \\    }
    \\  }
    \\  function create(v) {
    \\    if (isText(v)) return document.createTextNode(String(v));
    \\    const r = resolve(v);
    \\    if (r !== v) return create(r);
    \\    const el = document.createElement(v.type);
    \\    for (const k in v.props) setProp(el, k, v.props[k]);
    \\    for (const c of v.children) el.appendChild(create(c));
    \\    return el;
    \\  }
    \\  function resolve(v) {
    \\    while (typeof v.type === 'function') v = v.type(Object.assign({}, v.props, {children: v.children}));
    \\    return v;
    \\  }
    \\  function patch(parent, el, old, next) {
    \\    if (old === undefined) { parent.appendChild(create(next)); return; }
    \\    if (next === undefined) { parent.removeChild(el); return; }
    \\    if (!isText(old)) old = resolve(old);
    \\    if (!isText(next)) next = resolve(next);
    \\    if (isText(old) || isText(next) || old.type !== next.type) {
    \\      if (isText(old) && isText(next)) { if (old !== next) el.nodeValue = String(next); return; }
    \\      parent.replaceChild(create(next), el);
    \\      return;
    \\    }
    \\    for (const k in old.props) if (!(k in next.props)) { if (k.startsWith('on')) setProp(el, k, null, old.props[k]); else el.removeAttribute(k); }
    \\    for (const k in next.props) if (old.props[k] !== next.props[k]) setProp(el, k, next.props[k], old.props[k]);
    \\    const kids = Array.from(el.childNodes);
    \\    const n = Math.max(old.children.length, next.children.length);
    \\    for (let i = 0; i < n; i++) patch(el, kids[i], old.children[i], next.children[i]);
    \\  }
    \\  function render() {
    \\    scheduled = false; hookIndex = 0;
    \\    const next = resolve(rootVnode());
    \\    if (rootCurrent === undefined) rootContainer.appendChild(create(next));
    \\    else patch(rootContainer, rootContainer.firstChild, rootCurrent, next);
    \\    rootCurrent = next;
    \\  }
    \\  function useState(init) {
    \\    const i = hookIndex++;
    \\    if (!(i in hooks)) hooks[i] = init;
    \\    return [hooks[i], v => { hooks[i] = typeof v === 'function' ? v(hooks[i]) : v; if (!scheduled) { scheduled = true; queueMicrotask(render); } }];
    \\  }
    \\  return { h, useState, mount(fn, into) { rootVnode = fn; rootContainer = into; render(); } };
    \\})();
    \\const {h, useState} = Mini;
    \\function Counter() {
    \\  const [n, setN] = useState(0);
    \\  const [items, setItems] = useState(['alpha']);
    \\  return h('div', {className: 'app', 'data-count': n},
    \\    h('h1', null, 'Count is ', n),
    \\    h('button', {onClick: () => setN(n + 1), id: 'inc'}, 'Increment'),
    \\    h('button', {onClick: () => setItems(items.concat('item' + items.length))}, 'Add item'),
    \\    h('button', {onClick: () => setItems(items.slice(1))}, 'Drop first'),
    \\    h('ul', null, items.map(x => h('li', {key: x}, x))),
    \\    n > 1 ? h('p', {style: {fontWeight: 'bold'}}, 'Big number') : null);
    \\}
    \\Mini.mount(Counter, document.getElementById('root'));
;

test "a mini-React: click, state, diff, rendered text" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><title>mini</title><body><div id=root></div><script>" ++ mini_react ++ "</script>");
    r.t.frame();
    try testing.expect(r.t.containsText("Count is"));
    try testing.expect(r.t.containsText("0"));
    try testing.expect(r.t.hasText("alpha"));
    const button = try r.eval("document.getElementById('inc').__marker = 'same'; 'ok'");
    try testing.expectEqualStrings("ok", button);

    try r.t.clickText("Increment");
    r.settle();
    r.t.frame();
    try r.expectJs("document.querySelector('h1').textContent", "Count is 1");
    try r.expectJs("document.querySelector('.app').dataset.count", "1");
    try testing.expect(r.t.containsText("1"));
    // The diff kept the button: nothing was recreated.
    try r.expectJs("document.getElementById('inc').__marker", "same");

    try r.t.clickText("Increment");
    r.settle();
    r.t.frame();
    try testing.expect(r.t.hasText("Big number"));
    try r.expectJs("getComputedStyle(document.querySelector('p')).fontWeight", "700");

    try r.t.clickText("Add item");
    r.settle();
    r.t.frame();
    try testing.expect(r.t.hasText("item1"));
    try r.t.clickText("Drop first");
    r.settle();
    r.t.frame();
    try testing.expect(!r.t.hasText("alpha"));
    try r.expectJs("document.querySelectorAll('li').length", "1");
    try r.expectNoErrors();
}
