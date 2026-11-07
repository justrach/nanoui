// MutationObserver (records come from `mutate.zig` as a mutation happens),
// ResizeObserver and IntersectionObserver (checked in each frame after layout,
// and only while any exist), DOMParser, XMLSerializer, tree walking, and the
// little of Range and Selection that libraries touch.
(function ($, g) {
"use strict";
const def = $.def;

// Mutation observers.
class MutationRecord {
  constructor(type, target, added, removed, prev, next, attr, old) {
    this.type = type; this.target = target;
    this.addedNodes = added || []; this.removedNodes = removed || [];
    this.previousSibling = prev || null; this.nextSibling = next || null;
    this.attributeName = attr || null; this.attributeNamespace = null;
    this.oldValue = old === undefined ? null : old;
  }
}
const pending = new Set();
let queued = false;
function deliver() {
  queued = false;
  const list = Array.from(pending);
  pending.clear();
  for (const m of list) {
    const r = m._take();
    if (r.length) {
      try { m._cb.call(m, r, m); } catch (e) { $.reportError(e); }
    }
  }
}
$.hook("moRecord", (observer, type, target, added, removed, prev, next, attr, old) => {
  observer._queue.push(new MutationRecord(type, target, added, removed, prev, next, attr, old));
  pending.add(observer);
  if (!queued) { queued = true; g.queueMicrotask(deliver); }
});
class MutationObserver {
  _queue = [];
  constructor(cb) {
    if (typeof cb !== "function") throw new TypeError("Failed to construct 'MutationObserver': parameter 1 is not a function.");
    def(this, "_cb", cb);
  }
  _take() { const r = this._queue; this._queue = []; return r; }
  observe(node, o) {
    if (!$.isNode(node)) throw new TypeError("Failed to execute 'observe' on 'MutationObserver': parameter 1 is not of type 'Node'.");
    o = Object.assign({}, o);
    if (o.attributeOldValue !== undefined || o.attributeFilter !== undefined) { if (o.attributes === undefined) o.attributes = true; }
    if (o.characterDataOldValue !== undefined && o.characterData === undefined) o.characterData = true;
    if (!o.childList && !o.attributes && !o.characterData) throw new TypeError("Failed to execute 'observe' on 'MutationObserver': The options object must set at least one of 'attributes', 'characterData', or 'childList' to true.");
    $.observe(node, this, o);
  }
  disconnect() { $.disconnectObserver(this); this._queue = []; }
  takeRecords() { return this._take(); }
}

// Frame observers.
const resizers = new Set(), intersecters = new Set();
const setWork = () => $.frameObservers(resizers.size + intersecters.size > 0);
class ResizeObserverEntry {
  constructor(target, r) {
    this.target = target;
    this.contentRect = new DOMRectReadOnly(0, 0, r.width, r.height);
    const size = [{ inlineSize: r.width, blockSize: r.height }];
    this.contentBoxSize = size; this.borderBoxSize = size; this.devicePixelContentBoxSize = size;
  }
}
class ResizeObserver {
  #cb; #targets = new Map();
  constructor(cb) {
    if (typeof cb !== "function") throw new TypeError("Failed to construct 'ResizeObserver': parameter 1 is not a function.");
    this.#cb = cb;
  }
  observe(el) {
    if (!$.isNode(el) || el.nodeType !== 1) throw new TypeError("Failed to execute 'observe' on 'ResizeObserver': parameter 1 is not of type 'Element'.");
    this.#targets.set(el, null);
    resizers.add(this);
    setWork();
  }
  unobserve(el) { this.#targets.delete(el); if (!this.#targets.size) resizers.delete(this); setWork(); }
  disconnect() { this.#targets.clear(); resizers.delete(this); setWork(); }
  _check() {
    const out = [];
    for (const [el, last] of this.#targets) {
      const inner = el.getBoundingClientRect ? { width: el.clientWidth || el.getBoundingClientRect().width, height: el.clientHeight || el.getBoundingClientRect().height } : { width: 0, height: 0 };
      if (!last || last.width !== inner.width || last.height !== inner.height) {
        this.#targets.set(el, inner);
        out.push(new ResizeObserverEntry(el, inner));
      }
    }
    if (out.length) { try { this.#cb.call(this, out, this); } catch (e) { $.reportError(e); } }
  }
}
class IntersectionObserverEntry {
  constructor(o) { Object.assign(this, o); }
}
class IntersectionObserver {
  #cb; #targets = new Map(); #thresholds; #margins;
  constructor(cb, o = {}) {
    if (typeof cb !== "function") throw new TypeError("Failed to construct 'IntersectionObserver': parameter 1 is not a function.");
    this.#cb = cb;
    this.root = o.root || null;
    this.rootMargin = o.rootMargin || "0px";
    const t = o.threshold === undefined ? [0] : Array.isArray(o.threshold) ? o.threshold.slice() : [o.threshold];
    this.#thresholds = t.sort((a, b) => a - b);
    this.thresholds = this.#thresholds;
    const m = String(this.rootMargin).trim().split(/\s+/).map((x) => parseFloat(x) || 0);
    this.#margins = [m[0], m[1] === undefined ? m[0] : m[1], m[2] === undefined ? m[0] : m[2], m[3] === undefined ? (m[1] === undefined ? m[0] : m[1]) : m[3]];
  }
  observe(el) {
    if (!$.isNode(el) || el.nodeType !== 1) throw new TypeError("Failed to execute 'observe' on 'IntersectionObserver': parameter 1 is not of type 'Element'.");
    if (!this.#targets.has(el)) this.#targets.set(el, null);
    intersecters.add(this);
    setWork();
  }
  unobserve(el) { this.#targets.delete(el); if (!this.#targets.size) intersecters.delete(this); setWork(); }
  disconnect() { this.#targets.clear(); intersecters.delete(this); setWork(); }
  takeRecords() { return []; }
  #rootRect() {
    const m = this.#margins;
    let r;
    if (this.root && this.root.getBoundingClientRect) { const b = this.root.getBoundingClientRect(); r = { left: b.left, top: b.top, right: b.right, bottom: b.bottom }; }
    else r = { left: 0, top: 0, right: g.innerWidth, bottom: g.innerHeight };
    return { left: r.left - m[3], top: r.top - m[0], right: r.right + m[1], bottom: r.bottom + m[2] };
  }
  _check() {
    const root = this.#rootRect();
    const out = [];
    for (const [el, last] of this.#targets) {
      const b = el.getBoundingClientRect();
      const x1 = Math.max(b.left, root.left), y1 = Math.max(b.top, root.top);
      const x2 = Math.min(b.right, root.right), y2 = Math.min(b.bottom, root.bottom);
      const connected = el.isConnected && (b.width > 0 || b.height > 0 || el.getClientRects().length > 0);
      const crosses = connected && x1 <= x2 && y1 <= y2;
      const area = b.width * b.height;
      const shown = crosses ? Math.max(0, x2 - x1) * Math.max(0, y2 - y1) : 0;
      const ratio = crosses ? (area > 0 ? shown / area : 1) : 0;
      let band = -1;
      for (const t of this.#thresholds) if (crosses && ratio >= t) band++;
      if (last === null || last.band !== band || last.crosses !== crosses) {
        this.#targets.set(el, { band, crosses });
        out.push(new IntersectionObserverEntry({
          target: el, time: $.now(), isIntersecting: crosses && band >= 0, intersectionRatio: ratio,
          boundingClientRect: b,
          intersectionRect: new DOMRect(x1, y1, crosses ? x2 - x1 : 0, crosses ? y2 - y1 : 0),
          rootBounds: new DOMRect(root.left, root.top, root.right - root.left, root.bottom - root.top),
        }));
      }
    }
    if (out.length) { try { this.#cb.call(this, out, this); } catch (e) { $.reportError(e); } }
  }
}
$.hook("frameObservers", () => {
  for (const o of Array.from(resizers)) o._check();
  for (const o of Array.from(intersecters)) o._check();
});
for (const c of [MutationObserver, MutationRecord, ResizeObserver, ResizeObserverEntry, IntersectionObserver, IntersectionObserverEntry]) def(g, c.name, c);

// Message channels: a task apart, as `postMessage` is. A port sent elsewhere stays
// entangled with its partner through page and port numbers: until the far side has
// said where it is (`L`), what's posted waits here (`_limbo`).
const portIds = new Map();
let nextPort = 1;
class MessagePort extends EventTarget {
  _peer = null; _remote = null; _limbo = null; _onmessage = null; _started = false; _queue = [];
  get onmessage() { return this._onmessage; }
  set onmessage(f) { this._onmessage = f; this.start(); }
  onmessageerror = null;
  start() { this._started = true; for (const m of this._queue.splice(0)) this._deliver(m); }
  close() { this._peer = null; this._remote = null; this._limbo = null; }
  postMessage(data, transfer) {
    if (this._remote || this._limbo) {
      const text = $.wire(data, transfer);
      if (this._remote) $.portSend(this._remote.page, this._remote.id, "M" + text);
      else this._limbo.push(text);
      return;
    }
    const to = this._peer;
    if (!to) return;
    const m = { data: g.structuredClone(data), ports: $.transferred(transfer) };
    // Held at the port from now, not from the next task: it may be sent on before then.
    if (to._started) g.setTimeout(() => to._arrive(m), 0);
    else to._queue.push(m);
  }
  _arrive(m) { if (this._started) this._deliver(m); else this._queue.push(m); }
  _deliver(m) {
    const e = new MessageEvent("message", { data: m.data, ports: m.ports, source: null });
    if (typeof this._onmessage === "function") { try { this._onmessage(e); } catch (x) { $.reportError(x); } }
    this.dispatchEvent(e);
  }
}
class MessageChannel {
  constructor() {
    this.port1 = new MessagePort(); this.port2 = new MessagePort();
    this.port1._peer = this.port2; this.port2._peer = this.port1;
  }
}
// A port leaving this VM: what its other side needs to find its partner.
$.portOut = (p) => {
  const out = { page: 0, id: 0, queue: p._queue.splice(0).map((m) => $.wire(m.data, m.ports)) };
  if (p._remote) {
    out.page = p._remote.page; out.id = p._remote.id;
  } else if (p._peer) {
    const q = p._peer;
    q._peer = null; q._limbo = []; q._id = nextPort++;
    portIds.set(q._id, q);
    out.page = $.pageId(); out.id = q._id;
  }
  p._peer = null; p._remote = null; p._limbo = null;
  return out;
};
$.portIn = (entry) => {
  const p = new MessagePort();
  p._id = nextPort++;
  portIds.set(p._id, p);
  if (entry.page) {
    p._remote = { page: entry.page, id: entry.id };
    $.portSend(entry.page, entry.id, "L" + $.pageId() + ":" + p._id);
  }
  for (const t of entry.queue) p._queue.push($.unwire(t));
  return p;
};
$.hook("portMessage", (id, text) => {
  const p = portIds.get(id);
  if (!p) return;
  if (text[0] === "L") {
    const [page, at] = text.slice(1).split(":").map(Number);
    p._remote = { page, id: at };
    for (const t of p._limbo || []) $.portSend(page, at, "M" + t);
    p._limbo = null;
  } else p._arrive($.unwire(text.slice(1)));
});
const channels = new Map();
class BroadcastChannel extends EventTarget {
  onmessage = null;
  constructor(name) { super(); this.name = String(name); if (!channels.has(this.name)) channels.set(this.name, new Set()); channels.get(this.name).add(this); }
  postMessage(data) {
    for (const c of channels.get(this.name) || []) {
      if (c === this) continue;
      const copy = g.structuredClone(data);
      g.setTimeout(() => { const e = new MessageEvent("message", { data: copy }); if (typeof c.onmessage === "function") c.onmessage(e); c.dispatchEvent(e); }, 0);
    }
  }
  close() { const s = channels.get(this.name); if (s) s.delete(this); }
}
for (const c of [MessagePort, MessageChannel, BroadcastChannel]) def(g, c.name, c);

// Parsing and writing markup.
class DOMParser {
  parseFromString(text, type) {
    if (!/^(?:text\/html|text\/xml|application\/xml|application\/xhtml\+xml|image\/svg\+xml)$/.test(String(type))) throw new TypeError("Failed to execute 'parseFromString': The provided value '" + type + "' is not a valid enum value of type SupportedType.");
    return $.newDocument(String(text));
  }
}
class XMLSerializer {
  serializeToString(n) {
    if (n.nodeType === 9) return n.documentElement ? n.documentElement.outerHTML : "";
    if (n.nodeType === 1) return n.outerHTML;
    if (n.nodeType === 3) return n.data.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    if (n.nodeType === 11) { let s = ""; for (const k of n.childNodes) s += this.serializeToString(k); return s; }
    if (n.nodeType === 8) return "<!--" + n.data + "-->";
    return "";
  }
}
def(g, "DOMParser", DOMParser);
def(g, "XMLSerializer", XMLSerializer);

// Walking the tree.
const NodeFilter = {
  FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3,
  SHOW_ALL: 0xFFFFFFFF, SHOW_ELEMENT: 1, SHOW_ATTRIBUTE: 2, SHOW_TEXT: 4, SHOW_CDATA_SECTION: 8, SHOW_ENTITY_REFERENCE: 16, SHOW_ENTITY: 32, SHOW_PROCESSING_INSTRUCTION: 64, SHOW_COMMENT: 128, SHOW_DOCUMENT: 256, SHOW_DOCUMENT_TYPE: 512, SHOW_DOCUMENT_FRAGMENT: 1024, SHOW_NOTATION: 2048,
};
def(g, "NodeFilter", NodeFilter);
function testNode(w, n) {
  if (!((1 << (n.nodeType - 1)) & w.whatToShow)) return 3;
  if (!w.filter) return 1;
  const f = w.filter;
  return typeof f === "function" ? f(n) : f.acceptNode(n);
}
class TreeWalker {
  constructor(root, what = 0xFFFFFFFF, filter = null) { this.root = root; this.whatToShow = what === null ? 0xFFFFFFFF : what; this.filter = filter; this.currentNode = root; }
  #step(first, next) {
    let n = first(this.currentNode);
    while (n) {
      const r = testNode(this, n);
      if (r === 1) { this.currentNode = n; return n; }
      n = next(n, r);
    }
    return null;
  }
  nextNode() {
    let n = this.currentNode, r = 1;
    for (;;) {
      while (r !== 2 && n.firstChild) {
        n = n.firstChild;
        r = testNode(this, n);
        if (r === 1) { this.currentNode = n; return n; }
      }
      let s = null, t = n;
      while (t) {
        if (t === this.root) return null;
        s = t.nextSibling;
        if (s) { n = s; break; }
        t = t.parentNode;
      }
      if (!t) return null;
      r = testNode(this, n);
      if (r === 1) { this.currentNode = n; return n; }
    }
  }
  previousNode() {
    let n = this.currentNode;
    while (n !== this.root) {
      let s = n.previousSibling;
      while (s) {
        n = s;
        let r = testNode(this, n);
        while (r !== 2 && n.lastChild) { n = n.lastChild; r = testNode(this, n); }
        if (r === 1) { this.currentNode = n; return n; }
        s = n.previousSibling;
      }
      if (n === this.root || !n.parentNode) return null;
      n = n.parentNode;
      if (testNode(this, n) === 1) { this.currentNode = n; return n; }
    }
    return null;
  }
  parentNode() {
    let n = this.currentNode;
    while (n && n !== this.root) {
      n = n.parentNode;
      if (n && testNode(this, n) === 1) { this.currentNode = n; return n; }
    }
    return null;
  }
  firstChild() { let n = this.currentNode.firstChild; while (n) { const r = testNode(this, n); if (r === 1) { this.currentNode = n; return n; } n = n.nextSibling; } return null; }
  lastChild() { let n = this.currentNode.lastChild; while (n) { const r = testNode(this, n); if (r === 1) { this.currentNode = n; return n; } n = n.previousSibling; } return null; }
  nextSibling() { let n = this.currentNode.nextSibling; while (n) { const r = testNode(this, n); if (r === 1) { this.currentNode = n; return n; } n = n.nextSibling; } return null; }
  previousSibling() { let n = this.currentNode.previousSibling; while (n) { const r = testNode(this, n); if (r === 1) { this.currentNode = n; return n; } n = n.previousSibling; } return null; }
}
class NodeIterator extends TreeWalker {
  get referenceNode() { return this.currentNode; }
  get pointerBeforeReferenceNode() { return false; }
  detach() {}
}
def(g, "TreeWalker", TreeWalker);
def(g, "NodeIterator", NodeIterator);

// Range and Selection: what libraries touch without selecting anything for real.
class Range {
  constructor() { this.startContainer = g.document; this.startOffset = 0; this.endContainer = g.document; this.endOffset = 0; this.collapsed = true; this.commonAncestorContainer = g.document; }
  setStart(n, o) { this.startContainer = n; this.startOffset = o; this.#update(); }
  setEnd(n, o) { this.endContainer = n; this.endOffset = o; this.#update(); }
  setStartBefore(n) { this.setStart(n.parentNode, Array.prototype.indexOf.call(n.parentNode.childNodes, n)); }
  setStartAfter(n) { this.setStart(n.parentNode, Array.prototype.indexOf.call(n.parentNode.childNodes, n) + 1); }
  setEndBefore(n) { this.setEnd(n.parentNode, Array.prototype.indexOf.call(n.parentNode.childNodes, n)); }
  setEndAfter(n) { this.setEnd(n.parentNode, Array.prototype.indexOf.call(n.parentNode.childNodes, n) + 1); }
  selectNode(n) { this.setStartBefore(n); this.setEndAfter(n); }
  selectNodeContents(n) { this.setStart(n, 0); this.setEnd(n, n.childNodes.length); }
  collapse(toStart) { if (toStart) { this.endContainer = this.startContainer; this.endOffset = this.startOffset; } else { this.startContainer = this.endContainer; this.startOffset = this.endOffset; } this.#update(); }
  #update() {
    this.collapsed = this.startContainer === this.endContainer && this.startOffset === this.endOffset;
    let a = this.startContainer;
    while (a && !a.contains(this.endContainer)) a = a.parentNode;
    this.commonAncestorContainer = a || g.document;
  }
  cloneRange() { const r = new Range(); r.setStart(this.startContainer, this.startOffset); r.setEnd(this.endContainer, this.endOffset); return r; }
  getBoundingClientRect() { const n = this.startContainer; return n.getBoundingClientRect ? n.getBoundingClientRect() : n.parentElement ? n.parentElement.getBoundingClientRect() : new DOMRect(); }
  getClientRects() { const n = this.startContainer; return n.getClientRects ? n.getClientRects() : n.parentElement ? n.parentElement.getClientRects() : []; }
  createContextualFragment(html) {
    const ctx = this.startContainer.nodeType === 1 ? this.startContainer : this.startContainer.parentElement || g.document.body;
    const t = g.document.createElement(ctx.localName === "html" ? "div" : ctx.localName);
    t.innerHTML = html;
    const f = g.document.createDocumentFragment();
    while (t.firstChild) f.appendChild(t.firstChild);
    return f;
  }
  deleteContents() {}
  extractContents() { return g.document.createDocumentFragment(); }
  cloneContents() { return g.document.createDocumentFragment(); }
  insertNode(n) { const c = this.startContainer; if (c.nodeType === 1) c.insertBefore(n, c.childNodes[this.startOffset] || null); else if (c.parentNode) c.parentNode.insertBefore(n, c.nextSibling); }
  surroundContents() {}
  detach() {}
  toString() { return ""; }
}
for (const [k, v] of [["START_TO_START", 0], ["START_TO_END", 1], ["END_TO_END", 2], ["END_TO_START", 3]]) Range[k] = v;
// Ranges compare.
{
  const RP = Range.prototype;
  const def = (o, name, value) => { if (!(name in o)) Object.defineProperty(o, name, { value, writable: true, configurable: true, enumerable: false }); };
  const before = (an, ao, bn, bo) => {
    if (an === bn) return Math.sign(ao - bo);
    const p = an.compareDocumentPosition(bn);
    if (p & Node.DOCUMENT_POSITION_CONTAINED_BY) { let k = bn; while (k.parentNode !== an) k = k.parentNode; return Array.prototype.indexOf.call(an.childNodes, k) < ao ? 1 : -1; }
    if (p & Node.DOCUMENT_POSITION_CONTAINS) { let k = an; while (k.parentNode !== bn) k = k.parentNode; return Array.prototype.indexOf.call(bn.childNodes, k) < bo ? -1 : 1; }
    return p & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
  };
  def(RP, "comparePoint", function (n, o) {
    if (before(n, o, this.startContainer, this.startOffset) < 0) return -1;
    return before(n, o, this.endContainer, this.endOffset) > 0 ? 1 : 0;
  });
  def(RP, "isPointInRange", function (n, o) { return this.comparePoint(n, o) === 0; });
  def(RP, "intersectsNode", function (n) {
    const p = n.parentNode;
    if (!p) return true;
    const i = Array.prototype.indexOf.call(p.childNodes, n);
    return before(p, i, this.endContainer, this.endOffset) < 0 && before(p, i + 1, this.startContainer, this.startOffset) > 0;
  });
  def(RP, "compareBoundaryPoints", function (how, o) {
    const mine = how === 0 || how === 3 ? [this.startContainer, this.startOffset] : [this.endContainer, this.endOffset];
    const theirs = how === 0 || how === 1 ? [o.startContainer, o.startOffset] : [o.endContainer, o.endOffset];
    return before(mine[0], mine[1], theirs[0], theirs[1]);
  });
}
def(g, "Range", Range);
class Selection {
  anchorNode = null; anchorOffset = 0; focusNode = null; focusOffset = 0; isCollapsed = true; rangeCount = 0; type = "None";
  #ranges = [];
  getRangeAt(i) { if (i >= this.#ranges.length) throw new DOMException("0 is not a valid index.", "IndexSizeError"); return this.#ranges[i]; }
  addRange(r) { this.#ranges.push(r); this.rangeCount = this.#ranges.length; this.anchorNode = r.startContainer; this.focusNode = r.endContainer; this.isCollapsed = r.collapsed; this.type = r.collapsed ? "Caret" : "Range"; }
  removeAllRanges() { this.#ranges = []; this.rangeCount = 0; this.anchorNode = this.focusNode = null; this.isCollapsed = true; this.type = "None"; }
  removeRange(r) { this.#ranges = this.#ranges.filter((x) => x !== r); this.rangeCount = this.#ranges.length; }
  empty() { this.removeAllRanges(); }
  collapse() {} extend() {} selectAllChildren() {} deleteFromDocument() {} setBaseAndExtent() {} modify() {} containsNode() { return false; } collapseToStart() {} collapseToEnd() {}
  toString() { return ""; }
}
def(g, "Selection", Selection);
const selection = new Selection();
g.getSelection = function getSelection() { return selection; };
})
