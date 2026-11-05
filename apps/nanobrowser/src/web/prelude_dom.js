// The DOM's pure-logic parts over the natives: constants, ParentNode and
// ChildNode, iteration of collections, reflected attributes, DOMRect, Attr,
// `createEvent` and what a document says of itself.
(function ($, g) {
"use strict";
const def = $.def;
const accessor = (o, name, get, set) => Object.defineProperty(o, name, { get, set, configurable: true, enumerable: true });

// Node's constants.
const constants = { ELEMENT_NODE: 1, ATTRIBUTE_NODE: 2, TEXT_NODE: 3, CDATA_SECTION_NODE: 4, ENTITY_REFERENCE_NODE: 5, ENTITY_NODE: 6, PROCESSING_INSTRUCTION_NODE: 7, COMMENT_NODE: 8, DOCUMENT_NODE: 9, DOCUMENT_TYPE_NODE: 10, DOCUMENT_FRAGMENT_NODE: 11, NOTATION_NODE: 12, DOCUMENT_POSITION_DISCONNECTED: 1, DOCUMENT_POSITION_PRECEDING: 2, DOCUMENT_POSITION_FOLLOWING: 4, DOCUMENT_POSITION_CONTAINS: 8, DOCUMENT_POSITION_CONTAINED_BY: 16, DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC: 32 };
for (const k in constants) {
  Object.defineProperty(Node, k, { value: constants[k], enumerable: true });
  Object.defineProperty(Node.prototype, k, { value: constants[k], enumerable: true });
}
const NP = Node.prototype, EP = Element.prototype, DP = Document.prototype, FP = DocumentFragment.prototype, CP = CharacterData.prototype;
def(NP, "isSameNode", function (o) { return this === o; });
def(NP, "lookupNamespaceURI", function () { return null; });
def(NP, "lookupPrefix", function () { return null; });
def(NP, "isDefaultNamespace", function () { return false; });
accessor(NP, "baseURI", function () { return $.resolveUrl("") || $.pageUrl(); });

// What several node kinds take as "nodes or strings".
function nodify(doc, args) {
  if (args.length === 1) {
    const a = args[0];
    return $.isNode(a) ? a : doc.createTextNode(String(a));
  }
  const f = doc.createDocumentFragment();
  for (const a of args) f.appendChild($.isNode(a) ? a : doc.createTextNode(String(a)));
  return f;
}
const docOf = (n) => n.nodeType === 9 ? n : n.ownerDocument;
function firstNotIn(n, args) {
  while (n && args.includes(n)) n = n.nextSibling;
  return n;
}
const parentMixin = {
  append(...args) { if (args.length) this.insertBefore(nodify(docOf(this), args), null); },
  prepend(...args) { if (args.length) this.insertBefore(nodify(docOf(this), args), this.firstChild); },
  replaceChildren(...args) {
    while (this.firstChild) this.removeChild(this.firstChild);
    if (args.length) this.insertBefore(nodify(docOf(this), args), null);
  },
};
const childMixin = {
  remove() { const p = this.parentNode; if (p) p.removeChild(this); },
  before(...args) {
    const p = this.parentNode; if (!p || !args.length) return;
    let prev = this.previousSibling;
    while (prev && args.includes(prev)) prev = prev.previousSibling;
    p.insertBefore(nodify(this.ownerDocument, args), prev ? prev.nextSibling : p.firstChild);
  },
  after(...args) {
    const p = this.parentNode; if (!p || !args.length) return;
    p.insertBefore(nodify(this.ownerDocument, args), firstNotIn(this.nextSibling, args));
  },
  replaceWith(...args) {
    const p = this.parentNode; if (!p) return;
    const next = firstNotIn(this.nextSibling, args);
    const n = args.length ? nodify(this.ownerDocument, args) : null;
    if (this.parentNode === p) p.removeChild(this);
    if (n) p.insertBefore(n, next);
  },
};
for (const proto of [EP, DP, FP]) for (const k in parentMixin) def(proto, k, parentMixin[k]);
for (const proto of [EP, CP, DocumentType.prototype]) for (const k in childMixin) def(proto, k, childMixin[k]);

// Characters and text. Offsets are UTF-16 units, as strings' are.
const dataOps = {
  appendData(s) { this.data += s; },
  insertData(i, s) { const d = this.data; this.data = d.slice(0, i) + s + d.slice(i); },
  deleteData(i, n) { const d = this.data; this.data = d.slice(0, i) + d.slice(i + n); },
  replaceData(i, n, s) { const d = this.data; this.data = d.slice(0, i) + s + d.slice(i + n); },
  substringData(i, n) { return this.data.substr(i, n); },
};
for (const k in dataOps) def(CP, k, dataOps[k]);
accessor(CP, "length", function () { return this.data.length; });
def(Text.prototype, "splitText", function (i) {
  const d = this.data;
  const rest = this.ownerDocument.createTextNode(d.slice(i));
  this.data = d.slice(0, i);
  if (this.parentNode) this.parentNode.insertBefore(rest, this.nextSibling);
  return rest;
});
accessor(Text.prototype, "wholeText", function () {
  let s = this; while (s.previousSibling && s.previousSibling.nodeType === 3) s = s.previousSibling;
  let out = ""; for (; s && s.nodeType === 3; s = s.nextSibling) out += s.data;
  return out;
});
accessor(DocumentType.prototype, "name", function () { return this.nodeName; });
accessor(DocumentType.prototype, "publicId", function () { return ""; });
accessor(DocumentType.prototype, "systemId", function () { return ""; });

// Collections iterate like arrays.
const AP = Array.prototype;
for (const proto of [NodeList.prototype, HTMLCollection.prototype, DOMTokenList.prototype, NamedNodeMap.prototype]) {
  def(proto, Symbol.iterator, AP[Symbol.iterator]);
}
for (const proto of [NodeList.prototype, DOMTokenList.prototype]) {
  def(proto, "forEach", AP.forEach);
  def(proto, "keys", AP.keys);
  def(proto, "values", AP.values);
  def(proto, "entries", AP.entries);
}
def(DOMTokenList.prototype, "toString", function () { return this.value; });
def(DOMTokenList.prototype, "supports", function () { return true; });

// Attr: a name and an element.
class Attr {
  #owner; #name; #text = "";
  constructor(owner, name) { this.#owner = owner; this.#name = name; }
  get name() { return this.#name; }
  get localName() { const n = this.#name, i = n.indexOf(":"); return i < 0 ? n : n.slice(i + 1); }
  get nodeName() { return this.#name; }
  get namespaceURI() { return null; }
  get prefix() { const n = this.#name, i = n.indexOf(":"); return i < 0 ? null : n.slice(0, i); }
  get value() { return this.#owner ? this.#owner.getAttribute(this.#name) : this.#text; }
  set value(v) { if (this.#owner) this.#owner.setAttribute(this.#name, v); else this.#text = String(v); }
  get nodeValue() { return this.value; }
  set nodeValue(v) { this.value = v; }
  get textContent() { return this.value; }
  set textContent(v) { this.value = v; }
  get ownerElement() { return this.#owner; }
  get specified() { return true; }
  get nodeType() { return 2; }
}
def(g, "Attr", Attr);
$.hook("makeAttr", (el, name) => new Attr(el, name));
const nm = {
  item(i) { return this[i] || null; },
  getNamedItem(name) { const o = this[0] ? this[0].ownerElement : null; return o && o.hasAttribute(name) ? new Attr(o, name) : null; },
  getNamedItemNS(_, name) { return this.getNamedItem(name); },
  setNamedItem(attr) { const o = this[0] ? this[0].ownerElement : null; if (o) o.setAttribute(attr.name, attr.value); return null; },
  removeNamedItem(name) { const o = this[0] ? this[0].ownerElement : null; if (o) o.removeAttribute(name); },
};
for (const k in nm) def(NamedNodeMap.prototype, k, nm[k]);

// Attributes by namespace: stored under their qualified name.
const xlinkName = (ns, name) => ns === "http://www.w3.org/1999/xlink" && name.indexOf(":") < 0 ? "xlink:" + name : name;
const elementNS = {
  getAttributeNS(ns, name) { return this.getAttribute(xlinkName(ns, name)); },
  setAttributeNS(ns, name, v) { this.setAttribute(name, v); },
  removeAttributeNS(ns, name) { this.removeAttribute(xlinkName(ns, name)); },
  hasAttributeNS(ns, name) { return this.hasAttribute(xlinkName(ns, name)); },
  getAttributeNode(name) { return this.hasAttribute(name) ? new Attr(this, name) : null; },
  setAttributeNode(attr) { this.setAttribute(attr.name, attr.value); return null; },
  removeAttributeNode(attr) { this.removeAttribute(attr.name); return attr; },
  getElementsByTagNameNS(ns, name) { return this.getElementsByTagName(name); },
  insertAdjacentElement(where, el) {
    switch (String(where).toLowerCase()) {
      case "beforebegin": if (!this.parentNode) return null; this.parentNode.insertBefore(el, this); return el;
      case "afterbegin": this.insertBefore(el, this.firstChild); return el;
      case "beforeend": this.appendChild(el); return el;
      case "afterend": if (!this.parentNode) return null; this.parentNode.insertBefore(el, this.nextSibling); return el;
    }
    throw new DOMException("The value provided is not one of the positions.", "SyntaxError");
  },
  insertAdjacentText(where, text) { this.insertAdjacentElement(where, this.ownerDocument.createTextNode(text)); },
  webkitMatchesSelector(s) { return this.matches(s); },
  setPointerCapture() {}, releasePointerCapture() {}, hasPointerCapture() { return false; },
  // No animation runs: it is finished as soon as it starts.
  animate() {
    const a = { playState: "finished", currentTime: 0, finished: null, ready: Promise.resolve(), cancel() {}, play() {}, pause() {}, finish() {}, reverse() {}, commitStyles() {}, persist() {}, addEventListener() {}, removeEventListener() {}, onfinish: null, oncancel: null };
    a.finished = Promise.resolve(a);
    g.setTimeout(() => { if (typeof a.onfinish === "function") a.onfinish(new Event("finish")); }, 0);
    return a;
  },
  getAnimations() { return []; },
  requestFullscreen() { return Promise.reject(new TypeError("Fullscreen is not available")); },
  checkVisibility() { return this.getClientRects().length > 0; },
};
for (const k in elementNS) def(EP, k, elementNS[k]);
accessor(EP, "prefix", function () { return null; });
accessor(EP, "assignedSlot", function () {
  const root = this.parentNode && this.parentNode.shadowRoot;
  if (!root) return null;
  const name = this.getAttribute("slot") || "";
  return root.querySelector(name ? `slot[name="${CSS.escape(name)}"]` : "slot:not([name])");
});
accessor(EP, "part", function () { return this.classList; });
for (const name of ["role", "ariaLabel", "ariaHidden", "ariaExpanded", "ariaDisabled", "ariaChecked", "ariaSelected", "ariaCurrent", "ariaHasPopup", "ariaControls", "ariaLive", "ariaValueNow", "ariaValueMin", "ariaValueMax", "ariaDescribedByElements"]) {
  const attr = name === "role" ? "role" : "aria-" + name.slice(4).toLowerCase();
  accessor(EP, name, function () { return this.getAttribute(attr); }, function (v) { if (v === null) this.removeAttribute(attr); else this.setAttribute(attr, v); });
}

// DOMRect.
class DOMRectReadOnly {
  constructor(x = 0, y = 0, width = 0, height = 0) { this.x = +x; this.y = +y; this.width = +width; this.height = +height; }
  get top() { return Math.min(this.y, this.y + this.height); }
  get bottom() { return Math.max(this.y, this.y + this.height); }
  get left() { return Math.min(this.x, this.x + this.width); }
  get right() { return Math.max(this.x, this.x + this.width); }
  toJSON() { return { x: this.x, y: this.y, width: this.width, height: this.height, top: this.top, right: this.right, bottom: this.bottom, left: this.left }; }
  static fromRect(r) { return new this(r && r.x, r && r.y, r && r.width, r && r.height); }
}
class DOMRect extends DOMRectReadOnly {}
def(g, "DOMRect", DOMRect);
def(g, "DOMRectReadOnly", DOMRectReadOnly);
$.hook("makeRect", (x, y, w, h) => new DOMRect(x, y, w, h));
class DOMPoint { constructor(x = 0, y = 0, z = 0, w = 1) { this.x = x; this.y = y; this.z = z; this.w = w; } static fromPoint(p) { return new DOMPoint(p && p.x, p && p.y, p && p.z, p && p.w); } }
def(g, "DOMPoint", DOMPoint);
def(g, "DOMPointReadOnly", DOMPoint);

// The document's other members.
const eventClasses = { Event, Events: Event, HTMLEvents: Event, CustomEvent, UIEvent, UIEvents: UIEvent, MouseEvent, MouseEvents: MouseEvent, KeyboardEvent, KeyboardEvents: KeyboardEvent, FocusEvent, InputEvent, MessageEvent, HashChangeEvent, PopStateEvent, ErrorEvent, TouchEvent, WheelEvent };
const docProps = {
  createEvent(kind) {
    const C = eventClasses[kind];
    if (!C) throw new DOMException("The provided event type ('" + kind + "') is invalid.", "NotSupportedError");
    return new C("");
  },
  createAttribute(name) { return new Attr(null, name); },
  hasFocus() { return true; },
  getElementsByName(name) { return this.querySelectorAll(`[name="${CSS.escape(String(name))}"]`); },
  getSelection() { return g.getSelection(); },
  execCommand() { return false; },
  queryCommandSupported() { return false; },
  queryCommandEnabled() { return false; },
  exitFullscreen() { return Promise.resolve(); },
  createRange() { return new g.Range(); },
  createTreeWalker(root, what, filter) { return new g.TreeWalker(root, what, filter); },
  createNodeIterator(root, what, filter) { return new g.NodeIterator(root, what, filter); },
  createProcessingInstruction(target, data) { return this.createComment(`?${target} ${data}?`); },
  createCDATASection(data) { return this.createTextNode(data); },
  caretRangeFromPoint() { return null; },
  elementsFromPoint(x, y) { const e = this.elementFromPoint(x, y); const out = []; for (let n = e; n; n = n.parentElement) out.push(n); return out; },
  getAnimations() { return []; },
};
for (const k in docProps) def(DP, k, docProps[k]);
const live = (sel) => function () { return this.querySelectorAll(sel); };
accessor(DP, "forms", live("form"));
accessor(DP, "images", live("img"));
accessor(DP, "links", live("a[href],area[href]"));
accessor(DP, "scripts", live("script"));
accessor(DP, "embeds", live("embed"));
accessor(DP, "plugins", live("embed"));
accessor(DP, "anchors", live("a[name]"));
// `document.all`, which old pages test for and new ones compare with (Closure's
// sanitizer: `value === document.all`). One object a document, walked when read.
const allOf = new WeakMap();
accessor(DP, "all", function () {
  let c = allOf.get(this);
  if (c) return c;
  const doc = this;
  const list = () => doc.querySelectorAll("*");
  const named = (name) => doc.getElementById(name) || doc.querySelector(`[name="${String(name).replace(/["\\]/g, "\\$&")}"]`);
  const base = { get length() { return list().length; }, item(i) { return i === undefined ? null : typeof i === "string" && !/^\d+$/.test(i) ? named(i) : list()[i] || null; }, namedItem(n) { return named(n); }, [Symbol.iterator]() { return list()[Symbol.iterator](); } };
  c = $.markAll(new Proxy(base, { get(t, k) { if (k in t || typeof k === "symbol") return t[k]; return t.item(k) || undefined; } }));
  allOf.set(this, c);
  return c;
});
accessor(DP, "defaultView", function () { return this === g.document ? g : null; });
accessor(DP, "referrer", function () { return ""; });
accessor(DP, "domain", function () { const m = /^[a-z+.-]+:\/\/(?:[^@/]*@)?([^:/?#]*)/i.exec(this.URL); return m ? m[1] : ""; }, function () {});
accessor(DP, "characterSet", function () { return "UTF-8"; });
accessor(DP, "charset", function () { return "UTF-8"; });
accessor(DP, "inputEncoding", function () { return "UTF-8"; });
accessor(DP, "contentType", function () { return "text/html"; });
accessor(DP, "compatMode", function () { return "CSS1Compat"; });
accessor(DP, "designMode", function () { return "off"; }, function () {});
accessor(DP, "dir", function () { const r = this.documentElement; return r ? r.getAttribute("dir") || "" : ""; }, function (v) { if (this.documentElement) this.documentElement.setAttribute("dir", v); });
accessor(DP, "visibilityState", function () { return "visible"; });
accessor(DP, "hidden", function () { return false; });
accessor(DP, "wasDiscarded", function () { return false; });
accessor(DP, "fullscreenEnabled", function () { return false; });
accessor(DP, "fullscreenElement", function () { return null; });
accessor(DP, "pointerLockElement", function () { return null; });
accessor(DP, "lastModified", function () { return new Date().toUTCString(); });
accessor(DP, "scrollingElement", function () { return this.documentElement; });
accessor(DP, "styleSheets", function () { return $.styleSheets(this); });
// No `adoptedStyleSheets`: libraries then write `<style>` elements, which work.
accessor(DP, "timeline", function () { return { currentTime: $.now() }; });
const fonts = {
  ready: Promise.resolve(),
  status: "loaded",
  size: 0,
  load() { return Promise.resolve([]); },
  check() { return true; },
  add() {}, delete() { return false; }, clear() {},
  forEach() {},
  addEventListener() {}, removeEventListener() {},
  [Symbol.iterator]() { return [][Symbol.iterator](); },
};
accessor(DP, "fonts", function () { return fonts; });
fonts.ready = Promise.resolve(fonts);
class FontFace { constructor(family, src) { this.family = family; this.src = src; this.status = "loaded"; this.loaded = Promise.resolve(this); } load() { return Promise.resolve(this); } }
def(g, "FontFace", FontFace);
class DOMImplementation {
  createHTMLDocument(title) {
    const d = $.newDocument("<!doctype html><html><head><title></title></head><body></body></html>");
    if (title !== undefined) d.title = String(title); else d.head.removeChild(d.head.firstChild);
    return d;
  }
  createDocumentType(name) { return { nodeType: 10, nodeName: name, name, publicId: "", systemId: "" }; }
  createDocument() { return $.newDocument(""); }
  hasFeature() { return true; }
}
const impl = new DOMImplementation();
accessor(DP, "implementation", function () { return impl; });
def(g, "DOMImplementation", DOMImplementation);

// CSS and its tiny namespace.
const CSSns = {
  escape(s) {
    s = String(s);
    let out = "";
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c === 0) out += "\uFFFD";
      else if ((c >= 1 && c <= 31) || c === 127 || (c >= 48 && c <= 57 && (i === 0 || (i === 1 && s[0] === "-")))) out += "\\" + c.toString(16) + " ";
      else if (i === 0 && c === 45 && s.length === 1) out += "\\-";
      else if (c >= 128 || c === 45 || c === 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)) out += s[i];
      else out += "\\" + s[i];
    }
    return out;
  },
  supports(a, b) {
    if (b !== undefined) return a in document.documentElement.style || a.startsWith("--");
    const m = /^\s*\(?\s*([-\w]+)\s*:/.exec(String(a));
    return !!m && (m[1].startsWith("--") || m[1] in document.documentElement.style || /^(?:display|color|width|height|grid|flex|transform|transition)/.test(m[1]));
  },
};
def(g, "CSS", CSSns);
const document = $.document;
})
