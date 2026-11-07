// Web platform members sites call without asking first: found the way
// `prelude_es.js`'s were. These say truthfully what a browser with nothing granted
// says. What sites do check for, and that isn't here, stays undefined so they choose
// their other path: OffscreenCanvas, createImageBitmap, WebSocket, WebGL.
(function ($, g) {
"use strict";

const def = (o, name, value) => { if (!(name in o)) Object.defineProperty(o, name, { value, writable: true, configurable: true, enumerable: false }); };
const getter = (o, name, get) => { if (!(name in o)) Object.defineProperty(o, name, { get, configurable: true, enumerable: true }); };

// Permissions: nothing granted, and nothing that can be asked.
class PermissionStatus extends EventTarget {
  constructor(name) { super(); this.name = name; this.state = "prompt"; this.onchange = null; }
}
class Permissions { query(d) { return Promise.resolve(new PermissionStatus(d && d.name)); } }
class GeolocationPositionError { constructor() { this.code = 1; this.message = "User denied Geolocation"; } }
Object.assign(GeolocationPositionError, { PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
class Geolocation {
  getCurrentPosition(_ok, failed) { if (failed) g.setTimeout(() => failed(new GeolocationPositionError()), 0); }
  watchPosition(ok, failed) { this.getCurrentPosition(ok, failed); return 0; }
  clearWatch() {}
}
class MediaCapabilities {
  decodingInfo() { return Promise.resolve({ supported: false, smooth: false, powerEfficient: false }); }
  encodingInfo() { return Promise.resolve({ supported: false, smooth: false, powerEfficient: false }); }
}
class MediaSession { constructor() { this.metadata = null; this.playbackState = "none"; } setActionHandler() {} setPositionState() {} }
const once = (make) => { let v; return () => (v ??= make()); };
const NP = g.Navigator && g.Navigator.prototype;
if (NP) {
  getter(NP, "permissions", once(() => new Permissions()));
  getter(NP, "geolocation", once(() => new Geolocation()));
  getter(NP, "mediaCapabilities", once(() => new MediaCapabilities()));
  getter(NP, "mediaSession", once(() => new MediaSession()));
}
for (const c of [PermissionStatus, Permissions, Geolocation, GeolocationPositionError, MediaCapabilities, MediaSession]) def(g, c.name, c);

// Events with a few fields of their own.
class CloseEvent extends Event { constructor(type, i) { super(type, i); this.code = i?.code ?? 0; this.reason = i?.reason ?? ""; this.wasClean = i?.wasClean ?? false; } }
class ToggleEvent extends Event { constructor(type, i) { super(type, i); this.oldState = i?.oldState ?? ""; this.newState = i?.newState ?? ""; } }
class FormDataEvent extends Event { constructor(type, i) { super(type, i); this.formData = i?.formData; } }
class TextEvent extends UIEvent { constructor(type, i) { super(type, i); this.data = i?.data ?? ""; } }
for (const c of [CloseEvent, ToggleEvent, FormDataEvent, TextEvent]) def(g, c.name, c);

// DOMException's old codes, by which old code still tells errors apart.
const codes = { INDEX_SIZE_ERR: 1, DOMSTRING_SIZE_ERR: 2, HIERARCHY_REQUEST_ERR: 3, WRONG_DOCUMENT_ERR: 4, INVALID_CHARACTER_ERR: 5, NO_DATA_ALLOWED_ERR: 6, NO_MODIFICATION_ALLOWED_ERR: 7, NOT_FOUND_ERR: 8, NOT_SUPPORTED_ERR: 9, INUSE_ATTRIBUTE_ERR: 10, INVALID_STATE_ERR: 11, SYNTAX_ERR: 12, INVALID_MODIFICATION_ERR: 13, NAMESPACE_ERR: 14, INVALID_ACCESS_ERR: 15, VALIDATION_ERR: 16, TYPE_MISMATCH_ERR: 17, SECURITY_ERR: 18, NETWORK_ERR: 19, ABORT_ERR: 20, URL_MISMATCH_ERR: 21, QUOTA_EXCEEDED_ERR: 22, TIMEOUT_ERR: 23, INVALID_NODE_TYPE_ERR: 24, DATA_CLONE_ERR: 25 };
for (const name of Object.keys(codes)) { def(DOMException, name, codes[name]); def(DOMException.prototype, name, codes[name]); }
const codeOf = { IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4, InvalidCharacterError: 5, NoModificationAllowedError: 7, NotFoundError: 8, NotSupportedError: 9, InUseAttributeError: 10, InvalidStateError: 11, SyntaxError: 12, InvalidModificationError: 13, NamespaceError: 14, InvalidAccessError: 15, TypeMismatchError: 17, SecurityError: 18, NetworkError: 19, AbortError: 20, URLMismatchError: 21, QuotaExceededError: 22, TimeoutError: 23, InvalidNodeTypeError: 24, DataCloneError: 25 };
getter(DOMException.prototype, "code", function () { return codeOf[this.name] ?? 0; });

// A few calls on the document and on elements.
const DP = Document.prototype, EP = Element.prototype;
def(DP, "getElementsByTagNameNS", function (_ns, name) { return this.getElementsByTagName(name); });
def(EP, "getElementsByTagNameNS", function (_ns, name) { return this.getElementsByTagName(name); });
def(DP, "createAttributeNS", function (_ns, name) { return this.createAttribute(name); });
def(DP, "queryCommandState", () => false);
def(DP, "queryCommandValue", () => "");
def(DP, "queryCommandIndeterm", () => false);
def(DP, "hasStorageAccess", () => Promise.resolve(true));
def(DP, "requestStorageAccess", () => Promise.resolve());
def(DP, "exitPointerLock", () => {});
def(DP, "captureEvents", () => {});
def(DP, "releaseEvents", () => {});
def(DP, "clear", () => {});
getter(DP, "prerendering", () => false);
getter(DP, "fullscreen", () => false);
getter(DP, "rootElement", () => null);
def(g, "captureEvents", () => {});
def(g, "releaseEvents", () => {});
def(EP, "getHTML", function () { return this.innerHTML; });
def(EP, "setHTMLUnsafe", function (html) { this.innerHTML = html; });
def(EP, "scrollIntoViewIfNeeded", function () { this.scrollIntoView(); });
def(EP, "requestPointerLock", () => Promise.reject(new DOMException("Pointer lock isn't available.", "NotSupportedError")));
def(EP, "moveBefore", function (n, before) { return this.insertBefore(n, before); });

// CSS.
const C = g.CSS;
if (C) {
  def(C, "registerProperty", () => {});
  for (const unit of ["number", "percent", "px", "em", "rem", "ex", "ch", "vw", "vh", "vi", "vb", "vmin", "vmax", "cm", "mm", "in", "pt", "pc", "deg", "rad", "grad", "turn", "s", "ms", "Hz", "kHz", "dpi", "dpcm", "dppx", "fr"]) {
    const suffix = unit === "number" ? "" : unit === "percent" ? "%" : unit;
    def(C, unit, (v) => ({ value: v, unit, toString() { return v + suffix; } }));
  }
}

// Tables make their parts.
const TP = g.HTMLTableElement && g.HTMLTableElement.prototype;
if (TP) {
  const part = (tag, make, first) => function () {
    let e = this.querySelector(`:scope > ${tag}`);
    if (e) return e;
    e = this.ownerDocument.createElement(make);
    return first ? this.insertBefore(e, this.firstChild) : this.appendChild(e);
  };
  const drop = (tag) => function () { const e = this.querySelector(`:scope > ${tag}`); if (e) e.remove(); };
  def(TP, "createTHead", part("thead", "thead", true));
  def(TP, "createTFoot", part("tfoot", "tfoot", false));
  def(TP, "createCaption", part("caption", "caption", true));
  def(TP, "createTBody", function () { return this.appendChild(this.ownerDocument.createElement("tbody")); });
  def(TP, "deleteTHead", drop("thead"));
  def(TP, "deleteTFoot", drop("tfoot"));
  def(TP, "deleteCaption", drop("caption"));
}

// What's on the older elements as attributes.
const reflect = (cls, names) => {
  const P = g[cls] && g[cls].prototype;
  if (!P) return;
  for (const name of names) {
    if (name in P) continue;
    const attr = name.toLowerCase();
    Object.defineProperty(P, name, { get() { return this.getAttribute(attr) ?? ""; }, set(v) { this.setAttribute(attr, String(v)); }, configurable: true, enumerable: true });
  }
};
reflect("HTMLIFrameElement", ["align", "scrolling", "frameBorder", "longDesc", "marginHeight", "marginWidth"]);
reflect("HTMLImageElement", ["name", "lowsrc", "align", "longDesc", "border", "fetchPriority"]);
reflect("HTMLAnchorElement", ["coords", "charset", "name", "rev", "shape"]);
reflect("HTMLDivElement", ["align"]);
reflect("HTMLParagraphElement", ["align"]);
reflect("HTMLHeadingElement", ["align"]);
reflect("HTMLHRElement", ["align", "color", "size", "width"]);
reflect("HTMLBRElement", ["clear"]);
reflect("HTMLLIElement", ["type"]);
reflect("HTMLUListElement", ["type"]);
reflect("HTMLTableRowElement", ["align", "vAlign", "bgColor"]);
reflect("HTMLTableSectionElement", ["align", "vAlign"]);
reflect("HTMLTableColElement", ["align", "vAlign", "width"]);
reflect("HTMLTableCaptionElement", ["align"]);
reflect("HTMLLinkElement", ["sizes", "charset", "rev", "target"]);
reflect("HTMLSourceElement", ["width", "height"]);
reflect("HTMLModElement", ["cite", "dateTime"]);
reflect("HTMLOutputElement", ["name"]);
})
